// Shuttle: diagnostics log on desktop.
//
// Why: the desktop build only logs to the console, so a normal run leaves nothing behind. That made two things impossible to pin down:
// - occasional very slow auto-update downloads: which step was slow, and when;
// - Shuttle disappearing (e.g. after sleep) without a crash record: was it a clean exit, was it killed, or did it crash.
//
// How (Windows only):
// - A diagnostics-only log file, shuttle-diagnostics.log, with two categories: auto-update ("Update") and start / exit ("Lifecycle").
//   No transferred file names, device names or text content. Past 512 KB it rotates (the old file is kept as .1).
// - A session file, shuttle-session.json: this run's process ID, start time, "last alive" time (updated every 5 minutes), and the
//   exit reason, written on a clean exit. If the previous session has no exit reason at the next launch, it was killed or crashed,
//   and a line is logged. A long gap between two "alive" updates (PC asleep) is logged too, to compare with Windows' sleep records.
// - Location: the logs folder inside the program folder for the portable build (settings.json next to Shuttle.exe);
//   %LOCALAPPDATA%\Shuttle\logs for the installed build.
// Any failure in the diagnostics themselves never affects normal use.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:localsend_app/util/shared_preferences/shared_preferences_portable.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

/// Only these loggers are written to the file (they contain no file names, device names, etc.).
const diagnosticsLoggers = {'Update', 'Lifecycle'};

/// How often the "last alive" time is updated.
const diagnosticsAliveInterval = Duration(minutes: 5);

const _maxLogBytes = 512 * 1024;

final _logger = Logger('Lifecycle');

File? _logFile;
File? _sessionFile;
Map<String, dynamic>? _session;
Timer? _aliveTimer;
StreamSubscription<LogRecord>? _logSub;
StreamSubscription<LogRecord>? _earlySub;
final _early = <LogRecord>[];
const _maxEarlyRecords = 50;

/// Where the diagnostics files are stored.
Directory diagnosticsDirectory() {
  final appDir = File(Platform.resolvedExecutable).parent.path;
  if (SharedPreferencesPortable().exists()) return Directory(p.join(appDir, 'logs'));
  final local = Platform.environment['LOCALAPPDATA'];
  if (local == null || local.isEmpty) return Directory(p.join(appDir, 'logs'));
  return Directory(p.join(local, 'Shuttle', 'logs'));
}

/// Call at the very start (in preInit, after initLogger): the log file is only opened after the single-instance check
/// ([startDiagnostics]), so records from [diagnosticsLoggers] are buffered in memory until then (up to [_maxEarlyRecords]) and written
/// once it opens. Finding a damaged settings file and restoring it from a backup happens before that point (shared_preferences_file.dart).
void bufferEarlyDiagnostics() {
  if (!Platform.isWindows || _earlySub != null || _session != null) return;
  _earlySub = Logger.root.onRecord.where((r) => diagnosticsLoggers.contains(r.loggerName)).listen((r) {
    if (_early.length < _maxEarlyRecords) _early.add(r);
  });
}

/// Call once at startup, after the single-instance check: a process that hands over to an already running instance and exits must
/// not touch the session file.
Future<void> startDiagnostics({required String version}) async {
  if (!Platform.isWindows || _session != null) return;
  try {
    final dir = diagnosticsDirectory()..createSync(recursive: true);
    final log = File(p.join(dir.path, 'shuttle-diagnostics.log'));
    _rotateIfLarge(log);
    _logFile = log;
    // Switch to the file-writing listener without awaiting in between, so no record is missed
    final early = _earlySub;
    _earlySub = null;
    if (early != null) unawaited(early.cancel());
    for (final r in _early) {
      _append(_format(r), time: r.time);
    }
    _early.clear();
    _logSub = Logger.root.onRecord.where((r) => diagnosticsLoggers.contains(r.loggerName)).listen((r) {
      _append(_format(r));
    });

    final sessionFile = File(p.join(dir.path, 'shuttle-session.json'));
    _sessionFile = sessionFile;
    final note = describePreviousSession(readSessionFile(sessionFile));
    if (note != null) _logger.warning(note);

    final now = DateTime.now();
    _session = {'pid': pid, 'version': version, 'start': now.toIso8601String(), 'lastAlive': now.toIso8601String(), 'exit': null};
    _writeSession();
    _logger.info('start pid=$pid version=$version');
    _aliveTimer = Timer.periodic(diagnosticsAliveInterval, (_) => _tickAlive());
  } catch (_) {
    // Diagnostics problems must not affect normal use
  }
}

