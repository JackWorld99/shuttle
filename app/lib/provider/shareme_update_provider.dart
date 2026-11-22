// Shuttle auto-update: state and flow.
//
// - Checks 1 minute after the app opens, then every 24 hours (automatic checks can be turned off in settings).
// - New version: the PC downloads it right away; the phone downloads automatically only on Wi-Fi (or Ethernet) and waits for
//   the user to tap "Update" on mobile data.
// - Downloaded and verified (signature + size + SHA-256): a small dot on the settings icon + a "New version … · Update" row at
//   the top of the settings page. No pop-ups, no notifications.
// - Tapping "Update": nothing is installed during a file transfer. PC: Shuttle launches the installer and quits; the installer
//   reopens it when done. Phone: the system asks for confirmation once.
// - Any verification mismatch: the download is deleted, nothing is installed, and the settings page shows "failed verification".
// - A downloaded update isn't discarded by a single failed check (offline, timeout, manifest failing verification); it is only
//   replaced by a confirmed newer version, or once the latest manifest no longer lists it (see [stateAfterFailedCheck], [isSameUpdate]).
import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/util/coalesced_save.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/native/tray_helper.dart';
import 'package:localsend_app/util/shareme_diagnostics.dart';
import 'package:localsend_app/util/shareme_update/update_config.dart';
import 'package:localsend_app/util/shareme_update/update_download.dart';
import 'package:localsend_app/util/shareme_update/update_installer.dart';
import 'package:localsend_app/util/shareme_update/update_manifest.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:window_manager/window_manager.dart';

final _logger = Logger('Update');

enum SmUpdatePhase {
  /// Not checked yet (or not supported on this platform)
  idle,
  checking,
  upToDate,

  /// Network unreachable, host not found, etc.; try again next time
  checkFailed,

  /// A new version exists but isn't downloaded yet (on mobile data the phone waits for the user to tap)
  available,
  downloading,

  /// Downloaded and verified, waiting for the user to tap "Update"
  ready,

  /// The manifest signature, the format or the downloaded file didn't check out: not installed
  verifyFailed,

  /// Handed over to the installer / the system package installer
  installing,
}

class SmUpdateState {
  final SmUpdatePhase phase;

  /// The version newer than this one (set while available / downloading / ready / installing)
  final UpdateManifest? manifest;

  /// Download progress 0–1
  final double progress;
  final bool autoCheck;

  const SmUpdateState({required this.phase, required this.manifest, required this.progress, required this.autoCheck});

  /// Whether to show the dot on the settings icon and the row at the top of the settings page
  bool get hasNewVersion => switch (phase) {
    SmUpdatePhase.available || SmUpdatePhase.downloading || SmUpdatePhase.ready || SmUpdatePhase.installing => manifest != null,
    _ => false,
  };

  SmUpdateState copyWith({SmUpdatePhase? phase, UpdateManifest? manifest, bool clearManifest = false, double? progress, bool? autoCheck}) {
    return SmUpdateState(
      phase: phase ?? this.phase,
      manifest: clearManifest ? null : (manifest ?? this.manifest),
      progress: progress ?? this.progress,
      autoCheck: autoCheck ?? this.autoCheck,
    );
  }
}

/// Shuttle: the state after a check that got no trustworthy manifest (offline, timeout, manifest failing verification).
/// A new version confirmed earlier — downloaded and verified ([SmUpdatePhase.ready], [readyKept] meaning the file is still
/// tracked) or not downloaded yet ([SmUpdatePhase.available]) — is kept: its manifest's signature was verified, and one failed
/// check doesn't make it wrong. This used to always reset to "check failed", and a downloaded update only came back after the
/// next successful check. In all other cases the state shows [failure].
SmUpdateState stateAfterFailedCheck(
  SmUpdateState current, {
  required SmUpdatePhase previousPhase,
  required UpdateManifest? previousManifest,
  required bool readyKept,
  required SmUpdatePhase failure,
}) {
  final keep = previousManifest != null && ((previousPhase == SmUpdatePhase.ready && readyKept) || previousPhase == SmUpdatePhase.available);
  return keep ? current.copyWith(phase: previousPhase, manifest: previousManifest) : current.copyWith(phase: failure, clearManifest: true);
}

final smUpdateProvider = NotifierProvider<SmUpdateNotifier, SmUpdateState>((ref) => SmUpdateNotifier(), debugLabel: 'SmUpdateProvider');

class SmUpdateNotifier extends Notifier<SmUpdateState> {
  final String? _platform = currentUpdatePlatform();
  final UpdateInstaller? _installer = updateInstallerForCurrentPlatform();
  Timer? _firstCheck;
  Timer? _periodicCheck;

  /// The downloaded, verified build waiting to be installed (present together with [SmUpdatePhase.ready])
  ({UpdateManifest manifest, File file})? _ready;

  /// Whether this platform supports auto-update (Windows x64, Android arm64; macOS isn't wired up yet)
  bool get supported => _platform != null && _installer != null;

