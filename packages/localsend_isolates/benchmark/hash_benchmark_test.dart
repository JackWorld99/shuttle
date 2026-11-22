// Measures how long the sender needs to checksum a batch of files before the
// prepare-upload request can be sent: the old one-file-after-another loop
// against [calculateFileHashes] with several concurrency limits.
//
// Not part of `flutter test` (it lives outside test/). It needs the real Rust
// library, built from the repository root with
//   cargo build --release -p rust_lib_localsend_app
// and is run from packages/localsend_isolates with
//   flutter test benchmark/hash_benchmark_test.dart
// RUST_LIB may point to another build of the library.
//
// The 200 files of 2.5 MiB (500 MiB, like a batch of photos) are generated
// once into build/hash_bench and reused, so every run after the first one
// reads them from the OS file cache: the numbers show the hashing and the
// per-file overhead, not the speed of the disk.
@Timeout.none
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/api/cancel.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/util/file_hash.dart';

const _fileCount = 200;
const _fileSize = 5 * 512 * 1024;
const _rounds = 5;

String _defaultLibrary() {
  final name = Platform.isWindows
      ? 'rust_lib_localsend_app.dll'
      : Platform.isMacOS
      ? 'librust_lib_localsend_app.dylib'
      : 'librust_lib_localsend_app.so';
  return '${Directory.current.path}/../../target/release/$name';
}

List<String> _prepareFiles() {
  final dir = Directory('build/hash_bench')..createSync(recursive: true);
  final random = Random(20261121);
  final paths = <String>[];
  for (var i = 0; i < _fileCount; i++) {
    final file = File('${dir.path}/photo_$i.bin');
    if (!file.existsSync() || file.lengthSync() != _fileSize) {
      final bytes = Uint8List(_fileSize);
      for (var j = 0; j < bytes.length; j++) {
        bytes[j] = random.nextInt(256);
      }
      file.writeAsBytesSync(bytes, flush: true);
    }
    paths.add(file.absolute.path);
  }
  return paths;
}

/// The loop the sender used before: one file after another.
Future<List<String?>> _serial(List<String> paths) async {
  final token = createCancellationToken();
  final hashes = List<String?>.filled(paths.length, null);
  for (var i = 0; i < paths.length; i++) {
    hashes[i] = await calculateFileHash(path: paths[i], bytes: null, cancelToken: token, onProgress: (_) {});
  }
  return hashes;
}

Future<List<String?>> _parallel(List<String> paths, int concurrency) async {
  final token = createCancellationToken();
  final hashes = List<String?>.filled(paths.length, null);
  await calculateFileHashes(
    files: [for (final p in paths) (path: p, bytes: null)],
    cancelToken: token,
    concurrency: concurrency,
    onProgress: (_, _) {},
    onFileDone: (index, hash, error) {
      if (error != null) throw error;
      hashes[index] = hash;
    },
  );
  return hashes;
}

void main() {
  test('checksum batch benchmark', () async {
    final library = File(Platform.environment['RUST_LIB'] ?? _defaultLibrary());
    if (!library.existsSync()) {
      fail('Rust library not found at ${library.path}; build it with cargo build --release -p rust_lib_localsend_app');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(library.path));

    final paths = _prepareFiles();
    final modes = <String, Future<List<String?>> Function()>{
      'serial (old loop)': () => _serial(paths),
      for (final c in {1, 2, 4, 6, 8, defaultHashConcurrency})
        'parallel x$c${c == defaultHashConcurrency ? ' (default)' : ''}': () => _parallel(paths, c),
    };

    // Warm-up: fills the OS file cache and the reference checksums.
    final reference = await _serial(paths);

    final times = {for (final name in modes.keys) name: <int>[]};
    for (var round = 0; round < _rounds; round++) {
      for (final MapEntry(key: name, value: run) in modes.entries) {
        final watch = Stopwatch()..start();
        final hashes = await run();
        watch.stop();
        expect(hashes, reference, reason: name);
        times[name]!.add(watch.elapsedMilliseconds);
      }
    }

    // ignore: avoid_print
    print(
      '$_fileCount files x ${_fileSize / 1024 / 1024} MiB, '
      '${Platform.numberOfProcessors} logical processors, ${Platform.operatingSystem}, $_rounds rounds',
    );
    for (final MapEntry(key: name, value: ms) in times.entries) {
      final sorted = [...ms]..sort();
      // ignore: avoid_print
      print('${name.padRight(24)} median ${sorted[sorted.length ~/ 2]} ms   all $ms');
    }
  });
}
