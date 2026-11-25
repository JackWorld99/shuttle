import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Windows draws with Skia (windows/runner/main.cpp), which compiles a GPU program the first time a kind of drawing is needed: 40 to
/// 55 ms for a rounded rectangle, enough to show as a hitch when a page or a dialog opens for the first time.
///
/// This draws those kinds once, a few per frame, shortly after the window appears. It sits beneath the opaque backdrop ([SmAmbient]), so
/// nothing of it can be seen. It has to be part of real frames: Flutter's own ShaderWarmUp draws into an image, whose programs are
/// different ones (measured with tools/test/live/trace.dart).
class SmWarmUp extends StatefulWidget {
  const SmWarmUp({super.key});

  @override
  State<SmWarmUp> createState() => _SmWarmUpState();
}

class _SmWarmUpState extends State<SmWarmUp> {
  static const _pause = Duration(milliseconds: 90);
  static bool _done = false;

  ui.Image? _image;
  int _step = -1;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (!_done) _timer = Timer(const Duration(milliseconds: 900), _start);
  }

  Future<void> _start() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    for (var i = 0; i < 16; i++) {
      canvas.drawRect(Rect.fromLTWH((i % 4) * 16, (i ~/ 4) * 16, 16, 16), Paint()..color = Color(0xFF000000 | i * 0x0F1A2B));
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(64, 64);
    picture.dispose();
    if (!mounted) return image.dispose();
    _image = image;
    _next();
  }

  /// The next step only follows once this one was really painted (no frames are drawn while the window is hidden)
  void _next() {
    if (!mounted) return;
    setState(() => _step++);
    if (_step >= _drawings.length) {
      _done = true;
      _image?.dispose();
      _image = null;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _timer = Timer(_pause, _next));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (_step < 0 || _step >= _drawings.length || image == null) return const SizedBox.shrink();
    return CustomPaint(
      size: Size.infinite,
      painter: _Painter(_step, _Kit(context.sm, image, dark: Theme.of(context).brightness == Brightness.dark)),
    );
  }
}

class _Painter extends CustomPainter {
  final int step;
  final _Kit kit;

  const _Painter(this.step, this.kit);

  @override
  void paint(Canvas canvas, Size size) => _drawings[step](canvas, kit);

  @override
  bool shouldRepaint(_Painter old) => old.step != step;
}

class _Kit {
  final ShareMeColors c;
  final ui.Image image;
  final bool dark;

  const _Kit(this.c, this.image, {required this.dark});

  static const whole = Rect.fromLTWH(0, 0, 300, 200);
  static const box = Rect.fromLTWH(20, 20, 200, 120);
  static const tileBox = Rect.fromLTWH(30, 30, 48, 48);
  static final card = RRect.fromRectAndRadius(box, const Radius.circular(ShareMeSize.radiusGroup));
  static final tile = RRect.fromRectAndRadius(tileBox, const Radius.circular(15));

  static Shader vertical(Rect r, List<Color> colors) =>
      LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: colors).createShader(r);

  static Shader round(Rect r, Color color) => RadialGradient(colors: [color, color.withValues(alpha: 0)]).createShader(r);

  void decorated(Canvas canvas, Rect rect, Decoration decoration) {
    final painter = decoration.createBoxPainter(() {});
    painter.paint(canvas, rect.topLeft, ImageConfiguration(size: rect.size, textDirection: TextDirection.ltr));
    painter.dispose();
  }

  void text(Canvas canvas, String s, TextStyle style, Offset at) {
    final p = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    p.paint(canvas, at);
    p.dispose();
  }

  void picture(Canvas canvas, Rect rect, {FilterQuality quality = FilterQuality.medium, double opacity = 1}) => canvas.drawImageRect(
    image,
    const Rect.fromLTWH(0, 8, 64, 48),
    rect,
    Paint()
      ..filterQuality = quality
      ..color = Colors.black.withValues(alpha: opacity),
  );

  Paint stroke(double width, Color color) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..color = color;
}

