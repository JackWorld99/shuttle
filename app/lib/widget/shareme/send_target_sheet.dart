import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/pages/tabs/send_tab_vm.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/util/shareme_format.dart';
import 'package:localsend_app/util/shareme_pairing/pair_crypto.dart' show isTailscaleIp;
import 'package:localsend_app/widget/shareme/device_avatar.dart';
import 'package:localsend_app/widget/shareme/sm_sheets.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// "Send to" sheet.
///
/// - Online "My devices" come first; if only one is online it is selected by default.
/// - Offline "My devices" are shown but can't be selected.
/// - Nearby unpaired devices can be selected but are marked as needing approval.
///
/// Returns the selected device, or null when the user dismisses the sheet.
/// [onShareLink]: if given, a "Share as a link instead" button is added at the bottom; tapping it closes the sheet first,
/// then calls [onShareLink] and returns null.
Future<Device?> showSendTargetSheet(BuildContext context, {required int count, required int bytes, Future<void> Function()? onShareLink}) async {
  var link = false;
  final device = await showSmSheet<Device>(
    context,
    scroll: false,
    builder: (_) => _SendTargetSheet(count: count, bytes: bytes, onShareLink: onShareLink == null ? null : () => link = true),
  );
  if (link && onShareLink != null) {
    await onShareLink();
    return null;
  }
  return device;
}

class _SendTargetSheet extends StatefulWidget {
  final int count;
  final int bytes;
  final VoidCallback? onShareLink;

  const _SendTargetSheet({required this.count, required this.bytes, this.onShareLink});

  @override
  State<_SendTargetSheet> createState() => _SendTargetSheetState();
}

class _SendTargetSheetState extends State<_SendTargetSheet> {
  String? _selected; // device fingerprint
  bool _userChose = false;

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final vm = context.watch(sendTabVmProvider);
    // Preselect the default target (see defaultSendTarget); once the user has picked one, leave it alone
    if (!_userChose && _selected == null) _selected = defaultSendTarget(vm, lastTarget: lastSendTarget(context.ref));
    final selectedDevice = sendTargetDevice(vm, _selected);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(t.shareme.send.sheetTitle, style: ShareMeText.title.copyWith(color: c.ink, fontSize: 18)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      t.shareme.send.sheetSummary(n: widget.count, size: formatSize(widget.bytes)),
                      style: ShareMeText.data.copyWith(color: c.ink2),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SendTargetList(
                selected: _selected,
                onSelect: (fp) => setState(() {
                  _selected = fp;
                  _userChose = true;
                }),
              ),
            ),
            const SizedBox(height: 14),
            SendToButton(device: selectedDevice, onPressed: () => Navigator.of(context).pop(selectedDevice)),
            if (widget.onShareLink != null)
              TextButton(
                onPressed: () {
                  widget.onShareLink!();
                  Navigator.of(context).pop();
                },
                child: Text(t.shareme.send.shareLink),
              ),
          ],
        ),
      ),
    );
  }
}

/// Default send target (one-tap send):
/// 1. exactly one "My devices" entry online → that one;
/// 2. several "My devices" online → the one sent to last time ([lastTarget], if still online);
/// 3. otherwise no default; the user picks one in the "Send to" sheet.
/// With a default, picked content is sent to it right away; above the home send button it says "Send to X ▾" (tap the name to change).
String? defaultSendTarget(SendTabVm vm, {String? lastTarget}) {
  final online = vm.favoriteDevices.where((f) => vm.nearbyDevices.any((d) => d.fingerprint == f.fingerprint)).toList();
  if (online.length == 1) return online.first.fingerprint;
  if (lastTarget != null && online.any((f) => f.fingerprint == lastTarget)) return lastTarget;
  return null;
}

/// The device (fingerprint) sent to last time
String? lastSendTarget(Ref ref) => ref.read(persistenceProvider).getLastSendTarget();

/// Remembers this send target (the default next time several devices are online)
Future<void> rememberSendTarget(Ref ref, String fingerprint) => ref.read(persistenceProvider).setLastSendTarget(fingerprint);

/// Finds an online device by fingerprint (null if offline, since it can't be sent to).
Device? sendTargetDevice(SendTabVm vm, String? fingerprint) =>
    fingerprint == null ? null : vm.nearbyDevices.firstWhereOrNull((d) => d.fingerprint == fingerprint);

/// "Send to" list (shared by the send-files sheet and the send-text sheet): online "My devices" first;
/// offline ones are shown but can't be selected; nearby unpaired devices can be selected and are marked as needing approval.
class SendTargetList extends StatelessWidget {
  final String? selected;
  final ValueChanged<String> onSelect;

