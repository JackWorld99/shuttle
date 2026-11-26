import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/receive_page.dart' show ReceivePageVm;
import 'package:localsend_app/pages/web_share_page.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/paired_devices_provider.dart';
import 'package:localsend_app/util/shareme_format.dart';
import 'package:localsend_app/util/shareme_own_page.dart';
import 'package:localsend_app/util/shareme_resume.dart';
import 'package:localsend_app/widget/shareme/ambient.dart';
import 'package:localsend_app/widget/shareme/bottom_actions.dart';
import 'package:localsend_app/widget/shareme/content_stack.dart';
import 'package:localsend_app/widget/shareme/desktop_layout.dart';
import 'package:localsend_app/widget/shareme/device_avatar.dart';
import 'package:localsend_app/widget/shareme/sm_sheets.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Shuttle: the "incoming request" page. Only used for file requests; text and links are handled separately (snackbar or
/// bottom sheet, see ReceiveController).
///
/// Who, what, yes or no, and nothing else. A verified device of mine shows its check mark; anything to be careful about is one short
/// amber line ("Unknown device", "Not verified", "Not encrypted") that explains itself when tapped, and then neither button is
/// highlighted.
///
/// Data and actions fully reuse LocalSend's [ReceivePageVm] (accept / decline / close).
class SmReceivePage extends StatefulWidget {
  final ViewProvider<ReceivePageVm> vm;

  const SmReceivePage(this.vm, {super.key});

  @override
  State<SmReceivePage> createState() => _SmReceivePageState();
}

