// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'sent_history_entry.dart';

class SentHistoryResultMapper extends EnumMapper<SentHistoryResult> {
  SentHistoryResultMapper._();

  static SentHistoryResultMapper? _instance;
  static SentHistoryResultMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = SentHistoryResultMapper._());
    }
    return _instance!;
  }

  static SentHistoryResult fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  SentHistoryResult decode(dynamic value) {
    switch (value) {
      case r'delivered':
        return SentHistoryResult.delivered;
      case r'partial':
        return SentHistoryResult.partial;
      case r'declined':
        return SentHistoryResult.declined;
      case r'canceledByReceiver':
        return SentHistoryResult.canceledByReceiver;
      case r'canceledBySender':
        return SentHistoryResult.canceledBySender;
      case r'recipientBusy':
        return SentHistoryResult.recipientBusy;
      case r'tooManyAttempts':
        return SentHistoryResult.tooManyAttempts;
      case r'error':
        return SentHistoryResult.error;
      case r'expired':
        return SentHistoryResult.expired;
      case r'missing':
        return SentHistoryResult.missing;
      default:
        return SentHistoryResult.values[7];
    }
  }

  @override
  dynamic encode(SentHistoryResult self) {
    switch (self) {
      case SentHistoryResult.delivered:
        return r'delivered';
      case SentHistoryResult.partial:
        return r'partial';
      case SentHistoryResult.declined:
        return r'declined';
      case SentHistoryResult.canceledByReceiver:
        return r'canceledByReceiver';
      case SentHistoryResult.canceledBySender:
        return r'canceledBySender';
      case SentHistoryResult.recipientBusy:
        return r'recipientBusy';
      case SentHistoryResult.tooManyAttempts:
        return r'tooManyAttempts';
      case SentHistoryResult.error:
        return r'error';
      case SentHistoryResult.expired:
        return r'expired';
      case SentHistoryResult.missing:
        return r'missing';
    }
  }
}

extension SentHistoryResultMapperExtension on SentHistoryResult {
  String toValue() {
    SentHistoryResultMapper.ensureInitialized();
    return MapperContainer.globals.toValue<SentHistoryResult>(this) as String;
  }
}

class SentHistoryEntryMapper extends ClassMapperBase<SentHistoryEntry> {
  SentHistoryEntryMapper._();

