import 'dart:convert';
import 'dart:io';

import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/persistence/queued_send.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/model/state/send/sending_file.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/send_queue_provider.dart';
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
const _pc = 'pc-fp';
const _mb = 1024 * 1024;

Device _device(String fingerprint, String ip) => Device(
  signalingId: null,
  ip: ip,
  version: '2.1',
  port: 53317,
  https: true,
  fingerprint: fingerprint,
  alias: fingerprint,
  deviceModel: null,
  deviceType: DeviceType.mobile,
  download: false,
  channels: const [],
);

QueuedFile _file(String id, {int size = 10, String? path, bool owned = false, bool message = false}) => QueuedFile(
  id: id,
  fileName: '$id.jpg',
  fileType: message ? FileType.text : FileType.image,
  size: size,
  path: path,
  ownedCopy: owned,
  assetId: null,
  isMessage: message,
  preview: message ? 'hello' : null,
  lastModified: null,
  lastAccessed: null,
);

QueuedSend _entry(String id, String fingerprint, {DateTime? at, List<QueuedFile>? files}) => QueuedSend(
  id: id,
  targetFingerprint: fingerprint,
  targetAlias: 'Phone',
  createdAt: at ?? DateTime.utc(2026, 11, 26, 10),
  files: files ?? [_file('$id-1')],
);

SendSessionState _session(SessionStatus status, List<String> fileIds, {String? error}) => SendSessionState(
  sessionId: 's',
  remoteSessionId: null,
  background: true,
  status: status,
  target: _device(_phone, '192.168.1.5'),
  files: {
    for (final id in fileIds)
      id: SendingFile(
        file: FileDto(id: id, fileName: '$id.jpg', size: 1, fileType: FileType.image, hash: null, preview: null, metadata: null),
        token: null,
        thumbnail: null,
        asset: null,
        path: null,
        bytes: null,
        errorMessage: null,
      ),
  },
  hashedFileCount: fileIds.length,
  startTime: null,
  endTime: null,
  sendingTasks: const [],
  errorMessage: error,
);

QueueOutcome _classify(SendSessionState state, [Map<String, FileStatus> statuses = const {}]) => classifyQueueResult(
  QueueSendResult(state: state, statuses: statuses),
  insecureMessage: 'insecure',
  needsPinMessage: 'pin',
);

/// A store for the queue only (the queue's own provider reads and writes nothing else)
class _Store extends Fake implements PersistenceService {
  List<QueuedSend> saved = [];

  @override
  List<QueuedSend> getSendQueue() => saved;

  @override
  Future<void> setSendQueue(List<QueuedSend> entries) async => saved = entries;
}

Directory _tempDir() {
  final base = Directory('build/send_queue_test')..createSync(recursive: true);
  return base.createTempSync('q');
}

