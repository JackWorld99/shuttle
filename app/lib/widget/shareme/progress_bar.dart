import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';

/// Transfer progress: a soft track and a fill in the brand's warm gradient, with a light upper edge and a faint glow under it.
/// Moves smoothly between values. Without a [value] it is the usual "working on it" animation.
class SmProgressBar extends StatelessWidget {
  /// 0 to 1; null while there is nothing to measure yet
  final double? value;
  final double height;

  const SmProgressBar({required this.value, this.height = 8, super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final value = this.value;
    if (value == null) {
      return LinearProgressIndicator(
        minHeight: height,
        color: c.accent,
        backgroundColor: c.tonalStrong,
        borderRadius: BorderRadius.circular(ShareMeSize.radiusPill),
      );
    }
    final target = value.clamp(0.0, 1.0);
    return Semantics(
      value: '${(target * 100).round()}%',
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: target),
        duration: ShareMeMotion.short,
        builder: (context, v, _) => CustomPaint(
          size: Size(double.infinity, height),
          painter: _BarPainter(v, track: c.tonalStrong, dark: Theme.of(context).brightness == Brightness.dark),
        ),
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  final double value;
  final Color track;
  final bool dark;

  const _BarPainter(this.value, {required this.track, required this.dark});

  static const _fill = [Color(0xFFF2963B), Color(0xFFE2582B), Color(0xFFC93A22)];

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.height / 2);
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, radius), Paint()..color = track);
    if (value <= 0) return;
    // Never narrower than it is high, so the first percent is a round dot instead of a sliver
    final width = (size.width * value).clamp(size.height, size.width);
    final bar = Rect.fromLTWH(0, 0, width, size.height);
    final shape = RRect.fromRectAndRadius(bar, radius);
    canvas.drawRRect(
      shape.shift(Offset(0, dark ? 0 : size.height * 0.3)),
      Paint()
        ..color = const Color(0xFFE2582B).withValues(alpha: dark ? 0.6 : 0.28)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, size.height * (dark ? 0.9 : 0.6)),
    );
    canvas.drawRRect(shape, Paint()..shader = const LinearGradient(colors: _fill).createShader(bar));
    canvas.drawRRect(
      shape,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.center,
          colors: [Colors.white.withValues(alpha: 0.38), Colors.white.withValues(alpha: 0)],
        ).createShader(bar),
    );
  }

  @override
  bool shouldRepaint(_BarPainter old) => old.value != value || old.track != track || old.dark != dark;
}
