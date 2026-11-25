import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/native/win_window.dart';
import 'package:logging/logging.dart';
import 'package:window_manager/window_manager.dart';

final _logger = Logger('WindowBrightnessWatcher');

class WindowBrightnessWatcher extends StatefulWidget {
  final Widget child;

  const WindowBrightnessWatcher({
    required this.child,
    super.key,
  });

  @override
  State<WindowBrightnessWatcher> createState() => _WindowBrightnessWatcherState();
}

class _WindowBrightnessWatcherState extends State<WindowBrightnessWatcher> with WindowListener {
  Brightness? _brightness;
  bool _highContrast = false;

  @override
  void initState() {
    super.initState();
    if (checkPlatform([TargetPlatform.windows])) windowManager.addListener(this);
  }

  @override
  void dispose() {
    if (checkPlatform([TargetPlatform.windows])) windowManager.removeListener(this);
    super.dispose();
  }

  // Shuttle: when the colors of the system change, the runner gives the title bar the system's theme again (win32_window.cpp)
  @override
  void onWindowFocus() {
    final brightness = _brightness;
    if (brightness != null) unawaited(_setBrightness(brightness));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final brightness = Theme.of(context).brightness;
    final highContrast = MediaQuery.highContrastOf(context);
    if (!checkPlatform([TargetPlatform.linux, TargetPlatform.windows]) || (brightness == _brightness && highContrast == _highContrast)) {
      return;
    }

    _brightness = brightness;
    _highContrast = highContrast;
    unawaited(_setBrightness(brightness));
  }

  Future<void> _setBrightness(Brightness brightness) async {
    try {
      // Shuttle: on Windows the title bar continues the top of the backdrop, in the theme of the app. window_manager's setBrightness
      // can't make it dark while the system is light.
      if (checkPlatform([TargetPlatform.windows])) {
        final dark = brightness == Brightness.dark;
        final colors = dark ? ShareMeColors.dark : ShareMeColors.light;
        (await WinWindow.main())?.setTitleBar(dark: dark, color: _highContrast ? null : colors.bgTop);
        return;
      }
      await windowManager.setBrightness(brightness);
    } catch (e) {
      _logger.warning('Failed to set window brightness', e);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
