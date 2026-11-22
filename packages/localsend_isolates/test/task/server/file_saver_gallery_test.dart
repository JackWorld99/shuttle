import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/src/task/server/file_saver.dart';
import 'package:path/path.dart' as p;

const _channel = MethodChannel('org.localsend.localsend_app/localsend');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String destination;
  late String cache;
  late List<MethodCall> calls;
  late Object? Function(MethodCall call) answer;

  setUpAll(() {
    RustLib.initMock(api: _MockRustLibApi());
  });

  setUp(() {
    final root = Directory('build/file_saver_gallery_test')..createSync(recursive: true);
    tempDir = root.createTempSync('run');
    destination = p.join(tempDir.path, 'Download');
    cache = p.join(tempDir.path, 'cache');
    calls = [];
    answer = (call) => switch (call.method) {
      'createMediaStoreFile' => {'uri': 'content://media/external/images/media/7', 'fd': 42},
      'openFileForWriting' => 43,
      'deleteMediaStoreFile' => true,
      _ => null,
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return answer(call);
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  Future<FileSaveTarget> prepare({
    String fileName = 'photo.jpg',
    bool saveToGallery = true,
    bool isImage = true,
    int? androidSdkInt = 29,
  }) {
    return prepareFileSaveTarget(
      destinationDirectory: destination,
      cacheDirectory: cache,
      fileName: fileName,
      saveToGallery: saveToGallery,
      isImage: isImage,
      createdDirectories: {},
      androidSdkInt: androidSdkInt,
    );
  }

  List<String> filesIn(String dir) => Directory(dir).existsSync() ? Directory(dir).listSync().map((e) => p.basename(e.path)).toList() : [];

  group('Android 10+', () {
    test('an image is written straight into a pending gallery entry, not a cache file', () async {
      final target = await prepare();

      expect(target.kind, FileSaveKind.gallery);
      expect(target.path, isNull);
      expect(target.fileDescriptor, 42);
      expect(target.displayPath, 'content://media/external/images/media/7');
      expect(calls.map((c) => c.method), ['createMediaStoreFile']);
      expect(calls.single.arguments, {'fileName': 'photo.jpg', 'isImage': true});
      expect(filesIn(cache), isEmpty);
      expect(filesIn(destination), isEmpty);
    });

    test('a video entry is created as a video', () async {
      await prepare(fileName: 'clip.mp4', isImage: false);

      expect(calls.single.arguments, {'fileName': 'clip.mp4', 'isImage': false});
    });

    test('when the gallery does not take the file, it goes to the destination directory', () async {
      answer = (call) => throw PlatformException(code: 'UNSUPPORTED_FORMAT');

      final target = await prepare(fileName: 'photo.xyz');

      expect(target.kind, FileSaveKind.destination);
      expect(target.path, p.join(destination, 'photo.xyz'));
      expect(calls.map((c) => c.method), ['createMediaStoreFile']);
    });

    test('a name that tries to leave the directory is still refused', () async {
      await expectLater(prepare(fileName: p.join('..', 'photo.jpg')), throwsA('Path traversal detected'));
      expect(calls, isEmpty);
    });

    test('saving to a folder instead of the gallery is unaffected', () async {
      final target = await prepare(saveToGallery: false, androidSdkInt: 34);

      expect(target.kind, FileSaveKind.destination);
      expect(target.path, p.join(destination, 'photo.jpg'));
      expect(calls, isEmpty);
    });
  });

  test('Android 9 still receives gallery files into the cache first', () async {
    final target = await prepare(androidSdkInt: 28);

    expect(target.kind, FileSaveKind.galleryCache);
    expect(target.path, p.join(cache, 'photo.jpg'));
    expect(calls, isEmpty);
  });

  test('other platforms still receive gallery files into the cache first', () async {
    final target = await prepare(androidSdkInt: null);

    expect(target.kind, FileSaveKind.galleryCache);
    expect(calls, isEmpty);
  });

  test('a completely written gallery entry is published', () async {
    final target = await prepare();
    calls.clear();

    final result = await completeFileSaveTarget(
      target: target,
      destinationDirectory: destination,
      fileName: 'photo.jpg',
      isImage: true,
      createdDirectories: {},
    );

    expect(result, (true, null));
    expect(calls.map((c) => c.method), ['finishMediaStoreFile']);
    expect(calls.single.arguments, {'uri': 'content://media/external/images/media/7'});
  });

  test('a file in the destination directory is reported with its path', () async {
    final target = await prepare(saveToGallery: false);

    final result = await completeFileSaveTarget(
      target: target,
      destinationDirectory: destination,
      fileName: 'photo.jpg',
      isImage: true,
      createdDirectories: {},
    );

    expect(result, (false, p.join(destination, 'photo.jpg')));
    expect(calls, isEmpty);
  });

  test('a failed attempt deletes its gallery entry', () async {
    final target = await prepare();
    calls.clear();

    await discardFileSaveTarget(target);

    expect(calls.map((c) => c.method), ['deleteMediaStoreFile']);
    expect(calls.single.arguments, {'uri': 'content://media/external/images/media/7'});
  });

  test('a failed attempt keeps the incomplete file of other targets', () async {
    final target = await prepare(saveToGallery: false);
    File(target.path!).writeAsStringSync('partial');

    await discardFileSaveTarget(target);

    expect(calls, isEmpty);
    expect(File(target.path!).readAsStringSync(), 'partial');
  });

  test('a gallery entry that cannot be deleted does not fail the cleanup', () async {
    final target = await prepare();
    answer = (call) => throw PlatformException(code: 'MEDIA_STORE_FAILED');

    await discardFileSaveTarget(target);

    expect(calls.last.method, 'deleteMediaStoreFile');
  });

  test('reopening a gallery entry keeps it a gallery entry', () async {
    final target = await prepare();
    calls.clear();

    final reopened = await reopenFileSaveTarget(target);

    expect(reopened.kind, FileSaveKind.gallery);
    expect(reopened.fileDescriptor, 43);
    expect(reopened.displayPath, target.displayPath);
    expect(calls.single.method, 'openFileForWriting');
  });
}

class _MockRustLibApi implements RustLibApi {
  @override
  String crateApiFilenameSanitizeFileName({required String name}) => name;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Not mocked: ${invocation.memberName}');
}
