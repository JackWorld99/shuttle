import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/shareme_update_provider.dart';
import 'package:localsend_app/util/shareme_update/update_manifest.dart';

// Shuttle: a downloaded and verified update is not discarded by one failed check (offline, timeout, manifest failed verification).

const _manifest = UpdateManifest(
  version: '2026.11.21',
  build: 2290,
  date: null,
  notes: {},
  files: {'windows-x64': UpdateFile(url: 'https://example.invalid/a.exe', size: 3, sha256: 'aaa')},
);

SmUpdateState _checking() => const SmUpdateState(phase: SmUpdatePhase.checking, manifest: _manifest, progress: 1, autoCheck: true);

void main() {
  for (final failure in [SmUpdatePhase.checkFailed, SmUpdatePhase.verifyFailed]) {
    group('after a failed check ($failure)', () {
      test('a downloaded and verified update stays ready to install', () {
        final s = stateAfterFailedCheck(
          _checking(),
          previousPhase: SmUpdatePhase.ready,
          previousManifest: _manifest,
          readyKept: true,
          failure: failure,
        );
        expect(s.phase, SmUpdatePhase.ready);
        expect(s.manifest, same(_manifest));
        expect(s.hasNewVersion, isTrue, reason: 'the dot on the settings icon and the update row stay');
      });

      test('a known newer version that is not downloaded yet stays available', () {
        final s = stateAfterFailedCheck(
          _checking(),
          previousPhase: SmUpdatePhase.available,
          previousManifest: _manifest,
          readyKept: false,
          failure: failure,
        );
        expect(s.phase, SmUpdatePhase.available);
        expect(s.hasNewVersion, isTrue);
      });

      test('without a known update the failure is shown', () {
        for (final previous in [SmUpdatePhase.idle, SmUpdatePhase.upToDate, SmUpdatePhase.checkFailed, SmUpdatePhase.verifyFailed]) {
          final s = stateAfterFailedCheck(
            _checking().copyWith(clearManifest: true),
            previousPhase: previous,
            previousManifest: null,
            readyKept: false,
            failure: failure,
          );
          expect(s.phase, failure, reason: '$previous');
          expect(s.manifest, isNull);
          expect(s.hasNewVersion, isFalse);
        }
      });

      test('a ready state whose file is gone is not kept', () {
        final s = stateAfterFailedCheck(
          _checking(),
          previousPhase: SmUpdatePhase.ready,
          previousManifest: _manifest,
          readyKept: false,
          failure: failure,
        );
        expect(s.phase, failure);
        expect(s.manifest, isNull);
      });
    });
  }

  test('a setting changed while checking is not undone', () {
    final s = stateAfterFailedCheck(
      _checking().copyWith(autoCheck: false),
      previousPhase: SmUpdatePhase.ready,
      previousManifest: _manifest,
      readyKept: true,
      failure: SmUpdatePhase.checkFailed,
    );
    expect(s.autoCheck, isFalse);
  });
}
