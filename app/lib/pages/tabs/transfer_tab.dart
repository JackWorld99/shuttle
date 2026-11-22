import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/assets.gen.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/persistence/receive_history_entry.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/pages/home_page.dart';
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/pages/shareme_pair_host_page.dart';
import 'package:localsend_app/pages/shareme_pair_nearby_page.dart';
import 'package:localsend_app/pages/shareme_pair_scan_page.dart';
import 'package:localsend_app/pages/shareme_send_page.dart';
import 'package:localsend_app/pages/shareme_verify_device.dart';
import 'package:localsend_app/pages/tabs/send_tab.dart' show pickerOptions;
import 'package:localsend_app/pages/tabs/send_tab_vm.dart';
import 'package:localsend_app/pages/web_share_page.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/paired_devices_provider.dart';
import 'package:localsend_app/provider/receive_history_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/file_picker.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/shareme_format.dart';
import 'package:localsend_app/util/shareme_pairing/pair_crypto.dart' show isTailscaleIp;
import 'package:localsend_app/widget/shareme/confirm_remove_device.dart';
import 'package:localsend_app/widget/shareme/desktop_layout.dart';
import 'package:localsend_app/widget/shareme/device_avatar.dart';
import 'package:localsend_app/widget/shareme/film_strip.dart';
import 'package:localsend_app/widget/shareme/send_target_sheet.dart';
import 'package:localsend_app/widget/shareme/send_text_sheet.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// Shuttle home page (the "Transfer" tab), in the warm-color design.
///
/// Phone, top to bottom: icon and wordmark, scan → Just received (within a day) → My devices → Nearby (only when devices
/// are found) → selected files → send dock.
/// PC: device column (My devices, Add device, Nearby) | drop zone + Just received.
/// Receiving always runs in the background; there is no separate receive page. Sending fully reuses LocalSend's
/// [sendTabVmProvider]; only the UI is replaced here.
class TransferTab extends StatefulWidget {
  const TransferTab({super.key});

  @override
  State<TransferTab> createState() => _TransferTabState();
}

class _TransferTabState extends State<TransferTab> with Refena {
  /// Offline devices in "My devices": when some devices are online and 2 or more are offline, the offline ones collapse
  /// into one "N more offline" row by default.
  bool _showOffline = false;

  @override
  void initState() {
    super.initState();
    ensureRef((ref) async {
      await ref.global.dispatchAsync(SendTabInitAction(context));
    });
  }

