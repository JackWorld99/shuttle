import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/receive_page.dart' show ReceivePageVm;
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/paired_devices_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/message_preview.dart';
import 'package:localsend_app/widget/shareme/device_avatar.dart';
import 'package:localsend_app/widget/shareme/send_text_sheet.dart' show looksLikeLink;
import 'package:localsend_app/widget/shareme/sm_sheets.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:url_launcher/url_launcher.dart';

/// Bottom sheet for a received text / link.
///
/// - At the top: the sender's seal (only for "My devices") and name.
/// - A link shows only the URL itself and is **never fetched in the background for a title or image**: that would expose our IP
///   to the site and slow the sheet down.
/// - The primary button is the most common action: "Open link" for links, "Copy" for text.
/// - Once the sheet closes, receive_controller tells the sender it was seen (no files are accepted, same as LocalSend).
/// - The design's "Share to…" would need a new share_plus dependency and is left out for now.
class SmMessageSheet extends StatefulWidget {
  final ViewProvider<ReceivePageVm> vm;

  const SmMessageSheet(this.vm, {super.key});

  @override
  State<SmMessageSheet> createState() => _SmMessageSheetState();
}

class _SmMessageSheetState extends State<SmMessageSheet> {
  /// The content as first received. Text from my devices is answered and its session closed right away (clipboard sharing), so the
  /// session state may later be empty or already belong to the next transfer; the sheet keeps showing what it opened with.
  /// (receive_controller also keeps a copy of the text and the sender, see messageSender.)
  ReceivePageVm? _first;

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final live = context.watch(widget.vm);
    final vm = _first ??= live.message == null ? null : live;
    if (vm == null) return const SizedBox.shrink();
    final sender = vm.sender;
    final favorites = context.watch(favoritesProvider);
    final isMine = favorites.any((f) => f.fingerprint == sender.fingerprint);
    // Only verified "My devices" get auto-copy (see isVerifiedMine)
    final autoCopy = isVerifiedMine(favorites: favorites, paired: context.watch(pairedDevicesProvider), fingerprint: sender.fingerprint);
    final saved = context.watch(settingsProvider.select((s) => s.saveToHistory));
    return SmMessageView(
      message: vm.message ?? '',
      isLink: vm.isLink,
      sealFingerprint: isMine ? sender.fingerprint : null,
      deviceType: sender.deviceType,
      header: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: sender.alias,
              style: ShareMeText.deviceNameSm.copyWith(color: c.ink),
            ),
            TextSpan(text: ' ${vm.isLink ? t.shareme.text.receivedLink : t.shareme.text.receivedText} · ${t.shareme.time.justNow}'),
          ],
        ),
        style: ShareMeText.meta.copyWith(color: c.ink2),
      ),
      footnote: [
        if (autoCopy) t.shareme.text.autoCopied else if (isMine) t.shareme.receive.mineUnchecked,
        if (saved) t.shareme.text.savedToHistory,
      ].join(' · ').emptyToNull,
      // Shuttle: clipboard sharing — text from a verified "My devices" entry goes straight to the clipboard
      autoCopy: autoCopy,
    );
  }
}

extension on String {
  String? get emptyToNull => isEmpty ? null : this;
}

/// Tapping a text / link on the history page reopens it in the same sheet (read-only: copy / open link).
Future<void> showHistoryMessageSheet(
  BuildContext context, {
  required String message,
  required String header,
  required String? sealFingerprint,
}) {
  final c = context.sm;
  return showSmSheet<void>(
    context,
    maxWidth: 480,
    scroll: false,
    builder: (_) => SmMessageView(
      message: message,
      isLink: looksLikeLink(message),
      sealFingerprint: sealFingerprint,
      deviceType: null,
      header: Text(header, style: ShareMeText.meta.copyWith(color: c.ink2)),
      footnote: null,
    ),
  );
}

/// The sheet content itself: seal + a header line + body + two buttons.
class SmMessageView extends StatefulWidget {
  final String message;
  final bool isLink;

  /// Only "My devices" get a seal; otherwise the slot stays empty
  final String? sealFingerprint;
  final DeviceType? deviceType;
  final Widget header;
  final String? footnote;

  const SmMessageView({
    required this.message,
    required this.isLink,
    required this.sealFingerprint,
    required this.deviceType,
    required this.header,
    required this.footnote,
    this.autoCopy = false,
    super.key,
  });