/// Call before a clean exit (writes synchronously; exit right after).
void markCleanExit(String reason) {
  final s = _session;
  if (s == null) return;
  try {
    s['exit'] = reason;
    s['lastAlive'] = DateTime.now().toIso8601String();
    _writeSession();
    _append('[Lifecycle] exit reason=$reason');
  } catch (_) {}
}

void _tickAlive() {
  final s = _session;
  if (s == null) return;
  final now = DateTime.now();
  final gapNote = describeAliveGap(DateTime.tryParse(s['lastAlive'] as String? ?? ''), now);
  if (gapNote != null) _logger.info(gapNote);
  s['lastAlive'] = now.toIso8601String();
  _writeSession();
}

/// Reads the previous session file; null if it is missing or unparsable.
Map<String, dynamic>? readSessionFile(File file) {
  try {
    if (!file.existsSync()) return null;
    final json = jsonDecode(file.readAsStringSync());
    return json is Map<String, dynamic> ? json : null;
  } catch (_) {
    return null;
  }
}

/// The line to log if the previous run did not exit cleanly; null after a clean exit or if there is no record.
String? describePreviousSession(Map<String, dynamic>? previous) {
  if (previous == null || previous['exit'] != null) return null;
  return 'previous run did not exit normally (ended by someone else, crashed, or the PC shut down): '
      'pid=${previous['pid']} version=${previous['version']} started=${previous['start']} last alive=${previous['lastAlive']}';
}

/// The line to log when two "alive" updates are much further apart than normal (PC asleep, process suspended).
String? describeAliveGap(DateTime? lastAlive, DateTime now, {Duration interval = diagnosticsAliveInterval}) {
  if (lastAlive == null) return null;
  final gap = now.difference(lastAlive);
  if (gap < interval * 2) return null;
  return 'woke up after a gap of ${gap.inMinutes} min (last alive ${lastAlive.toIso8601String()}): sleep or suspended';
}

void _writeSession() {
  final f = _sessionFile;
  final s = _session;
  if (f == null || s == null) return;
  try {
    f.writeAsStringSync(jsonEncode(s), flush: true);
  } catch (_) {}
}

String _format(LogRecord r) => '[${r.loggerName}] ${r.message}${r.error == null ? '' : ' (${r.error})'}';

/// [time]: buffered early records keep the time they were logged.
void _append(String line, {DateTime? time}) {
  final f = _logFile;
  if (f == null) return;
  try {
    f.writeAsStringSync('${(time ?? DateTime.now()).toIso8601String()} $line\n', mode: FileMode.append);
  } catch (_) {}
}

void _rotateIfLarge(File log) {
  try {
    if (log.existsSync() && log.lengthSync() > _maxLogBytes) {
      final old = File('${log.path}.1');
      if (old.existsSync()) old.deleteSync();
      log.renameSync(old.path);
    }
  } catch (_) {}
}

/// Test-only: stops the timer and the log listeners.
Future<void> stopDiagnosticsForTest() async {
  _aliveTimer?.cancel();
  await _logSub?.cancel();
  await _earlySub?.cancel();
  _earlySub = null;
  _early.clear();
  _aliveTimer = null;
  _logSub = null;
  _session = null;
  _logFile = null;
  _sessionFile = null;
}
