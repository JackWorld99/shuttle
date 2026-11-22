import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/pages/language_page.dart';
import 'package:localsend_app/pages/shareme_pair_host_page.dart';
import 'package:localsend_app/pages/shareme_pair_scan_page.dart';
import 'package:localsend_app/pages/shareme_verify_device.dart';
import 'package:localsend_app/pages/tabs/send_tab_vm.dart';
import 'package:localsend_app/pages/tabs/settings_tab.dart';
import 'package:localsend_app/pages/tabs/settings_tab_controller.dart';
import 'package:localsend_app/pages/web_share_page.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/paired_devices_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/shareme_update_provider.dart';
import 'package:localsend_app/provider/version_provider.dart';
import 'package:localsend_app/util/i18n.dart';
import 'package:localsend_app/util/native/autostart_helper.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/native/macos_channel.dart';
import 'package:localsend_app/util/native/pick_directory_path.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/shareme_format.dart';
import 'package:localsend_app/util/shareme_pairing/pair_crypto.dart' show isTailscaleIp;
import 'package:localsend_app/widget/dialogs/pin_dialog.dart';
import 'package:localsend_app/widget/shareme/confirm_remove_device.dart';
import 'package:localsend_app/widget/shareme/device_avatar.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// The "Settings" tab, kept light on text:
///
/// - Each row on the main page shows only a name and the current value, no explanations: this device, Receive (including
///   a "Background receiving" row), My devices, General (theme, language, More).
/// - Rarely changed settings go under "More": receive from a browser, receive PIN, history, across networks (Tailscale),
///   this device's fingerprint, version, open-source licenses, plus LocalSend's original settings page (port,
///   encryption…; nothing is lost, and merging LocalSend updates stays easy).
/// - "Background receiving" (guidance only for now; always-on receiving comes later) shows how many items are missing and
///   opens a per-item page: the notification and battery optimization states can be read; Xiaomi autostart and battery
///   saver can't, so they only get a shortcut, never a "done" claim that can't be guaranteed.
class SmSettingsPage extends StatefulWidget {
  const SmSettingsPage({super.key});

  @override
  State<SmSettingsPage> createState() => _SmSettingsPageState();
}

class _SmSettingsPageState extends State<SmSettingsPage> with Refena, WidgetsBindingObserver {
  PermissionStatus? _notification;
  PermissionStatus? _battery;
  PermissionStatus? _mediaLocation;

  /// PC: whether start at sign-in is on (null = not read yet / not a PC)
  bool? _autoStart;

