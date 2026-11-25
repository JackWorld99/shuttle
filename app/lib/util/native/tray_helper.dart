import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localsend_app/gen/assets.gen.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/animation_provider.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/native/win_window.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:tray_manager/tray_manager.dart' as tm;
import 'package:window_manager/window_manager.dart';

final _logger = Logger('TrayHelper');

enum TrayEntry {
  sendClipboard, // Shuttle: send the clipboard to my devices
  open,
  close,
}

Future<void> initTray() async {
  if (!checkPlatformHasTray()) {
    return;
  }
  try {
    if (checkPlatform([TargetPlatform.windows])) {
      await tm.trayManager.setIcon(Assets.img.logo);
    } else if (checkPlatform([TargetPlatform.macOS])) {
      // The menu bar icon will created in AppDelegate.swift
      return;
    } else if (checkPlatform([TargetPlatform.linux])) {
      String icon;
      if (await File('/.flatpak-info').exists()) {
        // Icon for Flatpak, which must exist in /app/share/icons/hicolor/*x*/apps.
        icon = 'org.localsend.localsend_app-tray';
      } else {
        icon = Assets.img.logo32White.path;
      }
      _logger.info('Using "$icon" as path of system tray icon');
      await tm.trayManager.setIcon(icon);
    } else {
      await tm.trayManager.setIcon(Assets.img.logo32.path);
    }

    final items = [
      if (checkPlatform([TargetPlatform.windows]))
        tm.MenuItem(
          key: TrayEntry.sendClipboard.name,
          label: t.shareme.text.clipTray,
        ),
      tm.MenuItem(
        key: TrayEntry.open.name,
        label: t.tray.open,
      ),
      tm.MenuItem(
        key: TrayEntry.close.name,
        label: defaultTargetPlatform == TargetPlatform.windows ? t.tray.closeWindows : t.tray.close,
      ),
    ];
    await tm.trayManager.setContextMenu(tm.Menu(items: items));
    // No Linux implementation for setToolTip available as of tray_manager 0.2.2
    // https://pub.dev/packages/tray_manager#api
    if (!checkPlatform([TargetPlatform.linux])) {
      await tm.trayManager.setToolTip(t.appName);
    }
  } catch (e) {
    _logger.warning('Failed to init tray', e);
  }
}

Future<void> hideToTray() async {
  (await WinWindow.main())?.goesToTray(); // Shuttle
  await windowManager.hide();
  if (checkPlatform([TargetPlatform.macOS])) {
    // This will crash on Windows
    // https://github.com/localsend/localsend/issues/32
    await windowManager.setSkipTaskbar(true);
  }

  // Disable animations
  try {
    RefenaScope.defaultRef.notifier(sleepProvider).setState((_) => true);
  } catch (e) {
    _logger.warning('Failed to update sleep state (Refena not yet initialized)', e);
  }
}

/// Shuttle: tray reminder dot. When "decide later" was chosen in the mini window and a request is still waiting, the tray icon gets
/// a blue dot in its top-right corner; it goes away when the window opens, the request is accepted / declined, or the sender cancels.
/// Only the Windows tray supports this.
bool _trayReminder = false;

Future<void> setTrayReminder(bool on) async {
  if (_trayReminder == on || !checkPlatform([TargetPlatform.windows])) {
    return;
  }
  _trayReminder = on;
  try {
    await tm.trayManager.setIcon(on ? Assets.img.logoDot : Assets.img.logo);
  } catch (e) {
    _logger.warning('Failed to update tray icon', e);
  }
}

/// Shuttle: the window was maximized before the small window in the corner took its place, and is maximized again once it's shown
/// (a hidden window can't be)
bool _maximizeOnceShown = false;

void maximizeOnceShown() => _maximizeOnceShown = true;

Future<void> showFromTray() async {
  unawaited(setTrayReminder(false));
  final maximize = _maximizeOnceShown;
  _maximizeOnceShown = false;
  // Shuttle: a window that was hidden is black until it has been drawn
  await showOnceDrawn(() async {
    await windowManager.show();
    if (maximize) await windowManager.maximize();
    if (checkPlatform([TargetPlatform.macOS])) {
      // This will crash on Windows
      // https://github.com/localsend/localsend/issues/32
      await windowManager.setSkipTaskbar(false);
    }

    // Enable animations
    try {
      RefenaScope.defaultRef.notifier(sleepProvider).setState((_) => false);
    } catch (e) {
      _logger.warning('Failed to update sleep state (Refena not yet initialized)', e);
    }
  });
  await windowManager.focus();
}

Future<void> destroyTray() async {
  if (!checkPlatform([TargetPlatform.linux])) {
    await tm.trayManager.destroy();
  }
}
