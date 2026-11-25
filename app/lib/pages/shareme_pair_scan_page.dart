import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/paired_devices_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/shareme_pairing/pair_crypto.dart';
import 'package:localsend_app/util/shareme_pairing/pair_protocol.dart';
import 'package:localsend_app/widget/shareme/ambient.dart';
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
    return SmScaffold(
      appBar: AppBar(title: _stage == _Stage.done ? null : Text(s.scanTitle)),
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
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: smStatusBar(darkBackground: true), // the viewfinder is black in light mode too
      child: Scaffold(
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
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(LucideIcons.cameraOff, size: 40, color: Colors.white70),
                        const SizedBox(height: 16),
                        Text(
                          s.cameraError(error: error.errorDetails?.message ?? error.errorCode.name),
                          style: ShareMeText.body.copyWith(color: Colors.white),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // No frame over the message when the camera doesn't open
            Positioned.fill(
              child: ValueListenableBuilder(
                valueListenable: _scanner,
                builder: (context, camera, _) => camera.error == null ? const _Viewfinder() : const SizedBox.shrink(),
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
                  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [c.bgTop, c.bgBottom]),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(ShareMeSize.radiusSheet)),
                ),
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.scanFrame, style: ShareMeText.title.copyWith(color: c.ink, fontSize: 19)),
                      const SizedBox(height: 6),
                      Text(s.scanHowBody, style: ShareMeText.body.copyWith(color: c.ink2)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
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
    final name = _name.text.trim().isEmpty ? session.peer.alias : _name.text.trim();
    return Column(
      children: [
        const SizedBox(height: 44),
        PairedDuo(theirFingerprint: session.peer.fingerprint),
        const SizedBox(height: 30),
        Text(s.doneTitle, style: ShareMeText.display.copyWith(color: c.ink, fontSize: 30)),
        const SizedBox(height: 8),
        Text(
          settings.quickSave || settings.quickSaveFromFavorites ? s.doneAuto(name: name) : s.doneAsk(name: name),
          style: ShareMeText.body.copyWith(color: c.ink2),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 36),
        PairNameForm(controller: _name, onChanged: () => setState(() {}), onDone: _finish),
      ],
    );
  }
}

/// Everything but the frame is dimmed; the frame is four corners with a light that sweeps up and down.
class _Viewfinder extends StatefulWidget {
  const _Viewfinder();

  @override
  State<_Viewfinder> createState() => _ViewfinderState();
}

class _ViewfinderState extends State<_Viewfinder> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      unawaited(_c.repeat(reverse: true));
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(child: CustomPaint(painter: _ViewfinderPainter(_c))),
  );
}

class _ViewfinderPainter extends CustomPainter {
  final Animation<double> t;

  _ViewfinderPainter(this.t) : super(repaint: t);

  @override
  void paint(Canvas canvas, Size size) {
    const side = 250.0;
    const r = 34.0;
    // A little above the middle: the instructions cover the bottom
    final box = Rect.fromCenter(center: Offset(size.width / 2, size.height * 0.42), width: side, height: side);
    final hole = RRect.fromRectAndRadius(box, const Radius.circular(r));
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRRect(hole)),
      Paint()..color = const Color(0x8C000000),
    );
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFFF2874A);
    const half = side / 2 + 2;
    const arm = 22.0;
    final corner = Path()
      ..moveTo(-half, -half + r + arm)
      ..lineTo(-half, -half + r)
      ..arcToPoint(const Offset(-half + r, -half), radius: const Radius.circular(r))
      ..lineTo(-half + r + arm, -half);
    for (final (sx, sy) in const [(1.0, 1.0), (-1.0, 1.0), (1.0, -1.0), (-1.0, -1.0)]) {
      canvas
        ..save()
        ..translate(box.center.dx, box.center.dy)
        ..scale(sx, sy)
        ..drawPath(corner, pen)
        ..restore();
    }
    // The sweeping light
    final y = box.top + 18 + (side - 36) * Curves.easeInOut.transform(t.value);
    const reach = side / 2 - 18;
    final glow = Rect.fromCircle(center: Offset.zero, radius: reach);
    canvas
      ..save()
      ..translate(box.center.dx, y)
      ..drawRect(
        Rect.fromLTWH(-reach, -1, reach * 2, 2),
        Paint()..shader = const LinearGradient(colors: [Color(0x00FFB066), Color(0xFFFFC58A), Color(0x00FFB066)]).createShader(glow),
      )
      ..scale(1, 0.3)
      ..drawCircle(
        Offset.zero,
        reach,
        Paint()..shader = const RadialGradient(colors: [Color(0x47F2783C), Color(0x00F2783C)]).createShader(glow),
      )
      ..restore();
  }

  @override
  bool shouldRepaint(_ViewfinderPainter old) => false;
}