  bool get _android => checkPlatform([TargetPlatform.android]);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // ignore: discarded_futures
    _refreshStatus();
    // ignore: discarded_futures
    _readAutoStart();
  }

  /// Start at sign-in used to be hidden in LocalSend's original settings and off by default, so after a reboot nothing
  /// arrived until someone opened Shuttle. It now lives in the main settings, still off by default.
  Future<void> _readAutoStart() async {
    if (!checkPlatformIsDesktop()) return;
    try {
      final enabled = await isAutoStartEnabled();
      if (mounted) setState(() => _autoStart = enabled);
    } catch (_) {
      // If it can't be read, hide this row
    }
  }

  /// When on, Shuttle starts minimized to the tray after sign-in, ready to receive (no window)
  Future<void> _setAutoStart(bool enabled) async {
    final ok = enabled ? await enableAutoStart(startHidden: true) : await disableAutoStart();
    if (ok && mounted) setState(() => _autoStart = enabled);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Re-read the status when coming back from the system settings
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // ignore: discarded_futures
      _refreshStatus();
    }
  }

  Future<void> _refreshStatus() async {
    if (!_android) return;
    try {
      final notification = await Permission.notification.status;
      final battery = await Permission.ignoreBatteryOptimizations.status;
      final mediaLocation = await Permission.accessMediaLocation.status;
      if (!mounted) return;
      setState(() {
        _notification = notification;
        _battery = battery;
        _mediaLocation = mediaLocation;
      });
    } catch (_) {
      // If it can't be read, show no status
    }
  }

  Future<void> _request(Permission permission, PermissionStatus? current) async {
    if (current == PermissionStatus.permanentlyDenied) {
      await openAppSettings();
    } else {
      await permission.request();
    }
    await _refreshStatus();
  }

  Future<void> _rename(String current) async {
    final controller = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.shareme.settings.rename),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: InputDecoration(hintText: t.shareme.settings.renameHint),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.shareme.settings.cancel)),
          TextButton(onPressed: () => Navigator.of(context).pop(controller.text), child: Text(t.shareme.settings.save)),
        ],
      ),
    );
    controller.dispose();
    final alias = name?.trim();
    if (alias == null || alias.isEmpty || alias == current || !mounted) return;
    await ref.notifier(settingsProvider).setAlias(alias);
    if (!mounted) return;
    // Same as LocalSend: a rename restarts the receive server so nearby devices see the new name
    ref.read(settingsTabControllerProvider).onTapRestartServer(context);
  }

  Future<void> _pickReceiveMode() async {
    final settings = ref.read(settingsProvider);
    final current = settings.quickSave
        ? _ReceiveMode.all
        : settings.quickSaveFromFavorites
        ? _ReceiveMode.favorites
        : _ReceiveMode.ask;
    final mode = await showModalBottomSheet<_ReceiveMode>(
      context: context,
      useSafeArea: true,
      builder: (context) => _ReceiveModeSheet(current: current),
    );
    if (mode == null || mode == current) return;
    final notifier = ref.notifier(settingsProvider);
    await notifier.setQuickSave(mode == _ReceiveMode.all);
    await notifier.setQuickSaveFromFavorites(mode == _ReceiveMode.favorites);
  }

  Future<void> _pickDestination() async {
    final directory = await pickDirectoryPath();
    if (directory != null) {
      // macOS sandbox: the picked folder is only writable for this run, so store a bookmark to keep access after a restart
      // (as in the upstream settings page).
      if (checkPlatform([TargetPlatform.macOS])) {
        await persistDestinationFolderAccess(directory);
      }
      await ref.notifier(settingsProvider).setDestination(directory);
    }
  }

  Future<void> _resetDestination() async {
    if (checkPlatform([TargetPlatform.macOS])) {
      await removeExistingDestinationAccess();
    }
    await ref.notifier(settingsProvider).setDestination(null);
  }

  Future<void> _removeFavorite(FavoriteDevice f) async {
    final ok = await confirmRemoveDevice(context, f.alias);
    if (ok && mounted) {
      ref.redux(favoritesProvider).dispatch(RemoveFavoriteAction(deviceFingerprint: f.fingerprint));
      ref.redux(pairedDevicesProvider).dispatch(RemovePairedRecordAction(f.fingerprint)); // drop its verification record too
    }
  }

  Future<void> _onUpdate() async => startShuttleUpdate(context, ref);

  Future<void> _pickTheme() async {
    final current = ref.read(settingsProvider).theme;
    final mode = await showModalBottomSheet<ThemeMode>(
      context: context,
      useSafeArea: true,
      builder: (context) => _ChoiceSheet<ThemeMode>(
        title: t.shareme.settings.theme,
        current: current,
        options: {
          ThemeMode.system: t.shareme.settings.themeSystem,
          ThemeMode.light: t.shareme.settings.themeLight,
          ThemeMode.dark: t.shareme.settings.themeDark,
        },
      ),
    );
    if (mode != null && mode != current) await ref.notifier(settingsProvider).setTheme(mode);
  }

  /// A row under "My devices". Verified devices get a small green check on the avatar, so no "verified" text here;
  /// unverified ones (whose files aren't auto-accepted) say "Not verified", with a "Verify" button on the right when possible.
  Widget _deviceRow(FavoriteDevice f, {required bool verified, required Device? online}) {
    final c = context.sm;
    final s = t.shareme.settings;
    final verifyPage = verified ? null : verifyPageFor(peerType: knownDeviceType(f.fingerprint), online: online);
    final remove = IconButton(
      tooltip: s.remove,
      icon: Icon(LucideIcons.x, size: 20, color: c.ink3),
      onPressed: () async => _removeFavorite(f),
    );
    return _Row(
      lead: DeviceAvatar(
        deviceType: knownDeviceType(f.fingerprint),
        size: 40,
        mine: true,
        verified: verified,
        offline: online == null,
      ),
      title: f.alias,
      titleStyle: ShareMeText.deviceNameSm.copyWith(color: online != null ? c.ink : c.ink2),
      subtitle: [online != null ? s.online : s.offline, if (!verified) t.shareme.home.unverified].join(' · '),
      trailing: verifyPage == null
          ? remove
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(onPressed: () async => context.push(verifyPage), child: Text(s.verify)),
                remove,
              ],
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final settings = context.watch(settingsProvider);
    final server = context.watch(serverProvider);
    final favorites = context.watch(favoritesProvider);
    final verified = verifiedFingerprints(context.watch(pairedDevicesProvider));
    final updateState = context.watch(smUpdateProvider);
    final nearby = context.watch(sendTabVmProvider).nearbyDevices;
    final alias = server?.alias ?? settings.alias;
    final s = t.shareme.settings;

    // The second option auto-accepts only from verified devices in "My devices"
    final receiveMode = settings.quickSave
        ? s.modeAllShort
        : settings.quickSaveFromFavorites
        ? s.modeVerifiedShort
        : s.modeAskShort;
    // How many of the two readable items (notifications, battery optimization) aren't set up yet
    final backgroundMissing = [_notification, _battery].where((p) => p != null && !p.isGranted).length;
    final theme = switch (settings.theme) {
      ThemeMode.light => s.themeLight,
      ThemeMode.dark => s.themeDark,
      ThemeMode.system => s.themeSystem,
    };

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 14, 22, 6),
          child: Text(s.title, style: ShareMeText.headline.copyWith(color: c.ink)),
        ),

        // Auto-update: a new version only shows up as a row here (no popup); a failed verification is reported here too
        if (updateState.hasNewVersion || updateState.phase == SmUpdatePhase.verifyFailed) ...[
          _UpdateBanner(state: updateState, onUpdate: _onUpdate),
          const SizedBox(height: 14),
        ],

        // This device: avatar + name (as others see it) + rename
        _Group(
          children: [
            _Row(
              lead: DeviceAvatar(deviceType: checkPlatformIsDesktop() ? DeviceType.desktop : DeviceType.mobile, size: 46, mine: true),
              title: alias,
              titleStyle: ShareMeText.deviceName.copyWith(color: c.ink),
              subtitle: s.renameHint,
              trailing: IconButton(
                tooltip: s.rename,
                style: IconButton.styleFrom(backgroundColor: c.tonal),
                icon: Icon(LucideIcons.pen, size: 18, color: c.ink),
                onPressed: () async => _rename(alias),
              ),
              onTap: () async => _rename(alias),
            ),
          ],
        ),

        // Receive
        _SectionTitle(s.receive),
        _Group(
          children: [
            _Row(title: s.whenReceiving, value: receiveMode, trailing: const _Chevron(), onTap: _pickReceiveMode),
            if (checkPlatformWithFileSystem())
              _Row(
                title: s.saveTo,
                value: _folderName(settings.destination),
                trailing: settings.destination != null
                    ? TextButton(
                        onPressed: _resetDestination,
                        child: Text(s.resetLocation),
                      )
                    : const _Chevron(),
                onTap: _pickDestination,
              ),
            if (checkPlatformWithGallery())
              _Row(
                title: s.galleryShort,
                trailing: Switch(value: settings.saveToGallery, onChanged: (v) async => ref.notifier(settingsProvider).setSaveToGallery(v)),
                onTap: () async => ref.notifier(settingsProvider).setSaveToGallery(!settings.saveToGallery),
              ),
            if (_android && _mediaLocation != null)
              _Row(
                title: s.keepLocationShort,
                value: _mediaLocation!.isGranted ? s.turnedOn : s.turnOn,
                valueColor: _mediaLocation!.isGranted ? null : c.warn,
                trailing: _mediaLocation!.isGranted ? null : const _Chevron(),
                onTap: _mediaLocation!.isGranted ? null : () async => _request(Permission.accessMediaLocation, _mediaLocation),
              ),
            if (_android)
              _Row(
                title: s.background,
                value: backgroundMissing > 0 ? s.missing(n: backgroundMissing) : s.view,
                valueColor: backgroundMissing > 0 ? c.warn : null,
                trailing: const _Chevron(),
                onTap: () async {
                  await context.push(() => const _BackgroundPage());
                  await _refreshStatus();
                },
              ),
          ],
        ),

        // My devices
        _SectionTitle(s.devices),
        _Group(
          children: [
            if (favorites.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Text(s.devicesEmpty, style: ShareMeText.meta.copyWith(color: c.ink2)),
              ),
            for (final f in favorites)
              _deviceRow(f, verified: verified.contains(f.fingerprint), online: nearby.firstWhereOrNull((d) => d.fingerprint == f.fingerprint)),
            _Row(
              lead: const DeviceAvatar(size: 40, icon: LucideIcons.plus),
              title: t.shareme.home.addDevice,
              onTap: () async => context.push(() => checkPlatformIsDesktop() ? const SmPairHostPage() : const SmPairScanPage()),
            ),
          ],
        ),

        // General
        _SectionTitle(s.general),
        _Group(
          children: [
            if (_autoStart != null)
              _Row(
                title: s.autoStart,
                subtitle: s.autoStartNote,
                trailing: Switch(value: _autoStart!, onChanged: (v) async => _setAutoStart(v)),
                onTap: () async => _setAutoStart(!_autoStart!),
              ),
            _Row(title: s.theme, value: theme, trailing: const _Chevron(), onTap: _pickTheme),
            _Row(
              title: s.language,
              value: settings.locale?.getLocaleName() ?? s.languageSystem,
              trailing: const _Chevron(),
              onTap: () async => context.push(() => const LanguagePage()),
            ),
            _Row(title: s.moreShort, trailing: const _Chevron(), onTap: () async => context.push(() => const _SmMorePage())),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 0),
          child: Text(
            s.footer,
            style: ShareMeText.meta.copyWith(color: c.ink3),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

/// Tapping "Update" (the row at the top of Settings, or the row under "More" once a new version is found): doesn't install
/// during a transfer (on the PC, quitting would cut the transfer off).
Future<void> startShuttleUpdate(BuildContext context, Ref ref) async {
  final update = ref.notifier(smUpdateProvider);
  final u = t.shareme.update;
  void snack(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
  if (update.transferActive) {
    snack(u.busy);
    return;
  }
  final ok = await update.update();
  if (!ok && context.mounted) snack(ref.read(smUpdateProvider).phase == SmUpdatePhase.available ? u.downloadFailed : u.openFailed);
}

/// The "New version … · Update" row at the top of Settings.
class _UpdateBanner extends StatelessWidget {
  final SmUpdateState state;
  final Future<void> Function() onUpdate;

  const _UpdateBanner({required this.state, required this.onUpdate});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final u = t.shareme.update;
    if (state.phase == SmUpdatePhase.verifyFailed) {
      return _Group(
        children: [
          _Row(
            lead: _Lead(icon: LucideIcons.triangleAlert, color: c.warn, background: c.warnContainer),
            title: u.verifyFailed,
            titleStyle: ShareMeText.body.copyWith(color: c.warn, fontWeight: FontWeight.w500, fontSize: 15.5),
          ),
        ],
      );
    }
    final busy = state.phase == SmUpdatePhase.downloading || state.phase == SmUpdatePhase.installing;
    return _Group(
      children: [
        _Row(
          lead: _Lead(icon: LucideIcons.circleArrowUp, color: c.accent),
          // Include the build number: two releases from the same day share a date, so the date alone can't tell them apart
          title: u.available(
            version: u.versionBuild(version: state.manifest!.version, build: '${state.manifest!.build}'),
          ),
          subtitle: switch (state.phase) {
            SmUpdatePhase.downloading => u.downloading(percent: (state.progress * 100).floor()),
            SmUpdatePhase.installing => u.installing,
            _ => null,
          },
          trailing: FilledButton(onPressed: busy ? null : onUpdate, child: Text(u.install)),
          onTap: busy ? null : onUpdate,
        ),
      ],
    );
  }
}

/// The save location shows only the last folder name (the full path is visible when picking)
String _folderName(String? destination) {
  // The default is the system downloads folder (Download on Android, Downloads on Windows and macOS). Show its localized
  // name: Windows Explorer shows it localized too, and the English "Downloads" made it look like a different folder.
  if (destination == null) return t.shareme.settings.defaultDownloads;
  final parts = destination.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).toList();
  return parts.isEmpty ? destination : parts.last;
}

/// "More": rarely changed settings. Each row may have a short description.
class _SmMorePage extends StatefulWidget {
  const _SmMorePage();

  @override
  State<_SmMorePage> createState() => _SmMorePageState();
}

class _SmMorePageState extends State<_SmMorePage> with Refena {
  /// Like LocalSend's "Require PIN" setting: turning it off clears the PIN; turning it on asks for one first. The Rust server
  /// checks the PIN, so it only takes effect after a server restart.
  Future<void> _toggleReceivePin() async {
    if (ref.read(settingsProvider).receivePin != null) {
      await ref.notifier(settingsProvider).setReceivePin(null);
    } else {
      final pin = await showDialog<String>(
        context: context,
        builder: (_) => const PinDialog(obscureText: false, generateRandom: false),
      );
      if (pin == null || pin.isEmpty) return;
      await ref.notifier(settingsProvider).setReceivePin(pin);
    }
    if (ref.read(serverProvider) != null) {
      await ref.notifier(serverProvider).restartServerFromSettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final s = t.shareme.settings;
    final settings = context.watch(settingsProvider);
    final fingerprint = context.watch(securityProvider).certificateHash;
    final tailscaleIp = context.watch(localIpProvider).localIps.firstWhereOrNull(isTailscaleIp);
    final version = context.watch(versionProvider);
    final updateState = context.watch(smUpdateProvider);
    final update = ref.notifier(smUpdateProvider);
    final u = t.shareme.update;
    final updateBusy = updateState.phase == SmUpdatePhase.downloading || updateState.phase == SmUpdatePhase.installing;
    return Scaffold(
      appBar: AppBar(title: Text(s.moreShort)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _SectionTitle(s.receive),
          _Group(
            children: [
              // Surfaces LocalSend's existing "receive via link" and "receive PIN" options
              _Row(
                title: s.receiveLink,
                subtitle: s.receiveLinkNote,
                trailing: const _Chevron(),
                onTap: () async => context.push(() => const WebSharePage()),
              ),
              _Row(
                title: s.receivePin,
                subtitle: s.receivePinNote,
                trailing: Switch(value: settings.receivePin != null, onChanged: (_) async => _toggleReceivePin()),
                onTap: _toggleReceivePin,
              ),
              _Row(
                title: s.saveToHistoryShort,
                trailing: Switch(value: settings.saveToHistory, onChanged: (v) async => ref.notifier(settingsProvider).setSaveToHistory(v)),
                onTap: () async => ref.notifier(settingsProvider).setSaveToHistory(!settings.saveToHistory),
              ),
            ],
          ),

          // Across networks: via Tailscale (instead of running our own signaling server)
          _SectionTitle(s.crossNetwork),
          _Group(
            children: [
              _Row(
                lead: _Lead(icon: LucideIcons.globe, color: tailscaleIp == null ? c.ink3 : c.ok),
                title: s.tailscaleRow,
                value: tailscaleIp == null ? s.tailscaleNotConnected : '${s.tailscaleConnected} · $tailscaleIp',
              ),
            ],
          ),
          _Note(s.crossNetworkNote),

          _SectionTitle(s.thisDevice),
          _Group(
            children: [
              _Row(
                title: s.fingerprintLabel,
                subtitleWidget: Text(groupFingerprint(fingerprint), style: ShareMeText.data.copyWith(color: c.ink2)),
              ),
            ],
          ),

          _SectionTitle(s.about),
          _Group(
            children: [
              // Only the version and build number on the right (combined into one line, phones cut it to "2026.11.16 (2268…").
              // The "Based on LocalSend" attribution is on the "Open-source licenses" page (the UI doesn't name LocalSend, but
              // the attribution stays).
              _Row(
                title: s.version,
                value: version.maybeWhen(
                  data: (v) => t.shareme.update.versionBuild(version: v.version, build: v.buildNumber),
                  orElse: () => '',
                ),
              ),
              // Shuttle: auto-update (Windows, Android; not wired up on macOS yet)
              if (update.supported) ...[
                // Once a new version is found, this row becomes "New version … (…) · Update": it used to say only "New
                // version available", which read as already updated, while the "Update" button was at the top of Settings
                if (updateState.hasNewVersion && updateState.manifest != null)
                  _Row(
                    title: u.available(
                      version: u.versionBuild(version: updateState.manifest!.version, build: '${updateState.manifest!.build}'),
                    ),
                    subtitle: switch (updateState.phase) {
                      SmUpdatePhase.downloading => u.downloading(percent: (updateState.progress * 100).floor()),
                      SmUpdatePhase.installing => u.installing,
                      _ => null,
                    },
                    trailing: FilledButton(
                      onPressed: updateBusy ? null : () async => startShuttleUpdate(context, ref),
                      child: Text(u.install),
                    ),
                    onTap: updateBusy ? null : () async => startShuttleUpdate(context, ref),
                  )
                else
                  _Row(
                    title: u.check,
                    value: switch (updateState.phase) {
                      SmUpdatePhase.checking => u.checking,
                      SmUpdatePhase.upToDate => u.upToDate,
                      SmUpdatePhase.checkFailed => u.checkFailed,
                      SmUpdatePhase.verifyFailed => u.verifyFailed,
                      _ => null,
                    },
                    valueColor: updateState.phase == SmUpdatePhase.verifyFailed ? c.warn : null,
                    onTap: updateState.phase == SmUpdatePhase.checking ? null : () async => update.check(),
                  ),
                _Row(
                  title: u.auto,
                  trailing: Switch(value: updateState.autoCheck, onChanged: (v) async => update.setAutoCheck(v)),
                  onTap: () async => update.setAutoCheck(!updateState.autoCheck),
                ),
              ],
              _Row(
                title: s.license,
                trailing: const _Chevron(),
                onTap: () => showLicensePage(context: context, applicationName: 'Shuttle', applicationLegalese: s.licenseNote),
              ),
              _Row(
                title: s.localsendSettings,
                subtitle: s.localsendSettingsNote,
                trailing: const _Chevron(),
                onTap: () async => context.push(() => const _MoreSettingsPage()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "Background receiving": per-item explanations with one-tap fixes (Android only).
class _BackgroundPage extends StatefulWidget {
  const _BackgroundPage();

  @override
  State<_BackgroundPage> createState() => _BackgroundPageState();
}

class _BackgroundPageState extends State<_BackgroundPage> with WidgetsBindingObserver {
  PermissionStatus? _notification;
  PermissionStatus? _battery;
  bool _xiaomi = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // ignore: discarded_futures
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Re-read the status when coming back from the system settings
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // ignore: discarded_futures
      _refresh();
    }
  }

  Future<void> _refresh() async {
    try {
      final notification = await Permission.notification.status;
      final battery = await Permission.ignoreBatteryOptimizations.status;
      final xiaomi = await android_channel.isXiaomiAndroid();
      if (!mounted) return;
      setState(() {
        _notification = notification;
        _battery = battery;
        _xiaomi = xiaomi;
      });
    } catch (_) {
      // If it can't be read, show no status
    }
  }

  Future<void> _openMiui(Future<String> Function() open) async {
    final opened = await open();
    if (opened == 'appDetails' && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(t.shareme.settings.openedAppDetails)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = t.shareme.settings;
    return Scaffold(
      appBar: AppBar(title: Text(s.background)),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          _Group(
            children: [
              if (_notification != null)
                _StatusRow(
                  title: s.notifications,
                  ok: _notification!.isGranted,
                  okText: s.notificationsOn,
                  notOkText: s.notificationsOff,
                  onTap: _notification!.isGranted
                      ? null
                      : () async {
                          if (_notification == PermissionStatus.permanentlyDenied) {
                            await openAppSettings();
                          } else {
                            await Permission.notification.request();
                          }
                          await _refresh();
                        },
                ),
              if (_battery != null)
                _StatusRow(
                  title: s.battery,
                  ok: _battery!.isGranted,
                  okText: s.batteryOn,
                  notOkText: s.batteryOff,
                  onTap: _battery!.isGranted
                      ? null
                      : () async {
                          // Not permission_handler's request: on Xiaomi it pops up an app chooser instead; see MainActivity
                          await android_channel.requestIgnoreBatteryOptimizationsAndroid();
                          await _refresh();
                        },
                ),
              if (_xiaomi) ...[
                _Row(
                  lead: const _Lead(icon: LucideIcons.rocket),
                  title: s.autostart,
                  trailing: const _External(),
                  onTap: () async => _openMiui(android_channel.openAutostartSettingsAndroid),
                ),
                _Row(
                  lead: const _Lead(icon: LucideIcons.batteryCharging),
                  title: s.powerSaver,
                  trailing: const _External(),
                  onTap: () async => _openMiui(android_channel.openBatterySaverSettingsAndroid),
                ),
              ],
            ],
          ),
          if (_xiaomi) _Note(s.backgroundPageNote),
          _Note(s.backgroundLimit),
        ],
      ),
    );
  }
}

/// Single choice in a bottom sheet (theme etc.).
class _ChoiceSheet<T> extends StatelessWidget {
  final String title;
  final T current;
  final Map<T, String> options;

  const _ChoiceSheet({required this.title, required this.current, required this.options});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(title, style: ShareMeText.title.copyWith(color: c.ink, fontSize: 18)),
            ),
            for (final e in options.entries)
              ListTile(
                leading: Icon(e.key == current ? LucideIcons.circleCheck : LucideIcons.circle, color: e.key == current ? c.accent : c.ink3),
                title: Text(
                  e.value,
                  style: ShareMeText.body.copyWith(color: c.ink, fontWeight: FontWeight.w500),
                ),
                onTap: () => Navigator.of(context).pop(e.key),
              ),
          ],
        ),
      ),
    );
  }
}

/// A small gray note below a group (only used on the "More" and "Background receiving" pages).
class _Note extends StatelessWidget {
  final String text;

  const _Note(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 10, 28, 0),
      child: Text(text, style: ShareMeText.meta.copyWith(color: context.sm.ink2, fontSize: 12.5)),
    );
  }
}

