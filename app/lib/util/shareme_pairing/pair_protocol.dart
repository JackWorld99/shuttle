// Shuttle: message flow of pairing (same Wi-Fi).
// - QR pairing: the PC (host) temporarily opens an HTTPS endpoint with its own TLS certificate; the phone (guest) pins it by the
//   fingerprint in the QR code, so the handshake fails if the fingerprint doesn't match. Every phone message carries a MAC keyed by
//   the QR code's one-time key, so only a device that saw the code can pair. Both sides therefore confirm on their own once the
//   handshake checks out, without asking anyone to compare digits (the same trust model as linking a device by QR code in Signal or
//   WhatsApp). The code works once: a second device holding it is refused and the PC warns, and the PC's paired page offers to
//   remove a device that isn't yours.
// - The PC can't get the phone's certificate (dart:io's server doesn't accept unknown self-signed client certificates), so the
//   phone states its own fingerprint in hello. Claiming someone else's fingerprint is useless: every later transfer uses mutual TLS
//   on the Rust side, so a device without the matching private key can't connect; and a device sneaking in with its own fingerprint
//   changes the transcript hash, so the two sides' codes differ (the fingerprints are in the transcript hash).
// - PC-to-PC pairing: without a camera, the QR code's one-time key can't be passed. The other PC gets this one's address and
//   certificate fingerprint from "Nearby" and sends `nearby-hello` to the fixed port [pairNearbyPort]. There is no key, so that
//   hello carries no MAC and anyone can send it; the PC replies with a session ID over the encrypted connection, which keys the MACs
//   of later messages. Man-in-the-middle protection comes from commit-then-reveal plus each person typing the 6 digits shown on the
//   other computer (the host shows the first half of the 12-digit code, the guest the second half), the same idea as Bluetooth
//   "Numeric Comparison" but typed: people click a "Same" button out of habit, while a code can't be typed without looking (why
//   Microsoft Authenticator moved from approve/deny to number matching). A peer that can't do this ([pairCapTyped]) is refused, so
//   nobody can downgrade the check by posing as an older version.
// - A PC request on the "Add device" page must first be accepted by a person: before, anyone on the same Wi-Fi could take over the
//   pairing with a single `nearby-hello`, so a scanning phone only saw "already used", and QR pairing could be downgraded to relying
//   on comparing digits by eye alone. Now the request just waits ("X wants to pair with this computer: Ignore / Accept"), the QR
//   code can still be scanned meanwhile, and verification only starts after "Accept". When both sides clicked "Pair"
//   ([PairHost.onlyGuest]), the user already picked that PC, so there's no extra question. KDE Connect and Syncthing also use
//   "peer requests → this device accepts".
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:localsend_app/util/shareme_pairing/pair_crypto.dart';
import 'package:logging/logging.dart';

final _logger = Logger('Pairing');

const _base = '/shuttle/pair/v$pairProtocolVersion';
const _maxBody = 16 * 1024;
const _maxBadMacs = 30;

/// Maximum number of PC pairing requests from one address per pairing page (new commitments, rejections and "busy" replies all
/// count; polling for the result of the same request doesn't). A normal peer PC sends only one or two per page.
const _maxNearbyRequests = 10;

/// After "Accept", how long to wait for the peer to fetch the reply and start verifying. The peer polls every second; if it doesn't
/// come, assume it has left.
const _nearbyAcceptWait = Duration(seconds: 20);

/// What this version can do while pairing, exchanged in hello and reply (`caps`), so each side knows how the other confirms.
/// - [pairCapAutoQr]: confirms QR pairing on its own once the handshake checks out. Older versions ask their user to compare the 12
///   digits and tap "Same, pair", so the other side shows the digits for them.
/// - [pairCapTyped]: PC-to-PC pairing is confirmed by typing the code shown on the other computer. Required: a peer without it is
///   refused ([PairFailure.outdated]).
const pairCapAutoQr = 'auto-qr';
const pairCapTyped = 'typed';
const pairCaps = [pairCapAutoQr, pairCapTyped];

/// PC-to-PC pairing: wrong codes allowed before the pairing is cancelled. Retrying doesn't help an attacker: the code of a session
/// is fixed, so the retries only forgive typos.
const pairCodeTries = 3;

/// PC-to-PC pairing: time to type the codes on both computers (QR pairing uses [pairVerifyLifetime])
const pairTypedVerifyLifetime = Duration(minutes: 3);

enum PairCodeResult {
  /// The code matches; this side confirms
  match,

  /// Wrong code; tries are left
  wrong,

  /// Too many wrong codes; the pairing is cancelled on both sides ([PairFailure.codeMismatch])
  exhausted,
}

Set<String> _capsOf(Object? json) => {
  if (json is List)
    for (final c in json.take(16))
      if (c is String) c,
};

enum PairFailure {
  /// The QR code expired / the pairing page on the PC was closed
  expired,

  /// The user on this device chose "Different"
  rejectedHere,

  /// The peer chose "Different"
  rejectedByPeer,

  /// PC-to-PC pairing: the person at the peer's "Add device" page chose "Ignore"
  declined,

  /// The QR code was already used by another device
  used,

  /// The PC can't be reached
  unreachable,

  /// The PC's certificate fingerprint doesn't match the QR code (someone may be impersonating it)
  identity,

  /// Nobody confirmed the verification in time
  timeout,

  /// Bad message (version, format, MAC)
  protocol,

  /// PC-to-PC pairing: the other computer runs a Shuttle that can't confirm by typed code
  outdated,

  /// PC-to-PC pairing: the typed code was wrong [pairCodeTries] times (a typo, or a device pretending to be the other computer)
  codeMismatch,
}

class PairException implements Exception {
  final PairFailure failure;
  final String? detail;

  const PairException(this.failure, [this.detail]);

