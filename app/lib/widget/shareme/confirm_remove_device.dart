import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';

/// Asks before removing a device from "My devices" (shared by the settings page and the home page long-press menu).
/// The home page used to remove at once while settings asked first; both now use this one dialog and wording.
Future<bool> confirmRemoveDevice(BuildContext context, String name) async {
  final c = context.sm;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(t.shareme.settings.removeTitle(name: name)),
      content: Text(t.shareme.settings.removeBody),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.shareme.settings.cancel)),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(foregroundColor: c.warn),
          child: Text(t.shareme.settings.remove),
        ),
      ],
    ),
  );
  return ok == true;
}
