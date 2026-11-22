import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/state/server/receive_session_state.dart';
import 'package:localsend_app/model/state/server/receiving_file.dart';
import 'package:localsend_app/pages/web_share_page.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/native/open_file.dart';
import 'package:localsend_app/util/native/open_folder.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/shareme_format.dart';
import 'package:localsend_app/widget/dialogs/cancel_session_dialog.dart';
import 'package:localsend_app/widget/shareme/film_strip.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Shuttle: receive progress + done page.
/// Replaces LocalSend's ProgressPage on the receiving side (the sending side uses SmSendPage).
///
/// The done page centers on the film strip: its edge print states the source, count, size and "original, uncompressed",
/// and says "verified" only when every file's SHA-256 was checked; it ends with the sender's seal (only for "My devices").
/// Below that, it shows where each kind of file was saved.
class SmReceiveProgressPage extends StatefulWidget {
  final String sessionId;

  const SmReceiveProgressPage({required this.sessionId, super.key});

  @override
  State<SmReceiveProgressPage> createState() => _SmReceiveProgressPageState();
}

class _SmReceiveProgressPageState extends State<SmReceiveProgressPage> with Refena {
  Timer? _tick;
  final _samples = <(int, int)>[];
  double _speed = 0;
  bool get _useWakelock => checkPlatformIsNot([TargetPlatform.android]);

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      final session = ref.read(serverProvider)?.session;
      if (session != null && session.status == SessionStatus.sending) {
        final now = DateTime.now().millisecondsSinceEpoch;
        _samples.add((now, _bytes(session, ref.read(fileTransferProvider)).$2));
        _samples.removeWhere((s) => now - s.$1 > 3000);
        if (_samples.length >= 2) {
          final (t0, b0) = _samples.first;
          final (t1, b1) = _samples.last;
          _speed = t1 > t0 ? (b1 - b0) / ((t1 - t0) / 1000) : 0;
        }
      }
      setState(() {});
    });
    if (_useWakelock) {
      try {
        unawaited(WakelockPlus.enable());
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    if (_useWakelock) {
      try {
        unawaited(WakelockPlus.disable());
      } catch (_) {}
    }
    super.dispose();
  }

  void _leave() => context.global.dispatch(NavigateAction.popUntil<WebSharePage>());

  /// Leaving mid-transfer first asks to confirm the cancel (as in LocalSend); once finished, it closes the session.
  Future<void> _exit() async {
    final session = ref.read(serverProvider)?.session;
    final status = session?.status;
    if (status == SessionStatus.sending || status == SessionStatus.waiting) {
      final ok = (await context.pushBottomSheet(() => const CancelSessionDialog())) == true;
      if (!ok || !mounted) return;
      ref.notifier(serverProvider).cancelSession();
    } else if (session != null) {
      ref.notifier(serverProvider).closeSession();
    }
    if (mounted) _leave();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch(serverProvider)?.session;
    final transfers = context.watch(fileTransferProvider);

    if (session == null || session.sessionId != widget.sessionId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _leave();
      });
      return const Scaffold(body: SizedBox.shrink());
    }

    final isMine = context.watch(favoritesProvider).any((f) => f.fingerprint == session.sender.fingerprint);
    final verifyOn = context.watch(settingsProvider.select((s) => s.verifyChecksums));

    final Widget body = switch (session.status) {
      SessionStatus.sending => _Receiving(session: session, transfers: transfers, liveSpeed: _speed, onCancel: _exit),
      SessionStatus.finished || SessionStatus.finishedWithErrors => _Received(
        session: session,
        transfers: transfers,
        isMine: isMine,
        verifyOn: verifyOn,
      ),
      SessionStatus.waiting => Center(
        child: Text(t.shareme.receive.preparing, style: ShareMeText.body.copyWith(color: context.sm.ink2)),
      ),
      _ => _Canceled(onClose: _exit),
    };

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) await _exit();
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                  child: IconButton(icon: const Icon(LucideIcons.x), onPressed: _exit),
                ),
              ),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }
}

/// (total bytes, received bytes), excluding skipped files.
(int, int) _bytes(ReceiveSessionState s, FileTransferNotifier t) {
  var total = 0;
  var current = 0;
  for (final f in s.files.values) {
    if (t.getStatus(sessionId: s.sessionId, fileId: f.file.id) == FileStatus.skipped) continue;
    total += f.file.size;
    current += (t.getProgress(sessionId: s.sessionId, fileId: f.file.id) * f.file.size).round();
  }
  return (total, current);
}

