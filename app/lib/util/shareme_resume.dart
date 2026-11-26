// Shuttle: continuing interrupted transfers (resume), receiving side.
//
// When the connection is lost in the middle of a file, the server isolate keeps the part that arrived (a
// `.shuttle-part` file in the destination directory, or a pending gallery entry) instead of deleting it. This file
// remembers those parts in a small index, so the same sender (by its certificate) can continue the same file (by its
// SHA-256 and size) later, also after a restart of the app. Parts nobody continues are deleted after
// [partialFileMaxAge]. See docs/resume-transfer-design.md in the project folder.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/shared_preferences/shared_preferences_portable.dart';
import 'package:localsend_isolates/isolate.dart'
    show HttpServerFilePartialEvent, HttpServerFileUploadResultEvent, PartialFileLocation, discardPartialFile;
import 'package:localsend_isolates/model/dto/file_dto.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

final _logger = Logger('Resume');

/// How long the part of an interrupted file is kept for a continuation. The PC shuts down about twice a day, so a
/// transfer interrupted in the evening should still be continuable the next day.
const partialFileMaxAge = Duration(days: 3);

/// How often expired parts are looked for while the app runs.
const partialFileExpiryCheckInterval = Duration(hours: 6);

/// How long a continuation waits for the uploads of the session it replaces to report what they saved.
const _settleTimeout = Duration(seconds: 15);

/// The key of a partial file: the same sender certificate, the same content.
String partialFileKey({required String senderCert, required String sha256, required int size}) =>
    '${senderCert.toUpperCase()}|${sha256.toLowerCase()}|$size';

/// A part of a file received before the connection was lost.
@immutable
class PartialFileEntry {
  /// The SHA-256 fingerprint of the sender's client certificate (uppercase hex).
  final String senderCert;
  final String sha256;
  final int size;
  final String fileName;

  /// The partial file in the destination directory, or `null` for a gallery entry.
  final String? path;

  /// The content URI of a pending gallery entry (Android), or `null`.
  final String? uri;

  /// Bytes of the file that are safely saved: the offset the upload continues at.
  final int saved;

  final DateTime updatedAt;

  /// The receive session that wrote it last (to discard it when that session is canceled).
  final String sessionId;

  const PartialFileEntry({
    required this.senderCert,
    required this.sha256,
    required this.size,
    required this.fileName,
    required this.path,
    required this.uri,
    required this.saved,
    required this.updatedAt,
    required this.sessionId,
  });

  String get key => partialFileKey(senderCert: senderCert, sha256: sha256, size: size);

  PartialFileLocation get location => PartialFileLocation(path: path, uri: uri);

  PartialFileEntry copyWith({int? saved, DateTime? updatedAt, String? sessionId, PartialFileLocation? location}) {
    return PartialFileEntry(
      senderCert: senderCert,
      sha256: sha256,
      size: size,
      fileName: fileName,
      path: location != null ? location.path : path,
      uri: location != null ? location.uri : uri,
      saved: saved ?? this.saved,
      updatedAt: updatedAt ?? this.updatedAt,
      sessionId: sessionId ?? this.sessionId,
    );
  }

  Map<String, Object?> toJson() => {
    'senderCert': senderCert,
    'sha256': sha256,
    'size': size,
    'fileName': fileName,
    'path': path,
    'uri': uri,
    'saved': saved,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'sessionId': sessionId,
  };

  static PartialFileEntry fromJson(Map<String, Object?> json) => PartialFileEntry(
    senderCert: json['senderCert']! as String,
    sha256: json['sha256']! as String,
    size: json['size']! as int,
    fileName: json['fileName']! as String,
    path: json['path'] as String?,
    uri: json['uri'] as String?,
    saved: json['saved']! as int,
    updatedAt: DateTime.parse(json['updatedAt']! as String),
    sessionId: json['sessionId']! as String,
  );
}

