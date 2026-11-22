import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/state/server/receive_session_state.dart';
import 'package:localsend_app/pages/home_page.dart';
import 'package:localsend_app/pages/receive_page.dart' show ReceivePageVm;
import 'package:localsend_app/pages/shareme_receive_page.dart';
import 'package:localsend_app/pages/shareme_receive_progress_page.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/paired_devices_provider.dart';
import 'package:localsend_app/provider/selection/selected_receiving_files_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/open_file.dart';
import 'package:localsend_app/util/native/open_folder.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/native/tray_helper.dart';
import 'package:localsend_app/util/shareme_format.dart';
import 'package:localsend_app/util/shareme_sender_identity.dart';
import 'package:localsend_app/widget/shareme/device_avatar.dart';
import 'package:localsend_app/widget/shareme/film_strip.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:logging/logging.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

final _logger = Logger('SmPopup');

/// Shuttle desktop receive popup in the bottom-right corner.
///
/// As the design suggests, no extra window is opened; the **main window temporarily becomes the popup**: 380 wide, no title bar,
/// always on top, in the bottom-right corner of the screen (12 above the taskbar). After done / declined / "decide later" the window
/// gets back its original size, position and state (hidden to the tray or minimized).
///
/// Used only while the main window is out of sight (in the tray or minimized); otherwise the full receive page is used as before.
/// Windows only for now (the design only covers Windows).
class SmPopupWindow {
  SmPopupWindow._();

  static bool active = false;

  /// Final state saved by receive_controller when an automatic receive finishes, before the session is closed.
  /// The popup's "done" view relies on it: the state recorded on UI rebuilds alone misses the last file
  /// (2 files sent showed "Received 1 item").
  static (ReceiveSessionState, Map<String, FileStatus>)? finalSnapshot;

  static Rect? _savedBounds;
  static bool _wasMaximized = false;
  static bool _wasMinimized = false;

  /// Set by the popup page to handle tray icon clicks (switch back to the normal window and show the full receive page)
  static Future<void> Function()? _expandHandler;

  /// Closing the window (Alt+F4) acts like Esc: "decide later"
  static Future<void> Function()? _laterHandler;

  static const _minimalSize = Size(400, 500); // same as window_dimensions_provider
  static const width = 380.0;

  /// Main window in the tray or minimized → use the popup
  static Future<bool> shouldUse() async {
    if (!checkPlatform([TargetPlatform.windows])) return false;
    try {
      return await windowManager.isMinimized() || !(await windowManager.isVisible());
    } catch (e) {
      _logger.warning('Could not read window state', e);
      return false;
    }
  }

  static Future<void> enter(double height) async {
    if (active) {
      await resize(height);
      return;
    }
    active = true;
    finalSnapshot = null;
    try {
      _wasMinimized = await windowManager.isMinimized();
      _wasMaximized = await windowManager.isMaximized();
      if (_wasMinimized) await windowManager.restore();
      if (_wasMaximized) await windowManager.unmaximize();
      _savedBounds = await windowManager.getBounds();
      await windowManager.setMinimumSize(const Size(width, 160));
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
      await windowManager.setResizable(false);
      await windowManager.setAlwaysOnTop(true);
      await _place(height);
      // Don't steal focus, so someone who is typing isn't interrupted
      await windowManager.show(inactive: true);
    } catch (e) {
      _logger.warning('Could not enter popup mode', e);
    }
  }

  static Future<void> resize(double height) async {
    if (!active) return;
    try {
      await _place(height);
    } catch (e) {
      _logger.warning('Could not resize popup', e);
    }
  }

  static Future<void> _place(double height) async {
    final display = await screenRetriever.getPrimaryDisplay();
    final area = display.visibleSize ?? display.size;
    final origin = display.visiblePosition ?? Offset.zero;
    await windowManager.setBounds(
      Rect.fromLTWH(origin.dx + area.width - width - 12, origin.dy + area.height - height - 12, width, height),
    );
  }

  /// Leaves popup mode. [showMain] = switch to the normal window and show it; otherwise return to the previous state (tray or minimized).
  static Future<void> exit({required bool showMain}) async {
    if (!active) return;
    try {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      await windowManager.setResizable(true);
      await windowManager.setMinimumSize(_minimalSize);
      final bounds = _savedBounds;
      if (bounds != null) await windowManager.setBounds(bounds);
      if (_wasMaximized) await windowManager.maximize();
      active = false;
      if (showMain) {
        await showFromTray();
      } else if (_wasMinimized) {
        await windowManager.minimize();
      } else {
        await hideToTray();
      }
    } catch (e) {
      active = false;
      _logger.warning('Could not leave popup mode', e);
    }
  }

