import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/widget/shareme/seal.dart' show deviceTypeIcon;
import 'package:localsend_isolates/model/device.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Device avatar (replaces the earlier device seal).
///
/// - "My devices": the app icon's warm gradient + a white device icon; offline it falls back to a light gray tile and gray icon.
/// - Unknown devices: light gray tile + gray device icon.
/// - [verified]: checked during pairing → small green check mark in the bottom-right corner, while the device is online.
///
/// The avatar only helps people see what kind of device it is and whether it is theirs; security comes from the certificate
/// fingerprint, not the avatar.
class DeviceAvatar extends StatelessWidget {
  final DeviceType? deviceType;
  final double size;
  final bool mine;
  final bool verified;
  final bool offline;

  /// Icon shown instead of the device type (e.g. the plus of "Add device")
  final IconData? icon;

  const DeviceAvatar({
    this.deviceType,
    required this.size,
    this.mine = false,
    this.verified = false,
    this.offline = false,
    this.icon,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final warm = mine && !offline;
    // Coming online warms it up instead of switching
    final tile = AnimatedContainer(
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeInOut,
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: !warm
          ? smTileDecoration(c, radius: size * 0.32)
          : BoxDecoration(
              gradient: ShareMeGradients.brand,
              borderRadius: BorderRadius.circular(size * 0.32),
              boxShadow: size >= 30
                  ? [
                      BoxShadow(
                        color: ShareMeGradients.glow.withValues(alpha: 0.32),
                        blurRadius: size * 0.36,
                        spreadRadius: -size * 0.18,
                        offset: Offset(0, size * 0.16),
                      ),
                    ]
                  : null,
            ),
      child: Stack(
        alignment: Alignment.center,
        fit: StackFit.expand,
        children: [
          // Glossy top edge, like the app icon
          if (warm && size >= 30)
            Positioned(
              left: size * 0.05,
              right: size * 0.05,
              top: size * 0.03,
              height: size * 0.44,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(size * 0.28),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.white.withValues(alpha: 0.34), Colors.white.withValues(alpha: 0)],
                  ),
                ),
              ),
            ),
          Center(
            child: Icon(
              icon ?? deviceTypeIcon(deviceType),
              size: size * 0.5,
              color: warm ? Colors.white : (offline ? c.ink3 : c.ink2),
            ),
          ),
        ],
      ),
    );
    // Nothing to vouch for while the device is away
    if (!verified || offline) return tile;
    final badge = (size * 0.4).clamp(13.0, 28.0);
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipPath(
            clipper: BadgeHole(size: size, badge: badge),
            child: tile,
          ),
          BadgeHole.positioned(
            size: size,
            badge: badge,
            child: CheckBadge(size: badge, color: c.ok),
          ),
        ],
      ),
    );
  }
}

/// Cuts room for a round badge out of the bottom right corner of a tile, so whatever is behind shows around the badge. (A ring in
/// the background's color only matches on a plain background, and the cards are translucent.)
class BadgeHole extends CustomClipper<Path> {
  final double size;
  final double badge;

  const BadgeHole({required this.size, required this.badge});

  /// How far the badge sticks out of the tile
  static double _out(double badge) => badge * 0.2;

  static Widget positioned({required double size, required double badge, required Widget child}) => Positioned(
    right: -_out(badge),
    bottom: -_out(badge),
    width: badge,
    height: badge,
    child: child,
  );

  @override
  Path getClip(Size tile) {
    final center = Offset(size + _out(badge) - badge / 2, size + _out(badge) - badge / 2);
    final gap = (badge * 0.12).clamp(1.5, 3.0);
    return Path.combine(
      PathOperation.difference,
      Path()..addRect((Offset.zero & tile).inflate(size)), // leaves the tile's shadow alone
      Path()..addOval(Rect.fromCircle(center: center, radius: badge / 2 + gap)),
    );
  }

  @override
  bool shouldReclip(BadgeHole old) => old.size != size || old.badge != badge;
}

/// An avatar whose check mark pops in when [checked] turns true.
class CheckedAvatar extends StatelessWidget {
  final double size;
  final bool checked;
  final Widget child;

  const CheckedAvatar({required this.size, required this.checked, required this.child, super.key});

  @override
  Widget build(BuildContext context) {
    final badge = (size * 0.4).clamp(15.0, 28.0);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: checked ? 1 : 0),
      duration: const Duration(milliseconds: 420),
      curve: checked ? Curves.easeOutBack : Curves.easeIn,
      child: child,
      builder: (context, v, child) => v <= 0
          ? child!
          : SizedBox.square(
              dimension: size,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  ClipPath(
                    clipper: BadgeHole(size: size, badge: badge * v),
                    child: child,
                  ),
                  BadgeHole.positioned(
                    size: size,
                    badge: badge,
                    child: Transform.scale(
                      scale: v,
                      child: CheckBadge(size: badge, color: context.sm.ok),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

/// The round check mark on an avatar.
class CheckBadge extends StatelessWidget {
  final double size;
  final Color color;

  const CheckBadge({required this.size, required this.color, super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Icon(LucideIcons.check, size: size * 0.6, color: Colors.white),
    );
  }
}

/// Favorites carry no device type (LocalSend stores only name, address and fingerprint), so an offline "My devices" entry lacks one.
/// Remember the types seen so far (persisted in settings, kept across restarts) so the avatar icon stays right while offline.
final Map<String, DeviceType> _knownTypes = {};
Future<void> Function(Map<String, String>)? _saveKnownTypes;

/// Called at app start: loads the stored types and saves them back whenever they change.
void initKnownDeviceTypes(Map<String, String> stored, Future<void> Function(Map<String, String>) save) {
  for (final e in stored.entries) {
    final type = DeviceType.values.firstWhereOrNull((t) => t.name == e.value);
    if (type != null) _knownTypes[e.key] = type;
  }
  _saveKnownTypes = save;
}

void rememberDeviceType(String fingerprint, DeviceType type) {
  if (_knownTypes[fingerprint] == type) return;
  _knownTypes[fingerprint] = type;
  final save = _saveKnownTypes;
  if (save != null) unawaited(save({for (final e in _knownTypes.entries) e.key: e.value.name}));
}

DeviceType? knownDeviceType(String fingerprint) => _knownTypes[fingerprint];