/// One entry per frame
final _drawings = <void Function(Canvas canvas, _Kit k)>[
  // History: the slices of a card, with their content clipped to it
  (canvas, k) {
    const corner = Radius.circular(ShareMeSize.radiusGroup);
    final edge = BorderSide(color: k.c.cardBorder);
    for (final (top, bottom) in const [(true, true), (true, false), (false, false), (false, true)]) {
      final radius = BorderRadius.vertical(top: top ? corner : Radius.zero, bottom: bottom ? corner : Radius.zero);
      k.decorated(
        canvas,
        _Kit.box,
        BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [k.c.cardTop, k.c.cardBottom]),
          borderRadius: radius,
          border: Border(
            left: edge,
            right: edge,
            top: top ? edge : BorderSide.none,
            bottom: bottom ? edge : BorderSide.none,
          ),
          boxShadow: bottom ? k.c.cardShadow : null,
        ),
      );
      canvas.save();
      canvas.clipRRect(radius.toRRect(_Kit.box));
      canvas.drawRect(const Rect.fromLTWH(36, 80, 184, 1), Paint()..color = k.c.line);
      k.text(canvas, '合同', ShareMeText.body.copyWith(color: k.c.ink), const Offset(40, 40));
      canvas.restore();
    }
  },
  // Pictures in rounded tiles and what lies on them
  (canvas, k) {
    for (final quality in const [FilterQuality.low, FilterQuality.medium]) {
      canvas.save();
      canvas.clipRRect(_Kit.tile);
      k.picture(canvas, _Kit.tileBox, quality: quality);
      k.picture(canvas, _Kit.tileBox, quality: quality, opacity: 0.5);
      canvas.restore();
    }
    canvas.drawRRect(_Kit.tile, Paint()..color = const Color(0x8C000000));
    canvas.save();
    canvas.clipRRect(_Kit.card);
    k.picture(canvas, _Kit.box);
    canvas.restore();
  },
  // Tiles with room for their badge
  (canvas, k) {
    final hole = Path.combine(
      PathOperation.difference,
      Path()..addRect(_Kit.tileBox.inflate(48)),
      Path()..addOval(Rect.fromCircle(center: _Kit.tileBox.bottomRight, radius: 12)),
    );
    canvas.save();
    canvas.clipPath(hole);
    k.decorated(canvas, _Kit.tileBox, smTileDecoration(k.c, radius: 15));
    k.decorated(canvas, _Kit.tileBox, BoxDecoration(gradient: ShareMeGradients.brand, borderRadius: BorderRadius.circular(15)));
    canvas.clipRRect(_Kit.tile);
    k.picture(canvas, _Kit.tileBox);
    canvas.restore();
    k.decorated(canvas, const Rect.fromLTWH(120, 40, 20, 20), BoxDecoration(color: k.c.ok, shape: BoxShape.circle));
    k.decorated(canvas, const Rect.fromLTWH(160, 40, 72, 72), const BoxDecoration(gradient: ShareMeGradients.brand, shape: BoxShape.circle));
  },
  // Settings: switches, radio marks, outlined fields
  (canvas, k) {
    final track = RRect.fromRectAndRadius(const Rect.fromLTWH(20, 100, 52, 32), const Radius.circular(16));
    canvas.drawRRect(track, Paint()..color = k.c.accent);
    canvas.drawRRect(track.deflate(1), k.stroke(2, k.c.ink3));
    k.decorated(canvas, const Rect.fromLTWH(44, 104, 24, 24), const ShapeDecoration(shape: StadiumBorder(), color: Colors.white));
    k.decorated(canvas, const Rect.fromLTWH(84, 104, 28, 24), const ShapeDecoration(shape: StadiumBorder(), color: Colors.white));
    canvas.drawCircle(const Offset(130, 116), 20, Paint()..color = k.c.ink.withValues(alpha: 0.08));
    canvas.drawCircle(const Offset(180, 116), 9, k.stroke(2, k.c.ink3));
    canvas.drawCircle(const Offset(220, 116), 5, Paint()..color = k.c.accent);
    k.decorated(
      canvas,
      const Rect.fromLTWH(20, 20, 120, 34),
      ShapeDecoration(
        color: k.c.selected,
        shape: StadiumBorder(side: BorderSide(color: k.c.accent)),
      ),
    );
    k.decorated(canvas, const Rect.fromLTWH(150, 20, 120, 48), smInsetDecoration(k.c));
    k.decorated(canvas, const Rect.fromLTWH(20, 140, 40, 40), smTileDecoration(k.c, radius: 13));
    k.decorated(canvas, const Rect.fromLTWH(80, 140, 200, 50), smCardDecoration(k.c));
  },
  // Dialogs and sheets
  (canvas, k) {
    canvas.drawRect(_Kit.whole, Paint()..color = const Color(0x66000000));
    canvas.drawShadow(Path()..addRRect(_Kit.card), const Color(0xFF000000), 6, false);
    k.decorated(
      canvas,
      _Kit.box,
      ShapeDecoration(
        color: k.c.sheet,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: k.c.line),
          borderRadius: BorderRadius.circular(ShareMeSize.radiusGroup),
        ),
      ),
    );
    canvas.save();
    canvas.clipRRect(_Kit.card);
    canvas.drawRRect(_Kit.card, Paint()..color = k.c.sheet);
    k.decorated(canvas, _Kit.box.deflate(14), smInsetDecoration(k.c));
    k.text(canvas, '发给谁 3 项', ShareMeText.title.copyWith(color: k.c.ink), const Offset(40, 40));
    canvas.drawCircle(_Kit.box.center, 90, Paint()..color = k.c.ink.withValues(alpha: 0.08));
    canvas.restore();
  },
  // The same while it fades in
  (canvas, k) {
    canvas.saveLayer(_Kit.whole, Paint()..color = const Color(0x80000000));
    k.decorated(canvas, _Kit.box, smCardDecoration(k.c));
    canvas.drawRRect(_Kit.card, Paint()..color = k.c.sheet);
    canvas.drawRRect(_Kit.card.deflate(0.5), k.stroke(1, k.c.line));
    canvas.save();
    canvas.clipRRect(_Kit.card);
    k.decorated(canvas, _Kit.box.deflate(14), smInsetDecoration(k.c));
    k.picture(canvas, _Kit.tileBox);
    k.text(canvas, '发给谁 3 项', ShareMeText.title.copyWith(color: k.c.ink), const Offset(40, 40));
    canvas.restore();
    canvas.restore();
  },
  // Primary and secondary buttons, a list that fades out above them
  (canvas, k) {
    k.decorated(
      canvas,
      const Rect.fromLTWH(20, 20, 180, 52),
      BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: k.c.buttonGradient),
        borderRadius: BorderRadius.circular(ShareMeSize.radiusButton),
        boxShadow: [BoxShadow(color: ShareMeGradients.glow.withValues(alpha: 0.3), blurRadius: 18, spreadRadius: -6, offset: const Offset(0, 8))],
      ),
    );
    k.decorated(
      canvas,
      const Rect.fromLTWH(20, 90, 180, 52),
      ShapeDecoration(
        color: k.c.group,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: k.c.buttonEdge),
          borderRadius: BorderRadius.circular(ShareMeSize.radiusButton),
        ),
      ),
    );
    final icon = LucideIcons.check;
    k.text(
      canvas,
      String.fromCharCode(icon.codePoint),
      TextStyle(fontFamily: icon.fontFamily, package: icon.fontPackage, fontSize: 24, color: k.c.accent),
      const Offset(220, 100),
    );
    canvas.saveLayer(_Kit.whole, Paint());
    k.decorated(canvas, _Kit.box, smCardDecoration(k.c));
    canvas.drawRect(
      _Kit.whole,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = _Kit.vertical(_Kit.whole, const [Color(0xFF000000), Color(0x00000000)]),
    );
    canvas.restore();
  },
  // Sending: tilted pictures
  (canvas, k) {
    const r = Rect.fromLTWH(80, 30, 120, 120);
    for (final angle in const [0.0, 0.16, -0.17]) {
      canvas.save();
      canvas.rotate(angle);
      k.decorated(
        canvas,
        r,
        BoxDecoration(
          color: k.c.bgTop,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: k.dark ? 0.5 : 0.18),
              blurRadius: 24,
              spreadRadius: -5,
              offset: const Offset(0, 10),
            ),
          ],
        ),
      );
      canvas.clipRRect(RRect.fromRectAndRadius(r.deflate(3), const Radius.circular(16)));
      k.picture(canvas, r.deflate(3));
      canvas.restore();
    }
  },
  // Sending: the line between the two devices
  (canvas, k) {
    final wave = Path()
      ..moveTo(10, 100)
      ..cubicTo(100, 70, 200, 130, 290, 100);
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 7;
    canvas.drawPath(wave, pen..color = k.c.line);
    canvas.drawPath(wave, pen..shader = _Kit.vertical(_Kit.whole, k.c.buttonGradient));
    pen.shader = null;
    canvas.drawPath(
      wave,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 7
        ..color = k.c.accent.withValues(alpha: 0.4)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    const at = Offset(150, 100);
    canvas.drawCircle(at, 18, Paint()..shader = _Kit.round(Rect.fromCircle(center: at, radius: 18), k.c.accent));
    canvas.drawCircle(at, 7, Paint()..color = k.c.accent);
    canvas.drawRRect(_Kit.tile.inflate(8), k.stroke(1.5, k.c.accent.withValues(alpha: 0.3)));
    canvas.drawRRect(
      _Kit.tile,
      Paint()
        ..color = k.c.accent.withValues(alpha: 0.4)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
  },
];
