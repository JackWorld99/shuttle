import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/color_mode.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/persistence/paired_record.dart';
import 'package:localsend_app/model/persistence/queued_send.dart';
import 'package:localsend_app/model/persistence/quick_save_mode.dart';
import 'package:localsend_app/model/persistence/receive_history_entry.dart';
import 'package:localsend_app/model/persistence/sent_history_entry.dart';
import 'package:localsend_app/model/send_mode.dart';
import 'package:localsend_app/provider/window_dimensions_provider.dart';
import 'package:localsend_app/util/alias_generator.dart';
import 'package:localsend_app/util/native/autostart_helper.dart';
import 'package:localsend_app/util/native/context_menu_helper.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/security_helper.dart';
import 'package:localsend_app/util/shared_preferences/shared_preferences_file.dart';
import 'package:localsend_app/util/shared_preferences/shared_preferences_portable.dart';
import 'package:localsend_app/util/shareme_device_name.dart';
import 'package:localsend_app/util/ui/animations_status.dart';
import 'package:localsend_isolates/constants.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/stored_security_context.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:uuid/uuid.dart';

part 'persistence_provider_migrations.dart';

final _logger = Logger('PersistenceService');

// Shuttle (installed build): when there is no settings.json next to Shuttle.exe, settings are stored in %APPDATA%\Shuttle.
// Upstream uses %APPDATA%\LocalSend\settings.json, the same file as the official LocalSend, so both would share the device
// identity and settings. Upstream also reads official LocalSend's older settings file
// (%APPDATA%\org.localsend\localsend_app\shared_preferences.json) and migrates it; Shuttle doesn't read it.
String get _windowsFile {
  final appData = Platform.environment['APPDATA'];
  return '$appData\\Shuttle\\settings.json';
}

// Only _migrate2 in persistence_provider_migrations.dart still references this. _migrate2 only runs for settings version < 2,
// and since Shuttle no longer reads this old file and new settings start at the latest version, it is never reached in practice.
String get _windowsLegacyFile {
  final appData = Platform.environment['APPDATA'];
  return '$appData\\org.localsend\\localsend_app\\shared_preferences.json';
}

// Version of the storage
const _version = 'ls_version';

// Security keys (generated on first app start)
const _securityContext = 'ls_security_context';

// WebRTC
const _signalingServers = 'ls_signaling_servers';
const _stunServers = 'ls_stun_servers';

// Received file history
const _receiveHistory = 'ls_receive_history';
const _sentHistory = 'shareme_sent_history'; // Shuttle: sent history
const _pairedDevices = 'shareme_paired_devices'; // Shuttle: paired (verified) devices
const _sendQueue = 'shareme_send_queue'; // Shuttle: what waits to be sent to an offline "my device" (send_queue_provider.dart)
const _lastSendTarget = 'shareme_last_send_target'; // Shuttle: last send target (fingerprint), the default when several devices are online
const _aliasFromDeviceName = 'shareme_alias_from_device_name_v2'; // Shuttle: random alias / model code replaced by the device name (once)
const _knownDeviceTypes = 'shareme_known_device_types'; // Shuttle: whether seen devices are PCs or phones (fingerprint → type), for avatars
const _autoUpdate = 'shareme_auto_update'; // Shuttle: automatic update checks

// Favorites
const _favorites = 'ls_favorites';

// App Window Offset and Size info
const _windowOffsetX = 'ls_window_offset_x';
const _windowOffsetY = 'ls_window_offset_y';
const _windowWidth = 'ls_window_width';
const _windowHeight = 'ls_window_height';
const _saveWindowPlacement = 'ls_save_window_placement';
const _alwaysOnTop = 'ls_always_on_top';

