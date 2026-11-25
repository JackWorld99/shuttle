import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/settings/network_interfaces_page.dart';
import 'package:localsend_app/pages/tabs/settings_tab_controller.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/widget/shareme/ambient.dart';
import 'package:localsend_app/widget/shareme/bottom_actions.dart';
import 'package:localsend_app/widget/shareme/setting_rows.dart';
import 'package:localsend_app/widget/shareme/sm_sheets.dart';
import 'package:localsend_isolates/constants.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// "Advanced settings": the settings LocalSend has that Shuttle's own pages don't show. Replaces LocalSend's settings page, which
/// repeated half of Shuttle's (theme, language, auto-accept, save folder, …) in another style.
class SmAdvancedPage extends StatefulWidget {
  const SmAdvancedPage({super.key});

  @override
  State<SmAdvancedPage> createState() => _SmAdvancedPageState();
}

class _SmAdvancedPageState extends State<SmAdvancedPage> with Refena {
  SettingsService get _settings => ref.notifier(settingsProvider);

  @override
  void dispose() {
    // Read again next time: whether it starts at sign-in can change on the settings page
    ref.dispose(settingsTabControllerProvider);
    super.dispose();
  }

  Future<void> _restartServer() async {
    if (ref.read(serverProvider) != null) await ref.notifier(serverProvider).restartServerFromSettings();
  }

  /// Turning encryption off asks first: everyone on the same Wi-Fi could read along.
  Future<void> _setEncryption(bool on) async {
    if (!on) {
      final s = t.shareme.settings;
      final off = await showSmSheet<bool>(
        context,
        maxWidth: 400,
        builder: (context) {
          final c = context.sm;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
                  child: Column(
                    children: [
                      Text(
                        s.encryptionOffTitle,
                        style: ShareMeText.title.copyWith(color: c.ink, fontSize: 19, height: 1.35, fontWeight: FontWeight.w700),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        s.encryptionOffBody,
                        style: ShareMeText.body.copyWith(color: c.warn),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
                BottomActions(
                  secondaryLabel: s.encryptionOffConfirm,
                  onSecondary: () => Navigator.of(context).pop(true),
                  primaryLabel: s.encryptionKeep,
                  onPrimary: () => Navigator.of(context).pop(false),
                ),
              ],
            ),
          );
        },
      );
      if (off != true) return;
    }
    await _settings.setHttps(on);
  }

