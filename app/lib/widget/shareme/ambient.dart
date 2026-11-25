import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/assets.gen.dart';
import 'package:logging/logging.dart';

final _logger = Logger('SmAmbient');

/// The backdrop in one dithered pass, and a single light ([SmGlow]). Null until loaded (and where that fails): then plain gradients are
/// painted.
ui.FragmentShader? _backdropShader;
ui.FragmentShader? _glowShader;

/// Called once at the start. With plain gradients the soft lights show as rings (Impeller doesn't dither them on OpenGL ES, Skia only
/// coarsely), and with Impeller they are the most expensive part of every frame (measured with tools/test/live/bench.dart).
Future<void> loadBackdropShader() async {
  try {
    _backdropShader = (await ui.FragmentProgram.fromAsset('shaders/backdrop.frag')).fragmentShader();
    _glowShader = (await ui.FragmentProgram.fromAsset('shaders/glow.frag')).fragmentShader();
  } catch (e) {
    _logger.warning('Shaders not available', e);
  }
}

/// The app's backdrop: a base gradient plus two soft warm glows (top right and left middle), painted once behind the content and
/// behind the navigation bar. Light mode: warm cream with a hint of light; dark mode: near black with warm light
/// coming in from the corners, like the app icon's dark glass tile. Purely decorative.
class SmAmbient extends StatelessWidget {
  final Widget child;

  /// How strong the glows are: 1 on the home screen, less on pages that are opened on their own (they have fewer cards, so the same
  /// light would tint the whole page)
  final double strength;

  /// Something to draw without being seen: the backdrop covers it ([SmWarmUp])
  final Widget? beneath;

  const SmAmbient({required this.child, this.strength = 1, this.beneath, super.key});

  @override
  Widget build(BuildContext context) {
    // The content is its own layer, so scrolling doesn't repaint the backdrop
    final backdrop = CustomPaint(
      painter: _BackdropPainter(context.sm, strength, MediaQuery.devicePixelRatioOf(context)),
      child: RepaintBoundary(child: child),
    );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: smStatusBar(darkBackground: Theme.of(context).brightness == Brightness.dark),
      child: beneath == null
          ? backdrop
          : Stack(
              fit: StackFit.passthrough,
              children: [
                Positioned.fill(
                  child: ExcludeSemantics(
                    child: IgnorePointer(child: RepaintBoundary(child: beneath)),
                  ),
                ),
                backdrop,
              ],
            ),
    );
  }
}

/// A page with the ambient backdrop: a transparent [Scaffold] (and app bar) over [SmAmbient]. Use it for pages that are opened on
/// their own; tabs inside the home screen share the home screen's backdrop and stay plain transparent scaffolds.
class SmScaffold extends StatelessWidget {
  final PreferredSizeWidget? appBar;
  final Widget? body;
  final Widget? bottomNavigationBar;
  final Widget? floatingActionButton;
  final bool? resizeToAvoidBottomInset;

  const SmScaffold({this.appBar, this.body, this.bottomNavigationBar, this.floatingActionButton, this.resizeToAvoidBottomInset, super.key});

  @override
  Widget build(BuildContext context) {
    return SmAmbient(
      strength: 0.55,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: appBar,
        body: body,
        bottomNavigationBar: bottomNavigationBar,
        floatingActionButton: floatingActionButton,
        resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      ),
    );
  }
}

/// Side padding that keeps a list at most [maxWidth] wide and centered in a wide window, while the scroll area and its scroll bar
/// still span the whole width. 0 on phones.
double smSideInset(double width, {double maxWidth = 760}) => math.max(0, (width - maxWidth) / 2);

/// A scrolling page of [children] that stays readable in a wide window (see [smSideInset]).
class SmPageList extends StatelessWidget {
  final EdgeInsets padding;
  final double maxWidth;
  final List<Widget> children;

  const SmPageList({required this.padding, required this.children, this.maxWidth = 760, super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => ListView(
        padding: padding + EdgeInsets.symmetric(horizontal: smSideInset(box.maxWidth, maxWidth: maxWidth)),
        children: children,
      ),
    );
  }
}

/// Keeps a page's content at most [maxWidth] wide, centered at the top: in a wide window the send and receive pages would stretch
/// like an enlarged phone screen.
class SmMaxWidth extends StatelessWidget {
  final double maxWidth;

  /// Only as high as its child (e.g. a row of buttons) instead of filling the height
  final bool maxHeightFree;
  final Widget child;

