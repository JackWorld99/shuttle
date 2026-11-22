import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/api/cancel.dart';
import 'package:localsend_isolates/rust/api/crypto.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/util/file_hash.dart';

void main() {
  late _MockRustLibApi api;

  setUpAll(() {
    api = _MockRustLibApi();
    RustLib.initMock(api: api);
  });

  setUp(() {
    api.reset();
  });

  Future<Map<int, (String?, Object?)>> hashAll(
    List<FileHashSource> files, {
    required int concurrency,
    bool Function()? shouldStop,
    void Function(int index)? onDone,
    void Function(int index, int bytes)? onProgress,
  }) async {
    final results = <int, (String?, Object?)>{};
    await calculateFileHashes(
      files: files,
      cancelToken: _FakeToken(),
      concurrency: concurrency,
      shouldStop: shouldStop,
      onProgress: onProgress,
      onFileDone: (index, hash, error) {
        expect(results.containsKey(index), isFalse, reason: 'file $index reported twice');
        results[index] = (hash, error);
        onDone?.call(index);
      },
    );
    return results;
  }

  List<FileHashSource> paths(int n) => [for (var i = 0; i < n; i++) (path: 'f$i', bytes: null)];

  test('hashes at most `concurrency` files at once and starts them in order', () async {
    // Earlier files take longer, so they finish out of order.
    api.delay = (path) => Duration(milliseconds: 2 * (12 - int.parse(path.substring(1))));
    final progress = <int, int>{};

    final results = await hashAll(paths(12), concurrency: 3, onProgress: (index, bytes) => progress[index] = bytes);

    expect(api.maxRunning, 3);
    expect(api.started, [for (var i = 0; i < 12; i++) 'f$i']);
    expect(results, {for (var i = 0; i < 12; i++) i: ('hash-f$i', null)});
    expect(progress, {for (var i = 0; i < 12; i++) i: 100});
  });

  test('a file that cannot be hashed is reported with its error, the others still finish', () async {
    api.failing = {'f1'};

    final results = await hashAll(paths(3), concurrency: 2);

    expect(results[0], ('hash-f0', null));
    expect(results[1]!.$1, isNull);
    expect(results[1]!.$2, isA<StateError>());
    expect(results[2], ('hash-f2', null));
  });

  test('no new file is started once shouldStop returns true', () async {
    var stop = false;

    final results = await hashAll(paths(5), concurrency: 1, shouldStop: () => stop, onDone: (_) => stop = true);

    expect(api.started, ['f0']);
    expect(results.keys, [0]);
  });

  test('in-memory files are hashed from their bytes', () async {
    final results = await hashAll([(path: null, bytes: utf8Bytes('hello'))], concurrency: 4);

    expect(api.startedBytes, [utf8Bytes('hello')]);
    expect(results, {0: ('hash-5-bytes', null)});
  });

  test('the default concurrency stays between 1 and 4', () {
    expect(defaultHashConcurrency, inInclusiveRange(1, 4));
  });
}

Uint8List utf8Bytes(String s) => Uint8List.fromList(s.codeUnits);

class _FakeToken implements RsCancellationToken {
  @override
  void cancel() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Not mocked: ${invocation.memberName}');
}

class _MockRustLibApi implements RustLibApi {
  Duration Function(String path) delay = (_) => Duration.zero;
  Set<String> failing = {};
  final started = <String>[];
  final startedBytes = <Uint8List>[];
  int running = 0;
  int maxRunning = 0;

  void reset() {
    delay = (_) => Duration.zero;
    failing = {};
    started.clear();
    startedBytes.clear();
    running = 0;
    maxRunning = 0;
  }

  @override
  Stream<RsHashFileEvent> crateApiCryptoHashFile({
    String? path,
    int? fileDescriptor,
    Uint8List? bytes,
    required RsCancellationToken cancelToken,
  }) async* {
    if (path == null) {
      startedBytes.add(bytes!);
      yield RsHashFileEvent.done(hash: 'hash-${bytes.length}-bytes');
      return;
    }
    started.add(path);
    running++;
    maxRunning = max(maxRunning, running);
    try {
      await Future<void>.delayed(delay(path));
      if (failing.contains(path)) {
        throw StateError('cannot read $path');
      }
      yield RsHashFileEvent.progress(bytes: BigInt.from(100));
      yield RsHashFileEvent.done(hash: 'hash-$path');
    } finally {
      running--;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Not mocked: ${invocation.memberName}');
}