  @override
  String toString() => 'PairException($failure${detail == null ? '' : ': $detail'})';
}

/// What a device tells the peer about itself when pairing
class PairPeerInfo {
  /// TLS certificate fingerprint (uppercase hex)
  final String fingerprint;
  final String alias;
  final String? model;

  /// The [DeviceType]'s name
  final String type;

  /// Port of this device's LocalSend server and whether it uses HTTPS (needed to add it to "My devices" after pairing)
  final int port;
  final bool https;

  /// Addresses this device can be reached at (LAN + Tailscale). The peer stores them after pairing and tries them when not on the
  /// same Wi-Fi.
  final List<String> addresses;

  const PairPeerInfo({
    required this.fingerprint,
    required this.alias,
    required this.model,
    required this.type,
    required this.port,
    required this.https,
    this.addresses = const [],
  });

  Map<String, dynamic> toJson() => {
    'fp': b64u(fromHex(fingerprint)),
    'alias': alias,
    'model': model ?? '',
    'type': type,
    'port': port,
    'https': https,
    'addrs': addresses,
  };

  static PairPeerInfo fromJson(Object? json) {
    if (json is! Map) throw const PairException(PairFailure.protocol, 'peer');
    final fp = unb64u(json['fp'] as String);
    final alias = (json['alias'] as String).trim();
    final port = json['port'] as int;
    if (fp.length != 32 || alias.isEmpty || alias.length > 64 || port <= 0 || port > 65535) {
      throw const PairException(PairFailure.protocol, 'peer fields');
    }
    final model = (json['model'] as String?)?.trim();
    return PairPeerInfo(
      fingerprint: toHex(fp),
      alias: alias,
      model: model == null || model.isEmpty ? null : model,
      type: json['type'] as String,
      port: port,
      https: json['https'] as bool,
      addresses: [
        for (final a in (json['addrs'] as List<dynamic>? ?? const []).take(8))
          if (a is String && RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(a)) a,
      ],
    );
  }

  List<List<int>> macParts() => [
    fromHex(fingerprint),
    utf8Of(alias),
    utf8Of(model ?? ''),
    utf8Of(type),
    utf8Of('$port'),
    [if (https) 1 else 0],
    utf8Of(addresses.join(',')),
  ];
}

// ============================================================================================ PC side (host)

enum PairHostStage { starting, showingCode, verifying, paired, failed }

@immutable
class PairHostState {
  final PairHostStage stage;
  final String? qr;
  final DateTime? expiresAt;
  final PairPeerInfo? peer;
  final PairSas? sas;
  final bool hostConfirmed;
  final bool guestConfirmed;

  /// After the QR code was used, another device showed up with the correct key (the PC must warn as well)
  final bool intruder;
  final PairFailure? failure;

  /// The peer being verified is another PC that connected directly from "Nearby" (no QR code). Also true after "Accept" while the
  /// peer hasn't come back to start verifying yet.
  final bool nearby;

  /// A PC pairing request on the "Add device" page waiting for the user to choose "Accept" or "Ignore" (it doesn't hold the pairing
  /// yet; the QR code can still be scanned)
  final PairPeerInfo? request;

  /// QR pairing with a phone running an older Shuttle: it still asks its user to compare the 12 digits and tap "Same, pair", so
  /// the PC shows them too ([PairHostState.sas])
  final bool legacyPeer;

  const PairHostState({
    required this.stage,
    this.qr,
    this.expiresAt,
    this.peer,
    this.sas,
    this.hostConfirmed = false,
    this.guestConfirmed = false,
    this.intruder = false,
    this.failure,
    this.nearby = false,
    this.request,
    this.legacyPeer = false,
  });
}

typedef PairedCallback = Future<void> Function(PairPeerInfo peer, String peerIp, Uint8List pairSecret);

class _HostSession {
  final Uint8List key = randomBytes(16);

  /// MAC key derived from the QR code's key: QR hellos are always verified with it (also while another PC holds the pairing, so the
  /// phone gets "already used")
  late final Uint8List qrMacKey = PairKeys.macKey(key);

  /// MAC key for this pairing's later messages: QR pairing = [qrMacKey], PC-to-PC pairing = derived from the session ID
  late Uint8List macKey = qrMacKey;

  /// PC-to-PC pairing: there is no QR code, so the session ID sent to the peer replaces the one-time key
  bool nearby = false;
  Uint8List? sessionKey;

  List<int> get transcriptKey => nearby ? sessionKey! : key;
  final DateTime expiresAt = DateTime.now().add(pairCodeLifetime);
  String? sid;
  PairPeerInfo? guest;
  String? guestIp;
  Uint8List? commit;
  Uint8List? helloMac;
  Map<String, dynamic>? reply;
  Uint8List? hostNonce;
  Uint8List? transcript;
  Uint8List? secret;
  bool revealed = false;

  /// What the guest said it can do ([pairCaps])
  Set<String> guestCaps = const {};

  /// PC-to-PC pairing: wrong codes left before the pairing is cancelled
  int codeTriesLeft = pairCodeTries;

  bool get consumed => sid != null;
}

/// A PC pairing request waiting on the "Add device" page for the user to choose "Accept". The peer polls for the result every second
/// with the same commitment.
class _NearbyRequest {
  final PairPeerInfo guest;
  final String ip;
  final Uint8List commit;
  Timer? idle;

  _NearbyRequest(this.guest, this.ip, this.commit);
}

/// PC side: opens the pairing endpoint, shows the QR code and waits for the phone. One object per pairing page.
class PairHost {
  final PairPeerInfo self;
  final String certificatePem;
  final String privateKeyPem;

  /// LAN IPv4 addresses written into the QR code
  final List<String> ips;
  final PairedCallback onPaired;

  /// For tests: bind to the loopback address only
  final bool loopbackOnly;

