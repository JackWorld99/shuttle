import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localsend_app/provider/animation_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/window_dimensions_provider.dart';
import 'package:localsend_app/util/coalesced_save.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/native/tray_helper.dart';
import 'package:localsend_app/util/shareme_diagnostics.dart';
import 'package:localsend_app/widget/shareme/receive_popup.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:window_manager/window_manager.dart';

final _logger = Logger('WindowWatcher');

class WindowWatcher extends StatefulWidget {
  final Widget child;

  const WindowWatcher({
    required this.child,
    super.key,
  });

  @override
  State<WindowWatcher> createState() => _WindowWatcherState();

  static Future<void> closeWindow(BuildContext context) async {
    final state = context.findAncestorStateOfType<_WindowWatcherState>();
    await state?.onWindowClose();
  }
}

class _WindowWatcherState extends State<WindowWatcher> with WindowListener, Refena {
  static WindowDimensionsController? _dimensionsController;
  static Stopwatch s = Stopwatch();

  WindowDimensionsController _ensureDimensionsProvider() => ref.watch(windowDimensionProvider);

  @override
  Widget build(BuildContext context) {
    _dimensionsController ??= _ensureDimensionsProvider();
    s.start();
    return widget.child;
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    if (checkPlatformIsDesktop()) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          // always handle close actions manually
          await windowManager.setPreventClose(true);
        } catch (e) {
          _logger.warning('Failed to set prevent close', e);
        }
      });
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  //Linux alternative for onWindowMoved and onWindowResized
  @override
  Future<void> onWindowMove() async {
    if (checkPlatform([TargetPlatform.linux]) && s.elapsedMilliseconds >= 600) {
      s.reset();
      final windowOffset = await windowManager.getPosition();
      final windowSize = await windowManager.getSize();
      await _dimensionsController?.storeDimensions(windowOffset: windowOffset, windowSize: windowSize);
    }
  }

  @override
  Future<void> onWindowMoved() async {
    if (SmPopupWindow.active) return; // Shuttle: don't store the popup's position as the main window's
    final windowOffset = await windowManager.getPosition();
    await _dimensionsController?.storePosition(windowOffset: windowOffset);
  }

  @override
  Future<void> onWindowResized() async {
    if (SmPopupWindow.active) return; // Shuttle: don't store the popup's size as the main window's
    final windowSize = await windowManager.getSize();
    await _dimensionsController?.storeSize(windowSize: windowSize);
  }

  @override
  Future<void> onWindowClose() async {
    // Shuttle: closing the bottom-right popup = "decide later" (neither declines nor quits the app)
    if (await SmPopupWindow.closeRequested()) return;
    final windowOffset = await windowManager.getPosition();
    final windowSize = await windowManager.getSize();
    await _dimensionsController?.storeDimensions(windowOffset: windowOffset, windowSize: windowSize);

    if (!checkPlatformIsDesktop()) {
      return;
    }

    try {
      if (ref.read(settingsProvider).minimizeToTray) {
        await hideToTray();
      } else {
        await destroyTray();
        CoalescedSave.flushAllBeforeExit(); // Shuttle: write out pending history saves first
        markCleanExit('window closed');
        exit(0);
      }
    } catch (e) {
      _logger.warning('Failed to close window', e);
    }
  }

  @override
  void onWindowFocus() {
    // Shuttle: the user is back in the window, so the tray reminder dot is no longer needed
    if (!SmPopupWindow.active) {
      unawaited(setTrayReminder(false));
    }
    // call set state according to window_manager README
    setState(() {});
  }

  @override
  void onWindowMinimize() {
    ref.notifier(sleepProvider).setState((_) => true);
  }

  @override
  void onWindowRestore() {
    ref.notifier(sleepProvider).setState((_) => false);
  }
}
