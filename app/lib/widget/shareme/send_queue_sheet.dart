import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/persistence/queued_send.dart';
import 'package:localsend_app/pages/tabs/send_tab_vm.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/send_queue_runner.dart';
import 'package:localsend_app/provider/network/shareme_presence.dart';
import 'package:localsend_app/provider/send_queue_provider.dart';
import 'package:localsend_app/util/message_preview.dart';
import 'package:localsend_app/util/shareme_format.dart';
import 'package:localsend_app/widget/shareme/bottom_actions.dart';
import 'package:localsend_app/widget/shareme/device_avatar.dart';
import 'package:localsend_app/widget/shareme/film_strip.dart';
import 'package:localsend_app/widget/shareme/send_text_sheet.dart' show looksLikeLink;
import 'package:localsend_app/widget/shareme/sm_card.dart';
import 'package:localsend_app/widget/shareme/sm_sheets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

// Shuttle: the send queue as the user sees it. Tapping a "my device" that is offline (or one with something waiting) opens "Waiting for
// X": each batch with its own "Cancel", plus "Cancel all" and "Try now" / "Send now".

/// Queues [files] for one of "my devices" and says so ("Queued … Undo"), then asks whether the device is there after all (it may
/// just have been shown as offline). Returns the batch, or null when it couldn't be queued (the reason is shown instead).
Future<QueuedSend?> queueAndTell(Ref ref, {required String fingerprint, required String alias, required List<CrossFile> files}) async {
  final (:entry, :refusal) = await queueForDevice(ref, fingerprint: fingerprint, alias: alias, files: files);
  if (entry != null) unawaited(ref.global.dispatchAsync(CheckPresenceAction(force: true)));
  final context = Routerino.context;
  final messenger = context.mounted ? ScaffoldMessenger.maybeOf(context) : null;
  if (messenger == null) return entry;
  messenger.hideCurrentSnackBar();
  if (entry == null) {
    messenger.showSnackBar(
      SnackBar(content: Text(refusal == QueueRefusal.full ? t.shareme.queue.full(name: alias) : t.shareme.queue.tooLarge)),
    );
    return null;
  }
  messenger.showSnackBar(
    SnackBar(
      content: Text(t.shareme.queue.added(name: alias)),
      action: SnackBarAction(
        label: t.shareme.queue.undo,
        onPressed: () {
          final runner = SendQueueRunner.instance;
          if (runner != null) {
            runner.cancel(entry.id);
          } else {
            ref.redux(sendQueueProvider).dispatch(RemoveQueuedSendsAction.id(entry.id));
          }
        },
      ),
    ),
  );
  return entry;
}

/// What the sheet asks its caller to do after it closes
enum SendQueueSheetResult {
  /// "Pick something" / "Add more": pick content and queue it for this device
  pick,
}

/// "Waiting for X"
Future<SendQueueSheetResult?> showSendQueueSheet(BuildContext context, {required String fingerprint}) {
  return showSmSheet<SendQueueSheetResult>(context, maxWidth: 480, scroll: false, builder: (_) => SendQueueSheet(fingerprint: fingerprint));
}

class SendQueueSheet extends StatefulWidget {
  final String fingerprint;

  const SendQueueSheet({required this.fingerprint, super.key});

  @override
  State<SendQueueSheet> createState() => _SendQueueSheetState();
}

class _SendQueueSheetState extends State<SendQueueSheet> {
  /// Opened with something waiting: closes by itself once all of it is sent or canceled
  bool? _hadEntries;
  bool _closing = false;

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final fingerprint = widget.fingerprint;
    final vm = context.watch(sendTabVmProvider);
    final queue = queuedFor(context.watch(sendQueueProvider), fingerprint);
    context.watch(sendProvider); // a queued send starting or ending changes the rows
    final favorite = vm.favoriteDevices.firstWhereOrNull((f) => f.fingerprint == fingerprint);
    final name = favorite?.alias ?? queue.firstOrNull?.targetAlias ?? '';
    final online = vm.nearbyDevices.firstWhereOrNull((d) => d.fingerprint == fingerprint && d.ip != null);
    final runner = SendQueueRunner.instance;
    final held = queueHeldForLan(queue, online, allowRemote: runner?.allowsRemote(fingerprint) ?? false);