  /// The pairing endpoint tries this port first (another PC coming from "Nearby" needs a fixed port) and falls back to a random port
  /// if it's taken. 0 in tests.
  final int preferredPort;

  /// Only accept this device connecting from "Nearby" (uppercase hex fingerprint). When both PCs clicked "Pair", the one with the
  /// smaller fingerprint temporarily acts as host and waits only for the PC it wants to pair with; anyone else is rejected. The user
  /// already picked that PC on this one, so there is no "Accept" step.
  /// null = "Add device" page: anyone can send a request, but verification only starts after the user chooses "Accept".
  final String? onlyGuest;

  /// How long a waiting PC pairing request lives without being polled before it's dropped (the peer closed its pairing page).
  /// KDE Connect's pairing requests last 30 seconds. Shorter in tests.
  final Duration nearbyRequestIdle;

  /// What this side tells the peer it can do; tests pass fewer to act as an older version
  final List<String> caps;

  final state = ValueNotifier(const PairHostState(stage: PairHostStage.starting));

  HttpServer? _server;
  _HostSession? _session;
  Timer? _timer;

  /// Number of bad MACs received per source IP.
  /// This used to be a global counter that voided the whole pairing past the limit and was reset by each new QR code, so anyone on
  /// the same Wi-Fi who found the port could keep pairing failing. Now only the IP with too many errors is refused, and the phone
  /// being paired isn't affected. The key has 128 bits, so the limit was never about guessing. A new QR code doesn't reset it.
  final _badMacsByIp = <String, int>{};

  /// Number of PC pairing requests per source IP. A new QR code doesn't reset it either.
  final _nearbyByIp = <String, int>{};

  /// Addresses that were ignored on this page: later PC pairing requests from them are refused (QR pairing is unaffected).
  /// Tracked by address, not by fingerprint: the fingerprint is self-reported, so someone could claim your other PC's fingerprint
  /// first and get you to "Ignore" it.
  final _ignoredIps = <String>{};

  _NearbyRequest? _request;
  Future<void>? _finalizing;

  PairHost({
    required this.self,
    required this.certificatePem,
    required this.privateKeyPem,
    required this.ips,
    required this.onPaired,
    this.loopbackOnly = false,
    this.preferredPort = pairNearbyPort,
    this.onlyGuest,
    this.nearbyRequestIdle = const Duration(seconds: 15),
    @visibleForTesting this.caps = pairCaps,
  });

  int? get port => _server?.port;

  /// Listening on the fixed port: another PC can pair directly from "Nearby"
  bool get acceptsNearby => _server != null && _server!.port == pairNearbyPort;