enum _ReceiveMode { favorites, ask, all }

/// The three "When files arrive" options. "Accept from every device" spells out its risk in amber.
class _ReceiveModeSheet extends StatelessWidget {
  final _ReceiveMode current;

  const _ReceiveModeSheet({required this.current});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final s = t.shareme.settings;
    Widget option(_ReceiveMode mode, String title, {String? warn}) {
      final selected = mode == current;
      return ListTile(
        leading: Icon(selected ? LucideIcons.circleCheck : LucideIcons.circle, color: selected ? c.accent : c.ink3),
        title: Text(
          title,
          style: ShareMeText.body.copyWith(color: c.ink, fontWeight: FontWeight.w500),
        ),
        subtitle: warn == null ? null : Text(warn, style: ShareMeText.meta.copyWith(color: c.warn)),
        onTap: () => Navigator.of(context).pop(mode),
      );
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(s.whenReceiving, style: ShareMeText.title.copyWith(color: c.ink, fontSize: 18)),
            ),
            option(_ReceiveMode.favorites, s.modeVerified),
            option(_ReceiveMode.ask, s.modeAsk),
            option(_ReceiveMode.all, s.modeAll, warn: s.modeAllWarn),
          ],
        ),
      ),
    );
  }
}

/// "More settings": LocalSend's original settings page, unchanged.
class _MoreSettingsPage extends StatelessWidget {
  const _MoreSettingsPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t.shareme.settings.more)),
      body: const SettingsTab(),
    );
  }
}