/// The partial files, persisted as a JSON list. Writes are serialized and atomic (temporary file, then rename), so the
/// index is intact after a crash; a broken index only loses the parts (the files are deleted by their age or by
/// the gallery cleanup at startup).
class PartialFileIndex {
  final File file;
  final Map<String, PartialFileEntry> _entries = {};
  Future<void> _writes = Future.value();

  PartialFileIndex(this.file);

  Future<void> load() async {
    try {
      if (!await file.exists()) return;
      final list = jsonDecode(await file.readAsString()) as List<Object?>;
      for (final item in list) {
        final entry = PartialFileEntry.fromJson((item! as Map).cast<String, Object?>());
        _entries[entry.key] = entry;
      }
    } catch (e) {
      _logger.warning('Could not read the index of partial files, starting empty', e);
      _entries.clear();
    }
  }

  PartialFileEntry? operator [](String key) => _entries[key];

  Iterable<PartialFileEntry> get entries => _entries.values;

  void put(PartialFileEntry entry) {
    _entries[entry.key] = entry;
    _save();
  }

  void remove(String key) {
    if (_entries.remove(key) != null) _save();
  }

  /// Completes once every change so far is written.
  Future<void> flush() => _writes;

  void _save() {
    final json = jsonEncode([for (final e in _entries.values) e.toJson()]);
    _writes = _writes.then((_) async {
      try {
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(json, flush: true);
        await temporary.rename(file.path);
      } catch (e) {
        _logger.warning('Could not write the index of partial files', e);
      }
    });
  }
}

/// What a sender of a receive session offered, to find its files' parts.
class _SessionFiles {
  final String senderCert;
  final Map<String, FileDto> files;

  _SessionFiles(this.senderCert, this.files);
}

/// Where the accepted files of a request start (see [ResumeStore.plan]).
class ResumePlan {
  /// The accepted files that can be continued later, with the offset their upload starts at.
  final Map<String, int> offsets;

  /// Where the part of each file with an offset above 0 is.
  final Map<String, PartialFileLocation> partialFiles;

  const ResumePlan({required this.offsets, required this.partialFiles});
}

final resumeStoreProvider = Provider((ref) => ResumeStore());

/// Keeps track of the parts of interrupted files on the receiving side.
class ResumeStore {
  final Future<File> Function() _indexFile;
  final DateTime Function() _now;

  /// Checks whether a partial file in the destination directory is still there and how long it is.
  final Future<int?> Function(String path) _fileLength;

  /// Deletes a part.
  final Future<void> Function(PartialFileLocation location) _discard;

  ResumeStore({
    Future<File> Function()? indexFile,
    DateTime Function()? now,
    Future<int?> Function(String path)? fileLength,
    Future<void> Function(PartialFileLocation location)? discard,
  }) : _indexFile = indexFile ?? _defaultIndexFile,
       _now = now ?? DateTime.now,
       _fileLength = fileLength ?? _defaultFileLength,
       _discard = discard ?? discardPartialFile;

  late final Future<PartialFileIndex> _index = _open();

  /// The index once it is loaded (for the hints in the UI, which cannot wait).
  PartialFileIndex? _loaded;

  /// Senders and files of the recent requests that asked for the resume extension, by session ID.
  final Map<String, _SessionFiles> _sessions = {};

  /// Uploads per session whose result is not known yet.
  final Map<String, int> _inFlight = {};
  final Map<String, List<Completer<void>>> _settleWaiters = {};

  /// Next to the settings: a portable copy (settings.json next to Shuttle.exe) keeps its own index, as it keeps its
  /// own identity.
  static Future<File> _defaultIndexFile() async {
    const name = 'shuttle_partial_files.json';
    if (checkPlatform(const [TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS])) {
      final portable = SharedPreferencesPortable();
      if (portable.exists()) return File(p.join(p.dirname(portable.filePath), name));
    }
    final appData = checkPlatform(const [TargetPlatform.windows]) ? Platform.environment['APPDATA'] : null;
    if (appData != null) {
      // Where the installed build keeps its settings.json (see persistence_provider.dart)
      return File(p.join(appData, 'Shuttle', name));
    }
    return File(p.join((await getApplicationSupportDirectory()).path, name));
  }

