import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/persistence/queued_send.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/util/coalesced_save.dart';
import 'package:localsend_app/util/shareme_pairing/pair_crypto.dart' show isTailscaleIp;
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart' as path_provider;
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uuid/uuid.dart';

// Shuttle: the "send queue" — what to send to an offline "my device" waits here (see queued_send.dart for what is stored, and
// send_queue_runner.dart for how it goes out). Design and the decisions behind it: docs/send-queue-design.md in the project folder.
// Modeled on KDE Connect (links shared to an unreachable device are stored and delivered when it connects, and dropped when it is
// unpaired) and Syncthing (files are kept by location; the version present at send time goes out).

final _logger = Logger('SendQueue');
const _uuid = Uuid();

/// A batch is dropped after waiting this long (recorded in the history as "expired")
const queueMaxAge = Duration(days: 7);

/// At most this many batches wait for one device
const queueMaxPerDevice = 50;

/// Shuttle's own copies (text, clipboard images, files shared in on the phone) may take at most this much space in total
const maxQueueCopyBytes = 2 * 1024 * 1024 * 1024;

/// While a device is only reachable remotely (Tailscale), batches larger than this wait for the same Wi-Fi (it is slow there, about
/// 1 MB/s, and may use the phone's mobile data), unless "Send now" is tapped
const queueRemoteAutoLimit = 50 * 1024 * 1024;

/// Text that arrives later than this after it was queued is not copied to the receiver's clipboard automatically: it would replace
/// whatever the user has copied in the meantime. The sender writes the queue time into the text's "modified" field (see
/// [isLateQueuedMessage]).
const lateMessageAfter = Duration(minutes: 10);

/// Waits before the next attempt after the n-th failed attempt in a row (the device looked online but could not be reached, or was busy)
const queueRetryDelays = [Duration(seconds: 30), Duration(minutes: 1), Duration(minutes: 2), Duration(minutes: 5), Duration(minutes: 10)];

Duration queueRetryDelay(int failures) => queueRetryDelays[min(max(failures, 1), queueRetryDelays.length) - 1];

/// Why something could not be queued
enum QueueRefusal {
  /// [queueMaxPerDevice] batches already wait for this device
  full,

  /// Shuttle's copies would exceed [maxQueueCopyBytes]
  tooLarge,
}

/// Whether a new batch for [fingerprint] with [newCopyBytes] of Shuttle's own copies may be queued
QueueRefusal? queueRefusal(List<QueuedSend> queue, String fingerprint, int newCopyBytes) {
  if (queue.where((e) => e.targetFingerprint == fingerprint).length >= queueMaxPerDevice) return QueueRefusal.full;
  final copies = queue.fold<int>(0, (sum, e) => sum + e.ownedBytes);
  if (copies + newCopyBytes > maxQueueCopyBytes) return QueueRefusal.tooLarge;
  return null;
}

bool queueExpired(QueuedSend entry, DateTime now) => now.toUtc().difference(entry.createdAt) >= queueMaxAge;

/// Found only via Tailscale (or across networks): as on the home page, the slow path
bool isRemoteDevice(Device device) => device.signalingId != null || isTailscaleIp(device.ip);

/// A large batch waits for the same Wi-Fi while [device] is only reachable remotely, unless the user tapped "Send now" ([allowRemote])
bool holdUntilLan(QueuedSend entry, Device device, {required bool allowRemote}) =>
    !allowRemote && isRemoteDevice(device) && entry.totalSize > queueRemoteAutoLimit;

/// The batches for [fingerprint], oldest first
List<QueuedSend> queuedFor(Iterable<QueuedSend> queue, String fingerprint) =>
    queue.where((e) => e.targetFingerprint == fingerprint).sortedBy((e) => e.createdAt);

/// What to start now: per device the oldest batch, when the device is online ([online], by fingerprint), nothing is being sent to it
/// ([busy]: an active send, by the user or by the queue), its retry time has come ([retryAt]) and the batch isn't held back for the
/// same Wi-Fi ([holdUntilLan]). Batches go out one after another, in the order they were queued.
List<(QueuedSend, Device)> queueDue({
  required Iterable<QueuedSend> queue,
  required Map<String, Device> online,
  required Set<String> busy,
  required Map<String, DateTime> retryAt,
  required Set<String> allowRemote,
  required DateTime now,
}) {
  final result = <(QueuedSend, Device)>[];
  final fingerprints = queue.map((e) => e.targetFingerprint).toSet();
  for (final fingerprint in fingerprints) {
    final device = online[fingerprint];
    if (device == null || device.ip == null || busy.contains(fingerprint)) continue;
    final at = retryAt[fingerprint];
    if (at != null && now.isBefore(at)) continue;
    final first = queuedFor(queue, fingerprint).first;
    if (holdUntilLan(first, device, allowRemote: allowRemote.contains(fingerprint))) continue;
    result.add((first, device));
  }
  return result;
}

