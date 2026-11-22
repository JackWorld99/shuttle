import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/config/shareme_theme.dart';

/// Signature animation: the stamp.
///
/// The stamp goes from 1.18×, transparent, rotated -8° to 1.0×, opaque, rotated -4° in 260 ms with a slight bounce;
/// HapticFeedback.mediumImpact() fires as it lands. With the system's "remove animations" setting on it just appears, unscaled and unrotated.
/// At most one stamp per page; seals in lists aren't animated.
class Stamp extends StatefulWidget {
  final Widget child;
  final Duration delay;

  /// Tilt -4° when it lands (like a rubber stamp). Pass false for small labels and the like.
  final bool tilt;

  const Stamp({required this.child, this.delay = const Duration(milliseconds: 120), this.tilt = true, super.key});

  @override
  State<Stamp> createState() => _StampState();
}

class _StampState extends State<Stamp> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: ShareMeMotion.stamp);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.of(context).disableAnimations) {
      _c.value = 1;
      return;
    }
    Future<void>.delayed(widget.delay, () async {
      if (!mounted) return;
      await _c.forward();
      if (mounted) await HapticFeedback.mediumImpact();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.of(context).disableAnimations;
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        final t = ShareMeMotion.stampCurve.transform(_c.value);
        final scale = reduce ? 1.0 : 1.18 + (1.0 - 1.18) * t;
        final degrees = !widget.tilt ? 0.0 : (reduce ? -4.0 : -8 + 4 * t);
        return Opacity(
          opacity: _c.value.clamp(0.0, 1.0),
          child: Transform.rotate(
            angle: degrees * math.pi / 180,
            child: Transform.scale(scale: scale, child: child),
          ),
        );
      },
    );
  }
}
