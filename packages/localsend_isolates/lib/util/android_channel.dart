import 'dart:async';

import 'package:flutter/services.dart';
import 'package:localsend_isolates/util/content_uri_helper.dart';
import 'package:logging/logging.dart';

const _methodChannel = MethodChannel('org.localsend.localsend_app/localsend');
final _logger = Logger('AndroidSaf');

/// Scans a saved file at an absolute filesystem [path]
Future<void> scanFileAndroid({required String path}) async {
  try {
    final scanned = await _methodChannel
        .invokeMethod<bool>('scanFile', {
          'path': path,
        })
        .timeout(const Duration(seconds: 30));
    if (scanned != true) {
      _logger.warning('Android media scan returned no URI for the saved file: $path');
    }
  } on TimeoutException {
    _logger.warning('Android media scan timed out after 30 seconds for the saved file: $path');
  } catch (e, st) {
    _logger.warning('Android media scan failed for the saved file: $path', e, st);
  }
}

/// Opens [uri] for reading and returns an owned Linux file descriptor.
///
/// The descriptor stays open after this call and must be closed by the native
/// consumer it is passed to.
Future<int> getFileDescriptorAndroid({required String uri}) async {
  final fileDescriptor = await _methodChannel.invokeMethod<int>('getFileDescriptor', {
    'uri': uri,
  });
  if (fileDescriptor == null) {
    throw StateError('Android returned no file descriptor for $uri');
  }
  return fileDescriptor;
}

Future<void> createDirectory({
  required String documentUri,
  required String directoryName,
}) async {
  _logger.info('Creating directory "$directoryName" in $documentUri');
  await _methodChannel.invokeMethod('createDirectory', {
    'documentUri': documentUri,
    'directoryName': directoryName,
  });
}

Future<void> createMissingDirectoriesAndroid({
  required String parentUri,
  required String fileName,
  required Set<String> createdDirectories,
}) async {
  final parts = fileName.split('/');
  for (int i = 0; i < parts.length - 1; i++) {
    final subDirPath = parts.sublist(0, i + 1).join('/');
    if (createdDirectories.contains(subDirPath)) {
      continue;
    }

    await createDirectory(
      documentUri: ContentUriHelper.convertTreeUriToDocumentUri(
        treeUri: parentUri,
        suffix: i == 0 ? null : parts.sublist(0, i).join('/'),
      ),
      directoryName: parts[i],
    );
    createdDirectories.add(subDirPath);
  }
}

class CreatedFileAndroid {
  /// The URI of the created document. Android may rename the file on collisions.
  final String uri;

  /// An owned writable Linux file descriptor. It stays open after this call and
  /// must be closed by the native consumer it is passed to.
  final int fileDescriptor;

  CreatedFileAndroid({required this.uri, required this.fileDescriptor});
}

/// Creates a new file inside a SAF directory (a tree or document URI)
/// and opens it for writing.
Future<CreatedFileAndroid> createFileAndroid({
  required String parentUri,
  required String fileName,
}) async {
  final result = await _methodChannel.invokeMethod<Map>('createFile', {
    'parentUri': parentUri,
    'fileName': fileName,
  });
  if (result == null) {
    throw StateError('Android could not create $fileName in $parentUri');
  }
  return CreatedFileAndroid(
    uri: result['uri'] as String,
    fileDescriptor: result['fd'] as int,
  );
}

/// Creates a pending image ([isImage]) or video entry in the gallery
/// (Android 10+) and opens it for writing.
///
/// The entry stays hidden from the gallery and other apps until
/// [finishMediaStoreFileAndroid] publishes it; [deleteMediaStoreFileAndroid]
/// removes it after a failed transfer. Images go to Pictures/, videos to Movies/.
/// The returned name may carry a number when [fileName] is taken.
///
/// Throws a [PlatformException] with the code `UNSUPPORTED_FORMAT` when the
/// gallery would not take the file (its extension is not one of an image or
/// video).
Future<CreatedFileAndroid> createMediaStoreFileAndroid({
  required String fileName,
  required bool isImage,
}) async {
  final result = await _methodChannel.invokeMethod<Map>('createMediaStoreFile', {
    'fileName': fileName,
    'isImage': isImage,
  });
  if (result == null) {
    throw StateError('Android could not create a gallery entry for $fileName');
  }
  return CreatedFileAndroid(
    uri: result['uri'] as String,
    fileDescriptor: result['fd'] as int,
  );
}

/// Publishes a completely written gallery entry created by
/// [createMediaStoreFileAndroid], so it shows up in the gallery.
Future<void> finishMediaStoreFileAndroid({required String uri}) async {
  await _methodChannel.invokeMethod<void>('finishMediaStoreFile', {
    'uri': uri,
  });
}

/// Deletes a gallery entry created by [createMediaStoreFileAndroid],
/// e.g. because the transfer failed or was canceled.
Future<void> deleteMediaStoreFileAndroid({required String uri}) async {
  await _methodChannel.invokeMethod<bool>('deleteMediaStoreFile', {
    'uri': uri,
  });
}

/// Deletes the gallery entries of [createMediaStoreFileAndroid] that were
/// created before [createdBefore] and never published: files that were still
/// being received when the app was closed. Returns how many were deleted.
Future<int> deletePendingMediaStoreFilesAndroid({required DateTime createdBefore}) async {
  final deleted = await _methodChannel.invokeMethod<int>('deletePendingMediaStoreFiles', {
    'createdBefore': createdBefore.millisecondsSinceEpoch ~/ 1000,
  });
  return deleted ?? 0;
}

/// Opens an existing document created by [createFileAndroid] for writing and
/// discards its current content.
///
/// The descriptor stays open after this call and must be closed by the native
/// consumer it is passed to.
Future<int> openFileForWritingAndroid({required String uri}) async {
  final fileDescriptor = await _methodChannel.invokeMethod<int>('openFileForWriting', {
    'uri': uri,
  });
  if (fileDescriptor == null) {
    throw StateError('Android returned no file descriptor for $uri');
  }
  return fileDescriptor;
}