/// True when [entries] of a device are all held back for the same Wi-Fi (shown as "waiting for the same Wi-Fi", with "Send now")
bool queueHeldForLan(List<QueuedSend> entries, Device? online, {required bool allowRemote}) =>
    online != null && entries.isNotEmpty && holdUntilLan(entries.first, online, allowRemote: allowRemote);

/// Whether a text message from one of "my devices" was queued long enough ago that it shouldn't be auto-copied
/// ([lastModified] is the RFC 3339 time the sender queued it; ordinary messages don't carry one)
bool isLateQueuedMessage(String? lastModified, DateTime now) {
  if (lastModified == null) return false;
  final queuedAt = DateTime.tryParse(lastModified);
  if (queuedAt == null) return false;
  return now.toUtc().difference(queuedAt.toUtc()) > lateMessageAfter;
}

// ───────────────────────── Results of an attempt ─────────────────────────

/// How a send started by the queue ended: its last state and file statuses (read before the session was closed)
class QueueSendResult {
  final SendSessionState state;
  final Map<String, FileStatus> statuses;

  const QueueSendResult({required this.state, required this.statuses});
}

enum QueueStep {
  /// Delivered (or the receiver accepted only some files): remove the batch
  done,

  /// Some files went out, the rest failed: keep only the rest ([QueueOutcome.undelivered])
  partial,

  /// Not reachable / busy: keep it and try again later
  retry,

  /// Declined, canceled, needs a PIN or not encrypted: remove it, the history tells why
  drop,
}

class QueueOutcome {
  final QueueStep step;

  /// File IDs to keep for [QueueStep.partial]
  final Set<String> undelivered;

  const QueueOutcome(this.step, [this.undelivered = const {}]);

  /// Whether the session should be recorded in the sent history (not while the batch keeps waiting: the final attempt records it)
  bool get record => step != QueueStep.retry;
}

/// Decides what happens to a batch after an attempt. [insecureMessage] / [needsPinMessage] are the error texts the send uses for
/// "not encrypted" and "the device asks for a PIN" (both dropped: retrying wouldn't help).
QueueOutcome classifyQueueResult(QueueSendResult? result, {required String insecureMessage, required String needsPinMessage}) {
  if (result == null) return const QueueOutcome(QueueStep.retry);
  final s = result.state;
  switch (s.status) {
    case SessionStatus.finished:
      return const QueueOutcome(QueueStep.done);
    case SessionStatus.finishedWithErrors:
      if (s.errorMessage == insecureMessage || s.errorMessage == needsPinMessage) return const QueueOutcome(QueueStep.drop);
      final delivered = s.files.keys.where((id) => result.statuses[id] == FileStatus.finished).toSet();
      if (delivered.isEmpty) return const QueueOutcome(QueueStep.retry);
      final undelivered = s.files.keys.where((id) {
        final status = result.statuses[id];
        return status != FileStatus.finished && status != FileStatus.skipped;
      }).toSet();
      return undelivered.isEmpty ? const QueueOutcome(QueueStep.done) : QueueOutcome(QueueStep.partial, undelivered);
    case SessionStatus.recipientBusy:
      return const QueueOutcome(QueueStep.retry);
    case SessionStatus.declined:
    case SessionStatus.tooManyAttempts:
    case SessionStatus.canceledByReceiver:
    case SessionStatus.canceledBySender:
    // Closed while still waiting or sending: the user canceled it (the send page or the home row)
    case SessionStatus.waiting:
    case SessionStatus.sending:
      return const QueueOutcome(QueueStep.drop);
  }
}

// ───────────────────────── State ─────────────────────────

final sendQueueProvider = ReduxProvider<SendQueueService, List<QueuedSend>>((ref) {
  return SendQueueService(ref.read(persistenceProvider));
});

class SendQueueService extends ReduxNotifier<List<QueuedSend>> {
  final PersistenceService _persistence;

  /// Reads [state] only when saving, so the latest list is always saved. Changes are rare, so it saves on the next event-loop turn.
  late final _save = CoalescedSave(() => _persistence.setSendQueue(state), delay: Duration.zero);

  SendQueueService(this._persistence);

  @override
  List<QueuedSend> init() {
    try {
      return _persistence.getSendQueue();
    } catch (e) {
      _logger.warning('Could not read the send queue', e);
      return [];
    }
  }

  /// Saves now and waits until done
  Future<void> flushSave() => _save.flush();
}

class AddQueuedSendAction extends ReduxAction<SendQueueService, List<QueuedSend>> {
  final QueuedSend entry;