  /// The popup was closed (called by WindowWatcher): treated as "decide later"
  static Future<bool> closeRequested() async {
    final handler = _laterHandler;
    if (!active || handler == null) return false;
    await handler();
    return true;
  }

  /// The tray icon was clicked (called by TrayWatcher)
  static Future<bool> expandFromTray() async {
    final handler = _expandHandler;
    if (!active || handler == null) return false;
    await handler();
    return true;
  }
}

/// Popup content: request → progress → done, switched in place.
class SmReceivePopupPage extends StatefulWidget {
  /// Passed in by receive_controller for a file request; needed to switch to the full receive page on "decide later" or a tray click.
  /// Null for an automatic receive (files from my devices are accepted directly).
  final ViewProvider<ReceivePageVm>? vm;

  const SmReceivePopupPage({this.vm, super.key});

  @override
  State<SmReceivePopupPage> createState() => _SmReceivePopupPageState();
}

class _SmReceivePopupPageState extends State<SmReceivePopupPage> with Refena {
  // After an automatic receive, receive_controller closes the session, so the done state is shown from this snapshot
  ReceiveSessionState? _last;
  Map<String, FileStatus> _lastStatuses = {};
  bool _remember = false;
  bool _hovering = false;
  bool _closing = false;
  double? _height;
  Timer? _autoClose;
  Timer? _tick;
  final _samples = <(int, int)>[];
  double _speed = 0;
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    SmPopupWindow._expandHandler = _expand;
    SmPopupWindow._laterHandler = _later;
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      final session = ref.read(serverProvider)?.session;
      if (session != null && session.status == SessionStatus.sending) {
        final now = DateTime.now().millisecondsSinceEpoch;
        _samples.add((now, _bytes(session, ref.read(fileTransferProvider)).$2));
        _samples.removeWhere((s) => now - s.$1 > 3000);
        if (_samples.length >= 2) {
          final (t0, b0) = _samples.first;
          final (t1, b1) = _samples.last;
          _speed = t1 > t0 ? (b1 - b0) / ((t1 - t0) / 1000) : 0;
        }
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    if (SmPopupWindow._expandHandler == _expand) SmPopupWindow._expandHandler = null;
    if (SmPopupWindow._laterHandler == _later) SmPopupWindow._laterHandler = null;
    _tick?.cancel();
    _autoClose?.cancel();
    _focus.dispose();
    super.dispose();
  }

  // ───── Actions ─────

  Future<void> _accept(ReceiveSessionState session) async {
    // Shuttle security: a device whose certificate was never verified can't be "remembered" as one of my devices
    if (_remember && session.sender.ip != null && !isUnverifiedFingerprint(session.sender.fingerprint)) {
      ref
          .redux(favoritesProvider)
          .dispatch(
            AddFavoriteAction(
              FavoriteDevice.fromValues(
                fingerprint: session.sender.fingerprint,
                ip: session.sender.ip!,
                port: session.sender.port,
                alias: session.sender.alias,
              ),
            ),
          );
    }
    await ref.notifier(serverProvider).acceptFileRequest(ref.read(selectedReceivingFilesProvider));
  }

  Future<void> _decline() async {
    ref.notifier(serverProvider).declineFileRequest();
    await _finish();
  }

  Future<void> _cancel() async {
    ref.notifier(serverProvider).cancelSession();
    await _finish();
  }

  /// Finish: close the session, switch the home page back to "Transfer" and restore the window's previous state
  Future<void> _finish() async {
    if (_closing) return;
    _closing = true;
    _autoClose?.cancel();
    final session = ref.read(serverProvider)?.session;
    if (session != null && session.status != SessionStatus.waiting && session.status != SessionStatus.sending) {
      ref.notifier(serverProvider).closeSession();
    }
    await SmPopupWindow.exit(showMain: false);
    if (!mounted) return;
    // Routerino.context is the global navigator context, not this State's (LocalSend uses it the same way elsewhere)
    // ignore: use_build_context_synchronously
    unawaited(Routerino.context.pushRootImmediately(() => const HomePage(initialTab: HomeTab.transfer, appStart: false)));
  }

