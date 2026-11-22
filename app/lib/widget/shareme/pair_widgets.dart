import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/shareme_pairing/pair_crypto.dart';
import 'package:localsend_app/util/shareme_pairing/pair_protocol.dart';
import 'package:localsend_app/widget/shareme/device_avatar.dart';
import 'package:localsend_app/widget/shareme/seal.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// PC-to-PC pairing: this computer's half of the code, to type on the other computer, and a field for the half shown there.
/// Typing it can't be done without looking at the other screen, unlike a "Same" button. After [pairCodeTries] wrong codes the
/// pairing is cancelled ([onSubmit] returns [PairCodeResult.exhausted] and the page shows the failure).
class TypedCodePanel extends StatefulWidget {
  final String myCode;
  final String peerName;
  final Future<PairCodeResult> Function(String typed) onSubmit;
  final VoidCallback onCancel;

  const TypedCodePanel({required this.myCode, required this.peerName, required this.onSubmit, required this.onCancel, super.key});

  @override
  State<TypedCodePanel> createState() => _TypedCodePanelState();
}

class _TypedCodePanelState extends State<TypedCodePanel> {
  final _input = TextEditingController();
  int _wrong = 0;
  bool _checking = false;
  bool _matched = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final digits = _input.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 6 || _checking || _matched) return;
    setState(() => _checking = true);
    final result = await widget.onSubmit(digits);
    if (!mounted) return;
    setState(() {
      _checking = false;
      switch (result) {
        case PairCodeResult.match:
          _matched = true;
        case PairCodeResult.wrong:
          _wrong++;
          _input.clear();
        case PairCodeResult.exhausted:
          break; // the page switches to the failure view
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final s = t.shareme.pair;
    final codeStyle = ShareMeText.data.copyWith(color: c.ink, fontSize: 34, letterSpacing: 6, fontWeight: FontWeight.w600);
    return Column(
      children: [
        Text(
          s.typedShow(name: widget.peerName),
          style: ShareMeText.body.copyWith(color: c.ink2),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(widget.myCode, style: codeStyle),
        const SizedBox(height: 28),
        Text(
          s.typedEnter(name: widget.peerName),
          style: ShareMeText.body.copyWith(color: c.ink2),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: 240,
          child: TextField(
            controller: _input,
            autofocus: true,
            enabled: !_matched,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            style: codeStyle.copyWith(fontSize: 28),
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
            decoration: const InputDecoration(hintText: '000000'),
            onChanged: (v) {
              if (v.length == 6) unawaited(_submit());
            },
            onSubmitted: (_) => unawaited(_submit()),
          ),
        ),
        if (_wrong > 0 && !_matched) ...[
          const SizedBox(height: 10),
          Text(
            s.typedWrong(name: widget.peerName, n: pairCodeTries - _wrong),
            style: ShareMeText.body.copyWith(color: c.warn),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 20),
        if (_matched)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  s.typedChecked(name: widget.peerName),
                  style: ShareMeText.body.copyWith(color: c.ink2),
                ),
              ),
            ],
          )
        else
          TextButton(onPressed: widget.onCancel, child: Text(t.shareme.settings.cancel)),
        const SizedBox(height: 12),
        Text(
          s.typedHint,
          style: ShareMeText.meta.copyWith(color: c.ink2),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// Middle of the check screen: the enlarged pairing seal + the 12-digit code (only shown when the peer runs an older Shuttle that
/// still asks its user to compare them)
class PairCheckPanel extends StatelessWidget {
  final PairSas sas;

  const PairCheckPanel({required this.sas, super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return Column(
      children: [
        DeviceSeal(fingerprint: sas.sealKey, size: 132, paper: c.bg),
        const SizedBox(height: 18),
        SelectableText(
          sas.digits,
          textAlign: TextAlign.center,
          style: ShareMeText.data.copyWith(color: c.ink, fontSize: 28, letterSpacing: 2, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

/// Paired screen: the two devices' avatars joined by an ink line, with their names below
class PairedDuo extends StatelessWidget {
  final String myFingerprint;
  final String myName;
  final String theirFingerprint;
  final String theirName;

  const PairedDuo({required this.myFingerprint, required this.myName, required this.theirFingerprint, required this.theirName, super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    // Most pairs are one phone + one computer: if the peer's type is unknown, draw the opposite of this device's type
    final myType = checkPlatformIsDesktop() ? DeviceType.desktop : DeviceType.mobile;
    final theirGuess = myType == DeviceType.desktop ? DeviceType.mobile : DeviceType.desktop;
    Widget side(String fp, String name) => SizedBox(
      width: 120,
      child: Column(
        children: [
          DeviceAvatar(
            deviceType: fp == myFingerprint ? myType : (knownDeviceType(fp) ?? theirGuess),
            size: 72,
            mine: true,
            verified: fp != myFingerprint,
            badgeRing: c.bg,
          ),
          const SizedBox(height: 10),
          Text(
            name,
            style: ShareMeText.deviceNameSm.copyWith(color: c.ink),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        side(myFingerprint, myName),
        Padding(
          padding: const EdgeInsets.only(top: 35),
          child: Container(width: 48, height: 2, color: c.ink),
        ),
        side(theirFingerprint, theirName),
      ],
    );
  }
}

String pairFailureText(PairFailure f) {
  final s = t.shareme.pair;
  return switch (f) {
    PairFailure.expired => s.failExpired,
    PairFailure.rejectedHere => s.failRejectedHere,
    PairFailure.rejectedByPeer => s.failRejectedPeer,
    PairFailure.declined => s.failDeclined,
    PairFailure.used => s.failUsed,
    PairFailure.unreachable => s.failUnreachable,
    PairFailure.identity => s.failIdentity,
    PairFailure.timeout => s.failTimeout,
    PairFailure.protocol => s.failProtocol,
    PairFailure.outdated => s.failOutdated,
    PairFailure.codeMismatch => s.failCodeMismatch(n: pairCodeTries),
  };
}

/// Failure explanation; security-related cases (identity check failed, QR code already used by someone else) use the warn color
class PairFailureView extends StatelessWidget {
  final PairFailure failure;

  /// Overrides the default text (computer-to-computer pairing doesn't mention a QR code)
  final String? message;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final VoidCallback onClose;

  const PairFailureView({
    required this.failure,
    this.message,
    required this.primaryLabel,
    required this.onPrimary,
    required this.onClose,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final security =
        failure == PairFailure.identity ||
        failure == PairFailure.used ||
        failure == PairFailure.rejectedByPeer ||
        failure == PairFailure.codeMismatch;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(security ? LucideIcons.shieldAlert : LucideIcons.unlink, size: 40, color: security ? c.warn : c.ink3),
        const SizedBox(height: 14),
        Text(
          message ?? pairFailureText(failure),
          style: ShareMeText.body.copyWith(color: security ? c.warn : c.ink),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: ElevatedButton(
                onPressed: onClose,
                style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(ShareMeSize.buttonH)),
                child: Text(t.shareme.settings.cancel),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: FilledButton(onPressed: onPrimary, child: Text(primaryLabel)),
            ),
          ],
        ),
      ],
    );
  }
}

/// The small "verified" tag in a device row
class VerifiedTag extends StatelessWidget {
  const VerifiedTag({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(LucideIcons.badgeCheck, size: 14, color: c.ok),
        const SizedBox(width: 4),
        Text(t.shareme.pair.verified, style: ShareMeText.meta.copyWith(color: c.ok)),
      ],
    );
  }
}
