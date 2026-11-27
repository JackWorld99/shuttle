import 'dart:async';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/send_mode.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/model/state/send/sending_file.dart';
import 'package:localsend_app/pages/shareme_receive_page.dart' show RequestWarning;
import 'package:localsend_app/pages/tabs/send_tab_vm.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/send_queue_runner.dart';
import 'package:localsend_app/provider/network/shareme_send_resume.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/send_queue_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/message_preview.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/shareme_format.dart';
import 'package:localsend_app/util/shareme_own_page.dart';
import 'package:localsend_app/util/shareme_pairing/pair_crypto.dart' show isTailscaleIp;
import 'package:localsend_app/util/ui/snackbar.dart';
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
import 'package:routerino/routerino.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Shuttle: the send page. One page covers every state of a send:
/// waiting for acceptance → transferring → delivered (stamped) / partly failed / declined or canceled.
///
/// Only replaces LocalSend's sending-side SendPage + ProgressPage (pushed by sendProvider); the transfer logic is unchanged.
/// Leaving the page: while waiting = cancel; while transferring = keep sending in the background ("leaving this page won't
/// stop the transfer"); after it ends = close the session.
class SmSendPage extends StatefulWidget {
  final String sessionId;

  /// When false (LocalSend's "send to multiple devices" mode), leaving the page doesn't close the session.
  final bool closeSessionOnClose;

  const SmSendPage({required this.sessionId, this.closeSessionOnClose = true, super.key});

  /// Sessions with a page on the navigation stack. LocalSend opens a second page once the receiver accepts; this page already covers
  /// that state, and replacing it would cut its animation off.
  static final _open = <String, int>{};

  static bool isOpen(String sessionId) => (_open[sessionId] ?? 0) > 0;

  @override
  State<SmSendPage> createState() => _SmSendPageState();
}

class _SmSendPageState extends State<SmSendPage> with Refena {
  Timer? _tick; // refreshes speed and remaining time every 0.5 s

  /// Goes back to the home page shortly after everything is delivered (one-tap send: no need to tap "Done")
  Timer? _autoBack;

  /// Retries automatically when a send to one of my devices sent nothing at all (usually a temporary connection failure).
  /// At most 2 automatic retries per device within 2 minutes; after that only the "Retry" button remains, so it doesn't
  /// spin forever. A retry closes this page and opens a new one, so the count lives in a static map keyed by the peer's
  /// fingerprint.
  static final _autoRetries = <String, (int, DateTime)>{};
  static const _maxAutoRetries = 2;
  Timer? _autoRetry;
  int? _autoAttempt;

  /// Whether this page has already decided about auto-retry. Decided only once per page: the page refreshes every 0.5 s,
  /// and re-deciding each time would retry again once the failure page had been open for over 2 minutes and the count
  /// reset, so it would never stop.
  bool _autoRetryDecided = false;

  /// Schedules an automatic retry and returns its attempt number; returns null when no retries are left.
  int? _scheduleAutoRetry(SendSessionState session) {
    if (_autoRetryDecided) return _autoAttempt;
    _autoRetryDecided = true;
    final fingerprint = session.target.fingerprint;
    final now = DateTime.now();
    final prev = _autoRetries[fingerprint];
    final fresh = prev == null || now.difference(prev.$2) > const Duration(minutes: 2);
    final done = fresh ? 0 : prev.$1;
    if (done >= _maxAutoRetries) return null;
    _autoRetries[fingerprint] = (done + 1, fresh ? now : prev.$2);
    _autoAttempt = done + 1;
    _autoRetry = Timer(const Duration(seconds: 3), () {
      if (mounted) unawaited(_retryAll(session));
    });
    return _autoAttempt;
  }

  /// Shuttle send queue: a send to one of my devices that couldn't be delivered (not reachable once the automatic retries are used
  /// up, busy, or broken off partway) goes into the send queue by itself, decided once per page. [_queuedAll]: nothing was
  /// delivered by this attempt, so it isn't recorded in the history (the attempt that finally delivers it is).
  bool _queueDecided = false;
  bool _queueing = false;
  String? _queuedId;
  bool _queuedAll = false;