  AddQueuedSendAction(this.entry);

  @override
  List<QueuedSend> reduce() {
    notifier._save.schedule();
    return [...state.where((e) => e.id != entry.id), entry];
  }
}

/// Keeps only the files in [keep] (after a partly successful attempt); Shuttle's copies of the others are deleted
class KeepQueuedFilesAction extends ReduxAction<SendQueueService, List<QueuedSend>> {
  final String id;
  final Set<String> keep;

  KeepQueuedFilesAction({required this.id, required this.keep});

  @override
  List<QueuedSend> reduce() {
    final entry = state.firstWhereOrNull((e) => e.id == id);
    if (entry == null) return state;
    final kept = entry.files.where((f) => keep.contains(f.id)).toList();
    unawaited(deleteQueueCopies(entry.files.where((f) => !keep.contains(f.id))));
    notifier._save.schedule();
    if (kept.isEmpty) return state.where((e) => e.id != id).toList();
    return [
      for (final e in state) e.id == id ? e.copyWith(files: kept) : e,
    ];
  }
}

/// Removes batches (canceled, sent, expired, or for a device no longer in "my devices"), deleting Shuttle's copies
class RemoveQueuedSendsAction extends ReduxAction<SendQueueService, List<QueuedSend>> {
  final bool Function(QueuedSend entry) where;

  RemoveQueuedSendsAction(this.where);

  RemoveQueuedSendsAction.id(String id) : this((e) => e.id == id);

  RemoveQueuedSendsAction.device(String fingerprint) : this((e) => e.targetFingerprint == fingerprint);

  @override
  List<QueuedSend> reduce() {
    final removed = state.where(where).toList();
    if (removed.isEmpty) return state;
    unawaited(deleteQueueCopies(removed.expand((e) => e.files)));
    notifier._save.schedule();
    return state.where((e) => !where(e)).toList();
  }
}

/// Deletes Shuttle's copies among [files] (never the user's own files). Errors are only logged.
Future<void> deleteQueueCopies(Iterable<QueuedFile> files) async {
  for (final f in files) {
    final path = f.path;
    if (!f.ownedCopy || path == null) continue;
    try {
      final file = File(path);
      if (file.existsSync()) await file.delete();
    } catch (e) {
      _logger.warning('Could not delete the queued copy ${f.fileName}', e);
    }
  }
}

// ───────────────────────── Queuing ─────────────────────────

/// The folder for Shuttle's copies: next to settings.json on the PC (the portable folder, or %APPDATA%\Shuttle), else the app's
/// private files folder (not the cache: Shuttle empties that on every start, and Android clears it when space runs low).
Future<Directory> sendQueueDirectory() async {
  final base = PersistenceService.settingsDirectory ?? (await path_provider.getApplicationSupportDirectory()).path;
  final dir = Directory(p.join(base, 'send_queue'));
  await dir.create(recursive: true);
  return dir;
}

/// On the phone, files under the app cache folder (shared in from other apps, or copied there by a picker): Shuttle empties that
/// folder on every start, so queued ones are moved out of it. Null on the PC: there every file stays where the user keeps it.
Future<String?> _ownCacheDirectory() async {
  if (!Platform.isAndroid && !Platform.isIOS) return null;
  return (await path_provider.getTemporaryDirectory()).path;
}

/// Whether [path] lies inside [dir]
bool isInsideDirectory(String path, String? dir) => dir != null && p.isWithin(dir, path);

/// Bytes Shuttle will have to keep a copy of when [files] are queued (see [prepareQueuedFiles])
int queueCopyBytes(List<CrossFile> files, {required String? cacheDir}) =>
    files.where((f) => f.bytes != null || (f.path != null && isInsideDirectory(f.path!, cacheDir))).fold(0, (sum, f) => sum + max(f.size, 0));

/// Turns picked content into queued files. Text and clipboard images are written to [dir]; files inside [cacheDir] (phone only) are
/// moved into [dir] (same storage, so it takes no time and no extra space); everything else is kept by its location.
Future<List<QueuedFile>> prepareQueuedFiles(List<CrossFile> files, {required Directory dir, required String? cacheDir}) async {
  final message = files.length == 1 && files.first.fileType == FileType.text && files.first.bytes != null;
  final result = <QueuedFile>[];
  for (final f in files) {
    final id = _uuid.v4();
    final ext = p.extension(f.name);
    String? path = f.path;
    var owned = false;
    if (f.bytes != null) {
      path = p.join(dir.path, '$id$ext');
      await File(path).writeAsBytes(f.bytes!, flush: true);
      owned = true;
    } else if (path != null && isInsideDirectory(path, cacheDir)) {
      final target = p.join(dir.path, '$id$ext');
      try {
        await File(path).rename(target);
      } on FileSystemException {
        await File(path).copy(target);
        try {
          await File(path).delete();
        } catch (_) {}
      }
      path = target;
      owned = true;
    }
    result.add(
      QueuedFile(
        id: id,
        fileName: f.name,
        fileType: f.fileType,
        size: max(f.size, 0),
        path: path,
        ownedCopy: owned,
        assetId: f.asset?.id,
        isMessage: message,
        preview: message ? _preview(f.bytes!) : null,
        lastModified: f.lastModified,
        lastAccessed: f.lastAccessed,
      ),
    );
  }
  return result;
}