  @override
  SmUpdateState init() {
    return SmUpdateState(phase: SmUpdatePhase.idle, manifest: null, progress: 0, autoCheck: ref.read(persistenceProvider).getAutoUpdate());
  }

  /// Called once from postInit.
  void start() {
    if (!supported || _firstCheck != null) return;
    unawaited(_cleanup());
    _firstCheck = Timer(updateFirstCheckDelay, _scheduledCheck);
    _periodicCheck = Timer.periodic(updateCheckInterval, (_) => _scheduledCheck());
  }

  void _scheduledCheck() {
    if (state.autoCheck) unawaited(check());
  }

  Future<void> setAutoCheck(bool enabled) async {
    await ref.read(persistenceProvider).setAutoUpdate(enabled);
    state = state.copyWith(autoCheck: enabled);
  }

  /// Whether a file is being received or sent (waiting for acceptance counts). No update is installed then: once the desktop
  /// app quits, the transfer breaks.
  bool get transferActive {
    bool active(SessionStatus? s) => s == SessionStatus.waiting || s == SessionStatus.sending;
    if (active(ref.read(serverProvider)?.session?.status)) return true;
    return ref.read(sendProvider).values.any((s) => active(s.status));
  }

  /// Used by both the scheduled check (when automatic checks are on) and the user tapping "Check for updates".
  Future<void> check() async {
    if (!supported) return;
    if (const [SmUpdatePhase.checking, SmUpdatePhase.downloading, SmUpdatePhase.installing].contains(state.phase)) return;
    final previousPhase = state.phase;
    final previousManifest = state.manifest;
    SmUpdateState afterFailure(SmUpdatePhase failure) => stateAfterFailedCheck(
      state,
      previousPhase: previousPhase,
      previousManifest: previousManifest,
      readyKept: _ready != null,
      failure: failure,
    );
    state = state.copyWith(phase: SmUpdatePhase.checking);
    final client = newUpdateHttpClient();
    try {
      final current = await _currentBuild();
      final UpdateManifest manifest;
      try {
        final body = await fetchUpdateText(client, Uri.parse(updateManifestUrl), maxBytes: updateManifestMaxBytes);
        manifest = await verifyUpdateEnvelope(body, trustedKeys: updateTrustedKeys, downloadPrefix: updateDownloadPrefix);
      } on UpdateVerifyException catch (e) {
        _logger.warning('Update manifest did not pass verification: ${e.message}');
        state = afterFailure(SmUpdatePhase.verifyFailed);
        return;
      } catch (e) {
        _logger.info('Update check failed: $e');
        state = afterFailure(SmUpdatePhase.checkFailed);
        return;
      }
      final ready = _ready;
      if (ready != null) {
        if (isSameUpdate(ready.manifest, manifest, _platform!)) {
          _logger.info('Latest is still the downloaded build ${manifest.build}');
          state = state.copyWith(phase: SmUpdatePhase.ready, manifest: manifest, progress: 1);
          return;
        }
        // A newer version is confirmed, or the latest manifest no longer lists it (withdrawn): replace it
        _logger.info('Downloaded build ${ready.manifest.build} is no longer the latest (${manifest.build}), dropping it');
        _ready = null;
        await _deleteQuietly(ready.file);
      }
      final file = manifest.files[_platform];
      if (file == null || manifest.build <= current) {
        _logger.info('Up to date (local $current, latest ${manifest.build}, file for $_platform: ${file != null})');
        state = state.copyWith(phase: SmUpdatePhase.upToDate, clearManifest: true);
        return;
      }
      _logger.info('New version ${manifest.version} (${manifest.build}), local $current');
      state = state.copyWith(phase: SmUpdatePhase.available, manifest: manifest);
      if (!await _canDownloadWithoutAsking()) return;
      await _download(manifest, file);
    } on UpdateVerifyException catch (e) {
      // The downloaded file doesn't match the signed manifest: don't install
      _logger.warning('Update did not pass verification, not installing: ${e.message}');
      state = state.copyWith(phase: SmUpdatePhase.verifyFailed, clearManifest: true);
    } catch (e) {
      // The download broke off (_download already went back to "available"): keep it, tapping "Update" downloads again; this
      // used to reset to "check failed" as well
      _logger.info('Update download failed: $e');
      if (state.phase != SmUpdatePhase.available) state = state.copyWith(phase: SmUpdatePhase.checkFailed, clearManifest: true);
    } finally {
      client.close();
    }
  }

  /// "Update" was tapped: download first if needed (on the phone even on mobile data), then install.
  /// Returns false if the installer couldn't be launched (the UI shows a notice).
  Future<bool> update() async {
    final manifest = state.manifest;
    final file = manifest?.files[_platform];
    if (!supported || manifest == null || file == null) return false;
    if (state.phase == SmUpdatePhase.available) {
      try {
        await _download(manifest, file);
      } on UpdateVerifyException catch (e) {
        _logger.warning('Update did not pass verification, not installing: ${e.message}');
        state = state.copyWith(phase: SmUpdatePhase.verifyFailed, clearManifest: true);
        return true;
      } catch (e) {
        _logger.info('Update download failed: $e');
        state = state.copyWith(phase: SmUpdatePhase.available);
        return false;
      }
    }
    final ready = _ready;
    if (state.phase != SmUpdatePhase.ready || ready == null) return false;
    return _install(ready.file, file);
  }