  static Future<int?> _defaultFileLength(String path) async {
    final file = File(path);
    return await file.exists() ? await file.length() : null;
  }

  Future<PartialFileIndex> _open() async {
    final index = PartialFileIndex(await _indexFile());
    await index.load();
    _loaded = index;
    return index;
  }

  /// Remembers the sender and the files of a request that asked for the resume extension. Without a client
  /// certificate there is nothing to bind a part to, so nothing is remembered.
  void registerSession({required String sessionId, required String? senderCert, required Map<String, FileDto> files}) {
    if (senderCert == null) return;
    _sessions[sessionId] = _SessionFiles(senderCert, files);
    // The recent sessions are enough.
    while (_sessions.length > 32) {
      _sessions.remove(_sessions.keys.first);
    }
  }

  /// Whether the request of [sessionId] asked for the resume extension (with a certificate).
  bool isResumable(String sessionId) => _sessions.containsKey(sessionId);

  /// The bytes received earlier of a file of [sessionId] that are waiting for a continuation, for a hint before the
  /// request is accepted. `null` when there are none (or the index is not loaded yet).
  int? savedBefore({required String sessionId, required String fileId}) {
    final key = _keyOf(sessionId, fileId);
    if (key == null) return null;
    final saved = _loaded?[key]?.saved;
    return saved != null && saved > 0 ? saved : null;
  }

  /// Where the [acceptedIds] of the request [sessionId] start: the offset of each file with a checksum, taken from
  /// a part this sender left behind earlier (0 if there is none). `null` when the request did not ask for the resume
  /// extension.
  Future<ResumePlan?> plan({required String sessionId, required Iterable<String> acceptedIds}) async {
    final session = _sessions[sessionId];
    if (session == null) return null;
    final index = await _index;
    final offsets = <String, int>{};
    final partialFiles = <String, PartialFileLocation>{};
    for (final id in acceptedIds) {
      final file = session.files[id];
      final sha256 = file?.hash;
      if (file == null || sha256 == null) continue;
      final key = partialFileKey(senderCert: session.senderCert, sha256: sha256, size: file.size);
      final entry = index[key];
      var offset = 0;
      if (entry != null && entry.saved > 0) {
        final path = entry.path;
        // A part in the destination directory may have been deleted (or cut short) in the meantime.
        final available = path != null ? await _fileLength(path) : entry.saved;
        if (available == null || available == 0) {
          index.remove(key);
        } else {
          offset = min(entry.saved, available);
          partialFiles[id] = entry.location;
        }
      }
      offsets[id] = offset;
    }
    _logger.info('Resume plan for $sessionId: $offsets');
    return ResumePlan(offsets: offsets, partialFiles: partialFiles);
  }

  /// An upload of a file of [sessionId] started.
  void onUploadStarted(String sessionId) {
    _inFlight[sessionId] = (_inFlight[sessionId] ?? 0) + 1;
  }

  /// The part of a continuable upload that is saved so far.
  Future<void> onPartial(HttpServerFilePartialEvent event) async {
    final session = _sessions[event.sessionId];
    final file = session?.files[event.fileId];
    final sha256 = file?.hash;
    if (session == null || file == null || sha256 == null) return;
    final index = await _index;
    index.put(
      PartialFileEntry(
        senderCert: session.senderCert,
        sha256: sha256,
        size: file.size,
        fileName: file.fileName,
        path: event.location.path,
        uri: event.location.uri,
        saved: event.saved,
        updatedAt: _now(),
        sessionId: event.sessionId,
      ),
    );
  }

