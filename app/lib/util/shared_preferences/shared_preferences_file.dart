import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

const _beautyEncoder = JsonEncoder.withIndent('  ');
const _encoder = JsonEncoder();

// Shuttle: only records logged under 'Lifecycle' go into the diagnostics log (shareme_diagnostics.dart). Log only file names and
// error types, never content or full paths (the settings contain the device name and the transfer history).
final _logger = Logger('Lifecycle');

/// Shuttle: how the settings file was loaded on this launch.
enum SettingsLoadOutcome {
  /// Loaded normally.
  ok,

  /// No settings file (or an empty one) and no usable backup: first launch.
  fresh,

  /// The settings file was damaged, empty, missing or unreadable and was restored from a backup. The device identity is kept; at
  /// most the last change is lost.
  restored,

  /// The settings file is damaged and no backup is usable: a copy of the damaged file is kept and we start over (new device
  /// identity, devices must be paired again).
  unrecoverable,
}

/// Custom implementation of SharedPreferencesStorePlatform
/// that uses a custom file.
///
/// Shuttle: upstream overwrites settings.json in place and treats an unparsable file as empty. When a power cut, BSOD or full disk
/// corrupts the file, the next launch looks like the first one and regenerates the certificate: the PC gets a new identity and
/// "My devices", pairings and history are all lost. Now:
/// - Write: copy the current settings.json to settings.json.bak (previous version), write the new content to settings.json.tmp and
///   flush it to disk, then swap it in as settings.json in one step (on Windows, Dart replaces the existing file with MoveFileExW;
///   verified). If something fails midway, settings.json is still the complete old version. While another program (antivirus, a
///   second Shuttle starting up) has settings.json open, Windows refuses the replace ("Access denied"), so we retry after a short
///   wait; only if that keeps failing do we write into the original file directly (.bak is the safety net).
/// - Read: if settings.json is unparsable, empty, missing or keeps failing to read, use .tmp (a new version written last time but
///   not swapped in yet; only if complete), then .bak, and write the recovered data back to settings.json right away. Only if
///   neither works do we start over, and the damaged file is first copied to settings.json.corrupt-<time> and kept, not deleted.
///   All of this goes into the diagnostics log.
/// - If settings.json keeps failing to read (rather than being damaged) and there is no backup, fail the launch rather than treat it
///   as a first launch (which would change the identity).
class SharedPreferencesFile extends SharedPreferencesStorePlatform {
  final File _file;
  final bool beautify;

  SharedPreferencesFile({
    required String filePath,
    this.beautify = false,
  }) : _file = File(filePath);

  /// Shuttle: where the settings are stored (the send queue keeps its copies next to it, and resume its index of partial files)
  String get filePath => _file.path;

  /// The file is read on first use.
  Map<String, Object>? _loaded;

  Map<String, Object> get _cache => _loaded ??= _load();

  /// Whether the current settings.json is good (loaded, or just written by us). Only a good file is copied to the backup, so a
  /// damaged file never overwrites a good backup.
  bool _mainIsGood = false;

  SettingsLoadOutcome? _loadOutcome;
  String? _keptDamagedFile;
  bool _backupWarned = false;

  /// Delay before each retry when the replace fails (Chromium's ImportantFileWriter also retries 5 times). Zero in tests.
  @visibleForTesting
  List<Duration> replaceRetryDelays = const [
    Duration(milliseconds: 10),
    Duration(milliseconds: 20),
    Duration(milliseconds: 40),
    Duration(milliseconds: 80),
    Duration(milliseconds: 160),
  ];

  /// Delay before each retry when the file can't be read (locked by another program). Zero in tests.
  @visibleForTesting
  List<Duration> readRetryDelays = const [
    Duration(milliseconds: 50),
    Duration(milliseconds: 100),
    Duration(milliseconds: 200),
  ];

  /// Test-only: replaces the ".tmp → settings.json" swap step to simulate failures.
  @visibleForTesting
  void Function(File source, String target) rename = (source, target) => source.renameSync(target);

