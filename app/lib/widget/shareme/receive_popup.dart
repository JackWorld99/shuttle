import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/state/server/receive_session_state.dart';
import 'package:localsend_app/model/state/server/receiving_file.dart';
import 'package:localsend_app/pages/home_page.dart';
import 'package:localsend_app/pages/receive_page.dart' show ReceivePageVm;
import 'package:localsend_app/pages/shareme_receive_page.dart';
import 'package:localsend_app/pages/shareme_receive_progress_page.dart';
import 'package:localsend_app/provider/animation_provider.dart';
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
import 'package:localsend_app/util/native/win_window.dart';
import 'package:localsend_app/util/shareme_file_safety.dart';
import 'package:localsend_app/util/shareme_format.dart';
import 'package:localsend_app/util/shareme_sender_identity.dart';
import 'package:localsend_app/widget/shareme/ambient.dart';
import 'package:localsend_app/widget/shareme/device_avatar.dart';
import 'package:localsend_app/widget/shareme/film_strip.dart';
import 'package:localsend_app/widget/shareme/motion.dart';
import 'package:localsend_app/widget/shareme/progress_bar.dart';
import 'package:localsend_app/widget/shareme/transfer_stage.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:logging/logging.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
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

  /// On screen. False while it's being set up, out of sight
  static final shown = ValueNotifier(true);

  static WinWindow? _window;

  // The window as it was before
  static WinPlacement? _placement;
  static WinRect? _bounds;
  static bool _alwaysOnTop = false;

  /// Set by the popup page to handle tray icon clicks (switch back to the normal window and show the full receive page)
  static Future<void> Function()? _expandHandler;

  /// Closing the window (Alt+F4) acts like Esc: "decide later"
  static Future<void> Function()? _laterHandler;

  /// Set by the popup page: makes way for something that needs the normal window
  static Future<void> Function()? _makeWayHandler;

  /// Set by the popup page: it is about to be replaced and must not close the window any more
  static VoidCallback? _retireHandler;

  /// The window is becoming the popup
  static Future<void>? _entering;

  /// The popup is being left; a new transfer waits until the window is back in its previous state
  static Future<void>? _leaving;

  /// Windows lets a window that is closed or minimized fade out; only then it gets its normal shape back, unseen
  static const _fadeOut = Duration(milliseconds: 250);

  static const _minimalSize = Size(400, 500); // same as window_dimensions_provider
  static const width = 380.0;

  /// One height for every state: the window never jumps while files arrive. Larger system text makes the first row taller.
  static double get height => (212 + textRoom(WidgetsBinding.instance.platformDispatcher.textScaleFactor)).ceilToDouble();

  /// Extra height of the first row for larger system text (its two lines are 41 tall at the normal size)
  static double textRoom(double textScale) => 41 * (textScale.clamp(1.0, _maxTextScale) - 1);

  static const _maxTextScale = 1.6;

  /// Main window in the tray or minimized, or still showing the popup of the transfer before → use the popup
  static Future<bool> shouldUse() async {
    if (!checkPlatform([TargetPlatform.windows])) return false;
    await _leaving;
    if (active) return true;
    try {
      return await windowManager.isMinimized() || !(await windowManager.isVisible());
    } catch (e) {
      _logger.warning('Could not read window state', e);
      return false;
    }
  }

  /// Shows the popup for a request ([vm]) or an automatic receive. It replaces one that is still open (the previous "Received"), whose
  /// timer would otherwise close the window under the new one.
  static Future<void> open(ViewProvider<ReceivePageVm>? vm) async {
    final window = await WinWindow.main();
    // Routerino.context is the global navigator context (LocalSend uses it the same way elsewhere)
    // ignore: use_build_context_synchronously
    final navigator = Navigator.of(Routerino.context);
    final route = PageRouteBuilder<void>(
      settings: const RouteSettings(name: 'SmReceivePopupPage'),
      requestFocus: false,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => SmReceivePopupPage(vm: vm),
    );
    Future<void> show() async {
      finalSnapshot = null;
      if (active) {
        _retireHandler?.call();
        navigator.popUntil((r) => r.settings.name == 'SmReceivePopupPage' || r.isFirst);
        unawaited(navigator.pushReplacement(route));
        await _askedForFocus();
        window?.showInactive(); // it may have been minimized
        await WinWindow.drawn();
      } else {
        unawaited(navigator.push(route));
        await _enter(window);
      }
    }

    await (window == null ? show() : window.quietly(show));
  }

  /// Flutter asks for the keyboard right after a change of pages. If that happens while a minimized window is being restored, Windows
  /// grants it, whatever the window says; before, it doesn't.
  static Future<void> _askedForFocus() => Future<void>.delayed(Duration.zero);

  /// Back to the normal window, if the popup is open (it is only open after its transfer is over: there is one transfer at a time)
  static Future<void> makeWay() async {
    await _entering;
    await _leaving;
    if (!active) return;
    final handler = _makeWayHandler;
    await (handler != null ? handler() : exit(showMain: true));
  }

  static Future<void> _enter(WinWindow? window) async {
    active = true;
    shown.value = false;
    final entering = Completer<void>();
    _entering = entering.future;
    try {
      _window = window;
      if (window == null) throw StateError('No window');
      await window.behindCloak(() async {
        _placement = window.placement;
        _alwaysOnTop = window.alwaysOnTop;
        await _askedForFocus();
        window.showInactive();
        _bounds = window.bounds;
        await windowManager.setMinimumSize(const Size(width, 160));
        await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
        await windowManager.setResizable(false);
        window.setAlwaysOnTop(true);
        window.moveToCorner(Size(width, height), margin: 12);
        // Hidden in the tray, the app runs without animations (hideToTray); the popup is on screen
        RefenaScope.defaultRef.notifier(sleepProvider).setState((_) => false);
      });
    } catch (e) {
      _logger.warning('Could not enter popup mode', e);
      await showFromTray(); // the request must be seen
    } finally {
      shown.value = true;
      _entering = null;
      entering.complete();
    }
  }

  /// Leaves popup mode. [showMain] = switch to the normal window and show it; otherwise return to the previous state (tray or minimized).
  /// The popup is out of sight as soon as this is called, so the pages beneath it can be changed right after.
  static Future<void> exit({required bool showMain}) async {
    if (!active) return;
    final leavingAlready = _leaving;
    if (leavingAlready != null) {
      await leavingAlready;
      if (showMain) await showFromTray();
      return;
    }
    final leaving = Completer<void>();
    _leaving = leaving.future;
    try {
      if (_entering != null) await _entering;
      final window = _window;
      final placement = _placement;
      final bounds = _bounds;
      if (window == null || placement == null || bounds == null) {
        await _normalShape();
        active = false;
        await (showMain ? showFromTray() : hideToTray());
      } else if (showMain) {
        await window.behindCloak(() async {
          await _normalShape();
          window.setAlwaysOnTop(_alwaysOnTop);
          window.moveTo(bounds);
          if (placement.maximized) await windowManager.maximize();
          active = false;
          await showFromTray();
        });
        await windowManager.focus();
      } else {
        await window.quietly(() async {
          if (placement.minimized) {
            window.minimizeInactive();
          } else {
            window.hide();
            await hideToTray();
          }
          await Future<void>.delayed(_fadeOut);
          await _normalShape();
          window.setAlwaysOnTop(_alwaysOnTop);
          if (placement.minimized) {
            window.setMinimizedPlacement(placement);
          } else {
            window.moveTo(bounds);
            if (placement.maximized) maximizeOnceShown();
          }
        });
      }
    } catch (e) {
      _logger.warning('Could not leave popup mode', e);
    } finally {
      active = false;
      _leaving = null;
      leaving.complete();
    }
  }

  static Future<void> _normalShape() async {
    await windowManager.setTitleBarStyle(TitleBarStyle.normal);
    await windowManager.setResizable(true);
    await windowManager.setMinimumSize(_minimalSize);
  }

  /// The popup was closed (called by WindowWatcher): treated as "decide later". Popup mode always ends, whatever page is in the window.
  static Future<bool> closeRequested() async {
    await _entering;
    if (_leaving != null) {
      await _leaving;
      return true;
    }
    if (!active) return false;
    final handler = _laterHandler;
    await (handler != null ? handler() : exit(showMain: false));
    return true;
  }

  /// The tray icon was clicked (called by TrayWatcher), or the app was started a second time
  static Future<bool> expandFromTray() async {
    await _entering;
    await _leaving;
    if (!active) return false;
    final handler = _expandHandler;
    await (handler != null ? handler() : exit(showMain: true));
    return true;
  }
}