// Settings
const _showToken = 'ls_show_token';
const _aliasKey = 'ls_alias';
const _themeKey = 'ls_theme'; // now called brightness
const _colorKey = 'ls_color';
const _customColorKey = 'ls_custom_color'; // RRGGBB hex, used by ColorMode.custom
const _localeKey = 'ls_locale';
const _portKey = 'ls_port';
const _networkWhitelistKey = 'ls_network_whitelist';
const _networkBlacklistKey = 'ls_network_blacklist';
const _timeoutKey = 'ls_timeout';
const _multicastGroupKey = 'ls_multicast_group';
const _destinationKey = 'ls_destination';
const _saveToGallery = 'ls_save_to_gallery';
const _saveToHistory = 'ls_save_to_history';
const _quickSave = 'ls_quick_save'; // a QuickSaveMode; was a bool until storage version 2 ('ls_quick_save_from_favorites' is merged into this key)
const _receivePin = 'ls_receive_pin';
const _autoFinish = 'ls_auto_finish';
const _minimizeToTray = 'ls_minimize_to_tray';
const _https = 'ls_https';
const _sendMode = 'ls_send_mode';
const _enableAnimations = 'ls_enable_animations';
const _deviceType = 'ls_device_type';
const _deviceModel = 'ls_device_model';
const _shareViaLinkAutoAccept = 'ls_share_via_link_auto_accept';
const _receiveViaLinkAutoAccept = 'ls_receive_via_link_auto_accept';
const _createChecksums = 'ls_create_checksums';
const _verifyChecksums = 'ls_verify_checksums';
const _advancedSettingsKey = 'ls_advanced_settings';
const _whatsNewKey = 'ls_whats_new';

final persistenceProvider = Provider<PersistenceService>((ref) {
  throw Exception('persistenceProvider not initialized');
});

/// This service abstracts the persistence layer.
class PersistenceService {
  final SharedPreferences _prefs;
  final bool isFirstAppStart;

  PersistenceService._(this._prefs, this.isFirstAppStart);

  /// Shuttle: the folder holding settings.json on desktop (next to Shuttle.exe in portable mode, else %APPDATA%\Shuttle); null on
  /// phones, whose settings live in the platform store. Other data that belongs with the settings (the send queue's copies) goes here.
  static String? settingsDirectory;

  static Future<PersistenceService> initialize({
    required bool supportsDynamicColors,
  }) async {
    SharedPreferences prefs;

    final portableStore = SharedPreferencesPortable();
    if (checkPlatform(const [TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS]) && portableStore.exists()) {
      _logger.info('Using portable settings.');
      SharedPreferencesStorePlatform.instance = portableStore;
      settingsDirectory = File(portableStore.filePath).parent.path;
    } else if (defaultTargetPlatform == TargetPlatform.windows) {
      // Shuttle: don't read official LocalSend's old settings file (see the comment above _windowsFile)
      SharedPreferencesStorePlatform.instance = SharedPreferencesFile(filePath: _windowsFile);
      settingsDirectory = File(_windowsFile).parent.path;
    }

    final bool isFirstAppStart;
    final existingPrefs = await SharedPreferencesStorePlatform.instance.getAll();
    final existingVersion = existingPrefs['flutter.$_version'] as int?;
    _logger.info('Existing version: $existingVersion');
    isFirstAppStart = existingVersion == null && !existingPrefs.keys.any((key) => key.startsWith('flutter.ls_'));
    if (isFirstAppStart) {
      await SharedPreferencesStorePlatform.instance.setValue('Int', 'flutter.$_version', _latestVersion);
    } else {
      // Unversioned profiles in the current store may already contain string modes.
      // Only apply the repair migration; older migrations would replace those modes.
      final fromVersion = existingVersion ?? 3;
      if (fromVersion < _latestVersion) {
        await _runMigrations(fromVersion);
      }
    }

    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      // Shuttle: upstream deletes the Windows settings file here (in portable mode, even the wrong file), losing the device
      // identity. Null values in the settings file are now dropped on read (shared_preferences_file.dart), so this is normally
      // unreachable; if it is reached anyway, throw instead of deleting the file.
      _logger.severe('Could not initialize SharedPreferences', e);
      throw Exception('Could not initialize SharedPreferences');
    }