  Future<void> _edit({
    required String title,
    required String current,
    required Future<void> Function(String value) save,
    String? Function(String value)? error,
    bool number = false,
  }) async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _EditDialog(title: title, current: current, number: number, error: error),
    );
    if (value == null || value == current || !mounted) return;
    await save(value);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final s = t.shareme.settings;
    final vm = context.watch(settingsTabControllerProvider);
    final settings = vm.settings;
    final server = vm.serverState;
    final desktop = checkPlatformIsDesktop();
    final movable = checkPlatformIsNotWaylandDesktop();
    final needRestart = server != null && (server.alias != settings.alias || server.port != settings.port || server.https != settings.https);
    final customNetwork = settings.port != defaultPort || settings.multicastGroup != defaultMulticastGroup;

    Widget toggle(String title, {required bool value, required Future<void> Function(bool) set}) => SmRow(
      title: title,
      trailing: Switch(value: value, onChanged: (v) async => set(v)),
      onTap: () async => set(!value),
    );

    final general = [
      if (desktop && movable) toggle(s.alwaysOnTop, value: settings.alwaysOnTop, set: _settings.setAlwaysOnTop),
      if (desktop && movable) toggle(s.saveWindow, value: settings.saveWindowPlacement, set: _settings.setSaveWindowPlacement),
      if (checkPlatformHasTray()) toggle(s.minimizeToTray, value: settings.minimizeToTray, set: _settings.setMinimizeToTray),
      if (desktop && vm.autoStart)
        toggle(s.launchMinimized, value: vm.autoStartLaunchHidden, set: (_) async => vm.onToggleAutoStartLaunchHidden(context)),
      if (checkPlatform([TargetPlatform.windows]))
        toggle(s.contextMenu, value: vm.showInContextMenu, set: (_) async => vm.onToggleShowInContextMenu(context)),
      toggle(s.animations, value: settings.enableAnimations, set: _settings.setEnableAnimations),
    ];

    return SmScaffold(
      appBar: AppBar(title: Text(s.localsendSettings)),
      body: SmPageList(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          SmRowTitle(s.general),
          SmRowGroup(children: general),

          SmRowTitle(t.shareme.nav.transfer),
          SmRowGroup(
            children: [
              toggle(s.createChecksums, value: settings.createChecksums, set: _settings.setCreateChecksums),
              toggle(
                s.verifyChecksums,
                value: settings.verifyChecksums,
                set: (v) async {
                  await _settings.setVerifyChecksums(v);
                  await _restartServer(); // the Rust server checks them
                },
              ),
              toggle(s.linkAutoAccept, value: settings.shareViaLinkAutoAccept, set: _settings.setShareViaLinkAutoAccept),
            ],
          ),

          SmRowTitle(s.network),
          SmRowGroup(
            children: [
              SmRow(
                title: s.server,
                subtitle: needRestart
                    ? s.needRestart
                    : server == null
                    ? s.serverOff
                    : s.serverOn,
                subtitleColor: needRestart || server == null ? c.warn : null,
                trailing: server == null
                    ? TextButton(onPressed: () => vm.onTapStartServer(context), child: Text(s.start))
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(onPressed: vm.onTapStopServer, child: Text(s.stop)),
                          TextButton(
                            onPressed: () => vm.onTapRestartServer(context),
                            style: TextButton.styleFrom(foregroundColor: needRestart ? c.accent : null),
                            child: Text(s.restart),
                          ),
                        ],
                      ),
              ),
              SmRow(
                title: s.encryption,
                trailing: Switch(value: settings.https, onChanged: (v) async => _setEncryption(v)),
                onTap: () async => _setEncryption(!settings.https),
              ),
              SmRow(
                title: s.networks,
                value: settings.networkWhitelist != null || settings.networkBlacklist != null ? s.networksSome : s.networksAll,
                trailing: const SmRowChevron(),
                onTap: () async => context.push(() => const NetworkInterfacesPage()),
              ),
              SmRow(
                title: s.port,
                value: '${settings.port}',
                trailing: const SmRowChevron(),
                onTap: () async => _edit(
                  title: s.port,
                  current: '${settings.port}',
                  number: true,
                  error: (v) {
                    final port = int.tryParse(v);
                    return port == null || port < 1024 || port > 65535 ? s.portRange : null;
                  },
                  save: (v) async {
                    vm.portController.text = v;
                    await _settings.setPort(int.parse(v));
                  },
                ),
              ),
              SmRow(
                title: s.multicast,
                value: settings.multicastGroup,
                trailing: const SmRowChevron(),
                onTap: () async => _edit(
                  title: s.multicast,
                  current: settings.multicastGroup,
                  error: (v) => _isMulticast(v) ? null : s.multicastRange,
                  save: (v) async {
                    vm.multicastController.text = v;
                    await _settings.setMulticastGroup(v);
                  },
                ),
              ),
              SmRow(
                title: s.scanTimeout,
                value: '${settings.discoveryTimeout}',
                trailing: const SmRowChevron(),
                onTap: () async => _edit(
                  title: s.scanTimeout,
                  current: '${settings.discoveryTimeout}',
                  number: true,
                  error: (v) {
                    final ms = int.tryParse(v);
                    return ms == null || ms < 100 || ms > 60000 ? s.timeoutRange : null;
                  },
                  save: (v) async {
                    vm.timeoutController.text = v;
                    await _settings.setDiscoveryTimeout(int.parse(v));
                  },
                ),
              ),
            ],
          ),
          if (customNetwork) SmRowNote(s.customNetwork(port: '$defaultPort', address: defaultMulticastGroup)),

          SmRowTitle(s.thisDevice),
          SmRowGroup(
            children: [
              SmRow(
                title: s.deviceType,
                value: _typeName(vm.deviceInfo.deviceType),
                trailing: const SmRowChevron(),
                onTap: () async => _pickType(vm.deviceInfo.deviceType),
              ),
              SmRow(
                title: s.deviceModel,
                value: vm.deviceInfo.deviceModel ?? '',
                trailing: const SmRowChevron(),
                onTap: () async => _edit(
                  title: s.deviceModel,
                  current: vm.deviceInfo.deviceModel ?? '',
                  save: (v) async {
                    vm.deviceModelController.text = v;
                    await _settings.setDeviceModel(v);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static bool _isMulticast(String v) {
    final parts = v.split('.').map(int.tryParse).toList();
    return parts.length == 4 && parts.every((p) => p != null && p >= 0 && p <= 255) && parts.first! >= 224 && parts.first! <= 239;
  }

  static String _typeName(DeviceType type) {
    final s = t.shareme.settings;
    return switch (type) {
      DeviceType.mobile => s.typeMobile,
      DeviceType.desktop => s.typeDesktop,
      DeviceType.web || DeviceType.headless || DeviceType.server => s.typeOther,
    };
  }

  /// How other devices show this one
  Future<void> _pickType(DeviceType current) async {
    final picked = await showSmSheet<DeviceType>(
      context,
      maxWidth: 380,
      builder: (context) {
        final c = context.sm;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final type in const [DeviceType.mobile, DeviceType.desktop, DeviceType.web])
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 22),
                  leading: Icon(
                    _typeName(type) == _typeName(current) ? LucideIcons.circleCheck : LucideIcons.circle,
                    color: _typeName(type) == _typeName(current) ? c.accent : c.ink3,
                  ),
                  title: Text(
                    _typeName(type),
                    style: ShareMeText.body.copyWith(color: c.ink, fontWeight: FontWeight.w500),
                  ),
                  onTap: () => Navigator.of(context).pop(type),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (picked != null && _typeName(picked) != _typeName(current)) await _settings.setDeviceType(picked);
  }
}

class _EditDialog extends StatefulWidget {
  final String title;
  final String current;
  final bool number;
  final String? Function(String value)? error;

  const _EditDialog({required this.title, required this.current, required this.number, required this.error});

  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  late final _controller = TextEditingController(text: widget.current);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final value = _controller.text.trim();
    final error = widget.error?.call(value);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: widget.number ? TextInputType.number : null,
        inputFormatters: [if (widget.number) FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(fillColor: context.sm.bg, errorText: _error, errorMaxLines: 3),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _save(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.shareme.settings.cancel)),
        TextButton(
          onPressed: _save,
          style: TextButton.styleFrom(foregroundColor: context.sm.accent),
          child: Text(t.shareme.settings.save),
        ),
      ],
    );
  }
}