/// In place at once, while the window is out of sight. Going away again, the page fades like any other.
class _AtOnce extends RouterinoTransition {
  const _AtOnce();

  @override
  PageRoute<T> getRoute<T, W extends Widget>(SimpleWidgetBuilder<W> builder) => PageRouteBuilder(
    settings: RouteSettings(name: W.toString()),
    transitionDuration: Duration.zero,
    reverseTransitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (_, animation, _) => FadeTransition(opacity: animation, child: builder()),
  );
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
  bool _hovering = false;
  bool _closing = false;
  Timer? _autoClose;
  Timer? _tick;

  /// Once the last file is here, the number and the bar first run up to 100 before the result replaces them
  static const _fillUp = Duration(milliseconds: 440);
  Timer? _fillTimer;
  bool _wasReceiving = false;
  bool _filled = false;
  final _samples = <(int, int)>[];
  double _speed = 0;
  final _focus = FocusNode();

  // For Esc: the popup takes the keyboard when the user turns to it, not by itself
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    SmPopupWindow._expandHandler = _expand;
    SmPopupWindow._laterHandler = _later;
    SmPopupWindow._makeWayHandler = _makeWay;
    SmPopupWindow._retireHandler = _retire;
    _lifecycle = AppLifecycleListener(onResume: _focus.requestFocus);
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
    if (SmPopupWindow._expandHandler == _expand) {
      SmPopupWindow._expandHandler = null;
      SmPopupWindow._laterHandler = null;
      SmPopupWindow._makeWayHandler = null;
      SmPopupWindow._retireHandler = null;
      // Something else took this page away: no other page may be left in the popup
      if (!_closing) Timer.run(() => unawaited(SmPopupWindow.exit(showMain: false)));
    }
    _tick?.cancel();
    _autoClose?.cancel();
    _fillTimer?.cancel();
    _lifecycle.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ───── Actions ─────

