// Shuttle auto-update: manifest signature check, download verification, Windows installer arguments.
// The envelope_*.json files in fixtures/shareme_update were signed with support/scripts/shuttle_update_manifest.py (the same
// script the release build uses) and a one-off test key whose private half has been deleted; the app does not trust this key.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:localsend_app/util/shareme_update/update_config.dart';
import 'package:localsend_app/util/shareme_update/update_download.dart';
import 'package:localsend_app/util/shareme_update/update_installer.dart';
import 'package:localsend_app/util/shareme_update/update_manifest.dart';
import 'package:test/test.dart';

const _fixtures = 'test/fixtures/shareme_update';
const _windowsBytes = 'shuttle-test-windows\n';

String _read(String name) => File('$_fixtures/$name').readAsStringSync();

/// Unpacks the manifest from the envelope, changes it and packs it back (signature unchanged)
String _tamperPayload(String envelope, Map<String, dynamic> Function(Map<String, dynamic>) change) {
  final e = jsonDecode(envelope) as Map<String, dynamic>;
  final payload = jsonDecode(utf8.decode(base64.decode(e['payload'] as String))) as Map<String, dynamic>;
  e['payload'] = base64.encode(utf8.encode(jsonEncode(change(payload))));
  return jsonEncode(e);
}

void main() {
  final testKey = _read('test_public_key.txt').trim();
  final ok = _read('envelope_ok.json');

  group('verifyUpdateEnvelope', () {
    test('accepts what the release script signed', () async {
      final m = await verifyUpdateEnvelope(ok, trustedKeys: [testKey], downloadPrefix: updateDownloadPrefix);
      expect(m.version, '2026.11.20');
      expect(m.build, 2275);
      expect(m.date, DateTime.utc(2026, 11, 20, 8));
      expect(m.notesFor('zh'), '测试版');
      expect(m.notesFor('en'), 'Test build');
      expect(m.files.keys, containsAll(['windows-x64', 'android-arm64']));
      final win = m.files['windows-x64']!;
      expect(win.url, '${updateDownloadPrefix}v2026.11.20-2275/Shuttle-Setup-2026.11.20.exe');
      expect(win.size, utf8.encode(_windowsBytes).length);
      expect(win.sha256, crypto.sha256.convert(utf8.encode(_windowsBytes)).toString());
    });

    test('the key id in the envelope is derived from the public key', () {
      final envelope = jsonDecode(ok) as Map<String, dynamic>;
      expect(updateKeyId(base64.decode(testKey)), envelope['key']);
    });

    test('rejects a signature from a key the app does not trust', () async {
      await expectLater(
        verifyUpdateEnvelope(_read('envelope_other_key.json'), trustedKeys: [testKey], downloadPrefix: updateDownloadPrefix),
        throwsA(isA<UpdateVerifyException>()),
      );
      await expectLater(verifyUpdateEnvelope(ok, trustedKeys: const [], downloadPrefix: updateDownloadPrefix), throwsA(isA<UpdateVerifyException>()));
    });

    test('rejects a changed manifest (newer build, other file hash, other url)', () async {
      final changes = <Map<String, dynamic> Function(Map<String, dynamic>)>[
        (m) => m..['build'] = 99999,
        (m) => m..['files']['windows-x64']['sha256'] = '0' * 64,
        (m) => m..['files']['windows-x64']['url'] = '${updateDownloadPrefix}v1/evil.exe',
      ];
      for (final change in changes) {
        await expectLater(
          verifyUpdateEnvelope(_tamperPayload(ok, change), trustedKeys: [testKey], downloadPrefix: updateDownloadPrefix),
          throwsA(isA<UpdateVerifyException>()),
        );
      }
    });

    test('rejects a changed signature, a wrong key id and broken envelopes', () async {
      final e = jsonDecode(ok) as Map<String, dynamic>;
      final sig = base64.decode(e['signature'] as String);
      sig[0] ^= 1;
      final badSig = jsonEncode({...e, 'signature': base64.encode(sig)});
      final badKeyId = jsonEncode({...e, 'key': '0000000000000000'});
      final badFormat = jsonEncode({...e, 'format': 'shuttle-update-2'});
      for (final body in [badSig, badKeyId, badFormat, 'not json', '[]', '{}']) {
        await expectLater(
          verifyUpdateEnvelope(body, trustedKeys: [testKey], downloadPrefix: updateDownloadPrefix),
          throwsA(isA<UpdateVerifyException>()),
          reason: body.length > 40 ? body.substring(0, 40) : body,
        );
      }
    });

    test('rejects files hosted somewhere else, even with a valid signature', () async {
      await expectLater(
        verifyUpdateEnvelope(ok, trustedKeys: [testKey], downloadPrefix: 'https://github.com/someone-else/repo/releases/download/'),
        throwsA(isA<UpdateVerifyException>()),
      );
    });
  });

  group('parseUpdateManifest', () {
    Map<String, dynamic> valid() => {
      'schema': 1,
      'version': '2026.11.20',
      'build': 2275,
      'files': {
        'windows-x64': {'url': '${updateDownloadPrefix}v/a.exe', 'size': 3, 'sha256': 'a' * 64},
      },
    };

    test('a minimal manifest parses', () {
      final m = parseUpdateManifest(valid(), downloadPrefix: updateDownloadPrefix);
      expect(m.build, 2275);
      expect(m.date, isNull);
      expect(m.notesFor('zh'), isNull);
    });

    test('bad fields are rejected', () {
      final broken = <Map<String, dynamic> Function(Map<String, dynamic>)>[
        (m) => m..['schema'] = 2,
        (m) => m..['build'] = 0,
        (m) => m..['build'] = '2275',
        (m) => m..['version'] = '1.0 beta',
        (m) => m..['files'] = null,
        (m) => m..['files']['windows-x64']['size'] = 0,
        (m) => m..['files']['windows-x64']['sha256'] = 'A' * 64,
        (m) => m..['files']['windows-x64']['url'] = 'http://github.com/JackWorld99/shuttle/releases/download/v/a.exe',
      ];
      for (final change in broken) {
        expect(() => parseUpdateManifest(change(valid()), downloadPrefix: updateDownloadPrefix), throwsA(isA<UpdateVerifyException>()));
      }
    });
  });

  group('downloadUpdateFile', () {
    late HttpServer server;
    late Directory dir;
    var served = utf8.encode(_windowsBytes);

    setUp(() async {
      updateAllowHttpForTests = true;
      served = utf8.encode(_windowsBytes);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/missing') {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.add(served);
        }
        await request.response.close();
      });
      // In the project's own build folder, not the system temp folder (like shareme_file_safety_test).
      // In a clean checkout (CI) build/ doesn't exist yet and createTemp doesn't create parent folders, so create it first
      final parent = Directory('build/shuttle_update_test')..createSync(recursive: true);
      dir = await parent.createTemp('run');
    });

    tearDown(() async {
      updateAllowHttpForTests = false;
      await server.close(force: true);
      // On Windows, antivirus briefly holds freshly written files: retry the delete a few times, then give up (it's only a test folder)
      for (var i = 0; i < 10 && dir.existsSync(); i++) {
        try {
          await dir.delete(recursive: true);
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
    });

    UpdateFile meta(String path) => UpdateFile(
      url: 'http://127.0.0.1:${server.port}$path',
      size: utf8.encode(_windowsBytes).length,
      sha256: crypto.sha256.convert(utf8.encode(_windowsBytes)).toString(),
    );

    test('a file that matches the manifest is kept', () async {
      final client = newUpdateHttpClient();
      final target = File('${dir.path}/Shuttle-2275.bin');
      await downloadUpdateFile(client, meta('/a.exe'), target);
      client.close();
      expect(target.readAsStringSync(), _windowsBytes);
      expect(await updateFileMatches(target, meta('/a.exe')), isTrue);
      expect(File('${target.path}.part').existsSync(), isFalse);
    });

    test('a file with other content is deleted and not handed over', () async {
      served = utf8.encode('shuttle-evil-windows\n'); // same length, different content
      final client = newUpdateHttpClient();
      final target = File('${dir.path}/Shuttle-2275.bin');
      await expectLater(downloadUpdateFile(client, meta('/a.exe'), target), throwsA(isA<UpdateVerifyException>()));
      client.close();
      expect(target.existsSync(), isFalse);
      expect(File('${target.path}.part').existsSync(), isFalse);
    });

    test('a file larger than the manifest says is rejected', () async {
      served = utf8.encode('$_windowsBytes and more');
      final client = newUpdateHttpClient();
      final target = File('${dir.path}/Shuttle-2275.bin');
      await expectLater(downloadUpdateFile(client, meta('/a.exe'), target), throwsA(isA<UpdateVerifyException>()));
      client.close();
      expect(target.existsSync(), isFalse);
    });

    test('in the background thread: a matching file is kept and progress comes back', () async {
      // Downloading on the app's main isolate was too slow (about 117 KB/s), so it moved to a background isolate
      final target = File('${dir.path}/Shuttle-2276.bin');
      final seen = <(int, int)>[];
      await downloadUpdateFileInBackground(meta('/a.exe'), target, onProgress: (r, t) => seen.add((r, t)));
      expect(target.readAsStringSync(), _windowsBytes);
      expect(File('${target.path}.part').existsSync(), isFalse);
      // Progress and "done" use different channels, so the last progress message may arrive late; those that arrive must be right
      for (final (r, t) in seen) {
        expect(t, utf8.encode(_windowsBytes).length);
        expect(r, inInclusiveRange(1, t));
      }
    });

    test('in the background thread: a wrong file is still rejected and deleted', () async {
      served = utf8.encode('shuttle-evil-windows\n');
      final target = File('${dir.path}/Shuttle-2276.bin');
      await expectLater(downloadUpdateFileInBackground(meta('/a.exe'), target), throwsA(isA<UpdateVerifyException>()));
      expect(target.existsSync(), isFalse);
      expect(File('${target.path}.part').existsSync(), isFalse);
    });

    test('rename waits for a short lock (antivirus scanning the new exe) and then succeeds', () async {
      // Seen with build 2272: the first download finished and verified, but the rename failed (likely Defender scanning) and left a .part
      var tries = 0;
      final from = File('${dir.path}/Shuttle-2277.exe.part')..writeAsStringSync('x');
      await renameWithRetry(
        from,
        '${dir.path}/Shuttle-2277.exe',
        delay: Duration.zero,
        rename: (f, t) async {
          tries++;
          if (tries < 3) throw const FileSystemException('The process cannot access the file because it is being used by another process');
          await f.rename(t);
        },
      );
      expect(tries, 3);
      expect(File('${dir.path}/Shuttle-2277.exe').existsSync(), isTrue);
    });

    test('rename gives up after the last try and reports the error', () async {
      final from = File('${dir.path}/Shuttle-2278.exe.part')..writeAsStringSync('x');
      var tries = 0;
      await expectLater(
        renameWithRetry(
          from,
          '${dir.path}/Shuttle-2278.exe',
          attempts: 4,
          delay: Duration.zero,
          rename: (f, t) async {
            tries++;
            throw const FileSystemException('locked');
          },
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(tries, 4);
    });

    test('a changed file on disk no longer matches', () async {
      final target = File('${dir.path}/Shuttle-2275.bin')..writeAsStringSync('shuttle-evil-windows\n');
      expect(await updateFileMatches(target, meta('/a.exe')), isFalse);
    });

    test('HTTP errors are network errors, not verification errors', () async {
      final client = newUpdateHttpClient();
      await expectLater(
        fetchUpdateText(client, Uri.parse('http://127.0.0.1:${server.port}/missing'), maxBytes: 1024),
        throwsA(isA<UpdateNetworkException>()),
      );
      client.close();
    });

    test('only https is allowed outside tests', () async {
      updateAllowHttpForTests = false;
      final client = newUpdateHttpClient();
      await expectLater(
        fetchUpdateText(client, Uri.parse('http://127.0.0.1:${server.port}/a'), maxBytes: 1024),
        throwsA(isA<UpdateNetworkException>()),
      );
      client.close();
    });
  });

  group('installer', () {
    test('Windows installer arguments', () {
      expect(
        windowsInstallerArgs(appDir: r'C:\Program Files\Shuttle\', portable: false, startHidden: true, logPath: r'C:\x\install.log'),
        [
          '/VERYSILENT',
          '/SUPPRESSMSGBOXES',
          '/NORESTART',
          '/SHUTTLEUPDATE=1',
          '/HIDDEN=1',
          r'/DIR=C:\Program Files\Shuttle',
          r'/LOG=C:\x\install.log',
        ],
      );
      expect(
        windowsInstallerArgs(appDir: r'D:\Portable\Shuttle', portable: true, startHidden: false, logPath: 'l'),
        ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SHUTTLEUPDATE=1', '/PORTABLE=1', r'/DIR=D:\Portable\Shuttle', '/LOG=l'],
      );
    });

    test('installed or portable: the uninstaller in the folder is enough, the registry is a second way', () {
      // A Shuttle started via WMI can't read the uninstall entry in HKCU, so an installed copy was updated as if it were portable
      const dir = r'C:\Users\a\AppData\Local\Programs\Shuttle';
      expect(isInstalledShuttle(appDir: dir, hasUninstaller: true, registeredLocation: null), isTrue);
      expect(isInstalledShuttle(appDir: dir, hasUninstaller: false, registeredLocation: '$dir\\'), isTrue);
      expect(isInstalledShuttle(appDir: dir, hasUninstaller: false, registeredLocation: r'C:\Other\Shuttle'), isFalse);
      expect(isInstalledShuttle(appDir: dir, hasUninstaller: false, registeredLocation: null), isFalse, reason: 'portable');
    });

    test('install location from the registry matches the exe folder', () {
      expect(
        normalizeWindowsDir(r'C:\Users\a\Apps\Shuttle Portable\'),
        normalizeWindowsDir('C:/Users/A/Apps/Shuttle Portable'),
      );
      expect(normalizeWindowsDir(r'C:\a\b'), isNot(normalizeWindowsDir(r'C:\a\bc')));
    });

    test('download file names carry the build number', () {
      expect(updateFileName(2275, '${updateDownloadPrefix}v2026.11.20-2275/Shuttle-Setup-2026.11.20.exe'), 'Shuttle-2275.exe');
      expect(updateFileName(2275, '${updateDownloadPrefix}v2026.11.20-2275/Shuttle-2026.11.20.apk'), 'Shuttle-2275.apk');
    });
  });

  // When a downloaded update is kept and when it is replaced
  group('isSameUpdate', () {
    UpdateManifest manifest(int build, {String sha = 'a', int size = 3, bool android = false}) => UpdateManifest(
      version: '2026.11.21',
      build: build,
      date: null,
      notes: const {},
      files: {
        (android ? 'android-arm64' : 'windows-x64'): UpdateFile(url: '${updateDownloadPrefix}v$build/a', size: size, sha256: sha * 64),
      },
    );

    test('the same build with the same file is still the latest', () {
      expect(isSameUpdate(manifest(2290), manifest(2290), 'windows-x64'), isTrue);
    });

    test('a newer build replaces it', () {
      expect(isSameUpdate(manifest(2290), manifest(2291), 'windows-x64'), isFalse);
    });

    test('a manifest that no longer lists it (older build after a pulled release) replaces it', () {
      expect(isSameUpdate(manifest(2290), manifest(2289), 'windows-x64'), isFalse);
    });

    test('the same build with another file, or without a file for this platform, replaces it', () {
      expect(isSameUpdate(manifest(2290), manifest(2290, sha: 'b'), 'windows-x64'), isFalse);
      expect(isSameUpdate(manifest(2290), manifest(2290, size: 4), 'windows-x64'), isFalse);
      expect(isSameUpdate(manifest(2290), manifest(2290, android: true), 'windows-x64'), isFalse);
    });
  });

  group('config', () {
    test('the manifest comes from the same public repository as the files', () {
      expect(updateManifestUrl, startsWith('https://github.com/JackWorld99/shuttle/releases/latest/download/'));
      expect(updateDownloadPrefix, 'https://github.com/JackWorld99/shuttle/releases/download/');
    });

    test('trusted keys are raw 32-byte Ed25519 keys', () {
      for (final key in updateTrustedKeys) {
        expect(base64.decode(key).length, 32, reason: key);
      }
    });
  });
}
