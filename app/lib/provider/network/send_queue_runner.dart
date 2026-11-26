import 'dart:async';

import 'package:collection/collection.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/persistence/queued_send.dart';
import 'package:localsend_app/model/persistence/sent_history_entry.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/shareme_presence.dart';
import 'package:localsend_app/provider/send_queue_provider.dart';
import 'package:localsend_app/provider/sent_history_provider.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:uri_content/uri_content.dart';
import 'package:uuid/uuid.dart';

// Shuttle: sends what waits in the send queue (send_queue_provider.dart) as soon as its device is reachable.
//
// - Triggered when a device joins the "online" list (it announced itself, answered a presence check, or asked us — e.g. the PC's
//   Shuttle starting up asks every "my device"), when the queue or the running sends change, and every 30 s.
// - One batch at a time per device, oldest first, as an ordinary background send (the home page row shows its progress; the history
//   records it). Nothing goes out while the user is sending something else to that device.
// - Not reachable or busy: wait 30 s, 1, 2, 5, then 10 min between attempts; coming back online starts over right away.
// - On the phone it only runs while Shuttle's process is alive: nothing wakes it up in the background (no extra battery use).

final _logger = Logger('SendQueueRunner');
const _uuid = Uuid();

/// How often due batches, expired batches and removed devices are checked even without a trigger
const queueTick = Duration(seconds: 30);

/// How the runner sends (replaced in tests)
abstract class QueueSender {
  /// Sends [files] to [target] as a background send and returns how it ended (null if unknown)
  Future<QueueSendResult?> send({required String sessionId, required Device target, required List<CrossFile> files, required List<String> fileIds});

  /// Closes the session if it is still open in the background (a send page the user opened closes its own session)
  void close(String sessionId, {required bool recordHistory});

  /// Stops a running send (the user canceled its batch)
  void cancel(String sessionId);
}

class _SendProviderSender implements QueueSender {
  final Ref ref;

  _SendProviderSender(this.ref);

  @override
  Future<QueueSendResult?> send({
    required String sessionId,
    required Device target,
    required List<CrossFile> files,
    required List<String> fileIds,
  }) async {
    final sender = ref.notifier(sendProvider);
    sender.trackResult(sessionId);
    await sender.startSession(target: target, files: files, background: true, sessionId: sessionId, fileIds: fileIds, askPin: false);
    return sender.takeResult(sessionId);
  }

  @override
  void close(String sessionId, {required bool recordHistory}) {
    final session = ref.read(sendProvider)[sessionId];
    if (session == null || !session.background) return;
    ref.notifier(sendProvider).closeSession(sessionId, recordHistory: recordHistory);
  }

  @override
  void cancel(String sessionId) => ref.notifier(sendProvider).cancelSession(sessionId);
}

final _uriContent = UriContent();

Future<int?> _contentLength(Uri uri) async {
  try {
    return await _uriContent.getContentLength(uri) ?? -1;
  } catch (_) {
    return null;
  }
}

/// What the user is told when a batch went out
typedef QueueNotice = void Function(QueuedSend entry, {required int sent, required int missing});

void _showNotice(QueuedSend entry, {required int sent, required int missing}) {
  final context = Routerino.context;
  if (!context.mounted) return;
  final text = sent == 0
      ? t.shareme.queue.missingSnack(n: missing, name: entry.targetAlias)
      : entry.isMessage
      ? t.shareme.queue.sentTextSnack(name: entry.targetAlias)
      : missing > 0
      ? '${t.shareme.queue.sentSnack(n: sent, name: entry.targetAlias)} · ${t.shareme.queue.missingShort(n: missing)}'
      : t.shareme.queue.sentSnack(n: sent, name: entry.targetAlias);
  context.showSnackBar(text);
}

class SendQueueRunner {
  static SendQueueRunner? _instance;

  /// The runner of this app (null before [start])
  static SendQueueRunner? get instance => _instance;

  /// Session IDs of sends started by the queue. The send page leaves their failures to the queue (no auto-retry, no re-queuing).
  static final _sessionIds = <String>{};

  static bool isQueueSession(String sessionId) => _sessionIds.contains(sessionId);

  /// Starts sending queued batches (once, after the server and discovery are up)
  static void start(Ref ref) {
    _instance?.dispose();
    _instance = SendQueueRunner(ref)..listen();
  }

  final Ref ref;
  final QueueSender _sender;
  final DateTime Function() _now;
  final ContentLength _readContentLength;
  final QueueNotice _notice;
  final Map<String, Device> Function() _online;
  final void Function() _askPresence;

