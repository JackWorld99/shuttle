import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';

/// A card in the app's look ([smCardDecoration]): the content is clipped to the rounded corners and sits on a transparent
/// [Material], so ink ripples and list tiles work on top of the card's tint.
class SmCard extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;

  const SmCard({required this.child, this.radius = ShareMeSize.radiusGroup, this.padding, super.key});

  @override
  Widget build(BuildContext context) {
    final padding = this.padding;
    return DecoratedBox(
      decoration: smCardDecoration(context.sm, radius: radius),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Material(
          type: MaterialType.transparency,
          child: padding == null ? child : Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// A small neutral tile with an icon, the leading element of a list row (40 px, as wide as a thumbnail or a device avatar there).
class SmIconTile extends StatelessWidget {
  final IconData icon;

  /// Icon color, and a tile color for special cases (the amber warning)
  final Color? color;
  final Color? background;

  const SmIconTile({required this.icon, this.color, this.background, super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return Container(
      width: 40,
      height: 40,
      decoration: smTileDecoration(c, radius: 13, color: background),
      alignment: Alignment.center,
      child: Icon(icon, size: 19, color: color ?? c.ink2),
    );
  }
}

/// One row of a card whose rows are built one at a time (the history list): draws the slice of the card that belongs to row
/// [index] of [count], so the rows together look like a single [SmCard] while only the visible ones exist.
class SmCardSlice extends StatelessWidget {
  final int index;
  final int count;
  final Widget child;

  const SmCardSlice({required this.index, required this.count, required this.child, super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final first = index == 0;
    final last = index == count - 1;
    const corner = Radius.circular(ShareMeSize.radiusGroup);
    final radius = BorderRadius.vertical(top: first ? corner : Radius.zero, bottom: last ? corner : Radius.zero);
    final edge = BorderSide(color: c.cardBorder);
    Color tint(int row) => Color.lerp(c.cardTop, c.cardBottom, row / count)!;
    if (!first && !last) {
      // Most rows: plain rectangles, nothing to round off or to clip
      return CustomPaint(
        painter: _SlicePainter(tint(index), tint(index + 1), c.cardBorder),
        child: Material(type: MaterialType.transparency, child: child),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [tint(index), tint(index + 1)]),
        borderRadius: radius,
        border: Border(
          left: edge,
          right: edge,
          top: first ? edge : BorderSide.none,
          bottom: last ? edge : BorderSide.none,
        ),
        // Only below the last row: the other rows are followed by the next row of the same card
        boxShadow: last ? c.cardShadow : null,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Material(type: MaterialType.transparency, child: child),
      ),
    );
  }
}

class _SlicePainter extends CustomPainter {
  final Color top;
  final Color bottom;
  final Color edge;

  const _SlicePainter(this.top, this.bottom, this.edge);

  @override
  void paint(Canvas canvas, Size size) {
    final whole = Offset.zero & size;
    canvas.drawRect(
      whole,
      Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [top, bottom]).createShader(whole),
    );
    final line = Paint()..color = edge;
    canvas.drawRect(Rect.fromLTWH(0, 0, 1, size.height), line);
    canvas.drawRect(Rect.fromLTWH(size.width - 1, 0, 1, size.height), line);
  }

  @override
  bool shouldRepaint(_SlicePainter old) => old.top != top || old.bottom != bottom || old.edge != edge;
}