  Future<void> _rescan() async {
    ref.redux(nearbyDevicesProvider).dispatch(ClearFoundDevicesAction());
    await ref.global.dispatchAsync(StartSmartScan());
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Send dock: pick content → "Send to" sheet → send.
  Future<void> _pick(FilePickerOption option) => pickAndSend(context, option);

  /// Tapping a device: opens the send page if a transfer is running, otherwise sends (LocalSend shows a picker first when
  /// nothing is selected).
  Future<void> _tapDevice(Device device, SendSessionState? session) async {
    if (session != null) {
      // Back to the foreground: otherwise a finished background send is removed automatically and "Delivered" never shows
      ref.notifier(sendProvider).setBackground(session.sessionId, false);
      await context.push(() => SmSendPage(sessionId: session.sessionId));
      return;
    }
    await rememberSendTarget(ref, device.fingerprint);
    if (!mounted) return;
    await ref.read(sendTabVmProvider).onTapDevice(context, device);
  }

  Future<void> _deviceMenu(FavoriteDevice? favorite, Device? device) async {
    final add = favorite == null && device != null && device.ip != null;
    // Unverified devices in "My devices" get an extra "Verify this device" item: only verified ones are auto-accepted and auto-copied
    final verifyPage = favorite == null || verifiedFingerprints(ref.read(pairedDevicesProvider)).contains(favorite.fingerprint)
        ? null
        : verifyPageFor(peerType: knownDeviceType(favorite.fingerprint), online: device);
    final result = await showModalBottomSheet<_MenuChoice>(
      context: context,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (verifyPage != null)
              ListTile(
                leading: const Icon(LucideIcons.shieldCheck),
                title: Text(t.shareme.home.verifyDevice),
                onTap: () => Navigator.of(context).pop(_MenuChoice.verify),
              ),
            ListTile(
              leading: Icon(add ? LucideIcons.plus : LucideIcons.minus),
              title: Text(add ? t.shareme.home.addToMine : t.shareme.home.removeFromMine),
              onTap: () => Navigator.of(context).pop(_MenuChoice.addOrRemove),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (result == _MenuChoice.verify) {
      await context.push(verifyPage!);
      return;
    }
    if (add) {
      _addToMine(device);
    } else if (favorite != null) {
      if (!await confirmRemoveDevice(context, favorite.alias) || !mounted) return;
      ref.redux(favoritesProvider).dispatch(RemoveFavoriteAction(deviceFingerprint: favorite.fingerprint));
      ref.redux(pairedDevicesProvider).dispatch(RemovePairedRecordAction(favorite.fingerprint)); // drop its verification record too
    }
  }

  /// "Add" next to a nearby device: one tap adds it to "My devices" (unverified, so its transfers still ask; see
  /// [_deviceMenu] for verifying). Long-press a device row to remove it.
  void _addToMine(Device device) {
    final ip = device.ip;
    if (ip == null) return;
    ref
        .redux(favoritesProvider)
        .dispatch(AddFavoriteAction(FavoriteDevice.fromValues(fingerprint: device.fingerprint, ip: ip, port: device.port, alias: device.alias)));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final vm = context.watch(sendTabVmProvider);
    final server = context.watch(serverProvider);
    final history = context.watch(receiveHistoryProvider);
    final sessions = context.watch(sendProvider);
    final transfers = context.watch(fileTransferProvider);

    final nearby = vm.nearbyDevices.toList();
    for (final d in nearby) {
      rememberDeviceType(d.fingerprint, d.deviceType);
    }
    final favorites = vm.favoriteDevices;
    final verified = verifiedFingerprints(context.watch(pairedDevicesProvider));
    final favoriteFingerprints = favorites.map((f) => f.fingerprint).toSet();
    final unpaired = nearby.where((d) => !favoriteFingerprints.contains(d.fingerprint)).toList();
    final batch = _latestBatch(history);
    // "Just received" only covers the last day; older items are in "History"
    final recent = batch != null && DateTime.now().difference(batch.first.timestamp) < const Duration(days: 1) ? batch : null;
    // One-tap send: with a default device (the only one of my devices online, or the last target when several are
    // online), show it and send to it right after content is picked
    final target = sendTargetDevice(vm, defaultSendTarget(vm, lastTarget: lastSendTarget(ref)));
    Future<void> changeTarget() async {
      final fp = await showChooseMyDeviceSheet(context, current: target?.fingerprint);
      if (fp == null || !mounted) return;
      await rememberSendTarget(ref, fp);
      if (mounted) setState(() {});
    }

    SendSessionState? activeSession(String fingerprint) => sessions.values.firstWhereOrNull(
      (s) => s.target.fingerprint == fingerprint && (s.status == SessionStatus.waiting || s.status == SessionStatus.sending),
    );

    // ── Sections shared by the phone layout and the three-column desktop layout ──

    List<Widget> justReceived() {
      if (recent == null) return const [];
      return [
        _SectionHeader(title: t.shareme.home.justReceived, note: formatAgo(recent.first.timestamp)),
        _RecentCard(
          frames: [
            for (final e in recent)
              FilmFrame(fileName: e.fileName, fileType: e.fileType, path: e.path, isMessage: e.isMessage, inGallery: e.savedToGallery),
          ],
          fromAlias: recent.first.senderAlias,
          totalBytes: recent.fold<int>(0, (s, e) => s + e.fileSize),
          // The "original" tag gets a check only if every file in the batch had its SHA-256 verified (old entries are null)
          verified: recent.every((e) => e.checksumVerified == true),
          onTap: () => context.redux(homePageControllerProvider).dispatch(ChangeTabAction(HomeTab.history)),
        ),
      ];
    }

    Widget mineRow(FavoriteDevice f, double avatarSize) {
      final device = nearby.firstWhereOrNull((d) => d.fingerprint == f.fingerprint);
      final session = activeSession(f.fingerprint);
      return _DeviceRow(
        avatar: DeviceAvatar(
          deviceType: device?.deviceType ?? knownDeviceType(f.fingerprint),
          size: avatarSize,
          mine: true,
          verified: verified.contains(f.fingerprint),
          offline: device == null,
        ),
        name: f.alias,
        device: device,
        unverified: !verified.contains(f.fingerprint),
        session: session,
        transfers: transfers,
        onTap: device == null ? () => _toast(t.shareme.home.offlineTap(name: f.alias)) : () async => _tapDevice(device, session),
        onLongPress: () async => _deviceMenu(f, device),
      );
    }

    List<Widget> mineSection({required double avatarSize, VoidCallback? onScan, Widget? headerAction}) {
      final online = favorites.where((f) => nearby.any((d) => d.fingerprint == f.fingerprint)).toList();
      final offline = favorites.where((f) => !nearby.any((d) => d.fingerprint == f.fingerprint)).toList();
      final collapse = online.isNotEmpty && offline.length >= 2 && !_showOffline;
      return [
        _SectionHeader(title: t.shareme.home.myDevices, trailing: headerAction),
        if (favorites.isEmpty)
          _EmptyMine(onScan: onScan)
        else
          _Group(
            dividerIndent: 16 + avatarSize + 14,
            children: [
              for (final f in online) mineRow(f, avatarSize),
              if (collapse)
                _MoreRow(
                  text: t.shareme.home.offlineMore(n: offline.length),
                  indent: 16 + avatarSize + 14,
                  onTap: () => setState(() => _showOffline = true),
                )
              else
                for (final f in offline) mineRow(f, avatarSize),
            ],
          ),
      ];
    }

    List<Widget> nearbySection({required double avatarSize}) {
      if (unpaired.isEmpty) return const [];
      return [
        _SectionHeader(title: t.shareme.home.nearby),
        _Group(
          dividerIndent: 16 + avatarSize + 14,
          children: unpaired.map((d) {
            final session = activeSession(d.fingerprint);
            return _DeviceRow(
              avatar: DeviceAvatar(deviceType: d.deviceType, size: avatarSize),
              name: d.alias,
              device: d,
              showStatus: false,
              session: session,
              transfers: transfers,
              onTap: () async => _tapDevice(d, session),
              onLongPress: () async => _deviceMenu(null, d),
              // A PC seeing another PC: "Pair" (both sides compare 12 digits); other devices keep "Add"
              trailing: d.ip == null
                  ? null
                  : checkPlatformIsDesktop() && d.deviceType == DeviceType.desktop
                  ? _AddButton(
                      icon: LucideIcons.link,
                      label: t.shareme.pair.nearbyButton,
                      onTap: () async => context.push(() => SmPairNearbyPage(device: d)),
                    )
                  : _AddButton(onTap: () => _addToMine(d)),
            );
          }).toList(),
        ),
      ];
    }

    final selectionBar = vm.selectedFiles.isEmpty
        ? null
        : _SelectionBar(
            count: vm.selectedFiles.length,
            bytes: vm.selectedFiles.fold<int>(0, (sum, f) => sum + f.size),
            onClear: () => context.redux(selectedSendingFilesProvider).dispatch(ClearSelectionAction()),
          );

    // Only shown while receiving is off (server not running); normally there is no "Nearby devices can find you" line
    final receiveOff = server == null ? _Banner(text: t.shareme.home.meHidden) : null;

    // ── PC: three columns (the navigation rail lives in HomePage) → device column 300 | content ──
    if (useDesktopLayout(context)) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 300,
            child: ListView(
              padding: const EdgeInsets.only(top: 4, bottom: 16),
              children: [
                ?receiveOff,
                ...mineSection(
                  avatarSize: 40,
                  // PCs have no pull-to-refresh, so a small refresh button sits right of the title
                  headerAction: _HeaderIcon(icon: LucideIcons.refreshCw, tooltip: t.shareme.home.refresh, onTap: _rescan),
                ),
                _AddDeviceLink(onTap: () async => context.push(() => const SmPairHostPage())),
                ...nearbySection(avatarSize: 40),
              ],
            ),
          ),
          VerticalDivider(width: 1, thickness: 1, color: c.line),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 16, bottom: 24),
              children: [
                ?selectionBar,
                _DropZone(
                  // Use the name from "My devices" (it may have been renamed) to match the list on the left, not the peer's own name
                  targetName: target == null ? null : (favorites.firstWhereOrNull((f) => f.fingerprint == target.fingerprint)?.alias ?? target.alias),
                  onFiles: () async => pickAndSend(context, FilePickerOption.file),
                  onFolder: () async => pickAndSend(context, FilePickerOption.folder),
                  onText: () async => showSendTextSheet(context),
                ),
                ...justReceived(),
              ],
            ),
          ),
        ],
      );
    }

    // ── Phone ──
    // A narrow PC window also uses this phone layout; PCs don't scan (no camera permission on macOS) but show a QR code
    // instead, like "Add device" in Settings.
    Future<void> openScan() async => context.push(() => checkPlatformIsDesktop() ? const SmPairHostPage() : const SmPairScanPage());
    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            color: c.accent,
            backgroundColor: c.group,
            onRefresh: _rescan,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                _TopBar(onScan: openScan),
                ?receiveOff,
                ...justReceived(),
                ...mineSection(avatarSize: 46, onScan: openScan),
                ...nearbySection(avatarSize: 46),
              ],
            ),
          ),
        ),
        ?selectionBar,
        _SendDock(
          target: target,
          onChangeTarget: changeTarget,
          onMedia: () async => _pick(FilePickerOption.media),
          onFile: () async => _pick(FilePickerOption.file),
          onText: () async => showSendTextSheet(context), // send-text sheet
        ),
      ],
    );
  }
}

