import 'dart:io';

import 'package:localsend_app/util/shareme_file_safety.dart';
import 'package:test/test.dart';

void main() {
  group('isRunnableFile', () {
    test('programs, scripts and shortcuts are runnable', () {
      for (final name in ['setup.exe', 'run.BAT', 'a.ps1', 'x.vbs', 'link.lnk', 'tool.msi', 'page.hta', 'disk.iso', 'app.jar']) {
        expect(isRunnableFile(name), isTrue, reason: name);
      }
    });

    test('photos, videos, documents and archives are not', () {
      for (final name in ['IMG_1.HEIC', 'v.mp4', 'report.pdf', 'notes.docx', 'a.zip', 'readme', 'shuttle-lan-test-100mb.bin']) {
        expect(isRunnableFile(name), isFalse, reason: name);
      }
    });

    // Types added later: installers, Remote Desktop, ClickOnce, settings shortcuts, the various PowerShell files, etc.
    test('installers, remote desktop files, setting shortcuts and less common scripts are runnable', () {
      const added = [
        'rdp', 'appref-ms', 'msu', 'msix', 'msixbundle', 'appx', 'appxbundle', 'application', 'hta', 'cpl', 'scf', 'lnk', 'url', //
        'settingcontent-ms', 'library-ms', 'search-ms', 'searchconnector-ms', 'wsf', 'wsh', 'jse', 'vbe', 'msh', 'ps1xml', 'psc1', //
        'gadget', 'inf', 'reg', 'theme', 'themepack', 'ppkg', 'vsto', 'xbap', 'jnlp', 'website', 'wsb', 'cer', 'mdb', 'sh',
      ];
      for (final ext in added) {
        expect(isRunnableFile('file.$ext'), isTrue, reason: ext);
        expect(isRunnableFile('FILE.${ext.toUpperCase()}'), isTrue, reason: '$ext in capitals');
      }
    });

    test('common files people send each other stay openable', () {
      for (final name in [
        'a.jpg', 'a.png', 'a.gif', 'a.webp', 'a.heic', 'a.mov', 'a.mkv', 'a.mp3', 'a.m4a', 'a.txt', 'a.md', 'a.csv', 'a.json', //
        'a.xlsx', 'a.pptx', 'a.7z', 'a.rar', 'a.tar', 'a.gz', 'a.epub', 'a.html', 'a.svg', 'a.apk',
      ]) {
        expect(isRunnableFile(name), isFalse, reason: name);
      }
    });

    test('the list holds bare lower-case extensions', () {
      for (final ext in runnableExtensions) {
        expect(ext, ext.toLowerCase(), reason: ext);
        expect(ext.contains('.') || ext.contains(' ') || ext.isEmpty, isFalse, reason: ext);
      }
    });

    test('only the last extension counts, so a disguised program is caught', () {
      expect(isRunnableFile('holiday.jpg.exe'), isTrue);
      expect(isRunnableFile('setup.exe.txt'), isFalse);
    });

    test('trailing dots and spaces are ignored like Windows does', () {
      expect(isRunnableFile('evil.exe.'), isTrue);
      expect(isRunnableFile('evil.exe  '), isTrue);
    });

    test('works on full paths with either separator', () {
      expect(isRunnableFile(r'C:\Users\me\Downloads\Shuttle\tool.CMD'), isTrue);
      expect(isRunnableFile('/storage/emulated/0/Download/photo.png'), isFalse);
      expect(isRunnableFile(r'C:\folder.exe\photo.png'), isFalse);
    });

    test('a hidden file without an extension is not runnable', () {
      expect(lastExtension('.bashrc'), '');
      expect(isRunnableFile('.exe'), isFalse);
    });
  });

  group('markFromInternet', () {
    test('writes ZoneId=3 next to the file on Windows', () async {
      // In the project's own build folder, not the system temp folder
      final dir = Directory('build/test_file_safety')..createSync(recursive: true);
      final file = File('${dir.path}${Platform.pathSeparator}received.exe')..writeAsStringSync('MZ');
      addTearDown(() => dir.deleteSync(recursive: true));

      final marked = await markFromInternet(file.absolute.path);
      if (!Platform.isWindows) {
        expect(marked, isFalse);
        return;
      }
      expect(marked, isTrue);
      final stream = File('${file.absolute.path}:Zone.Identifier').readAsStringSync();
      expect(stream, zoneIdentifierInternet);
      expect(stream, contains('ZoneId=3'));
      expect(file.readAsStringSync(), 'MZ', reason: 'the file itself is unchanged');
    });

    test('content:// paths are left alone', () async {
      expect(await markFromInternet('content://media/external/file/1'), isFalse);
    });
  });
}
