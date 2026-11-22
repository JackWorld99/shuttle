import 'dart:convert';
import 'dart:io';

import 'package:localsend_app/util/shared_preferences/shared_preferences_file.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:test/test.dart';

// Shuttle: a damaged settings file must not give the computer a new identity (shared_preferences_file.dart).
// Test files live under build/, not in the system temp folder.

const _identity = 'flutter.ls_security_context';

void main() {
  late Directory dir;
  late String path;
  late List<LogRecord> logs;

  setUp(() {
    final root = Directory('build/shared_preferences_file_test')..createSync(recursive: true);
    dir = root.createTempSync('case');
    path = p.join(dir.path, 'settings.json');
    logs = [];
    final sub = Logger.root.onRecord.listen(logs.add);
    addTearDown(sub.cancel);
    addTearDown(() => dir.deleteSync(recursive: true));
  });

  SharedPreferencesFile open({bool beautify = false}) {
    return SharedPreferencesFile(filePath: path, beautify: beautify)
      ..replaceRetryDelays = const [Duration.zero, Duration.zero]
      ..readRetryDelays = const [];
  }

  File file(String name) => File(p.join(dir.path, name));

  Map<String, dynamic> readJson(String name) => jsonDecode(file(name).readAsStringSync()) as Map<String, dynamic>;

  List<String> damagedCopies() => dir.listSync().map((e) => p.basename(e.path)).where((n) => n.contains('.corrupt-')).toList()..sort();

  List<LogRecord> lifecycle(Level level) => logs.where((r) => r.loggerName == 'Lifecycle' && r.level == level).toList();

  group('writing', () {
    test('saves through a temporary file and keeps the previous version as .bak', () async {
      final store = open();
      expect(store.loadOutcome, SettingsLoadOutcome.fresh);
      expect(file('settings.json').existsSync(), isFalse, reason: 'nothing is created before the first save');

      await store.setValue('String', _identity, 'id-1');
      expect(readJson('settings.json'), {_identity: 'id-1'});
      expect(file('settings.json.tmp').existsSync(), isFalse);

      await store.setValue('String', 'flutter.ls_alias', 'PC');
      expect(readJson('settings.json'), {_identity: 'id-1', 'flutter.ls_alias': 'PC'});
      expect(readJson('settings.json.bak'), {_identity: 'id-1'});
    });

    test('a write that fails half way leaves settings.json intact', () async {
      file('settings.json').writeAsStringSync(jsonEncode({_identity: 'id-1'}));
      final store = open();
      expect(store.loadOutcome, SettingsLoadOutcome.ok);
      Directory(p.join(dir.path, 'settings.json.tmp')).createSync(); // .tmp can't be written (like a full disk: the write fails half way)

      expect(() => store.setValue('String', 'flutter.ls_alias', 'PC'), throwsA(isA<FileSystemException>()));

      expect(readJson('settings.json'), {_identity: 'id-1'});
      expect(lifecycle(Level.SEVERE).single.message, contains('could not save settings.json'));
      expect(lifecycle(Level.SEVERE).single.message, isNot(contains(dir.path)), reason: 'no full paths in the diagnostics log');
    });

    test('when replacing keeps failing, it writes in place (the backup covers that)', () async {
      file('settings.json').writeAsStringSync(jsonEncode({_identity: 'id-1'}));
      final store = open();
      var attempts = 0;
      store.rename = (source, target) {
        attempts++;
        throw FileSystemException('Cannot rename file', source.path, const OSError('Access is denied', 5));
      };

      await store.setValue('String', 'flutter.ls_alias', 'PC');

      expect(attempts, 3, reason: 'first try + 2 retries');
      expect(readJson('settings.json'), {_identity: 'id-1', 'flutter.ls_alias': 'PC'});
      expect(readJson('settings.json.bak'), {_identity: 'id-1'});
      expect(file('settings.json.tmp').existsSync(), isFalse);
      expect(lifecycle(Level.WARNING).single.message, contains('OS error 5'));
    });

    test('a replace that fails once and then works needs no fallback', () async {
      final store = open();
      var attempts = 0;
      store.rename = (source, target) {
        if (++attempts == 1) throw const FileSystemException('busy');
        source.renameSync(target);
      };

      await store.setValue('String', _identity, 'id-1');

      expect(attempts, 2);
      expect(readJson('settings.json'), {_identity: 'id-1'});
      expect(lifecycle(Level.WARNING), isEmpty);
    });

    test('Windows: another program has settings.json open (real file lock)', () async {
      file('settings.json').writeAsStringSync(jsonEncode({_identity: 'id-1'}));
      final store = open();
      final reader = file('settings.json').openSync(); // while it is open, Windows refuses the replace (access denied)
      try {
        await store.setValue('String', 'flutter.ls_alias', 'PC');
      } finally {
        reader.closeSync();
      }

      expect(readJson('settings.json'), {_identity: 'id-1', 'flutter.ls_alias': 'PC'});
      // once it is closed, the next save uses the normal replace again
      logs.clear();
      await store.setValue('String', 'flutter.ls_alias', 'PC2');
      expect(readJson('settings.json')['flutter.ls_alias'], 'PC2');
      expect(file('settings.json.tmp').existsSync(), isFalse);
      expect(lifecycle(Level.WARNING), isEmpty);
    }, skip: Platform.isWindows ? false : 'Windows only');

    test('pretty-printed (portable mode) files are read back the same', () async {
      final store = open(beautify: true);
      await store.setValue('StringList', 'flutter.ls_receive_history', ['a', 'b']);
      expect(file('settings.json').readAsStringSync(), contains('\n  "flutter.ls_receive_history"'));
      expect(await open().getAll(), {
        'flutter.ls_receive_history': ['a', 'b'],
      });
    });

    test('clear() really clears (upstream only wrote an empty file and saved everything again next time)', () async {
      final store = open();
      await store.setValue('String', _identity, 'id-1');
      await store.clear();
      await store.setValue('String', 'flutter.ls_alias', 'PC');
      expect(readJson('settings.json'), {'flutter.ls_alias': 'PC'});
    });
  });

  group('reading', () {
    test('a good file is read as is and nothing is touched', () async {
      file('settings.json').writeAsStringSync(jsonEncode({_identity: 'id-1'}));
      file('settings.json.bak').writeAsStringSync(jsonEncode({_identity: 'old'}));
      final store = open();
      expect(await store.getAll(), {_identity: 'id-1'});
      expect(store.loadOutcome, SettingsLoadOutcome.ok);
      expect(readJson('settings.json.bak'), {_identity: 'old'});
      expect(damagedCopies(), isEmpty);
      expect(logs, isEmpty);
    });

    test('damaged file + good backup: restored from the backup, damaged file kept, same identity', () async {
      file('settings.json').writeAsStringSync('{"flutter.ls_security_context": "id-1", "flutter.ls_ali');
      file('settings.json.bak').writeAsStringSync(jsonEncode({_identity: 'id-1'}));
      final store = open();

      expect(await store.getAll(), {_identity: 'id-1'});
      expect(store.loadOutcome, SettingsLoadOutcome.restored);
      expect(readJson('settings.json'), {_identity: 'id-1'}, reason: 'written back right away');
      expect(damagedCopies(), [store.keptDamagedFile]);
      expect(file(store.keptDamagedFile!).readAsStringSync(), startsWith('{"flutter.ls_security_context": "id-1", "flutter.ls_ali'));
      final warning = lifecycle(Level.WARNING).single.message;
      expect(warning, contains('restored from settings.json.bak'));
      expect(warning, contains(store.keptDamagedFile));
      expect(warning, isNot(contains('id-1')), reason: 'no settings content in the diagnostics log');

      // the next save doesn't overwrite the backup with the damaged file
      await store.setValue('String', 'flutter.ls_alias', 'PC');
      expect(readJson('settings.json.bak'), {_identity: 'id-1'});
    });

    test('a file full of zero bytes (what a power cut often leaves) is damaged too', () async {
      file('settings.json').writeAsBytesSync(List.filled(4096, 0));
      file('settings.json.bak').writeAsStringSync(jsonEncode({_identity: 'id-1'}));
      final store = open();
      expect(await store.getAll(), {_identity: 'id-1'});
      expect(store.loadOutcome, SettingsLoadOutcome.restored);
      expect(damagedCopies().length, 1);
    });

    test('empty or missing file + backup: restored, nothing to keep', () async {
      file('settings.json').writeAsStringSync('');
      file('settings.json.bak').writeAsStringSync(jsonEncode({_identity: 'id-1'}));
      final store = open();
      expect(await store.getAll(), {_identity: 'id-1'});
      expect(store.loadOutcome, SettingsLoadOutcome.restored);
      expect(store.keptDamagedFile, isNull);
      expect(damagedCopies(), isEmpty);
      expect(readJson('settings.json'), {_identity: 'id-1'});
    });

    test('a complete .tmp (written, not yet swapped in) is preferred over the older backup', () async {
      file('settings.json').writeAsStringSync('{broken');
      file('settings.json.tmp').writeAsStringSync(jsonEncode({_identity: 'id-1', 'flutter.ls_alias': 'new'}));
      file('settings.json.bak').writeAsStringSync(jsonEncode({_identity: 'id-1', 'flutter.ls_alias': 'old'}));
      final store = open();
      expect(await store.getAll(), {_identity: 'id-1', 'flutter.ls_alias': 'new'});
      expect(lifecycle(Level.WARNING).single.message, contains('restored from settings.json.tmp'));
    });

    test('a half-written .tmp is ignored', () async {
      file('settings.json').writeAsStringSync('{broken');
      file('settings.json.tmp').writeAsStringSync('{"flutter.ls_security_context": "id-2"');
      file('settings.json.bak').writeAsStringSync(jsonEncode({_identity: 'id-1'}));
      final store = open();
      expect(await store.getAll(), {_identity: 'id-1'});
    });

    test('damaged and no usable backup: starts over, but never silently — both files kept and logged', () async {
      file('settings.json').writeAsStringSync('{"flutter.ls_security_context": "id-1", "flutt');
      file('settings.json.bak').writeAsStringSync('not json either');
      final store = open();

      expect(await store.getAll(), isEmpty);
      expect(store.loadOutcome, SettingsLoadOutcome.unrecoverable);
      expect(damagedCopies(), hasLength(2));
      expect(file(store.keptDamagedFile!).readAsStringSync(), contains('id-1'));
      expect(file('settings.json').existsSync(), isTrue, reason: 'portable mode is detected by settings.json being there');
      final severe = lifecycle(Level.SEVERE).single.message;
      expect(severe, contains('new device identity'));
      expect(severe, contains(store.keptDamagedFile));

      // later saves work normally and leave the kept damaged files alone
      await store.setValue('String', _identity, 'id-new');
      await store.setValue('String', 'flutter.ls_alias', 'PC');
      expect(readJson('settings.json'), {_identity: 'id-new', 'flutter.ls_alias': 'PC'});
      expect(damagedCopies(), hasLength(2));
      expect(file(store.keptDamagedFile!).readAsStringSync(), contains('id-1'));
    });

    test('no file at all: first start, nothing logged', () async {
      final store = open();
      expect(await store.getAll(), isEmpty);
      expect(store.loadOutcome, SettingsLoadOutcome.fresh);
      expect(logs, isEmpty);
    });

    test('a file that is valid JSON but not an object counts as damaged', () async {
      file('settings.json').writeAsStringSync('[1, 2, 3]');
      file('settings.json.bak').writeAsStringSync(jsonEncode({_identity: 'id-1'}));
      final store = open();
      expect(await store.getAll(), {_identity: 'id-1'});
      expect(store.loadOutcome, SettingsLoadOutcome.restored);
    });

    test('UTF-8 BOM (edited in Notepad) is fine; null values are dropped instead of breaking SharedPreferences', () async {
      file('settings.json').writeAsStringSync('﻿${jsonEncode({_identity: 'id-1', 'flutter.ls_alias': null})}');
      final store = open();
      expect(await store.getAll(), {_identity: 'id-1'});
      expect(store.loadOutcome, SettingsLoadOutcome.ok);

      // Upstream, a null value makes SharedPreferences.getInstance fail, and the settings file then gets deleted
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = store;
      addTearDown(SharedPreferences.resetStatic);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('ls_security_context'), 'id-1');
    });
  });
}