void main() {
  group('limits', () {
    test('at most 50 batches per device', () {
      final queue = [for (var i = 0; i < queueMaxPerDevice; i++) _entry('e$i', _phone)];
      expect(queueRefusal(queue, _phone, 0), QueueRefusal.full);
      expect(queueRefusal(queue, _pc, 0), isNull, reason: 'another device has its own 50');
      expect(queueRefusal(queue.sublist(1), _phone, 0), isNull);
    });

    test("Shuttle's own copies may take at most 2 GB, files kept by their location don't count", () {
      final queue = [
        _entry('a', _phone, files: [_file('a1', size: maxQueueCopyBytes - 100, owned: true)]),
        _entry(
          'b',
          _phone,
          files: [_file('b1', size: 10 * 1024 * _mb, path: r'D:\videos\big.mp4')],
        ),
      ];
      expect(queueRefusal(queue, _phone, 100), isNull);
      expect(queueRefusal(queue, _phone, 101), QueueRefusal.tooLarge);
    });

    test('a batch expires after 7 days', () {
      final e = _entry('a', _phone, at: DateTime.utc(2026, 11, 1, 12));
      expect(queueExpired(e, DateTime.utc(2026, 11, 8, 11, 59)), isFalse);
      expect(queueExpired(e, DateTime.utc(2026, 11, 8, 12)), isTrue);
    });

    test('waits 30 s, 1, 2, 5, then 10 min between failed attempts', () {
      expect([for (var i = 1; i <= 7; i++) queueRetryDelay(i).inSeconds], [30, 60, 120, 300, 600, 600, 600]);
    });
  });

  group('what goes out when', () {
    final lan = _device(_phone, '192.168.1.5');
    final remote = _device(_phone, '100.101.102.103');
    final big = _entry('big', _phone, files: [_file('v', size: 60 * _mb)]);
    final small = _entry('small', _phone, files: [_file('p', size: 3 * _mb)]);

    test('large batches wait for the same Wi-Fi while the device is only reachable over Tailscale', () {
      expect(holdUntilLan(big, remote, allowRemote: false), isTrue);
      expect(holdUntilLan(big, remote, allowRemote: true), isFalse, reason: '"Send now"');
      expect(holdUntilLan(big, lan, allowRemote: false), isFalse);
      expect(holdUntilLan(small, remote, allowRemote: false), isFalse, reason: 'up to 50 MB goes over Tailscale too');
    });

    test('per device the oldest batch, only when online, idle and not waiting to retry', () {
      final now = DateTime.utc(2026, 11, 26, 12);
      final older = _entry('older', _phone, at: DateTime.utc(2026, 11, 26, 9));
      final newer = _entry('newer', _phone, at: DateTime.utc(2026, 11, 26, 11));
      final forPc = _entry('pc', _pc);
      final queue = [newer, forPc, older];
      List<String> due({Map<String, Device>? online, Set<String> busy = const {}, Map<String, DateTime> retryAt = const {}}) => [
        for (final (e, _) in queueDue(
          queue: queue,
          online: online ?? {_phone: lan},
          busy: busy,
          retryAt: retryAt,
          allowRemote: const {},
          now: now,
        ))
          e.id,
      ];
      expect(due(), ['older'], reason: 'the PC is offline');
      expect(due(online: {}), isEmpty);
      expect(due(busy: {_phone}), isEmpty, reason: 'something else is being sent to it');
      expect(due(retryAt: {_phone: now.add(const Duration(seconds: 1))}), isEmpty);
      expect(due(retryAt: {_phone: now}), ['older']);
      expect(due(online: {_phone: lan, _pc: _device(_pc, '192.168.1.9')}).toSet(), {'older', 'pc'});
    });

    test('a held batch holds back the ones behind it (they go out in order)', () {
      final queue = [big, _entry('later', _phone, at: DateTime.utc(2026, 11, 26, 11))];
      final due = queueDue(queue: queue, online: {_phone: remote}, busy: const {}, retryAt: const {}, allowRemote: const {}, now: DateTime.now());
      expect(due, isEmpty);
      expect(queueHeldForLan(queue, remote, allowRemote: false), isTrue);
      expect(queueHeldForLan(queue, null, allowRemote: false), isFalse, reason: 'offline is not "held"');
    });
  });

  group('after an attempt', () {
    test('delivered: done', () {
      expect(_classify(_session(SessionStatus.finished, ['a'])).step, QueueStep.done);
    });

    test('not reachable (nothing delivered): try again later, not recorded', () {
      final outcome = _classify(_session(SessionStatus.finishedWithErrors, ['a', 'b'], error: 'Connection refused'));
      expect(outcome.step, QueueStep.retry);
      expect(outcome.record, isFalse);
      expect(_classify(_session(SessionStatus.recipientBusy, ['a'])).step, QueueStep.retry);
      expect(classifyQueueResult(null, insecureMessage: 'insecure', needsPinMessage: 'pin').step, QueueStep.retry);
    });

    test('broken off partway: keeps only what did not arrive', () {
      final outcome = _classify(_session(SessionStatus.finishedWithErrors, ['a', 'b', 'c']), {
        'a': FileStatus.finished,
        'b': FileStatus.failed,
        'c': FileStatus.queue,
      });
      expect(outcome.step, QueueStep.partial);
      expect(outcome.undelivered, {'b', 'c'});
      expect(outcome.record, isTrue);
    });

    test('files the receiver chose not to take count as handled', () {
      final outcome = _classify(_session(SessionStatus.finishedWithErrors, ['a', 'b']), {'a': FileStatus.finished, 'b': FileStatus.skipped});
      expect(outcome.step, QueueStep.done);
    });

    test('declined, canceled, PIN or no encryption: dropped (retrying would not help)', () {
      for (final state in [
        _session(SessionStatus.declined, ['a']),
        _session(SessionStatus.canceledByReceiver, ['a']),
        _session(SessionStatus.canceledBySender, ['a']),
        _session(SessionStatus.tooManyAttempts, ['a']),
        _session(SessionStatus.sending, ['a']), // closed while still sending = the user canceled it
        _session(SessionStatus.finishedWithErrors, ['a'], error: 'insecure'),
        _session(SessionStatus.finishedWithErrors, ['a'], error: 'pin'),
      ]) {
        expect(_classify(state).step, QueueStep.drop, reason: '${state.status} ${state.errorMessage}');
      }
    });
  });

  group('late text', () {
    final now = DateTime.utc(2026, 11, 26, 12);

    test('only text queued more than 10 minutes ago', () {
      expect(isLateQueuedMessage(null, now), isFalse, reason: 'ordinary text has no time');
      expect(isLateQueuedMessage('2026-11-26T11:55:00.000Z', now), isFalse);
      expect(isLateQueuedMessage('2026-11-26T11:49:00.000Z', now), isTrue);
      expect(isLateQueuedMessage('2026-11-26T19:49:00+08:00', now), isTrue, reason: 'time zones are respected');
      expect(isLateQueuedMessage('not a time', now), isFalse);
    });
  });

  group('stored', () {
    test('survives a round trip through JSON (restart)', () {
      final e = QueuedSend(
        id: 'id',
        targetFingerprint: _phone,
        targetAlias: '手机',
        createdAt: DateTime.utc(2026, 11, 26, 10, 30),
        files: [
          const QueuedFile(
            id: 'f',
            fileName: 'IMG_1.jpg',
            fileType: FileType.image,
            size: 1234,
            path: 'content://media/external/images/media/42',
            ownedCopy: false,
            assetId: '42',
            isMessage: false,
            preview: null,
            lastModified: '2026-11-20T08:00:00.000Z',
            lastAccessed: null,
          ),
          _file('t', message: true, owned: true, path: 'q/t.txt'),
        ],
      );
      final back = QueuedSend.fromJson(jsonDecode(jsonEncode(e.toJson())) as Map<String, dynamic>);
      expect(back.toJson(), e.toJson());
      expect(back.createdAt.isUtc, isTrue);
    });

    test('an unknown file type reads as "other"', () {
      final json = _entry('a', _phone).toJson();
      (json['files'] as List).first['fileType'] = 'hologram';
      expect(QueuedSend.fromJson(json).files.first.fileType, FileType.other);
    });

    test('changes are saved, and a batch can be trimmed or removed', () async {
      final store = _Store();
      final ref = RefenaContainer(overrides: [persistenceProvider.overrideWithValue(store)]);
      ref.redux(sendQueueProvider).dispatch(AddQueuedSendAction(_entry('a', _phone, files: [_file('1'), _file('2')])));
      ref.redux(sendQueueProvider).dispatch(AddQueuedSendAction(_entry('b', _pc)));
      await ref.notifier(sendQueueProvider).flushSave();
      expect(store.saved.map((e) => e.id), ['a', 'b']);

      ref.redux(sendQueueProvider).dispatch(KeepQueuedFilesAction(id: 'a', keep: {'2'}));
      expect(ref.read(sendQueueProvider).first.files.map((f) => f.id), ['2']);
      ref.redux(sendQueueProvider).dispatch(KeepQueuedFilesAction(id: 'a', keep: {}));
      expect(ref.read(sendQueueProvider).map((e) => e.id), ['b'], reason: 'nothing left to keep');

      ref.redux(sendQueueProvider).dispatch(RemoveQueuedSendsAction.device(_pc));
      await ref.notifier(sendQueueProvider).flushSave();
      expect(store.saved, isEmpty);
    });

    test('a store that cannot be read starts empty', () {
      final ref = RefenaContainer(overrides: [persistenceProvider.overrideWithValue(_BrokenStore())]);
      expect(ref.read(sendQueueProvider), isEmpty);
    });
  });

  group('files on disk', () {
    late Directory dir;
    late Directory queueDir;
    late Directory cacheDir;

    setUp(() {
      dir = _tempDir();
      queueDir = Directory(p.join(dir.path, 'send_queue'))..createSync();
      cacheDir = Directory(p.join(dir.path, 'cache'))..createSync();
    });

    tearDown(() => dir.deleteSync(recursive: true));

    CrossFile cross(String name, {String? path, List<int>? bytes, FileType type = FileType.image, int? size}) => CrossFile(
      name: name,
      fileType: type,
      size: size ?? bytes?.length ?? (path == null ? 0 : File(path).lengthSync()),
      thumbnail: null,
      asset: null,
      path: path,
      bytes: bytes,
      lastModified: null,
      lastAccessed: null,
    );

    test('text gets a copy; a file in the app cache is moved out of it; other files stay where they are', () async {
      final own = File(p.join(dir.path, 'mine.jpg'))..writeAsBytesSync([1, 2, 3]);
      final shared = File(p.join(cacheDir.path, 'shared.jpg'))..writeAsBytesSync([4, 5]);

      final text = await prepareQueuedFiles(
        [cross('m.txt', bytes: utf8.encode('你好'), type: FileType.text)],
        dir: queueDir,
        cacheDir: cacheDir.path,
      );
      expect(text.single.isMessage, isTrue);
      expect(text.single.preview, '你好');
      expect(text.single.ownedCopy, isTrue);
      expect(utf8.decode(File(text.single.path!).readAsBytesSync()), '你好');

      final files = await prepareQueuedFiles(
        [cross('mine.jpg', path: own.path), cross('shared.jpg', path: shared.path)],
        dir: queueDir,
        cacheDir: cacheDir.path,
      );
      expect(files[0].path, own.path);
      expect(files[0].ownedCopy, isFalse);
      expect(files[0].isMessage, isFalse);
      expect(files[1].ownedCopy, isTrue);
      expect(p.isWithin(queueDir.path, files[1].path!), isTrue);
      expect(shared.existsSync(), isFalse, reason: 'moved, not copied: Shuttle empties the cache on every start');
      expect(File(files[1].path!).readAsBytesSync(), [4, 5]);

      expect(
        queueCopyBytes([
          cross('a', path: own.path),
          cross('b', bytes: [1, 2]),
        ], cacheDir: cacheDir.path),
        2,
      );
    });

    test('at send time: gone files are left out, the rest goes out as it is now; text is read back with its queue time', () async {
      final kept = File(p.join(dir.path, 'kept.jpg'))..writeAsBytesSync([1, 2, 3]);
      final message = File(p.join(queueDir.path, 'm.txt'))..writeAsStringSync('hi');
      final entry = _entry(
        'e',
        _phone,
        at: DateTime.utc(2026, 11, 26, 9, 15),
        files: [
          _file('kept', size: 1, path: kept.path),
          _file('gone', path: p.join(dir.path, 'gone.jpg')),
          _file('nopath'),
          _file('uriGone', path: 'content://x/gone'),
          _file('uriNoSize', size: 77, path: 'content://x/nosize'),
          _file('uri', path: 'content://x/ok'),
        ],
      );
      final resolved = await resolveQueuedFiles(
        entry,
        contentLength: (uri) async => switch (uri.path) {
          '/ok' => 42,
          '/nosize' => -1,
          _ => null,
        },
      );
      expect(resolved.missing.map((f) => f.id), ['gone', 'nopath', 'uriGone']);
      expect({for (final (q, c) in resolved.available) q.id: c.size}, {'kept': 3, 'uriNoSize': 77, 'uri': 42});

      final text = await resolveQueuedFiles(
        _entry(
          't',
          _phone,
          at: DateTime.utc(2026, 11, 26, 9, 15),
          files: [_file('m', message: true, owned: true, path: message.path)],
        ),
        contentLength: (_) async => null,
      );
      final (_, cross) = text.available.single;
      expect(utf8.decode(cross.bytes!), 'hi');
      expect(cross.path, isNull, reason: 'sent as a message, from memory');
      expect(cross.lastModified, '2026-11-26T09:15:00.000Z');
    });

    test("only Shuttle's own copies are deleted", () async {
      final user = File(p.join(dir.path, 'user.jpg'))..writeAsBytesSync([1]);
      final copy = File(p.join(queueDir.path, 'copy.jpg'))..writeAsBytesSync([1]);
      await deleteQueueCopies([_file('u', path: user.path), _file('c', path: copy.path, owned: true)]);
      expect(user.existsSync(), isTrue);
      expect(copy.existsSync(), isFalse);
    });
  });
}

class _BrokenStore extends Fake implements PersistenceService {
  @override
  List<QueuedSend> getSendQueue() => throw const FormatException('broken');
}
