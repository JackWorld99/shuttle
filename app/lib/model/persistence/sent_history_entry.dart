import 'package:dart_mappable/dart_mappable.dart';
import 'package:localsend_isolates/model/file_type.dart';

part 'sent_history_entry.mapper.dart';

/// Shuttle: the record of one send (one send session). LocalSend only keeps a history of received items, not sent ones
/// (upstream issue #1269), so this part is our own.
///
/// One entry = one batch: recipient, files (or a piece of text), and result.
/// Files are not copied; only the name, type, size and original location (for thumbnails) are stored.
@MappableClass()
class SentHistoryEntry with SentHistoryEntryMappable {
  /// The local send session ID
  final String id;

  final String targetAlias;

  /// The recipient's certificate fingerprint; tells whether it is one of "my devices" and which badge to stamp
  final String targetFingerprint;

  /// UTC
  final DateTime timestamp;

  final List<SentHistoryFile> files;

  /// The original text when a piece of text / a link was sent ([files] is empty then)
  final String? message;

  final SentHistoryResult result;

  /// The raw, untranslated error message for [SentHistoryResult.error]
  final String? errorMessage;

  const SentHistoryEntry({
    required this.id,
    required this.targetAlias,
    required this.targetFingerprint,
    required this.timestamp,
    required this.files,
    required this.message,
    required this.result,
    required this.errorMessage,
  });

  bool get isMessage => message != null;

  bool get failed => result != SentHistoryResult.delivered;

  static const fromJson = SentHistoryEntryMapper.fromJson;
}

@MappableClass()
class SentHistoryFile with SentHistoryFileMappable {
  final String fileName;
  final FileType fileType;
  final int size;

  /// Original file path (on Android, the real path of the gallery original, or a content:// URI)
  final String? path;

  /// Gallery asset ID of a photo / video picked from the gallery, used to fetch the system thumbnail
  final String? assetId;

  /// Whether this file was delivered
  final bool delivered;

  const SentHistoryFile({
    required this.fileName,
    required this.fileType,
    required this.size,
    required this.path,
    required this.assetId,
    required this.delivered,
  });

  static const fromJson = SentHistoryFileMapper.fromJson;
}

@MappableEnum(defaultValue: SentHistoryResult.error)
enum SentHistoryResult {
  /// Everything delivered
  delivered,

  /// Only part delivered
  partial,
  declined,
  canceledByReceiver,
  canceledBySender,
  recipientBusy,
  tooManyAttempts,
  error,
}
