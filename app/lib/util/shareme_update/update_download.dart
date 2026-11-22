// Shuttle auto-update: downloads the manifest and the installer, computing SHA-256 while downloading. The installer is downloaded
// in a background isolate ([downloadUpdateFileInBackground]).
// Uses only dart:io's HttpClient (GitHub download URLs redirect with 302 to githubusercontent, which HttpClient follows itself).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart' as crypto;
import 'package:localsend_app/util/shareme_update/update_manifest.dart';
import 'package:meta/meta.dart';

/// Requests carry only this, never the device name or any personal information.
const updateUserAgent = 'Shuttle-Updater';

/// No network, a 404, etc. The UI shows "Couldn't check" and tries again next time.
class UpdateNetworkException implements Exception {
  final String message;

  const UpdateNetworkException(this.message);

  @override
  String toString() => 'UpdateNetworkException: $message';
}

HttpClient newUpdateHttpClient() => HttpClient()
  ..connectionTimeout = const Duration(seconds: 20)
  ..userAgent = updateUserAgent;

/// Downloads a small text file (the manifest), giving up beyond [maxBytes].
Future<String> fetchUpdateText(HttpClient client, Uri url, {required int maxBytes}) async {
  final response = await _get(client, url);
  final bytes = <int>[];
  await for (final chunk in response.timeout(const Duration(seconds: 30))) {
    bytes.addAll(chunk);
    if (bytes.length > maxBytes) throw const UpdateNetworkException('manifest too large');
  }
  return utf8.decode(bytes, allowMalformed: false);
}

/// Downloads to [target]: writes `<target>.part` first and renames it to [target] only if size and SHA-256 both match; otherwise
/// deletes it and throws [UpdateVerifyException]. An existing [target] that matches is used as is (e.g. downloaded earlier, not yet installed).
Future<void> downloadUpdateFile(
  HttpClient client,
  UpdateFile file,
  File target, {
  void Function(int received, int total)? onProgress,
}) async {
  if (await updateFileMatches(target, file)) return;
  if (target.existsSync()) await target.delete();

  final part = File('${target.path}.part');
  await part.parent.create(recursive: true);
  final digest = _DigestSink();
  final hasher = crypto.sha256.startChunkedConversion(digest);
  final sink = part.openWrite();
  var received = 0;
  try {
    final response = await _get(client, Uri.parse(file.url));
    await for (final chunk in response.timeout(const Duration(seconds: 60))) {
      received += chunk.length;
      if (received > file.size) throw const UpdateVerifyException('file is larger than the manifest says');
      hasher.add(chunk);
      sink.add(chunk);
      onProgress?.call(received, file.size);
    }
    await sink.flush();
    await sink.close();
    hasher.close();
  } catch (_) {
    await sink.close().catchError((_) {});
    if (part.existsSync()) await part.delete();
    rethrow;
  }

  if (received != file.size || digest.value.toString() != file.sha256) {
    await part.delete();
    throw const UpdateVerifyException('downloaded file does not match the manifest');
  }
  await renameWithRetry(part, target.path);
}

/// Renames, retrying after a short wait on failure (for up to about 10 seconds).
///
/// Why: once, a freshly downloaded installer passed verification but the rename failed, leaving a complete `.part` and nothing shown
/// in the UI; later downloads of the same file worked fine. Most likely Windows Defender scans an exe it hasn't seen before once it
/// is written (possibly asking the cloud too) and holds the file meanwhile, so renaming fails. The occasional test failures when
/// touching received.exe right after writing it are the same thing.
Future<void> renameWithRetry(
  File from,
  String to, {
  int attempts = 20,
  Duration delay = const Duration(milliseconds: 500),
  @visibleForTesting Future<void> Function(File from, String to)? rename,
}) async {
  final doRename = rename ?? (File f, String t) => f.rename(t);
  for (var attempt = 1; ; attempt++) {
    try {
      await doRename(from, to);
      return;
    } on FileSystemException {
      if (attempt >= attempts) rethrow;
      await Future<void>.delayed(delay);
    }
  }
}