  Future<void> start() async {
    final ctx = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(certificatePem))
      ..usePrivateKeyBytes(utf8.encode(privateKeyPem));
    final address = loopbackOnly ? InternetAddress.loopbackIPv4 : InternetAddress.anyIPv4;
    try {
      _server = await HttpServer.bindSecure(address, preferredPort, ctx);
    } on SocketException catch (e) {
      _logger.info('pairing port $preferredPort is busy, using a random one (QR only)', e);
      _server = await HttpServer.bindSecure(address, 0, ctx);
    }
    _server!.listen((req) => unawaited(_handle(req)), onError: (Object e) => _logger.warning('pair server', e));
    renew();
  }

  /// Switches to a new QR code (new one-time key). The previous one becomes invalid.
  void renew() {
    final server = _server;
    if (server == null) return;
    _timer?.cancel();
    _finalizing = null;
    _dropRequest(notify: false); // the whole state is replaced below; when the peer polls again it is queued as a new request
    final s = _session = _HostSession();
    final invite = PairInvite(
      fingerprint: self.fingerprint,
      key: s.key,
      addresses: [for (final ip in ips) (host: ip, port: server.port)],
    );
    _timer = Timer(pairCodeLifetime, () => _fail(PairFailure.expired));
    _set(PairHostState(stage: PairHostStage.showingCode, qr: invite.encode(), expiresAt: s.expiresAt));
  }

  /// This side's confirmation. QR pairing confirms on its own at reveal; PC-to-PC pairing only after [checkCode] matched.
  Future<void> _confirmHost() async {
    final st = state.value;
    if (st.stage != PairHostStage.verifying || st.hostConfirmed) return;
    _set(_copy(hostConfirmed: true));
    if (state.value.guestConfirmed) await _finalize();
  }

  /// PC-to-PC pairing: the code the person typed here, read from the other computer's screen (its half: [PairSas.guestCode]).
  /// A match confirms this side; after [pairCodeTries] wrong codes the pairing is cancelled on both sides.
  PairCodeResult checkCode(String typed) {
    final st = state.value;
    final s = _session;
    if (st.stage != PairHostStage.verifying || !st.nearby || s == null || st.sas == null) return PairCodeResult.exhausted;
    if (st.hostConfirmed) return PairCodeResult.match;
    if (PairSas.codeMatches(typed, st.sas!.guestCode)) {
      unawaited(_confirmHost());
      return PairCodeResult.match;
    }
    if (--s.codeTriesLeft > 0) return PairCodeResult.wrong;
    _fail(PairFailure.codeMismatch);
    return PairCodeResult.exhausted;
  }

  /// The pairing is cancelled on the PC ("Cancel" while checking)
  void reject() {
    if (state.value.stage == PairHostStage.verifying) _fail(PairFailure.rejectedHere);
  }

  /// "Accept" was chosen on "X wants to pair with this computer": the pairing now belongs to X (the QR code becomes invalid); X gets
  /// the reply on its next poll and verification starts
  void acceptNearby() {
    final r = _request;
    final s = _session;
    if (r == null || s == null || s.consumed || state.value.stage != PairHostStage.showingCode) return;
    _dropRequest(notify: false);
    _startNearby(s, r.guest, r.ip, r.commit);
    // If the peer closed its page and stops polling, don't let this pairing hang forever
    _timer?.cancel();
    _timer = Timer(_nearbyAcceptWait, () {
      if (_session == s && !s.revealed) _fail(PairFailure.timeout);
    });
  }

  /// "Ignore" was chosen on "X wants to pair with this computer": drops the request; this page no longer takes PC pairing requests
  /// from that address
  void ignoreNearby() {
    final r = _request;
    if (r == null) return;
    _ignoredIps.add(r.ip);
    _dropRequest();
  }

  Future<void> close() async {
    _timer?.cancel();
    _dropRequest(notify: false);
    _session = null;
    await _server?.close(force: true);
    _server = null;
  }

  void _set(PairHostState s) => state.value = s;

  PairHostState _copy({
    PairHostStage? stage,
    PairPeerInfo? peer,
    PairSas? sas,
    bool? hostConfirmed,
    bool? guestConfirmed,
    bool? intruder,
    PairFailure? failure,
    bool? nearby,
    PairPeerInfo? request,
    bool clearRequest = false,
    bool? legacyPeer,
  }) {
    final o = state.value;
    return PairHostState(
      stage: stage ?? o.stage,
      qr: o.qr,
      expiresAt: o.expiresAt,
      peer: peer ?? o.peer,
      sas: sas ?? o.sas,
      hostConfirmed: hostConfirmed ?? o.hostConfirmed,
      guestConfirmed: guestConfirmed ?? o.guestConfirmed,
      intruder: intruder ?? o.intruder,
      failure: failure ?? o.failure,
      nearby: nearby ?? o.nearby,
      request: clearRequest ? null : request ?? o.request,
      legacyPeer: legacyPeer ?? o.legacyPeer,
    );
  }

  void _fail(PairFailure f) {
    final stage = state.value.stage;
    if (stage == PairHostStage.paired || stage == PairHostStage.failed) return;
    _timer?.cancel();
    _dropRequest(notify: false);
    _set(_copy(stage: PairHostStage.failed, failure: f, clearRequest: true));
  }

  /// Drops the waiting PC pairing request (on the peer's next poll: "busy" if someone else took this pairing, otherwise a new request)
  void _dropRequest({bool notify = true}) {
    _request?.idle?.cancel();
    _request = null;
    if (notify && state.value.request != null) _set(_copy(clearRequest: true));
  }

  Future<void> _finalize() {
    return _finalizing ??= () async {
      final s = _session!;
      _timer?.cancel();
      await onPaired(s.guest!, s.guestIp!, s.secret!);
      _set(_copy(stage: PairHostStage.paired));
    }();
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      if (req.method == 'GET' && path == '$_base/ping') {
        return await _send(res, 200, {'v': pairProtocolVersion});
      }
      if (req.method != 'POST' || !path.startsWith('$_base/')) {
        return await _send(res, 404, {'error': 'not found'});
      }
      final ip = req.connectionInfo?.remoteAddress.address ?? '';
      if ((_badMacsByIp[ip] ?? 0) > _maxBadMacs || (_nearbyByIp[ip] ?? 0) > _maxNearbyRequests) {
        return await _send(res, 429, {'error': 'too many'});
      }
      final body = await _readJson(req);
      final s = _session;
      if (s == null) return await _send(res, 410, {'error': 'expired'});
      switch (path.substring(_base.length + 1)) {
        case 'hello':
          return await _hello(req, res, s, body, ip);
        case 'nearby-hello':
          return await _nearbyHello(res, s, body, ip);
        case 'reveal':
          return await _reveal(res, s, body, ip);
        case 'confirm':
          return await _confirmFromGuest(res, s, body, ip);
        case 'status':
          if (!_checkMac(s, body, 'status', [utf8Of(s.sid ?? '')], ip)) return await _send(res, 403, {'error': 'mac'});
          return await _send(res, 200, _status(s));
        case 'reject':
          if (!_checkMac(s, body, 'reject', [utf8Of(s.sid ?? '')], ip)) return await _send(res, 403, {'error': 'mac'});
          _fail(PairFailure.rejectedByPeer);
          return await _send(res, 200, {'ok': true});
        default:
          return await _send(res, 404, {'error': 'not found'});
      }
    } catch (e) {
      _logger.info('bad pairing request', e);
      try {
        await _send(res, 400, {'error': 'bad request'});
      } catch (_) {}
    }
  }

  Future<void> _hello(HttpRequest req, HttpResponse res, _HostSession s, Map<String, dynamic> body, String ip) async {
    if (DateTime.now().isAfter(s.expiresAt) || state.value.stage == PairHostStage.failed) {
      return _send(res, 410, {'error': 'expired'});
    }
    final guest = PairPeerInfo.fromJson(body['peer']);
    final commit = unb64u(body['commit'] as String);
    if (commit.length != 32) throw const PairException(PairFailure.protocol, 'commit');
    final expected = pairMac(s.qrMacKey, 'hello', [...guest.macParts(), commit]);
    if (!constantTimeEquals(expected, unb64u(body['mac'] as String))) {
      // Someone who hasn't seen the QR code: void neither the key nor the pairing (so a stranger can't break pairing just by
      // connecting); only count it against that IP
      _countBadMac(ip);
      return _send(res, 403, {'error': 'mac'});
    }
    if (s.consumed) {
      if (!s.nearby && s.guest!.fingerprint == guest.fingerprint && constantTimeEquals(s.commit!, commit)) {
        return _send(res, 200, s.reply!); // the same phone retrying
      }
      // Someone came late with the correct QR code: the phone shows "already used" and the PC warns as well.
      // Also warn when the peer being verified is another PC (the UI uses different wording then).
      _set(_copy(intruder: true));
      return _send(res, 409, {'error': 'used'});
    }
    // A scanning phone takes priority: drop the waiting PC pairing request; that PC gets "busy" on its next poll
    _dropRequest(notify: false);
    s
      ..sid = b64u(randomBytes(16))
      ..guest = guest
      ..guestIp = req.connectionInfo?.remoteAddress.address
      ..commit = commit
      ..helloMac = expected
      ..hostNonce = randomBytes(32)
      ..guestCaps = _capsOf(body['caps']);
    s.reply = {
      'sid': s.sid,
      'peer': self.toJson(),
      'nonce': b64u(s.hostNonce!),
      'mac': b64u(pairMac(s.macKey, 'reply', [utf8Of(s.sid!), ...self.macParts(), s.hostNonce!, expected])),
      'caps': caps,
    };
    _set(_copy(clearRequest: true));
    return _send(res, 200, s.reply!);
  }

  /// PC-to-PC pairing: another PC connects directly from "Nearby" without a QR code, so this hello carries no MAC and anyone can send it.
  /// - "Add device" page ([onlyGuest] is null): the request waits, answered with 202, until the user chooses "Accept"; the peer polls
  ///   every second with the same commitment. A waiting request doesn't hold the pairing, so a scanning phone still works (the request
  ///   is dropped as soon as a phone arrives). Only one request waits at a time; others get 409.
  /// - Both sides clicked "Pair" ([onlyGuest] is the peer): the user already picked that PC, so verification starts right away;
  ///   anyone else gets 403.
  /// Only one peer is verified at a time (a scanning phone included), and nothing is saved until people on both sides choose
  /// "Same, pair". The session ID is sent to the peer only over this encrypted connection and keys the MACs of later messages, so
  /// bystanders on the same Wi-Fi can't cut in.
  Future<void> _nearbyHello(HttpResponse res, _HostSession s, Map<String, dynamic> body, String ip) async {
    if (DateTime.now().isAfter(s.expiresAt) || state.value.stage == PairHostStage.failed) {
      return _send(res, 410, {'error': 'expired'});
    }
    if (_ignoredIps.contains(ip)) return _send(res, 403, {'error': 'declined'});
    final guest = PairPeerInfo.fromJson(body['peer']);
    final commit = unb64u(body['commit'] as String);
    if (commit.length != 32) throw const PairException(PairFailure.protocol, 'commit');
    if (!_capsOf(body['caps']).contains(pairCapTyped)) {
      // An older Shuttle would confirm with a one-click "Same, pair". Refusing it also keeps a man in the middle from posing as one.
      _countNearby(ip);
      return _send(res, 426, {'error': 'outdated'});
    }
    if (s.consumed) {
      if (s.nearby && s.guest!.fingerprint == guest.fingerprint && s.guestIp == ip && constantTimeEquals(s.commit!, commit)) {
        return _send(res, 200, s.reply!); // the same PC retrying, or fetching the reply after "Accept" was chosen here
      }
      _countNearby(ip);
      return _send(res, 409, {'error': 'used'});
    }
    if (onlyGuest != null) {
      _countNearby(ip);
      if (guest.fingerprint != onlyGuest) return _send(res, 403, {'error': 'not expected'});
      _startNearby(s, guest, ip, commit);
      return _send(res, 200, s.reply!);
    }
    final pending = _request;
    if (pending != null && pending.ip == ip && pending.guest.fingerprint == guest.fingerprint) {
      if (constantTimeEquals(pending.commit, commit)) {
        _touch(pending); // the same request polling for the result
        return _send(res, 202, {'state': 'waiting'});
      }
      // The same PC started over (e.g. "Try again" on its side): switch to the new commitment. No nonce was sent yet, so this is safe.
    } else if (pending != null) {
      _countNearby(ip);
      return _send(res, 409, {'error': 'used'}); // only one waiting request at a time
    }
    _countNearby(ip);
    _dropRequest(notify: false);
    final r = _request = _NearbyRequest(guest, ip, commit);
    _touch(r);
    _set(_copy(request: guest));
    return _send(res, 202, {'state': 'waiting'});
  }

  /// Drops the waiting request if nobody polls for it for a while
  void _touch(_NearbyRequest r) {
    r.idle?.cancel();
    r.idle = Timer(nearbyRequestIdle, () {
      if (_request == r) _dropRequest();
    });
  }

  void _countNearby(String ip) => _nearbyByIp.update(ip, (n) => n + 1, ifAbsent: () => 1);

  /// The pairing now belongs to this PC: issues a session ID and a nonce (the reply is stored and returned as is whenever the peer polls)
  void _startNearby(_HostSession s, PairPeerInfo guest, String ip, Uint8List commit) {
    final sessionKey = randomBytes(16);
    s
      ..sid = b64u(sessionKey)
      ..nearby = true
      ..sessionKey = sessionKey
      ..macKey = PairKeys.macKey(sessionKey, nearby: true)
      ..guest = guest
      ..guestIp = ip
      ..commit = commit
      ..hostNonce = randomBytes(32);
    s.helloMac = pairMac(s.macKey, 'hello', [...guest.macParts(), commit]);
    s.guestCaps = const {pairCapTyped}; // checked in _nearbyHello before any request gets this far
    s.reply = {
      'sid': s.sid,
      'peer': self.toJson(),
      'nonce': b64u(s.hostNonce!),
      'mac': b64u(pairMac(s.macKey, 'reply', [utf8Of(s.sid!), ...self.macParts(), s.hostNonce!, s.helloMac!])),
      'caps': caps,
    };
    _set(_copy(nearby: true, peer: guest, clearRequest: true));
  }

  Future<void> _reveal(HttpResponse res, _HostSession s, Map<String, dynamic> body, String ip) async {
    // A pairing that has already failed (expired, rejected, ...) can't be revived
    if (state.value.stage == PairHostStage.failed) return _send(res, 410, {'error': 'expired'});
    if (!s.consumed || s.revealed) return _send(res, 409, {'error': 'state'});
    final nonce = unb64u(body['nonce'] as String);
    if (!_checkMac(s, body, 'reveal', [utf8Of(s.sid!), nonce], ip)) return _send(res, 403, {'error': 'mac'});
    if (nonce.length != 32 || !constantTimeEquals(sha256Of(nonce), s.commit!)) {
      _fail(PairFailure.protocol);
      return _send(res, 409, {'error': 'commit'});
    }
    final t = PairKeys.transcript(
      k: s.transcriptKey,
      hostFingerprint: self.fingerprint,
      guestFingerprint: s.guest!.fingerprint,
      hostNonce: s.hostNonce!,
      guestNonce: nonce,
      nearby: s.nearby,
    );
    s
      ..revealed = true
      ..transcript = t
      ..secret = PairKeys.pairSecret(k: s.transcriptKey, hostNonce: s.hostNonce!, guestNonce: nonce, transcript: t, nearby: s.nearby);
    _timer?.cancel();
    _timer = Timer(s.nearby ? pairTypedVerifyLifetime : pairVerifyLifetime, () => _fail(PairFailure.timeout));
    _set(
      _copy(
        stage: PairHostStage.verifying,
        peer: s.guest,
        sas: PairKeys.sas(t),
        // QR pairing: the phone proved it saw the code (MAC with its one-time key) and talks to this pinned certificate, so the PC
        // confirms on its own. PC-to-PC pairing waits for the typed code (checkCode).
        hostConfirmed: !s.nearby,
        legacyPeer: !s.nearby && !s.guestCaps.contains(pairCapAutoQr),
      ),
    );
    return _send(res, 200, {'ok': true});
  }

  Future<void> _confirmFromGuest(HttpResponse res, _HostSession s, Map<String, dynamic> body, String ip) async {
    if (!s.revealed) return _send(res, 409, {'error': 'state'});
    if (!_checkMac(s, body, 'confirm-guest', [utf8Of(s.sid!), s.transcript!], ip)) return _send(res, 403, {'error': 'mac'});
    if (state.value.stage == PairHostStage.verifying && !state.value.guestConfirmed) {
      _set(_copy(guestConfirmed: true));
      if (state.value.hostConfirmed) await _finalize();
    }
    return _send(res, 200, _status(s));
  }

  Map<String, dynamic> _status(_HostSession s) {
    final st = state.value;
    switch (st.stage) {
      case PairHostStage.paired:
        return {
          'state': 'paired',
          'mac': b64u(pairMac(s.macKey, 'confirm-host', [utf8Of(s.sid!), s.transcript!])),
        };
      case PairHostStage.failed:
        return {'state': st.failure == PairFailure.expired || st.failure == PairFailure.timeout ? 'expired' : 'rejected'};
      default:
        return {'state': 'waiting'};
    }
  }

  bool _checkMac(_HostSession s, Map<String, dynamic> body, String label, List<List<int>> parts, String ip) {
    if (!s.consumed || body['sid'] != s.sid) return false;
    final ok = constantTimeEquals(pairMac(s.macKey, label, parts), unb64u(body['mac'] as String));
    if (!ok) _countBadMac(ip);
    return ok;
  }

  void _countBadMac(String ip) => _badMacsByIp.update(ip, (n) => n + 1, ifAbsent: () => 1);

  static Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in req) {
      bytes.add(chunk);
      if (bytes.length > _maxBody) throw const PairException(PairFailure.protocol, 'too big');
    }
    return jsonDecode(utf8.decode(bytes.toBytes())) as Map<String, dynamic>;
  }

  static Future<void> _send(HttpResponse res, int status, Map<String, dynamic> body) async {
    res
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await res.close();
  }
}

