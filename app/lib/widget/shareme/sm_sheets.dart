import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/native/file_picker.dart';
import 'package:localsend_app/widget/shareme/bottom_actions.dart';
import 'package:localsend_app/widget/shareme/desktop_layout.dart';
import 'package:localsend_app/widget/shareme/motion.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Everything that opens on top of a page: a bottom sheet on phones, a dialog in the middle of a PC window (a sheet glued to the
/// bottom edge looks lost there). Never taller than the screen; with [scroll], longer content scrolls instead of overflowing
/// (landscape, large text). Content that scrolls by itself passes false.
Future<T?> showSmSheet<T>(BuildContext context, {required WidgetBuilder builder, double maxWidth = 440, bool scroll = true}) {
  Widget content(BuildContext context) => scroll ? SingleChildScrollView(child: builder(context)) : builder(context);

  if (useDesktopLayout(context)) {
    return showDialog<T>(
      context: context,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Padding(padding: const EdgeInsets.only(top: 22, bottom: 6), child: content(context)),
        ),
      ),
    );
  }
  // As wide as the screen (not as its content), up to a comfortable width in landscape and on tablets
  final width = math.min(MediaQuery.sizeOf(context).width, 600.0);
  return showModalBottomSheet<T>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    constraints: BoxConstraints(minWidth: width, maxWidth: width),
    // A little air below even where there is no gesture bar
    builder: (context) => SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 8),
      child: SizedBox(width: double.infinity, child: content(context)),
    ),
  );
}

/// Asked before a running transfer is stopped. The answer that does no harm is the large button.
Future<bool> confirmStopTransfer(BuildContext context, {required bool sending}) async {
  final stop = await showSmSheet<bool>(
    context,
    maxWidth: 380,
    builder: (context) {
      final c = context.sm;
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 18),
              child: Text(
                sending ? t.shareme.send.stopTitle : t.shareme.receive.stopTitle,
                style: ShareMeText.title.copyWith(color: c.ink, fontSize: 19, height: 1.35, fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
            ),
            BottomActions(
              secondaryLabel: t.shareme.send.stop,
              onSecondary: () => Navigator.of(context).pop(true),
              primaryLabel: t.shareme.send.keepGoing,
              onPrimary: () => Navigator.of(context).pop(false),
            ),
          ],
        ),
      );
    },
  );
  return stop == true;
}

/// What to send to a device that was tapped while nothing is picked yet.
Future<FilePickerOption?> showSendOptions(
  BuildContext context, {
  required String name,
  required Widget avatar,
  required List<FilePickerOption> options,
}) {
  return showSmSheet<FilePickerOption>(
    context,
    maxWidth: 460,
    builder: (context) {
      final c = context.sm;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  avatar,
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      t.shareme.home.sendToName(name: name),
                      style: ShareMeText.title.copyWith(color: c.ink, fontSize: 18),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              LayoutBuilder(
                builder: (context, box) {
                  const gap = 10.0;
                  // Three to a row on phones, four on a PC; as many tiles as needed, all the same size
                  final columns = box.maxWidth >= 400 && options.length == 4 ? 4 : 3;
                  final width = (box.maxWidth - gap * (columns - 1)) / columns;
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (final o in options)
                        SizedBox(
                          width: width,
                          child: _OptionTile(option: o, onTap: () => Navigator.of(context).pop(o)),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _OptionTile extends StatelessWidget {
  final FilePickerOption option;
  final VoidCallback onTap;

  const _OptionTile({required this.option, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final (icon, label, kind) = switch (option) {
      FilePickerOption.media => (LucideIcons.images, t.shareme.home.sendMedia, 'image'),
      FilePickerOption.file => (LucideIcons.file, t.shareme.home.file, 'other'),
      FilePickerOption.folder => (LucideIcons.folder, t.shareme.home.pickFolder, 'other'),
      FilePickerOption.text => (LucideIcons.type, t.shareme.home.text, 'text'),
      FilePickerOption.clipboard => (LucideIcons.clipboard, option.label, 'text'),
      FilePickerOption.app => (LucideIcons.layoutGrid, option.label, 'video'),
    };
    final colors = smKindColors(dark: Theme.of(context).brightness == Brightness.dark, kind: kind);
    return SmPressable(
      scale: 0.95,
      child: DecoratedBox(
        decoration: smInsetDecoration(c, radius: ShareMeSize.radiusButton),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(ShareMeSize.radiusButton),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 14, 6, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [colors.top, colors.bottom]),
                      borderRadius: BorderRadius.circular(15),
                      border: Border.all(color: colors.icon.withValues(alpha: 0.12)),
                    ),
                    child: Icon(icon, size: 21, color: colors.icon),
                  ),
                  const SizedBox(height: 9),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(label, style: ShareMeText.label.copyWith(color: c.ink, fontSize: 13.5), maxLines: 1),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
