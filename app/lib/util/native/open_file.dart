import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/native/open_folder.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/shareme_file_safety.dart';
import 'package:localsend_app/widget/dialogs/cannot_open_file_dialog.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_file/open_file.dart';
import 'package:permission_handler/permission_handler.dart';

/// Opens the selected file which is stored on the device.
Future<void> openFile(
  BuildContext context,
  FileType fileType,
  String filePath, {
  void Function()? onDeleteTap,
}) async {
  if ((fileType == FileType.apk || filePath.toLowerCase().endsWith('.apk')) && checkPlatform([TargetPlatform.android])) {
    await Permission.requestInstallPackages.request();
  }

  if (filePath.startsWith('content://')) {
    await android_channel.openContentUri(uri: filePath);
    return;
  }

  // Shuttle: on Windows, "opening" an executable-type file runs it, so it is only shown in its folder (shareme_file_safety.dart)
  if (checkPlatform([TargetPlatform.windows]) && isRunnableFile(filePath)) {
    if (context.mounted) await _showRunnableInFolder(context, filePath);
    return;
  }

  final fileOpenResult = await OpenFile.open(filePath);
  if (fileOpenResult.type != ResultType.done && context.mounted) {
    await CannotOpenFileDialog.open(context, filePath, onDeleteTap);
  }
}

/// "This file can run a program": explains why it isn't opened directly and offers "Show in folder" (with the file selected).
Future<void> _showRunnableInFolder(BuildContext context, String filePath) async {
  final c = context.sm;
  final show = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: Icon(LucideIcons.shieldAlert, color: c.warn, size: 28),
      title: Text(t.shareme.safety.runnableTitle),
      content: Text(t.shareme.safety.runnableBody),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.general.cancel)),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(t.shareme.safety.showInFolder)),
      ],
    ),
  );
  if (show == true) await showInFolder(filePath);
}

/// Opens the folder of [filePath] with the file selected (Windows).
Future<void> showInFolder(String filePath) async {
  final normalized = filePath.replaceAll('/', '\\');
  final cut = normalized.lastIndexOf('\\');
  if (cut <= 0) return;
  await openFolder(folderPath: normalized.substring(0, cut), fileName: normalized.substring(cut + 1));
}
