import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:localsend_app/config/shareme_theme.dart';

/// Gives a card or button some body: it sinks a little under the finger and springs back. Only adds the movement; taps are handled
/// by the child (usually an InkWell).
class SmPressable extends StatefulWidget {
  final Widget child;
  final double scale;

  const SmPressable({required this.child, this.scale = 0.97, super.key});

  @override
  State<SmPressable> createState() => _SmPressableState();
}

class _SmPressableState extends State<SmPressable> {
  bool _down = false;
  Offset _at = Offset.zero;

  void _set(bool down) {
    // The finger may lift after the widget is gone (a sheet closed by an incoming transfer)
    if (mounted && _down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (e) {
        _at = e.position;
        _set(true);
      },
      // Scrolling is not pressing
      onPointerMove: (e) => (e.position - _at).distance > 10 ? _set(false) : null,
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: _down ? const Duration(milliseconds: 90) : const Duration(milliseconds: 260),
        curve: _down ? Curves.easeOut : Curves.easeOutBack,
        child: widget.child,
      ),
    );
  }
}

/// The tabs of the home screen: the old one fades out and the new one fades in and rises a little, overlapping, so there is never
/// an empty page in between.
///
/// Every tab stays alive once it was built (with its scroll position), and the others are built ahead while nothing moves: building one
/// takes 40 to 65 ms on a phone, which showed as a hitch at every switch. Hidden tabs are neither painted nor animated.
class SmTabSwitcher extends StatefulWidget {
  final int index;
  final List<Widget> children;

  const SmTabSwitcher({required this.index, required this.children, super.key});

  @override
  State<SmTabSwitcher> createState() => _SmTabSwitcherState();
}

class _SmTabSwitcherState extends State<SmTabSwitcher> with SingleTickerProviderStateMixin {
  static const _enterCurve = Interval(0.12, 1, curve: ShareMeMotion.enter);

  /// The old tab is gone after the first third
  static const _leaveCurve = Interval(0, 1 / 3);

  late final _move = AnimationController(vsync: this, duration: const Duration(milliseconds: 300), value: 1)
    ..addStatusListener((status) {
      if (status.isCompleted && _leaving != null) setState(() => _leaving = null);
    });
  late final _shown = [for (var i = 0; i < widget.children.length; i++) ValueNotifier(i == widget.index)];
  late final _built = {widget.index};
  int? _leaving;
  Timer? _ahead;

  @override
  void initState() {
    super.initState();
    _buildAhead();
  }

  void _buildAhead() {
    if (_built.length == widget.children.length) return;
    _ahead = Timer(const Duration(milliseconds: 1200), () {
      unawaited(
        SchedulerBinding.instance.scheduleTask(() {
          if (!mounted) return;
          final next = [for (var i = 0; i < widget.children.length; i++) i].where((i) => !_built.contains(i)).firstOrNull;
          if (next == null) return;
          setState(() => _built.add(next));
          _buildAhead();
        }, Priority.idle),
      );
    });
  }