  void _maybeQueue(SendSessionState session, FileTransferNotifier transfers, {required bool nothingSent, required int? autoAttempt}) {
    final insecure = session.errorMessage == t.shareme.send.insecure;
    List<SendingFile>? files;
    var all = false;
    if (session.status == SessionStatus.recipientBusy || (nothingSent && !insecure && autoAttempt == null)) {
      files = session.files.values.toList();
      all = true;
    } else if (session.status == SessionStatus.finishedWithErrors && !nothingSent) {
      final failed = session.files.values
          .where((f) => f.token != null && transfers.getStatus(sessionId: session.sessionId, fileId: f.file.id) == FileStatus.failed)
          .toList();
      if (failed.isNotEmpty) files = failed;
    }
    if (files == null) return;
    _queueDecided = true;
    _queueing = true;
    _queuedAll = all;
    final queued = files;
    // Not during build: queuing writes to disk and changes providers
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_enqueue(session, queued)));
  }

  Future<void> _enqueue(SendSessionState session, List<SendingFile> files) async {
    final favorite = ref.read(favoritesProvider).firstWhereOrNull((f) => f.fingerprint == session.target.fingerprint);
    final alias = favorite?.alias ?? session.target.alias;
    final (:entry, :refusal) = await queueForDevice(ref, fingerprint: session.target.fingerprint, alias: alias, files: _crossFiles(files));
    // Taken care of, as after a delivered send: don't leave "N selected" on the home page (shared files were moved into the queue)
    if (entry != null && ref.read(settingsProvider).sendMode == SendMode.single) {
      ref.redux(selectedSendingFilesProvider).dispatch(ClearSelectionAction());
    }
    if (!mounted) return;
    setState(() {
      _queueing = false;
      _queuedId = entry?.id;
      if (entry == null) _queuedAll = false; // not queued after all: this attempt is the last word
    });
    if (refusal != null) {
      Routerino.context.showSnackBar(refusal == QueueRefusal.full ? t.shareme.queue.full(name: alias) : t.shareme.queue.tooLarge);
    }
  }

  /// "Remove from queue": the batch won't be sent, and this attempt is recorded as it ended
  void _cancelQueued() {
    final id = _queuedId;
    if (id != null) {
      final runner = SendQueueRunner.instance;
      if (runner != null) {
        runner.cancel(id);
      } else {
        ref.redux(sendQueueProvider).dispatch(RemoveQueuedSendsAction.id(id));
      }
    }
    _queuedAll = false;
    _finish();
  }

  static List<CrossFile> _crossFiles(Iterable<SendingFile> files) => [
    for (final f in files)
      CrossFile(
        name: f.file.fileName,
        fileType: f.file.fileType,
        size: f.file.size,
        thumbnail: f.thumbnail,
        asset: f.asset,
        path: f.path,
        bytes: f.bytes,
        lastModified: f.file.metadata?.lastModified,
        lastAccessed: f.file.metadata?.lastAccessed,
      ),
  ];

  // Android stays alive through a foreground service; other platforms use a wakelock to keep the screen on (as in
  // LocalSend's ProgressPage)
  bool get _useWakelock => checkPlatformIsNot([TargetPlatform.android]);

  /// (time, bytes sent) samples from the last 3 s, used for the live speed (the design shows the current speed, not the
  /// overall average)
  final _samples = <(int, int)>[];
  double _speed = 0;

  /// The page as last built while its session existed. Closing the page ends the session first, so this is what stays on screen
  /// during the exit animation (instead of an empty page).
  Widget? _last;

  void _sample() {
    final session = ref.read(sendProvider)[widget.sessionId];
    if (session == null || session.status != SessionStatus.sending) {
      _samples.clear();
      _speed = 0;
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    _samples.add((now, _Totals(session, ref.read(fileTransferProvider)).current));
    _samples.removeWhere((s) => now - s.$1 > 3000);
    if (_samples.length >= 2) {
      final (t0, b0) = _samples.first;
      final (t1, b1) = _samples.last;
      _speed = t1 > t0 ? (b1 - b0) / ((t1 - t0) / 1000) : 0;
    }
  }

  @override
  void initState() {
    super.initState();
    SmSendPage._open[widget.sessionId] = (SmSendPage._open[widget.sessionId] ?? 0) + 1;
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      _sample();
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
    final open = (SmSendPage._open[widget.sessionId] ?? 1) - 1;
    if (open > 0) {
      SmSendPage._open[widget.sessionId] = open;
    } else {
      SmSendPage._open.remove(widget.sessionId);
    }
    _tick?.cancel();
    _autoBack?.cancel();
    _autoRetry?.cancel();
    if (_useWakelock) {
      try {
        unawaited(WakelockPlus.disable());
      } catch (_) {}
    }
    super.dispose();
  }

  /// "Stop sending?" is open
  bool _asking = false;

  void _close() => closeOwnPage(context, () => context.global.dispatch(NavigateAction.popUntilRoot()), ownSheet: _asking);

  /// Cleanup when the page is closed by the back gesture / back button.
  void _onLeave(SendSessionState? session) {
    if (session == null) return;
    final notifier = ref.notifier(sendProvider);
    switch (session.status) {
      case SessionStatus.waiting:
        if (widget.closeSessionOnClose) {
          notifier.cancelSession(widget.sessionId);
        } else {
          notifier.setBackground(widget.sessionId, true);
        }
      case SessionStatus.sending:
        notifier.setBackground(widget.sessionId, true); // keep sending in the background; cleans up by itself when done
      default:
        if (widget.closeSessionOnClose) notifier.closeSession(widget.sessionId, recordHistory: !_queuedAll);
    }
  }

  Future<void> _confirmCancel() async {
    _asking = true;
    final ok = await confirmStopTransfer(context, sending: true);
    _asking = false;
    if (!ok || !mounted) return;
    ref.notifier(sendProvider).cancelSession(widget.sessionId);
    _close();
  }

  void _finish() {
    ref.notifier(sendProvider).closeSession(widget.sessionId, recordHistory: !_queuedAll);
    _close();
  }

  /// "Retry" when nothing was sent: sends the same files to the same device again (at its currently discovered address).
  Future<void> _retryAll(SendSessionState session) async {
    final files = _crossFiles(session.files.values);
    final target = ref.read(sendTabVmProvider).nearbyDevices.firstWhereOrNull((d) => d.fingerprint == session.target.fingerprint) ?? session.target;
    final notifier = ref.notifier(sendProvider);
    // Not recorded in the sent history: nothing of it arrived, and the new attempt is the same send (it is recorded when it
    // ends, or when the send queue finally delivers it). Otherwise each automatic retry left a "not delivered" entry.
    notifier.closeSession(widget.sessionId, recordHistory: false);
    _close();
    await notifier.startSession(target: target, files: files, background: false);
  }

  /// Shuttle: "Continue sending" after a lost connection: the interrupted files continue where they stopped, at the
  /// receiver's current address.
  Future<void> _continue(SendSessionState session) async {
    final target = ref.read(sendTabVmProvider).nearbyDevices.firstWhereOrNull((d) => d.fingerprint == session.target.fingerprint);
    await ref.notifier(sendProvider).continueSession(session.sessionId, target: target);
  }

  Future<void> _retryFailed(SendSessionState session, FileTransferNotifier transfers) async {
    final failed = session.files.values.where(
      (f) => f.token != null && transfers.getStatus(sessionId: session.sessionId, fileId: f.file.id) == FileStatus.failed,
    );
    for (final f in failed) {
      await ref.notifier(sendProvider).sendFile(sessionId: session.sessionId, file: f, isRetry: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch(sendProvider)[widget.sessionId];
    final transfers = context.watch(fileTransferProvider);
    final resume = context.watch(sendResumeProvider).get(widget.sessionId); // Shuttle

    if (session == null) {
      // The session is gone (e.g. removed automatically after a successful background send).
      // Only while this page is still on the navigation stack (see closeOwnPage). Once it is closed and playing its exit
      // animation (e.g. after "Retry": this page closes, then a new send page opens), the 0.5 s refresh still rebuilds it;
      // going home then would also close the new send page, and the new send would count as "you canceled".
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _close();
      });
      return IgnorePointer(child: _last ?? const SmScaffold(body: SizedBox.shrink()));
    }

    final isMine = context.watch(favoritesProvider).any((f) => f.fingerprint == session.target.fingerprint);
    if (session.status == SessionStatus.finished && _autoBack == null) {
      _autoRetries.remove(session.target.fingerprint); // delivered: reset the auto-retry count
      _autoBack = Timer(_autoBackAfter, () {
        if (mounted) _finish();
      });
    }
    final nothingSent = session.status == SessionStatus.finishedWithErrors && _nothingSent(session, transfers);
    // A send started by the queue: its failures are the queue's business (it keeps the batch and tries again), so no automatic
    // retry here and no queuing it a second time
    final fromQueue = SendQueueRunner.isQueueSession(session.sessionId);
    final autoAttempt = nothingSent && isMine && !fromQueue && session.errorMessage != t.shareme.send.insecure ? _scheduleAutoRetry(session) : null;
    if (isMine && !fromQueue && !_queueDecided) _maybeQueue(session, transfers, nothingSent: nothingSent, autoAttempt: autoAttempt);
    final queued = _queueDecided && (_queueing || _queuedId != null);
    final sending = session.status == SessionStatus.sending;
    final waiting = session.status == SessionStatus.waiting;

    final page = PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _onLeave(ref.read(sendProvider)[widget.sessionId]);
      },
      child: SmScaffold(
        body: SafeArea(
          child: Column(
            children: [
              TransferTopBar(
                title: session.target.alias,
                // While waiting, leaving cancels, so there is only "Cancel" then
                leading: sending
                    ? IconButton(
                        icon: const Icon(LucideIcons.chevronDown),
                        tooltip: t.shareme.send.leaveHint,
                        onPressed: () => Navigator.of(context).maybePop(),
                      )
                    : null,
                trailing: sending || waiting
                    ? TextButton(
                        onPressed: sending ? _confirmCancel : () => Navigator.of(context).maybePop(),
                        child: Text(t.shareme.send.cancel, style: ShareMeText.label.copyWith(color: context.sm.ink2)),
                      )
                    : null,
              ),
              Expanded(
                child: SmMaxWidth(
                  maxWidth: 480,
                  child: _Stage(
                    session: session,
                    isMine: isMine,
                    transfers: transfers,
                    liveSpeed: _speed,
                    nothingSent: nothingSent,
                    autoAttempt: autoAttempt,
                    queued: queued,
                    fromQueue: fromQueue,
                    onCancelQueued: _queuedId == null ? null : _cancelQueued,
                    onDone: _finish,
                    onRetryAll: () async => _retryAll(session),
                    onRetryFailed: () async => _retryFailed(session, transfers),
                    resume: resume,
                    onContinue: () async => _continue(session),
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

/// How long "Delivered" stays before the page closes by itself
const _autoBackAfter = Duration(milliseconds: 3000);

/// Byte totals and progress of the files the peer accepted in one session.
class _Totals {
  final int total;
  final int current;
  final int count;
  final int doneCount;

  _Totals(SendSessionState s, FileTransferNotifier t)
    : this._(
        s.files.values.where((f) => t.getStatus(sessionId: s.sessionId, fileId: f.file.id) != FileStatus.skipped).toList(),
        s.sessionId,
        t,
        s.status == SessionStatus.waiting,
      );

  /// [connecting]: still connecting to the peer (the session is waiting). Each file's "progress" is then the checksum
  /// progress before sending, not the amount sent, so it counts as 0 (otherwise sending to a PC that was off showed "100%"
  /// with not a single byte sent).
  _Totals._(List<SendingFile> files, String sessionId, FileTransferNotifier t, bool connecting)
    : total = files.fold(0, (a, f) => a + f.file.size),
      current = connecting ? 0 : files.fold(0, (a, f) => a + (t.getProgress(sessionId: sessionId, fileId: f.file.id) * f.file.size).round()),
      count = files.length,
      doneCount = connecting ? 0 : files.where((f) => t.getStatus(sessionId: sessionId, fileId: f.file.id) == FileStatus.finished).length;
}

/// The session errored and no file finished or was marked failed: it failed at the "prepare upload" step (peer
/// unreachable, peer error, etc.).
bool _nothingSent(SendSessionState session, FileTransferNotifier transfers) => session.files.values.every((f) {
  final s = transfers.getStatus(sessionId: session.sessionId, fileId: f.file.id);
  return s != FileStatus.finished && s != FileStatus.failed;
});

// ───────────────────────── The stage ─────────────────────────

/// One continuous picture for every state: what is being sent on top, the two devices with the line between them, and one short
/// block of text. When it arrives, the pictures fly into the receiving device and the rest settles in the middle.
class _Stage extends StatelessWidget {
  final SendSessionState session;
  final bool isMine;
  final FileTransferNotifier transfers;

  /// Live speed over the last 3 s; falls back to the overall average until there are enough samples
  final double liveSpeed;
  final bool nothingSent;

  /// For my devices an automatic retry follows shortly: its attempt number (null = no automatic retry)
  final int? autoAttempt;

  /// Shuttle send queue: what didn't arrive was put into the queue ([onCancelQueued] takes it out again)
  final bool queued;

  /// This send was started by the queue (a failure keeps it in the queue)
  final bool fromQueue;
  final VoidCallback? onCancelQueued;
  final VoidCallback onDone;
  final VoidCallback onRetryAll;
  final VoidCallback onRetryFailed;

  /// Shuttle: continuing interrupted files (resume)
  final SendResume? resume;
  final VoidCallback onContinue;

  const _Stage({
    required this.session,
    required this.isMine,
    required this.transfers,
    required this.liveSpeed,
    required this.nothingSent,
    required this.autoAttempt,
    this.queued = false,
    this.fromQueue = false,
    this.onCancelQueued,
    required this.onDone,
    required this.onRetryAll,
    required this.onRetryFailed,
    required this.resume,
    required this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    final totals = _Totals(session, transfers);
    final ratio = totals.total == 0 ? 0.0 : (totals.current / totals.total).clamp(0.0, 1.0);
    final failed = [
      if (session.status == SessionStatus.finishedWithErrors && !nothingSent)
        for (final f in session.files.values)
          if (transfers.getStatus(sessionId: session.sessionId, fileId: f.file.id) == FileStatus.failed) f,
    ];
    final delivered =
        session.status == SessionStatus.finished || (session.status == SessionStatus.finishedWithErrors && !nothingSent && failed.isEmpty);
    final phase = switch (session.status) {
      SessionStatus.waiting => ScenePhase.waiting,
      SessionStatus.sending => ScenePhase.moving,
      _ => delivered ? ScenePhase.done : ScenePhase.broken,
    };

    return TransferStage(
      phase: phase,
      progress: ratio,
      from: (size) => DeviceAvatar(deviceType: checkPlatformIsDesktop() ? DeviceType.desktop : DeviceType.mobile, size: size, mine: true),
      to: (size) => DeviceAvatar(deviceType: session.target.deviceType, size: size, mine: isMine),
      frames: _frames(session),
      sceneAtTop: failed.isNotEmpty,
      // Same key as the moving text, so the number simply runs up to 100
      arrivingText: Column(
        key: const ValueKey('moving'),
        children: [
          const BigPercent(1, glide: Duration(milliseconds: 300)),
          const SizedBox(height: 4),
          Text('', style: ShareMeText.body.copyWith(fontSize: 14)),
        ],
      ),
      text: switch (phase) {
        ScenePhase.waiting => _waitingText(context),
        ScenePhase.moving => _movingText(context, totals, ratio),
        ScenePhase.done => _doneText(context),
        ScenePhase.broken =>
          failed.isNotEmpty
              ? _failedText(context, failed, totals, ratio)
              : _StoppedText(key: ValueKey('stopped-$queued'), session: session, queued: queued, fromQueue: fromQueue),
      },
      bottom: _bottom(context, phase, failed.isNotEmpty),
    );
  }

  /// Shuttle: the percentage shown in the resume texts (never 0 or 100 for a transfer that is neither).
  static int _percent(double ratio) => (ratio * 100).floor().clamp(0, 99);

  static List<FilmFrame> _frames(SendSessionState s) => [
    for (final f in s.files.values)
      _isMessage(f)
          ? FilmFrame(fileName: messageLabelOf(f.bytes!), fileType: FileType.text, path: null, isMessage: true)
          : FilmFrame(fileName: f.file.fileName, fileType: f.file.fileType, path: f.path, assetId: f.asset?.id, bytes: f.thumbnail),
  ];

  /// Text and links are sent as an in-memory text file
  static bool _isMessage(SendingFile f) => f.file.fileType == FileType.text && f.path == null && f.bytes != null;

  Widget _summary() => ContentSummary(
    files: [for (final f in session.files.values) (f.file.fileName, f.file.fileType)],
    bytes: session.files.values.fold<int>(0, (a, f) => a + f.file.size),
    message: session.files.values.every(_isMessage),
    alignment: WrapAlignment.center,
  );

  Widget _waitingText(BuildContext context) {
    // Checksums are computed before the request goes out (a few seconds for 200 photos); not connecting yet
    final preparing = session.hashedFileCount < session.files.length;
    return StageText(
      key: ValueKey('waiting-$preparing'),
      title: preparing
          ? t.shareme.send.preparing(curr: session.hashedFileCount, n: session.files.length)
          : isMine
          ? t.shareme.send.connecting
          : t.shareme.send.waitingTitle(name: session.target.alias),
      children: [_summary(), ..._notEncrypted()],
    );
  }

  /// Sending to a device without encryption (its encryption is off): said for as long as it lasts
  List<Widget> _notEncrypted() => session.target.https
      ? const []
      : [
          const SizedBox(height: 14),
          RequestWarning(text: t.shareme.send.notEncrypted),
        ];

  Widget _movingText(BuildContext context, _Totals totals, double ratio) {
    final c = context.sm;
    final start = session.startTime;
    final elapsedMs = start == null ? 0 : DateTime.now().millisecondsSinceEpoch - start;
    final average = elapsedMs > 500 ? totals.current / (elapsedMs / 1000) : 0.0;
    final speed = liveSpeed > 0 ? liveSpeed : average;
    final remaining = speed > 0 ? Duration(seconds: ((totals.total - totals.current) / speed).round()) : null;
    // Shuttle: the connection was lost and the transfer continues by itself (resume)
    final reconnecting = resume?.reconnectAttempt != null;
    final continuedBytes = resume?.continuedBytes ?? 0;
    return Column(
      key: const ValueKey('moving'),
      children: [
        // While reconnecting, not above the 99 % the line below says: the sender may have handed (nearly) everything to the
        // network before the connection broke, but the receiver hasn't stored it all, so it isn't done
        BigPercent(reconnecting ? math.min(ratio, 0.99) : ratio),
        const SizedBox(height: 4),
        if (reconnecting)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, color: c.ink2)),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  t.shareme.resume.sendReconnecting(percent: _percent(ratio)),
                  style: ShareMeText.body.copyWith(color: c.ink2, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          )
        else
          Text(
            formatPace(left: remaining, speed: speed),
            style: ShareMeText.body.copyWith(color: c.ink2, fontSize: 14),
          ),
        if (!reconnecting && continuedBytes > 0 && totals.total > 0) ...[
          const SizedBox(height: 4),
          Text(
            t.shareme.resume.sendContinuingFrom(percent: _percent(continuedBytes / totals.total)),
            style: ShareMeText.meta.copyWith(color: c.ink2),
          ),
        ],
        ..._notEncrypted(),
      ],
    );
  }

  Widget _doneText(BuildContext context) => StageText(
    key: const ValueKey('done'),
    title: t.shareme.send.delivered,
    titleSize: 30,
    children: [
      Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 8,
        children: [
          _summary(),
          // No check mark: only the receiver can verify the checksums
          if (!session.files.values.every(_isMessage)) const OriginalChip(verified: false),
        ],
      ),
    ],
  );

  Widget _failedText(BuildContext context, List<SendingFile> failed, _Totals totals, double ratio) {
    final c = context.sm;
    // Shuttle: interrupted by a lost connection, the receiver keeps what arrived (resume)
    final canContinue = resume?.canContinue == true;
    return Column(
      key: const ValueKey('failed'),
      children: [
        Text(
          canContinue
              ? t.shareme.resume.sendNotFinished(percent: _percent(ratio), size: formatSize(totals.current))
              : t.shareme.send.failedTitle(n: failed.length),
          style: ShareMeText.display.copyWith(color: c.warn, fontSize: canContinue ? 20 : 24),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 18),
        SmCard(
          child: Column(
            children: [
              for (final (i, f) in failed.indexed) ...[
                if (i > 0) Divider(height: 1, indent: 70, color: c.line),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      FileThumb(
                        frame: FilmFrame(fileName: f.file.fileName, fileType: f.file.fileType, path: f.path, assetId: f.asset?.id),
                        size: 42,
                        radius: 12,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          f.file.fileName,
                          style: ShareMeText.body.copyWith(color: c.ink, fontSize: 14.5),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        if (queued || fromQueue) ...[
          const SizedBox(height: 14),
          Text(
            queued ? t.shareme.queue.pageQueued(name: session.target.alias) : t.shareme.queue.stillQueued(name: session.target.alias),
            style: ShareMeText.body.copyWith(color: c.ink2),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }

  Widget? _bottom(BuildContext context, ScenePhase phase, bool someFailed) {
    final c = context.sm;
    if (phase == ScenePhase.done) {
      return Padding(
        key: const ValueKey('done'),
        padding: BottomActions.padding,
        child: CountdownButton(
          label: t.shareme.send.done,
          // The button fills up while the page waits to close by itself
          countdown: session.status == SessionStatus.finished ? _autoBackAfter - TransferStage.flight : null,
          onPressed: onDone,
        ),
      );
    }
    if (phase != ScenePhase.broken) return null;
    if (queued) {
      return BottomActions(
        key: const ValueKey('queued'),
        secondaryLabel: t.shareme.queue.cancelQueued,
        onSecondary: onCancelQueued,
        primaryLabel: t.shareme.queue.ok,
        onPrimary: onDone,
      );
    }
    if (fromQueue) {
      return Padding(
        key: const ValueKey('back'),
        padding: BottomActions.padding,
        child: SizedBox(
          width: double.infinity,
          child: FilledButton(onPressed: onDone, child: Text(t.shareme.send.back)),
        ),
      );
    }
    if (someFailed && resume?.canContinue == true) {
      // Shuttle: continues where it stopped (resume)
      return BottomActions(
        key: const ValueKey('continue'),
        secondaryLabel: t.shareme.send.done,
        onSecondary: onDone,
        primaryLabel: t.shareme.resume.sendContinue,
        onPrimary: onContinue,
      );
    }
    if (someFailed) {
      return BottomActions(
        key: const ValueKey('failed'),
        secondaryLabel: t.shareme.send.done,
        onSecondary: onDone,
        primaryLabel: t.shareme.send.retry,
        onPrimary: onRetryFailed,
      );
    }
    final insecure = session.errorMessage == t.shareme.send.insecure;
    if (nothingSent && !insecure) {
      return Column(
        key: const ValueKey('retry'),
        mainAxisSize: MainAxisSize.min,
        children: [
          if (autoAttempt != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, color: c.ink2)),
                  const SizedBox(width: 8),
                  Text(
                    t.shareme.send.autoRetrying(n: autoAttempt!),
                    style: ShareMeText.meta.copyWith(color: c.ink2),
                  ),
                ],
              ),
            ),
          BottomActions(
            secondaryLabel: t.shareme.send.back,
            onSecondary: onDone,
            primaryLabel: t.shareme.send.retryAll,
            onPrimary: onRetryAll,
          ),
        ],
      );
    }
    return Padding(
      key: const ValueKey('back'),
      padding: BottomActions.padding,
      child: SizedBox(
        width: double.infinity,
        child: FilledButton(onPressed: onDone, child: Text(t.shareme.send.back)),
      ),
    );
  }
}

/// Declined, busy, canceled or not sent. The reason is a single sentence; the raw error is tucked under "Details".
class _StoppedText extends StatefulWidget {
  final SendSessionState session;

  /// Shuttle send queue: it was put into the queue / it came from the queue and stays there
  final bool queued;
  final bool fromQueue;

  const _StoppedText({required this.session, this.queued = false, this.fromQueue = false, super.key});

  @override
  State<_StoppedText> createState() => _StoppedTextState();
}

class _StoppedTextState extends State<_StoppedText> {
  bool _details = false;

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final session = widget.session;
    final name = session.target.alias;
    final busy = session.status == SessionStatus.recipientBusy;
    final message = switch (session.status) {
      _ when widget.queued => busy ? t.shareme.queue.busyTitle(name: name) : t.shareme.queue.cantReach(name: name),
      SessionStatus.declined => t.shareme.send.declined(name: name),
      SessionStatus.recipientBusy => t.shareme.send.busy(name: name),
      SessionStatus.tooManyAttempts => t.shareme.send.tooMany,
      SessionStatus.canceledByReceiver => t.shareme.send.canceledByReceiver(name: name),
      SessionStatus.finishedWithErrors => t.shareme.send.notSent(name: name),
      _ => t.shareme.send.canceledBySender,
    };
    // Not sent because the connection isn't encrypted (security fix): the reason is that safety note, shown as is, no retry
    final insecure = session.errorMessage == t.shareme.send.insecure;
    final notSent = session.status == SessionStatus.finishedWithErrors && !insecure;
    final reason = widget.queued
        ? (busy ? t.shareme.queue.pageBusyQueued(name: name) : t.shareme.queue.pageQueued(name: name))
        : insecure
        ? session.errorMessage
        : widget.fromQueue && (notSent || busy)
        ? t.shareme.queue.stillQueued(name: name)
        : notSent
        ? (isTailscaleIp(session.target.ip) ? t.shareme.send.notSentReasonRemote : t.shareme.send.notSentReason)
        : null;
    final details = notSent ? session.errorMessage : null;
    return StageText(
      title: message,
      children: [
        if (reason != null)
          Text(
            reason,
            style: ShareMeText.body.copyWith(color: c.ink2),
            textAlign: TextAlign.center,
          ),
        if (details != null) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => setState(() => _details = !_details),
            icon: Icon(_details ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 16, color: c.ink3),
            label: Text(t.shareme.send.details, style: ShareMeText.meta.copyWith(color: c.ink2)),
          ),
          if (_details)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: smInsetDecoration(c, radius: 12),
              child: SelectableText(details, style: ShareMeText.meta.copyWith(color: c.ink2, fontSize: 12)),
            ),
        ],
      ],
    );
  }
}

/// Finds the active send session for a device (used by the device rows on the home page).
SendSessionState? activeSendSessionFor(Map<String, SendSessionState> sessions, String fingerprint) => sessions.values.firstWhereOrNull(
  (s) => s.target.fingerprint == fingerprint && (s.status == SessionStatus.waiting || s.status == SessionStatus.sending),
);
