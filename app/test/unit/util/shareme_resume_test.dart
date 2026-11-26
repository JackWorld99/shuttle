// Shuttle: continuing interrupted transfers (resume), receiving side: the index of the parts that wait for a
// continuation.

import 'dart:convert';
import 'dart:io';

import 'package:localsend_app/util/shareme_resume.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/dto/file_dto.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _cert = 'AABBCC';
const _otherCert = 'DDEEFF';
const _sha = '0123abcd';

FileDto _file(String id, {String? hash = _sha, int size = 1000}) => FileDto(
  id: id,
  fileName: '$id.mp4',
  size: size,
  fileType: FileType.video,
  hash: hash,
  preview: null,
  metadata: null,
);

void main() {
  late Directory dir;
  late File indexFile;
  late DateTime now;
  late Map<String, int?> lengths;
  late List<PartialFileLocation> discarded;

  ResumeStore store() => ResumeStore(
    indexFile: () async => indexFile,
    now: () => now,
    fileLength: (path) async => lengths[path],
    discard: (location) async => discarded.add(location),
  );

  HttpServerFilePartialEvent partial(String sessionId, String fileId, int saved, {String? path, String? uri}) => HttpServerFilePartialEvent(
    sessionId: sessionId,
    fileId: fileId,
    location: PartialFileLocation(path: path ?? (uri == null ? p.join(dir.path, '$fileId.mp4$partialFileSuffix') : null), uri: uri),
    saved: saved,
  );

  HttpServerFileUploadResultEvent result(String sessionId, String fileId, {String? error, int? partialSaved}) => HttpServerFileUploadResultEvent(
    sessionId: sessionId,
    fileId: fileId,
    path: null,
    savedToGallery: false,
    error: error,
    partialSaved: partialSaved,
  );

  /// Session s1 sent `a`, the connection was lost after [saved] bytes.
  Future<void> interrupt(ResumeStore s, {int saved = 400, String? uri}) async {
    s.registerSession(sessionId: 's1', senderCert: _cert, files: {'a': _file('a')});
    s.onUploadStarted('s1');
    await s.onPartial(partial('s1', 'a', 0, uri: uri));
    await s.onPartial(partial('s1', 'a', saved, uri: uri));
    await s.onResult(result('s1', 'a', error: 'Expected 1000 bytes, received $saved', partialSaved: saved));
  }

  setUp(() {
    final root = Directory('build/shareme_resume_test')..createSync(recursive: true);
    dir = root.createTempSync('run');
    indexFile = File(p.join(dir.path, 'index.json'));
    now = DateTime.utc(2026, 11, 26, 12);
    lengths = {};
    discarded = [];
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('the part of an interrupted file is offered to the same sender for the same file', () async {
    final s = store();
    await interrupt(s);
    lengths[p.join(dir.path, 'a.mp4$partialFileSuffix')] = 400;

    // Later, the same file is sent again (other file ID, new session)
    s.registerSession(sessionId: 's2', senderCert: _cert, files: {'x': _file('x')});
    final plan = await s.plan(sessionId: 's2', acceptedIds: ['x']);

    expect(plan!.offsets, {'x': 400});
    expect(plan.partialFiles['x']!.path, p.join(dir.path, 'a.mp4$partialFileSuffix'));
    expect(s.savedBefore(sessionId: 's2', fileId: 'x'), 400);
  });

  test('another sender, other content or a file without checksum starts at 0', () async {
    final s = store();
    await interrupt(s);
    lengths[p.join(dir.path, 'a.mp4$partialFileSuffix')] = 400;

    s.registerSession(sessionId: 'other', senderCert: _otherCert, files: {'x': _file('x')});
    expect((await s.plan(sessionId: 'other', acceptedIds: ['x']))!.offsets, {'x': 0});

    s.registerSession(
      sessionId: 'changed',
      senderCert: _cert,
      files: {
        'x': _file('x', hash: 'ffff'),
        'y': _file('y', size: 999),
      },
    );
    expect((await s.plan(sessionId: 'changed', acceptedIds: ['x', 'y']))!.offsets, {'x': 0, 'y': 0});

    s.registerSession(sessionId: 'nohash', senderCert: _cert, files: {'x': _file('x', hash: null)});
    expect((await s.plan(sessionId: 'nohash', acceptedIds: ['x']))!.offsets, isEmpty);
  });

  test('without a certificate (no encryption) nothing is continued', () async {
    final s = store();
    s.registerSession(sessionId: 's1', senderCert: null, files: {'a': _file('a')});

    expect(s.isResumable('s1'), isFalse);
    expect(await s.plan(sessionId: 's1', acceptedIds: ['a']), isNull);
  });

  test('only the accepted files are planned', () async {
    final s = store();
    s.registerSession(
      sessionId: 's1',
      senderCert: _cert,
      files: {
        'a': _file('a'),
        'b': _file('b', hash: 'bbbb'),
      },
    );

    expect((await s.plan(sessionId: 's1', acceptedIds: ['b']))!.offsets, {'b': 0});
  });

  test('a part that was deleted meanwhile starts at 0 and is forgotten; a shorter one continues at its length', () async {
    final s = store();
    await interrupt(s);

    s.registerSession(sessionId: 's2', senderCert: _cert, files: {'x': _file('x')});
    lengths[p.join(dir.path, 'a.mp4$partialFileSuffix')] = 300;
    expect((await s.plan(sessionId: 's2', acceptedIds: ['x']))!.offsets, {'x': 300});

    lengths.clear();
    expect((await s.plan(sessionId: 's2', acceptedIds: ['x']))!.offsets, {'x': 0});
    expect((await s.index).entries, isEmpty);
  });

  test('a gallery entry is trusted (it cannot be looked at from here) and kept at startup', () async {
    final s = store();
    await interrupt(s, uri: 'content://media/external/video/media/5');

    s.registerSession(sessionId: 's2', senderCert: _cert, files: {'x': _file('x')});
    final plan = await s.plan(sessionId: 's2', acceptedIds: ['x']);

    expect(plan!.offsets, {'x': 400});
    expect(plan.partialFiles['x']!.uri, 'content://media/external/video/media/5');
    expect(await s.galleryUris(), ['content://media/external/video/media/5']);
  });

  test('a completed file and a discarded part are forgotten', () async {
    final s = store();
    await interrupt(s);

    // The continuation completes it
    s.registerSession(sessionId: 's2', senderCert: _cert, files: {'x': _file('x')});
    s.onUploadStarted('s2');
    await s.onPartial(partial('s2', 'x', 400));
    await s.onResult(result('s2', 'x'));
    expect((await s.index).entries, isEmpty);

    // A failure that kept nothing (checksum mismatch, canceled)
    await interrupt(s);
    s.registerSession(sessionId: 's3', senderCert: _cert, files: {'y': _file('y')});
    s.onUploadStarted('s3');
    await s.onPartial(partial('s3', 'y', 400));
    await s.onResult(result('s3', 'y', error: 'Checksum mismatch'));
    expect((await s.index).entries, isEmpty);
  });

  test('a late result of an older session does not forget the part a newer session took over', () async {
    final s = store();
    await interrupt(s);
    s.registerSession(sessionId: 's2', senderCert: _cert, files: {'x': _file('x')});
    await s.onPartial(partial('s2', 'x', 600));

    s.onUploadStarted('s1');
    await s.onResult(result('s1', 'a', error: 'aborted'));

    expect((await s.index).entries.single.saved, 600);
  });

  test('the index survives a restart of the app', () async {
    final first = store();
    await interrupt(first);
    await (await first.index).flush();

    final restarted = store();
    restarted.registerSession(sessionId: 's2', senderCert: _cert, files: {'x': _file('x')});
    lengths[p.join(dir.path, 'a.mp4$partialFileSuffix')] = 400;

    expect((await restarted.plan(sessionId: 's2', acceptedIds: ['x']))!.offsets, {'x': 400});
    final json = jsonDecode(indexFile.readAsStringSync()) as List;
    expect(json.single['senderCert'], _cert);
    expect(json.single['saved'], 400);
  });

  test('a broken index starts empty instead of failing', () async {
    indexFile.writeAsStringSync('{not json');
    final s = store();
    s.registerSession(sessionId: 's1', senderCert: _cert, files: {'a': _file('a')});

    expect((await s.plan(sessionId: 's1', acceptedIds: ['a']))!.offsets, {'a': 0});
  });

  test('parts nobody continued for 3 days are deleted', () async {
    final s = store();
    await interrupt(s);

    now = now.add(const Duration(days: 2, hours: 23));
    expect(await s.cleanExpired(), 0);
    expect(discarded, isEmpty);

    now = now.add(const Duration(hours: 2));
    expect(await s.cleanExpired(), 1);
    expect(discarded.single.path, p.join(dir.path, 'a.mp4$partialFileSuffix'));
    expect((await s.index).entries, isEmpty);
  });

  test('canceling a session deletes its parts', () async {
    final s = store();
    await interrupt(s);

    await s.discardSession('other');
    expect(discarded, isEmpty);

    await s.discardSession('s1');
    expect(discarded.single.path, p.join(dir.path, 'a.mp4$partialFileSuffix'));
    expect((await s.index).entries, isEmpty);
  });

  test('a continuation waits until the uploads of the session it replaces reported what they saved', () async {
    final s = store();
    s.registerSession(sessionId: 's1', senderCert: _cert, files: {'a': _file('a')});
    s.onUploadStarted('s1');
    await s.onPartial(partial('s1', 'a', 0));

    var settled = false;
    final waiting = s.settled('s1').then((_) => settled = true);
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);

    await s.onResult(result('s1', 'a', error: 'aborted', partialSaved: 512));
    await waiting;
    expect(settled, isTrue);
    expect((await s.index).entries.single.saved, 512);

    // Nothing running: no wait
    await s.settled('s1');
    // Gives up after a while instead of hanging
    s.onUploadStarted('s9');
    await s.settled('s9', timeout: const Duration(milliseconds: 10));
  });

  test('a page keeps showing a session that was continued in a new one', () {
    ReceiveContinuation.link(from: 'one', to: 'two');
    ReceiveContinuation.link(from: 'two', to: 'three');

    expect(ReceiveContinuation.continuesTo('one', 'three'), isTrue);
    expect(ReceiveContinuation.continuesTo('three', 'three'), isTrue);
    expect(ReceiveContinuation.continuesTo('three', 'one'), isFalse);
    expect(ReceiveContinuation.continuesTo('else', 'three'), isFalse);
  });
}
