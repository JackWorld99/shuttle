// Shuttle auto-update: how each platform hands the verified new version to the system for installation.
//
// - Windows: run the same Inno Setup installer (support/scripts/shuttle_windows-inno.iss) in "update mode": no dialogs, wait for
//   Shuttle to exit, reopen it when done. Used by both installed and portable builds; portable adds /PORTABLE=1 (no uninstall entry
//   or Start menu entry). Shuttle quits completely after starting the installer.
// - Android: hand over to the system installer (via open_file, just like opening a received APK); the system asks once whether to
//   update the app.
// - macOS: not supported yet. To add it: return the manifest's platform name from [currentUpdatePlatform] (e.g. 'macos-universal')
//   and an [UpdateInstaller] from [updateInstallerForCurrentPlatform] (e.g. using Sparkle, or opening the downloaded dmg).
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localsend_app/util/shared_preferences/shared_preferences_portable.dart';
import 'package:logging/logging.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:win32_registry/win32_registry.dart';

final _logger = Logger('Update');

/// This device's platform name in the manifest's files; null on platforms without auto-update.
String? currentUpdatePlatform() {
  if (kIsWeb) return null;
  final abi = Abi.current();
  if (abi == Abi.windowsX64) return 'windows-x64';
  if (abi == Abi.androidArm64) return 'android-arm64';
  return null;
}

enum UpdateInstallResult {
  /// The system installer is open (Android) and the user confirms in the system UI. Shuttle keeps running.
  handedOver,

  /// The installer was started in the background (Windows); Shuttle must quit now so it can replace the files.
  quitNow,

  /// The installation could not be started.
  failed,
}

abstract class UpdateInstaller {
  /// Where downloaded updates are stored.
  Future<Directory> downloadDirectory();

  /// [appVisible]: whether the window is open on desktop; the app reopens the same way after installing (back to the tray if it was there).
  Future<UpdateInstallResult> install(File file, {required bool appVisible});
}

UpdateInstaller? updateInstallerForCurrentPlatform() {
  switch (currentUpdatePlatform()) {
    case 'windows-x64':
      return WindowsUpdateInstaller();
    case 'android-arm64':
      return AndroidUpdateInstaller();
    default:
      return null;
  }
}

/// Download file name: `Shuttle-<build>.<extension>`, with the extension taken from the download URL.
String updateFileName(int build, String url) {
  final ext = p.extension(Uri.parse(url).path).toLowerCase();
  return 'Shuttle-$build${ext.isEmpty ? '' : ext}';
}

/// Uninstall key for the AppId hard-coded in the Inno Setup installer (support/scripts/shuttle_windows-inno.iss). Shuttle is
/// installed for the current user only, so the uninstall entry is under HKCU.
const shuttleInnoUninstallKey = r'Software\Microsoft\Windows\CurrentVersion\Uninstall\{7840FBA4-023A-4668-BCE2-D17981C43955}_is1';

/// Command line for update mode. [appDir] must not end with a backslash: Inno (Delphi's ParamStr) doesn't understand the `\"` escape.
List<String> windowsInstallerArgs({required String appDir, required bool portable, required bool startHidden, required String logPath}) {
  final dir = appDir.replaceAll(RegExp(r'[\\/]+$'), '');
  return [
    '/VERYSILENT',
    '/SUPPRESSMSGBOXES',
    '/NORESTART',
    '/SHUTTLEUPDATE=1',
    if (portable) '/PORTABLE=1',
    if (startHidden) '/HIDDEN=1',
    '/DIR=$dir',
    '/LOG=$logPath',
  ];
}

