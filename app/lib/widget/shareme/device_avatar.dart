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
/// - [verified]: checked during QR pairing → small green check mark in the bottom-right corner (replaces the old "verified" text).
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

  /// Ring around the check mark = the background behind the avatar, so it looks inset into the corner. Defaults to the card color.
  final Color? badgeRing;

  const DeviceAvatar({
    this.deviceType,
    required this.size,
    this.mine = false,
    this.verified = false,
    this.offline = false,
    this.icon,
    this.badgeRing,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final warm = mine && !offline;
    final tile = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: warm ? ShareMeGradients.brand : null,
        color: warm ? null : c.tonal,
        borderRadius: BorderRadius.circular(size * 0.32),
        boxShadow: warm && size >= 30
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
      child: Icon(
        icon ?? deviceTypeIcon(deviceType),
        size: size * 0.5,
        color: warm ? Colors.white : (offline ? c.ink3 : c.ink2),
      ),
    );
    if (!verified) return tile;
    final badge = (size * 0.4).clamp(12.0, 28.0);
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          tile,
          Positioned(
            right: -badge * 0.24,
            bottom: -badge * 0.24,
            child: Container(
              width: badge,
              height: badge,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: offline ? c.ink3 : c.ok,
                shape: BoxShape.circle,
                border: Border.all(color: badgeRing ?? c.group, width: (badge * 0.13).clamp(1.5, 3.0)),
              ),
              child: Icon(LucideIcons.check, size: badge * 0.52, color: Colors.white),
            ),
          ),
        ],
      ),
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
