import 'dart:async';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

final _logger = Logger('CoalescedSave');

/// Shuttle: saves after a short delay, one save at a time. Used for the transfer history.
///
/// Why: previously every received file re-encoded up to 500 history entries and rewrote the whole settings file, building the new
/// list from the old one and only updating it once the write finished, so when several files finished together a later save still
/// used the old list and overwrote the earlier one. Now entries are updated in memory first (visible at once) and saving is left to
/// this class: after [schedule], at most one save per [delay] however many changes come in; each save reads the latest content; a
/// change made during a save triggers one more save afterwards, so two writes never overlap.
///
/// Call [flushAllBeforeExit] before a normal exit (tray quit, window close, quit shortcut, update), or the last second of changes is lost.
class CoalescedSave {
  /// Saves the latest content (read at save time, so it is always up to date).
  final Future<void> Function() _save;
  final Duration delay;

  CoalescedSave(this._save, {this.delay = const Duration(seconds: 1)});

  /// Instances with unsaved changes (must be saved before exit).
  static final _pendingSaves = <CoalescedSave>{};

  Timer? _timer;
  Future<void>? _running;
  bool _dirty = false;

  /// Whether there are unsaved changes.
  bool get hasPendingChanges => _dirty || _running != null;

  /// Marks a change: saves once within [delay] (all changes made in the meantime are saved together).
  void schedule() {
    _dirty = true;
    _pendingSaves.add(this);
    _timer ??= Timer(delay, () {
      _timer = null;
      unawaited(_drain());
    });
  }

  /// Saves now and waits until done (including a save already in progress).
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    await _drain();
  }

  /// Saves immediately before exit, without waiting. On desktop the settings file is written synchronously
  /// (shared_preferences_file.dart), so the data is on disk when this returns and the app can exit right away.
  static void flushAllBeforeExit() {
    for (final save in _pendingSaves.toList()) {
      save._timer?.cancel();
      save._timer = null;
      if (!save._dirty) continue;
      save._dirty = false;
      // A save in progress can be ignored: its synchronous write has already finished, and this save writes the latest content
      unawaited(save._runOnce());
    }
    _pendingSaves.clear();
  }

  @visibleForTesting
  static int get pendingCountForTest => _pendingSaves.length;

  Future<void> _drain() async {
    while (true) {
      final running = _running;
      if (running != null) {
        await running;
        continue;
      }
      if (!_dirty) {
        if (_timer == null) _pendingSaves.remove(this);
        return;
      }
      _dirty = false;
      final future = _runOnce();
      _running = future;
      await future;
      if (identical(_running, future)) _running = null;
    }
  }

  Future<void> _runOnce() async {
    try {
      await _save();
    } catch (e, st) {
      // The in-memory state is still correct and the next change saves again; the settings file has already logged the error
      _logger.warning('Could not save', e, st);
    }
  }
}