  const SendTargetList({required this.selected, required this.onSelect, super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final vm = context.watch(sendTabVmProvider);
    final nearby = vm.nearbyDevices.toList();
    final favorites = vm.favoriteDevices;
    final favoriteFingerprints = favorites.map((f) => f.fingerprint).toSet();
    bool online(FavoriteDevice f) => nearby.any((d) => d.fingerprint == f.fingerprint);
    // Shuttle: label by the address it was found at, like the home page. It used to always say "Same Wi-Fi · direct", even via Tailscale
    bool viaTailscale(FavoriteDevice f) => isTailscaleIp(nearby.firstWhereOrNull((d) => d.fingerprint == f.fingerprint)?.ip);

    final rows = <Widget>[
      for (final f in favorites.where(online))
        _TargetRow(
          seal: DeviceAvatar(
            deviceType: nearby.firstWhereOrNull((d) => d.fingerprint == f.fingerprint)?.deviceType,
            size: 40,
            mine: true,
          ),
          name: f.alias,
          status: viaTailscale(f) ? t.shareme.home.viaTailscale : t.shareme.home.sameWifi,
          okStatus: !viaTailscale(f),
          value: f.fingerprint,
          groupValue: selected,
          onChanged: onSelect,
        ),
      for (final f in favorites.where((f) => !online(f)))
        _TargetRow(
          seal: DeviceAvatar(deviceType: knownDeviceType(f.fingerprint), size: 40, mine: true, offline: true),
          name: f.alias,
          status: t.shareme.send.offlineCannot,
          value: f.fingerprint,
          groupValue: selected,
          onChanged: null,
        ),
      for (final d in nearby.where((d) => !favoriteFingerprints.contains(d.fingerprint)))
        _TargetRow(
          seal: DeviceAvatar(deviceType: d.deviceType, size: 40),
          name: d.alias,
          status: t.shareme.send.nearbyNeedsApproval,
          value: d.fingerprint,
          groupValue: selected,
          onChanged: onSelect,
        ),
    ];

    return Material(
      // The list group inside the sheet uses the bg color to stand apart from the sheet's group background
      color: c.bg,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: c.line),
        borderRadius: BorderRadius.circular(ShareMeSize.radiusGroup),
      ),
      clipBehavior: Clip.antiAlias,
      child: rows.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: Text(t.shareme.send.noDevices, style: ShareMeText.meta.copyWith(color: c.ink2)),
            )
          : ListView.separated(
              shrinkWrap: true,
              itemCount: rows.length,
              separatorBuilder: (_, _) => Divider(height: 1, indent: 68, color: c.line),
              itemBuilder: (_, i) => rows[i],
            ),
    );
  }
}

/// The "Send to X" primary button; disabled and showing "Choose a device first" while no device is selected (just "Send" while there
/// is nothing to choose from).
class SendToButton extends StatelessWidget {
  final Device? device;
  final VoidCallback onPressed;
  final String? label;

  /// False when a device is selected but sending isn't possible yet (e.g. empty text): disabled, without "Choose a device first"
  final bool enabled;

  const SendToButton({required this.device, required this.onPressed, this.label, this.enabled = true, super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final device = this.device;
    final none = context.watch(sendTabVmProvider).nearbyDevices.isEmpty;
    final text = device != null
        ? label ?? t.shareme.send.sendTo(name: device.alias)
        : none
        ? t.shareme.text.send
        : t.shareme.send.chooseDevice;
    return FilledButton(
      onPressed: device == null || !enabled ? null : onPressed,
      style: FilledButton.styleFrom(disabledBackgroundColor: c.tonal, disabledForegroundColor: c.ink3),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(text, maxLines: 1),
      ),
    );
  }
}

/// Small device row: 40 px avatar ([seal]), name, trailing radio mark.
class _TargetRow extends StatelessWidget {
  final Widget seal;
  final String name;
  final String status;
  final bool okStatus;
  final String value;
  final String? groupValue;
  final ValueChanged<String>? onChanged;

  const _TargetRow({
    required this.seal,
    required this.name,
    required this.status,
    required this.value,
    required this.groupValue,
    required this.onChanged,
    this.okStatus = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final enabled = onChanged != null;
    return Semantics(
      container: true,
      inMutuallyExclusiveGroup: true,
      checked: value == groupValue,
      enabled: enabled,
      child: InkWell(
        onTap: enabled ? () => onChanged!(value) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            children: [
              seal,
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: ShareMeText.deviceNameSm.copyWith(color: enabled ? c.ink : c.ink3),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      status,
                      style: ShareMeText.meta.copyWith(color: okStatus ? c.ok : c.ink2),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              // Custom-drawn radio mark (Radio's groupValue / onChanged are deprecated in newer Flutter)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Icon(
                  value == groupValue ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  size: 22,
                  color: !enabled ? c.line : (value == groupValue ? c.accent : c.ink3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opened from the home "Send to X ▾": pick another online "My devices" entry. Returns its fingerprint (stored by the caller as the last target).
Future<String?> showChooseMyDeviceSheet(BuildContext context, {required String? current}) {
  return showSmSheet<String>(
    context,
    maxWidth: 400,
    builder: (context) {
      final c = context.sm;
      final vm = context.watch(sendTabVmProvider);
      final online = vm.favoriteDevices.where((f) => vm.nearbyDevices.any((d) => d.fingerprint == f.fingerprint)).toList();
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(t.shareme.send.sheetTitle, style: ShareMeText.title.copyWith(color: c.ink, fontSize: 18)),
              ),
              for (final f in online)
                ListTile(
                  leading: DeviceAvatar(
                    deviceType: vm.nearbyDevices.firstWhereOrNull((d) => d.fingerprint == f.fingerprint)?.deviceType,
                    size: 40,
                    mine: true,
                  ),
                  title: Text(f.alias, style: ShareMeText.deviceNameSm.copyWith(color: c.ink)),
                  trailing: f.fingerprint == current ? Icon(Icons.check_rounded, color: c.accent) : null,
                  onTap: () => Navigator.of(context).pop(f.fingerprint),
                ),
            ],
          ),
        ),
      );
    },
  );
}
