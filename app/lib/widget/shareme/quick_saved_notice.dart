import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/native/open_file.dart';
import 'package:localsend_app/util/native/open_folder.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:routerino/routerino.dart';

/// Shuttle: notice shown after an automatic receive (files from "My devices" are accepted directly).
///
/// Replaces LocalSend's "Open file? Open / Show in folder / Close (5)" dialog, whose style didn't match the rest of the app:
/// one bar at the bottom ("Received N items from X") with a single button; it goes away after 8 seconds and blocks nothing.
/// - Desktop: open the folder (with the file selected)
/// - Phone: saved to the gallery → view in the gallery; otherwise → open
void showQuickSavedNotice({
  required String senderAlias,
  required int count,
  required String filePath,
  required FileType fileType,
  required bool savedToGallery,
}) {
  final context = Routerino.context;
  final String label;
  final Future<void> Function() action;
  if (checkPlatformIsDesktop()) {
    final file = File(filePath);
    label = t.shareme.receive.openFolder;
    action = () => openFolder(folderPath: file.parent.path, fileName: file.uri.pathSegments.last);
  } else if (savedToGallery) {
    label = t.shareme.receive.viewInGallery;
    action = android_channel.openGallery;
  } else {
    label = t.shareme.receive.open;
    action = () => openFile(context, fileType, filePath);
  }

  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(t.shareme.receive.quickSaved(n: count, name: senderAlias)),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(label: label, onPressed: () => unawaited(action())),
      ),
    );
}
