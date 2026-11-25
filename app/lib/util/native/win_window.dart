import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/widgets.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:logging/logging.dart';
import 'package:win32/win32.dart';
import 'package:window_manager/window_manager.dart';

final _logger = Logger('WinWindow');

/// In physical pixels
typedef WinRect = ({int left, int top, int right, int bottom});

/// Where a window is, and whether it is normal, minimized or maximized, the way Windows remembers it
class WinPlacement {
  final int _state;
  final int _flags;
  final Uint8List _bytes;

  WinPlacement._(this._state, this._flags, this._bytes);

  bool get minimized => _state == SW_SHOWMINIMIZED;

  /// Also if it is minimized, but was maximized before
  bool get maximized => _state == SW_SHOWMAXIMIZED || (minimized && _flags & WPF_RESTORETOMAXIMIZED != 0);
}

/// Shuttle: the app's window on Windows, for what window_manager doesn't offer. Its `show(inactive: true)` takes the focus all the same
/// on Windows, its restore() and maximize() are only requests, and a window that comes into view is black until Flutter has drawn it.
///
/// Not to be called while building: a change of size draws a frame right away.
class WinWindow {
  final int _handle;

  WinWindow._(this._handle);

  static WinWindow? _main;

  /// Null where there is no such window (other platforms, tests)
  static Future<WinWindow?> main() async {
    if (!checkPlatform([TargetPlatform.windows])) return null;
    try {
      return _main ??= WinWindow._(await windowManager.getId());
    } catch (e) {
      _logger.warning('No window handle', e);
      return null;
    }
  }

  // ───── Out of sight until drawn ─────

  static int _cloaks = 0;

  /// Runs [change] while the window is out of sight, and shows the window once it has been drawn. Windows draws a cloaked window like any
  /// other, only not on the screen (Chromium and Firefox open their windows this way). It is out of sight as soon as this is called.
  Future<void> behindCloak(Future<void> Function() change) async {
    if (_cloaks++ == 0) _cloak(true);
    final limit = Timer(const Duration(seconds: 4), () => _cloak(false)); // it comes back, whatever happens
    try {
      await change();
      await drawn();
    } finally {
      limit.cancel();
      if (--_cloaks == 0) _cloak(false);
    }
  }

  void _cloak(bool on) => using((arena) {
    final value = arena<Int32>()..value = on ? 1 : 0;
    final result = DwmSetWindowAttribute(_handle, DWMWA_CLOAK, value, sizeOf<Int32>());
    if (result != 0) _logger.warning('Cloak $on: $result');
  });

