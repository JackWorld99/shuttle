import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/pages/tabs/send_tab_vm.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/widget/shareme/send_target_sheet.dart';
import 'package:localsend_app/widget/shareme/sm_sheets.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uuid/uuid.dart';

/// "Send text or a link" sheet.
///
/// - Reads the clipboard once when opened (since Android 10 only the foreground app may read it); if it has content,
///   a "Paste" suggestion appears at the top.
/// - Below, the target is chosen ([SendTargetList], shared with the send-files sheet); the only online "My devices" entry is preselected.
/// - Text is sent on its own, not added to the selected files, so it doesn't get mixed up with photos the user already picked.
///
/// [to]: the device (fingerprint) to send to unless the user picks another one
Future<void> showSendTextSheet(BuildContext context, {String? to}) {
  return showSmSheet<void>(context, maxWidth: 480, scroll: false, builder: (_) => _SendTextSheet(to: to));
}

class _SendTextSheet extends StatefulWidget {
  final String? to;

  const _SendTextSheet({this.to});

  @override
  State<_SendTextSheet> createState() => _SendTextSheetState();
}

class _SendTextSheetState extends State<_SendTextSheet> with Refena {
  final _controller = TextEditingController();
  String? _clipboard;
  late String? _selected = widget.to;
  bool _userChose = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
    unawaited(_readClipboardOnce());
  }

  Future<void> _readClipboardOnce() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim();
      if (mounted && text != null && text.isNotEmpty) setState(() => _clipboard = text);
    } catch (_) {
      // Clipboard unreadable (system restriction or no content): no suggestion
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final vm = ref.read(sendTabVmProvider);
    final device = sendTargetDevice(vm, _selected);
    final text = _controller.text;
    if (device == null || text.trim().isEmpty) return;
    final bytes = utf8.encode(text);
    // Built the same way as LocalSend's AddMessageAction (the text is sent as an in-memory text/plain file)
    final file = CrossFile(
      name: '${const Uuid().v4()}.txt',
      fileType: FileType.text,
      size: bytes.length,
      thumbnail: null,
      asset: null,
      path: null,
      bytes: bytes,
      lastModified: null,
      lastAccessed: null,
    );
    final sender = ref.notifier(sendProvider);
    Navigator.of(context).pop();
    await sender.startSession(target: device, files: [file], background: false);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final vm = context.watch(sendTabVmProvider);
    if (!_userChose && _selected == null) _selected = defaultSendTarget(vm);
    final device = sendTargetDevice(vm, _selected);
    final text = _controller.text;
    final clip = _clipboard;
    final showClip = clip != null && clip != text.trim();
    final clipIsLink = clip != null && looksLikeLink(clip);
    final keyboard = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                child: Text(t.shareme.text.sheetTitle, style: ShareMeText.title.copyWith(color: c.ink, fontSize: 18)),
              ),
              if (showClip)
                DecoratedBox(
                  decoration: smInsetDecoration(c),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                    child: Row(
                      children: [
                        Icon(clipIsLink ? LucideIcons.link : LucideIcons.clipboard, size: 18, color: c.ink2),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                clipIsLink ? t.shareme.text.clipboardLink : t.shareme.text.clipboardText,
                                style: ShareMeText.meta.copyWith(color: c.ink2),
                              ),
                              Text(
                                clip,
                                style: (clipIsLink ? ShareMeText.data : ShareMeText.body).copyWith(color: c.ink, fontSize: 13),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            _controller.text = clip;
                            _controller.selection = TextSelection.collapsed(offset: clip.length);
                          },
                          child: Text(t.shareme.text.paste),
                        ),
                      ],
                    ),
                  ),
                ),
              if (showClip) const SizedBox(height: 10),
              TextField(
                controller: _controller,
                minLines: 3,
                maxLines: 6,
                keyboardType: TextInputType.multiline,
                decoration: InputDecoration(hintText: t.shareme.text.hint, fillColor: c.bg),
                style: ShareMeText.body.copyWith(color: c.ink),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                child: Text(t.shareme.text.sendTo, style: ShareMeText.section.copyWith(color: c.ink2)),
              ),
              Flexible(
                child: SendTargetList(
                  selected: _selected,
                  onSelect: (fp) => setState(() {
                    _selected = fp;
                    _userChose = true;
                  }),
                ),
              ),
              const SizedBox(height: 14),
              SendToButton(
                device: device,
                enabled: text.trim().isNotEmpty,
                label: t.shareme.text.send,
                onPressed: _send,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Same check as LocalSend's ReceivePageVm.isLink: no whitespace, a complete absolute URL.
/// Shuttle security: only http / https URLs with a host count as a "link" and get an "Open" button.
/// Any "xxx://" used to count (as in LocalSend): e.g. if someone sends file://some-computer/x, one tap on "Open" on Windows
/// could send your login credentials to that computer, or launch another program.
bool looksLikeLink(String text) {
  final s = text.trim();
  if (s.contains(RegExp(r'\s'))) return false;
  final uri = Uri.tryParse(s);
  return uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;
}
