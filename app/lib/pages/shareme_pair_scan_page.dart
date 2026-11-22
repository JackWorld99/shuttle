import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/paired_devices_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/shareme_pairing/pair_crypto.dart';
import 'package:localsend_app/util/shareme_pairing/pair_protocol.dart';
import 'package:localsend_app/widget/shareme/pair_widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:refena_flutter/refena_flutter.dart';

enum _Stage {
  scanning,
  connecting,

  /// Handshake done; both sides confirm on their own
  finishing,

  /// The PC runs an older Shuttle that still asks its user to compare the 12 digits: show them and wait for its "Same, pair"
  legacy,
  done,
  failed,
}

/// Shuttle: "Scan to pair" on the phone. Scan the QR code on the PC: the code holds the PC's certificate fingerprint and a one-time
/// key, so once the handshake checks out both sides pair on their own and add each other to "My devices" (nothing to compare).
/// Screens: (1) all-black viewfinder + instructions at the bottom → (2) connecting → (3) paired, with a field to rename the PC.
class SmPairScanPage extends StatefulWidget {
  const SmPairScanPage({super.key});

  @override
  State<SmPairScanPage> createState() => _SmPairScanPageState();
}

class _SmPairScanPageState extends State<SmPairScanPage> with Refena {
  final _scanner = MobileScannerController(formats: const [BarcodeFormat.qrCode], detectionSpeed: DetectionSpeed.noDuplicates);
  final _name = TextEditingController();
  _Stage _stage = _Stage.scanning;
  PairGuestSession? _session;
  PairFailure? _failure;
  bool _foreignCode = false;
  Timer? _foreignTimer;

  /// "Cancel" was tapped while waiting for an older PC: ignore the failure the waiting loop reports afterwards
  bool _cancelled = false;

  @override
  void dispose() {
    _foreignTimer?.cancel();
    unawaited(_scanner.dispose());
    _name.dispose();
    super.dispose();
  }

  PairGuest _guest() {
    final me = ref.read(deviceFullInfoProvider);
    final settings = ref.read(settingsProvider);
    return PairGuest(
      self: PairPeerInfo(
        fingerprint: ref.read(securityProvider).certificateHash,
        alias: me.alias == '-' ? settings.alias : me.alias,
        model: me.deviceModel,
        type: me.deviceType.name,
        port: me.port > 0 ? me.port : settings.port,
        https: me.https,
        addresses: pairAddresses(ref.read(localIpProvider)),
      ),
    );
  }

