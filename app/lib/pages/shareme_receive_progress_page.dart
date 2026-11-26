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
import 'package:localsend_app/util/shareme_own_page.dart';
import 'package:localsend_app/util/shareme_resume.dart';
import 'package:localsend_app/widget/shareme/ambient.dart';
import 'package:localsend_app/widget/shareme/bottom_actions.dart';
import 'package:localsend_app/widget/shareme/content_stack.dart';
import 'package:localsend_app/widget/shareme/device_avatar.dart';
import 'package:localsend_app/widget/shareme/film_strip.dart';
import 'package:localsend_app/widget/shareme/sm_card.dart';
import 'package:localsend_app/widget/shareme/sm_sheets.dart';
import 'package:localsend_app/widget/shareme/transfer_scene.dart';
import 'package:localsend_app/widget/shareme/transfer_stage.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Shuttle: receive progress + done page.
/// Replaces LocalSend's ProgressPage on the receiving side (the sending side uses SmSendPage).
///
/// While files arrive it is the same scene as the send page, the other way round. Once everything is there, the pictures take over:
/// one block of photos, then any other files, then the buttons. The "original" chip gets its check mark only when every file's
/// SHA-256 was verified.
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

  /// The arrival plays first, then the received files appear
  bool _showResult = false;
  Timer? _resultTimer;
  bool _firstBuild = true;

  /// The page as last built while its session existed: stays on screen during the exit animation (see SmSendPage)
  Widget? _last;

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
    _resultTimer?.cancel();
    if (_useWakelock) {
      try {
        unawaited(WakelockPlus.disable());
      } catch (_) {}
    }
    super.dispose();
  }

  /// "Stop receiving?" is open
  bool _asking = false;

  void _leave() => closeOwnPage(context, () => context.global.dispatch(NavigateAction.popUntil<WebSharePage>()), ownSheet: _asking);

  /// Leaving mid-transfer first asks to confirm the cancel (as in LocalSend); once finished, it closes the session.
  Future<void> _exit() async {
    final session = ref.read(serverProvider)?.session;
    final status = session?.status;
    if (status == SessionStatus.sending || status == SessionStatus.waiting) {
      _asking = true;
      final ok = await confirmStopTransfer(context, sending: false);
      _asking = false;
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

    // Shuttle: a session continued in a new one (the sender lost its connection) stays on this page
    if (session == null || !ReceiveContinuation.continuesTo(widget.sessionId, session.sessionId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _leave();
      });
      return IgnorePointer(child: _last ?? const SmScaffold(body: SizedBox.shrink()));
    }

    final isMine = context.watch(favoritesProvider).any((f) => f.fingerprint == session.sender.fingerprint);
    final verifyOn = context.watch(settingsProvider.select((s) => s.verifyChecksums));
    final finished = _finished(session.status);
    final live = session.status == SessionStatus.sending || session.status == SessionStatus.waiting;
    if (_firstBuild) {
      _firstBuild = false;
      _showResult = finished; // opened after the fact: nothing left to play
    }
    // Something is missing: say so at once instead of playing the arrival first
    if (session.status == SessionStatus.finishedWithErrors) _showResult = true;
    if (finished && !_showResult && _resultTimer == null) {
      _resultTimer = Timer(MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 1200), () {
        if (mounted) setState(() => _showResult = true);
      });
    }

    final page = PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) await _exit();
      },
      child: SmScaffold(
        body: SafeArea(
          child: Column(
            children: [
              TransferTopBar(
                title: session.senderAlias,
                leading: live
                    ? null
                    : IconButton(
                        icon: const Icon(LucideIcons.x),
                        tooltip: t.shareme.receive.close,
                        onPressed: _exit,
                      ),
                trailing: live
                    ? TextButton(
                        onPressed: _exit,
                        child: Text(t.shareme.send.cancel, style: ShareMeText.label.copyWith(color: context.sm.ink2)),
                      )
                    : null,
              ),
              Expanded(
                child: SmMaxWidth(
                  maxWidth: 480,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Out of sight while the arrival plays, so the pictures are decoded by the time the result appears
                      if (finished && !_showResult)
                        Offstage(
                          child: _Received(session: session, transfers: transfers, verifyOn: verifyOn, onClose: _exit),
                        ),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 420),
                        switchInCurve: const Interval(0.22, 1, curve: Curves.easeOutCubic),
                        switchOutCurve: const Interval(0.4, 1, curve: Curves.easeIn),
                        child: finished && _showResult
                            ? _Received(key: const ValueKey('result'), session: session, transfers: transfers, verifyOn: verifyOn, onClose: _exit)
                            : _Receiving(
                                key: const ValueKey('stage'),
                                session: session,
                                isMine: isMine,
                                transfers: transfers,
                                liveSpeed: _speed,
                                onClose: _exit,
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    _last = page;
    return IgnorePointer(ignoring: false, child: page);
  }
}

bool _finished(SessionStatus? status) => status == SessionStatus.finished || status == SessionStatus.finishedWithErrors;

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

/// Shuttle: after this long without data, the page says the connection seems lost.
const _seemsLostAfter = Duration(seconds: 30);

class _Receiving extends StatelessWidget {
  final ReceiveSessionState session;
  final bool isMine;
  final FileTransferNotifier transfers;
  final double liveSpeed;
  final VoidCallback onClose;

  const _Receiving({
    required this.session,
    required this.isMine,
    required this.transfers,
    required this.liveSpeed,
    required this.onClose,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final (total, current) = _bytes(session, transfers);
    final ratio = total == 0 ? 0.0 : (current / total).clamp(0.0, 1.0);
    final remaining = liveSpeed > 0 ? Duration(seconds: ((total - current) / liveSpeed).round()) : null;
    final phase = switch (session.status) {
      SessionStatus.waiting => ScenePhase.waiting,
      SessionStatus.sending => ScenePhase.moving,
      SessionStatus.finished || SessionStatus.finishedWithErrors => ScenePhase.done,
      _ => ScenePhase.broken,
    };
    final accepted = session.files.values
        .where((f) => transfers.getStatus(sessionId: session.sessionId, fileId: f.file.id) != FileStatus.skipped)
        .toList();
    // Files that are already here come first, so the pictures show up as they arrive
    final frames = [
      for (final f in [...accepted.where((f) => f.path != null || f.savedToGallery), ...accepted.where((f) => f.path == null && !f.savedToGallery)])
        FilmFrame(fileName: f.desiredName ?? f.file.fileName, fileType: f.file.fileType, path: f.path, inGallery: f.savedToGallery),
    ];
    return TransferStage(
      phase: phase,
      progress: ratio,
      settles: false, // the result page follows right away
      from: (size) => DeviceAvatar(deviceType: session.sender.deviceType, size: size, mine: isMine),
      to: (size) => DeviceAvatar(deviceType: checkPlatformIsDesktop() ? DeviceType.desktop : DeviceType.mobile, size: size, mine: true),
      frames: frames,
      arrivingText: Column(
        key: const ValueKey('moving'),
        children: [
          const BigPercent(1, glide: Duration(milliseconds: 300)),
          const SizedBox(height: 4),
          Text('', style: ShareMeText.body.copyWith(fontSize: 14)),
        ],
      ),
      text: switch (phase) {
        ScenePhase.waiting => StageText(key: const ValueKey('waiting'), title: t.shareme.receive.preparing),
        ScenePhase.moving => Column(
          key: const ValueKey('moving'),
          children: [
            BigPercent(ratio),
            const SizedBox(height: 4),
            // Shuttle: nothing arrived for a while: the sender continues where it stopped once it is back (resume)
            if ((ReceiveContinuation.idleFor(session.sessionId) ?? Duration.zero) > _seemsLostAfter)
              Text(
                t.shareme.resume.receiveSeemsLost,
                style: ShareMeText.body.copyWith(color: c.ink2, fontSize: 14),
                textAlign: TextAlign.center,
              )
            else
              Text(
                formatPace(left: remaining, speed: liveSpeed),
                style: ShareMeText.body.copyWith(color: c.ink2, fontSize: 14),
              ),
          ],
        ),
        ScenePhase.done => StageText(
          key: const ValueKey('done'),
          title: t.shareme.receive.receivedTitle(n: accepted.length),
          titleSize: 28,
        ),
        ScenePhase.broken => StageText(key: const ValueKey('broken'), title: t.shareme.receive.canceledBySender),
      },
      bottom: phase == ScenePhase.broken
          ? Padding(
              padding: BottomActions.padding,
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: onClose, child: Text(t.shareme.receive.close)),
              ),
            )
          : null,
    );
  }
}

// ───────────────────────── Received ─────────────────────────

class _Received extends StatelessWidget {
  final ReceiveSessionState session;
  final FileTransferNotifier transfers;
  final bool verifyOn;
  final VoidCallback onClose;

  const _Received({required this.session, required this.transfers, required this.verifyOn, required this.onClose, super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    FileStatus status(ReceivingFile f) => transfers.getStatus(sessionId: session.sessionId, fileId: f.file.id);
    final done = session.files.values.where((f) => status(f) == FileStatus.finished).toList();
    final failed = session.files.values.where((f) => status(f) == FileStatus.failed).toList();
    final bytes = done.fold<int>(0, (a, f) => a + f.file.size);
    // "Verified" only if every received file came with a SHA-256 and checksum verification is on here (on a mismatch the
    // core fails the file, so it never shows up in done)
    final verified = verifyOn && done.isNotEmpty && done.every((f) => f.file.hash != null);
    final inGallery = done.any((f) => f.savedToGallery);
    bool isMedia(ReceivingFile f) => f.file.fileType == FileType.image || f.file.fileType == FileType.video;
    final media = done.where(isMedia).toList();
    final others = done.where((f) => !isMedia(f)).toList();
    final openable = done.where((f) => !f.savedToGallery && f.path != null).toList();

    Future<void> open(ReceivingFile f) async {
      if (f.savedToGallery) {
        await android_channel.openGallery();
      } else if (f.path != null) {
        await openFile(context, f.file.fileType, f.path!);
      }
    }

    Future<void> showFolder() async => openFolder(folderPath: session.destinationDirectory);

    final list = ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                done.isEmpty ? t.shareme.receive.failedTitle(n: failed.length) : t.shareme.receive.receivedTitle(n: done.length),
                style: ShareMeText.display.copyWith(color: done.isEmpty ? c.warn : c.ink),
              ),
              if (done.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: ContentSummary(
                        files: [for (final f in done) (f.desiredName ?? f.file.fileName, f.file.fileType)],
                        bytes: bytes,
                      ),
                    ),
                    const SizedBox(width: 12),
                    OriginalChip(verified: verified),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (media.isNotEmpty)
          MediaMosaic(
            frames: [
              for (final f in media)
                FilmFrame(
                  fileName: f.desiredName ?? f.file.fileName,
                  fileType: f.file.fileType,
                  path: f.path,
                  inGallery: f.savedToGallery,
                ),
            ],
            onTap: (i) async => open(media[i]),
          ),
        if (others.isNotEmpty) ...[
          if (media.isNotEmpty) const SizedBox(height: 14),
          SmCard(
            child: Column(
              children: [
                for (final (i, f) in others.indexed) ...[
                  if (i > 0) Divider(height: 1, thickness: 1, indent: 72, color: c.line),
                  _FileRow(
                    name: f.desiredName ?? f.file.fileName,
                    type: f.file.fileType,
                    size: f.file.size,
                    onTap: f.path == null && !f.savedToGallery ? null : () async => open(f),
                  ),
                ],
              ],
            ),
          ),
        ],
        if (failed.isNotEmpty && done.isNotEmpty) ...[
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              t.shareme.receive.failedTitle(n: failed.length),
              style: ShareMeText.title.copyWith(color: c.warn),
            ),
          ),
        ],
        for (final f in failed)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
            child: Text(
              '${f.desiredName ?? f.file.fileName}${f.errorMessage == null ? '' : ': ${f.errorMessage}'}',
              style: ShareMeText.meta.copyWith(color: c.ink2),
            ),
          ),
      ],
    );
    if (done.isEmpty) {
      return Column(
        children: [
          Expanded(child: list),
          _SingleAction(label: t.shareme.receive.close, onPressed: onClose),
        ],
      );
    }
    return Column(
      children: [
        Expanded(child: SmFadeBottom(child: list)),
        if (inGallery)
          _SingleAction(label: t.shareme.receive.viewInGallery, onPressed: () async => android_channel.openGallery())
        else if (openable.length == 1)
          BottomActions(
            secondaryLabel: t.shareme.receive.openFolder,
            onSecondary: showFolder,
            primaryLabel: t.shareme.receive.open,
            onPrimary: () async => open(openable.first),
          )
        else
          _SingleAction(label: t.shareme.receive.openFolder, onPressed: showFolder),
      ],
    );
  }
}

class _SingleAction extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const _SingleAction({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: BottomActions.padding,
      child: SizedBox(
        width: double.infinity,
        child: FilledButton(onPressed: onPressed, child: Text(label)),
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  final String name;
  final FileType type;
  final int size;
  final VoidCallback? onTap;

  const _FileRow({required this.name, required this.type, required this.size, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(
          children: [
            FileThumb(
              frame: FilmFrame(fileName: name, fileType: type, path: null),
              size: 44,
              radius: 13,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: ShareMeText.body.copyWith(color: c.ink, fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(formatSize(size), style: ShareMeText.data.copyWith(color: c.ink2)),
                ],
              ),
            ),
            if (onTap != null) Icon(LucideIcons.chevronRight, size: 20, color: c.ink3),
          ],
        ),
      ),
    );
  }
}
