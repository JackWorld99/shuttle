import 'package:localsend_app/util/shareme_pairing/pair_crypto.dart' show pairProtocolVersion;

/// Verification method: QR pairing (the phone scans the PC's QR code)
const pairMethodQr = 'qr+sas';

/// Verification method: PC-to-PC pairing from "Nearby" (no QR code; connects by the fingerprint seen in Nearby).
/// Older nearby pairings were recorded as "qr+sas" too. Informational only; no code branches on it.
const pairMethodNearby = 'nearby+sas';

/// Shuttle: a device verified by pairing (both sides keep a copy). "My devices" are still LocalSend's favorites; this only
/// adds the "verified" status and the shared secret agreed during pairing (meant for cross-network use).
class PairedRecord {
  /// The peer's TLS certificate fingerprint (uppercase hex)
  final String fingerprint;

  /// 32-byte shared secret, base64url
  final String secret;
  final int pairedAt;

  /// Verification method: [pairMethodQr] or [pairMethodNearby]
  final String method;
  final int version;

  /// Addresses the peer reported when pairing (LAN + Tailscale). Scans try these in addition to the IP stored in "my devices".
  final List<String> addresses;

  const PairedRecord({
    required this.fingerprint,
    required this.secret,
    required this.pairedAt,
    this.addresses = const [],
    this.method = pairMethodQr,
    this.version = pairProtocolVersion,
  });

  Map<String, dynamic> toJson() => {
    'fingerprint': fingerprint,
    'secret': secret,
    'pairedAt': pairedAt,
    'method': method,
    'version': version,
    'addresses': addresses,
  };

  static PairedRecord fromJson(Map<String, dynamic> j) => PairedRecord(
    fingerprint: j['fingerprint'] as String,
    secret: j['secret'] as String,
    pairedAt: j['pairedAt'] as int,
    method: j['method'] as String? ?? pairMethodQr,
    version: j['version'] as int? ?? 1,
    addresses: [for (final a in j['addresses'] as List<dynamic>? ?? const []) a as String],
  );
}
