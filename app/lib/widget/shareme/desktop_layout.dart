import 'package:flutter/widgets.dart';
import 'package:localsend_app/util/native/platform_check.dart';

/// Shuttle desktop layout.
///
/// A wide enough window gets three columns: vertical nav 76 | device column 300 | content (drop zone, just received, recent).
/// The threshold is in Flutter logical pixels: 76 + 300 + at least ~340 for the content ≈ 720.
/// The design's original 900 was too strict: at 125% display scaling a 1124 px wide window is only 899 logical pixels.
/// Narrower windows keep the phone layout.
const shareMeDesktopMinWidth = 720.0;

bool useDesktopLayout(BuildContext context) {
  return checkPlatformIsDesktop() && MediaQuery.sizeOf(context).width >= shareMeDesktopMinWidth;
}

/// True while files are being dragged over the window: the home drop zone then shows a solid border and a darker fill
/// (updated by HomePage's DropTarget).
final shareMeDragActive = ValueNotifier<bool>(false);
