import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/persistence/paired_record.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/paired_devices_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/shareme_pairing/pair_crypto.dart';
import 'package:localsend_app/util/shareme_pairing/pair_protocol.dart';
import 'package:localsend_app/widget/shareme/pair_widgets.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';

final _logger = Logger('PairNearby');

enum _Stage { connecting, verifying, done, failed }

/// PC-to-PC pairing: opened by clicking "Pair" next to another PC under "Nearby" on the home page.
///
/// Either of two cases connects, in any order:
/// - The other PC has its "Add device" page open (waiting on the fixed port [pairNearbyPort]): connect to it; while it isn't
///   open, retry every 2 s for up to 5 minutes. Once connected, it shows "X wants to pair with this computer" and verification
///   only starts after someone there clicks "Accept"; this page tells the user to go and click it.
/// - The other PC also clicked "Pair" (otherwise both would just wait for each other): the certificate fingerprints decide
///   the roles. The PC with the smaller fingerprint also waits on the fixed port, accepting only the PC it wants to pair
///   with; the larger one connects as usual. The two PCs always get opposite results, so one waits and the other connects.
/// Checking: each computer shows 6 digits and asks for the 6 digits shown on the other one ([TypedCodePanel]); only when both
/// codes were typed correctly do they add each other to "My devices". A peer with an older Shuttle is refused
/// ([PairFailure.outdated]).
/// A peer that isn't Shuttle (e.g. the official LocalSend) can never connect, so there is an "add without checking" fallback.
class SmPairNearbyPage extends StatefulWidget {
  final Device device;

  const SmPairNearbyPage({required this.device, super.key});

  @override
  State<SmPairNearbyPage> createState() => _SmPairNearbyPageState();
}

class _SmPairNearbyPageState extends State<SmPairNearbyPage> with Refena {
  final _name = TextEditingController();
  _Stage _stage = _Stage.connecting;
  PairFailure? _failure;

  /// The session where this PC connects out (the peer is the host)
  PairGuestSession? _session;

  /// This PC waiting on the fixed port for the peer to connect in (both clicked "Pair" and this PC's fingerprint is smaller)
  PairHost? _host;

  /// The session being verified is the one where the peer connected in
  bool _asHost = false;

  /// An attempt failed to connect: most likely the other PC hasn't clicked "Pair" or opened "Add device", so ask the user to do it
  bool _otherPageMissing = false;

  /// The other PC has "Add device" open and the request was sent; waiting for someone there to click "Accept"
  bool _waitingAccept = false;

  /// Incremented on each connection start; when the page closes, restarts, or the peer connects in first, the old retry
  /// loop sees the changed number and stops
  int _attempt = 0;

  String get _peerName => widget.device.alias;

  PairSas? get _sas => _asHost ? _host?.state.value.sas : _session?.sas;

  PairPeerInfo? get _peer => _asHost ? _host?.state.value.peer : _session?.peer;

  @override
  void initState() {
    super.initState();
    ensureRef((ref) => _connectLoop());
  }

  @override
  void dispose() {
    _attempt++;
    unawaited(_closeHost());
    _name.dispose();
    super.dispose();
  }

  PairPeerInfo _self() {
    final me = ref.read(deviceFullInfoProvider);
    final settings = ref.read(settingsProvider);
    return PairPeerInfo(
      fingerprint: ref.read(securityProvider).certificateHash,
      alias: me.alias == '-' ? settings.alias : me.alias,
      model: me.deviceModel,
      type: me.deviceType.name,
      port: me.port > 0 ? me.port : settings.port,
      https: me.https,
      addresses: pairAddresses(ref.read(localIpProvider)),
    );
  }

  PairGuest _guest() => PairGuest(self: _self());

  /// Who waits when both PCs clicked "Pair": the one with the smaller fingerprint (uppercase hex). The two always get
  /// opposite results.
  bool get _iWait => ref.read(securityProvider).certificateHash.compareTo(widget.device.fingerprint) < 0;

  Future<void> _startHost() async {
    await _closeHost();
    if (!_iWait) return;
    final security = ref.read(securityProvider);
    final host = PairHost(
      self: _self(),
      certificatePem: security.certificate,
      privateKeyPem: security.privateKey,
      ips: const [],
      onlyGuest: widget.device.fingerprint,
      onPaired: (peer, ip, secret) => savePairing(ref, peer, ip, secret, customName: _name.text, method: pairMethodNearby),
    );
    try {
      await host.start();
    } catch (e) {
      _logger.info('could not wait for the other computer, only connecting to it', e);
      return;
    }
    if (!mounted || !host.acceptsNearby) {
      // The fixed port is taken (e.g. this PC's "Add device" page is still open): only act as the connecting side
      await host.close();
      return;
    }
    host.state.addListener(_onHostState);
    _host = host;
  }