// ============================================================================================ Phone side (guest)

class PairGuestSession {
  /// The QR code for QR pairing; null for PC-to-PC pairing
  final PairInvite? invite;

  /// The peer's pinned certificate fingerprint (from the QR code, or as seen in "Nearby")
  final String pin;
  final ({String host, int port}) address;
  final String sid;

  /// What the PC reported about itself (its fingerprint already checked against the QR code)
  final PairPeerInfo peer;
  final PairSas sas;
  final Uint8List transcript;
  final Uint8List secret;
  final Uint8List macKey;

  /// PC-to-PC pairing (no QR code): confirmed by typing the code shown on the other computer ([PairGuest.checkCode])
  final bool nearby;

  /// What the host said it can do ([pairCaps])
  final Set<String> hostCaps;

  /// PC-to-PC pairing: wrong codes left, and whether the typed code matched
  int codeTriesLeft = pairCodeTries;
  bool codeChecked = false;

  PairGuestSession({
    required this.invite,
    required this.pin,
    required this.address,
    required this.sid,
    required this.peer,
    required this.sas,
    required this.transcript,
    required this.secret,
    required this.macKey,
    this.nearby = false,
    this.hostCaps = const {},
  });

  /// QR pairing: the PC confirms on its own. False for an older PC, which still asks its user to compare the 12 digits.
  bool get hostAutoQr => hostCaps.contains(pairCapAutoQr);
}

