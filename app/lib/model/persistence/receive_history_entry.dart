import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter/widgets.dart';
import 'package:localsend_app/util/system_date_time_formatter.dart';
import 'package:localsend_isolates/model/file_type.dart';

part 'receive_history_entry.mapper.dart';

@MappableClass()
class ReceiveHistoryEntry with ReceiveHistoryEntryMappable {
  final String id;

  /// The name of the file.
  /// If [isMessage] is true, this is the message content.
  final String fileName;

  final FileType fileType;
  final String? path;
  final bool savedToGallery;

  @MappableField(hook: IsMessageHook())
  final bool isMessage;

  final int fileSize;
  final String senderAlias;
  final DateTime timestamp;

  /// Shuttle: the sender's certificate fingerprint (from the mTLS certificate in encrypted mode, so it can't be forged).
  /// Used to stamp the sender's badge on the film strip. Null for older entries, which lack this field.
  final String? senderFingerprint;

  /// Shuttle: whether this file passed SHA-256 verification (the sender attached a hash, the receiver has verification on,
  /// and they match). On a mismatch the Rust core fails the file, so it never gets an entry. null = unknown (older entries).
  final bool? checksumVerified;

  /// Shuttle: the receive this file belongs to (receive session ID); the history page groups a batch of files into one row by it.
  /// Null for older entries (grouped by guessing from sender + close timestamps).
  final String? batchId;

  const ReceiveHistoryEntry({
    required this.id,
    required this.fileName,
    required this.fileType,
    required this.path,
    required this.savedToGallery,
    required this.isMessage,
    required this.fileSize,
    required this.senderAlias,
    required this.timestamp,
    this.senderFingerprint,
    this.checksumVerified,
    this.batchId,
  });

  /// Format string using the system date and time format.
  /// Because the raw timestamp is saved in UTC, we need to transform it to local time zone first.
  String timestampString(BuildContext context) {
    return SystemDateTimeFormatter.dateTime(context, timestamp.toLocal());
  }

  static const fromJson = ReceiveHistoryEntryMapper.fromJson;
}

class IsMessageHook extends MappingHook {
  const IsMessageHook();

  @override
  Object? beforeDecode(Object? value) {
    return value == true;
  }
}