  Future<void> _closeHost() async {
    final h = _host;
    _host = null;
    if (h == null) return;
    h.state.removeListener(_onHostState);
    await h.close();
  }

  void _onHostState() {
    final st = _host?.state.value;
    if (st == null || !mounted) return;
    switch (st.stage) {
      case PairHostStage.verifying when !_asHost && _stage == _Stage.connecting:
        _attempt++; // the peer connected in first: stop this side's connect loop
        _name.text = st.peer!.alias;
        setState(() {
          _asHost = true;
          _stage = _Stage.verifying;
        });
      case PairHostStage.paired when _asHost:
        setState(() => _stage = _Stage.done);
      case PairHostStage.failed when _asHost && _stage != _Stage.failed:
        _fail(st.failure ?? PairFailure.protocol);
      default:
        break;
    }
  }

  Future<void> _connectLoop() async {
    final attempt = ++_attempt;
    final ip = widget.device.ip;
    if (ip == null) {
      _fail(PairFailure.unreachable);
      return;
    }
    final deadline = DateTime.now().add(pairCodeLifetime);
    // On the first run this is already the state, so skip setState (we may still be inside initState)
    if (_stage != _Stage.connecting || _failure != null || _otherPageMissing || _waitingAccept || _asHost) {
      setState(() {
        _stage = _Stage.connecting;
        _session = null;
        _failure = null;
        _otherPageMissing = false;
        _waitingAccept = false;
        _asHost = false;
      });
    }
    await _startHost();
    while (mounted && attempt == _attempt) {
      try {
        final session = await _guest().connectNearby(
          host: ip,
          fingerprint: widget.device.fingerprint,
          onWaitingForAccept: () {
            if (mounted && attempt == _attempt) {
              setState(() {
                _waitingAccept = true;
                _otherPageMissing = false;
              });
            }
          },
          cancelled: () => !mounted || attempt != _attempt,
        );
        if (!mounted || attempt != _attempt) return;
        await _closeHost(); // connected to the peer, so stop waiting here
        _name.text = session.peer.alias;
        setState(() {
          _session = session;
          _stage = _Stage.verifying;
        });
        return;
      } on PairException catch (e) {
        if (!mounted || attempt != _attempt) return;
        if (e.failure == PairFailure.unreachable && DateTime.now().isBefore(deadline)) {
          setState(() {
            _otherPageMissing = true;
            _waitingAccept = false; // the other side closed its page while we waited for "Accept"
          });
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }
        _fail(e.failure);
        return;
      } catch (_) {
        if (mounted && attempt == _attempt) _fail(PairFailure.unreachable);
        return;
      }
    }
  }

  /// The code typed here (read from the other computer's screen)
  Future<PairCodeResult> _submitCode(String code) async {
    if (_asHost) {
      // A match confirms this side; saved as soon as the peer's code matches too (_onHostState switches to the done page on
      // "paired", or to the failure on too many wrong codes)
      return _host?.checkCode(code) ?? PairCodeResult.exhausted;
    }
    final session = _session!;
    final result = await _guest().checkCode(session, code);
    switch (result) {
      case PairCodeResult.match:
        unawaited(_confirmGuest(session));
      case PairCodeResult.exhausted:
        _fail(PairFailure.codeMismatch);
      case PairCodeResult.wrong:
        break;
    }
    return result;
  }

  /// This side's code matched: wait for the other computer's code to match too, then save
  Future<void> _confirmGuest(PairGuestSession session) async {
    try {
      await _guest().confirm(session);
      await savePairing(ref, session.peer, session.address.host, session.secret, customName: _name.text, method: pairMethodNearby);
      if (mounted) setState(() => _stage = _Stage.done);
    } on PairException catch (e) {
      _fail(e.failure);
    } catch (_) {
      _fail(PairFailure.unreachable);
    }
  }

  void _finish() {
    final peer = _peer;
    if (peer != null) renameMyDevice(ref, peer.fingerprint, _name.text, ownName: peer.alias);
    Navigator.of(context).pop();
  }

  /// "Cancel" while checking
  Future<void> _cancel() async {
    if (_asHost) {
      _host?.reject();
      _fail(PairFailure.rejectedHere);
      return;
    }
    final session = _session;
    _fail(PairFailure.rejectedHere);
    if (session != null) await _guest().reject(session);
  }