/// The latest received batch: the newest entry plus consecutive entries from the same sender within 2 minutes of each other.
List<ReceiveHistoryEntry>? _latestBatch(List<ReceiveHistoryEntry> history) {
  // Photos, videos and files only; received text / links are in "History"
  final files = history.where((e) => !e.isMessage).toList();
  if (files.isEmpty) return null;
  final sorted = files..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  final batch = <ReceiveHistoryEntry>[sorted.first];
  for (final e in sorted.skip(1)) {
    final prev = batch.last;
    if (e.senderAlias != prev.senderAlias || prev.timestamp.difference(e.timestamp).inMinutes >= 2) break;
    batch.add(e);
  }
  return batch;
}

/// Pick content → "Send to" sheet → send. Shared by the home page send dock and the "History" empty-state button.
Future<void> pickAndSend(BuildContext context, FilePickerOption option) async {
  final ref = context.ref;
  final effective = pickerOptions.contains(option) ? option : FilePickerOption.file;
  await ref.global.dispatchAsync(PickFileAction(option: effective, context: context));
  if (!context.mounted) return;
  await chooseTargetAndSend(context);
}

/// After content is picked: sends straight to the default device ([defaultSendTarget]) if there is one; otherwise shows
/// "Send to". Files dropped onto the PC window also come through here.
///
/// [confirm]: always show "Send to", so the user taps once before anything is sent. Used for content shared in from other
/// apps: any app on the phone can share text or files to Shuttle, and these used to go straight to the default device,
/// where the PC treated them as coming from "My devices": text went to the clipboard and files were saved automatically.
Future<void> chooseTargetAndSend(BuildContext context, {bool confirm = false}) async {
  final ref = context.ref;
  final files = ref.read(selectedSendingFilesProvider);
  if (files.isEmpty) return;
  final vm = ref.read(sendTabVmProvider);
  final direct = confirm ? null : sendTargetDevice(vm, defaultSendTarget(vm, lastTarget: lastSendTarget(ref)));
  if (direct != null) {
    await _sendSelectedTo(ref, direct);
    return;
  }
  final device = await showSendTargetSheet(
    context,
    count: files.length,
    bytes: files.fold<int>(0, (a, f) => a + f.size),
    // The peer doesn't have Shuttle: fall back to LocalSend's existing "share via link" (downloaded in a browser)
    onShareLink: () async => context.push(() => WebSharePage(files: files)),
  );
  if (device == null || !context.mounted) return; // sheet dismissed: keep the selection so a device row can still send it
  await rememberSendTarget(ref, device.fingerprint);
  if (!context.mounted) return;
  // Must read the latest vm: the vm captured on tap still has no selected files, and sending with it would show "Add
  // files" once more
  await ref.read(sendTabVmProvider).onTapDevice(context, device);
}

