import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/widget/shareme/device_avatar.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

enum ScenePhase {
  /// Nothing is moving yet (connecting, waiting for the other side to accept)
  waiting,
  moving,
  done,

  /// Declined, canceled or failed
  broken,
}

/// Shuttle's own picture of a transfer: two devices joined by a path with the app icon's S bend, which fills up as the files move
/// across, instead of a progress bar and words like "sending to". Waiting: dots run along the path. Done: the receiving device
/// catches what arrives, a ring runs outwards and the check mark appears.
class TransferScene extends StatefulWidget {
  /// The sending and the receiving device
  final Widget from;
  final Widget to;
  final double avatarSize;
  final ScenePhase phase;

  /// 0 to 1, shown while [ScenePhase.moving]
  final double progress;

  /// Delay before the arrival plays (while something is still flying towards the receiving device)
  final Duration arriveAfter;

  const TransferScene({
    required this.from,
    required this.to,
    required this.avatarSize,
    required this.phase,
    this.progress = 0,
    this.arriveAfter = Duration.zero,
    super.key,
  });

  @override
  State<TransferScene> createState() => _TransferSceneState();
}

class _TransferSceneState extends State<TransferScene> with TickerProviderStateMixin {
  late final _loop = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
  late final _arrive = AnimationController(vsync: this, duration: const Duration(milliseconds: 760));
  Timer? _delay;
  bool _still = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.disableAnimationsOf(context);
    _sync(justOpened: true);
  }

  @override
  void didUpdateWidget(TransferScene old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync({bool justOpened = false}) {
    final live = widget.phase == ScenePhase.waiting || widget.phase == ScenePhase.moving;
    if (live && !_still) {
      if (!_loop.isAnimating) unawaited(_loop.repeat());
    } else {
      _loop.stop();
    }
    if (widget.phase != ScenePhase.done) {
      _delay?.cancel();
      _delay = null;
      _arrive.value = 0;
    } else if (_still) {
      _arrive.value = 1;
    } else if (_delay == null && _arrive.value == 0) {
      _delay = Timer(justOpened ? Duration.zero : widget.arriveAfter, () {
        if (!mounted) return;
        unawaited(_arrive.forward());
        unawaited(HapticFeedback.mediumImpact());
      });
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    _loop.dispose();
    _arrive.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final size = widget.avatarSize;
    final solid = widget.phase != ScenePhase.waiting;
    final filled = switch (widget.phase) {
      ScenePhase.done => 1.0,
      ScenePhase.moving => widget.progress.clamp(0.0, 1.0),
      _ => 0.0,
    };
    return SizedBox(
      height: size,
      child: Row(
        children: [
          widget.from,
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: size * 0.16),
              child: RepaintBoundary(
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: solid ? 1 : 0),
                  duration: const Duration(milliseconds: 320),
                  builder: (context, solidity, _) => TweenAnimationBuilder<double>(
                    tween: Tween(end: filled),
                    // The numbers arrive about twice a second: gliding between them keeps the line moving all the time
                    duration: Duration(milliseconds: widget.phase == ScenePhase.done ? 260 : 600),
                    builder: (context, value, _) => CustomPaint(
                      size: Size(double.infinity, size),
                      painter: _PathPainter(
                        loop: _loop,
                        arrive: _arrive,
                        solidity: solidity,
                        value: value,
                        phase: widget.phase,
                        bend: size * 0.42,
                        stroke: size < 50 ? 5 : 6,
                        track: c.tonalStrong,
                        accent: c.accent,
                        dark: Theme.of(context).brightness == Brightness.dark,
                      ),
                      child: widget.phase == ScenePhase.broken
                          ? Center(
                              child: Container(
                                width: size * 0.36,
                                height: size * 0.36,
                                decoration: BoxDecoration(color: c.warnContainer, shape: BoxShape.circle),
                                child: Icon(LucideIcons.x, size: size * 0.2, color: c.warn),
                              ),
                            )
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
          _Arrival(animation: _arrive, size: size, child: widget.to),
        ],
      ),
    );
  }
}

/// The receiving device: gives way a little as it catches what arrives, a ring runs outwards and the check mark pops in.
class _Arrival extends StatelessWidget {
  final Animation<double> animation;
  final double size;
  final Widget child;

  const _Arrival({required this.animation, required this.size, required this.child});

  static final _catch = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.94).chain(CurveTween(curve: Curves.easeOut)), weight: 12),
    TweenSequenceItem(tween: Tween(begin: 0.94, end: 1.06).chain(CurveTween(curve: Curves.easeOut)), weight: 24),
    TweenSequenceItem(tween: Tween(begin: 1.06, end: 1.0).chain(CurveTween(curve: Curves.easeInOut)), weight: 26),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 38),
  ]);

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final badge = (size * 0.4).clamp(16.0, 30.0);
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final v = animation.value;
        final pop = Curves.easeOutBack.transform(((v - 0.14) / 0.5).clamp(0.0, 1.0));
        return Transform.scale(
          scale: _catch.transform(v.clamp(0.0, 1.0)),
          child: SizedBox.square(
            dimension: size,
            child: CustomPaint(
              painter: v > 0 && v < 1 ? _PulsePainter(v, radius: size * 0.32) : null,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  if (pop > 0)
                    ClipPath(
                      clipper: BadgeHole(size: size, badge: badge * pop),
                      child: child,
                    )
                  else
                    child!,
                  if (pop > 0)
                    BadgeHole.positioned(
                      size: size,
                      badge: badge,
                      child: Transform.scale(
                        scale: pop,
                        child: CheckBadge(size: badge, color: c.ok),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PulsePainter extends CustomPainter {
  final double v;
  final double radius;

  const _PulsePainter(this.v, {required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final t = Curves.easeOutCubic.transform(v);
    final grow = size.width * 0.36 * t;
    canvas.drawRRect(
      RRect.fromRectAndRadius((Offset.zero & size).inflate(grow), Radius.circular(radius + grow)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5 * (1 - t) + 0.5
        ..color = const Color(0xFFF2783C).withValues(alpha: 0.6 * (1 - t)),
    );
  }

  @override
  bool shouldRepaint(_PulsePainter old) => old.v != v;
}

class _PathPainter extends CustomPainter {
  final Animation<double> loop;
  final Animation<double> arrive;

  /// 0 = dots (waiting), 1 = line
  final double solidity;
  final double value;
  final ScenePhase phase;
  final double bend;
  final double stroke;
  final Color track;
  final Color accent;
  final bool dark;

  _PathPainter({
    required this.loop,
    required this.arrive,
    required this.solidity,
    required this.value,
    required this.phase,
    required this.bend,
    required this.stroke,
    required this.track,
    required this.accent,
    required this.dark,
  }) : super(repaint: Listenable.merge([loop, arrive]));

  static const _colors = [Color(0xFFF6B04E), Color(0xFFEE7A3A), Color(0xFFD9452A)];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0) return;
    final y = size.height / 2;
    final path = Path()
      ..moveTo(stroke / 2, y)
      ..cubicTo(size.width * 0.34, y - bend, size.width * 0.66, y + bend, size.width - stroke / 2, y);
    final metric = path.computeMetrics().first;
    if (solidity < 1) _dots(canvas, metric);
    if (solidity > 0) _line(canvas, size, path, metric);
  }

  void _dots(Canvas canvas, ui.PathMetric metric) {
    final n = math.max(5, (metric.length / 14).floor());
    final head = loop.value * (n + 5) - 2;
    for (var i = 0; i < n; i++) {
      final at = metric.getTangentForOffset(metric.length * (i + 0.5) / n)!.position;
      final near = Curves.easeInOut.transform((1 - (head - i).abs() / 2.6).clamp(0.0, 1.0));
      final color = Color.lerp(track, accent, near)!;
      canvas.drawCircle(at, 2.2 + 1.8 * near, Paint()..color = color.withValues(alpha: color.a * (1 - solidity)));
    }
  }

  Paint _pen(double width) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeWidth = width;

  void _line(Canvas canvas, Size size, Path path, ui.PathMetric metric) {
    final base = _pen(stroke)..color = track.withValues(alpha: track.a * solidity);
    final length = metric.length;
    if (phase == ScenePhase.broken) {
      final gap = math.min(50.0, length * 0.36);
      canvas.drawPath(metric.extractPath(0, (length - gap) / 2), base);
      canvas.drawPath(metric.extractPath((length + gap) / 2, length), base);
      return;
    }
    canvas.drawPath(path, base);
    if (value <= 0 && phase != ScenePhase.moving) return;
    final reached = math.max(0.1, length * value);
    final done = metric.extractPath(0, reached);
    final shader = const LinearGradient(colors: _colors, stops: [0, 0.5, 1]).createShader(
      Rect.fromLTWH(0, 0, math.max(1, size.width * math.max(value, 0.25)), size.height),
    );
    canvas.drawPath(
      done.shift(Offset(0, dark ? 0 : 2)),
      _pen(stroke)
        ..color = const Color(0xFFE2582B).withValues(alpha: (dark ? 0.7 : 0.3) * solidity)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, dark ? 6 : 4),
    );
    canvas.drawPath(done, _pen(stroke)..shader = shader);
    canvas.drawPath(
      done.shift(Offset(0, -stroke * 0.2)),
      _pen(stroke * 0.28)..color = Colors.white.withValues(alpha: 0.4 * solidity),
    );
    // The light that carries the files, breathing gently
    if (phase == ScenePhase.moving) {
      final breath = 0.5 + 0.5 * math.sin(loop.value * 2 * math.pi);
      final at = metric.getTangentForOffset(reached)!.position;
      final halo = stroke * 2.2 + 3 * breath;
      canvas.drawCircle(
        at,
        halo,
        Paint()
          ..shader = RadialGradient(
            colors: [
              const Color(0xFFFF8A3D).withValues(alpha: dark ? 0.65 : 0.45),
              const Color(0x00FF8A3D),
            ],
          ).createShader(Rect.fromCircle(center: at, radius: halo)),
      );
      canvas.drawCircle(at, stroke * 1.05, Paint()..color = const Color(0xFFE2582B));
      canvas.drawCircle(at, stroke * 0.58 + 0.4 * breath, Paint()..color = const Color(0xFFFFEBD6));
    }
    // Arrival: a glint runs along the finished line
    if (phase == ScenePhase.done && arrive.value > 0 && arrive.value < 0.6) {
      final p = Curves.easeOut.transform(arrive.value / 0.6);
      final from = (length * p - 30).clamp(0.0, length);
      final to = (length * p + 10).clamp(0.0, length);
      canvas.drawPath(metric.extractPath(from, to), _pen(stroke * 0.8)..color = Colors.white.withValues(alpha: 0.75 * (1 - p)));
    }
  }

  @override
  bool shouldRepaint(_PathPainter old) =>
      old.solidity != solidity || old.value != value || old.phase != phase || old.track != track || old.dark != dark || old.bend != bend;
}