  /// Esc: "decide later" — don't decline, just hide the popup; opening from the tray later shows the full receive page
  Future<void> _later() async {
    final session = ref.read(serverProvider)?.session;
    if (session == null || session.status != SessionStatus.waiting) {
      await _finish();
      return;
    }
    _closing = true;
    final vm = widget.vm;
    if (vm != null) {
      unawaited(Routerino.context.pushReplacement(() => SmReceivePage(vm)));
    }
    await SmPopupWindow.exit(showMain: false);
    await setTrayReminder(true); // the request is still pending: add a reminder dot to the tray icon
  }

  /// Tray icon clicked: switch to the normal window and the full page
  Future<void> _expand() async {
    _closing = true;
    _autoClose?.cancel();
    final session = ref.read(serverProvider)?.session;
    final vm = widget.vm;
    if (session != null && session.status == SessionStatus.waiting && vm != null) {
      unawaited(Routerino.context.pushReplacement(() => SmReceivePage(vm)));
    } else if (session != null) {
      unawaited(Routerino.context.pushReplacement(() => SmReceiveProgressPage(sessionId: session.sessionId)));
    } else {
      unawaited(Routerino.context.pushRootImmediately(() => const HomePage(initialTab: HomeTab.transfer, appStart: false)));
    }
    await SmPopupWindow.exit(showMain: true);
  }

  void _armAutoClose() {
    if (_autoClose != null || _closing) return;
    // The done state closes itself after 8 seconds, but not while the mouse hovers over it
    _autoClose = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_hovering) return;
      if (timer.tick >= 8) {
        timer.cancel();
        unawaited(_finish());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final live = context.watch(serverProvider)?.session;
    final transfers = context.watch(fileTransferProvider);
    if (live != null) {
      _last = live;
      _lastStatuses = {for (final f in live.files.values) f.file.id: transfers.getStatus(sessionId: live.sessionId, fileId: f.file.id)};
    }
    final snapshot = SmPopupWindow.finalSnapshot;
    if (live == null && snapshot != null) {
      _last = snapshot.$1;
      _lastStatuses = snapshot.$2;
    }
    final session = live ?? _last;
    final favorites = context.watch(favoritesProvider);
    final isMine = favorites.any((f) => f.fingerprint == session?.sender.fingerprint);
    final verified =
        session != null &&
        isVerifiedMine(favorites: favorites, paired: context.watch(pairedDevicesProvider), fingerprint: session.sender.fingerprint);

    final Widget body;
    final double height;
    final status = live == null && _last != null && _last!.status == SessionStatus.sending
        ? SessionStatus
              .finished // automatic receive: the session is closed right after the last file, so show it as done
        : session?.status;
    if (session == null) {
      body = const SizedBox.shrink();
      height = 160;
    } else {
      switch (status) {
        case SessionStatus.waiting:
          height = isMine ? 300 : 340;
          body = _Request(
            session: session,
            isMine: isMine,
            verified: verified,
            remember: _remember,
            onRemember: (v) => setState(() => _remember = v),
            onDecline: _decline,
            onAccept: () => _accept(session),
          );
        case SessionStatus.sending:
          height = 236;
          body = _Progress(session: session, transfers: transfers, isMine: isMine, speed: _speed, onCancel: _cancel);
        case SessionStatus.finished || SessionStatus.finishedWithErrors:
          height = 330;
          _armAutoClose();
          body = _Done(session: session, statuses: _lastStatuses, isMine: isMine, onClose: _finish);
        default:
          height = 160;
          _armAutoClose();
          body = _Message(text: t.shareme.receive.canceledBySender, onClose: _finish);
      }
    }
    if (height != _height) {
      _height = height;
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(SmPopupWindow.resize(height)));
    }

