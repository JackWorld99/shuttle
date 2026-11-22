import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Pairing check pattern (formerly the "device seal").
///
/// Device lists now use [DeviceAvatar] (device_avatar.dart); this pattern is only used on the QR pairing check screen:
/// both sides show the same pattern and the same digits, so they can be compared at a glance. It follows the new theme:
/// a warm-gradient rounded square + a white pattern, no inner frame.
///
/// The pattern comes from the fingerprint: a 6×6 grid mirrored left/right, so 3 columns × 6 rows = 18 bits decide it.
/// The pattern only helps the eye compare; security comes from the digits and the certificate fingerprint.
class DeviceSeal extends StatelessWidget {
  final String fingerprint;
  final double size;

  /// "Paper" color: strokes and inner frame take the color of the background behind the seal, so they look carved. Defaults to group.
  final Color? paper;

  /// Grayed out while offline (ink3 at 50% opacity).
  final bool offline;

  const DeviceSeal({
    required this.fingerprint,
    required this.size,
    this.paper,
    this.offline = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.square(size),
        painter: _SealPainter(
          grid: sealGrid(fingerprint),
          ink: offline ? c.ink3.withValues(alpha: 0.5) : null,
          paper: offline ? (paper ?? c.group) : Colors.white,
        ),
      ),
    );
  }
}

/// Computes the 6 rows × 3 columns of on/off cells from the fingerprint (left half; the right half is mirrored).
///
/// The fingerprint is hashed with SHA-256 and the first 18 bits are used: LocalSend's fingerprint is the certificate hash (hex)
/// in encrypted mode but a random string in unencrypted mode, so hashing it again ensures evenly distributed bits and enough length.
List<List<bool>> sealGrid(String fingerprint) {
  final digest = sha256.convert(utf8.encode(fingerprint.toUpperCase())).bytes;
  var bits = (digest[0] << 16) | (digest[1] << 8) | digest[2]; // 24 bits, the first 18 are used
  final grid = List.generate(6, (_) => List.filled(3, false));
  var on = 0;
  for (var y = 0; y < 6; y++) {
    for (var x = 0; x < 3; x++) {
      final v = (bits & 0x800000) != 0;
      bits = (bits << 1) & 0xFFFFFF;
      grid[y][x] = v;
      if (v) on++;
    }
  }
  // A nearly empty pattern is hard to recognize: with too few cells on, add a fixed stroke
  if (on < 7) {
    grid[1][1] = grid[2][0] = grid[3][2] = grid[4][1] = true;
  }
  return grid;
}

class _SealPainter extends CustomPainter {
  final List<List<bool>> grid;

  /// null = the warm gradient of the app icon
  final Color? ink;
  final Color paper;

  _SealPainter({required this.grid, required this.ink, required this.paper});

  bool _on(int x, int y) {
    if (x < 0 || y < 0 || x >= 6 || y >= 6) return false;
    return x < 3 ? grid[y][x] : grid[y][5 - x];
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Draw in the design's 100×100 coordinates, then scale everything
    final s = size.width / 100;
    canvas.save();
    canvas.scale(s);

    // Background: corner radius = edge × 0.3 (same as the device avatar), warm gradient; gray while offline
    const rect = Rect.fromLTWH(2, 2, 96, 96);
    final fill = Paint();
    if (ink != null) {
      fill.color = ink!;
    } else {
      fill.shader = ShareMeGradients.brand.createShader(rect);
    }
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(30)), fill);

    // Strokes: a dot for every cell that is on, joined by thick lines to on-cells to the right and below (like seal-carving cuts)
    const pad = 15.0;
    const cell = 70.0 / 6;
    final stroke = Paint()
      ..color = paper
      ..style = PaintingStyle.stroke
      ..strokeWidth = cell * 0.56
      ..strokeCap = StrokeCap.round;
    final dot = Paint()..color = paper;
    for (var y = 0; y < 6; y++) {
      for (var x = 0; x < 6; x++) {
        if (!_on(x, y)) continue;
        final cx = pad + x * cell + cell / 2;
        final cy = pad + y * cell + cell / 2;
        canvas.drawCircle(Offset(cx, cy), cell * 0.28, dot);
        if (_on(x + 1, y)) canvas.drawLine(Offset(cx, cy), Offset(cx + cell, cy), stroke);
        if (_on(x, y + 1)) canvas.drawLine(Offset(cx, cy), Offset(cx, cy + cell), stroke);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SealPainter old) => old.ink != ink || old.paper != paper || !identical(old.grid, grid);
}

/// "Empty slot" for an unpaired device: no seal, just a dashed ink3 rounded square (1.5 stroke) with the device type icon inside.
class BlankSeal extends StatelessWidget {
  final double size;
  final DeviceType? deviceType;

  /// Icon shown instead of the device type (e.g. the plus of "Pair new device" on the settings page)
  final IconData? icon;

  const BlankSeal({required this.size, this.deviceType, this.icon, super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return CustomPaint(
      size: Size.square(size),
      painter: DashedRRectPainter(color: c.ink3, radius: size * 0.27),
      child: SizedBox.square(
        dimension: size,
        child: Icon(icon ?? deviceTypeIcon(deviceType), size: size * 0.42, color: c.ink2),
      ),
    );
  }
}

IconData deviceTypeIcon(DeviceType? type) {
  return switch (type) {
    DeviceType.mobile => LucideIcons.smartphone,
    DeviceType.desktop => LucideIcons.laptop,
    DeviceType.web => LucideIcons.globe,
    DeviceType.headless || DeviceType.server => LucideIcons.server,
    null => LucideIcons.monitor,
  };
}

/// Dashed rounded rectangle: the empty seal slot, and the desktop drop zone (2 px).
class DashedRRectPainter extends CustomPainter {
  final Color color;
  final double radius;
  final double strokeWidth;

  DashedRRectPainter({required this.color, required this.radius, this.strokeWidth = 1.5});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    final inset = strokeWidth / 2;
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(inset, inset, size.width - strokeWidth, size.height - strokeWidth), Radius.circular(radius)));
    final dash = strokeWidth * 8 / 3;
    final gap = strokeWidth * 2;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + dash), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(DashedRRectPainter old) => old.color != color || old.radius != radius || old.strokeWidth != strokeWidth;
}