String _preview(List<int> bytes) {
  final text = utf8.decode(bytes, allowMalformed: true);
  return text.length > 200 ? text.substring(0, 200) : text;
}

/// Puts [files] in the queue for [fingerprint] (one of "my devices"). Returns the new batch, or why it couldn't be queued.
/// The queue is saved before this returns, so it survives the app being closed right after.
Future<({QueuedSend? entry, QueueRefusal? refusal})> queueForDevice(
  Ref ref, {
  required String fingerprint,
  required String alias,
  required List<CrossFile> files,
}) async {
  final cacheDir = await _ownCacheDirectory();
  final refusal = queueRefusal(ref.read(sendQueueProvider), fingerprint, queueCopyBytes(files, cacheDir: cacheDir));
  if (refusal != null) return (entry: null, refusal: refusal);
  final queued = await prepareQueuedFiles(files, dir: await sendQueueDirectory(), cacheDir: cacheDir);
  final entry = QueuedSend(id: _uuid.v4(), targetFingerprint: fingerprint, targetAlias: alias, createdAt: DateTime.now().toUtc(), files: queued);
  ref.redux(sendQueueProvider).dispatch(AddQueuedSendAction(entry));
  await ref.notifier(sendQueueProvider).flushSave();
  _logger.info('Queued ${queued.length} item(s) for $alias');
  return (entry: entry, refusal: null);
}

// ───────────────────────── Before sending ─────────────────────────

/// Reads the size of an Android content:// URI: null or an error = can't be read (permission gone, file moved); negative = readable,
/// size unknown
typedef ContentLength = Future<int?> Function(Uri uri);

/// A queued batch made ready to send: the files that are still there (as [CrossFile]s, with their current size) and the ones that
/// are gone
class ResolvedQueuedSend {
  final List<(QueuedFile, CrossFile)> available;
  final List<QueuedFile> missing;

  const ResolvedQueuedSend({required this.available, required this.missing});
}

/// Looks at each file right before sending: deleted / moved / unreadable ones are left out ([ResolvedQueuedSend.missing]); the
/// others go out as they are now (current size). Text is read back from its copy and sent as a message, its "modified" time set
/// to when it was queued (see [isLateQueuedMessage]).
Future<ResolvedQueuedSend> resolveQueuedFiles(QueuedSend entry, {required ContentLength contentLength}) async {
  final available = <(QueuedFile, CrossFile)>[];
  final missing = <QueuedFile>[];
  for (final f in entry.files) {
    final path = f.path;
    try {
      if (path == null) {
        missing.add(f);
      } else if (f.isMessage) {
        final file = File(path);
        if (!file.existsSync()) {
          missing.add(f);
          continue;
        }
        final bytes = await file.readAsBytes();
        available.add((f, _crossFile(f, size: bytes.length, path: null, bytes: bytes, lastModified: entry.createdAt.toUtc().toIso8601String())));
      } else if (path.startsWith('content://')) {
        final size = await contentLength(Uri.parse(path));
        if (size == null) {
          missing.add(f);
          continue;
        }
        // A negative size: readable, but the provider doesn't report a size
        available.add((f, _crossFile(f, size: size < 0 ? f.size : size, path: path, bytes: null, lastModified: f.lastModified)));
      } else {
        final file = File(path);
        if (!file.existsSync()) {
          missing.add(f);
          continue;
        }
        available.add((f, _crossFile(f, size: await file.length(), path: path, bytes: null, lastModified: f.lastModified)));
      }
    } catch (e) {
      _logger.warning('Queued file ${f.fileName} cannot be read', e);
      missing.add(f);
    }
  }
  return ResolvedQueuedSend(available: available, missing: missing);
}

CrossFile _crossFile(QueuedFile f, {required int size, required String? path, required List<int>? bytes, required String? lastModified}) => CrossFile(
  name: f.fileName,
  fileType: f.fileType,
  size: size,
  thumbnail: null,
  asset: null,
  path: path,
  bytes: bytes,
  lastModified: lastModified,
  lastAccessed: f.lastAccessed,
);
