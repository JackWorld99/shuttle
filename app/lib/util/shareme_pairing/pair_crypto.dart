// Shuttle: QR code format and cryptography for QR pairing.
//
// This version covers the same Wi-Fi only: the PC temporarily opens an HTTPS endpoint (with its own TLS certificate) and the phone
// pins it by the fingerprint in the QR code. The QR code carries no Ed25519 public key or signaling address (cross-network pairing
// is not implemented yet), so the transcript hash doesn't include them either.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:localsend_app/model/state/network_state.dart';
import 'package:localsend_app/util/shareme_net_interface.dart';
import 'package:logging/logging.dart';

final _logger = Logger('Pairing');

const pairProtocolVersion = 1;
const pairQrScheme = 'shuttle';
const pairCodeLifetime = Duration(minutes: 5);
const pairVerifyLifetime = Duration(minutes: 2);

/// PC-to-PC pairing: without a camera there's no way to pass a QR code, so the "Add device" page always listens on this port, and
/// the other PC gets its address and certificate fingerprint from "Nearby" and connects directly. LocalSend uses 53317; 53318 is
/// reserved for test tools. If the port is taken, the pairing page falls back to a random port: QR pairing still works, only
/// PC-to-PC pairing doesn't.
const pairNearbyPort = 53319;

final _random = Random.secure();

Uint8List randomBytes(int n) => Uint8List.fromList(List.generate(n, (_) => _random.nextInt(256)));