/// Starts sending the current selection directly. Not vm.onTapDevice: it uses the selection snapshot from when the vm was
/// built, which lacks the content just added, so it would show "Add to selection" once more.
Future<void> _sendSelectedTo(Ref ref, Device device) async {
  final files = ref.read(selectedSendingFilesProvider);
  ref.redux(selectedSendingFilesProvider).dispatch(ClearSelectionAction()); // don't leave "N selected" on the home page
  await rememberSendTarget(ref, device.fingerprint);
  await ref.notifier(sendProvider).startSession(target: device, files: files, background: false);
}

/// Sends the clipboard contents (text, image or files) to "My devices" (used by the PC tray menu and the phone's quick
/// settings tile). With a default device (the only one of my devices online, or the last target when several are online)
/// it sends directly, otherwise it shows "Send to". Devices may not be found yet right after the app opens, so it waits
/// up to 5 s.
Future<void> sendClipboard(BuildContext context) async {
  final ref = context.ref;
  ref.redux(selectedSendingFilesProvider).dispatch(ClearSelectionAction());
  await ref.global.dispatchAsync(PickFileAction(option: FilePickerOption.clipboard, context: context));
  if (!context.mounted) return;
  if (ref.read(selectedSendingFilesProvider).isEmpty) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(t.shareme.text.clipEmpty)));
    return;
  }
  final last = lastSendTarget(ref);
  var vm = ref.read(sendTabVmProvider);
  var target = defaultSendTarget(vm, lastTarget: last);
  for (var i = 0; target == null && i < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    vm = ref.read(sendTabVmProvider);
    target = defaultSendTarget(vm, lastTarget: last);
  }
  if (!context.mounted) return;
  final device = sendTargetDevice(vm, target);
  if (device == null) {
    await chooseTargetAndSend(context);
    return;
  }
  await _sendSelectedTo(ref, device);
}

