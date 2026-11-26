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
      'openFileForContinuing' => 44,
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
      // Shuttle: received under a temporary name until it is complete
      expect(target.path, p.join(destination, 'photo.xyz$partialFileSuffix'));
      expect(calls.map((c) => c.method), ['createMediaStoreFile']);
    });

    test('a name that tries to leave the directory is still refused', () async {
      await expectLater(prepare(fileName: p.join('..', 'photo.jpg')), throwsA('Path traversal detected'));
      expect(calls, isEmpty);
    });

    test('saving to a folder instead of the gallery is unaffected', () async {
      final target = await prepare(saveToGallery: false, androidSdkInt: 34);

      expect(target.kind, FileSaveKind.destination);
      expect(target.path, p.join(destination, 'photo.jpg$partialFileSuffix'));
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
    File(target.path!).writeAsStringSync('complete');

    final result = await completeFileSaveTarget(
      target: target,
      destinationDirectory: destination,
      fileName: 'photo.jpg',
      isImage: true,
      createdDirectories: {},
    );

    expect(result, (false, p.join(destination, 'photo.jpg')));
    expect(calls, isEmpty);
    // Shuttle: only the complete file gets its real name
    expect(filesIn(destination), ['photo.jpg']);
    expect(File(p.join(destination, 'photo.jpg')).readAsStringSync(), 'complete');
  });

  test('a failed attempt deletes its gallery entry', () async {
    final target = await prepare();
    calls.clear();

    await discardFileSaveTarget(target);

    expect(calls.map((c) => c.method), ['deleteMediaStoreFile']);
    expect(calls.single.arguments, {'uri': 'content://media/external/images/media/7'});
  });

  test('a failed attempt deletes its partial file in the destination directory', () async {
    final target = await prepare(saveToGallery: false);
    File(target.path!).writeAsStringSync('partial');

    await discardFileSaveTarget(target);

    expect(calls, isEmpty);
    expect(filesIn(destination), isEmpty);
  });

  test('a failed attempt keeps the incomplete file of a SAF document (overwritten by a retry)', () async {
    final target = FileSaveTarget(path: null, fileDescriptor: 9, displayPath: 'content://doc/1');

    await discardFileSaveTarget(target);

    expect(calls, isEmpty);
  });

  group('Shuttle: partial files (resume)', () {
    test('a partial name that is taken gets a number, the real name is not touched', () async {
      Directory(destination).createSync(recursive: true);
      File(p.join(destination, 'video.mp4$partialFileSuffix')).writeAsStringSync('another transfer');

      final target = await prepare(fileName: 'video.mp4', saveToGallery: false);

      expect(target.path, p.join(destination, 'video.mp4 (2)$partialFileSuffix'));
      expect(target.partial, isTrue);
      expect(target.continuable, isTrue);
    });

    test('a complete file whose real name was taken meanwhile gets a numbered name', () async {
      final target = await prepare(fileName: 'video.mp4', saveToGallery: false);
      File(target.path!).writeAsStringSync('new');
      File(p.join(destination, 'video.mp4')).writeAsStringSync('old');

      final result = await completeFileSaveTarget(
        target: target,
        destinationDirectory: destination,
        fileName: 'video.mp4',
        isImage: false,
        createdDirectories: {},
      );

      expect(result, (false, p.join(destination, 'video (2).mp4')));
      expect(File(p.join(destination, 'video.mp4')).readAsStringSync(), 'old');
      expect(File(p.join(destination, 'video (2).mp4')).readAsStringSync(), 'new');
      expect(filesIn(destination).where((f) => f.endsWith(partialFileSuffix)), isEmpty);
    });

    test('a file of a folder transfer keeps its sub-directory', () async {
      final target = await prepare(fileName: p.join('trip', 'clip.mp4'), saveToGallery: false);
      File(target.path!).writeAsStringSync('clip');

      final result = await completeFileSaveTarget(
        target: target,
        destinationDirectory: destination,
        fileName: p.join('trip', 'clip.mp4'),
        isImage: false,
        createdDirectories: {},
      );

      expect(result, (false, p.join(destination, 'trip', 'clip.mp4')));
    });

    test('a gallery entry and a partial file can be continued, the gallery cache and SAF documents not', () async {
      expect((await prepare()).continuable, isTrue);
      expect((await prepare(saveToGallery: false)).continuable, isTrue);
      expect((await prepare(androidSdkInt: 28)).continuable, isFalse);
      expect(FileSaveTarget(path: null, fileDescriptor: 9, displayPath: 'content://doc/1').continuable, isFalse);
    });

    test('a partial file is continued at its path', () async {
      final path = p.join(destination, 'video.mp4$partialFileSuffix');

      final target = await reopenPartialFile(PartialFileLocation(path: path, uri: null));

      expect(target.path, path);
      expect(target.partial, isTrue);
      expect(target.kind, FileSaveKind.destination);
      expect(calls, isEmpty);
    });

    test('a pending gallery entry is opened for reading and writing to continue it', () async {
      final target = await reopenPartialFile(const PartialFileLocation(path: null, uri: 'content://media/external/video/media/9'));

      expect(target.kind, FileSaveKind.gallery);
      expect(target.fileDescriptor, 44);
      expect(target.displayPath, 'content://media/external/video/media/9');
      expect(calls.single.method, 'openFileForContinuing');
      expect(calls.single.arguments, {'uri': 'content://media/external/video/media/9'});
    });

    test('reopening a gallery entry to continue it does not truncate it', () async {
      final target = await prepare();
      calls.clear();

      final reopened = await reopenFileSaveTarget(target, continuing: true);

      expect(reopened.fileDescriptor, 44);
      expect(calls.single.method, 'openFileForContinuing');
    });

    test('the location of a target is its path or its gallery entry', () async {
      final file = await prepare(saveToGallery: false);
      final entry = await prepare();

      expect(PartialFileLocation.of(file).path, file.path);
      expect(PartialFileLocation.of(file).uri, isNull);
      expect(PartialFileLocation.of(entry).path, isNull);
      expect(PartialFileLocation.of(entry).uri, 'content://media/external/images/media/7');
    });

    test('a part is discarded by its location', () async {
      final target = await prepare(saveToGallery: false);
      File(target.path!).writeAsStringSync('part');
      calls.clear();

      await discardPartialFile(PartialFileLocation(path: target.path, uri: null));
      await discardPartialFile(const PartialFileLocation(path: null, uri: 'content://media/external/video/media/9'));
      // Gone already: nothing to do, no error
      await discardPartialFile(PartialFileLocation(path: target.path, uri: null));

      expect(File(target.path!).existsSync(), isFalse);
      expect(calls.single.method, 'deleteMediaStoreFile');
    });
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