/// base64url without `=` padding (shorter in the QR code)
String b64u(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List unb64u(String s) => base64Url.decode(s + '=' * ((4 - s.length % 4) % 4));

/// LocalSend fingerprint format: uppercase hex
String toHex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

Uint8List fromHex(String hex) {
  if (hex.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(hex)) {
    throw const FormatException('not hex');
  }
  return Uint8List.fromList([for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
}

Uint8List sha256Of(List<int> data) => Uint8List.fromList(sha256.convert(data).bytes);

Uint8List hmacSha256(List<int> key, List<int> data) => Uint8List.fromList(Hmac(sha256, key).convert(data).bytes);

/// HKDF-SHA256 (RFC 5869). An empty salt means 32 zero bytes, as the RFC specifies.
Uint8List hkdf({required List<int> ikm, List<int>? salt, required List<int> info, required int length}) {
  final prk = hmacSha256(salt == null || salt.isEmpty ? List.filled(32, 0) : salt, ikm);
  final out = BytesBuilder(copy: false);
  var block = <int>[];
  for (var i = 1; out.length < length; i++) {
    block = hmacSha256(prk, [...block, ...info, i]);
    out.add(block);
  }
  return Uint8List.sublistView(out.toBytes(), 0, length);
}

/// Constant-time comparison, so the MAC can't be guessed from timing
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Builds the MAC input from a label and fields: label ‖ each field (4-byte big-endian length ‖ content), so field boundaries can't shift.
Uint8List macInput(String label, List<List<int>> parts) {
  final b = BytesBuilder(copy: false)..add(utf8.encode(label));
  for (final p in parts) {
    b
      ..add([(p.length >> 24) & 0xFF, (p.length >> 16) & 0xFF, (p.length >> 8) & 0xFF, p.length & 0xFF])
      ..add(p);
  }
  return b.toBytes();
}

Uint8List pairMac(List<int> macKey, String label, List<List<int>> parts) => hmacSha256(macKey, macInput(label, parts));

List<int> utf8Of(String s) => utf8.encode(s);

bool _isIpv4(String ip) => RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(ip);

/// Tailscale gives every device an address in 100.64.0.0/10 (carrier-grade NAT uses this range too, so it only means "probably Tailscale")
bool isTailscaleIp(String? ip) {
  if (ip == null || !_isIpv4(ip)) return false;
  final p = ip.split('.').map(int.parse).toList();
  return p[0] == 100 && p[1] >= 64 && p[1] <= 127;
}

// ------------------------------------------------------------------------------------ Addresses offered to the peer when pairing

/// The addresses we tell the peer it can find us at when pairing: LAN addresses (up to 3) + Tailscale addresses (up to 2).
/// The peer stores them in the pairing record and tries them later when not on the same Wi-Fi, so keep only ones it can really reach:
/// - drop loopback, link-local (169.254), 0.x and 464XLAT's 192.0.0.0/29 ([isUsableIpv4]);
/// - drop addresses on mobile-data interfaces. VoLTE's 10.73.x used to be stored and could never be reached; a carrier-grade NAT
///   address can also be in 100.64.0.0/10, get stored as Tailscale, and later make the peer probe other people's devices;
/// - 100.64.0.0/10 counts as Tailscale only on a Tailscale or VPN interface (Android tun*); on Wi-Fi etc. it's a plain LAN address;
/// - drop other VPNs (e.g. a proxy app's tun interface, whose address is fake) and host-only virtual networks (WSL, Hyper-V, VMware,
///   VirtualBox).
/// Interfaces are classified in shareme_net_interface.dart. Addresses whose interface is unknown fall back to the old range-only
/// check, so Tailscale addresses aren't squeezed out.
List<String> pairAddresses(NetworkState network) {
  final lan = <String>[];
  final tailscale = <String>[];
  final dropped = <String>[];
  for (final ip in network.localIps.toSet()) {
    if (!isUsableIpv4(ip)) continue;
    final name = network.interfaceNames[ip];
    switch (name == null || name.isEmpty ? null : netInterfaceKindOf(name)) {
      case null:
        (isTailscaleIp(ip) ? tailscale : lan).add(ip);
      case NetInterfaceKind.other:
        lan.add(ip);
      case NetInterfaceKind.tailscale || NetInterfaceKind.vpn when inTailscaleRange(ip):
        tailscale.add(ip);
      case NetInterfaceKind.tailscale || NetInterfaceKind.vpn || NetInterfaceKind.cellular || NetInterfaceKind.hostOnly:
        dropped.add('$ip ($name)');
    }
  }
  if (dropped.isNotEmpty) _logger.info('Not offered for pairing (unreachable for the peer): ${dropped.join(', ')}');
  return [...lan.take(3), ...tailscale.take(2)];
}

/// QR code content: `shuttle://pair?v=1&f=<PC certificate fingerprint>&k=<one-time key>&a=<ip:port,...>`. No device name.
class PairInvite {
  /// The PC's TLS certificate fingerprint (uppercase hex, 64 characters)
  final String fingerprint;

  /// One-time pairing key K, 16 bytes
  final Uint8List key;

  /// The PC's LAN addresses with the pairing endpoint's port
  final List<({String host, int port})> addresses;

  const PairInvite({required this.fingerprint, required this.key, required this.addresses});

  String encode() {
    final a = addresses.map((e) => '${e.host}:${e.port}').join(',');
    return '$pairQrScheme://pair?v=$pairProtocolVersion&f=${b64u(fromHex(fingerprint))}&k=${b64u(key)}&a=$a';
  }

  /// Returns null for a code that isn't ours, has missing fields or an unknown version
  static PairInvite? tryParse(String text) {
    try {
      final uri = Uri.parse(text.trim());
      if (uri.scheme != pairQrScheme || uri.host != 'pair') return null;
      final q = uri.queryParameters;
      if (q['v'] != '$pairProtocolVersion') return null;
      final fp = unb64u(q['f'] ?? '');
      final k = unb64u(q['k'] ?? '');
      if (fp.length != 32 || k.length != 16) return null;
      final addresses = <({String host, int port})>[];
      for (final part in (q['a'] ?? '').split(',')) {
        final i = part.lastIndexOf(':');
        if (i <= 0) continue;
        final host = part.substring(0, i);
        final port = int.tryParse(part.substring(i + 1));
        if (port == null || port <= 0 || port > 65535 || !RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) continue;
        addresses.add((host: host, port: port));
      }
      if (addresses.isEmpty || addresses.length > 6) return null;
      return PairInvite(fingerprint: toHex(fp), key: k, addresses: addresses);
    } catch (_) {
      return null;
    }
  }
}

/// Values both sides compute independently from the transcript
class PairSas {
  /// 12 digits in three groups: "4821 0937 5562". Shown only when the peer runs an older Shuttle that still asks people to
  /// compare them by eye.
  final String digits;

  /// Seed for the "pairing seal" drawn by [DeviceSeal] (the seal uses only 18 bits and just helps the eye; security comes from the
  /// digits and the one-time commitment)
  final String sealKey;

  const PairSas({required this.digits, required this.sealKey});

  /// PC-to-PC pairing: the host shows the first six digits and the guest the last six; each person types the code shown on the
  /// other computer (see [PairHost.checkCode] and [PairGuest.checkCode]). A side never shows the code it expects, so the check
  /// can't be passed by copying from the same screen.
  String get hostCode => _six(0);
  String get guestCode => _six(6);

  String _six(int from) {
    final d = digits.replaceAll(' ', '').substring(from, from + 6);
    return '${d.substring(0, 3)} ${d.substring(3)}';
  }

  /// Whether [typed] is [code] (spaces and other separators are ignored)
  static bool codeMatches(String typed, String code) => typed.replaceAll(RegExp(r'\D'), '') == code.replaceAll(' ', '');
}

/// Pairing key material; both sides use the same algorithm.
///
/// [nearby] = PC-to-PC pairing (no QR code). There is no one-time key K then; `k` is the session ID the PC sends to the peer over
/// the encrypted connection. Security rests entirely on commit-then-reveal plus people comparing the 12 digits on both sides (the
/// same idea as Bluetooth "Numeric Comparison"). The labels differ from QR pairing, so values from one mode can't be passed off as
/// the other's.
class PairKeys {
  PairKeys._();

  static Uint8List macKey(List<int> k, {bool nearby = false}) =>
      hkdf(ikm: k, info: utf8Of(nearby ? 'shuttle-pair-nearby-mac-v1' : 'shuttle-pair-mac-v1'), length: 32);

  /// Transcript hash T: the one-time key (or session ID), both fingerprints, both nonces
  static Uint8List transcript({
    required List<int> k,
    required String hostFingerprint,
    required String guestFingerprint,
    required List<int> hostNonce,
    required List<int> guestNonce,
    bool nearby = false,
  }) {
    return sha256Of([
      ...utf8Of(nearby ? 'shuttle-pair-nearby-v1' : 'shuttle-pair-v1'),
      ...k,
      ...fromHex(hostFingerprint),
      ...fromHex(guestFingerprint),
      ...hostNonce,
      ...guestNonce,
    ]);
  }

  static PairSas sas(List<int> transcript) {
    final s = hkdf(ikm: transcript, info: utf8Of('shuttle-sas-v1'), length: 16);
    var n = BigInt.zero;
    for (final b in s.sublist(0, 8)) {
      n = (n << 8) | BigInt.from(b);
    }
    final d = (n % BigInt.from(10).pow(12)).toString().padLeft(12, '0');
    return PairSas(digits: '${d.substring(0, 4)} ${d.substring(4, 8)} ${d.substring(8)}', sealKey: 'PAIR-${toHex(s.sublist(8))}');
  }

  /// Shared secret both sides store after pairing (meant for deriving the room ID for future cross-network connections)
  static Uint8List pairSecret({
    required List<int> k,
    required List<int> hostNonce,
    required List<int> guestNonce,
    required List<int> transcript,
    bool nearby = false,
  }) {
    return hkdf(
      ikm: [...k, ...hostNonce, ...guestNonce],
      salt: transcript,
      info: utf8Of(nearby ? 'shuttle-pair-nearby-secret-v1' : 'shuttle-pair-secret-v1'),
      length: 32,
    );
  }
}
