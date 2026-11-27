import 'dart:async';
import 'dart:io';

import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/persistence/queued_send.dart';
import 'package:localsend_app/model/persistence/sent_history_entry.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/model/state/send/sending_file.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/send_queue_runner.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/send_queue_provider.dart';
import 'package:localsend_app/provider/sent_history_provider.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/dto/file_dto.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:mockito/mockito.dart';
import 'package:path/path.dart' as p;
import 'package:refena_flutter/refena_flutter.dart';
import 'package:test/test.dart';

const _phone = 'phone-fp';
const _mb = 1024 * 1024;

class _Store extends Fake implements PersistenceService {
  List<QueuedSend> queue = [];
  List<FavoriteDevice> favorites = [FavoriteDevice.fromValues(fingerprint: _phone, ip: '192.168.1.5', port: 53317, alias: 'Phone')];
  List<SentHistoryEntry> history = [];

  @override
  List<QueuedSend> getSendQueue() => queue;

  @override
  Future<void> setSendQueue(List<QueuedSend> entries) async => queue = entries;

  @override
  List<FavoriteDevice> getFavorites() => favorites;

  @override
  Future<void> setFavorites(List<FavoriteDevice> list) async => favorites = list;

  @override
  List<SentHistoryEntry> getSentHistory() => history;

  @override
  Future<void> setSentHistory(List<SentHistoryEntry> entries) async => history = entries;

  @override
  bool isSaveToHistory() => true;
}

class _NoSends extends SendNotifier {
  final Map<String, SendSessionState> initial;

  _NoSends([this.initial = const {}]);

  @override
  Map<String, SendSessionState> init() => initial;
}

/// One attempt: what was sent, and how the test lets it end
class _Attempt {
  final String sessionId;
  final Device target;
  final List<CrossFile> files;
  final List<String> fileIds;
  final done = Completer<QueueSendResult?>();

  _Attempt(this.sessionId, this.target, this.files, this.fileIds);

  /// Ends it with [status]; [statuses] per file ID (default: all finished on success, all queued otherwise)
  void end(SessionStatus status, {Map<String, FileStatus>? statuses, String? error}) {
    done.complete(
      QueueSendResult(
        state: SendSessionState(
          sessionId: sessionId,
          remoteSessionId: null,
          background: true,
          status: status,
          target: target,
          files: {
            for (final (i, id) in fileIds.indexed)
              id: SendingFile(
                file: FileDto(
                  id: id,
                  fileName: files[i].name,
                  size: files[i].size,
                  fileType: files[i].fileType,
                  hash: null,
                  preview: null,
                  metadata: null,
                ),
                token: null,
                thumbnail: null,
                asset: null,
                path: files[i].path,
                bytes: files[i].bytes,
                errorMessage: null,
              ),
          },
          hashedFileCount: 0,
          startTime: null,
          endTime: null,
          sendingTasks: const [],
          errorMessage: error,
        ),
        statuses: statuses ?? {for (final id in fileIds) id: status == SessionStatus.finished ? FileStatus.finished : FileStatus.queue},
      ),
    );
  }
}

class _Sender implements QueueSender {
  final attempts = <_Attempt>[];
  final closed = <String, bool>{};
  final canceled = <String>[];

  @override
  Future<QueueSendResult?> send({required String sessionId, required Device target, required List<CrossFile> files, required List<String> fileIds}) {
    final attempt = _Attempt(sessionId, target, files, fileIds);
    attempts.add(attempt);
    return attempt.done.future;
  }

  @override
  void close(String sessionId, {required bool recordHistory}) => closed[sessionId] = recordHistory;

  @override
  void cancel(String sessionId) => canceled.add(sessionId);
}

Device _device(String ip) => Device(
  signalingId: null,
  ip: ip,
  version: '2.1',
  port: 53317,
  https: true,
  fingerprint: _phone,
  alias: 'Phone',
  deviceModel: null,
  deviceType: DeviceType.mobile,
  download: false,
  channels: const [],
);

/// Lets the runner get on. Before it sends a batch it checks the queued files on disk (real file I/O), which can take more turns
/// of the event loop than [pumpEventQueue] gives on a busy machine (a full test run failed here once). Waits until [done] holds,
/// for at most 5 seconds; without a condition it only lets the event queue run (for checks that nothing happens).
Future<void> settle([bool Function()? done]) async {
  await pumpEventQueue();
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (done != null && !done() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await pumpEventQueue();
  }
}