    return Scaffold(
      backgroundColor: c.group,
      body: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => unawaited(_later())},
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          child: MouseRegion(
            onEnter: (_) => _hovering = true,
            onExit: (_) => _hovering = false,
            child: DecoratedBox(
              decoration: BoxDecoration(border: Border.all(color: c.line)),
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}

(int, int) _bytes(ReceiveSessionState s, FileTransferNotifier t) {
  var total = 0;
  var current = 0;
  for (final f in s.files.values) {
    if (t.getStatus(sessionId: s.sessionId, fileId: f.file.id) == FileStatus.skipped) continue;
    total += f.file.size;
    current += (t.getProgress(sessionId: s.sessionId, fileId: f.file.id) * f.file.size).round();
  }
  return (total, current);
}

// ───────────────────────── The three states ─────────────────────────

/// Header: 40 px device avatar + name + a subtitle line + close button at the top right
class _Header extends StatelessWidget {
  final ReceiveSessionState session;
  final bool isMine;
  final Widget subtitle;
  final VoidCallback? onClose;

  const _Header({required this.session, required this.isMine, required this.subtitle, this.onClose});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
      child: Row(
        children: [
          DeviceAvatar(deviceType: session.sender.deviceType, size: 40, mine: isMine),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session.senderAlias,
                  style: ShareMeText.deviceNameSm.copyWith(color: c.ink, fontSize: 17),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle,
              ],
            ),
          ),
          if (onClose != null)
            IconButton(
              icon: Icon(LucideIcons.x, size: 16, color: c.ink2),
              onPressed: onClose,
            ),
        ],
      ),
    );
  }
}

class _Request extends StatelessWidget {
  final ReceiveSessionState session;
  final bool isMine;

  /// A verified "My devices" entry (unverified ones also end up here and are asked)
  final bool verified;
  final bool remember;
  final ValueChanged<bool> onRemember;
  final VoidCallback onDecline;
  final VoidCallback onAccept;

  const _Request({
    required this.session,
    required this.isMine,
    required this.verified,
    required this.remember,
    required this.onRemember,
    required this.onDecline,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final files = session.files.values.toList();
    final bytes = files.fold<int>(0, (a, f) => a + f.file.size);
    final shown = files.take(5).toList();
    final more = files.length - shown.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          session: session,
          isMine: isMine,
          subtitle: Text(
            t.shareme.receive.wantsToSend(n: files.length, size: formatSize(bytes)),
            style: ShareMeText.meta.copyWith(color: c.ink2),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              for (final f in shown) ...[
                FileThumb(
                  frame: FilmFrame(fileName: f.file.fileName, fileType: f.file.fileType, path: null),
                  size: 56,
                ),
                const SizedBox(width: 4),
              ],
              if (more > 0)
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(color: c.tonal, borderRadius: BorderRadius.circular(ShareMeSize.radiusFrame)),
                  alignment: Alignment.center,
                  child: Text('+$more', style: ShareMeText.data.copyWith(color: c.ink2, fontSize: 13)),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: isMine
              ? Text(
                  verified ? t.shareme.receive.mineVerified : t.shareme.receive.mineUnchecked,
                  style: ShareMeText.meta.copyWith(color: verified ? c.ok : c.ink2),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.shareme.receive.popupStranger, style: ShareMeText.meta.copyWith(color: c.warn)),
                    const SizedBox(height: 2),
                    Text(
                      '${t.shareme.receive.fingerprint}  ${groupFingerprint(session.sender.fingerprint)}',
                      style: ShareMeText.data.copyWith(color: c.ink2, fontSize: 11.5),
                    ),
                  ],
                ),
        ),
        // Devices whose certificate was never verified can't be "remembered".
        // Ticking it only adds the device to "My devices" and it is still asked next time (accepting directly needs QR or pairing
        // verification), so the label no longer promises "accept directly from now on".
        if (!isMine && !isUnverifiedFingerprint(session.sender.fingerprint))
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 16, 0),
            child: Row(
              children: [
                Checkbox(value: remember, onChanged: (v) => onRemember(v ?? false)),
                Expanded(
                  child: Text(t.shareme.home.addToMine, style: ShareMeText.meta.copyWith(color: c.ink2)),
                ),
              ],
            ),
          ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: onDecline,
                  style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(40)),
                  child: Text(t.shareme.receive.decline),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: onAccept,
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(40)),
                  child: Text(t.shareme.receive.accept),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            t.shareme.receive.popupEsc,
            style: ShareMeText.meta.copyWith(color: c.ink3, fontSize: 11.5),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

class _Progress extends StatelessWidget {
  final ReceiveSessionState session;
  final FileTransferNotifier transfers;
  final bool isMine;
  final double speed;
  final VoidCallback onCancel;