  /// Until the window has a picture of what it shows now. Two frames at most are under way at once, so when a third one has been built,
  /// the first one is on the window. The time limits are for the case that no frames come; the window must not stay out of sight.
  static Future<void> drawn() async {
    final binding = WidgetsBinding.instance;
    Future<void> frames() async {
      for (var i = 0; i < 3; i++) {
        await binding.endOfFrame.timeout(const Duration(milliseconds: 200), onTimeout: () {});
      }
    }

    if (binding.firstFrameRasterized) return frames();
    // The app is starting: the first page, and the pictures on it (the logo, what was received last)
    await binding.waitUntilFirstFrameRasterized.timeout(const Duration(seconds: 2), onTimeout: () {});
    await frames();
    for (var i = 0; i < 20 && PaintingBinding.instance.imageCache.pendingImageCount > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await frames();
  }

  // ───── Not taking the keyboard ─────

  static int _quiet = 0;

  /// Runs [change] without making this the active window, so someone who is typing (or watching a film) elsewhere isn't interrupted.
  /// Flutter asks for the keyboard with every new page, and window_manager activates the window when it changes the frame. Windows lets
  /// them have it after a click in this window or when nobody has touched the keyboard for a while, even if the window is hidden, which
  /// leaves the user typing into nothing.
  Future<void> quietly(Future<void> Function() change) async {
    _quiet++;
    _setActivatable(false, taskbarButton: visible);
    try {
      await change();
    } finally {
      if (--_quiet == 0) _setActivatable(visible);
    }
  }

  /// In the tray: from here on nothing but [leavesTray] (and [quietly] with a window that has come into view) makes it activatable again
  void goesToTray() => _setActivatable(false);

  void leavesTray() => _setActivatable(true);

  /// Windows leaves a window that can't be activated out of the taskbar, unless it has [taskbarButton]
  void _setActivatable(bool on, {bool taskbarButton = false}) {
    final style = GetWindowLongPtr(_handle, GWL_EXSTYLE) & ~(WS_EX_NOACTIVATE | WS_EX_APPWINDOW);
    SetWindowLongPtr(_handle, GWL_EXSTYLE, on ? style : style | WS_EX_NOACTIVATE | (taskbarButton ? WS_EX_APPWINDOW : 0));
  }

  // ───── State ─────

  /// Minimized counts as visible
  bool get visible => IsWindowVisible(_handle) != 0;

  bool get focused => GetForegroundWindow() == _handle;

  WinPlacement get placement => using((arena) {
    final size = sizeOf<WINDOWPLACEMENT>();
    final native = arena<WINDOWPLACEMENT>()..ref.length = size;
    GetWindowPlacement(_handle, native);
    return WinPlacement._(native.ref.showCmd, native.ref.flags, Uint8List.fromList(native.cast<Uint8>().asTypedList(size)));
  });

  WinRect get bounds => using((arena) {
    final native = arena<RECT>();
    GetWindowRect(_handle, native);
    return (left: native.ref.left, top: native.ref.top, right: native.ref.right, bottom: native.ref.bottom);
  });

  bool get alwaysOnTop => GetWindowLongPtr(_handle, GWL_EXSTYLE) & WS_EX_TOPMOST != 0;

  // ───── Changes, none of which takes the focus ─────

  /// Visible and neither minimized nor maximized
  void showInactive() {
    // More than once: the first call of a process may do what the process was started with instead (hidden, minimized), and a window that
    // was maximized before it was minimized is maximized again first
    for (var i = 0; i < 3; i++) {
      ShowWindow(_handle, SW_SHOWNOACTIVATE);
      if (visible && IsIconic(_handle) == 0 && IsZoomed(_handle) == 0) return;
    }
  }

  void minimizeInactive() => ShowWindow(_handle, SW_SHOWMINNOACTIVE);

  void hide() => ShowWindow(_handle, SW_HIDE);

  void setAlwaysOnTop(bool on) => SetWindowPos(_handle, on ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);

  void moveTo(WinRect to) {
    // Again if it isn't there: the first move may lead to a display with another scale, which resizes the window
    for (var i = 0; i < 2; i++) {
      SetWindowPos(_handle, 0, to.left, to.top, to.right - to.left, to.bottom - to.top, SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
      if (bounds == to) return;
    }
  }

  /// Into the bottom right corner of the main display, above the taskbar. [content] is the size of the content; that and [margin] are in
  /// logical pixels.
  void moveToCorner(Size content, {required double margin}) {
    final area = using((arena) {
      final native = arena<RECT>();
      SystemParametersInfo(SPI_GETWORKAREA, 0, native, 0);
      return (right: native.ref.right, bottom: native.ref.bottom);
    });
    // Until it fits: the first move may lead to a display with another scale, and the new frame only takes effect with a move
    for (var i = 0; i < 3; i++) {
      final scale = GetDpiForWindow(_handle) / 96;
      int px(double logical) => (logical * scale).round();
      final frame = _frame;
      final right = area.right - px(margin) + frame.right;
      final bottom = area.bottom - px(margin) + frame.bottom;
      moveTo((
        left: right - px(content.width) - frame.left - frame.right,
        top: bottom - px(content.height) - frame.top - frame.bottom,
        right: right,
        bottom: bottom,
      ));
      if (GetDpiForWindow(_handle) / 96 == scale && _frame == frame) return;
    }
  }

  /// How far the window reaches beyond its content: the borders Windows keeps at the sides, most of which can't be seen
  WinRect get _frame => using((arena) {
    final content = arena<RECT>();
    final origin = arena<POINT>();
    GetClientRect(_handle, content);
    ClientToScreen(_handle, origin);
    final outer = bounds;
    return (
      left: origin.ref.x - outer.left,
      top: origin.ref.y - outer.top,
      right: outer.right - origin.ref.x - content.ref.right,
      bottom: outer.bottom - origin.ref.y - content.ref.bottom,
    );
  });

  /// The title bar in the theme of the app; by itself it has the theme of the system. [color] only has an effect on Windows 11.
  void setTitleBar({required bool dark, required Color? color}) => using((arena) {
    final value = arena<Uint32>()..value = dark ? 1 : 0;
    DwmSetWindowAttribute(_handle, DWMWA_USE_IMMERSIVE_DARK_MODE, value, sizeOf<Uint32>());
    int channel(double v) => (v * 255).round();
    value.value = color == null
        ? 0xFFFFFFFF // DWMWA_COLOR_DEFAULT
        : channel(color.r) | channel(color.g) << 8 | channel(color.b) << 16; // COLORREF: 0x00BBGGRR
    DwmSetWindowAttribute(_handle, DWMWA_CAPTION_COLOR, value, sizeOf<Uint32>());
  });

  /// For a minimized window: it stays minimized, and will be restored to what [to] says
  void setMinimizedPlacement(WinPlacement to) => using((arena) {
    final native = arena<WINDOWPLACEMENT>();
    native.cast<Uint8>().asTypedList(to._bytes.length).setAll(0, to._bytes);
    native.ref.showCmd = SW_SHOWMINNOACTIVE;
    SetWindowPlacement(_handle, native);
  });
}

/// Runs [show], which brings a hidden window into view, and shows the window once it has been drawn. A window in view is left alone, and
/// so is a minimized one, which Windows unfolds with an animation of its own.
Future<void> showOnceDrawn(Future<void> Function() show) async {
  final window = await WinWindow.main();
  window?.leavesTray();
  if (window == null || window.visible) return show();
  await window.behindCloak(show);
}

/// Opens a page because of another device. If the user is busy with another window, this one isn't pulled in front of it.
void openQuietly(void Function() open) {
  final window = WinWindow._main; // known since the app started; null on other platforms
  if (window == null || window.focused) return open();
  unawaited(
    window.quietly(() async {
      open();
      await WinWindow.drawn();
    }),
  );
}