void main() {
  late Directory dir;
  late _Store store;
  late RefenaContainer ref;
  late _Sender sender;
  late SendQueueRunner runner;
  late DateTime now;
  late Map<String, Device> online;
  late List<(String, int, int)> notices;
  late int presenceAsks;

  // The declared size is what counts for the rules; the file on disk stays small
  File file(String name) => File(p.join(dir.path, name))..writeAsBytesSync(List.filled(3, 7));

  QueuedFile queued(String id, {String? path, int size = 3}) => QueuedFile(
    id: id,
    fileName: '$id.jpg',
    fileType: FileType.image,
    size: size,
    path: path ?? file('$id.jpg').path,
    ownedCopy: false,
    assetId: null,
    isMessage: false,
    preview: null,
    lastModified: null,
    lastAccessed: null,
  );

  void add(String id, List<QueuedFile> files, {DateTime? at}) => ref
      .redux(sendQueueProvider)
      .dispatch(AddQueuedSendAction(QueuedSend(id: id, targetFingerprint: _phone, targetAlias: 'Phone', createdAt: at ?? now, files: files)));

  List<String> queueIds() => ref.read(sendQueueProvider).map((e) => e.id).toList();

  setUp(() {
    final base = Directory('build/send_queue_test')..createSync(recursive: true);
    dir = base.createTempSync('runner');
    store = _Store();
    sender = _Sender();
    now = DateTime.utc(2026, 11, 26, 12);
    online = {};
    notices = [];
    presenceAsks = 0;
    ref = RefenaContainer(
      overrides: [
        persistenceProvider.overrideWithValue(store),
        sendProvider.overrideWithNotifier((ref) => _NoSends()),
      ],
    );
    runner = SendQueueRunner(
      ref,
      sender: sender,
      clock: () => now,
      contentLength: (_) async => null,
      notice: (entry, {required sent, required missing}) => notices.add((entry.id, sent, missing)),
      online: () => online,
      askPresence: () => presenceAsks++,
    );
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('waits while the device is offline, sends as soon as it is online', () async {
    add('a', [queued('1')]);
    runner.pump();
    await pumpEventQueue();
    expect(sender.attempts, isEmpty);

    online = {_phone: _device('192.168.1.5')};
    runner.pump();
    await settle(() => sender.attempts.isNotEmpty);
    expect(sender.attempts, hasLength(1));
    expect(sender.attempts.single.fileIds, ['1'], reason: 'the queued IDs, so the result maps back to the batch');
    expect(SendQueueRunner.isQueueSession(sender.attempts.single.sessionId), isTrue);

    runner.pump(); // a second trigger while it is being sent starts nothing
    await pumpEventQueue();
    expect(sender.attempts, hasLength(1));

    sender.attempts.single.end(SessionStatus.finished);
    await pumpEventQueue();
    expect(queueIds(), isEmpty);
    expect(notices, [('a', 1, 0)]);
    expect(SendQueueRunner.isQueueSession(sender.attempts.single.sessionId), isFalse);
    expect(sender.closed[sender.attempts.single.sessionId], isTrue, reason: 'the delivered send is recorded');
  });

  test('batches go out one after another, oldest first', () async {
    add('second', [queued('2')], at: now.subtract(const Duration(minutes: 1)));
    add('first', [queued('1')], at: now.subtract(const Duration(minutes: 5)));
    online = {_phone: _device('192.168.1.5')};
    runner.pump();
    await settle(() => sender.attempts.isNotEmpty);
    expect(sender.attempts.map((a) => a.fileIds.single), ['1']);
    sender.attempts.last.end(SessionStatus.finished);
    await settle(() => sender.attempts.length == 2);
    expect(sender.attempts.map((a) => a.fileIds.single), ['1', '2']);
  });

  test('not reachable: kept, not recorded, tried again after 30 s', () async {
    add('a', [queued('1')]);
    online = {_phone: _device('192.168.1.5')};
    runner.pump();
    await settle(() => sender.attempts.isNotEmpty);
    sender.attempts.single.end(SessionStatus.finishedWithErrors, error: 'Connection refused');
    await pumpEventQueue();
    expect(queueIds(), ['a']);
    expect(sender.closed.values.single, isFalse, reason: 'the attempt is not recorded in the history');
    expect(runner.retryAt(_phone), now.add(const Duration(seconds: 30)));

    runner.pump();
    await pumpEventQueue();
    expect(sender.attempts, hasLength(1));

    now = now.add(const Duration(seconds: 30));
    runner.pump();
    await settle(() => sender.attempts.length == 2);
    expect(sender.attempts, hasLength(2));
  });

  test('broken off partway: only what did not arrive keeps waiting', () async {
    add('a', [queued('1'), queued('2'), queued('3')]);
    online = {_phone: _device('192.168.1.5')};
    runner.pump();
    await settle(() => sender.attempts.isNotEmpty);
    sender.attempts.single.end(
      SessionStatus.finishedWithErrors,
      statuses: {'1': FileStatus.finished, '2': FileStatus.failed, '3': FileStatus.queue},
    );
    await pumpEventQueue();
    expect(ref.read(sendQueueProvider).single.files.map((f) => f.id), ['2', '3']);
  });

  test('declined: dropped', () async {
    add('a', [queued('1')]);
    online = {_phone: _device('192.168.1.5')};
    runner.pump();
    await settle(() => sender.attempts.isNotEmpty);
    sender.attempts.single.end(SessionStatus.declined);
    await pumpEventQueue();
    expect(queueIds(), isEmpty);
    expect(notices, isEmpty);
  });

  test('deleted files are left out and recorded; a batch with nothing left is not sent at all', () async {
    add('some', [queued('1'), queued('gone', path: p.join(dir.path, 'nothing-here.jpg'))]);
    online = {_phone: _device('192.168.1.5')};
    runner.pump();
    await settle(() => sender.attempts.isNotEmpty);
    expect(sender.attempts.single.fileIds, ['1']);
    sender.attempts.single.end(SessionStatus.finished);
    await pumpEventQueue();
    expect(notices, [('some', 1, 1)]);
    expect(ref.read(sentHistoryProvider).single.result, SentHistoryResult.missing);
    expect(ref.read(sentHistoryProvider).single.files.single.fileName, 'gone.jpg');

    add('none', [queued('x', path: p.join(dir.path, 'also-gone.jpg'))]);
    runner.pump();
    await settle(() => notices.length == 2);
    expect(sender.attempts, hasLength(1));
    expect(queueIds(), isEmpty);
    expect(notices.last, ('none', 0, 1));
  });

  test('after 7 days a batch is dropped and recorded as expired', () async {
    add('old', [queued('1')], at: now.subtract(const Duration(days: 7, minutes: 1)));
    add('new', [queued('2')], at: now.subtract(const Duration(days: 6)));
    runner.tick();
    await pumpEventQueue();
    expect(queueIds(), ['new']);
    expect(ref.read(sentHistoryProvider).single.result, SentHistoryResult.expired);
  });

  test('removing the device from "my devices" drops what waits for it', () async {
    add('a', [queued('1')]);
    ref.redux(favoritesProvider).dispatch(RemoveFavoriteAction(deviceFingerprint: _phone));
    runner.dropRemovedDevices();
    expect(queueIds(), isEmpty);
  });

  test('over Tailscale a large batch waits for the same Wi-Fi until "Send now"', () async {
    add('big', [queued('v', size: 60 * _mb)]);
    online = {_phone: _device('100.101.102.103')};
    runner.pump();
    await pumpEventQueue();
    expect(sender.attempts, isEmpty);

    runner.tryNow(_phone);
    await settle(() => sender.attempts.isNotEmpty);
    expect(presenceAsks, 1);
    expect(sender.attempts, hasLength(1));
  });

  test('nothing goes out while something else is being sent to the device', () async {
    ref = RefenaContainer(
      overrides: [
        persistenceProvider.overrideWithValue(store),
        sendProvider.overrideWithNotifier((ref) => _NoSends({'user': _activeSend()})),
      ],
    );
    runner = SendQueueRunner(
      ref,
      sender: sender,
      clock: () => now,
      contentLength: (_) async => null,
      notice: (_, {required sent, required missing}) {},
      online: () => online,
      askPresence: () {},
    );
    add('a', [queued('1')]);
    online = {_phone: _device('192.168.1.5')};
    runner.pump();
    await pumpEventQueue();
    expect(sender.attempts, isEmpty);
  });

  test('canceling a batch that is being sent stops the send', () async {
    add('a', [queued('1')]);
    online = {_phone: _device('192.168.1.5')};
    runner.pump();
    await settle(() => runner.isSending('a'));
    expect(runner.isSending('a'), isTrue);
    runner.cancel('a');
    expect(queueIds(), isEmpty);
    expect(sender.canceled, [sender.attempts.single.sessionId]);
    sender.attempts.single.end(SessionStatus.sending); // closed by the cancel
    await pumpEventQueue();
    expect(runner.isSending('a'), isFalse);
  });
}

SendSessionState _activeSend() => SendSessionState(
  sessionId: 'user',
  remoteSessionId: null,
  background: false,
  status: SessionStatus.sending,
  target: _device('192.168.1.5'),
  files: const {},
  hashedFileCount: 0,
  startTime: null,
  endTime: null,
  sendingTasks: const [],
  errorMessage: null,
);
