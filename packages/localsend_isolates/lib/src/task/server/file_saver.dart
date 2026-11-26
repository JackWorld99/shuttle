import 'dart:io';

import 'package:gal/gal.dart';
import 'package:localsend_isolates/rust/api/filename.dart' as rust_filename;
import 'package:localsend_isolates/util/android_channel.dart' as android_channel;
import 'package:localsend_isolates/util/content_uri_helper.dart';
import 'package:localsend_isolates/util/file_path_helper.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _logger = Logger('FileSaver');

/// From this Android version (10, API 29) on, gallery files are written
/// straight into a gallery entry instead of a cache file.
const _androidGalleryInPlaceSdk = 29;

/// Shuttle: the suffix of a file that is still being received into the
/// destination directory. It gets its real name only once it is complete
/// (and its checksum matched), so a half-received file never looks like a
/// finished one. Like `.crdownload` / `.part` of web browsers.
const partialFileSuffix = '.shuttle-part';

/// How often renaming a completed file to its real name is tried: right after
/// writing, a virus scanner may still hold the file open (Windows).
const _renameAttempts = 5;

/// How a [FileSaveTarget] gets to its final place once it has been written.
enum FileSaveKind {
  /// Written to the destination directory (a path or an Android SAF document).
  destination,

  /// Written to the cache directory and moved into the gallery afterwards
  /// (iOS, Android 9 and older), see [saveCachedFileToGallery].
  galleryCache,

  /// Written straight into a pending gallery entry (Android 10+), hidden from
  /// the gallery until [completeFileSaveTarget] publishes it.
  gallery,
}

/// Where an incoming file should be written to.
/// The actual writing is done by the Rust server which receives either a
/// plain file [path] or a writable [fileDescriptor] (Android SAF or gallery).
class FileSaveTarget {
  /// The path to write the file to. `null` when [fileDescriptor] is used.
  final String? path;

  /// A writable file descriptor (Android SAF or gallery entry).
  /// `null` when [path] is used.
  final int? fileDescriptor;

  /// The path or content URI of the destination, used for the history
  /// and to locate the file after it has been written.
  final String displayPath;

  final FileSaveKind kind;

  /// Shuttle: the file is written to [path] under a temporary name ending in
  /// [partialFileSuffix] and renamed once it is complete.
  final bool partial;

  FileSaveTarget({
    required this.path,
    required this.fileDescriptor,
    required this.displayPath,
    this.kind = FileSaveKind.destination,
    this.partial = false,
  });

  /// Shuttle: whether an interrupted upload into this target can be continued
  /// later: a partial file in the destination directory, or a pending gallery
  /// entry (both are hidden from the user's view of finished files). Folders
  /// picked through SAF and the gallery cache of older systems are not.
  bool get continuable => (kind == FileSaveKind.destination && path != null && partial) || kind == FileSaveKind.gallery;
}

/// Shuttle: where the part of a file received before an interrupted upload is
/// kept: a [path] in the destination directory, or the content [uri] of a
/// pending gallery entry (Android 10+).
class PartialFileLocation {
  final String? path;
  final String? uri;

  const PartialFileLocation({required this.path, required this.uri});

  /// The location of a [FileSaveTarget.continuable] target.
  factory PartialFileLocation.of(FileSaveTarget target) {
    return switch (target.kind) {
      FileSaveKind.gallery => PartialFileLocation(path: null, uri: target.displayPath),
      _ => PartialFileLocation(path: target.path, uri: null),
    };
  }
}

