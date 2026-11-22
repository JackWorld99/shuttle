// Shuttle: protection against harmful received files.
//
// 1. On desktop, files from unknown devices get the Mark of the Web, like browser downloads: a Zone.Identifier stream is written
//    alongside the file with ZoneId=3 (Internet). Double-clicking an executable in Explorer then shows a SmartScreen warning, Office
//    files open in Protected View, and files extracted from a marked archive are marked too.
//    Same approach as Chromium (components/services/quarantine/quarantine_win.cc: HostUrl=about:internet when the source URL is unknown).
//    Files from "My devices" are not marked: they are your own devices, and with the mark every Word file from your own phone would
//    need "Enable Editing". Only verified "My devices" are exempt (isVerifiedMine in paired_devices_provider.dart); devices added
//    with just "Add" are still marked.
// 2. Executable-type files (see [runnableExtensions]) are never "opened" in the app, only shown in their folder, whoever sent them.
//    On Windows, opening such a file runs it.
import 'dart:io';

import 'package:logging/logging.dart';

final _logger = Logger('FileSafety');

/// File types that run a program or change system settings when opened (Windows).
/// Based on Chromium's list of dangerous download types (components/safe_browsing/content/resources/download_file_types.asciipb,
/// those marked dangerous on Windows) and the "high risk" types of the Windows Attachment Manager. Only the last extension is
/// compared, so "photo.jpg.exe" counts too. Also includes the attachment types blocked by Outlook (support.microsoft.com "Blocked
/// attachments in Outlook") that run something or change settings when opened, plus types missing from that list but actually used
/// in recent attacks (rdp, searchconnector-ms, themepack, ppkg, vsto). Not included: types that only display content when opened
/// (tmp, pst, cab, mht, asp, etc.). Android doesn't rely on this list: installing an APK always takes another tap in the system installer.
const runnableExtensions = {
  // Programs and installers
  'exe', 'com', 'scr', 'pif', 'cpl', 'msi', 'msp', 'mst', 'msu', 'msix', 'msixbundle', 'appx', 'appxbundle', 'appinstaller',
  'application', 'appref-ms', 'xbap', 'vsto', 'jnlp', 'gadget', 'msc', 'xll', 'diagcab', 'ppkg', 'printerexport', 'webpnp',
  'app', 'prg', 'fxp', 'osd',
  // Scripts (sh: on a PC with Git installed, double-clicking runs it in Git Bash)
  'bat', 'cmd', 'ps1', 'psm1', 'psd1', 'ps1xml', 'ps2', 'ps2xml', 'psc1', 'psc2', 'pssc', 'cdxml',
  'msh', 'msh1', 'msh2', 'mshxml', 'msh1xml', 'msh2xml', 'vb', 'vbs', 'vbe', 'vbp', 'bas', 'js', 'jse', 'wsf', 'wsh', 'wsc', 'ws',
  'sct', 'hta', 'htc', 'shb', 'shs', 'jar', 'py', 'pyw', 'pyc', 'pyo', 'pyz', 'pyzw', 'pl', 'sh', 'bash', 'csh', 'ksh',
  'vsmacros', 'vsw',
  // Shortcuts, Remote Desktop, registry, and settings files that are executed directly
  'lnk', 'url', 'website', 'rdp', 'scf', 'reg', 'inf', 'ins', 'isp', 'udl', 'prf', 'ops', 'xnk', 'grp', 'wsb', 'library-ms',
  'search-ms', 'searchconnector-ms', 'settingcontent-ms', 'appcontent-ms', 'theme', 'themepack', 'desktopthemepackfile',
  'chm', 'hlp', 'hpj', 'cnt', 'its', 'mcf', 'plg', 'bgi', 'pcd',
  // Certificates: opening one starts "Install Certificate", and an installed root certificate lets someone impersonate any website
  'cer', 'crt', 'der',
  // Access databases and their shortcuts: can run macros when opened
  'ade', 'adp', 'mad', 'maf', 'mag', 'mam', 'maq', 'mar', 'mas', 'mat', 'mau', 'mav', 'maw', 'mda', 'mdb', 'mde', 'mdt', 'mdw',
  'mdz',
  // Disk images: opening one mounts it, and programs inside used to bypass the Mark of the Web
  'iso', 'img', 'vhd', 'vhdx',
};

/// The last extension of a file name or path (lowercase, without the dot); an empty string if there is none.
String lastExtension(String nameOrPath) {
  final name = nameOrPath.split(RegExp(r'[\\/]')).last.trimRight();
  // Windows ignores trailing dots and spaces in file names ("a.exe." opens a.exe)
  final trimmed = name.replaceAll(RegExp(r'[. ]+$'), '');
  final dot = trimmed.lastIndexOf('.');
  return dot <= 0 ? '' : trimmed.substring(dot + 1).toLowerCase();
}

/// Whether opening the file runs a program (see [runnableExtensions]).
bool isRunnableFile(String nameOrPath) => runnableExtensions.contains(lastExtension(nameOrPath));

/// Content of the Mark of the Web (the Zone.Identifier stream).
const zoneIdentifierInternet = '[ZoneTransfer]\r\nZoneId=3\r\nHostUrl=about:internet\r\n';

/// Adds the Mark of the Web to [path]. Only on Windows and for plain file paths (not Android content:// URIs). Drives that aren't
/// NTFS (e.g. a FAT32 USB stick) can't store it; failures are only logged and don't affect receiving. Returns whether it was written.
Future<bool> markFromInternet(String path) async {
  if (!Platform.isWindows || path.startsWith('content://')) return false;
  try {
    await File('$path:Zone.Identifier').writeAsString(zoneIdentifierInternet, flush: true);
    return true;
  } catch (e) {
    _logger.warning('Could not mark $path as downloaded from the internet', e);
    return false;
  }
}