  void _onDetect(BarcodeCapture capture) {
    if (_stage != _Stage.scanning) return;
    for (final b in capture.barcodes) {
      final invite = PairInvite.tryParse(b.rawValue ?? '');
      if (invite != null) {
        unawaited(_connect(invite));
        return;
      }
    }
    setState(() => _foreignCode = true);
    _foreignTimer?.cancel();
    _foreignTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _foreignCode = false);
    });
  }

  Future<void> _connect(PairInvite invite) async {
    setState(() => _stage = _Stage.connecting);
    unawaited(_scanner.stop());
    _cancelled = false;
    try {
      final guest = _guest();
      final session = await guest.connect(invite);
      if (!mounted) return;
      _name.text = session.peer.alias;
      setState(() {
        _session = session;
        _stage = session.hostAutoQr ? _Stage.finishing : _Stage.legacy;
      });
      // The QR code already proved who is who (pinned certificate + one-time key): confirm right away
      await guest.confirm(session);
      await savePairing(ref, session.peer, session.address.host, session.secret);
      if (mounted && !_cancelled) setState(() => _stage = _Stage.done);
    } on PairException catch (e) {
      if (!_cancelled) _fail(e.failure);
    } catch (_) {
      if (!_cancelled) _fail(PairFailure.unreachable);
    }
  }

  /// "Cancel" while an older PC waits for its user to compare the digits
  Future<void> _cancel() async {
    final session = _session;
    _cancelled = true;
    _fail(PairFailure.rejectedHere);
    if (session != null) await _guest().reject(session);
  }

  void _fail(PairFailure f) {
    if (!mounted) return;
    setState(() {
      _failure = f;
      _stage = _Stage.failed;
    });
  }

  Future<void> _scanAgain() async {
    setState(() {
      _session = null;
      _failure = null;
      _stage = _Stage.scanning;
    });
    await _scanner.start();
  }

  void _finish() {
    final session = _session;
    if (session != null) renameMyDevice(ref, session.peer.fingerprint, _name.text, ownName: session.peer.alias);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final s = t.shareme.pair;
    if (_stage == _Stage.scanning) return _scanView(context);
    return Scaffold(
      appBar: AppBar(title: Text(_stage == _Stage.done ? s.doneTitle : s.scanTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          children: [
            switch (_stage) {
              _Stage.connecting || _Stage.finishing => Padding(
                padding: const EdgeInsets.only(top: 80),
                child: Column(
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                      _stage == _Stage.connecting ? s.connecting : s.finishing,
                      style: ShareMeText.body.copyWith(color: c.ink2),
                    ),
                  ],
                ),
              ),
              _Stage.legacy => _legacyView(context),
              _Stage.done => _doneView(context),
              _Stage.failed => Padding(
                padding: const EdgeInsets.only(top: 60),
                child: PairFailureView(
                  failure: _failure ?? PairFailure.protocol,
                  primaryLabel: s.tryAgain,
                  onPrimary: () async => _scanAgain(),
                  onClose: () => Navigator.of(context).pop(),
                ),
              ),
              _Stage.scanning => const SizedBox(),
            },
          ],
        ),
      ),
    );
  }

  Widget _scanView(BuildContext context) {
    final c = context.sm;
    final s = t.shareme.pair;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: MobileScanner(
              controller: _scanner,
              onDetect: _onDetect,
              errorBuilder: (context, error) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    s.cameraError(error: error.errorDetails?.message ?? error.errorCode.name),
                    style: ShareMeText.body.copyWith(color: Colors.white),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
          // Viewfinder frame
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white.withValues(alpha: 0.9), width: 2),
                borderRadius: BorderRadius.circular(ShareMeSize.radiusGroup),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                icon: const Icon(LucideIcons.x, color: Colors.white),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
          if (_foreignCode)
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 56),
                  child: Text(s.notOurCode, style: ShareMeText.body.copyWith(color: Colors.white)),
                ),
              ),
            ),
          // Instructions at the bottom (screen 1)
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: c.bg,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(ShareMeSize.radiusGroup)),
              ),
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.scanFrame, style: ShareMeText.title.copyWith(color: c.ink)),
                    const SizedBox(height: 12),
                    Text(s.scanHowTitle, style: ShareMeText.section.copyWith(color: c.ink2)),
                    const SizedBox(height: 4),
                    Text(s.scanHowBody, style: ShareMeText.body.copyWith(color: c.ink2)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The PC runs an older Shuttle: it shows the same 12 digits and waits for its user to compare and confirm
  Widget _legacyView(BuildContext context) {
    final c = context.sm;
    final s = t.shareme.pair;
    final session = _session!;
    return Column(
      children: [
        Text(
          s.legacyHost,
          style: ShareMeText.body.copyWith(color: c.ink2),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        PairCheckPanel(sas: session.sas),
        const SizedBox(height: 22),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Text(s.waitComputer, style: ShareMeText.body.copyWith(color: c.ink2)),
          ],
        ),
        const SizedBox(height: 14),
        TextButton(onPressed: () async => _cancel(), child: Text(t.shareme.settings.cancel)),
      ],
    );
  }

  Widget _doneView(BuildContext context) {
    final c = context.sm;
    final s = t.shareme.pair;
    final session = _session!;
    final settings = context.watch(settingsProvider);
    final me = ref.read(deviceFullInfoProvider);
    final name = _name.text.trim().isEmpty ? session.peer.alias : _name.text.trim();
    return Column(
      children: [
        const SizedBox(height: 24),
        PairedDuo(
          myFingerprint: ref.read(securityProvider).certificateHash,
          myName: me.alias == '-' ? settings.alias : me.alias,
          theirFingerprint: session.peer.fingerprint,
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
