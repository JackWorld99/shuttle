import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/shareme_format.dart';
import 'package:localsend_app/widget/shareme/film_strip.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// What is being sent, as a small fan of up to three pictures (or file tiles) with the number of items. Fans out when it appears.
class ContentStack extends StatelessWidget {
  final List<FilmFrame> frames;
  final double size;

  /// Number on the badge, the length of [frames] by default
  final int? count;

  const ContentStack({required this.frames, required this.size, this.count, super.key});

  /// Room the fan needs around a card of [size]
  static Size boxFor(double size) => Size(size * 1.6, size * 1.16);

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final box = boxFor(size);
    final shown = frames.take(3).toList();
    final total = count ?? frames.length;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final radius = size * 0.15;

    Widget card(FilmFrame frame) => DecoratedBox(
      decoration: BoxDecoration(
        color: Color.alphaBlend(c.cardTop, c.bgTop),
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.5 : 0.18),
            blurRadius: size * 0.2,
            spreadRadius: -size * 0.04,
            offset: Offset(0, size * 0.08),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: FileThumb(frame: frame, size: size - 6, radius: radius - 2),
      ),
    );

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 520),
      curve: Curves.easeOutCubic,
      builder: (context, t, _) {
        // Back to front: right card, left card, front card
        Widget placed(int i) {
          if (shown.length == 1) return card(shown[0]);
          final (dx, angle, scale) = switch (i) {
            0 => (0.0, -2.0, 1.0),
            1 => (0.21, 9.0, 0.9),
            _ => (-0.21, -10.0, 0.88),
          };
          return Transform.translate(
            offset: Offset(size * dx * t, i == 0 ? 0 : size * 0.02 * t),
            child: Transform.rotate(
              angle: angle * t * math.pi / 180,
              child: Transform.scale(scale: 1 - (1 - scale) * t, child: card(shown[i])),
            ),
          );
        }

        return SizedBox.fromSize(
          size: box,
          child: Opacity(
            opacity: t.clamp(0.0, 1.0),
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                for (var i = shown.length - 1; i >= 0; i--) placed(i),
                if (total > 1)
                  Positioned(
                    right: box.width / 2 - size / 2 - 8,
                    top: box.height / 2 - size / 2 - 8,
                    child: Transform.scale(
                      scale: t,
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 28),
                        height: 28,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          gradient: ShareMeGradients.brand,
                          borderRadius: BorderRadius.circular(ShareMeSize.radiusPill),
                          border: Border.all(color: c.bgTop, width: 2.5),
                        ),
                        child: Text(
                          '$total',
                          style: ShareMeText.data.copyWith(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700, height: 1),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// What a batch contains, almost without words: an icon and a number per kind, then the size. A single file shows its name.
class ContentSummary extends StatelessWidget {
  final List<(String name, FileType type)> files;
  final int bytes;
  final WrapAlignment alignment;
  final double fontSize;

  /// A piece of text or a link rather than files
  final bool message;

  const ContentSummary({
    required this.files,
    required this.bytes,
    this.alignment = WrapAlignment.start,
    this.fontSize = 14,
    this.message = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final style = ShareMeText.body.copyWith(color: c.ink2, fontSize: fontSize, height: 1.3);
    if (message) return Text(t.shareme.home.text, style: style);
    final size = formatSize(bytes);
    final photos = files.where((f) => f.$2 == FileType.image).length;
    final videos = files.where((f) => f.$2 == FileType.video).length;
    final others = files.length - photos - videos;

    if (files.length == 1 && others == 1) {
      return Text(
        '${files.first.$1} · $size',
        style: style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: alignment == WrapAlignment.center ? TextAlign.center : TextAlign.start,
      );
    }
    Widget kind(IconData icon, int n) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: fontSize + 3, color: c.ink2),
        const SizedBox(width: 5),
        Text(
          '$n',
          style: style.copyWith(color: c.ink, fontWeight: FontWeight.w600),
        ),
      ],
    );
    final words = [
      if (photos > 0) t.shareme.receive.photos(n: photos),
      if (videos > 0) t.shareme.receive.videos(n: videos),
      if (others > 0) t.shareme.receive.files(n: others),
      size,
    ].join(', ');
    return Semantics(
      label: words,
      excludeSemantics: true,
      child: Wrap(
        alignment: alignment,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 4,
        children: [
          if (photos > 0) kind(LucideIcons.image, photos),
          if (videos > 0) kind(LucideIcons.clapperboard, videos),
          if (others > 0) kind(LucideIcons.file, others),
          Text(size, style: style),
        ],
      ),
    );
  }
}

/// Received pictures as one block: one large, two halves, or a grid of four whose last tile says how many more there are. Tapping that
/// one unfolds the rest.
class MediaMosaic extends StatefulWidget {
  final List<FilmFrame> frames;
  final double radius;
  final void Function(int index)? onTap;

  const MediaMosaic({required this.frames, this.radius = ShareMeSize.radiusGroup, this.onTap, super.key});

  @override
  State<MediaMosaic> createState() => _MediaMosaicState();
}

class _MediaMosaicState extends State<MediaMosaic> {
  static const _gap = 3.0;
  static const _folded = 4;

  /// How many more each tap on "+N" shows (all of them at once would mean decoding hundreds of pictures)
  static const _step = 60;

  int _shown = _folded;

  Widget _tile(int i, {required bool last}) {
    final frames = widget.frames;
    final more = last ? frames.length - i - 1 : 0;
    final onTap = more > 0 ? () => setState(() => _shown = _shown == _folded ? _step : _shown + _step) : () => widget.onTap?.call(i);
    return LayoutBuilder(
      builder: (context, box) {
        Widget content = FileThumb(
          frame: frames[i],
          size: math.max(box.maxWidth, box.maxHeight),
          radius: 0,
          fit: Size(box.maxWidth, box.maxHeight),
        );
        if (more > 0) {
          content = Stack(
            fit: StackFit.expand,
            children: [
              content,
              const ColoredBox(color: Color(0x8C000000)),
              Center(
                child: Text(
                  '+$more',
                  style: ShareMeText.data.copyWith(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w600, height: 1),
                ),
              ),
            ],
          );
        }
        if (widget.onTap == null) return content;
        return Semantics(
          container: true,
          button: true,
          label: more > 0 ? '+$more' : frames[i].fileName,
          onTap: onTap,
          child: ExcludeSemantics(
            child: GestureDetector(onTap: onTap, child: content),
          ),
        );
      },
    );
  }

  Widget _mosaic(int n) {
    Widget tile(int i) => _tile(i, last: i == n - 1);
    final Widget grid = switch (n) {
      1 => tile(0),
      2 => Row(
        children: [
          Expanded(child: tile(0)),
          const SizedBox(width: _gap),
          Expanded(child: tile(1)),
        ],
      ),
      3 => Row(
        children: [
          Expanded(flex: 3, child: tile(0)),
          const SizedBox(width: _gap),
          Expanded(
            flex: 2,
            child: Column(
              children: [
                Expanded(child: tile(1)),
                const SizedBox(height: _gap),
                Expanded(child: tile(2)),
              ],
            ),
          ),
        ],
      ),
      _ => Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: tile(0)),
                const SizedBox(width: _gap),
                Expanded(child: tile(1)),
              ],
            ),
          ),
          const SizedBox(height: _gap),
          Expanded(
            child: Row(
              children: [
                Expanded(child: tile(2)),
                const SizedBox(width: _gap),
                Expanded(child: tile(3)),
              ],
            ),
          ),
        ],
      ),
    };
    return AspectRatio(aspectRatio: n == 2 ? 2 : 4 / 3, child: grid);
  }

  Widget _unfolded(int n) => LayoutBuilder(
    builder: (context, box) {
      final columns = box.maxWidth >= 460 ? 4 : 3;
      // A hair less, so rounding never pushes the last tile of a row to the next one
      final size = (box.maxWidth - _gap * (columns - 1)) / columns - 0.01;
      return Wrap(
        spacing: _gap,
        runSpacing: _gap,
        children: [
          for (var i = 0; i < n; i++)
            SizedBox.square(
              dimension: size,
              child: _tile(i, last: i == n - 1),
            ),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final n = math.min(_shown, widget.frames.length);
    if (n == 0) return const SizedBox.shrink();
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(widget.radius), boxShadow: ShareMeColors.light.cardShadow),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: AnimatedSize(
          duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 320),
          curve: Curves.easeInOutCubicEmphasized,
          alignment: Alignment.topCenter,
          child: _shown == _folded ? _mosaic(n) : _unfolded(n),
        ),
      ),
    );
  }
}