// ───────────────────────── Widgets ─────────────────────────

class _SectionTitle extends StatelessWidget {
  final String title;

  const _SectionTitle(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 22, 16, 8),
      child: Text(title, style: ShareMeText.section.copyWith(color: context.sm.ink2)),
    );
  }
}

class _Group extends StatelessWidget {
  final List<Widget> children;

  const _Group({required this.children});

  static bool _hasLead(Widget w) => w is _StatusRow || (w is _Row && w.lead != null);

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: DecoratedBox(
        decoration: smCardDecoration(c),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(ShareMeSize.radiusGroup),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) Divider(height: 1, thickness: 1, indent: _hasLead(children[i]) ? 70 : 16, color: c.line),
                  children[i],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Settings row: [leading icon] title / (description)  [current value] [trailing], min height 56. The main page only uses
/// "title + current value"; descriptions are only used on sub-pages.
class _Row extends StatelessWidget {
  final Widget? lead;
  final String title;
  final TextStyle? titleStyle;
  final String? subtitle;
  final Widget? subtitleWidget;
  final Color? subtitleColor;

  /// The gray current value on the right (e.g. "My devices: automatic")
  final String? value;
  final Color? valueColor;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _Row({
    required this.title,
    this.lead,
    this.titleStyle,
    this.subtitle,
    this.subtitleWidget,
    this.subtitleColor,
    this.value,
    this.valueColor,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final sub = subtitleWidget ?? (subtitle == null ? null : Text(subtitle!, style: ShareMeText.meta.copyWith(color: subtitleColor ?? c.ink2)));
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              if (lead != null) ...[lead!, const SizedBox(width: 14)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: titleStyle ?? ShareMeText.body.copyWith(color: c.ink, fontWeight: FontWeight.w500, fontSize: 15.5),
                    ),
                    if (sub != null) ...[const SizedBox(height: 2), sub],
                  ],
                ),
              ),
              if (value != null) ...[
                const SizedBox(width: 12),
                // Right-aligned: Flexible takes the right part and Align pins the value to the edge ("On" used to float mid-row)
                Flexible(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      value!,
                      style: ShareMeText.meta.copyWith(color: valueColor ?? c.ink2, fontSize: 14),
                      textAlign: TextAlign.end,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
              if (trailing != null) ...[const SizedBox(width: 6), trailing!],
            ],
          ),
        ),
      ),
    );
  }
}