  Future<void> _download(UpdateManifest manifest, UpdateFile file) async {
    final dir = await _installer!.downloadDirectory();
    final target = File('${dir.path}${Platform.pathSeparator}${updateFileName(manifest.build, file.url)}');
    state = state.copyWith(phase: SmUpdatePhase.downloading, progress: 0);
    var lastProgress = 0.0;
    // Log duration and speed (into the desktop diagnostics log, see shareme_diagnostics.dart), so a slow download shows up there.
    // Downloads once crawled at about 117 KB/s while running on the main isolate; see downloadUpdateFileInBackground
    final watch = Stopwatch()..start();
    _logger.info('Downloading ${file.size} bytes for build ${manifest.build}');
    try {
      // Download on a background isolate (see downloadUpdateFileInBackground)
      await downloadUpdateFileInBackground(
        file,
        target,
        onProgress: (received, total) {
          final progress = received / total;
          if (progress - lastProgress >= 0.01 || received == total) {
            lastProgress = progress;
            state = state.copyWith(progress: progress);
          }
        },
      );
    } catch (e) {
      _logger.info('Download stopped after ${watch.elapsedMilliseconds} ms at ${(lastProgress * 100).floor()}%: $e');
      if (state.phase == SmUpdatePhase.downloading) state = state.copyWith(phase: SmUpdatePhase.available);
      rethrow;
    }
    _ready = (manifest: manifest, file: target);
    final ms = watch.elapsedMilliseconds;
    _logger.info('Downloaded and verified ${target.path} in $ms ms (${ms == 0 ? '-' : (file.size / ms).round()} KB/s)');
    state = state.copyWith(phase: SmUpdatePhase.ready, progress: 1);
  }

  Future<bool> _install(File target, UpdateFile file) async {
    // A long time may have passed since the download, so verify again before handing it to the system
    if (!await updateFileMatches(target, file)) {
      _logger.warning('Downloaded file changed since it was verified, not installing');
      await _deleteQuietly(target);
      _ready = null;
      state = state.copyWith(phase: SmUpdatePhase.verifyFailed, clearManifest: true);
      return true;
    }
    state = state.copyWith(phase: SmUpdatePhase.installing);
    final visible = checkPlatformIsDesktop() ? await windowManager.isVisible() : true;
    final result = await _installer!.install(target, appVisible: visible);
    switch (result) {
      case UpdateInstallResult.quitNow:
        // Quit right away, like the tray's "Quit"; the installer is waiting for this process to exit
        await destroyTray();
        CoalescedSave.flushAllBeforeExit(); // Shuttle: write out pending transfer history first
        markCleanExit('update');
        exit(0);
      case UpdateInstallResult.handedOver:
        // The user may have canceled in the system UI, so keep the "Update" button
        state = state.copyWith(phase: SmUpdatePhase.ready);
        return true;
      case UpdateInstallResult.failed:
        state = state.copyWith(phase: SmUpdatePhase.ready);
        return false;
    }
  }

  /// PC: may always download. Phone: downloads automatically only on Wi-Fi or Ethernet (on mobile data it waits for "Update").
  Future<bool> _canDownloadWithoutAsking() async {
    if (!checkPlatform([TargetPlatform.android])) return true;
    try {
      final types = await Connectivity().checkConnectivity();
      return types.contains(ConnectivityResult.wifi) || types.contains(ConnectivityResult.ethernet);
    } catch (_) {
      return false;
    }
  }

  Future<int> _currentBuild() async {
    final info = await PackageInfo.fromPlatform();
    return int.tryParse(info.buildNumber) ?? 0;
  }

  /// At startup, deletes partial downloads and builds that are already installed or older (build number not above the local one).
  /// Fully downloaded newer builds are kept and reused by the next check.
  Future<void> _cleanup() async {
    try {
      final dir = await _installer!.downloadDirectory();
      if (!dir.existsSync()) return;
      final current = await _currentBuild();
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name == 'install.log') continue;
        final build = int.tryParse(RegExp(r'^Shuttle-(\d+)\.').firstMatch(name)?.group(1) ?? '');
        if (name.endsWith('.part') || build == null || build <= current) await _deleteQuietly(entity);
      }
    } catch (e) {
      _logger.info('Update cleanup failed: $e');
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (file.existsSync()) await file.delete();
    } catch (_) {
      // The file is still in use (e.g. the installer just exited); it is deleted on the next launch
    }
  }

  @override
  void dispose() {
    _firstCheck?.cancel();
    _periodicCheck?.cancel();
    super.dispose();
  }
}