  static SentHistoryEntryMapper? _instance;
  static SentHistoryEntryMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = SentHistoryEntryMapper._());
      SentHistoryFileMapper.ensureInitialized();
      SentHistoryResultMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'SentHistoryEntry';

  static String _$id(SentHistoryEntry v) => v.id;
  static const Field<SentHistoryEntry, String> _f$id = Field('id', _$id);
  static String _$targetAlias(SentHistoryEntry v) => v.targetAlias;
  static const Field<SentHistoryEntry, String> _f$targetAlias = Field(
    'targetAlias',
    _$targetAlias,
  );
  static String _$targetFingerprint(SentHistoryEntry v) => v.targetFingerprint;
  static const Field<SentHistoryEntry, String> _f$targetFingerprint = Field(
    'targetFingerprint',
    _$targetFingerprint,
  );
  static DateTime _$timestamp(SentHistoryEntry v) => v.timestamp;
  static const Field<SentHistoryEntry, DateTime> _f$timestamp = Field(
    'timestamp',
    _$timestamp,
  );
  static List<SentHistoryFile> _$files(SentHistoryEntry v) => v.files;
  static const Field<SentHistoryEntry, List<SentHistoryFile>> _f$files = Field(
    'files',
    _$files,
  );
  static String? _$message(SentHistoryEntry v) => v.message;
  static const Field<SentHistoryEntry, String> _f$message = Field(
    'message',
    _$message,
  );
  static SentHistoryResult _$result(SentHistoryEntry v) => v.result;
  static const Field<SentHistoryEntry, SentHistoryResult> _f$result = Field(
    'result',
    _$result,
  );
  static String? _$errorMessage(SentHistoryEntry v) => v.errorMessage;
  static const Field<SentHistoryEntry, String> _f$errorMessage = Field(
    'errorMessage',
    _$errorMessage,
  );

  @override
  final MappableFields<SentHistoryEntry> fields = const {
    #id: _f$id,
    #targetAlias: _f$targetAlias,
    #targetFingerprint: _f$targetFingerprint,
    #timestamp: _f$timestamp,
    #files: _f$files,
    #message: _f$message,
    #result: _f$result,
    #errorMessage: _f$errorMessage,
  };

  static SentHistoryEntry _instantiate(DecodingData data) {
    return SentHistoryEntry(
      id: data.dec(_f$id),
      targetAlias: data.dec(_f$targetAlias),
      targetFingerprint: data.dec(_f$targetFingerprint),
      timestamp: data.dec(_f$timestamp),
      files: data.dec(_f$files),
      message: data.dec(_f$message),
      result: data.dec(_f$result),
      errorMessage: data.dec(_f$errorMessage),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static SentHistoryEntry fromJson(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<SentHistoryEntry>(map);
  }

  static SentHistoryEntry deserialize(String json) {
    return ensureInitialized().decodeJson<SentHistoryEntry>(json);
  }
}

mixin SentHistoryEntryMappable {
  String serialize() {
    return SentHistoryEntryMapper.ensureInitialized()
        .encodeJson<SentHistoryEntry>(this as SentHistoryEntry);
  }

  Map<String, dynamic> toJson() {
    return SentHistoryEntryMapper.ensureInitialized()
        .encodeMap<SentHistoryEntry>(this as SentHistoryEntry);
  }

  SentHistoryEntryCopyWith<SentHistoryEntry, SentHistoryEntry, SentHistoryEntry>
  get copyWith =>
      _SentHistoryEntryCopyWithImpl<SentHistoryEntry, SentHistoryEntry>(
        this as SentHistoryEntry,
        $identity,
        $identity,
      );
  @override
  String toString() {
    return SentHistoryEntryMapper.ensureInitialized().stringifyValue(
      this as SentHistoryEntry,
    );
  }

  @override
  bool operator ==(Object other) {
    return SentHistoryEntryMapper.ensureInitialized().equalsValue(
      this as SentHistoryEntry,
      other,
    );
  }

  @override
  int get hashCode {
    return SentHistoryEntryMapper.ensureInitialized().hashValue(
      this as SentHistoryEntry,
    );
  }
}

extension SentHistoryEntryValueCopy<$R, $Out>
    on ObjectCopyWith<$R, SentHistoryEntry, $Out> {
  SentHistoryEntryCopyWith<$R, SentHistoryEntry, $Out>
  get $asSentHistoryEntry =>
      $base.as((v, t, t2) => _SentHistoryEntryCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class SentHistoryEntryCopyWith<$R, $In extends SentHistoryEntry, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  ListCopyWith<
    $R,
    SentHistoryFile,
    SentHistoryFileCopyWith<$R, SentHistoryFile, SentHistoryFile>
  >
  get files;
  $R call({
    String? id,
    String? targetAlias,
    String? targetFingerprint,
    DateTime? timestamp,
    List<SentHistoryFile>? files,
    String? message,
    SentHistoryResult? result,
    String? errorMessage,
  });
  SentHistoryEntryCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _SentHistoryEntryCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, SentHistoryEntry, $Out>
    implements SentHistoryEntryCopyWith<$R, SentHistoryEntry, $Out> {
  _SentHistoryEntryCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<SentHistoryEntry> $mapper =
      SentHistoryEntryMapper.ensureInitialized();
  @override
  ListCopyWith<
    $R,
    SentHistoryFile,
    SentHistoryFileCopyWith<$R, SentHistoryFile, SentHistoryFile>
  >
  get files => ListCopyWith(
    $value.files,
    (v, t) => v.copyWith.$chain(t),
    (v) => call(files: v),
  );
  @override
  $R call({
    String? id,
    String? targetAlias,
    String? targetFingerprint,
    DateTime? timestamp,
    List<SentHistoryFile>? files,
    Object? message = $none,
    SentHistoryResult? result,
    Object? errorMessage = $none,
  }) => $apply(
    FieldCopyWithData({
      if (id != null) #id: id,
      if (targetAlias != null) #targetAlias: targetAlias,
      if (targetFingerprint != null) #targetFingerprint: targetFingerprint,
      if (timestamp != null) #timestamp: timestamp,
      if (files != null) #files: files,
      if (message != $none) #message: message,
      if (result != null) #result: result,
      if (errorMessage != $none) #errorMessage: errorMessage,
    }),
  );
  @override
  SentHistoryEntry $make(CopyWithData data) => SentHistoryEntry(
    id: data.get(#id, or: $value.id),
    targetAlias: data.get(#targetAlias, or: $value.targetAlias),
    targetFingerprint: data.get(
      #targetFingerprint,
      or: $value.targetFingerprint,
    ),
    timestamp: data.get(#timestamp, or: $value.timestamp),
    files: data.get(#files, or: $value.files),
    message: data.get(#message, or: $value.message),
    result: data.get(#result, or: $value.result),
    errorMessage: data.get(#errorMessage, or: $value.errorMessage),
  );

  @override
  SentHistoryEntryCopyWith<$R2, SentHistoryEntry, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) => _SentHistoryEntryCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class SentHistoryFileMapper extends ClassMapperBase<SentHistoryFile> {
  SentHistoryFileMapper._();

  static SentHistoryFileMapper? _instance;
  static SentHistoryFileMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = SentHistoryFileMapper._());
      FileTypeMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'SentHistoryFile';

  static String _$fileName(SentHistoryFile v) => v.fileName;
  static const Field<SentHistoryFile, String> _f$fileName = Field(
    'fileName',
    _$fileName,
  );
  static FileType _$fileType(SentHistoryFile v) => v.fileType;
  static const Field<SentHistoryFile, FileType> _f$fileType = Field(
    'fileType',
    _$fileType,
  );
  static int _$size(SentHistoryFile v) => v.size;
  static const Field<SentHistoryFile, int> _f$size = Field('size', _$size);
  static String? _$path(SentHistoryFile v) => v.path;
  static const Field<SentHistoryFile, String> _f$path = Field('path', _$path);
  static String? _$assetId(SentHistoryFile v) => v.assetId;
  static const Field<SentHistoryFile, String> _f$assetId = Field(
    'assetId',
    _$assetId,
  );
  static bool _$delivered(SentHistoryFile v) => v.delivered;
  static const Field<SentHistoryFile, bool> _f$delivered = Field(
    'delivered',
    _$delivered,
  );

  @override
  final MappableFields<SentHistoryFile> fields = const {
    #fileName: _f$fileName,
    #fileType: _f$fileType,
    #size: _f$size,
    #path: _f$path,
    #assetId: _f$assetId,
    #delivered: _f$delivered,
  };

  static SentHistoryFile _instantiate(DecodingData data) {
    return SentHistoryFile(
      fileName: data.dec(_f$fileName),
      fileType: data.dec(_f$fileType),
      size: data.dec(_f$size),
      path: data.dec(_f$path),
      assetId: data.dec(_f$assetId),
      delivered: data.dec(_f$delivered),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static SentHistoryFile fromJson(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<SentHistoryFile>(map);
  }

  static SentHistoryFile deserialize(String json) {
    return ensureInitialized().decodeJson<SentHistoryFile>(json);
  }
}

mixin SentHistoryFileMappable {
  String serialize() {
    return SentHistoryFileMapper.ensureInitialized()
        .encodeJson<SentHistoryFile>(this as SentHistoryFile);
  }

  Map<String, dynamic> toJson() {
    return SentHistoryFileMapper.ensureInitialized().encodeMap<SentHistoryFile>(
      this as SentHistoryFile,
    );
  }

  SentHistoryFileCopyWith<SentHistoryFile, SentHistoryFile, SentHistoryFile>
  get copyWith =>
      _SentHistoryFileCopyWithImpl<SentHistoryFile, SentHistoryFile>(
        this as SentHistoryFile,
        $identity,
        $identity,
      );
  @override
  String toString() {
    return SentHistoryFileMapper.ensureInitialized().stringifyValue(
      this as SentHistoryFile,
    );
  }

  @override
  bool operator ==(Object other) {
    return SentHistoryFileMapper.ensureInitialized().equalsValue(
      this as SentHistoryFile,
      other,
    );
  }

  @override
  int get hashCode {
    return SentHistoryFileMapper.ensureInitialized().hashValue(
      this as SentHistoryFile,
    );
  }
}

extension SentHistoryFileValueCopy<$R, $Out>
    on ObjectCopyWith<$R, SentHistoryFile, $Out> {
  SentHistoryFileCopyWith<$R, SentHistoryFile, $Out> get $asSentHistoryFile =>
      $base.as((v, t, t2) => _SentHistoryFileCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class SentHistoryFileCopyWith<$R, $In extends SentHistoryFile, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({
    String? fileName,
    FileType? fileType,
    int? size,
    String? path,
    String? assetId,
    bool? delivered,
  });
  SentHistoryFileCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _SentHistoryFileCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, SentHistoryFile, $Out>
    implements SentHistoryFileCopyWith<$R, SentHistoryFile, $Out> {
  _SentHistoryFileCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<SentHistoryFile> $mapper =
      SentHistoryFileMapper.ensureInitialized();
  @override
  $R call({
    String? fileName,
    FileType? fileType,
    int? size,
    Object? path = $none,
    Object? assetId = $none,
    bool? delivered,
  }) => $apply(
    FieldCopyWithData({
      if (fileName != null) #fileName: fileName,
      if (fileType != null) #fileType: fileType,
      if (size != null) #size: size,
      if (path != $none) #path: path,
      if (assetId != $none) #assetId: assetId,
      if (delivered != null) #delivered: delivered,
    }),
  );
  @override
  SentHistoryFile $make(CopyWithData data) => SentHistoryFile(
    fileName: data.get(#fileName, or: $value.fileName),
    fileType: data.get(#fileType, or: $value.fileType),
    size: data.get(#size, or: $value.size),
    path: data.get(#path, or: $value.path),
    assetId: data.get(#assetId, or: $value.assetId),
    delivered: data.get(#delivered, or: $value.delivered),
  );

  @override
  SentHistoryFileCopyWith<$R2, SentHistoryFile, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) => _SentHistoryFileCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