// ───────────────────────── Receiving ─────────────────────────

class _Receiving extends StatelessWidget {
  final ReceiveSessionState session;
  final FileTransferNotifier transfers;
  final double liveSpeed;
  final VoidCallback onCancel;

  const _Receiving({required this.session, required this.transfers, required this.liveSpeed, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final (total, current) = _bytes(session, transfers);
    final ratio = total == 0 ? 0.0 : (current / total).clamp(0.0, 1.0);
    final remaining = liveSpeed > 0 ? Duration(seconds: ((total - current) / liveSpeed).round()) : null;
    final files = session.files.values.where(
      (f) => transfers.getStatus(sessionId: session.sessionId, fileId: f.file.id) != FileStatus.skipped,
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
      children: [
        Text(t.shareme.receive.receivingFrom, style: ShareMeText.meta.copyWith(color: c.ink2)),
        const SizedBox(height: 2),
        Text(
          session.senderAlias,
          style: ShareMeText.headline.copyWith(color: c.ink),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 20),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('${(ratio * 100).floor()}', style: ShareMeText.dataLg.copyWith(color: c.ink)),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text('%', style: ShareMeText.data.copyWith(color: c.ink2, fontSize: 16)),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                [
                  if (liveSpeed > 0) formatSpeed(liveSpeed),
                  if (remaining != null) t.shareme.home.remaining(time: formatDuration(remaining)),
                ].join('   '),
                style: ShareMeText.data.copyWith(color: c.ink2),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        TweenAnimationBuilder<double>(
          tween: Tween(end: ratio),
          duration: ShareMeMotion.short,
          builder: (_, v, _) => LinearProgressIndicator(
            value: v,
            minHeight: 6,
            color: c.ink,
            backgroundColor: c.tonal,
            borderRadius: BorderRadius.circular(ShareMeSize.radiusPill),
          ),
        ),
        const SizedBox(height: 8),
        Text('${formatSize(current)} / ${formatSize(total)}', style: ShareMeText.data.copyWith(color: c.ink2)),
        const SizedBox(height: 24),
        Material(
          color: c.group,
          borderRadius: BorderRadius.circular(ShareMeSize.radiusGroup),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final (i, f) in files.indexed) ...[
                if (i > 0) Divider(height: 1, indent: 16, color: c.line),
                _FileLine(file: f, sessionId: session.sessionId, transfers: transfers),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        Center(
          child: TextButton(
            onPressed: onCancel,
            style: TextButton.styleFrom(foregroundColor: c.warn),
            child: Text(t.shareme.receive.cancelReceive),
          ),
        ),
      ],
    );
  }
}

class _FileLine extends StatelessWidget {
  final ReceivingFile file;
  final String sessionId;
  final FileTransferNotifier transfers;

  const _FileLine({required this.file, required this.sessionId, required this.transfers});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final status = transfers.getStatus(sessionId: sessionId, fileId: file.file.id);
    final progress = transfers.getProgress(sessionId: sessionId, fileId: file.file.id);
    final (String right, Color color) = switch (status) {
      FileStatus.finished => (formatSize(file.file.size), c.ink2),
      FileStatus.sending => ('${(progress * 100).floor()}%', c.ink),
      FileStatus.failed => (t.shareme.send.failed, c.warn),
      _ => (t.shareme.send.queued, c.ink3),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              file.desiredName ?? file.file.fileName,
              style: ShareMeText.body.copyWith(color: status == FileStatus.queue ? c.ink2 : c.ink, fontSize: 14),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          Text(right, style: ShareMeText.data.copyWith(color: color)),
        ],
      ),
    );
  }
}

// ───────────────────────── Received ─────────────────────────

class _Received extends StatelessWidget {
  final ReceiveSessionState session;
  final FileTransferNotifier transfers;
  final bool isMine;
  final bool verifyOn;

  const _Received({required this.session, required this.transfers, required this.isMine, required this.verifyOn});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    FileStatus status(ReceivingFile f) => transfers.getStatus(sessionId: session.sessionId, fileId: f.file.id);
    final done = session.files.values.where((f) => status(f) == FileStatus.finished).toList();
    final failed = session.files.values.where((f) => status(f) == FileStatus.failed).toList();
    final bytes = done.fold<int>(0, (a, f) => a + f.file.size);
    final start = session.startTime;
    final end = session.endTime;
    final elapsed = start != null && end != null ? Duration(milliseconds: end - start) : null;
    final avg = elapsed != null && elapsed.inMilliseconds > 0 ? bytes / (elapsed.inMilliseconds / 1000) : null;
    // "Verified" only if every received file came with a SHA-256 and checksum verification is on here (on a mismatch the
    // core fails the file, so it never shows up in done)
    final verified = verifyOn && done.isNotEmpty && done.every((f) => f.file.hash != null);
    final inGallery = done.where((f) => f.savedToGallery).toList();
    final elsewhere = done.where((f) => !f.savedToGallery && f.path != null).toList();