  /// Copy to the clipboard as soon as the sheet opens (text from "My devices")
  final bool autoCopy;

  @override
  State<SmMessageView> createState() => _SmMessageViewState();
}

class _SmMessageViewState extends State<SmMessageView> {
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoCopy && widget.message.isNotEmpty) {
      _copied = true;
      unawaited(Clipboard.setData(ClipboardData(text: widget.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final message = widget.message;
    final url = widget.isLink ? Uri.tryParse(message.trim()) : null;
    final seal = widget.sealFingerprint;
    final footnote = [?widget.footnote, if (isMessageExcerpt(message)) t.shareme.text.excerpt].join(' · ').emptyToNull;

    Future<void> copy() async {
      await Clipboard.setData(ClipboardData(text: message));
      if (mounted) setState(() => _copied = true);
    }

    Future<void> open() async {
      if (url == null) return;
      // Hand the URL to the system browser only after the user taps
      await launchUrl(url, mode: LaunchMode.externalApplication);
      if (context.mounted) Navigator.of(context).pop();
    }

    final copyLabel = _copied ? t.shareme.text.copied : t.shareme.text.copy;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                DeviceAvatar(deviceType: widget.deviceType, size: 40, mine: seal != null),
                const SizedBox(width: 12),
                Expanded(child: widget.header),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.45),
              padding: const EdgeInsets.all(16),
              decoration: smInsetDecoration(c),
              child: SingleChildScrollView(
                child: url != null
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(url.host, style: ShareMeText.deviceName.copyWith(color: c.ink)),
                          const SizedBox(height: 6),
                          SelectableText(messageExcerpt(message.trim()), style: ShareMeText.data.copyWith(color: c.ink2, fontSize: 13, height: 1.5)),
                        ],
                      )
                    : SelectableText(messageExcerpt(message), style: ShareMeText.body.copyWith(color: c.ink)),
              ),
            ),
            const SizedBox(height: 16),
            // Two buttons side by side: the primary one takes 2/3 of the width, on the right
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: url != null ? copy : () => Navigator.of(context).pop(),
                    style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(ShareMeSize.buttonH)),
                    icon: Icon(url != null ? LucideIcons.copy : LucideIcons.x, size: 18),
                    label: Text(url != null ? copyLabel : t.shareme.text.close),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: url != null ? open : copy,
                    icon: Icon(url != null ? LucideIcons.externalLink : LucideIcons.copy, size: 20),
                    label: Text(url != null ? t.shareme.text.openLink : copyLabel),
                  ),
                ),
              ],
            ),
            if (footnote != null) ...[
              const SizedBox(height: 10),
              Text(
                footnote,
                style: ShareMeText.meta.copyWith(color: c.ink3, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Text from my devices is already copied automatically, so only a snack bar shows at the bottom for a few seconds.
/// "View" opens the full text; for a URL (http / https only) the button is "Open", and the browser is used only once the user taps it.
/// [late]: the text waited in the sender's send queue and was not copied automatically; the button copies it then.
void showReceivedTextSnack({required String alias, required String message, required String senderFingerprint, bool late = false}) {
  final context = Routerino.context;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final isLink = looksLikeLink(message);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 5),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              late
                  ? (isLink ? t.shareme.text.snackLateLink(name: alias) : t.shareme.text.snackLateText(name: alias))
                  : isLink
                  ? t.shareme.text.snackLink(name: alias)
                  : t.shareme.text.snackCopied(name: alias),
              style: ShareMeText.body.copyWith(color: const Color(0xFFF3F3F1), fontWeight: FontWeight.w600),
            ),
            Text(
              messageLabel(message),
              style: ShareMeText.meta.copyWith(color: const Color(0xFFB5B8BC)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        action: SnackBarAction(
          label: late ? t.shareme.text.copy : (isLink ? t.shareme.text.snackOpen : t.shareme.text.snackView),
          onPressed: () async {
            if (late) {
              await Clipboard.setData(ClipboardData(text: message));
              return;
            }
            final url = isLink ? Uri.tryParse(message.trim()) : null;
            if (url != null) {
              await launchUrl(url, mode: LaunchMode.externalApplication);
              return;
            }
            await showHistoryMessageSheet(
              Routerino.context,
              message: message,
              header: alias,
              sealFingerprint: senderFingerprint,
            );
          },
        ),
      ),
    );
}