/// Prepares the destination for an incoming file with [fileName].
///
/// When [saveToGallery] is true, an image ([isImage]) or video goes to the
/// gallery: on Android 10+ it is written straight into a pending gallery entry,
/// elsewhere it is first written to the [cacheDirectory]. Either way, call
/// [completeFileSaveTarget] after the file has been written. When the gallery
/// does not take the file, it is saved to the [destinationDirectory] instead.
///
/// On Android, destinations that cannot be written directly (SAF content URIs
/// and SD cards) are created via the Storage Access Framework and a writable
/// file descriptor is returned instead of a path.
///
/// Shuttle: a file written to a path in the destination directory gets a
/// temporary name ending in [partialFileSuffix] until [completeFileSaveTarget]
/// gives it its real name.
Future<FileSaveTarget> prepareFileSaveTarget({
  required String destinationDirectory,
  required String cacheDirectory,
  required String fileName,
  required bool saveToGallery,
  required bool isImage,
  required Set<String> createdDirectories,
  int? androidSdkInt,
}) async {
  var toGallery = saveToGallery;
  if (toGallery && androidSdkInt != null && androidSdkInt >= _androidGalleryInPlaceSdk) {
    final galleryEntry = await _createGalleryEntry(fileName: fileName, isImage: isImage);
    if (galleryEntry != null) {
      return galleryEntry;
    }
    // The same place a file goes when the gallery rejects it after it has been received.
    toGallery = false;
  }

  final parentDirectory = toGallery ? cacheDirectory : destinationDirectory;

  final (destinationPath, documentUri, finalName) = await digestFilePathAndPrepareDirectory(
    parentDirectory: parentDirectory,
    fileName: fileName,
    createdDirectories: createdDirectories,
  );

  if (toGallery) {
    return FileSaveTarget(
      path: destinationPath,
      fileDescriptor: null,
      displayPath: destinationPath,
      kind: FileSaveKind.galleryCache,
    );
  }

  // Only the destination directory can need SAF; gallery files were handled above.
  if (androidSdkInt != null) {
    String? parentUri;
    if (documentUri != null || destinationPath.startsWith('content://')) {
      parentUri = documentUri ?? destinationPath;
    } else {
      final sdCardPath = getSdCardPath(destinationPath);
      if (sdCardPath != null) {
        final uriString = ContentUriHelper.encodeTreeUri(sdCardPath.path.parentPath());
        parentUri = 'content://com.android.externalstorage.documents/tree/${sdCardPath.sdCardId}:$uriString';
      }
    }

    if (parentUri != null) {
      _logger.info('Using SAF to save file to $parentUri as $finalName');
      final createdFile = await android_channel.createFileAndroid(
        parentUri: parentUri,
        fileName: finalName,
      );
      return FileSaveTarget(
        path: null,
        fileDescriptor: createdFile.fileDescriptor,
        displayPath: createdFile.uri,
      );
    }
  }

  // Shuttle: received under a temporary name, see [partialFileSuffix].
  // The real name is chosen again when the file is complete.
  final partialPath = await _freePartialPath(destinationPath);
  return FileSaveTarget(
    path: partialPath,
    fileDescriptor: null,
    displayPath: partialPath,
    partial: true,
  );
}

/// The first `<destinationPath>.shuttle-part` (numbered if taken) that is free.
Future<String> _freePartialPath(String destinationPath) async {
  var counter = 1;
  while (true) {
    final candidate = counter == 1 ? '$destinationPath$partialFileSuffix' : '$destinationPath ($counter)$partialFileSuffix';
    if (await FileSystemEntity.type(candidate, followLinks: false) == FileSystemEntityType.notFound) {
      return candidate;
    }
    counter++;
  }
}

/// Prepares [target] for another attempt at the same file, e.g. after the
/// previous attempt was rejected because of a checksum mismatch.
///
/// The destination is kept, so the file is overwritten instead of being
/// created a second time under a numbered name.
///
/// Shuttle: with [continuing], the upload continues at an offset, so a
/// descriptor is opened for reading and writing without truncating.
Future<FileSaveTarget> reopenFileSaveTarget(FileSaveTarget target, {bool continuing = false}) async {
  final path = target.path;
  if (path != null) {
    // The server opens (and truncates, unless continuing) the path itself.
    return target;
  }

  // The descriptor of the previous attempt was consumed by it, so the SAF
  // document (or gallery entry) has to be opened again.
  _logger.info('Reopening ${target.displayPath}');
  return FileSaveTarget(
    path: null,
    fileDescriptor: continuing
        ? await android_channel.openFileForContinuingAndroid(uri: target.displayPath)
        : await android_channel.openFileForWritingAndroid(uri: target.displayPath),
    displayPath: target.displayPath,
    kind: target.kind,
    partial: target.partial,
  );
}