  Future<void> _accept() async {
    await ref.notifier(serverProvider).acceptFileRequest(ref.read(selectedReceivingFilesProvider));
  }

  /// "Add" once files from an unknown device have arrived. It is still asked next time: accepting directly needs pairing.
  /// Shuttle security: a device whose certificate was never verified can't be added.
  void _add(ReceiveSessionState session) {
    if (session.sender.ip == null || isUnverifiedFingerprint(session.sender.fingerprint)) return;
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
    final left = SmPopupWindow.exit(showMain: false);
    unawaited(Routerino.context.pushRootImmediately(() => const HomePage(initialTab: HomeTab.transfer, appStart: false)));
    await left;
  }

  void _retire() {
    _closing = true;
    _autoClose?.cancel();
  }

  /// Esc: "decide later" — don't decline, just hide the popup; opening from the tray later shows the full receive page
  Future<void> _later() async {
    final session = ref.read(serverProvider)?.session;
    if (session == null || session.status != SessionStatus.waiting) {
      await _finish();
      return;
    }
    if (_closing) return;
    _closing = true;
    final left = SmPopupWindow.exit(showMain: false);
    final vm = widget.vm;
    if (vm != null) {
      unawaited(Routerino.context.pushReplacement(() => SmReceivePage(vm), transition: const _AtOnce()));
    }
    await setTrayReminder(true); // the request is still pending: add a reminder dot to the tray icon
    await left;
  }