  const SmMaxWidth({required this.child, this.maxWidth = 560, this.maxHeightFree = false, super.key});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      heightFactor: maxHeightFree ? 1 : null,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// Fades out the lower edge of a scrolling list that ends above a row of pinned buttons, instead of cutting it off.
class SmFadeBottom extends StatelessWidget {
  final double extent;
  final Widget child;

  const SmFadeBottom({required this.child, this.extent = 20, super.key});

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: const [Colors.black, Colors.black, Color(0x00000000)],
        stops: [0, bounds.height <= extent ? 0 : 1 - extent / bounds.height, 1],
      ).createShader(bounds),
      child: child,
    );
  }
}

/// A soft round light behind [child] (the drop zone, the popup), without the rings of a plain radial gradient.
class SmGlow extends StatelessWidget {
  final Color color;
  final Alignment center;

  /// As a part of the shorter side
  final double radius;
  final double corner;
  final Widget? child;

  const SmGlow({required this.color, required this.center, required this.radius, this.corner = 0, this.child, super.key});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _GlowPainter(color, center, radius, corner, MediaQuery.devicePixelRatioOf(context)),
      child: child,
    );
  }
}

class _GlowPainter extends CustomPainter {
  final Color color;
  final Alignment center;
  final double radius;
  final double corner;
  final double pixelRatio;

  const _GlowPainter(this.color, this.center, this.radius, this.corner, this.pixelRatio);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final whole = Offset.zero & size;
    final at = center.withinRect(whole);
    final r = radius * size.shortestSide;
    final paint = Paint();
    final shader = _glowShader;
    if (shader != null) {
      final values = [at.dx, at.dy, r, pixelRatio, color.r, color.g, color.b, color.a];
      for (final (i, v) in values.indexed) {
        shader.setFloat(i, v);
      }
      paint.shader = shader;
    } else {
      paint.shader = RadialGradient(colors: [color, color.withValues(alpha: 0)]).createShader(Rect.fromCircle(center: at, radius: r));
    }
    canvas.drawRRect(RRect.fromRectAndRadius(whole, Radius.circular(corner)), paint);
  }

  @override
  bool shouldRepaint(_GlowPainter old) =>
      old.color != color || old.center != center || old.radius != radius || old.corner != corner || old.pixelRatio != pixelRatio;
}

/// The app icon with a warm drop shadow (phone top bar, desktop navigation rail).
class SmAppLogo extends StatelessWidget {
  final double size;

  const SmAppLogo({required this.size, super.key});

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * 0.28);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: ShareMeGradients.glow.withValues(alpha: 0.3),
            blurRadius: size / 3,
            spreadRadius: -size / 9,
            offset: Offset(0, size / 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Assets.img.logo128.image(width: size, height: size, filterQuality: FilterQuality.medium),
      ),
    );
  }
}

class _BackdropPainter extends CustomPainter {
  final ShareMeColors c;
  final double strength;
  final double pixelRatio;

  const _BackdropPainter(this.c, this.strength, this.pixelRatio);

  @override
  void paint(Canvas canvas, Size size) {
    final whole = Offset.zero & size;
    if (whole.isEmpty) return;
    // A phone screen's width, or the same proportion of a wide window: the lights stay in the corners instead of tinting it all
    final base = math.min(size.width, math.max(size.height * 0.6, 300.0));
    final lights = [
      (at: Offset(size.width - base * 0.14, -size.height * 0.04), radius: base * 1.05, color: c.glow1),
      (at: Offset(-base * 0.14, size.height * 0.25), radius: base * 0.95, color: c.glow2),
    ];

    final shader = _backdropShader;
    if (shader != null) {
      final values = [
        size.width,
        size.height,
        pixelRatio,
        0.0,
        for (final color in [c.bgTop, c.bgBottom]) ...[color.r, color.g, color.b, 1.0],
        for (final l in lights) ...[l.color.r, l.color.g, l.color.b, l.color.a * strength, l.at.dx, l.at.dy, l.radius, 0.0],
      ];
      for (final (i, v) in values.indexed) {
        shader.setFloat(i, v);
      }
      canvas.drawRect(whole, Paint()..shader = shader);
      return;
    }

    canvas.drawRect(
      whole,
      Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [c.bgTop, c.bgBottom]).createShader(whole),
    );
    canvas.save();
    canvas.clipRect(whole);
    for (final l in lights) {
      final rect = Rect.fromCircle(center: l.at, radius: l.radius);
      final color = l.color.withValues(alpha: l.color.a * strength);
      canvas.drawRect(rect, Paint()..shader = RadialGradient(colors: [color, color.withValues(alpha: 0)]).createShader(rect));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BackdropPainter old) => old.c != c || old.strength != strength || old.pixelRatio != pixelRatio;
}