/// Shuttle: the target of a file whose earlier, interrupted upload left the
/// partial file at [location]; the upload continues where it stopped.
Future<FileSaveTarget> reopenPartialFile(PartialFileLocation location) async {
  final path = location.path;
  if (path != null) {
    return FileSaveTarget(
      path: path,
      fileDescriptor: null,
      displayPath: path,
      partial: true,
    );
  }
  final uri = location.uri!;
  _logger.info('Continuing the gallery entry $uri');
  return FileSaveTarget(
    path: null,
    fileDescriptor: await android_channel.openFileForContinuingAndroid(uri: uri),
    displayPath: uri,
    kind: FileSaveKind.gallery,
  );
}

/// Creates a pending gallery entry for [fileName] (Android 10+).
/// Returns `null` when the gallery does not take the file.
Future<FileSaveTarget?> _createGalleryEntry({required String fileName, required bool isImage}) async {
  // Gallery saves are only offered for names without a directory, see the receive controller.
  final name = sanitizeRelativeName(fileName).last;
  try {
    final created = await android_channel.createMediaStoreFileAndroid(fileName: name, isImage: isImage);
    _logger.info('Writing $name straight into the gallery as ${created.uri}');
    return FileSaveTarget(
      path: null,
      fileDescriptor: created.fileDescriptor,
      displayPath: created.uri,
      kind: FileSaveKind.gallery,
    );
  } catch (e) {
    _logger.warning('Could not create a gallery entry for $name, saving it to the destination directory', e);
    return null;
  }
}

/// Finishes [target] after the file has been written to it completely:
/// publishes a gallery entry, moves a cache file into the gallery or lets
/// Android scan a file in the destination directory.
///
/// Returns (savedToGallery, filePath) like [saveCachedFileToGallery]:
/// filePath is `null` for a file in the gallery.
Future<(bool, String?)> completeFileSaveTarget({
  required FileSaveTarget target,
  required String destinationDirectory,
  required String fileName,
  required bool isImage,
  required Set<String> createdDirectories,
}) async {
  switch (target.kind) {
    case FileSaveKind.gallery:
      await android_channel.finishMediaStoreFileAndroid(uri: target.displayPath);
      return (true, null);
    case FileSaveKind.galleryCache:
      return saveCachedFileToGallery(
        cachedPath: target.displayPath,
        destinationDirectory: destinationDirectory,
        fileName: fileName,
        isImage: isImage,
        createdDirectories: createdDirectories,
      );
    case FileSaveKind.destination:
      var path = target.path;
      if (target.partial && path != null) {
        // Shuttle: the file is complete, now it gets its real name.
        path = await _renameToFinal(partialPath: path, fileName: fileName, createdDirectories: createdDirectories);
      }
      if (Platform.isAndroid && path != null) {
        // Scan before reporting success so Android can handle the saved file correctly
        // when it is moved to Trash, allowing another file with the same name.
        // https://github.com/localsend/localsend/issues/2007
        await android_channel.scanFileAndroid(path: path);
      }
      return (false, path ?? target.displayPath);
  }
}

