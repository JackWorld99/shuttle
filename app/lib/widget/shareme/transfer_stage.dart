import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/widget/shareme/content_stack.dart';
import 'package:localsend_app/widget/shareme/film_strip.dart';
import 'package:localsend_app/widget/shareme/motion.dart';
import 'package:localsend_app/widget/shareme/transfer_scene.dart';

/// Top bar of the send and receive pages: the other device's name in the middle, at most one action on each side.
class TransferTopBar extends StatelessWidget {
  final String title;
  final Widget? leading;
  final Widget? trailing;

  const TransferTopBar({required this.title, this.leading, this.trailing, super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: NavigationToolbar(
        leading: leading == null ? null : Padding(padding: const EdgeInsets.only(left: 8), child: leading),
        middle: Text(
          title,
          style: ShareMeText.title.copyWith(color: context.sm.ink, fontSize: 17),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: trailing == null ? null : Padding(padding: const EdgeInsets.only(right: 8), child: trailing),
      ),
    );
  }
}

/// The picture of a transfer that fills the send and receive pages: the content on top, the two devices joined by a line, one short
/// block of text and the buttons. It stays in place through every state, so waiting, moving and arriving are one movement.
///
/// Arrival: the content flies into the receiving device, the device catches it (ring, check mark), the number turns into the result
/// and the buttons come in, and only then does the rest settle in the middle.
class TransferStage extends StatefulWidget {
  final ScenePhase phase;
  final double progress;
  final Widget Function(double size) from;
  final Widget Function(double size) to;
  final List<FilmFrame> frames;

  /// The text block; give it a key per state
  final Widget text;

  /// Shown instead of [text] while the content is still flying (the number running up to 100)
  final Widget? arrivingText;

  /// Moves the scene to the top, to make room for a list in [text]
  final bool sceneAtTop;

  /// Once everything has arrived, the devices move to the middle. False when another view takes over instead.
  final bool settles;

  /// Buttons; null while there is nothing to decide
  final Widget? bottom;

  const TransferStage({
    required this.phase,
    required this.progress,
    required this.from,
    required this.to,
    required this.frames,
    required this.text,
    this.arrivingText,
    this.sceneAtTop = false,
    this.settles = true,
    this.bottom,
    super.key,
  });

  /// From "done" until the receiving device has caught the content, and until everything has settled
  static const flight = Duration(milliseconds: 430);
  static const settle = Duration(milliseconds: 820);

  @override
  State<TransferStage> createState() => _TransferStageState();
}

class _TransferStageState extends State<TransferStage> {
  /// The content has landed / the scene may move to the middle
  bool _caught = false;
  bool _settled = false;
  Timer? _catchTimer;
  Timer? _settleTimer;
  bool _first = true;

  static const _curve = Curves.easeInOutCubicEmphasized;

  void _sync() {
    if (widget.phase == ScenePhase.done) {
      if (_first || MediaQuery.disableAnimationsOf(context)) {
        _caught = true;
        _settled = true;
      } else if (_catchTimer == null && !_caught) {
        _catchTimer = Timer(TransferStage.flight, () {
          if (mounted) setState(() => _caught = true);
        });
        if (widget.settles) {
          _settleTimer = Timer(TransferStage.settle, () {
            if (mounted) setState(() => _settled = true);
          });
        }
      }
    } else {
      _catchTimer?.cancel();
      _settleTimer?.cancel();
      _catchTimer = null;
      _settleTimer = null;
      _caught = widget.phase == ScenePhase.broken;
      _settled = widget.phase == ScenePhase.broken;
    }
    _first = false;
  }