  const _Progress({required this.session, required this.transfers, required this.isMine, required this.speed, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final (total, current) = _bytes(session, transfers);
    final ratio = total == 0 ? 0.0 : (current / total).clamp(0.0, 1.0);
    final files = session.files.values.toList();
    final done = files.where((f) => transfers.getStatus(sessionId: session.sessionId, fileId: f.file.id) == FileStatus.finished).length;
    final left = speed > 0 ? Duration(seconds: ((total - current) / speed).round()) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          session: session,
          isMine: isMine,
          subtitle: Text(
            '${t.shareme.receive.popupReceiving} · ${t.shareme.receive.popupFileOf(i: (done + 1).clamp(1, files.length), n: files.length)}',
            style: ShareMeText.meta.copyWith(color: c.ink2),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${(ratio * 100).floor()}%',
                style: ShareMeText.dataLg.copyWith(color: c.ink, fontSize: 30, height: 34 / 30),
              ),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('${formatSize(current)} / ${formatSize(total)}', style: ShareMeText.data.copyWith(color: c.ink2)),
                  Text(
                    // Speed needs two samples; until then don't show "0.0 MB/s"
                    [if (speed > 0) formatSpeed(speed), if (left != null) t.shareme.receive.popupLeft(time: formatDuration(left))].join(' · '),
                    style: ShareMeText.data.copyWith(color: c.ink2),
                  ),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(value: ratio, minHeight: 6, color: c.ink, backgroundColor: c.tonal),
          ),
        ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
          child: ElevatedButton(
            onPressed: onCancel,
            style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(40)),
            child: Text(t.shareme.receive.cancelReceive),
          ),
        ),
      ],
    );
  }
}

class _Done extends StatelessWidget {
  final ReceiveSessionState session;
  final Map<String, FileStatus> statuses;
  final bool isMine;
  final VoidCallback onClose;

  const _Done({required this.session, required this.statuses, required this.isMine, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final ref = context.ref;
    final done = session.files.values.where((f) => statuses[f.file.id] == FileStatus.finished || f.path != null || f.savedToGallery).toList();
    final bytes = done.fold<int>(0, (a, f) => a + f.file.size);
    final start = session.startTime;
    final end = session.endTime ?? DateTime.now().millisecondsSinceEpoch;
    final elapsed = start != null ? Duration(milliseconds: end - start) : null;
    final verified = ref.read(settingsProvider).verifyChecksums && done.isNotEmpty && done.every((f) => f.file.hash != null);
    final firstPath = done.map((f) => f.path).whereType<String>().firstOrNull;
    final folder = firstPath != null ? File(firstPath).parent.path : session.destinationDirectory;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          session: session,
          isMine: isMine,
          onClose: onClose,
          subtitle: Text(
            [
              t.shareme.receive.receivedTitle(n: done.length),
              if (elapsed != null) formatDuration(elapsed),
            ].join(' · '),
            style: ShareMeText.meta.copyWith(color: c.ink2),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 10),
        if (done.isNotEmpty)
          FilmStrip(
            frames: [
              for (final f in done)
                FilmFrame(fileName: f.desiredName ?? f.file.fileName, fileType: f.file.fileType, path: f.path, inGallery: f.savedToGallery),
            ],
            fromAlias: session.senderAlias,
            totalBytes: bytes,
            sealFingerprint: isMine ? session.sender.fingerprint : null,
            verified: verified,
            animateStamp: true,
            frameSize: 56,
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Text(
            t.shareme.receive.popupSavedTo(path: folder),
            style: ShareMeText.data.copyWith(color: c.ink2, fontSize: 11.5),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
          child: Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: () async => openFolder(folderPath: folder),
                  style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(40)),
                  child: FittedBox(fit: BoxFit.scaleDown, child: Text(t.shareme.receive.openFolder, maxLines: 1)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: firstPath == null ? null : () async => openFile(context, done.first.file.fileType, firstPath),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(40)),
                  child: Text(t.shareme.receive.open),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  final String text;
  final VoidCallback onClose;

  const _Message({required this.text, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(text, style: ShareMeText.title.copyWith(color: c.ink)),
          const Spacer(),
          ElevatedButton(
            onPressed: onClose,
            style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(40)),
            child: Text(t.shareme.receive.close),
          ),
        ],
      ),
    );
  }
}