// ───────────────────────── Widgets ─────────────────────────

/// Top bar: app icon + wordmark + scan button, 56 high.
class _TopBar extends StatelessWidget {
  final VoidCallback onScan;

  const _TopBar({required this.onScan});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.only(left: 20, right: 10),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Assets.img.logo128.image(width: 28, height: 28, filterQuality: FilterQuality.medium),
            ),
            const SizedBox(width: 10),
            Text('Shuttle', style: ShareMeText.brand.copyWith(color: c.ink)),
            const Spacer(),
            IconButton(
              tooltip: t.shareme.home.scanToPair,
              icon: const Icon(LucideIcons.scanQrCode),
              onPressed: onScan,
            ),
          ],
        ),
      ),
    );
  }
}

/// A banner that only appears when something is wrong (currently only "receiving is off").
class _Banner extends StatelessWidget {
  final String text;

  const _Banner({required this.text});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: c.warnContainer, borderRadius: BorderRadius.circular(14)),
        child: Row(
          children: [
            Icon(LucideIcons.wifiOff, size: 18, color: c.warn),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text, style: ShareMeText.meta.copyWith(color: c.ink)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Section header: title on the left (ink2); on the right, an optional small gray note (e.g. "12 h ago") or a small button.
class _SectionHeader extends StatelessWidget {
  final String title;
  final String? note;
  final Widget? trailing;

  const _SectionHeader({required this.title, this.note, this.trailing});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return Padding(
      padding: EdgeInsets.fromLTRB(22, 18, trailing == null ? 22 : 12, 8),
      child: Row(
        children: [
          Text(title, style: ShareMeText.section.copyWith(color: c.ink2)),
          const Spacer(),
          if (note != null) Text(note!, style: ShareMeText.meta.copyWith(color: c.ink2)),
          ?trailing,
        ],
      ),
    );
  }
}

/// Grouped list: white card (dark gray in dark mode), radius 22, soft shadow, 16 from the screen edge; the 1px row
/// dividers start where the text starts.
class _Group extends StatelessWidget {
  final List<Widget> children;
  final double dividerIndent;

  const _Group({required this.children, this.dividerIndent = 76});

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
                  if (i > 0) Divider(height: 1, thickness: 1, indent: dividerIndent, color: c.line),
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

/// No "My devices" yet: a title, one line on how to add one, and on phones a "Scan to pair" button.
class _EmptyMine extends StatelessWidget {
  final VoidCallback? onScan;

  const _EmptyMine({this.onScan});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return _Group(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
          child: Column(
            children: [
              const DeviceAvatar(size: 52, icon: LucideIcons.monitorSmartphone),
              const SizedBox(height: 14),
              Text(
                t.shareme.home.emptyTitle,
                style: ShareMeText.title.copyWith(color: c.ink),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                t.shareme.home.emptyBody,
                style: ShareMeText.meta.copyWith(color: c.ink2, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              if (onScan != null) ...[
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: onScan,
                  icon: const Icon(LucideIcons.scanQrCode, size: 18),
                  label: Text(t.shareme.home.scanToPair),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// "N more offline": tap to show them all.
class _MoreRow extends StatelessWidget {
  final String text;
  final double indent;
  final VoidCallback onTap;

  const _MoreRow({required this.text, required this.indent, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 50,
        child: Padding(
          padding: EdgeInsets.only(left: indent, right: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(text, style: ShareMeText.meta.copyWith(color: c.ink2, fontSize: 14)),
              ),
              Icon(LucideIcons.chevronDown, size: 20, color: c.ink3),
            ],
          ),
        ),
      ),
    );
  }
}

enum _MenuChoice { addOrRemove, verify }

/// Device row: "avatar | name and status | trailing control"; during a transfer, a transfer block expands under the name.
/// The status only says "Online / Online · remote / Offline"; verified devices get a small green check at the avatar's
/// bottom right, unverified ones get "· Not verified" after the status.
class _DeviceRow extends StatelessWidget {
  final Widget avatar;
  final String name;
  final Device? device;
  final SendSessionState? session;
  final FileTransferNotifier transfers;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;

  /// Nearby devices are online by definition, so no status is shown
  final bool showStatus;

  /// An unverified device in "My devices" (its transfers aren't auto-accepted)
  final bool unverified;

  const _DeviceRow({
    required this.avatar,
    required this.name,
    required this.device,
    required this.session,
    required this.transfers,
    required this.onTap,
    this.onLongPress,
    this.trailing,
    this.showStatus = true,
    this.unverified = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final online = device != null;
    // Found via Tailscale (or WebRTC across networks): say "remote", a hint that the speed depends on both networks
    final remote = device?.signalingId != null || isTailscaleIp(device?.ip);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 13, 12, 13),
        child: Row(
          crossAxisAlignment: session != null ? CrossAxisAlignment.start : CrossAxisAlignment.center,
          children: [
            avatar,
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    style: ShareMeText.deviceName.copyWith(color: online ? c.ink : c.ink2),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (showStatus) ...[
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (online) ...[
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(color: c.ok, shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Flexible(
                          child: Text(
                            (!online
                                    ? t.shareme.home.offline
                                    : remote
                                    ? t.shareme.home.viaTailscale
                                    : t.shareme.home.sameWifi) +
                                (unverified ? ' · ${t.shareme.home.unverified}' : ''),
                            style: ShareMeText.meta.copyWith(color: c.ink2),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (session != null) _TransferBlock(session: session!, transfers: transfers),
                ],
              ),
            ),
            // Keep a gap when the name fills the row exactly (a long name used to run into the "Pair" button)
            if (trailing != null)
              Padding(padding: const EdgeInsets.only(left: 10), child: trailing!)
            else
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(LucideIcons.chevronRight, size: 20, color: c.ink3),
              ),
          ],
        ),
      ),
    );
  }
}

/// "Add" next to a nearby device ("Pair" when a PC sees another PC).
class _AddButton extends StatelessWidget {
  final VoidCallback onTap;
  final IconData icon;
  final String? label;

  const _AddButton({required this.onTap, this.icon = LucideIcons.plus, this.label});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return Material(
      color: c.tonal,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 7, 14, 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: c.ink),
              const SizedBox(width: 4),
              Text(label ?? t.shareme.home.add, style: ShareMeText.label.copyWith(color: c.ink, fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Transfer block: caption + percentage / 6-high progress bar / numbers (sent/total, speed, time left).
class _TransferBlock extends StatelessWidget {
  final SendSessionState session;
  final FileTransferNotifier transfers;

  const _TransferBlock({required this.session, required this.transfers});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    var total = 0;
    var current = 0;
    for (final f in session.files.values) {
      if (transfers.getStatus(sessionId: session.sessionId, fileId: f.file.id) == FileStatus.skipped) continue;
      total += f.file.size;
      current += (transfers.getProgress(sessionId: session.sessionId, fileId: f.file.id) * f.file.size).round();
    }
    final waiting = session.status == SessionStatus.waiting;
    final ratio = total == 0 ? 0.0 : (current / total).clamp(0.0, 1.0);
    final start = session.startTime;
    final elapsedMs = start == null ? 0 : DateTime.now().millisecondsSinceEpoch - start;
    final speed = elapsedMs > 500 ? current / (elapsedMs / 1000) : 0.0;
    final remaining = speed > 0 ? Duration(seconds: ((total - current) / speed).round()) : null;

    return Padding(
      padding: const EdgeInsets.only(top: 10, right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  waiting
                      // Checksums are computed before the request goes out, so it isn't "waiting for acceptance" yet
                      ? (session.hashedFileCount < session.files.length
                            ? t.shareme.send.preparing(curr: session.hashedFileCount, n: session.files.length)
                            : t.shareme.home.waiting(n: session.files.length))
                      : t.shareme.home.sending(n: session.files.length),
                  style: ShareMeText.meta.copyWith(color: c.ink),
                ),
              ),
              if (!waiting) Text('${(ratio * 100).floor()}%', style: ShareMeText.data.copyWith(color: c.ink)),
            ],
          ),
          const SizedBox(height: 6),
          TweenAnimationBuilder<double>(
            tween: Tween(end: waiting ? 0 : ratio),
            duration: ShareMeMotion.short,
            builder: (context, value, _) => ClipRRect(
              borderRadius: BorderRadius.circular(ShareMeSize.radiusPill),
              child: LinearProgressIndicator(value: waiting ? null : value, minHeight: 6, color: c.accent, backgroundColor: c.tonalStrong),
            ),
          ),
          if (!waiting) ...[
            const SizedBox(height: 6),
            Text(
              [
                '${formatSize(current)}/${formatSize(total)}',
                if (speed > 0) formatSpeed(speed),
                if (remaining != null) t.shareme.home.remaining(time: formatDuration(remaining)),
              ].join('   '),
              style: ShareMeText.data.copyWith(color: c.ink2),
            ),
          ],
        ],
      ),
    );
  }
}

/// "Just received" card: thumbnails (up to 3 stacked) + "N items · size" + "From `name`" + an "original" tag. Tapping it
/// opens "History".
class _RecentCard extends StatelessWidget {
  final List<FilmFrame> frames;
  final String fromAlias;
  final int totalBytes;
  final bool verified;
  final VoidCallback onTap;

  const _RecentCard({required this.frames, required this.fromAlias, required this.totalBytes, required this.verified, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return _Group(
      children: [
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: Row(
              children: [
                _ThumbStack(frames: frames),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${t.shareme.home.edgeCount(n: frames.length)} · ${formatSize(totalBytes)}',
                        style: ShareMeText.title.copyWith(color: c.ink, fontSize: 15.5),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              t.shareme.home.fromName(name: fromAlias),
                              style: ShareMeText.meta.copyWith(color: c.ink2),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          OriginalChip(verified: verified),
                        ],
                      ),
                    ],
                  ),
                ),
                Icon(LucideIcons.chevronRight, size: 20, color: c.ink3),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Up to 3 stacked thumbnails (the first on top); a single-item batch is one 60 square.
class _ThumbStack extends StatelessWidget {
  final List<FilmFrame> frames;

  const _ThumbStack({required this.frames});

  static const _size = 60.0;
  static const _step = 16.0;

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final shown = frames.take(3).toList();
    final stacked = shown.length > 1;
    return SizedBox(
      width: _size + (shown.length - 1) * _step,
      height: _size,
      child: Stack(
        children: [
          for (var i = shown.length - 1; i >= 0; i--)
            Positioned(
              left: i * _step,
              top: 0,
              child: Container(
                decoration: stacked
                    ? BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: c.group, width: 2),
                      )
                    : null,
                child: FileThumb(frame: shown[i], size: stacked ? _size - 4 : _size, radius: 14),
              ),
            ),
        ],
      ),
    );
  }
}

/// Selected-files bar (above the send dock).
class _SelectionBar extends StatelessWidget {
  final int count;
  final int bytes;
  final VoidCallback onClear;

  const _SelectionBar({required this.count, required this.bytes, required this.onClear});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: DecoratedBox(
        decoration: smCardDecoration(c, radius: ShareMeSize.radiusButton),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.shareme.home.selected(n: count, size: formatSize(bytes)),
                      style: ShareMeText.title.copyWith(color: c.ink, fontSize: 15),
                    ),
                    Text(t.shareme.home.selectedHint, style: ShareMeText.meta.copyWith(color: c.ink2)),
                  ],
                ),
              ),
              TextButton(onPressed: onClear, child: Text(t.shareme.home.clear)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Send dock: "warm primary button | 74 | 74", 56 high, radius 18, pinned above the navigation bar.
/// With a default device, a "Send to [avatar] name ▾" pill above it says who picked content goes to; tap it to switch.
class _SendDock extends StatelessWidget {
  final Device? target;
  final VoidCallback onChangeTarget;
  final VoidCallback onMedia;
  final VoidCallback onFile;
  final VoidCallback onText;

  const _SendDock({
    required this.target,
    required this.onChangeTarget,
    required this.onMedia,
    required this.onFile,
    required this.onText,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final target = this.target;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (target != null) ...[
            DecoratedBox(
              decoration: smCardDecoration(c, radius: ShareMeSize.radiusPill),
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: onChangeTarget,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(t.shareme.home.sendTo, style: ShareMeText.meta.copyWith(color: c.ink2, fontSize: 13.5)),
                        const SizedBox(width: 8),
                        DeviceAvatar(deviceType: target.deviceType, size: 22, mine: true),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            target.alias,
                            style: ShareMeText.label.copyWith(color: c.ink, fontSize: 13.5),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Icon(LucideIcons.chevronDown, size: 16, color: c.ink2),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
          _dockButtons(),
        ],
      ),
    );
  }

  Widget _dockButtons() {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: onMedia,
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 16)),
            icon: const Icon(LucideIcons.images, size: 21),
            // Scales down instead of truncating when the system font size is larger (e.g. 1.25x)
            label: FittedBox(fit: BoxFit.scaleDown, child: Text(t.shareme.home.sendMedia, maxLines: 1)),
          ),
        ),
        const SizedBox(width: 10),
        _DockButton(icon: LucideIcons.file, label: t.shareme.home.file, onTap: onFile),
        const SizedBox(width: 10),
        _DockButton(icon: LucideIcons.type, label: t.shareme.home.text, onTap: onText),
      ],
    );
  }
}