  /// Fallback when the peer isn't Shuttle: like the old "Add", it only adds the device to "My devices", without verifying
  Future<void> _addPlain() async {
    final d = widget.device;
    _attempt++;
    await _closeHost();
    ref
        .redux(favoritesProvider)
        .dispatch(AddFavoriteAction(FavoriteDevice.fromValues(fingerprint: d.fingerprint, ip: d.ip!, port: d.port, alias: d.alias)));
    if (mounted) Navigator.of(context).pop();
  }

  void _fail(PairFailure f) {
    if (!mounted) return;
    _attempt++;
    setState(() {
      _failure = f;
      _stage = _Stage.failed;
    });
    // When we are the host and the peer has connected in, keep the host open until "Try again" so the peer also sees why it failed
    if (!_asHost) unawaited(_closeHost());
  }

  String _failureText(PairFailure f) {
    final s = t.shareme.pair;
    return switch (f) {
      PairFailure.used => s.failNearbyBusy(name: _peerName),
      PairFailure.unreachable => s.failNearbyUnreachable(name: _peerName),
      PairFailure.expired => s.failNearbyExpired(name: _peerName),
      PairFailure.declined => s.failNearbyDeclined(name: _peerName),
      PairFailure.outdated => s.failNearbyOutdated(name: _peerName),
      _ => pairFailureText(f),
    };
  }

  @override
  Widget build(BuildContext context) {
    final s = t.shareme.pair;
    return Scaffold(
      appBar: AppBar(title: Text(_stage == _Stage.done ? s.doneTitle : s.nearbyTitle(name: _peerName))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
            child: switch (_stage) {
              _Stage.connecting => _connectingView(context),
              _Stage.verifying => TypedCodePanel(
                myCode: _asHost ? _sas!.hostCode : _sas!.guestCode,
                peerName: _peer?.alias ?? _peerName,
                onSubmit: _submitCode,
                onCancel: () async => _cancel(),
              ),
              _Stage.done => _doneView(context),
              _Stage.failed => Padding(
                padding: const EdgeInsets.only(top: 60),
                child: PairFailureView(
                  failure: _failure ?? PairFailure.protocol,
                  message: _failureText(_failure ?? PairFailure.protocol),
                  primaryLabel: s.tryAgainShort,
                  onPrimary: () async => _connectLoop(),
                  onClose: () => Navigator.of(context).pop(),
                ),
              ),
            },
          ),
        ),
      ),
    );
  }

  Widget _connectingView(BuildContext context) {
    final c = context.sm;
    final s = t.shareme.pair;
    return Padding(
      padding: const EdgeInsets.only(top: 60),
      child: Column(
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 18),
          Text(
            s.nearbyConnecting(name: _peerName),
            style: ShareMeText.body.copyWith(color: c.ink2),
            textAlign: TextAlign.center,
          ),
          if (_waitingAccept) ...[
            const SizedBox(height: 20),
            Text(
              s.nearbyWaitAccept(name: _peerName),
              style: ShareMeText.body.copyWith(color: c.ink),
              textAlign: TextAlign.center,
            ),
          ] else if (_otherPageMissing) ...[
            const SizedBox(height: 20),
            Text(
              s.nearbyOpenOther(name: _peerName),
              style: ShareMeText.body.copyWith(color: c.ink),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            TextButton(onPressed: () async => _addPlain(), child: Text(s.nearbyAddPlain)),
          ],
        ],
      ),
    );
  }

  Widget _doneView(BuildContext context) {
    final c = context.sm;
    final s = t.shareme.pair;
    final peer = _peer!;
    final settings = context.watch(settingsProvider);
    final me = ref.read(deviceFullInfoProvider);
    final name = _name.text.trim().isEmpty ? peer.alias : _name.text.trim();
    return Column(
      children: [
        const SizedBox(height: 24),
        PairedDuo(
          myFingerprint: ref.read(securityProvider).certificateHash,
          myName: me.alias == '-' ? settings.alias : me.alias,
          theirFingerprint: peer.fingerprint,
          theirName: name,
        ),
        const SizedBox(height: 22),
        Text(s.doneTitle, style: ShareMeText.display.copyWith(color: c.ink)),
        const SizedBox(height: 10),
        Text(
          settings.quickSave || settings.quickSaveFromFavorites ? s.doneAuto(name: name) : s.doneAsk(name: name),
          style: ShareMeText.body.copyWith(color: c.ink2),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 18),
        TextField(
          controller: _name,
          maxLength: 32,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: s.nameIt, counterText: ''),
        ),
        const SizedBox(height: 20),
        FilledButton(onPressed: _finish, child: Text(s.done)),
      ],
    );
  }
}