/// An item whose real status can be read: a green check when OK, otherwise an amber warning + tap to fix it.
class _StatusRow extends StatelessWidget {
  final String title;
  final bool ok;
  final String okText;
  final String notOkText;
  final VoidCallback? onTap;

  const _StatusRow({required this.title, required this.ok, required this.okText, required this.notOkText, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return _Row(
      lead: ok ? _Lead(icon: LucideIcons.check, color: c.ok) : _Lead(icon: LucideIcons.triangleAlert, color: c.warn, background: c.warnContainer),
      title: title,
      titleStyle: ok ? null : ShareMeText.body.copyWith(color: c.warn, fontWeight: FontWeight.w500, fontSize: 15.5),
      subtitle: ok ? okText : notOkText,
      subtitleColor: ok ? null : c.warn,
      trailing: onTap == null ? null : const _External(),
      onTap: onTap,
    );
  }
}

class _Lead extends StatelessWidget {
  final IconData icon;
  final Color? color;
  final Color? background;

  const _Lead({required this.icon, this.color, this.background});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(color: background ?? c.tonal, borderRadius: BorderRadius.circular(12)),
      alignment: Alignment.center,
      child: Icon(icon, size: 20, color: color ?? c.ink),
    );
  }
}

class _Chevron extends StatelessWidget {
  const _Chevron();

  @override
  Widget build(BuildContext context) => Icon(LucideIcons.chevronRight, size: 20, color: context.sm.ink3);
}

class _External extends StatelessWidget {
  const _External();

  @override
  Widget build(BuildContext context) => Icon(LucideIcons.externalLink, size: 18, color: context.sm.ink3);
}