class _DockButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _DockButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final radius = BorderRadius.circular(ShareMeSize.radiusButton);
    return DecoratedBox(
      decoration: smCardDecoration(c, radius: ShareMeSize.radiusButton),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: SizedBox(
            width: 74,
            height: ShareMeSize.buttonH,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 20, color: c.ink),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: ShareMeText.labelSm.copyWith(color: c.ink, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Desktop drop zone: solid card + warm round upload icon + a title + "or press Ctrl+V to send the clipboard" + three
/// small buttons.
/// - While dragging over: accent border, light warm background, "Release, then choose who to send to" (120 ms transition).
///   The OS doesn't say how many files or how big while dragging (desktop_drop only gives the file list on drop), so no
///   count is shown.
/// - "Drop onto a device on the left to send directly" isn't done yet: each row would need its own drop target, which
///   would compete with the window-wide one; left for later.
class _DropZone extends StatelessWidget {
  /// With a default device the title says "Drop here to send to `name`" (dropping sends right away)
  final String? targetName;
  final VoidCallback onFiles;
  final VoidCallback onFolder;
  final VoidCallback onText;

  const _DropZone({required this.targetName, required this.onFiles, required this.onFolder, required this.onText});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return ValueListenableBuilder<bool>(
      valueListenable: shareMeDragActive,
      builder: (context, active, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: AnimatedContainer(
            duration: ShareMeMotion.press,
            height: 300,
            decoration: BoxDecoration(
              color: active ? c.accentSoft : c.group,
              borderRadius: BorderRadius.circular(ShareMeSize.radiusGroup),
              border: Border.all(color: active ? c.accent : Colors.transparent, width: 2),
              boxShadow: c.cardShadow,
            ),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        gradient: ShareMeGradients.brand,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: ShareMeGradients.glow.withValues(alpha: 0.35),
                            blurRadius: 22,
                            spreadRadius: -8,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Icon(active ? LucideIcons.download : LucideIcons.upload, size: 28, color: Colors.white),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      targetName == null
                          ? (active ? t.shareme.home.dropActive : t.shareme.home.dropTitle)
                          : (active ? t.shareme.home.dropActiveTo(name: targetName!) : t.shareme.home.dropTitleTo(name: targetName!)),
                      style: ShareMeText.title.copyWith(color: c.ink, fontSize: 21, height: 28 / 21, fontWeight: FontWeight.w700),
                      textAlign: TextAlign.center,
                    ),
                    if (!active) ...[
                      const SizedBox(height: 6),
                      Text(
                        checkPlatform([TargetPlatform.macOS]) ? t.shareme.home.dropHintMac : t.shareme.home.dropHint,
                        style: ShareMeText.meta.copyWith(color: c.ink2, fontSize: 14),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 22),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 10,
                        runSpacing: 8,
                        children: [
                          _TonalChipButton(icon: LucideIcons.file, label: t.shareme.home.pickFiles, onTap: onFiles),
                          _TonalChipButton(icon: LucideIcons.folder, label: t.shareme.home.pickFolder, onTap: onFolder),
                          _TonalChipButton(icon: LucideIcons.type, label: t.shareme.home.sendTextOrLink, onTap: onText),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TonalChipButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _TonalChipButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return Material(
      color: c.tonal,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: c.ink),
              const SizedBox(width: 8),
              Text(label, style: ShareMeText.label.copyWith(color: c.ink, fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }
}

/// "+ Add device" in the desktop device column (opens the QR code page for a phone to scan).
class _AddDeviceLink extends StatelessWidget {
  final VoidCallback onTap;

  const _AddDeviceLink({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: onTap,
          icon: Icon(LucideIcons.plus, size: 18, color: c.ink2),
          label: Text(t.shareme.home.addDevice, style: ShareMeText.label.copyWith(color: c.ink2, fontSize: 14)),
        ),
      ),
    );
  }
}

/// Small icon button right of a section title ("Refresh" on the PC).
class _HeaderIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _HeaderIcon({required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 32, height: 28),
      iconSize: 17,
      icon: Icon(icon, color: c.ink3),
    );
  }
}