    _hadEntries ??= queue.isNotEmpty;
    if (_hadEntries! && queue.isEmpty && !_closing) {
      _closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
    }

    final status = queue.isEmpty
        ? t.shareme.queue.empty(name: name)
        : online == null
        ? t.shareme.queue.offline(name: name)
        : held
        ? t.shareme.queue.holdLan
        : runner?.retryAt(fingerprint) != null
        ? t.shareme.queue.retrying
        : t.shareme.queue.online(name: name);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
              child: Row(
                children: [
                  DeviceAvatar(deviceType: online?.deviceType ?? knownDeviceType(fingerprint), size: 40, mine: true, offline: online == null),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.shareme.queue.title(name: name),
                          style: ShareMeText.title.copyWith(color: c.ink, fontSize: 18),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(status, style: ShareMeText.meta.copyWith(color: c.ink2)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (queue.isNotEmpty)
              Flexible(
                child: SmCard(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: queue.length,
                    separatorBuilder: (_, _) => Divider(height: 1, indent: 72, color: c.line),
                    itemBuilder: (_, i) => _EntryRow(
                      entry: queue[i],
                      sending: runner?.isSending(queue[i].id) ?? false,
                      onCancel: () => _cancel(queue[i].id),
                    ),
                  ),
                ),
              ),
            if (queue.isEmpty)
              Padding(
                padding: BottomActions.padding.copyWith(left: 2, right: 2),
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(SendQueueSheetResult.pick),
                  child: Text(t.shareme.queue.pick),
                ),
              )
            else ...[
              const SizedBox(height: 4),
              BottomActions(
                secondaryLabel: t.shareme.queue.cancelAll,
                onSecondary: () {
                  final runner = SendQueueRunner.instance;
                  if (runner != null) {
                    runner.cancelAll(fingerprint);
                  } else {
                    context.redux(sendQueueProvider).dispatch(RemoveQueuedSendsAction.device(fingerprint));
                  }
                },
                primaryLabel: held ? t.shareme.queue.sendNow : t.shareme.queue.tryNow,
                onPrimary: () => SendQueueRunner.instance?.tryNow(fingerprint),
              ),
              if (online == null)
                TextButton(
                  onPressed: () => Navigator.of(context).pop(SendQueueSheetResult.pick),
                  child: Text(t.shareme.queue.addMore),
                ),
            ],
          ],
        ),
      ),
    );
  }

  void _cancel(String entryId) {
    final runner = SendQueueRunner.instance;
    if (runner != null) {
      runner.cancel(entryId);
    } else {
      context.redux(sendQueueProvider).dispatch(RemoveQueuedSendsAction.id(entryId));
    }
  }
}

/// One waiting batch: thumbnail of its first item, what it is, size and when it was queued, and "Cancel"
class _EntryRow extends StatelessWidget {
  final QueuedSend entry;
  final bool sending;
  final VoidCallback onCancel;

  const _EntryRow({required this.entry, required this.sending, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final first = entry.files.first;
    final message = entry.isMessage ? first.preview ?? '' : null;
    final isLink = message != null && looksLikeLink(message);
    final title = message != null
        ? messageLabel(message)
        : entry.files.length == 1
        ? first.fileName
        : t.shareme.queue.more(name: first.fileName, n: entry.files.length);
    final what = message != null ? (isLink ? t.shareme.queue.linkItem : t.shareme.queue.textItem) : formatSize(entry.totalSize);
    final subtitle = sending ? t.shareme.queue.sending : '$what · ${t.shareme.queue.queuedAgo(time: formatAgo(entry.createdAt.toLocal()))}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
      child: Row(
        children: [
          FileThumb(
            frame: message != null
                ? FilmFrame(fileName: messageLabel(message), fileType: first.fileType, path: null, isMessage: true)
                : FilmFrame(fileName: first.fileName, fileType: first.fileType, path: first.path, assetId: first.assetId),
            size: 44,
            radius: 12,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: (isLink ? ShareMeText.data : ShareMeText.body).copyWith(color: c.ink, fontSize: 14.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  subtitle,
                  style: ShareMeText.meta.copyWith(color: sending ? c.accent : c.ink2),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onCancel,
            tooltip: t.shareme.queue.cancel,
            icon: Icon(LucideIcons.x, size: 18, color: c.ink3),
          ),
        ],
      ),
    );
  }
}