  @override
  void didUpdateWidget(SmTabSwitcher old) {
    super.didUpdateWidget(old);
    if (old.index == widget.index) return;
    _built.add(widget.index);
    if (MediaQuery.disableAnimationsOf(context)) {
      _leaving = null;
      _move.value = 1;
    } else {
      _leaving = old.index;
      unawaited(_move.forward(from: 0));
    }
    // Tabs may rebuild when told, which isn't possible in the middle of a build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final (i, shown) in _shown.indexed) {
        shown.value = i == widget.index;
      }
    });
  }

  @override
  void dispose() {
    _ahead?.cancel();
    _move.dispose();
    for (final shown in _shown) {
      shown.dispose();
    }
    super.dispose();
  }

  Widget _tab(int i) {
    final current = i == widget.index;
    final leaving = i == _leaving;
    return Offstage(
      offstage: !current && !leaving,
      child: TickerMode(
        enabled: current,
        child: ExcludeFocus(
          excluding: !current,
          child: IgnorePointer(
            ignoring: !current,
            child: AnimatedBuilder(
              animation: _move,
              child: RepaintBoundary(
                // A controller of its own: on phones, lists share the page's one, and here several are alive
                child: PrimaryScrollController.none(
                  child: SmTabShown(shown: _shown[i], child: widget.children[i]),
                ),
              ),
              builder: (context, child) {
                final v = current ? _enterCurve.transform(_move.value) : 1 - _leaveCurve.transform(_move.value);
                return Opacity(
                  opacity: v,
                  // Only the new tab moves
                  child: Transform.translate(offset: Offset(0, current ? 12 * (1 - v) : 0), child: child),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          if (_built.contains(i)) KeyedSubtree(key: ValueKey(i), child: _tab(i)),
      ],
    );
  }
}

/// Tells the widgets of a tab whether it is the one being shown.
class SmTabShown extends InheritedWidget {
  final ValueListenable<bool> shown;

  const SmTabShown({required this.shown, required super.child, super.key});

  /// Doesn't depend on it: a change is no reason to rebuild the tab
  static ValueListenable<bool>? of(BuildContext context) => context.getInheritedWidgetOfExactType<SmTabShown>()?.shown;

  @override
  bool updateShouldNotify(SmTabShown old) => false;
}

/// For what a tab does each time it comes to the front (it stays alive while another one is shown).
mixin SmTabState<T extends StatefulWidget> on State<T> {
  ValueListenable<bool>? _shown;

  /// Also called once at the start if the tab is the one shown then (or not in a [SmTabSwitcher] at all)
  void onTabShown();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final first = _shown == null;
    final shown = SmTabShown.of(context);
    if (identical(shown, _shown) && !first) return;
    _shown?.removeListener(_changed);
    _shown = shown?..addListener(_changed);
    if (first && (shown?.value ?? true) && !_startedOnce) {
      _startedOnce = true;
      onTabShown();
    }
  }

  bool _startedOnce = false;

  void _changed() {
    if (mounted && (_shown?.value ?? false)) {
      _startedOnce = true;
      onTabShown();
    }
  }

  @override
  void dispose() {
    _shown?.removeListener(_changed);
    super.dispose();
  }
}

/// A text that changes with time ("4 min ago"), kept up to date.
class SmTicking extends StatefulWidget {
  final String Function() text;
  final TextStyle style;

  const SmTicking(this.text, {required this.style, super.key});

  @override
  State<SmTicking> createState() => _SmTickingState();
}

class _SmTickingState extends State<SmTicking> {
  late final _timer = Timer.periodic(const Duration(seconds: 20), (_) => setState(() {}));

  @override
  void initState() {
    super.initState();
    _timer;
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(widget.text(), style: widget.style);
}

/// Content that appears or goes away (a new "Just received" card, a nearby device): the room opens and closes smoothly and the
/// content fades, instead of everything below jumping.
class SmReveal extends StatelessWidget {
  final Widget? child;
  final AlignmentGeometry alignment;

  const SmReveal({required this.child, this.alignment = Alignment.topCenter, super.key});

  @override
  Widget build(BuildContext context) {
    const duration = Duration(milliseconds: 320);
    return AnimatedSize(
      duration: duration,
      curve: Curves.easeInOutCubicEmphasized,
      alignment: alignment,
      clipBehavior: Clip.none,
      child: AnimatedSwitcher(
        duration: duration,
        switchInCurve: const Interval(0.25, 1, curve: Curves.easeOut),
        switchOutCurve: const Interval(0.6, 1, curve: Curves.easeIn),
        layoutBuilder: (current, previous) => Stack(
          alignment: alignment,
          children: [
            for (final p in previous) Positioned(left: 0, right: 0, top: 0, child: p),
            ?current,
          ],
        ),
        child: child ?? const SizedBox(width: double.infinity),
      ),
    );
  }
}

/// Text (or any small block) that changes with the state: the old one fades up and out, the new one rises in.
class SmSwap extends StatelessWidget {
  /// Must have a key that differs per state
  final Widget child;
  final Duration duration;
  final AlignmentGeometry alignment;

  const SmSwap({required this.child, this.duration = const Duration(milliseconds: 340), this.alignment = Alignment.topCenter, super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: const Interval(0.35, 1, curve: Curves.easeOutCubic),
      switchOutCurve: const Interval(0.62, 1, curve: Curves.easeIn),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.06), end: Offset.zero).animate(animation),
          child: child,
        ),
      ),
      layoutBuilder: (current, previous) => Stack(
        alignment: alignment,
        children: [...previous, ?current],
      ),
      child: child,
    );
  }
}