class _SmReceivePageState extends State<SmReceivePage> {
  /// The page as last built while its request existed: stays on screen during the exit animation (declining ends the session first)
  Widget? _last;

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final vm = context.watch(widget.vm);
    if (vm.status == null && _last != null) {
      // The request is gone (declined, answered elsewhere, replaced by another one): so is this page
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) closeOwnPage(this.context, () => this.context.global.dispatch(NavigateAction.popUntil<WebSharePage>()));
      });
      return IgnorePointer(child: _last);
    }
    final sender = vm.sender;
    final favorites = context.watch(favoritesProvider);
    final isMine = favorites.any((f) => f.fingerprint == sender.fingerprint);
    // Only verified devices in "My devices" are accepted directly; unverified ones are asked on this page too
    final verified = isVerifiedMine(favorites: favorites, paired: context.watch(pairedDevicesProvider), fingerprint: sender.fingerprint);
    final bytes = vm.files.fold<int>(0, (a, f) => a + f.size);

    void decline() {
      vm.onDecline();
      context.global.dispatch(NavigateAction.popUntil<WebSharePage>()); // as in LocalSend: back to WebSharePage if receiving via link, else home
    }

    void close() {
      vm.onClose();
      context.global.dispatch(NavigateAction.popUntil<WebSharePage>()); // as in LocalSend: back to WebSharePage if receiving via link, else home
    }

    final canceled = vm.status == SessionStatus.canceledBySender;
    final warnings = [
      if (!isMine) t.shareme.receive.stranger else if (!verified && sender.https) t.shareme.home.unverified,
      if (!sender.https) t.shareme.receive.notEncrypted,
    ];

    final page = PopScope(
      // Back gesture = decline (same as LocalSend's ReceivePage)
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && !canceled) vm.onDecline();
        if (didPop && canceled) vm.onClose();
      },
      child: SmScaffold(
        body: SafeArea(
          child: SmMaxWidth(
            maxWidth: 480,
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
                      child: Column(
                        children: [
                          _Arriving(
                            waiting: !canceled,
                            child: DeviceAvatar(deviceType: sender.deviceType, size: 104, mine: isMine, verified: verified),
                          ),
                          const SizedBox(height: 26),
                          Text(
                            sender.alias,
                            style: ShareMeText.display.copyWith(color: c.ink, fontSize: 28),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 10),
                          ContentSummary(
                            files: [for (final f in vm.files) (f.fileName, f.fileType)],
                            bytes: bytes,
                            alignment: WrapAlignment.center,
                            fontSize: 16,
                          ),
                          // Shuttle: part of it arrived in an earlier transfer that was interrupted (resume)
                          if (_resumedPercent(context, vm, bytes) case final percent?) ...[
                            const SizedBox(height: 8),
                            Text(
                              t.shareme.resume.receiveBefore(percent: percent),
                              style: ShareMeText.meta.copyWith(color: c.ink2),
                              textAlign: TextAlign.center,
                            ),
                          ],
                          if (warnings.isNotEmpty) ...[
                            const SizedBox(height: 22),
                            for (final w in warnings)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: RequestWarning(text: w, onTap: () async => _explain(context, sender)),
                              ),
                          ],
                          if (canceled) ...[
                            const SizedBox(height: 22),
                            Text(
                              t.shareme.receive.canceledBySender,
                              style: ShareMeText.title.copyWith(color: c.warn),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                if (canceled)
                  Padding(
                    padding: BottomActions.padding,
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(onPressed: close, child: Text(t.shareme.receive.close)),
                    ),
                  )
                else
                  BottomActions(
                    secondaryLabel: t.shareme.receive.decline,
                    onSecondary: decline,
                    primaryLabel: t.shareme.receive.accept,
                    onPrimary: vm.onAccept,
                    // An unknown device: neither answer is the obvious one
                    equal: !isMine,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    _last = page;
    return IgnorePointer(ignoring: false, child: page);
  }

  /// Who this is and what to check, for those who want to know
  Future<void> _explain(BuildContext context, Device sender) async {
    final c = context.sm;
    await showSmSheet<void>(
      context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(sender.alias, style: ShareMeText.title.copyWith(color: c.ink, fontSize: 18)),
              const SizedBox(height: 12),
              if (!sender.https) ...[
                Text(t.shareme.receive.unencrypted, style: ShareMeText.body.copyWith(color: c.ink2)),
                const SizedBox(height: 10),
              ],
              Text(t.shareme.receive.strangerTitle, style: ShareMeText.body.copyWith(color: c.ink2)),
              const SizedBox(height: 4),
              Text(t.shareme.receive.strangerBody, style: ShareMeText.body.copyWith(color: c.ink2)),
              const SizedBox(height: 14),
              Text(
                '${t.shareme.receive.fingerprint}  ${groupFingerprint(sender.fingerprint)}',
                style: ShareMeText.data.copyWith(color: c.ink3, fontSize: 13),
              ),
              // A sheet is dragged away; a dialog on the PC needs a button
              if (useDesktopLayout(context))
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.shareme.receive.close)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The sender's avatar with rings running outwards behind it, as long as the request waits for an answer.
/// Shuttle: how much of this request arrived in an earlier, interrupted transfer, in percent; `null` for nothing.
int? _resumedPercent(BuildContext context, ReceivePageVm vm, int totalBytes) {
  final sessionId = context.read(serverProvider)?.session?.sessionId;
  if (sessionId == null || totalBytes == 0) return null;
  final store = context.read(resumeStoreProvider);
  var saved = 0;
  for (final f in vm.files) {
    saved += store.savedBefore(sessionId: sessionId, fileId: f.id) ?? 0;
  }
  return saved == 0 ? null : (saved * 100 ~/ totalBytes).clamp(1, 99);
}

class _Arriving extends StatefulWidget {
  final bool waiting;
  final Widget child;

  const _Arriving({required this.waiting, required this.child});

  @override
  State<_Arriving> createState() => _ArrivingState();
}

class _ArrivingState extends State<_Arriving> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _run();
  }

  @override
  void didUpdateWidget(_Arriving old) {
    super.didUpdateWidget(old);
    _run();
  }

  void _run() {
    if (!widget.waiting || MediaQuery.disableAnimationsOf(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      unawaited(_c.repeat());
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: widget.waiting ? _RingsPainter(_c, context.sm.accent) : null,
        child: Padding(padding: const EdgeInsets.all(34), child: widget.child),
      ),
    );
  }
}

class _RingsPainter extends CustomPainter {
  final Animation<double> t;
  final Color color;

  _RingsPainter(this.t, this.color) : super(repaint: t);

  @override
  void paint(Canvas canvas, Size size) {
    final inner = Rect.fromLTWH(34, 34, size.width - 68, size.height - 68);
    final corner = inner.width * 0.32;
    for (final shift in const [0.0, 0.5]) {
      final v = (t.value + shift) % 1;
      final grow = 34 * Curves.easeOut.transform(v);
      canvas.drawRRect(
        RRect.fromRectAndRadius(inner.inflate(grow), Radius.circular(corner + grow)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = color.withValues(alpha: 0.32 * (1 - v)),
      );
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) => old.color != color;
}

/// A short amber line ("Unknown device", "Not encrypted"); tap it for the explanation.
class RequestWarning extends StatelessWidget {
  final String text;
  final VoidCallback? onTap;

  const RequestWarning({required this.text, this.onTap, super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return Material(
      color: c.warnContainer,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, 7, onTap == null ? 14 : 9, 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.triangleAlert, size: 16, color: c.warn),
              const SizedBox(width: 7),
              Text(text, style: ShareMeText.label.copyWith(color: c.warn, fontSize: 14)),
              // There is more to read behind it
              if (onTap != null) ...[const SizedBox(width: 2), Icon(LucideIcons.chevronRight, size: 16, color: c.warn)],
            ],
          ),
        ),
      ),
    );
  }
}