/// Phone side: connects to the PC from the QR code, exchanges nonces, and confirms after verification.
class PairGuest {
  final PairPeerInfo self;

  /// Interval between polls (shorter in tests)
  final Duration pollInterval;

  /// What this side tells the host it can do; tests pass fewer to act as an older version
  final List<String> caps;

  const PairGuest({required this.self, this.pollInterval = const Duration(seconds: 1), @visibleForTesting this.caps = pairCaps});

  /// Connects and exchanges messages until the pairing seal can be shown
  Future<PairGuestSession> connect(PairInvite invite) async {
    final address = await _firstReachable(invite);
    final pin = invite.fingerprint;
    final macKey = PairKeys.macKey(invite.key);
    final nonce = randomBytes(32);
    final commit = sha256Of(nonce);
    final helloMac = pairMac(macKey, 'hello', [...self.macParts(), commit]);
    final hello = await _post(pin, address, 'hello', {
      'peer': self.toJson(),
      'commit': b64u(commit),
      'mac': b64u(helloMac),
      'caps': caps,
    });
    _checkHelloStatus(hello);
    return _finishHandshake(
      invite: invite,
      pin: pin,
      address: address,
      hello: hello.body,
      macKey: macKey,
      helloMac: helloMac,
      k: invite.key,
      nonce: nonce,
      nearby: false,
    );
  }

