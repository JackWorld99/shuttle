import 'dart:io';
import 'dart:typed_data';

import 'package:localsend_isolates/rust/api/cancel.dart';
import 'package:localsend_isolates/rust/api/crypto.dart' as rust_crypto;
import 'package:localsend_isolates/util/android_channel.dart';
import 'package:pool/pool.dart';

/// How many files [calculateFileHashes] hashes at the same time by default.
///
/// The hashing runs on the Rust async runtime, which is shared with the HTTP
/// server and client, so only half of the cores are used, and at most 4.
/// Each running hash holds one 512 KiB read buffer; files are never loaded
/// into memory as a whole.
int get defaultHashConcurrency => (Platform.numberOfProcessors ~/ 2).clamp(1, 4);

/// The content of a file to hash with [calculateFileHashes]:
/// a [path] (or Android content URI), or the [bytes] of an in-memory file.
typedef FileHashSource = ({String? path, List<int>? bytes});

/// Calculates the SHA-256 checksums of several files, at most [concurrency]
/// files at the same time.
///
/// The files are started in the order of [files]; [onFileDone] is called once
/// per file as soon as that file is finished (so not necessarily in order),
/// with its index and either the checksum or the error that prevented it.
/// [onProgress] reports the cumulative number of bytes hashed of a file.
///
/// No new file is started once [shouldStop] returns true. Cancelling
/// [cancelToken] additionally aborts the files that are already running;
/// they are reported to [onFileDone] with the cancellation error.
Future<void> calculateFileHashes({
  required List<FileHashSource> files,
  required RsCancellationToken cancelToken,
  required int concurrency,
  required void Function(int index, String? hash, Object? error) onFileDone,
  void Function(int index, int bytes)? onProgress,
  bool Function()? shouldStop,
}) async {
  await Pool(concurrency).forEach<int, void>(Iterable<int>.generate(files.length), (index) async {
    if (shouldStop?.call() ?? false) {
      return;
    }
    final file = files[index];
    String? hash;
    Object? error;
    try {
      hash = await calculateFileHash(
        path: file.path,
        bytes: file.bytes,
        cancelToken: cancelToken,
        onProgress: onProgress == null ? null : (bytes) => onProgress(index, bytes),
      );
    } catch (e) {
      error = e;
    }
    onFileDone(index, hash, error);
  }).drain<void>();
}

/// Calculates the SHA-256 checksum (lowercase hex) of a single file.
///
/// The file is read and hashed in Rust, so this only occupies the Dart isolate
/// while waiting for the result.
/// [onProgress] is called with the cumulative number of bytes hashed so far;
/// the events are already throttled on the Rust side.
/// Cancelling [cancelToken] aborts the calculation and throws.
Future<String> calculateFileHash({
  required String? path,
  required List<int>? bytes,
  required RsCancellationToken cancelToken,
  void Function(int bytes)? onProgress,
}) async {
  final Stream<rust_crypto.RsHashFileEvent> events;
  if (path != null) {
    if (path.startsWith('content://')) {
      // Android SAF files can only be read through a file descriptor.
      // The descriptor is closed by Rust after the file has been read.
      final fileDescriptor = await getFileDescriptorAndroid(uri: path);
      events = rust_crypto.hashFile(fileDescriptor: fileDescriptor, cancelToken: cancelToken);
    } else {
      events = rust_crypto.hashFile(path: path, cancelToken: cancelToken);
    }
  } else if (bytes != null) {
    events = rust_crypto.hashFile(
      bytes: bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      cancelToken: cancelToken,
    );
  } else {
    throw ArgumentError('Either path or bytes must be provided');
  }

  await for (final event in events) {
    switch (event) {
      case rust_crypto.RsHashFileEvent_Progress():
        onProgress?.call(event.bytes.toInt());
      case rust_crypto.RsHashFileEvent_Done():
        return event.hash;
    }
  }

  // The Done event is always the last event, so this is unreachable unless
  // the Rust side failed, in which case the loop above has already thrown.
  throw StateError('Hashing ended without a result');
}