  /// The optional parameters replace the real sending, clock, file access, snackbar, online list and presence check in tests
  SendQueueRunner(
    this.ref, {
    QueueSender? sender,
    DateTime Function()? clock,
    ContentLength? contentLength,
    QueueNotice? notice,
    Map<String, Device> Function()? online,
    void Function()? askPresence,
  }) : _sender = sender ?? _SendProviderSender(ref),
       _now = clock ?? DateTime.now,
       _readContentLength = contentLength ?? _contentLength,
       _notice = notice ?? _showNotice,
       _online = online ?? (() => _onlineDevices(ref)),
       _askPresence = askPresence ?? (() => unawaited(ref.global.dispatchAsync(CheckPresenceAction(force: true))));

  /// Devices in the "online" list with an address, by fingerprint
  static Map<String, Device> _onlineDevices(Ref ref) => {
    for (final d in ref.read(nearbyDevicesProvider).devices.values)
      if (d.ip != null) d.fingerprint: d,
  };

  /// Devices (fingerprints) a batch is being sent to right now
  final _running = <String>{};

  /// Batch ID → its running send session
  final _sessionOf = <String, String>{};

  /// Failed attempts in a row per device, and when to try again
  final _failures = <String, int>{};
  final _retryAt = <String, DateTime>{};

  /// Devices whose large batches may go over Tailscale too ("Send now")
  final _allowRemote = <String>{};

  final _subscriptions = <StreamSubscription<dynamic>>[];
  Timer? _timer;

  /// Whether this batch is being sent right now
  bool isSending(String entryId) => _sessionOf.containsKey(entryId);

  /// Whether the user allowed large batches for this device over Tailscale
  bool allowsRemote(String fingerprint) => _allowRemote.contains(fingerprint);

  /// When the next attempt for this device is due (after a failed one), or null
  DateTime? retryAt(String fingerprint) => _retryAt[fingerprint];

  void listen() {
    _subscriptions
      ..add(
        ref.stream(nearbyDevicesProvider).listen((event) {
          // Came (back) online: forget the waiting time from earlier failures and try right away
          for (final fingerprint in event.next.devices.keys.toSet().difference(event.prev.devices.keys.toSet())) {
            _retryAt.remove(fingerprint);
            _failures.remove(fingerprint);
          }
          pump();
        }),
      )
      ..add(ref.stream(sendQueueProvider).listen((_) => pump()))
      ..add(ref.stream(favoritesProvider).listen((_) => dropRemovedDevices()))
      ..add(
        ref.stream(sendProvider).listen((event) {
          // A send to some device ended: its next batch may go now
          if (!const SetEquality<String>().equals(_activeSends(event.prev), _activeSends(event.next))) pump();
        }),
      );
    _timer = Timer.periodic(queueTick, (_) => tick());
    tick();
  }

  void dispose() {
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    _subscriptions.clear();
    _timer?.cancel();
  }

  void tick() {
    dropExpired();
    dropRemovedDevices();
    pump();
  }

  /// Devices with a send in progress (by the user or by the queue)
  static Set<String> _activeSends(Map<String, SendSessionState> sessions) => {
    for (final s in sessions.values)
      if (s.status == SessionStatus.waiting || s.status == SessionStatus.sending) s.target.fingerprint,
  };

  /// Starts every batch that is due now (see [queueDue])
  void pump() {
    final queue = ref.read(sendQueueProvider);
    _allowRemote.removeWhere((fingerprint) => queue.none((e) => e.targetFingerprint == fingerprint));
    final due = queueDue(
      queue: queue,
      online: _online(),
      busy: {..._activeSends(ref.read(sendProvider)), ..._running},
      retryAt: _retryAt,
      allowRemote: _allowRemote,
      now: _now(),
    );
    for (final (entry, device) in due) {
      _running.add(entry.targetFingerprint);
      unawaited(_run(entry, device));
    }
  }

  /// "Send now" / "Try now" in the queue sheet: forget the waiting time, allow large batches over Tailscale, and ask whether the
  /// device is there
  void tryNow(String fingerprint) {
    _allowRemote.add(fingerprint);
    _retryAt.remove(fingerprint);
    _failures.remove(fingerprint);
    _askPresence();
    pump();
  }

  /// Cancels a batch: removes it, and stops it if it is being sent
  void cancel(String entryId) {
    ref.redux(sendQueueProvider).dispatch(RemoveQueuedSendsAction.id(entryId));
    final sessionId = _sessionOf[entryId];
    if (sessionId != null) _sender.cancel(sessionId);
  }

  /// Cancels every batch for a device
  void cancelAll(String fingerprint) {
    for (final e in queuedFor(ref.read(sendQueueProvider), fingerprint)) {
      cancel(e.id);
    }
  }

  /// Batches waiting longer than [queueMaxAge] are dropped and recorded as "expired"
  void dropExpired() {
    final now = _now();
    final expired = ref.read(sendQueueProvider).where((e) => queueExpired(e, now) && !isSending(e.id)).toList();
    if (expired.isEmpty) return;
    for (final e in expired) {
      _logger.info('Batch for ${e.targetAlias} expired after ${now.difference(e.createdAt).inHours} h');
      _record(e, e.files, SentHistoryResult.expired);
    }
    final ids = expired.map((e) => e.id).toSet();
    ref.redux(sendQueueProvider).dispatch(RemoveQueuedSendsAction((e) => ids.contains(e.id)));
  }