  /// PC-to-PC pairing: connects directly to the fixed port of the peer's "Add device" page, using the address and certificate
  /// fingerprint seen in "Nearby" (no QR code). Throws [PairFailure.unreachable] if the peer's page isn't open (the UI retries every
  /// few seconds) and [PairFailure.used] if the peer is verifying another device. While the peer shows its "Add device" page, the
  /// person there must choose "Accept": [onWaitingForAccept] is called once, then the same commitment is sent again every
  /// [pollInterval] until accepted (verification continues), ignored ([PairFailure.declined]) or [cancelled] returns true (page closed).
  Future<PairGuestSession> connectNearby({
    required String host,
    int port = pairNearbyPort,
    required String fingerprint,
    VoidCallback? onWaitingForAccept,
    bool Function()? cancelled,
  }) async {
    final address = (host: host, port: port);
    final nonce = randomBytes(32);
    final commit = sha256Of(nonce);
    final request = {'peer': self.toJson(), 'commit': b64u(commit), 'caps': caps};
    final deadline = DateTime.now().add(pairCodeLifetime);
    var hello = await _post(fingerprint, address, 'nearby-hello', request);
    var told = false;
    while (hello.status == 202) {
      if (!told) {
        told = true;
        onWaitingForAccept?.call();
      }
      if (DateTime.now().isAfter(deadline)) throw const PairException(PairFailure.timeout);
      await Future<void>.delayed(pollInterval);
      if (cancelled?.call() ?? false) throw const PairException(PairFailure.rejectedHere, 'cancelled');
      hello = await _post(fingerprint, address, 'nearby-hello', request);
    }
    _checkHelloStatus(hello);
    final sessionKey = unb64u(hello.body['sid'] as String);
    if (sessionKey.length != 16) throw const PairException(PairFailure.protocol, 'sid');
    final macKey = PairKeys.macKey(sessionKey, nearby: true);
    return _finishHandshake(
      invite: null,
      pin: fingerprint,
      address: address,
      hello: hello.body,
      macKey: macKey,
      helloMac: pairMac(macKey, 'hello', [...self.macParts(), commit]),
      k: sessionKey,
      nonce: nonce,
      nearby: true,
    );
  }

  static void _checkHelloStatus(({int status, Map<String, dynamic> body}) r) {
    switch (r.status) {
      case 200:
        return;
      case 403 when r.body['error'] == 'declined':
        throw const PairException(PairFailure.declined);
      case 409:
        throw const PairException(PairFailure.used);
      case 410:
        throw const PairException(PairFailure.expired);
      case 426:
        throw const PairException(PairFailure.outdated);
      default:
        throw PairException(PairFailure.protocol, 'hello ${r.status}');
    }
  }

  /// After hello both pairing modes are the same: check the PC's reply → reveal our nonce → compute the pairing seal
  Future<PairGuestSession> _finishHandshake({
    required PairInvite? invite,
    required String pin,
    required ({String host, int port}) address,
    required Map<String, dynamic> hello,
    required Uint8List macKey,
    required Uint8List helloMac,
    required List<int> k,
    required Uint8List nonce,
    required bool nearby,
  }) async {
    final sid = hello['sid'] as String;
    final peer = PairPeerInfo.fromJson(hello['peer']);
    final hostNonce = unb64u(hello['nonce'] as String);
    final replyMac = pairMac(macKey, 'reply', [utf8Of(sid), ...peer.macParts(), hostNonce, helloMac]);
    if (peer.fingerprint != pin || hostNonce.length != 32 || !constantTimeEquals(replyMac, unb64u(hello['mac'] as String))) {
      throw const PairException(PairFailure.protocol, 'reply');
    }
    final hostCaps = _capsOf(hello['caps']);
    if (nearby && !hostCaps.contains(pairCapTyped)) {
      // An older Shuttle would confirm with a one-click "Same, pair"; stop before revealing (its page times out on its own)
      throw const PairException(PairFailure.outdated);
    }
    final reveal = await _post(pin, address, 'reveal', {
      'sid': sid,
      'nonce': b64u(nonce),
      'mac': b64u(pairMac(macKey, 'reveal', [utf8Of(sid), nonce])),
    });
    if (reveal.status == 410) throw const PairException(PairFailure.expired);
    if (reveal.status != 200) throw PairException(PairFailure.protocol, 'reveal ${reveal.status}');
    final t = PairKeys.transcript(
      k: k,
      hostFingerprint: pin,
      guestFingerprint: self.fingerprint,
      hostNonce: hostNonce,
      guestNonce: nonce,
      nearby: nearby,
    );
    return PairGuestSession(
      invite: invite,
      pin: pin,
      address: address,
      sid: sid,
      peer: peer,
      sas: PairKeys.sas(t),
      transcript: t,
      secret: PairKeys.pairSecret(k: k, hostNonce: hostNonce, guestNonce: nonce, transcript: t, nearby: nearby),
      macKey: macKey,
      nearby: nearby,
      hostCaps: hostCaps,
    );
  }