/// Runs [downloadUpdateFile] in a background isolate and sends progress back to the main isolate.
///
/// Why: inside the app (Windows, with the main isolate also running the UI) a 20 MB download took almost 3 minutes, about 117 KB/s,
/// versus 1.1 s for curl on the same URL and 6.4 s for the same code run on its own. Every small chunk (5 KB on average) waited
/// about 46 ms for its turn on the main isolate. A background isolate has its own event loop and doesn't compete with the UI.
/// Verification (size, SHA-256, delete on mismatch) is exactly the same as before. Errors are still thrown as
/// [UpdateVerifyException] / [UpdateNetworkException] (the isolate passes exceptions back unchanged).
Future<void> downloadUpdateFileInBackground(
  UpdateFile file,
  File target, {
  void Function(int received, int total)? onProgress,
}) async {
  final progress = ReceivePort();
  progress.listen((message) {
    if (message case [final int received, final int total]) onProgress?.call(received, total);
  });
  try {
    await _runInIsolate(file, target, progress.sendPort, updateAllowHttpForTests);
  } finally {
    progress.close();
  }
}

/// A separate function: the closure passed to the isolate may only capture objects that can be sent across isolates (all these
/// parameters can). Inside [downloadUpdateFileInBackground], onProgress captured by another closure in the same scope could be
/// dragged along and fail to send.
Future<void> _runInIsolate(UpdateFile file, File target, SendPort port, bool allowHttp) =>
    Isolate.run(() => _downloadInIsolate(file, target, port, allowHttp), debugName: 'shuttle-update-download');

Future<void> _downloadInIsolate(UpdateFile file, File target, SendPort port, bool allowHttp) async {
  updateAllowHttpForTests = allowHttp;
  final client = newUpdateHttpClient();
  var lastPercent = -1;
  try {
    await downloadUpdateFile(
      client,
      file,
      target,
      onProgress: (received, total) {
        // Send once per 1% instead of a cross-isolate message for every chunk
        final percent = total == 0 ? 100 : received * 100 ~/ total;
        if (percent != lastPercent) {
          lastPercent = percent;
          port.send([received, total]);
        }
      },
    );
  } finally {
    client.close();
  }
}

/// The file exists and its size and SHA-256 match the manifest. Checked again right before installing (a long time may have passed
/// since the download).
Future<bool> updateFileMatches(File target, UpdateFile file) async {
  if (!target.existsSync() || await target.length() != file.size) return false;
  final digest = await crypto.sha256.bind(target.openRead()).first;
  return digest.toString() == file.sha256;
}

/// Unit tests only (local http server). Production always uses https.
@visibleForTesting
bool updateAllowHttpForTests = false;

Future<HttpClientResponse> _get(HttpClient client, Uri url) async {
  if (url.scheme != 'https' && !(updateAllowHttpForTests && url.scheme == 'http')) throw UpdateNetworkException('not https: $url');
  final HttpClientResponse response;
  try {
    final request = await client.getUrl(url).timeout(const Duration(seconds: 30));
    response = await request.close().timeout(const Duration(seconds: 30));
  } on TimeoutException {
    throw UpdateNetworkException('timeout: $url');
  } on SocketException catch (e) {
    throw UpdateNetworkException('$e');
  } on HttpException catch (e) {
    throw UpdateNetworkException('$e');
  } on HandshakeException catch (e) {
    throw UpdateNetworkException('$e');
  }
  if (response.statusCode != HttpStatus.ok) {
    await response.drain<void>().catchError((_) {});
    throw UpdateNetworkException('HTTP ${response.statusCode}: $url');
  }
  return response;
}

class _DigestSink implements Sink<crypto.Digest> {
  late crypto.Digest value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}
