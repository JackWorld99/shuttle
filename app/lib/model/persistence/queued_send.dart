import 'package:collection/collection.dart';
import 'package:localsend_isolates/model/file_type.dart';

// Shuttle: the "send queue" (README roadmap). Content sent to one of "my devices" while it is offline or unreachable waits here and
// goes out by itself once that device is reachable again (see send_queue_provider.dart).
//
// Files are kept by their location only (like Syncthing: whatever is there when it is sent goes out, and a deleted file is
// skipped), so a queued 4 GB video takes no extra space. Only content without a lasting location gets a copy in the queue folder:
// text and clipboard images (they only exist in memory), and on the phone files shared in from other apps (the share plugin
// copies them into the app cache, which Shuttle empties on every start).
//
// Written by hand instead of with dart_mappable: the format is small and stays readable in settings.json.

/// One file (or piece of text) waiting to be sent
class QueuedFile {
  /// Stable ID inside its entry
  final String id;
  final String fileName;
  final FileType fileType;

  /// Size when it was queued (the size at send time is what goes out)
  final int size;

  /// Where it is read from when sent: the original path, an Android content:// URI, or a copy in the queue folder ([ownedCopy])
  final String? path;

  /// [path] is Shuttle's own copy in the queue folder: deleted once the entry is sent or canceled
  final bool ownedCopy;

  /// Gallery asset ID (thumbnails, as in the sent history)
  final String? assetId;

  /// A piece of text or a link (sent as a message, its text is in the copy at [path]); [preview] holds its beginning for the list
  final bool isMessage;
  final String? preview;

  /// RFC 3339, as picked
  final String? lastModified;
  final String? lastAccessed;

  const QueuedFile({
    required this.id,
    required this.fileName,
    required this.fileType,
    required this.size,
    required this.path,
    required this.ownedCopy,
    required this.assetId,
    required this.isMessage,
    required this.preview,
    required this.lastModified,
    required this.lastAccessed,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'fileName': fileName,
    'fileType': fileType.name,
    'size': size,
    if (path != null) 'path': path,
    if (ownedCopy) 'ownedCopy': true,
    if (assetId != null) 'assetId': assetId,
    if (isMessage) 'isMessage': true,
    if (preview != null) 'preview': preview,
    if (lastModified != null) 'lastModified': lastModified,
    if (lastAccessed != null) 'lastAccessed': lastAccessed,
  };

  factory QueuedFile.fromJson(Map<String, dynamic> json) => QueuedFile(
    id: json['id'] as String,
    fileName: json['fileName'] as String,
    fileType: FileType.values.firstWhereOrNull((t) => t.name == json['fileType']) ?? FileType.other,
    size: (json['size'] as num).toInt(),
    path: json['path'] as String?,
    ownedCopy: json['ownedCopy'] == true,
    assetId: json['assetId'] as String?,
    isMessage: json['isMessage'] == true,
    preview: json['preview'] as String?,
    lastModified: json['lastModified'] as String?,
    lastAccessed: json['lastAccessed'] as String?,
  );
}

/// One batch waiting for one device (sent as one transfer, like the batch the user picked)
class QueuedSend {
  final String id;

  /// The device it is for (its certificate fingerprint): only that device gets it, whatever address it turns up at
  final String targetFingerprint;

  /// Its name when queued (shown in the list and the history if the device has been renamed or removed since)
  final String targetAlias;

  /// When it was queued (UTC)
  final DateTime createdAt;

  final List<QueuedFile> files;

  const QueuedSend({
    required this.id,
    required this.targetFingerprint,
    required this.targetAlias,
    required this.createdAt,
    required this.files,
  });

  int get totalSize => files.fold(0, (sum, f) => sum + f.size);

  /// A single piece of text or a link
  bool get isMessage => files.length == 1 && files.first.isMessage;

  /// Bytes of Shuttle's own copies (counted against maxQueueCopyBytes)
  int get ownedBytes => files.where((f) => f.ownedCopy).fold(0, (sum, f) => sum + f.size);

  QueuedSend copyWith({List<QueuedFile>? files}) => QueuedSend(
    id: id,
    targetFingerprint: targetFingerprint,
    targetAlias: targetAlias,
    createdAt: createdAt,
    files: files ?? this.files,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'targetFingerprint': targetFingerprint,
    'targetAlias': targetAlias,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'files': files.map((f) => f.toJson()).toList(),
  };

  factory QueuedSend.fromJson(Map<String, dynamic> json) => QueuedSend(
    id: json['id'] as String,
    targetFingerprint: json['targetFingerprint'] as String,
    targetAlias: json['targetAlias'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
    files: (json['files'] as List).map((f) => QueuedFile.fromJson(f as Map<String, dynamic>)).toList(),
  );
}