  /// PC-to-PC pairing: the code the person typed here, read from the other computer's screen (its half: [PairSas.hostCode]).
  /// On a match, [confirm] may be called. After [pairCodeTries] wrong codes the pairing is cancelled, and the other computer is told.
  Future<PairCodeResult> checkCode(PairGuestSession s, String typed) async {
    if (!s.nearby || s.codeTriesLeft <= 0) return PairCodeResult.exhausted;
    if (s.codeChecked || PairSas.codeMatches(typed, s.sas.hostCode)) {
      s.codeChecked = true;
      return PairCodeResult.match;
    }
    if (--s.codeTriesLeft > 0) return PairCodeResult.wrong;
    await reject(s);
    return PairCodeResult.exhausted;
  }

  /// Confirms this side and waits until the host confirms too. On return both sides have confirmed and the pairing can be saved.
  /// QR pairing calls it right after [connect]; PC-to-PC pairing only after [checkCode] matched. [onWaiting] is called once if the
  /// host hasn't confirmed yet (the UI shows "Waiting for the computer").
  Future<void> confirm(PairGuestSession s, {VoidCallback? onWaiting}) async {
    if (s.nearby && !s.codeChecked) throw const PairException(PairFailure.protocol, 'code not checked');
    final deadline = DateTime.now().add(s.nearby ? pairTypedVerifyLifetime : pairVerifyLifetime);
    var r = await _post(s.pin, s.address, 'confirm', {
      'sid': s.sid,
      'mac': b64u(pairMac(s.macKey, 'confirm-guest', [utf8Of(s.sid), s.transcript])),
    });
    var told = false;
    while (true) {
      if (r.status == 410) throw const PairException(PairFailure.expired);
      if (r.status != 200) throw PairException(PairFailure.protocol, 'confirm ${r.status}');
      switch (r.body['state']) {
        case 'paired':
          final expected = pairMac(s.macKey, 'confirm-host', [utf8Of(s.sid), s.transcript]);
          if (!constantTimeEquals(expected, unb64u(r.body['mac'] as String))) {
            throw const PairException(PairFailure.protocol, 'host confirm mac');
          }
          return;
        case 'rejected':
          throw const PairException(PairFailure.rejectedByPeer);
        case 'expired':
          throw const PairException(PairFailure.timeout);
      }
      if (!told) {
        told = true;
        onWaiting?.call();
      }
      if (DateTime.now().isAfter(deadline)) throw const PairException(PairFailure.timeout);
      await Future<void>.delayed(pollInterval);
      r = await _post(s.pin, s.address, 'status', {
        'sid': s.sid,
        'mac': b64u(pairMac(s.macKey, 'status', [utf8Of(s.sid)])),
      });
    }
  }

  /// Cancels the pairing ("Cancel", or too many wrong codes): tries to tell the host; if that fails it doesn't matter (the host
  /// side times out)
  Future<void> reject(PairGuestSession s) async {
    try {
      await _post(s.pin, s.address, 'reject', {
        'sid': s.sid,
        'mac': b64u(pairMac(s.macKey, 'reject', [utf8Of(s.sid)])),
      });
    } catch (e) {
      _logger.info('reject not delivered', e);
    }
  }

  /// Tries all addresses from the QR code in parallel and uses the first one that connects with a matching certificate fingerprint
  Future<({String host, int port})> _firstReachable(PairInvite invite) async {
    final done = Completer<({String host, int port})>();
    var pending = invite.addresses.length;
    var identityProblem = false;
    for (final a in invite.addresses) {
      unawaited(() async {
        final client = _client(invite.fingerprint);
        try {
          final req = await client.getUrl(Uri.parse('https://${a.host}:${a.port}$_base/ping')).timeout(const Duration(seconds: 5));
          final res = await req.close().timeout(const Duration(seconds: 5));
          await res.drain<void>();
          if (res.statusCode == 200 && !done.isCompleted) done.complete(a);
        } on HandshakeException {
          identityProblem = true;
        } catch (_) {
          // This address can't be reached; the others may still work
        } finally {
          client.close(force: true);
          if (--pending == 0 && !done.isCompleted) {
            done.completeError(PairException(identityProblem ? PairFailure.identity : PairFailure.unreachable));
          }
        }
      }());
    }
    return done.future;
  }

  HttpClient _client(String pin, [void Function(String fingerprint)? presented]) {
    return HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = const Duration(seconds: 5)
      ..badCertificateCallback = (cert, host, port) {
        final fp = toHex(sha256Of(cert.der));
        presented?.call(fp);
        return fp == pin;
      };
  }

  Future<({int status, Map<String, dynamic> body})> _post(
    String pin,
    ({String host, int port}) a,
    String path,
    Map<String, dynamic> body,
  ) async {
    String? presented;
    final client = _client(pin, (fp) => presented = fp);
    try {
      final req = await client.postUrl(Uri.parse('https://${a.host}:${a.port}$_base/$path')).timeout(const Duration(seconds: 8));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close().timeout(const Duration(seconds: 8));
      final text = await res.transform(utf8.decoder).join();
      final decoded = text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>;
      return (status: res.statusCode, body: decoded);
    } on HandshakeException {
      // The other side presented my own certificate: I connected back to myself (when both sides clicked "Pair" I also listen on
      // 53319, and the peer's address points to this machine, e.g. two Shuttles on the same PC). Not impersonation; treat it as the
      // peer not being ready yet, and the UI keeps waiting.
      // No connection is established either way; someone else presenting my certificate only amounts to "no answer".
      if (presented == self.fingerprint) throw const PairException(PairFailure.unreachable, 'reached myself');
      throw const PairException(PairFailure.identity);
    } on PairException {
      rethrow;
    } catch (e) {
      throw PairException(PairFailure.unreachable, '$e');
    } finally {
      client.close(force: true);
    }
  }
}