  bool exists() {
    return _file.existsSync();
  }

  String getPath() {
    return _file.path;
  }

  /// Shuttle: how the settings file was loaded on this launch.
  SettingsLoadOutcome get loadOutcome {
    _ensureLoaded();
    return _loadOutcome!;
  }

  /// Shuttle: the kept copy of the damaged file (a file name, in the same folder as settings.json), or null if there is none.
  String? get keptDamagedFile {
    _ensureLoaded();
    return _keptDamagedFile;
  }

  @override
  Future<bool> clear() {
    _cache.clear(); // upstream only wrote an empty file; the values stayed in memory and the next save wrote them all back
    _write(_cache);
    return Future.value(true);
  }

  @override
  Future<Map<String, Object>> getAll() async {
    return _cache;
  }

  @override
  Future<bool> remove(String key) {
    _cache.remove(key);
    _write(_cache);
    return Future.value(true);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    _cache[key] = value;
    _write(_cache);
    return Future.value(true);
  }

  void _ensureLoaded() {
    _loaded ??= _load();
  }

  String get _name => p.basename(_file.path);

  File get _backupFile => File('${_file.path}.bak');

  File get _tmpFile => File('${_file.path}.tmp');

  Map<String, Object> _load() {
    final main = _read(_file, retryDelays: readRetryDelays);
    if (main.data != null) {
      _mainIsGood = true;
      _loadOutcome = SettingsLoadOutcome.ok;
      return main.data!;
    }

    // settings.json is unusable: try the .tmp written last time but not swapped in yet, then the previous version in .bak
    for (final candidate in [_tmpFile, _backupFile]) {
      final data = _read(candidate).data;
      if (data == null) continue;
      final kept = main.damaged ? _keepDamagedCopy(_file) : null;
      _keptDamagedFile = kept;
      _logger.warning(
        'settings: $_name ${main.describe()}; restored from ${p.basename(candidate.path)}'
        '${kept == null ? '' : '; the damaged file is kept as $kept'}',
      );
      _loadOutcome = SettingsLoadOutcome.restored;
      try {
        _write(data);
      } catch (_) {
        // Still usable if writing back fails (the data is in memory); the next save tries again. _write has already logged it
      }
      return data;
    }

    if (main.unreadable != null) {
      // Not damaged but persistently unreadable (locked), and no backup: starting over would change the identity, so fail this launch
      _logger.severe('settings: $_name ${main.describe()} and there is no backup; not starting over');
      throw main.unreadable!;
    }

    if (!main.damaged) {
      _loadOutcome = SettingsLoadOutcome.fresh;
      return {};
    }

    _keptDamagedFile = _keepDamagedCopy(_file);
    if (_read(_backupFile).damaged) {
      // The backup is damaged too: keep a copy of it as well (the next save overwrites it with the new settings.json)
      _keepDamagedCopy(_backupFile);
    }
    _logger.severe(
      'settings: $_name ${main.describe()} and no usable backup; starting over with a new device identity'
      '${_keptDamagedFile == null ? ' (could not keep a copy of the damaged file)' : '; the damaged file is kept as $_keptDamagedFile'}',
    );
    _loadOutcome = SettingsLoadOutcome.unrecoverable;
    return {};
  }

  /// Reads a settings file. Missing or empty: data is null in both cases; unparsable: damaged; unreadable (stays locked): unreadable.
  _ReadResult _read(File file, {List<Duration> retryDelays = const []}) {
    for (var attempt = 0; ; attempt++) {
      try {
        if (!file.existsSync()) return const _ReadResult(missing: true);
        var text = file.readAsStringSync();
        if (text.startsWith('﻿')) text = text.substring(1); // edited in Notepad and saved as UTF-8 with BOM
        if (text.trim().isEmpty) return const _ReadResult();
        final decoded = json.decode(text);
        if (decoded is! Map) return const _ReadResult(problem: 'is not a JSON object');
        final data = <String, Object>{};
        decoded.forEach((key, value) {
          // null values make SharedPreferences.getInstance fail (upstream deletes the settings file there), so drop them
          if (key is String && value != null) data[key] = value as Object;
        });
        return _ReadResult(data: data);
      } on FileSystemException catch (e) {
        if (attempt >= retryDelays.length) return _ReadResult(unreadable: e);
        sleep(retryDelays[attempt]);
      } catch (e) {
        // FormatException: not UTF-8 / not JSON (common after a power cut: half the content, or a file full of zero bytes)
        return _ReadResult(problem: 'is damaged (${_describe(e)})');
      }
    }
  }