    // Shuttle: the language follows the system (Chinese on a Chinese system, English otherwise), as on the phone. Earlier desktop
    // builds saved Simplified Chinese on first launch; those installs, and any where the user picked a language, keep their setting.

    // Locale configuration upon persistence initialisation to prevent unlocalised Alias generation
    final persistedLocale = prefs.getString(_localeKey);
    if (persistedLocale == null) {
      await LocaleSettings.useDeviceLocale();
    } else {
      await LocaleSettings.setLocaleRaw(persistedLocale);
    }

    if (prefs.getString(_showToken) == null) {
      await prefs.setString(_showToken, const Uuid().v4());
    }

    // Shuttle: the alias is the system device name (PC name / phone name) instead of a random "adjective + fruit". Older installs
    // still using a random name are switched once; names the user changed stay (shareme_device_name.dart)
    if (prefs.getString(_aliasKey) == null) {
      await prefs.setString(_aliasKey, await defaultDeviceAlias());
      await prefs.setBool(_aliasFromDeviceName, true);
    } else if (prefs.getBool(_aliasFromDeviceName) != true) {
      final current = prefs.getString(_aliasKey)!;
      if (await shouldUseDeviceAlias(current)) {
        final name = await defaultDeviceAlias();
        _logger.info('Replacing the random alias "$current" with the system device name "$name"');
        await prefs.setString(_aliasKey, name);
      }
      await prefs.setBool(_aliasFromDeviceName, true);
    }

    if (prefs.getString(_securityContext) == null) {
      await prefs.setString(_securityContext, jsonEncode(await generateSecurityContext()));
    }

    if (isFirstAppStart) {
      final systemAnimations = await getSystemAnimationsStatus();
      if (!systemAnimations) {
        _logger.info('System animations are disabled, disabling animations in the app.');
        await prefs.setBool(_enableAnimations, false);
      }
    }

    if (prefs.getString(_colorKey) == null) {
      await _initColorSetting(prefs, supportsDynamicColors);
    } else {
      // fix when device does not support dynamic colors
      final supported = supportsDynamicColors ? ColorMode.values : ColorMode.values.where((e) => e != ColorMode.system);
      final colorMode = supported.firstWhereOrNull((color) => color.name == prefs.getString(_colorKey));
      if (colorMode == null) {
        await _initColorSetting(prefs, supportsDynamicColors);
      }
    }

    // migrate legacy auto start settings (current implementation is stateless and relies on the Windows registry / file system)
    const launchAtStartupLegacyKey = 'ls_launch_at_startup';
    const launchMinimizedLegacyKey = 'ls_auto_start_launch_minimized';
    if (prefs.getBool(launchAtStartupLegacyKey) == true) {
      _logger.info('Enable auto start on legacy settings');
      await prefs.remove(launchAtStartupLegacyKey);
      await enableAutoStart(startHidden: prefs.getBool(launchMinimizedLegacyKey) == true);
      await prefs.remove(launchMinimizedLegacyKey);
    }