  @override
  void dispose() {
    _catchTimer?.cancel();
    _settleTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _sync();
    final phase = widget.phase;
    final still = MediaQuery.disableAnimationsOf(context);
    final move = still ? Duration.zero : const Duration(milliseconds: 560);
    final flying = phase == ScenePhase.done;
    final showContent = phase == ScenePhase.waiting || phase == ScenePhase.moving;
    final flight = still ? Duration.zero : TransferStage.flight;

    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth;
              final h = box.maxHeight;
              final avatar = h < 440 ? 56.0 : 72.0;
              final sceneWidth = math.min(w - 56, 320.0);
              final card = (h * 0.33).clamp(80.0, 190.0);
              final fan = ContentStack.boxFor(card);
              const aboveScene = 34.0;
              const belowScene = 28.0;
              const textHeight = 104.0;
              final top = math.max(4.0, (h - fan.height - aboveScene - avatar - belowScene - textHeight) * 0.46);
              final liveTop = top + fan.height + aboveScene;
              final restTop = widget.sceneAtTop ? 16.0 : math.max(16.0, (h - avatar - belowScene - textHeight) * 0.4);
              final sceneTop = _settled ? restTop : liveTop;
              final sceneLeft = (w - sceneWidth) / 2;
              // Where the content lands: the middle of the receiving device (before anything moves)
              final target = Offset(sceneLeft + sceneWidth - avatar / 2, liveTop + avatar / 2);
              final text = flying && !_caught ? (widget.arrivingText ?? widget.text) : widget.text;

              return Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedPositioned(
                    duration: move,
                    curve: _curve,
                    left: sceneLeft,
                    top: sceneTop,
                    width: sceneWidth,
                    height: avatar,
                    child: TransferScene(
                      from: widget.from(avatar),
                      to: widget.to(avatar),
                      avatarSize: avatar,
                      phase: phase,
                      progress: widget.progress,
                      arriveAfter: flight - const Duration(milliseconds: 60),
                    ),
                  ),
                  AnimatedPositioned(
                    duration: flight,
                    // Slow to leave, fast to arrive: drawn in by the device
                    curve: Curves.easeInCubic,
                    left: flying ? target.dx - fan.width / 2 : (w - fan.width) / 2,
                    top: flying ? target.dy - fan.height / 2 : top,
                    width: fan.width,
                    height: fan.height,
                    child: IgnorePointer(
                      child: AnimatedScale(
                        duration: flight,
                        curve: flying ? Curves.easeInCubic : Curves.easeOutCubic,
                        scale: showContent ? 1 : (flying ? 0.14 : 0.92),
                        child: AnimatedOpacity(
                          duration: flight,
                          curve: flying ? const Interval(0.82, 1) : Curves.easeOut,
                          opacity: showContent ? 1 : 0,
                          child: widget.frames.isEmpty ? null : ContentStack(frames: widget.frames, size: card),
                        ),
                      ),
                    ),
                  ),
                  AnimatedPositioned(
                    duration: move,
                    curve: _curve,
                    left: 0,
                    right: 0,
                    top: sceneTop + avatar + belowScene,
                    bottom: 0,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                      child: SmSwap(child: text),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        // Room for the buttons from the start, so nothing jumps when they appear
        SizedBox(
          height: _hasButtons(phase) || widget.bottom != null ? null : 80,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 360),
            switchInCurve: const Interval(0.25, 1, curve: Curves.easeOutCubic),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(animation),
                child: child,
              ),
            ),
            child: _caught && widget.bottom != null ? widget.bottom : const SizedBox(width: double.infinity, height: 80),
          ),
        ),
      ],
    );
  }

  bool _hasButtons(ScenePhase phase) => phase == ScenePhase.done || phase == ScenePhase.broken;
}

/// Title and a few lines below it, centered (waiting, delivered, not sent).
class StageText extends StatelessWidget {
  final String title;
  final Color? titleColor;
  final double titleSize;
  final List<Widget> children;

  const StageText({required this.title, this.titleColor, this.titleSize = 22, this.children = const [], super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          title,
          style: ShareMeText.display.copyWith(color: titleColor ?? context.sm.ink, fontSize: titleSize, height: 1.3),
          textAlign: TextAlign.center,
        ),
        if (children.isNotEmpty) const SizedBox(height: 10),
        ...children,
      ],
    );
  }
}

/// The big number: counts up smoothly between updates.
class BigPercent extends StatelessWidget {
  final double ratio;
  final double size;
  final Duration glide;

  const BigPercent(this.ratio, {this.size = 60, this.glide = const Duration(milliseconds: 600), super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: ratio.clamp(0.0, 1.0)),
      duration: glide,
      builder: (context, v, _) => Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '${(v * 100).floor()}'),
            TextSpan(
              text: '%',
              style: TextStyle(fontSize: size * 0.4, color: c.ink2, fontWeight: FontWeight.w500, letterSpacing: 0),
            ),
          ],
        ),
        style: ShareMeText.dataLg.copyWith(color: c.ink, fontSize: size, height: 1.15, fontWeight: FontWeight.w700, letterSpacing: -size * 0.02),
      ),
    );
  }
}

/// A primary button whose lower edge runs out while the page waits to close by itself, instead of a sentence saying so.
class CountdownButton extends StatelessWidget {
  final String label;
  final Duration? countdown;
  final VoidCallback onPressed;

  const CountdownButton({required this.label, required this.countdown, required this.onPressed, super.key});

  @override
  Widget build(BuildContext context) {
    final countdown = this.countdown;
    return Stack(
      children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton(onPressed: onPressed, child: Text(label)),
        ),
        if (countdown != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 9,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  width: 36,
                  height: 2.5,
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(color: const Color(0x47FFFFFF), borderRadius: BorderRadius.circular(2)),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 1, end: 0),
                    duration: countdown,
                    builder: (context, v, child) => FractionallySizedBox(widthFactor: v, heightFactor: 1, child: child),
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: const Color(0xF2FFFFFF), borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