/// Shuttle: renames the complete [partialPath] to the real name of [fileName]
/// in the same directory, numbered if that name is taken by now.
Future<String> _renameToFinal({
  required String partialPath,
  required String fileName,
  required Set<String> createdDirectories,
}) async {
  for (var attempt = 1; ; attempt++) {
    // The partial file stays where it is (it may be from an earlier session
    // when the destination directory was a different one).
    final (finalPath, _, _) = await digestFilePathAndPrepareDirectory(
      parentDirectory: p.dirname(partialPath),
      fileName: sanitizeRelativeName(fileName).last,
      createdDirectories: createdDirectories,
    );
    try {
      await File(partialPath).rename(finalPath);
      return finalPath;
    } on FileSystemException catch (e) {
      if (attempt >= _renameAttempts) {
        rethrow;
      }
      _logger.warning('Could not rename $partialPath to $finalPath (attempt $attempt), trying again', e);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}

/// Cleans up after an attempt to write [target] failed or was canceled.
///
/// A gallery entry is deleted: it holds only part of the file, and it is
/// hidden while pending, so it would only take up space. Another attempt at
/// the same file needs a new target from [prepareFileSaveTarget].
/// Shuttle: so is a partial file in the destination directory (it would
/// otherwise stay behind as a broken file).
/// Other targets (SAF documents) keep the incomplete file, which another
/// attempt overwrites.
Future<void> discardFileSaveTarget(FileSaveTarget target) async {
  if (target.kind == FileSaveKind.destination && target.partial && target.path != null) {
    await discardPartialFile(PartialFileLocation(path: target.path, uri: null));
    return;
  }
  if (target.kind != FileSaveKind.gallery) {
    return;
  }
  await discardPartialFile(PartialFileLocation(path: null, uri: target.displayPath));
}

/// Shuttle: deletes the partial file at [location]. Errors are only logged:
/// a gallery entry left pending is deleted on the next app start.
Future<void> discardPartialFile(PartialFileLocation location) async {
  final path = location.path;
  final uri = location.uri;
  try {
    if (path != null) {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } else if (uri != null) {
      await android_channel.deleteMediaStoreFileAndroid(uri: uri);
    }
  } catch (e) {
    _logger.warning('Could not delete the incomplete file ${path ?? uri}', e);
  }
}

/// Moves a file that has been written to the cache directory into the
/// OS gallery (Photos/Videos).
///
/// If the gallery rejects the file (unsupported format, missing permission,
/// not enough space, ...), the cached file is moved to [destinationDirectory]
/// as fallback. At this point the file is already fully received and the
/// sender was already told success, so failing the transfer would lose it.
///
/// Returns (savedToGallery, filePath):
/// - savedToGallery: true if saved to gallery, false if saved to directory
/// - filePath: absolute path to file (null when saved to gallery)
Future<(bool, String?)> saveCachedFileToGallery({
  required String cachedPath,
  required String destinationDirectory,
  required String fileName,
  required bool isImage,
  required Set<String> createdDirectories,
}) async {
  try {
    isImage ? await Gal.putImage(cachedPath) : await Gal.putVideo(cachedPath);
  } on GalException catch (e) {
    _logger.warning('Could not save to gallery (${e.type.name}), moving to destination directory', e);

    final (fallbackPath, _, _) = await digestFilePathAndPrepareDirectory(
      parentDirectory: destinationDirectory,
      fileName: fileName,
      createdDirectories: createdDirectories,
    );

    _logger.info('Moving file from $cachedPath to $fallbackPath');
    await File(cachedPath).rename(fallbackPath);
    return (false, fallbackPath);
  }

  try {
    await File(cachedPath).delete();
  } catch (e) {
    _logger.warning('Could not delete cached file after saving to gallery', e);
  }
  return (true, null);
}

/// Turns the peer-supplied [fileName] into a relative name that stays inside
/// the destination directory.
///
/// Protocol v2 lets a name carry directory components, for folder transfers.
/// The peer chooses them, so they get the same treatment as the base name:
/// `..` and absolute names are refused outright rather than rewritten, since a
/// name that tries to leave the destination is not a name to guess at, and
/// every remaining component is sanitized. Without that, only the base name
/// was checked and a directory could still be named `con`, end in a dot or
/// carry control characters.
///
/// Throws `'Path traversal detected'` when the name tries to leave the
/// destination.
List<String> sanitizeRelativeName(String fileName) {
  final parts = p.split(fileName);

  final components = <String>[];
  for (final part in parts) {
    // `p.split` keeps the root of an absolute name ('/', 'C:\\', ...) as the
    // first component, so this catches absolute names as well.
    if (part == '..' || p.rootPrefix(part).isNotEmpty) {
      throw 'Path traversal detected';
    }
    // A '.' component (and the empty ones `p.split` can produce) addresses the
    // directory it is in, so it simply drops out.
    if (part == '.' || part.isEmpty) {
      continue;
    }
    components.add(rust_filename.sanitizeFileName(name: part));
  }

  // Everything collapsed, e.g. the name was empty or just '.'.
  if (components.isEmpty) {
    components.add(rust_filename.sanitizeFileName(name: ''));
  }

  return components;
}

/// If the name is already occupied, appends a number to the file name.
Future<(String, String?, String)> digestFilePathAndPrepareDirectory({
  required String parentDirectory,
  required String fileName,
  required Set<String> createdDirectories,
}) async {
  final components = sanitizeRelativeName(fileName);
  fileName = components.join('/');

  if (parentDirectory.startsWith('content://')) {
    final String documentUri;
    if (fileName.contains('/')) {
      try {
        await android_channel.createMissingDirectoriesAndroid(parentUri: parentDirectory, fileName: fileName, createdDirectories: createdDirectories);
      } catch (e) {
        _logger.warning('Could not create missing directories', e);
      }
      documentUri = ContentUriHelper.convertTreeUriToDocumentUri(treeUri: parentDirectory, suffix: fileName.parentPath());
    } else {
      // root directory
      documentUri = ContentUriHelper.convertTreeUriToDocumentUri(treeUri: parentDirectory, suffix: null);
    }

    // destinationUri is for the history
    // documentUri is for SAF to save the file, it should point to the parent directory
    final destinationUri = ContentUriHelper.convertTreeUriToDocumentUri(treeUri: parentDirectory, suffix: fileName);
    return (destinationUri, documentUri, p.basename(fileName));
  }

  final actualFileName = components.last;
  final dir = p.joinAll([parentDirectory, ...components.take(components.length - 1)]);

  if (components.length > 1) {
    // Second gate: the components above cannot escape on their own, but the
    // resulting directory is what is about to be created.
    if (!p.isWithin(parentDirectory, dir)) {
      throw 'Path traversal detected';
    }
  }

  // The destination directory may not exist anymore, e.g. because it was deleted
  // or is on a drive that is no longer mounted. This also creates the
  // sub-directories of a folder transfer. Errors are propagated so that the
  // caller fails the upload instead of writing to a path that cannot be opened.
  Directory(dir).createSync(recursive: true);

  String destinationPath;
  int counter = 1;
  do {
    destinationPath = counter == 1 ? p.join(dir, actualFileName) : p.join(dir, actualFileName.withCount(counter));
    counter++;
  } while (await FileSystemEntity.type(destinationPath, followLinks: false) != FileSystemEntityType.notFound);
  return (destinationPath, null, p.basename(destinationPath));
}

final _sdCardPathRegex = RegExp(r'^/storage/([A-Fa-f0-9]{4}-[A-Fa-f0-9]{4})/(.*)$');

class SdCardPath {
  final String sdCardId;
  final String path;

  SdCardPath(this.sdCardId, this.path);
}

/// Checks if the [path] is on the SD card and returns the SD card path.
/// Returns `null` if the [path] is not on the SD card.
/// Only works on Android.
SdCardPath? getSdCardPath(String path) {
  final match = _sdCardPathRegex.firstMatch(path);
  if (match == null) {
    return null;
  }
  return SdCardPath(match.group(1)!, match.group(2)!);
}