    return PersistenceService._(prefs, isFirstAppStart);
  }

  static Future<void> _initColorSetting(SharedPreferences prefs, bool supportsDynamicColors) async {
    await prefs.setString(
      _colorKey,
      checkPlatform([TargetPlatform.android]) && supportsDynamicColors ? ColorMode.system.name : ColorMode.localsend.name,
    );
  }

  bool isPortableMode() {
    return SharedPreferencesStorePlatform.instance is SharedPreferencesPortable;
  }

  /// Shuttle: how the desktop settings file was loaded this time (recovered / had to start over); null on phones and macOS,
  /// which use system storage. Used when the UI needs to show a notice.
  SettingsLoadOutcome? get settingsLoadOutcome {
    final store = SharedPreferencesStorePlatform.instance;
    return store is SharedPreferencesFile ? store.loadOutcome : null;
  }

  StoredSecurityContext getSecurityContext() {
    final contextRaw = _prefs.getString(_securityContext)!;
    return StoredSecurityContext.fromJson(jsonDecode(contextRaw));
  }

  Future<void> setSecurityContext(StoredSecurityContext context) async {
    await _prefs.setString(_securityContext, jsonEncode(context));
  }

  List<String>? getSignalingServers() {
    final serversRaw = _prefs.getString(_signalingServers);
    if (serversRaw == null) {
      return null;
    }

    return (jsonDecode(serversRaw) as List).cast<String>();
  }

  Future<void> setSignalingServers(List<String> servers) async {
    await _prefs.setString(_signalingServers, jsonEncode(servers));
  }

  List<String>? getStunServers() {
    final serversRaw = _prefs.getString(_stunServers);
    if (serversRaw == null) {
      return null;
    }

    return (jsonDecode(serversRaw) as List).cast<String>();
  }

  Future<void> setStunServers(List<String> servers) async {
    await _prefs.setString(_stunServers, jsonEncode(servers));
  }

  List<ReceiveHistoryEntry> getReceiveHistory() {
    final historyRaw = _prefs.getStringList(_receiveHistory) ?? [];
    return historyRaw.map((entry) => ReceiveHistoryEntry.fromJson(jsonDecode(entry))).toList();
  }

  Future<void> setReceiveHistory(List<ReceiveHistoryEntry> entries) async {
    final historyRaw = entries.map((entry) => jsonEncode(entry.toJson())).toList();
    await _prefs.setStringList(_receiveHistory, historyRaw);
  }

  // Shuttle: sent history
  List<SentHistoryEntry> getSentHistory() {
    final historyRaw = _prefs.getStringList(_sentHistory) ?? [];
    final result = <SentHistoryEntry>[];
    for (final entry in historyRaw) {
      try {
        result.add(SentHistoryEntry.fromJson(jsonDecode(entry)));
      } catch (e) {
        _logger.warning('Could not parse sent history entry', e);
      }
    }
    return result;
  }

  Future<void> setSentHistory(List<SentHistoryEntry> entries) async {
    final historyRaw = entries.map((entry) => jsonEncode(entry.toJson())).toList();
    await _prefs.setStringList(_sentHistory, historyRaw);
  }

  /// Shuttle: paired (verified) devices
  List<PairedRecord> getPairedRecords() {
    final raw = _prefs.getStringList(_pairedDevices) ?? [];
    final result = <PairedRecord>[];
    for (final entry in raw) {
      try {
        result.add(PairedRecord.fromJson(jsonDecode(entry) as Map<String, dynamic>));
      } catch (e) {
        _logger.warning('Could not parse paired record', e);
      }
    }
    return result;
  }

  Future<void> setPairedRecords(List<PairedRecord> records) async {
    await _prefs.setStringList(_pairedDevices, records.map((r) => jsonEncode(r.toJson())).toList());
  }

  /// Shuttle: the type of each seen device (fingerprint → DeviceType.name). Favorites don't store the type, so avatars rely on
  /// this to show the right icon while a device is offline.
  Map<String, String> getKnownDeviceTypes() {
    final raw = _prefs.getString(_knownDeviceTypes);
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>).map((k, v) => MapEntry(k, v as String));
    } catch (e) {
      _logger.warning('Could not parse known device types', e);
      return {};
    }
  }

  Future<void> setKnownDeviceTypes(Map<String, String> types) async {
    await _prefs.setString(_knownDeviceTypes, jsonEncode(types));
  }

  /// Shuttle: the send queue (one JSON string per batch; unreadable entries are skipped)
  List<QueuedSend> getSendQueue() {
    final raw = _prefs.getStringList(_sendQueue) ?? [];
    final result = <QueuedSend>[];
    for (final entry in raw) {
      try {
        result.add(QueuedSend.fromJson(jsonDecode(entry) as Map<String, dynamic>));
      } catch (e) {
        _logger.warning('Could not parse a queued send', e);
      }
    }
    return result;
  }

  Future<void> setSendQueue(List<QueuedSend> entries) async {
    await _prefs.setStringList(_sendQueue, entries.map((e) => jsonEncode(e.toJson())).toList());
  }

  /// Shuttle: the device last sent to (fingerprint)
  String? getLastSendTarget() => _prefs.getString(_lastSendTarget);

  Future<void> setLastSendTarget(String fingerprint) async {
    await _prefs.setString(_lastSendTarget, fingerprint);
  }

  List<FavoriteDevice> getFavorites() {
    final favoritesRaw = _prefs.getStringList(_favorites) ?? [];
    return favoritesRaw.map((entry) => FavoriteDevice.fromJson(jsonDecode(entry))).toList();
  }

  Future<void> setFavorites(List<FavoriteDevice> entries) async {
    final favoritesRaw = entries.map((entry) => jsonEncode(entry.toJson())).toList();
    await _prefs.setStringList(_favorites, favoritesRaw);
  }

  String getShowToken() {
    return _prefs.getString(_showToken)!;
  }

  String getAlias() {
    return _prefs.getString(_aliasKey) ?? generateRandomAlias();
  }

  Future<void> setAlias(String alias) async {
    await _prefs.setString(_aliasKey, alias);
  }

  ThemeMode getTheme() {
    final value = _prefs.getString(_themeKey);
    if (value == null) {
      return ThemeMode.system;
    }
    return ThemeMode.values.firstWhereOrNull((theme) => theme.name == value) ?? ThemeMode.system;
  }

  Future<void> setTheme(ThemeMode theme) async {
    await _prefs.setString(_themeKey, theme.name);
  }

  ColorMode getColorMode() {
    final value = _prefs.getString(_colorKey);
    if (value == null) {
      return ColorMode.system;
    }
    return ColorMode.values.firstWhereOrNull((color) => color.name == value) ?? ColorMode.system;
  }

  Future<void> setColorMode(ColorMode color) async {
    await _prefs.setString(_colorKey, color.name);
  }

  Color getCustomColor() {
    final value = _prefs.getString(_customColorKey);
    final rgb = value == null ? null : int.tryParse(value, radix: 16);
    if (rgb == null) {
      return Colors.teal;
    }
    return Color(0xff000000 | rgb);
  }

  Future<void> setCustomColor(Color color) async {
    await _prefs.setString(_customColorKey, color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2));
  }

  AppLocale? getLocale() {
    final value = _prefs.getString(_localeKey);
    if (value == null) {
      return null;
    }
    return AppLocale.values.firstWhereOrNull((locale) => locale.languageTag == value);
  }

  Future<void> setLocale(AppLocale? locale) async {
    if (locale == null) {
      await _prefs.remove(_localeKey);
    } else {
      await _prefs.setString(_localeKey, locale.languageTag);
    }
  }

  int getPort() {
    return _prefs.getInt(_portKey) ?? defaultPort;
  }

  Future<void> setPort(int port) async {
    await _prefs.setInt(_portKey, port);
  }

  List<String>? getNetworkWhitelist() {
    return _prefs.getStringList(_networkWhitelistKey);
  }

  Future<void> setNetworkWhitelist(List<String>? whitelist) async {
    if (whitelist == null) {
      await _prefs.remove(_networkWhitelistKey);
    } else {
      await _prefs.setStringList(_networkWhitelistKey, whitelist);
    }
  }

  List<String>? getNetworkBlacklist() {
    return _prefs.getStringList(_networkBlacklistKey);
  }

  Future<void> setNetworkBlacklist(List<String>? blacklist) async {
    if (blacklist == null) {
      await _prefs.remove(_networkBlacklistKey);
    } else {
      await _prefs.setStringList(_networkBlacklistKey, blacklist);
    }
  }

  int getDiscoveryTimeout() {
    return _prefs.getInt(_timeoutKey) ?? defaultDiscoveryTimeout;
  }

  Future<void> setDiscoveryTimeout(int timeout) async {
    await _prefs.setInt(_timeoutKey, timeout);
  }

  bool getShareViaLinkAutoAccept() {
    return _prefs.getBool(_shareViaLinkAutoAccept) ?? false;
  }

  Future<void> setShareViaLinkAutoAccept(bool shareViaLinkAutoAccept) async {
    await _prefs.setBool(_shareViaLinkAutoAccept, shareViaLinkAutoAccept);
  }

  bool getReceiveViaLinkAutoAccept() {
    return _prefs.getBool(_receiveViaLinkAutoAccept) ?? false;
  }

  Future<void> setReceiveViaLinkAutoAccept(bool receiveViaLinkAutoAccept) async {
    await _prefs.setBool(_receiveViaLinkAutoAccept, receiveViaLinkAutoAccept);
  }

  bool getCreateChecksums() {
    return _prefs.getBool(_createChecksums) ?? true;
  }

  Future<void> setCreateChecksums(bool createChecksums) async {
    await _prefs.setBool(_createChecksums, createChecksums);
  }

  bool getVerifyChecksums() {
    return _prefs.getBool(_verifyChecksums) ?? true;
  }

  Future<void> setVerifyChecksums(bool verifyChecksums) async {
    await _prefs.setBool(_verifyChecksums, verifyChecksums);
  }

  String getMulticastGroup() {
    return _prefs.getString(_multicastGroupKey) ?? defaultMulticastGroup;
  }

  Future<void> setMulticastGroup(String group) async {
    await _prefs.setString(_multicastGroupKey, group);
  }

  String? getDestination() {
    return _prefs.getString(_destinationKey);
  }

  Future<void> setDestination(String? destination) async {
    if (destination == null) {
      await _prefs.remove(_destinationKey);
    } else {
      await _prefs.setString(_destinationKey, destination);
    }
  }

  bool isSaveToGallery() {
    return _prefs.getBool(_saveToGallery) ?? true;
  }

  Future<void> setSaveToGallery(bool saveToGallery) async {
    await _prefs.setBool(_saveToGallery, saveToGallery);
  }

  bool isSaveToHistory() {
    return _prefs.getBool(_saveToHistory) ?? true;
  }

  Future<void> setSaveToHistory(bool saveToHistory) async {
    await _prefs.setBool(_saveToHistory, saveToHistory);
  }

  bool getAdvancedSettingsEnabled() {
    return _prefs.getBool(_advancedSettingsKey) ?? false;
  }

  Future<void> setAdvancedSettingsEnabled(bool isEnabled) async {
    await _prefs.setBool(_advancedSettingsKey, isEnabled);
  }

  QuickSaveMode getQuickSave() {
    final value = _prefs.getString(_quickSave);
    return QuickSaveMode.values.firstWhereOrNull((mode) => mode.name == value) ?? QuickSaveMode.paired;
  }

  Future<void> setQuickSave(QuickSaveMode mode) async {
    await _prefs.setString(_quickSave, mode.name);
  }

  String? getReceivePin() {
    return _prefs.getString(_receivePin);
  }

  Future<void> setReceivePin(String? pin) async {
    if (pin == null) {
      await _prefs.remove(_receivePin);
    } else {
      await _prefs.setString(_receivePin, pin);
    }
  }

  bool isAutoFinish() {
    return _prefs.getBool(_autoFinish) ?? false;
  }

  Future<void> setAutoFinish(bool autoFinish) async {
    await _prefs.setBool(_autoFinish, autoFinish);
  }

  bool isMinimizeToTray() {
    // Shuttle: on Windows and macOS, closing the window minimizes to the tray (the menu bar on macOS) and keeps receiving in the
    // background by default. LocalSend's default is to quit. Users can still change it in "More settings".
    return _prefs.getBool(_minimizeToTray) ?? checkPlatform([TargetPlatform.windows, TargetPlatform.macOS]);
  }

  Future<void> setMinimizeToTray(bool minimizeToTray) async {
    await _prefs.setBool(_minimizeToTray, minimizeToTray);
  }

  bool isHttps() {
    return _prefs.getBool(_https) ?? true;
  }

  Future<void> setHttps(bool https) async {
    await _prefs.setBool(_https, https);
  }

  SendMode getSendMode() {
    return SendMode.values.firstWhereOrNull((m) => m.name == _prefs.getString(_sendMode)) ?? SendMode.single;
  }

  Future<void> setSendMode(SendMode mode) async {
    await _prefs.setString(_sendMode, mode.name);
  }

  Future<void> setWindowOffsetX(double x) async {
    await _prefs.setDouble(_windowOffsetX, x);
  }

  Future<void> setWindowOffsetY(double y) async {
    await _prefs.setDouble(_windowOffsetY, y);
  }

  Future<void> setWindowHeight(double height) async {
    await _prefs.setDouble(_windowHeight, height);
  }

  Future<void> setWindowWidth(double width) async {
    await _prefs.setDouble(_windowWidth, width);
  }

  WindowDimensions? getWindowLastDimensions() {
    Size? size;
    Offset? position;
    final offsetX = _prefs.getDouble(_windowOffsetX);
    final offsetY = _prefs.getDouble(_windowOffsetY);
    final width = _prefs.getDouble(_windowWidth);
    final height = _prefs.getDouble(_windowHeight);

    if (width != null && height != null) {
      size = Size(width, height);
    }

    if (offsetX != null && offsetY != null) {
      position = Offset(offsetX, offsetY);
    }

    if (size == null || position == null) {
      return null;
    }

    return WindowDimensions(
      position: position,
      size: size,
    );
  }

  Future<void> setSaveWindowPlacement(bool savePlacement) async {
    await _prefs.setBool(_saveWindowPlacement, savePlacement);
  }

  bool getSaveWindowPlacement() {
    if (!checkPlatformIsNotWaylandDesktop()) return false;
    return _prefs.getBool(_saveWindowPlacement) ?? true;
  }

  Future<void> setAlwaysOnTop(bool alwaysOnTop) async {
    await _prefs.setBool(_alwaysOnTop, alwaysOnTop);
  }

  bool getAlwaysOnTop() {
    return _prefs.getBool(_alwaysOnTop) ?? false;
  }

  Future<void> setEnableAnimations(bool enableAnimations) async {
    await _prefs.setBool(_enableAnimations, enableAnimations);
  }

  bool getEnableAnimations() {
    return _prefs.getBool(_enableAnimations) ?? true;
  }

  DeviceType? getDeviceType() {
    return DeviceType.values.firstWhereOrNull((m) => m.name == _prefs.getString(_deviceType));
  }

  Future<void> setDeviceType(DeviceType deviceType) async {
    await _prefs.setString(_deviceType, deviceType.name);
  }

  String? getDeviceModel() {
    return _prefs.getString(_deviceModel);
  }

  Future<void> setDeviceModel(String deviceModel) async {
    await _prefs.setString(_deviceModel, deviceModel);
  }

  String? getWhatsNew() {
    return _prefs.getString(_whatsNewKey);
  }

  Future<void> setWhatsNew(String version) async {
    await _prefs.setString(_whatsNewKey, version);
  }

  /// Shuttle: automatic update checks (on by default)
  bool getAutoUpdate() => _prefs.getBool(_autoUpdate) ?? true;

  Future<void> setAutoUpdate(bool enabled) async {
    await _prefs.setBool(_autoUpdate, enabled);
  }

  Future<void> clear() async {
    await _prefs.clear();
  }
}
