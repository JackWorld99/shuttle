import 'package:flutter/widgets.dart';
import 'package:localsend_app/pages/shareme_pair_host_page.dart';
import 'package:localsend_app/pages/shareme_pair_nearby_page.dart';
import 'package:localsend_app/pages/shareme_pair_scan_page.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_isolates/model/device.dart';

/// Which page to open to verify one of "My devices".
enum VerifyRoute {
  /// The phone scans the PC's QR code.
  scan,

  /// The PC shows a QR code (a phone scans it, or another PC clicks "Pair" under "Nearby").
  host,

  /// The PC pairs with another PC that is online nearby.
  nearby,
}

/// Shuttle: an unverified device in "My devices" (e.g. one only added with "Add") gets no auto-accept and no auto-copy.
/// The UI offers a "Verify" entry that runs the normal pairing flow (both sides compare 12 digits), which leaves a
/// verification record. Possible pairs: phone ↔ PC and PC ↔ PC. Phone ↔ phone, or a web / command-line peer, can't pair:
/// returns null (and the UI shows no "Verify").
/// An unknown [peerType] (never seen online) counts as a PC: devices that can be added on a phone are mostly PCs.
VerifyRoute? verifyRouteFor({required bool thisIsDesktop, required DeviceType? peerType, required bool peerOnline}) {
  if (peerType == DeviceType.web || peerType == DeviceType.headless || peerType == DeviceType.server) return null;
  if (!thisIsDesktop) return peerType == DeviceType.mobile ? null : VerifyRoute.scan;
  if (peerType == DeviceType.desktop && peerOnline) return VerifyRoute.nearby;
  return VerifyRoute.host;
}

/// The page for [verifyRouteFor]; null when it can't pair. [online] is the device as currently seen in "Nearby" (null when offline).
Widget Function()? verifyPageFor({required DeviceType? peerType, required Device? online}) {
  final route = verifyRouteFor(thisIsDesktop: checkPlatformIsDesktop(), peerType: online?.deviceType ?? peerType, peerOnline: online?.ip != null);
  return switch (route) {
    VerifyRoute.scan => () => const SmPairScanPage(),
    VerifyRoute.host => () => const SmPairHostPage(),
    VerifyRoute.nearby => () => SmPairNearbyPage(device: online!),
    null => null,
  };
}
