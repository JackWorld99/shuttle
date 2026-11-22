import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/shareme_diagnostics.dart';

// Shuttle: desktop diagnostics log — did the previous run exit normally, and was there a long gap (sleep) between two "alive" ticks.

void main() {
  group('previous run', () {
    test('no record, or a normal exit: nothing to note', () {
      expect(describePreviousSession(null), isNull);
      expect(describePreviousSession({'pid': 1, 'exit': 'tray quit'}), isNull);
    });

    test('no exit reason: it was ended by someone else, crashed, or the PC shut down', () {
      final note = describePreviousSession({
        'pid': 31136,
        'version': '2026.11.18+2274',
        'start': '2026-11-20T12:06:49',
        'lastAlive': '2026-11-20T13:01:49',
        'exit': null,
      });
      expect(note, contains('did not exit normally'));
      expect(note, contains('31136'));
      expect(note, contains('2026-11-20T13:01:49'));
    });

    test('a broken or missing session file is simply ignored', () {
      final dir = Directory('build/shareme_diagnostics_test')..createSync(recursive: true);
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(readSessionFile(File('${dir.path}/missing.json')), isNull);
      final broken = File('${dir.path}/broken.json')..writeAsStringSync('{not json');
      expect(readSessionFile(broken), isNull);
      final ok = File('${dir.path}/ok.json')..writeAsStringSync('{"pid": 5, "exit": null}');
      expect(readSessionFile(ok), {'pid': 5, 'exit': null});
    });
  });

  group('alive gaps', () {
    final last = DateTime(2026, 11, 20, 1, 10);

    test('a normal tick is not noted', () {
      expect(describeAliveGap(last, last.add(const Duration(minutes: 5))), isNull);
      expect(describeAliveGap(last, last.add(const Duration(minutes: 9))), isNull);
      expect(describeAliveGap(null, last), isNull);
    });

    test('a long gap (the PC slept) is noted with its length', () {
      final note = describeAliveGap(last, last.add(const Duration(hours: 8, minutes: 4)));
      expect(note, contains('484 min'));
    });
  });
}