/// For comparing paths: strips trailing slashes and normalizes to lowercase with backslashes.
String normalizeWindowsDir(String path) => path.replaceAll('/', r'\').replaceAll(RegExp(r'\\+$'), '').toLowerCase();

/// A folder installed by Inno contains the uninstaller unins000.exe; portable builds (including /PORTABLE=1 updates) don't create it.
const shuttleInnoUninstaller = 'unins000.exe';

/// Whether this is the installed build: the folder contains the uninstaller, or the uninstall entry's location is this folder.
/// Either one is enough.
///
/// Why not only the registry: a process started via WMI can't see this uninstall entry in the user's usual HKCU (the same key is
/// visible from a normally opened PowerShell), so an installed Shuttle was updated as a portable one (the version shown in
/// "Installed apps" stayed old).
bool isInstalledShuttle({required String appDir, required bool hasUninstaller, required String? registeredLocation}) {
  if (hasUninstaller) return true;
  return registeredLocation != null && normalizeWindowsDir(registeredLocation) == normalizeWindowsDir(appDir);
}

class WindowsUpdateInstaller implements UpdateInstaller {
  String get _appDir => File(Platform.resolvedExecutable).parent.path;

  /// Whether the build in this folder is the installed one rather than portable. See [isInstalledShuttle].
  bool _isInstalledHere() {
    final hasUninstaller = File(p.join(_appDir, shuttleInnoUninstaller)).existsSync();
    final registered = _registeredLocation();
    final installed = isInstalledShuttle(appDir: _appDir, hasUninstaller: hasUninstaller, registeredLocation: registered);
    _logger.info(
      'Install mode for $_appDir: ${installed ? 'installed' : 'portable'} (uninstaller: $hasUninstaller, registered location: ${registered ?? 'none'})',
    );
    return installed;
  }

  /// The install location from the uninstall entry; null if there is no entry (or it can't be read).
  String? _registeredLocation() {
    try {
      final key = Registry.openPath(RegistryHive.currentUser, path: shuttleInnoUninstallKey);
      try {
        return key.getStringValue('InstallLocation');
      } finally {
        key.close();
      }
    } catch (_) {
      return null;
    }
  }

  /// In the program folder if settings.json is next to Shuttle.exe (portable mode settings);
  /// otherwise in %LOCALAPPDATA%\Shuttle\updates.
  @override
  Future<Directory> downloadDirectory() async {
    if (SharedPreferencesPortable().exists()) return Directory(p.join(_appDir, 'updates'));
    final local = Platform.environment['LOCALAPPDATA'];
    if (local != null && local.isNotEmpty) return Directory(p.join(local, 'Shuttle', 'updates'));
    return Directory(p.join((await getApplicationSupportDirectory()).path, 'updates'));
  }

  @override
  Future<UpdateInstallResult> install(File file, {required bool appVisible}) async {
    final installed = _isInstalledHere();
    final args = windowsInstallerArgs(
      appDir: _appDir,
      portable: !installed,
      startHidden: !appVisible,
      logPath: p.join(file.parent.path, 'install.log'),
    );
    _logger.info('Starting installer ${file.path} ${args.join(' ')}');
    try {
      await Process.start(file.path, args, mode: ProcessStartMode.detached);
      return UpdateInstallResult.quitNow;
    } catch (e) {
      _logger.warning('Could not start installer', e);
      return UpdateInstallResult.failed;
    }
  }
}

class AndroidUpdateInstaller implements UpdateInstaller {
  /// The app's own cache directory (open_file's FileProvider can hand files there to the system installer).
  @override
  Future<Directory> downloadDirectory() async => Directory(p.join((await getTemporaryDirectory()).path, 'updates'));

  /// The first time, the user must allow Shuttle to install apps in system settings (upstream already declares REQUEST_INSTALL_PACKAGES).
  @override
  Future<UpdateInstallResult> install(File file, {required bool appVisible}) async {
    try {
      final result = await OpenFile.open(file.path, type: 'application/vnd.android.package-archive');
      if (result.type == ResultType.done) return UpdateInstallResult.handedOver;
      _logger.warning('System installer did not open: ${result.type} ${result.message}');
      return UpdateInstallResult.failed;
    } catch (e) {
      _logger.warning('Could not open the system installer', e);
      return UpdateInstallResult.failed;
    }
  }
}
