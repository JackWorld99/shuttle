import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/model/state/send/sending_file.dart';
import 'package:localsend_app/pages/tabs/send_tab_vm.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/shareme_format.dart';
import 'package:localsend_app/util/shareme_pairing/pair_crypto.dart' show isTailscaleIp;
import 'package:localsend_app/widget/dialogs/cancel_session_dialog.dart';
import 'package:localsend_app/widget/shareme/device_avatar.dart';
import 'package:localsend_app/widget/shareme/stamp.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_status.dart';
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

  @override
  State<SmSendPage> createState() => _SmSendPageState();
}

class _SmSendPageState extends State<SmSendPage> with Refena {
  Timer? _tick; // refreshes speed and remaining time every 0.5 s

  /// Goes back to the home page 2 s after everything is delivered (one-tap send: no need to tap "Done")
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

  // Android stays alive through a foreground service; other platforms use a wakelock to keep the screen on (as in
  // LocalSend's ProgressPage)
  bool get _useWakelock => checkPlatformIsNot([TargetPlatform.android]);

  /// (time, bytes sent) samples from the last 3 s, used for the live speed (the design shows the current speed, not the
  /// overall average)
  final _samples = <(int, int)>[];
  double _speed = 0;

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

  void _toRoot() => context.global.dispatch(NavigateAction.popUntilRoot());

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
        if (widget.closeSessionOnClose) notifier.closeSession(widget.sessionId);
    }
  }

  Future<void> _confirmCancel() async {
    final ok = (await context.pushBottomSheet(() => const CancelSessionDialog())) == true;
    if (!ok || !mounted) return;
    ref.notifier(sendProvider).cancelSession(widget.sessionId);
    _toRoot();
  }

  void _finish() {
    ref.notifier(sendProvider).closeSession(widget.sessionId);
    _toRoot();
  }

  /// "Retry" when nothing was sent: sends the same files to the same device again (at its currently discovered address).
  Future<void> _retryAll(SendSessionState session) async {
    final files = [
      for (final f in session.files.values)
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
    final target = ref.read(sendTabVmProvider).nearbyDevices.firstWhereOrNull((d) => d.fingerprint == session.target.fingerprint) ?? session.target;
    final notifier = ref.notifier(sendProvider);
    notifier.closeSession(widget.sessionId);
    _toRoot();
    await notifier.startSession(target: target, files: files, background: false);
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

    if (session == null) {
      // The session is gone (e.g. removed automatically after a successful background send).
      // Only go back home while this page is still on the navigation stack. Once it is closed and playing its exit
      // animation (e.g. after "Retry": this page closes, then a new send page opens), the 0.5 s refresh still rebuilds it;
      // going home then would also close the new send page, and the new send would count as "you canceled".
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && (ModalRoute.of(context)?.isActive ?? false)) _toRoot();
      });
      return const Scaffold(body: SizedBox.shrink());
    }

    final myFingerprint = context.watch(securityProvider).certificateHash;
    final isMine = context.watch(favoritesProvider).any((f) => f.fingerprint == session.target.fingerprint);
    if (session.status == SessionStatus.finished && _autoBack == null) {
      _autoRetries.remove(session.target.fingerprint); // delivered: reset the auto-retry count
      _autoBack = Timer(const Duration(seconds: 2), () {
        if (mounted) _finish();
      });
    }
    final nothingSent = session.status == SessionStatus.finishedWithErrors && _nothingSent(session, transfers);
    final autoAttempt = nothingSent && isMine && session.errorMessage != t.shareme.send.insecure ? _scheduleAutoRetry(session) : null;

    final Widget body = switch (session.status) {
      // To "My devices": the peer accepts automatically, so skip "waiting for acceptance" and show progress (0% before it starts)
      SessionStatus.waiting when isMine => _Sending(session: session, transfers: transfers, liveSpeed: _speed, onCancel: _confirmCancel),
      SessionStatus.waiting => _Waiting(session: session, isMine: isMine, onCancel: () => Navigator.of(context).maybePop()),
      SessionStatus.sending => _Sending(session: session, transfers: transfers, liveSpeed: _speed, onCancel: _confirmCancel),
      // Nothing was sent (e.g. the peer was unreachable): the session errored, but no file finished or was marked failed,
      // so the "Delivered" page below would wrongly report success (seen over Tailscale: the PC dialed the phone's stale
      // Wi-Fi address, sent nothing, yet showed "Delivered").
      SessionStatus.finishedWithErrors when nothingSent => _Stopped(
        session: session,
        onBack: _finish,
        onRetry: () async => _retryAll(session),
        autoAttempt: autoAttempt,
      ),
      SessionStatus.finished || SessionStatus.finishedWithErrors => _Delivered(
        session: session,
        transfers: transfers,
        myFingerprint: myFingerprint,
        isMine: isMine,
        onDone: _finish,
        onRetry: () async => _retryFailed(session, transfers),
        autoBack: session.status == SessionStatus.finished,
      ),
      _ => _Stopped(session: session, onBack: _finish),
    };

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _onLeave(ref.read(sendProvider)[widget.sessionId]);
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
                  child: IconButton(
                    icon: const Icon(LucideIcons.chevronDown),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
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

// ───────────────────────── Waiting for acceptance ─────────────────────────

class _Waiting extends StatelessWidget {
  final SendSessionState session;
  final bool isMine;
  final VoidCallback onCancel;

  const _Waiting({required this.session, required this.isMine, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final name = session.target.alias;
    final bytes = session.files.values.fold<int>(0, (a, f) => a + f.file.size);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      child: Column(
        children: [
          const Spacer(),
          DeviceAvatar(deviceType: session.target.deviceType, size: 88, mine: isMine, badgeRing: c.bg),
          const SizedBox(height: 24),
          Text(
            t.shareme.send.waitingTitle(name: name),
            style: ShareMeText.display.copyWith(color: c.ink),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          Text(
            t.shareme.send.waitingBody(name: name),
            style: ShareMeText.body.copyWith(color: c.ink2),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 18),
          Text(
            t.shareme.send.sheetSummary(n: session.files.length, size: formatSize(bytes)),
            style: ShareMeText.data.copyWith(color: c.ink2),
          ),
          const SizedBox(height: 18),
          // While checksums are still being computed the request hasn't been sent yet; show "Preparing x/y"
          if (session.hashedFileCount < session.files.length)
            Text(
              t.shareme.send.preparing(curr: session.hashedFileCount, n: session.files.length),
              style: ShareMeText.data.copyWith(color: c.ink2),
            )
          else
            SizedBox(
              width: 40,
              child: LinearProgressIndicator(minHeight: 4, color: c.ink, backgroundColor: c.tonal, borderRadius: BorderRadius.circular(99)),
            ),
          const Spacer(flex: 2),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(onPressed: onCancel, child: Text(t.shareme.send.cancel)),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── Transferring ─────────────────────────

class _Sending extends StatelessWidget {
  final SendSessionState session;
  final FileTransferNotifier transfers;

  /// Live speed over the last 3 s; falls back to the overall average until there are enough samples
  final double liveSpeed;
  final VoidCallback onCancel;

  const _Sending({required this.session, required this.transfers, required this.liveSpeed, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final totals = _Totals(session, transfers);
    final ratio = totals.total == 0 ? 0.0 : (totals.current / totals.total).clamp(0.0, 1.0);
    final start = session.startTime;
    final elapsedMs = start == null ? 0 : DateTime.now().millisecondsSinceEpoch - start;
    final average = elapsedMs > 500 ? totals.current / (elapsedMs / 1000) : 0.0;
    final speed = liveSpeed > 0 ? liveSpeed : average;
    final remaining = speed > 0 ? Duration(seconds: ((totals.total - totals.current) / speed).round()) : null;
    final index = (totals.doneCount + 1).clamp(1, totals.count == 0 ? 1 : totals.count);
    final target = session.target;
    final files = session.files.values.where(
      (f) => transfers.getStatus(sessionId: session.sessionId, fileId: f.file.id) != FileStatus.skipped,
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
      children: [
        Text(t.shareme.send.sendingTo, style: ShareMeText.meta.copyWith(color: c.ink2)),
        const SizedBox(height: 2),
        Text(
          target.alias,
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
                session.status == SessionStatus.waiting
                    // Checksums are computed before the request goes out (a few seconds for 200 photos); not connecting yet
                    ? (session.hashedFileCount < session.files.length
                          ? t.shareme.send.preparing(curr: session.hashedFileCount, n: session.files.length)
                          : t.shareme.send.connecting)
                    : [
                        if (speed > 0) formatSpeed(speed),
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
        Row(
          children: [
            Text('${formatSize(totals.current)} / ${formatSize(totals.total)}', style: ShareMeText.data.copyWith(color: c.ink2)),
            const Spacer(),
            Text(
              t.shareme.send.fileIndex(i: index, n: totals.count),
              style: ShareMeText.data.copyWith(color: c.ink2),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Text(t.shareme.send.files, style: ShareMeText.section.copyWith(color: c.ink2)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                [
                  if (target.signalingId == null) t.shareme.home.sameWifi else t.shareme.home.crossNetwork,
                  if (target.https) t.shareme.send.encrypted else t.shareme.send.notEncrypted,
                ].join(' · '),
                style: ShareMeText.meta.copyWith(color: target.https ? c.ink3 : c.warn, fontSize: 12.5),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
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
        const SizedBox(height: 18),
        Text(
          t.shareme.send.leaveHint,
          style: ShareMeText.meta.copyWith(color: c.ink2),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        Center(
          child: TextButton(
            onPressed: onCancel,
            style: TextButton.styleFrom(foregroundColor: c.warn),
            child: Text(t.shareme.send.cancelSend),
          ),
        ),
      ],
    );
  }
}

class _FileLine extends StatelessWidget {
  final SendingFile file;
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
              file.file.fileName,
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

// ───────────────────────── Delivered / partly failed ─────────────────────────

class _Delivered extends StatelessWidget {
  final SendSessionState session;
  final FileTransferNotifier transfers;
  final String myFingerprint;
  final bool isMine;
  final VoidCallback onDone;
  final VoidCallback onRetry;

  /// All delivered: goes back home automatically after 2 s, with a note under the buttons
  final bool autoBack;

  const _Delivered({
    required this.session,
    required this.transfers,
    required this.myFingerprint,
    required this.isMine,
    required this.onDone,
    required this.onRetry,
    required this.autoBack,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final totals = _Totals(session, transfers);
    final failed = session.files.values
        .where((f) => transfers.getStatus(sessionId: session.sessionId, fileId: f.file.id) == FileStatus.failed)
        .toList();
    final ok = failed.isEmpty;
    final start = session.startTime;
    final end = session.endTime;
    final elapsed = start != null && end != null ? Duration(milliseconds: end - start) : null;
    final avgSpeed = elapsed != null && elapsed.inMilliseconds > 0 ? totals.total / (elapsed.inMilliseconds / 1000) : null;
    final sent = session.files.values.where(
      (f) => transfers.getStatus(sessionId: session.sessionId, fileId: f.file.id) == FileStatus.finished,
    );
    // Only say "the receiver can verify each file" if every sent file really carried a SHA-256
    final allHashed = sent.isNotEmpty && sent.every((f) => f.file.hash != null);

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        const SizedBox(height: 16),
        // This device's avatar → the peer's; on delivery the peer's avatar "drops" in (unknown devices get a gray avatar)
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            DeviceAvatar(deviceType: checkPlatformIsDesktop() ? DeviceType.desktop : DeviceType.mobile, size: 60, mine: true),
            Container(width: 48, height: 2, color: c.tonalStrong, margin: const EdgeInsets.symmetric(horizontal: 12)),
            if (ok)
              Stamp(
                tilt: false,
                child: DeviceAvatar(deviceType: session.target.deviceType, size: 60, mine: isMine),
              )
            else
              DeviceAvatar(deviceType: session.target.deviceType, size: 60, mine: isMine),
          ],
        ),
        const SizedBox(height: 28),
        if (ok) ...[
          Text(
            t.shareme.send.deliveredTo,
            style: ShareMeText.meta.copyWith(color: c.ink2),
            textAlign: TextAlign.center,
          ),
          Text(
            session.target.alias,
            style: ShareMeText.display.copyWith(color: c.ink),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            t.shareme.send.deliveredBody(n: totals.count),
            style: ShareMeText.body.copyWith(color: c.ink2),
            textAlign: TextAlign.center,
          ),
        ] else ...[
          Text(
            t.shareme.send.failedTitle(n: failed.length),
            style: ShareMeText.display.copyWith(color: c.warn),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Material(
            color: c.group,
            borderRadius: BorderRadius.circular(ShareMeSize.radiusGroup),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final (i, f) in failed.indexed) ...[
                  if (i > 0) Divider(height: 1, indent: 16, color: c.line),
                  _FileLine(file: f, sessionId: session.sessionId, transfers: transfers),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
        Row(
          children: [
            _Stat(value: formatSize(totals.total), label: t.shareme.send.statSize),
            _Stat(value: elapsed == null ? '--:--' : formatDuration(elapsed), label: t.shareme.send.statTime),
            _Stat(value: avgSpeed == null ? '--' : formatSpeed(avgSpeed), label: t.shareme.send.statSpeed),
          ],
        ),
        const SizedBox(height: 20),
        if (sent.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: c.group, borderRadius: BorderRadius.circular(ShareMeSize.radiusGroup)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.shareme.send.originalTitle, style: ShareMeText.title.copyWith(color: c.ink)),
                      const SizedBox(height: 4),
                      Text(
                        allHashed ? t.shareme.send.originalWithHash : t.shareme.send.originalNoHash,
                        style: ShareMeText.meta.copyWith(color: c.ink2),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: c.tonal, borderRadius: BorderRadius.circular(ShareMeSize.radiusTag)),
                  child: Text(
                    t.shareme.send.originalBadge,
                    style: ShareMeText.labelSm.copyWith(color: c.ok, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 28),
        // Two buttons side by side: the primary one takes 2/3 of the width, on the right
        Row(
          children: [
            Expanded(
              child: ElevatedButton(
                onPressed: ok ? onDone : onRetry,
                style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(ShareMeSize.buttonH)),
                child: FittedBox(fit: BoxFit.scaleDown, child: Text(ok ? t.shareme.send.sendMore : t.shareme.send.retry, maxLines: 1)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: FilledButton(onPressed: onDone, child: Text(t.shareme.send.done)),
            ),
          ],
        ),
        if (ok && autoBack) ...[
          const SizedBox(height: 12),
          Text(
            t.shareme.send.autoBack,
            style: ShareMeText.meta.copyWith(color: c.ink2),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  final String value;
  final String label;

  const _Stat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: ShareMeText.data.copyWith(color: c.ink, fontSize: 16, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 2),
          Text(label, style: ShareMeText.meta.copyWith(color: c.ink2, fontSize: 12)),
        ],
      ),
    );
  }
}

/// The session errored and no file finished or was marked failed: it failed at the "prepare upload" step (peer
/// unreachable, peer error, etc.).
bool _nothingSent(SendSessionState session, FileTransferNotifier transfers) => session.files.values.every((f) {
  final s = transfers.getStatus(sessionId: session.sessionId, fileId: f.file.id);
  return s != FileStatus.finished && s != FileStatus.failed;
});

// ───────────────────────── Declined / busy / canceled / not sent ─────────────────────────

class _Stopped extends StatefulWidget {
  final SendSessionState session;
  final VoidCallback onBack;

  /// Retry is possible when nothing was sent
  final VoidCallback? onRetry;

  /// For my devices an automatic retry follows shortly: its attempt number (null = no automatic retry)
  final int? autoAttempt;

  const _Stopped({required this.session, required this.onBack, this.onRetry, this.autoAttempt});

  @override
  State<_Stopped> createState() => _StoppedState();
}

/// The reason is a single sentence; the raw error is tucked under "Details" and only shown when expanded.
class _StoppedState extends State<_Stopped> {
  bool _details = false;

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final session = widget.session;
    final name = session.target.alias;
    final message = switch (session.status) {
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
    final reason = insecure
        ? session.errorMessage
        : notSent
        ? (isTailscaleIp(session.target.ip) ? t.shareme.send.notSentReasonRemote(name: name) : t.shareme.send.notSentReason(name: name))
        : null;
    final details = notSent ? session.errorMessage : null;
    final retry = notSent ? widget.onRetry : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      child: Column(
        children: [
          const Spacer(),
          Container(
            width: 84,
            height: 84,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: c.warnContainer, shape: BoxShape.circle),
            child: Icon(notSent ? LucideIcons.wifiOff : LucideIcons.circleAlert, size: 36, color: c.warn),
          ),
          const SizedBox(height: 20),
          Text(
            message,
            style: ShareMeText.title.copyWith(color: c.ink, fontSize: 20, fontWeight: FontWeight.w700),
            textAlign: TextAlign.center,
          ),
          if (reason != null) ...[
            const SizedBox(height: 8),
            Text(
              reason,
              style: ShareMeText.body.copyWith(color: c.ink2),
              textAlign: TextAlign.center,
            ),
          ],
          if (details != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => setState(() => _details = !_details),
              icon: Icon(_details ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 16, color: c.ink2),
              label: Text(t.shareme.send.details, style: ShareMeText.meta.copyWith(color: c.ink2)),
            ),
            if (_details)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: c.tonal, borderRadius: BorderRadius.circular(12)),
                child: SelectableText(details, style: ShareMeText.meta.copyWith(color: c.ink2, fontSize: 12)),
              ),
          ],
          const Spacer(flex: 2),
          if (retry != null && widget.autoAttempt != null) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, color: c.ink2)),
                const SizedBox(width: 8),
                Text(
                  t.shareme.send.autoRetrying(n: widget.autoAttempt!),
                  style: ShareMeText.meta.copyWith(color: c.ink2),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          if (retry != null)
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: widget.onBack,
                    style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(ShareMeSize.buttonH)),
                    child: Text(t.shareme.send.back),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton(onPressed: retry, child: Text(t.shareme.send.retryAll)),
                ),
              ],
            )
          else
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: widget.onBack, child: Text(t.shareme.send.back)),
            ),
        ],
      ),
    );
  }
}

/// Finds the active send session for a device (used by the device rows on the home page).
SendSessionState? activeSendSessionFor(Map<String, SendSessionState> sessions, String fingerprint) => sessions.values.firstWhereOrNull(
  (s) => s.target.fingerprint == fingerprint && (s.status == SessionStatus.waiting || s.status == SessionStatus.sending),
);