  /// Tray icon clicked: switch to the normal window and the full page
  Future<void> _expand() async {
    if (_closing) return;
    _closing = true;
    _autoClose?.cancel();
    final left = SmPopupWindow.exit(showMain: true);
    final session = ref.read(serverProvider)?.session;
    final vm = widget.vm;
    if (session != null && session.status == SessionStatus.waiting && vm != null) {
      unawaited(Routerino.context.pushReplacement(() => SmReceivePage(vm), transition: const _AtOnce()));
    } else if (session != null) {
      unawaited(Routerino.context.pushReplacement(() => SmReceiveProgressPage(sessionId: session.sessionId), transition: const _AtOnce()));
    } else {
      unawaited(Routerino.context.pushRootImmediately(() => const HomePage(initialTab: HomeTab.transfer, appStart: false)));
    }
    await left;
  }

  /// A text arrived: the normal window, with the home page
  Future<void> _makeWay() async {
    if (_closing) return;
    _closing = true;
    _autoClose?.cancel();
    final left = SmPopupWindow.exit(showMain: true);
    unawaited(Routerino.context.pushRootImmediately(() => const HomePage(initialTab: HomeTab.transfer, appStart: false)));
    await left;
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
    final status = live == null && _last != null && _last!.status == SessionStatus.sending
        ? SessionStatus
              .finished // automatic receive: the session is closed right after the last file, so show it as done
        : session?.status;
    final phase = switch (status) {
      SessionStatus.waiting => _Phase.request,
      SessionStatus.sending => _Phase.progress,
      SessionStatus.finished || SessionStatus.finishedWithErrors => _Phase.done,
      _ => _Phase.stopped,
    };
    if (session != null && (phase == _Phase.done || phase == _Phase.stopped)) _armAutoClose();
    if (phase == _Phase.progress) _wasReceiving = true;
    final filling = status == SessionStatus.finished && _wasReceiving && !_filled && !MediaQuery.disableAnimationsOf(context);
    if (filling) {
      _fillTimer ??= Timer(_fillUp, () {
        if (mounted) setState(() => _filled = true);
      });
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_later());
      },
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: SmPopupWindow._maxTextScale,
        child: Scaffold(
          backgroundColor: c.sheet,
          body: CallbackShortcuts(
            bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => unawaited(_later())},
            child: Focus(
              focusNode: _focus,
              child: MouseRegion(
                onEnter: (_) => _hovering = true,
                onExit: (_) => _hovering = false,
                child: DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(border: Border.all(color: c.line)),
                  child: SmGlow(
                    // Light only behind the device that is sending
                    color: c.glow1.withValues(alpha: c.glow1.a * 0.75),
                    center: const Alignment(-0.8, -0.64),
                    radius: 0.72,
                    child: session == null
                        ? const SizedBox.expand()
                        : _Enter(
                            child: _Body(
                              session: session,
                              phase: filling ? _Phase.progress : phase,
                              filling: filling,
                              transfers: transfers,
                              statuses: _lastStatuses,
                              isMine: isMine,
                              verified: verified,
                              speed: _speed,
                              onAccept: _accept,
                              onDecline: _decline,
                              onLater: _later,
                              onCancel: _cancel,
                              onClose: _finish,
                              onAdd: () => _add(session),
                            ),
                          ),
                  ),
                ),
              ),
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

// ───────────────────────── Content ─────────────────────────

enum _Phase { request, progress, done, stopped }

/// The content glides in from the right, the edge the popup comes from.
class _Enter extends StatelessWidget {
  final Widget child;

  const _Enter({required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: SmPopupWindow.shown,
      child: child,
      builder: (context, shown, child) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: shown ? 1 : 0),
        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 380),
        curve: Curves.easeOutCubic,
        child: child,
        builder: (context, v, child) => Opacity(
          opacity: v,
          child: Transform.translate(offset: Offset(28 * (1 - v), 0), child: child),
        ),
      ),
    );
  }
}