    Future<void> openFirst() async {
      if (inGallery.isNotEmpty) {
        await android_channel.openGallery();
      } else if (elsewhere.isNotEmpty) {
        await openFile(context, elsewhere.first.file.fileType, elsewhere.first.path!);
      }
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.shareme.receive.receivedTitle(n: done.length),
                style: ShareMeText.display.copyWith(color: c.ink),
              ),
              const SizedBox(height: 6),
              Text(
                t.shareme.receive.receivedFrom(
                  name: session.senderAlias,
                  time: elapsed == null ? '--:--' : formatDuration(elapsed),
                  speed: avg == null ? '--' : formatSpeed(avg),
                ),
                style: ShareMeText.meta.copyWith(color: c.ink2),
              ),
            ],
          ),
        ),
        if (done.isNotEmpty)
          FilmStrip(
            frames: [
              for (final f in done)
                FilmFrame(
                  fileName: f.desiredName ?? f.file.fileName,
                  fileType: f.file.fileType,
                  path: f.path,
                  inGallery: f.savedToGallery,
                ),
            ],
            fromAlias: session.senderAlias,
            totalBytes: bytes,
            sealFingerprint: isMine ? session.sender.fingerprint : null,
            verified: verified,
            animateStamp: true,
          ),
        if (failed.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.shareme.receive.failedTitle(n: failed.length),
                  style: ShareMeText.title.copyWith(color: c.warn),
                ),
                for (final f in failed)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '${f.desiredName ?? f.file.fileName}${f.errorMessage == null ? '' : '：${f.errorMessage}'}',
                      style: ShareMeText.meta.copyWith(color: c.ink2),
                    ),
                  ),
              ],
            ),
          ),
        if (done.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(t.shareme.receive.whereSaved, style: ShareMeText.section.copyWith(color: c.ink2)),
                const SizedBox(height: 10),
                Material(
                  color: c.group,
                  borderRadius: BorderRadius.circular(ShareMeSize.radiusGroup),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      if (inGallery.isNotEmpty)
                        ListTile(
                          leading: Icon(LucideIcons.images, color: c.ink2),
                          title: Text(t.shareme.receive.mediaItems(n: inGallery.length)),
                          subtitle: Text(t.shareme.receive.savedToGallery, style: ShareMeText.meta.copyWith(color: c.ok)),
                        ),
                      for (final f in elsewhere)
                        ListTile(
                          leading: Icon(LucideIcons.file, color: c.ink2),
                          title: Text(f.desiredName ?? f.file.fileName, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            '${_folderOf(f.path!)} · ${formatSize(f.file.size)}',
                            style: ShareMeText.data.copyWith(color: c.ink2),
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: TextButton(
                            onPressed: () async => openFile(context, f.file.fileType, f.path!),
                            child: Text(t.shareme.receive.open),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 26),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: inGallery.isNotEmpty
                            ? () async => android_channel.openGallery()
                            : () async => openFolder(folderPath: session.destinationDirectory),
                        style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(ShareMeSize.buttonH)),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(inGallery.isNotEmpty ? t.shareme.receive.viewInGallery : t.shareme.receive.openFolder, maxLines: 1),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: FilledButton(onPressed: openFirst, child: Text(t.shareme.receive.open)),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _folderOf(String path) {
    if (path.startsWith('content://')) return path;
    final i = path.replaceAll('\\', '/').lastIndexOf('/');
    return i <= 0 ? path : path.substring(0, i);
  }
}

class _Canceled extends StatelessWidget {
  final VoidCallback onClose;

  const _Canceled({required this.onClose});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      child: Column(
        children: [
          const Spacer(),
          Icon(LucideIcons.circleAlert, size: 48, color: c.warn),
          const SizedBox(height: 16),
          Text(
            t.shareme.receive.canceledBySender,
            style: ShareMeText.title.copyWith(color: c.ink, fontSize: 18),
            textAlign: TextAlign.center,
          ),
          const Spacer(flex: 2),
          SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: onClose, child: Text(t.shareme.receive.close)),
          ),
        ],
      ),
    );
  }
}