  /// Copies the damaged file (rather than renaming it: settings.json must stay in place, since the portable build relies on it to
  /// detect portable mode). Returns the copy's file name.
  String? _keepDamagedCopy(File file) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
    var target = '${file.path}.corrupt-$stamp';
    for (var n = 2; File(target).existsSync(); n++) {
      target = '${file.path}.corrupt-$stamp-$n';
    }
    try {
      file.copySync(target);
      return p.basename(target);
    } catch (e) {
      _logger.warning('settings: could not keep a copy of ${p.basename(file.path)} (${_describe(e)})');
      return null;
    }
  }

  void _write(Map<String, dynamic> data) {
    try {
      _writeText((beautify ? _beautyEncoder : _encoder).convert(data));
    } catch (e) {
      // e.g. disk full: writing .tmp fails and settings.json is still the complete original
      _logger.severe('settings: could not save $_name (${_describe(e)})');
      rethrow;
    }
  }

  void _writeText(String text) {
    _file.parent.createSync(recursive: true);

    // 1. Keep the current (good) file as the previous version
    if (_mainIsGood) {
      try {
        _file.copySync(_backupFile.path);
      } catch (e) {
        // Only one safety net is lost (e.g. .bak is open in another program); carry on writing
        if (!_backupWarned) {
          _backupWarned = true;
          _logger.warning('settings: could not update the backup $_name.bak (${_describe(e)})');
        }
      }
    }

    // 2. Write the complete new content to .tmp and flush it to disk
    _tmpFile.writeAsStringSync(text, flush: true);

    // 3. Swap it in in one step
    if (!_replaceMain()) {
      _file.writeAsStringSync(text, flush: true);
      try {
        _tmpFile.deleteSync();
      } catch (_) {}
    }
    _mainIsGood = true;
  }

  /// Replaces settings.json with .tmp. On Windows this is refused while another program has settings.json open, so retry after a wait.
  bool _replaceMain() {
    Object? lastError;
    for (var attempt = 0; attempt <= replaceRetryDelays.length; attempt++) {
      if (attempt > 0) sleep(replaceRetryDelays[attempt - 1]);
      try {
        rename(_tmpFile, _file.path);
        return true;
      } on FileSystemException catch (e) {
        lastError = e;
      }
    }
    _logger.warning(
      'settings: could not replace $_name after ${replaceRetryDelays.length + 1} tries (${_describe(lastError!)}); writing it in place',
    );
    return false;
  }
}

class _ReadResult {
  final Map<String, Object>? data;
  final bool missing;
  final String? problem;
  final FileSystemException? unreadable;

  const _ReadResult({this.data, this.missing = false, this.problem, this.unreadable});

  bool get damaged => problem != null;

  String describe() {
    if (unreadable != null) return 'could not be read (${_describe(unreadable!)})';
    if (problem != null) return problem!;
    return missing ? 'is missing' : 'is empty';
  }
}

/// Describes only the error type and OS error code, without paths or content (a FormatException's message includes part of the file).
String _describe(Object e) {
  if (e is FileSystemException) {
    final code = e.osError?.errorCode;
    return code == null ? '${e.runtimeType}' : '${e.runtimeType}, OS error $code';
  }
  if (e is FormatException) {
    return e.offset == null ? 'FormatException' : 'FormatException at offset ${e.offset}';
  }
  return '${e.runtimeType}';
}