/// Three rows that stay where they are in every state: the device and one line of text, the files as a strip of tiles that turn into
/// pictures as they arrive, and at most two buttons.
class _Body extends StatelessWidget {
  final ReceiveSessionState session;
  final _Phase phase;

  /// Everything has arrived; the bar is running up to its end
  final bool filling;
  final FileTransferNotifier transfers;
  final Map<String, FileStatus> statuses;
  final bool isMine;

  /// A verified "My devices" entry (unverified ones also end up here and are asked)
  final bool verified;
  final double speed;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onLater;
  final VoidCallback onCancel;
  final VoidCallback onClose;
  final VoidCallback onAdd;

  const _Body({
    required this.session,
    required this.phase,
    required this.filling,
    required this.transfers,
    required this.statuses,
    required this.isMine,
    required this.verified,
    required this.speed,
    required this.onAccept,
    required this.onDecline,
    required this.onLater,
    required this.onCancel,
    required this.onClose,
    required this.onAdd,
  });

  static const _gap = SizedBox(height: 16);

  static bool _runnable(ReceivingFile f) => isRunnableFile(f.path!);

  /// Files that would run a program are shown in their folder. [openFile] explains that in a dialog, which has no room here.
  static Future<void> _open(BuildContext context, ReceivingFile f) async =>
      _runnable(f) ? await showInFolder(f.path!) : await openFile(context, f.file.fileType, f.path!);

  bool _arrived(ReceivingFile f) => f.path != null || f.savedToGallery || statuses[f.file.id] == FileStatus.finished;