  /// Batches for a device no longer in "my devices" are dropped (as KDE Connect does when a device is unpaired)
  void dropRemovedDevices() {
    final mine = ref.read(favoritesProvider).map((f) => f.fingerprint).toSet();
    if (ref.read(sendQueueProvider).every((e) => mine.contains(e.targetFingerprint))) return;
    ref.redux(sendQueueProvider).dispatch(RemoveQueuedSendsAction((e) => !mine.contains(e.targetFingerprint) && !isSending(e.id)));
  }

  bool _stillQueued(String entryId) => ref.read(sendQueueProvider).any((e) => e.id == entryId);

  void _failed(String fingerprint) {
    final failures = (_failures[fingerprint] ?? 0) + 1;
    _failures[fingerprint] = failures;
    _retryAt[fingerprint] = _now().add(queueRetryDelay(failures));
  }

  Future<void> _run(QueuedSend entry, Device device) async {
    final fingerprint = entry.targetFingerprint;
    String? sessionId;
    try {
      final resolved = await resolveQueuedFiles(entry, contentLength: _readContentLength);
      if (!_stillQueued(entry.id)) return; // canceled meanwhile
      if (resolved.available.isEmpty) {
        _logger.info('Nothing left to send to ${entry.targetAlias}: all ${entry.files.length} item(s) are gone');
        _record(entry, resolved.missing, SentHistoryResult.missing);
        ref.redux(sendQueueProvider).dispatch(RemoveQueuedSendsAction.id(entry.id));
        _notice(entry, sent: 0, missing: resolved.missing.length);
        return;
      }

      final id = sessionId = _uuid.v4();
      _sessionIds.add(id);
      _sessionOf[entry.id] = id;
      _logger.info('Sending ${resolved.available.length} queued item(s) to ${entry.targetAlias} (${device.ip})');
      final result = await _sender.send(
        sessionId: id,
        target: device,
        files: [for (final (_, file) in resolved.available) file],
        fileIds: [for (final (queued, _) in resolved.available) queued.id],
      );
      final outcome = classifyQueueResult(result, insecureMessage: t.shareme.send.insecure, needsPinMessage: needsPinMessage);
      _logger.info('Queued send to ${entry.targetAlias}: ${result?.state.status} → ${outcome.step}');
      _sender.close(id, recordHistory: outcome.record);
      final missing = resolved.missing;
      switch (outcome.step) {
        case QueueStep.done:
          _failures.remove(fingerprint);
          _retryAt.remove(fingerprint);
          ref.redux(sendQueueProvider).dispatch(RemoveQueuedSendsAction.id(entry.id));
          if (missing.isNotEmpty) _record(entry, missing, SentHistoryResult.missing);
          _notice(entry, sent: resolved.available.length, missing: missing.length);
        case QueueStep.partial:
          // Keep what didn't arrive; files that are gone won't come back
          ref.redux(sendQueueProvider).dispatch(KeepQueuedFilesAction(id: entry.id, keep: outcome.undelivered));
          if (missing.isNotEmpty) _record(entry, missing, SentHistoryResult.missing);
          _failed(fingerprint);
        case QueueStep.retry:
          _failed(fingerprint);
        case QueueStep.drop:
          ref.redux(sendQueueProvider).dispatch(RemoveQueuedSendsAction.id(entry.id));
          if (missing.isNotEmpty) _record(entry, missing, SentHistoryResult.missing);
      }
    } catch (e, st) {
      _logger.warning('Queued send to ${entry.targetAlias} failed', e, st);
      _failed(fingerprint);
    } finally {
      if (sessionId != null) _sessionIds.remove(sessionId);
      _sessionOf.remove(entry.id);
      _running.remove(fingerprint);
    }
    pump(); // the next batch for this device, if any
  }

  /// Records [files] of [entry] in the sent history with [result] (expired, or gone before sending)
  void _record(QueuedSend entry, List<QueuedFile> files, SentHistoryResult result) {
    final message = entry.isMessage ? entry.files.first.preview : null;
    ref
        .redux(sentHistoryProvider)
        .dispatch(
          AddSentHistoryAction(
            SentHistoryEntry(
              id: '${entry.id}-${result.name}',
              targetAlias: entry.targetAlias,
              targetFingerprint: entry.targetFingerprint,
              timestamp: _now().toUtc(),
              files: message != null
                  ? const []
                  : [
                      for (final f in files)
                        SentHistoryFile(
                          fileName: f.fileName,
                          fileType: f.fileType,
                          size: f.size,
                          path: f.ownedCopy ? null : f.path,
                          assetId: f.assetId,
                          delivered: false,
                        ),
                    ],
              message: message,
              result: result,
              errorMessage: null,
            ),
          ),
        );
  }
}