  /// An upload ended: a complete file or one whose part was discarded is no longer waiting for a continuation; the
  /// part of an interrupted one is.
  Future<void> onResult(HttpServerFileUploadResultEvent event) async {
    try {
      final key = _keyOf(event.sessionId, event.fileId);
      if (key == null) return;
      final index = await _index;
      final partialSaved = event.partialSaved;
      final entry = index[key];
      if (event.error != null && partialSaved != null && entry != null) {
        index.put(entry.copyWith(saved: partialSaved, updatedAt: _now(), sessionId: event.sessionId));
      } else if (entry != null && entry.sessionId == event.sessionId) {
        index.remove(key);
      }
    } finally {
      final left = (_inFlight[event.sessionId] ?? 1) - 1;
      if (left > 0) {
        _inFlight[event.sessionId] = left;
      } else {
        _inFlight.remove(event.sessionId);
        for (final waiter in _settleWaiters.remove(event.sessionId) ?? <Completer<void>>[]) {
          waiter.complete();
        }
      }
    }
  }

  /// Completes once every upload of [sessionId] reported its result (or after a while): a continuation of that
  /// session needs to know what its interrupted uploads saved.
  Future<void> settled(String sessionId, {Duration timeout = _settleTimeout}) async {
    if ((_inFlight[sessionId] ?? 0) > 0) {
      final waiter = Completer<void>();
      _settleWaiters.putIfAbsent(sessionId, () => []).add(waiter);
      try {
        await waiter.future.timeout(timeout);
      } on TimeoutException {
        _logger.warning('Uploads of $sessionId did not report their result in time');
      }
    }
    await (await _index).flush();
  }

  /// Deletes the parts of a canceled session: canceling is not an interruption.
  Future<void> discardSession(String sessionId) async {
    final index = await _index;
    for (final entry in index.entries.where((e) => e.sessionId == sessionId).toList()) {
      _logger.info('Discarding the part of ${entry.fileName}: the transfer was canceled');
      await _discard(entry.location);
      index.remove(entry.key);
    }
  }

  /// Deletes the parts nobody continued within [partialFileMaxAge]. Returns how many.
  Future<int> cleanExpired() async {
    final index = await _index;
    final limit = _now().subtract(partialFileMaxAge);
    final expired = index.entries.where((e) => e.updatedAt.isBefore(limit)).toList();
    for (final entry in expired) {
      _logger.info('Deleting the part of ${entry.fileName} (${entry.saved} of ${entry.size} bytes): not continued in time');
      await _discard(entry.location);
      index.remove(entry.key);
    }
    return expired.length;
  }

  /// The pending gallery entries that hold a part (they must survive the cleanup at startup).
  Future<List<String>> galleryUris() async {
    final index = await _index;
    return [for (final e in index.entries) ?e.uri];
  }

  @visibleForTesting
  Future<PartialFileIndex> get index => _index;

  String? _keyOf(String sessionId, String fileId) {
    final session = _sessions[sessionId];
    final file = session?.files[fileId];
    final sha256 = file?.hash;
    if (session == null || file == null || sha256 == null) return null;
    return partialFileKey(senderCert: session.senderCert, sha256: sha256, size: file.size);
  }
}

/// A receive session continued in a new one (the sender lost its connection and continued): pages that show the old
/// session keep showing the new one.
class ReceiveContinuation {
  static final Map<String, String> _next = {};

  /// When each session last received data, for the "connection seems lost" hint.
  static final Map<String, DateTime> _lastActivity = {};

  static void link({required String from, required String to}) {
    _next[from] = to;
    final activity = _lastActivity.remove(from);
    if (activity != null) _lastActivity[to] = activity;
  }

  /// Whether [sessionId] (shown by a page) is [current] or was continued by it.
  static bool continuesTo(String sessionId, String current) {
    var id = sessionId;
    for (var i = 0; i < 16; i++) {
      if (id == current) return true;
      final next = _next[id];
      if (next == null) return false;
      id = next;
    }
    return false;
  }

  static void touch(String sessionId) => _lastActivity[sessionId] = DateTime.now();

  /// How long [sessionId] has not received data.
  static Duration? idleFor(String sessionId) {
    final last = _lastActivity[sessionId];
    return last == null ? null : DateTime.now().difference(last);
  }
}