  @override
  Widget build(BuildContext context) {
    final files = session.files.values.where((f) => statuses[f.file.id] != FileStatus.skipped).toList();
    final done = files.where(_arrived).toList();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          SizedBox(height: 44 + SmPopupWindow.textRoom(MediaQuery.textScalerOf(context).scale(1)), child: _device(context, files, done)),
          _gap,
          SizedBox(
            height: 60,
            child: _Strip(
              files: files,
              dimPending: phase == _Phase.progress || phase == _Phase.stopped,
              arrived: _arrived,
              onOpen: phase == _Phase.done ? (f) async => f.path == null ? null : _open(context, f) : null,
            ),
          ),
          _gap,
          SizedBox(
            height: 44,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 340),
              // Out first, then in, with a hint of overlap: never two sets of controls on top of each other, never an empty row
              switchInCurve: const Interval(0.34, 1, curve: Curves.easeOut),
              switchOutCurve: const Interval(0.54, 1, curve: Curves.easeIn),
              child: KeyedSubtree(key: ValueKey(phase), child: _actions(context, done)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _device(BuildContext context, List<ReceivingFile> files, List<ReceivingFile> done) {
    final c = context.sm;
    final bytes = files.fold<int>(0, (a, f) => a + f.file.size);
    final meta = ShareMeText.meta.copyWith(color: c.ink2);
    final (total, current) = _bytes(session, transfers);
    final ratio = filling
        ? 1.0
        : total == 0
        ? 0.0
        : (current / total).clamp(0.0, 1.0);
    final left = speed > 0 && !filling ? Duration(seconds: ((total - current) / speed).round()) : null;

    final Widget line = switch (phase) {
      _Phase.request when !isMine => _Careful(t.shareme.receive.stranger, rest: formatSize(bytes)),
      _Phase.request when !session.sender.https => _Careful(t.shareme.receive.notEncrypted, rest: formatSize(bytes)),
      _Phase.request when !verified => _Careful(t.shareme.home.unverified, rest: formatSize(bytes)),
      _Phase.request => Text('${t.shareme.home.edgeCount(n: files.length)} · ${formatSize(bytes)}', style: meta),
      _Phase.progress => Text(
        // Speed needs two samples; until then there is nothing to say about the time left
        speed > 0 ? formatPace(left: left, speed: speed) : formatSize(bytes),
        style: meta,
      ),
      _Phase.done => Text(
        '${t.shareme.receive.receivedShort(n: done.length)} · ${formatSize(done.fold<int>(0, (a, f) => a + f.file.size))}',
        style: meta,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      _Phase.stopped => Text(t.shareme.receive.canceledBySender, style: meta.copyWith(color: c.warn)),
    };

    return Row(
      children: [
        CheckedAvatar(
          size: 44,
          // The check mark means "verified", nothing else; that everything arrived is said in words
          checked: verified,
          child: DeviceAvatar(deviceType: session.sender.deviceType, size: 44, mine: isMine),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                session.senderAlias,
                style: ShareMeText.deviceNameSm.copyWith(color: c.ink, fontSize: 16),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 1),
              SmSwap(
                alignment: Alignment.topLeft,
                child: KeyedSubtree(key: ValueKey(phase), child: line),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          // Out first, then in, like the rows below
          switchInCurve: const Interval(0.36, 1, curve: Curves.easeOut),
          switchOutCurve: const Interval(0.54, 1, curve: Curves.easeIn),
          layoutBuilder: (current, previous) => Stack(alignment: Alignment.centerRight, clipBehavior: Clip.none, children: [...previous, ?current]),
          child: KeyedSubtree(
            key: ValueKey(phase),
            child: switch (phase) {
              _Phase.progress => BigPercent(ratio, size: 27, glide: Duration(milliseconds: filling ? 320 : 600)),
              _Phase.request => _CloseButton(tooltip: t.shareme.receive.later, onTap: onLater),
              _Phase.done || _Phase.stopped => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (phase == _Phase.done && !isMine && session.sender.ip != null && !isUnverifiedFingerprint(session.sender.fingerprint))
                    _Add(onTap: onAdd)
                  else if (phase == _Phase.done)
                    OriginalChip(
                      verified: context.ref.read(settingsProvider).verifyChecksums && done.isNotEmpty && done.every((f) => f.file.hash != null),
                    ),
                  const SizedBox(width: 4),
                  _CloseButton(tooltip: t.shareme.receive.close, onTap: onClose),
                ],
              ),
            },
          ),
        ),
      ],
    );
  }

  Widget _actions(BuildContext context, List<ReceivingFile> done) {
    Widget secondary(String label, VoidCallback onTap) => ElevatedButton(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
      child: FittedBox(fit: BoxFit.scaleDown, child: Text(label, maxLines: 1)),
    );
    Widget pair(Widget a, Widget b, {bool equal = false}) => Row(
      children: [
        Expanded(child: a),
        const SizedBox(width: 10),
        Expanded(flex: equal ? 1 : 2, child: b),
      ],
    );
    Widget primary(String label, VoidCallback? onTap) => FilledButton(
      onPressed: onTap,
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
      child: FittedBox(fit: BoxFit.scaleDown, child: Text(label, maxLines: 1)),
    );

    switch (phase) {
      case _Phase.request:
        final decline = secondary(t.shareme.receive.decline, onDecline);
        // An unknown device: neither answer is the obvious one
        return isMine
            ? pair(decline, primary(t.shareme.receive.accept, onAccept))
            : pair(decline, secondary(t.shareme.receive.accept, onAccept), equal: true);
      case _Phase.progress:
        final (total, current) = _bytes(session, transfers);
        return Row(
          children: [
            Expanded(
              child: SmProgressBar(
                value: filling
                    ? 1
                    : total == 0
                    ? 0
                    : current / total,
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: filling ? () {} : onCancel,
              child: Text(t.shareme.send.cancel, style: ShareMeText.label.copyWith(color: context.sm.ink2)),
            ),
          ],
        );
      case _Phase.done:
        final first = done.where((f) => f.path != null).firstOrNull;
        final folder = first != null ? File(first.path!).parent.path : session.destinationDirectory;
        final open = Tooltip(
          message: folder,
          child: secondary(t.shareme.home.pickFolder, () async => openFolder(folderPath: folder)),
        );
        return pair(
          open,
          primary(
            first != null && _runnable(first) ? t.shareme.safety.showInFolder : t.shareme.receive.open,
            first == null ? null : () async => _open(context, first),
          ),
        );
      case _Phase.stopped:
        return SizedBox(width: double.infinity, child: secondary(t.shareme.receive.close, onClose));
    }
  }
}

/// The files as tiles: types at first, pictures as soon as they are here. At most five; more are counted on the last tile.
class _Strip extends StatelessWidget {
  final List<ReceivingFile> files;

  /// Files that haven't arrived yet are faint
  final bool dimPending;
  final bool Function(ReceivingFile) arrived;
  final void Function(ReceivingFile)? onOpen;

  const _Strip({required this.files, required this.dimPending, required this.arrived, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    if (files.isEmpty) return const SizedBox.shrink();
    final shown = files.length <= 5 ? files : files.take(4).toList();
    final more = files.length - shown.length;

    Widget tile(ReceivingFile f) {
      final here = arrived(f);
      final thumb = AnimatedOpacity(
        duration: const Duration(milliseconds: 300),
        opacity: dimPending && !here ? 0.42 : 1,
        child: FileThumb(
          frame: FilmFrame(
            fileName: f.desiredName ?? f.file.fileName,
            fileType: f.file.fileType,
            path: here ? f.path : null,
            inGallery: f.savedToGallery,
          ),
          size: 60,
          radius: 15,
        ),
      );
      if (onOpen == null || f.path == null) return thumb;
      final name = f.desiredName ?? f.file.fileName;
      return Semantics(
        container: true,
        button: true,
        label: name,
        onTap: () => onOpen!(f),
        child: ExcludeSemantics(
          child: Tooltip(
            message: name,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => onOpen!(f),
                child: SmPressable(scale: 0.93, child: thumb),
              ),
            ),
          ),
        ),
      );
    }

    if (files.length == 1) {
      final f = files.first;
      return Row(
        children: [
          tile(f),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              f.desiredName ?? f.file.fileName,
              style: ShareMeText.body.copyWith(color: c.ink, height: 1.35),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        for (final (i, f) in shown.indexed) ...[
          if (i > 0) const SizedBox(width: 12),
          tile(f),
        ],
        if (more > 0) ...[
          const SizedBox(width: 12),
          Container(
            width: 60,
            height: 60,
            decoration: smTileDecoration(c, radius: 15),
            alignment: Alignment.center,
            child: Text(
              '+$more',
              style: ShareMeText.data.copyWith(color: c.ink, fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ],
    );
  }
}

/// The amber line under the name: what to be careful about, then the size.
class _Careful extends StatelessWidget {
  final String text;
  final String rest;

  const _Careful(this.text, {required this.rest});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return Row(
      children: [
        Icon(LucideIcons.triangleAlert, size: 14, color: c.warn),
        const SizedBox(width: 5),
        Text(
          text,
          style: ShareMeText.meta.copyWith(color: c.warn, fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            rest,
            style: ShareMeText.meta.copyWith(color: c.ink2),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _CloseButton extends StatelessWidget {
  final String tooltip;
  final VoidCallback onTap;

  const _CloseButton({required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      padding: EdgeInsets.zero,
      icon: Icon(LucideIcons.x, size: 17, color: context.sm.ink3),
    );
  }
}

class _Add extends StatelessWidget {
  final VoidCallback onTap;

  const _Add({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return Tooltip(
      message: t.shareme.home.addToMine,
      child: Material(
        color: c.tonal,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(9, 5, 12, 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.plus, size: 15, color: c.ink),
                const SizedBox(width: 3),
                Text(t.shareme.home.add, style: ShareMeText.label.copyWith(color: c.ink, fontSize: 13)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
