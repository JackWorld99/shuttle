import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/pages/tabs/transfer_tab.dart' show sendClipboard;
import 'package:localsend_app/util/coalesced_save.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/native/tray_helper.dart';
import 'package:localsend_app/util/shareme_diagnostics.dart';
import 'package:localsend_app/widget/shareme/receive_popup.dart';
import 'package:routerino/routerino.dart';
import 'package:tray_manager/tray_manager.dart';

class TrayWatcher extends StatefulWidget {
  final Widget child;

  const TrayWatcher({required this.child, super.key});

  @override
  State<TrayWatcher> createState() => _TrayWatcherState();
}

class _TrayWatcherState extends State<TrayWatcher> with TrayListener {
  @override
  Widget build(BuildContext context) {
    return widget.child;
  }

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
  }

  @override
  void dispose() {
    trayManager.removeListener(this);
    super.dispose();
  }

  @override
  void onTrayIconMouseDown() async {
    if (checkPlatform([TargetPlatform.macOS])) {
      await trayManager.popUpContextMenu();
    } else {
      // Shuttle: while the bottom-right popup is open, a tray click opens the full receive page
      if (await SmPopupWindow.expandFromTray()) return;
      await showFromTray();
    }
  }

  @override
  void onTrayIconRightMouseDown() async {
    await trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    final entry = TrayEntry.values.firstWhereOrNull((e) => e.name == menuItem.key);
    switch (entry) {
      case TrayEntry.sendClipboard:
        // Don't disturb a receive running in the bottom-right popup
        if (SmPopupWindow.active) break;
        await showFromTray(); // show the window so "Sent to…" or "Send to" is visible
        // Routerino.context is the global navigator context (LocalSend uses it the same way elsewhere)
        // ignore: use_build_context_synchronously
        await sendClipboard(Routerino.context);
        break;
      case TrayEntry.open:
        if (await SmPopupWindow.expandFromTray()) break;
        await showFromTray();
        break;
      case TrayEntry.close:
        CoalescedSave.flushAllBeforeExit(); // Shuttle: write out pending history saves first
        markCleanExit('tray quit');
        exit(0);
      default:
    }
  }
}
