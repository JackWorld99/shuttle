import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/paired_record.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/paired_devices_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/shareme_pairing/pair_crypto.dart';
import 'package:localsend_app/util/shareme_pairing/pair_protocol.dart';
import 'package:localsend_app/widget/shareme/ambient.dart';
import 'package:localsend_app/widget/shareme/confirm_remove_device.dart';
import 'package:localsend_app/widget/shareme/pair_widgets.dart';
import 'package:localsend_app/widget/shareme/sm_card.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Shuttle: "Pair a new device" on the PC. Shows a QR code; a phone that scans it pairs on its own (the code holds this PC's
/// certificate fingerprint and a one-time key). The paired page names the device, warns if another device tried the same code,
/// and offers "Not your device? Remove it".
/// Another PC can also pair directly from "Nearby" (no QR code): each person then types the 6 digits shown on the other computer.
/// That PC's request first shows as "X wants to pair with this computer: Ignore / Accept"; checking only starts after "Accept".
/// Until then the QR code can still be scanned (so someone on the same Wi-Fi can't occupy pairing with a request).
class SmPairHostPage extends StatefulWidget {
  const SmPairHostPage({super.key});

  @override
  State<SmPairHostPage> createState() => _SmPairHostPageState();
}

class _SmPairHostPageState extends State<SmPairHostPage> with Refena {
  PairHost? _host;
  String? _startError;
  bool _noNetwork = false;
  Timer? _tick;
  final _name = TextEditingController();

  @override
  void initState() {
    super.initState();
    ensureRef((ref) => unawaited(_start()));
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _host?.state.value.stage == PairHostStage.showingCode) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(_host?.close());
    _name.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final me = ref.read(deviceFullInfoProvider);
    final settings = ref.read(settingsProvider);
    final security = ref.read(securityProvider);
    final ips = pairAddresses(ref.read(localIpProvider));
    if (ips.isEmpty) {
      setState(() => _noNetwork = true);
      return;
    }
    final host = PairHost(
      self: PairPeerInfo(
        fingerprint: security.certificateHash,
        alias: me.alias == '-' ? settings.alias : me.alias,
        model: me.deviceModel,
        type: me.deviceType.name,
        port: me.port > 0 ? me.port : settings.port,
        https: me.https,
        addresses: ips,
      ),
      certificatePem: security.certificate,
      privateKeyPem: security.privateKey,
      ips: ips,
      // This page accepts both: a phone scanning the code, or another PC clicking "Pair" under "Nearby" (state.nearby)
      onPaired: (peer, ip, secret) => savePairing(
        ref,
        peer,
        ip,
        secret,
        customName: _name.text,
        method: (_host?.state.value.nearby ?? false) ? pairMethodNearby : pairMethodQr,
      ),
    );
    host.state.addListener(_onState);
    try {
      await host.start();
      if (!mounted) {
        await host.close();
        return;
      }
      setState(() => _host = host);
    } catch (e) {
      if (mounted) setState(() => _startError = '$e');
    }
  }

  void _onState() {
    final st = _host?.state.value;
    if (st?.stage == PairHostStage.verifying && _name.text.isEmpty && st?.peer != null) {
      _name.text = st!.peer!.alias;
    }
  }

  /// "Another computer?" was tapped
  bool _otherPc = false;

  void _newCode() {
    _name.clear();
    _host?.renew();
  }

  void _finish(PairPeerInfo peer) {
    renameMyDevice(ref, peer.fingerprint, _name.text, ownName: peer.alias);
    Navigator.of(context).pop();
  }

  /// "Not your device? Remove it": someone else may have used the code (it was visible on this screen)
  Future<void> _removeNotMine(PairPeerInfo peer) async {
    final name = _name.text.trim().isEmpty ? peer.alias : _name.text.trim();
    if (!await confirmRemoveDevice(context, name) || !mounted) return;
    removeMyDevice(ref, peer.fingerprint);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final s = t.shareme.pair;
    final host = _host;
    return SmScaffold(
      appBar: AppBar(title: host?.state.value.stage == PairHostStage.paired ? null : Text(s.hostTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
            child: _noNetwork
                ? Text(
                    s.noNetwork,
                    style: ShareMeText.body.copyWith(color: c.warn),
                    textAlign: TextAlign.center,
                  )
                : _startError != null
                ? Text(
                    s.startFailed(error: _startError!),
                    style: ShareMeText.body.copyWith(color: c.warn),
                    textAlign: TextAlign.center,
                  )
                : host == null
                ? const Center(child: CircularProgressIndicator())
                : ValueListenableBuilder(valueListenable: host.state, builder: (context, st, _) => _body(context, host, st)),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, PairHost host, PairHostState st) {
    final c = context.sm;
    final s = t.shareme.pair;
    switch (st.stage) {
      case PairHostStage.starting:
        return const Center(child: CircularProgressIndicator());
      case PairHostStage.showingCode:
        if (st.nearby) {
          // "Accept" was clicked; wait for that PC to start verification (usually within a second)
          return Padding(
            padding: const EdgeInsets.only(top: 60),
            child: Column(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 18),
                Text(
                  s.nearbyConnecting(name: st.peer?.alias ?? ''),
                  style: ShareMeText.body.copyWith(color: c.ink2),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          );
        }
        final left = st.expiresAt!.difference(DateTime.now());
        final mm = left.inMinutes.clamp(0, 99);
        final ss = (left.inSeconds % 60).clamp(0, 59).toString().padLeft(2, '0');
        return Column(
          children: [
            if (st.request != null) ...[
              _NearbyRequestCard(peer: st.request!, onIgnore: host.ignoreNearby, onAccept: host.acceptNearby),
              const SizedBox(height: 20),
            ],
            Container(
              padding: const EdgeInsets.all(20),
              // Always white, so cameras can read it in dark mode too
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(ShareMeSize.radiusGroup),
                boxShadow: ShareMeColors.light.cardShadow,
              ),
              child: SizedBox(
                width: 260,
                height: 260,
                child: PrettyQrView.data(
                  data: st.qr!,
                  errorCorrectLevel: QrErrorCorrectLevel.M,
                  decoration: const PrettyQrDecoration(shape: PrettyQrSmoothSymbol(roundFactor: 0, color: Color(0xFF1A1D1B))),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              s.scanMe,
              style: ShareMeText.title.copyWith(color: c.ink, fontSize: 19),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            // How long the code still works; tap for a new one
            TextButton.icon(
              onPressed: _newCode,
              icon: Icon(LucideIcons.refreshCw, size: 15, color: c.ink2),
              label: Text('$mm:$ss', style: ShareMeText.data.copyWith(color: c.ink2, fontSize: 14)),
            ),
            if (host.acceptsNearby) ...[
              const SizedBox(height: 18),
              if (_otherPc)
                Text(
                  s.nearbyHostHint,
                  style: ShareMeText.body.copyWith(color: c.ink2),
                  textAlign: TextAlign.center,
                )
              else
                TextButton(
                  onPressed: () => setState(() => _otherPc = true),
                  child: Text(s.otherPc, style: ShareMeText.label.copyWith(color: c.ink2)),
                ),
            ],
          ],
        );
      case PairHostStage.verifying:
        final peer = st.peer!;
        final warning = st.intruder
            ? Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(
                  st.nearby ? s.intruderNearby(name: peer.alias) : s.intruder,
                  style: ShareMeText.body.copyWith(color: c.warn, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center,
                ),
              )
            : const SizedBox.shrink();
        if (st.nearby) {
          // Another PC: each person types the 6 digits shown on the other computer
          return Column(
            children: [
              TypedCodePanel(
                myCode: st.sas!.hostCode,
                peerName: peer.alias,
                onSubmit: (code) async => host.checkCode(code),
                onCancel: host.reject,
              ),
              warning,
            ],
          );
        }
        if (st.legacyPeer) {
          // A phone with an older Shuttle still asks its user to compare these 12 digits and tap "Same, pair"
          return Column(
            children: [
              Text(
                s.legacyGuest,
                style: ShareMeText.body.copyWith(color: c.ink2),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 22),
              PairCheckPanel(sas: st.sas!),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Text(s.waitPhone, style: ShareMeText.body.copyWith(color: c.ink2)),
                ],
              ),
              const SizedBox(height: 12),
              TextButton(onPressed: host.reject, child: Text(t.shareme.settings.cancel)),
              warning,
            ],
          );
        }
        // A current phone confirms on its own within a moment
        return Padding(
          padding: const EdgeInsets.only(top: 60),
          child: Column(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 18),
              Text(
                s.finishing,
                style: ShareMeText.body.copyWith(color: c.ink2),
                textAlign: TextAlign.center,
              ),
              warning,
            ],
          ),
        );
      case PairHostStage.paired:
        final peer = st.peer!;
        final settings = context.watch(settingsProvider);
        final name = _name.text.trim().isEmpty ? peer.alias : _name.text.trim();
        return Column(
          children: [
            const SizedBox(height: 44),
            PairedDuo(theirFingerprint: peer.fingerprint),
            const SizedBox(height: 30),
            Text(s.doneTitle, style: ShareMeText.display.copyWith(color: c.ink, fontSize: 30)),
            const SizedBox(height: 8),
            Text(
              settings.quickSave || settings.quickSaveFromFavorites ? s.doneAuto(name: name) : s.doneAsk(name: name),
              style: ShareMeText.body.copyWith(color: c.ink2),
              textAlign: TextAlign.center,
            ),
            if (st.intruder) ...[
              const SizedBox(height: 14),
              Text(
                s.intruderAfter(name: name),
                style: ShareMeText.body.copyWith(color: c.warn, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 26),
            PairNameForm(controller: _name, onChanged: () => setState(() {}), onDone: () => _finish(peer)),
            const SizedBox(height: 8),
            TextButton(onPressed: () async => _removeNotMine(peer), child: Text(s.notMine)),
          ],
        );
      case PairHostStage.failed:
        return PairFailureView(
          failure: st.failure ?? PairFailure.protocol,
          primaryLabel: s.newCode,
          onPrimary: _newCode,
          onClose: () => Navigator.of(context).pop(),
        );
    }
  }
}

/// "X wants to pair with this computer: Ignore / Accept" (another PC clicked "Pair" next to this one under "Nearby").
/// Shown above the QR code, which can still be scanned.
class _NearbyRequestCard extends StatelessWidget {
  final PairPeerInfo peer;
  final VoidCallback onIgnore;
  final VoidCallback onAccept;

  const _NearbyRequestCard({required this.peer, required this.onIgnore, required this.onAccept});

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final s = t.shareme.pair;
    return SmCard(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.requestTitle(name: peer.alias),
            style: ShareMeText.title.copyWith(color: c.ink),
          ),
          if (peer.model != null) ...[
            const SizedBox(height: 2),
            Text(peer.model!, style: ShareMeText.meta.copyWith(color: c.ink2)),
          ],
          const SizedBox(height: 10),
          Text(
            s.requestHint(name: peer.alias),
            style: ShareMeText.body.copyWith(color: c.ink2),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: onIgnore,
                  style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(ShareMeSize.buttonH)),
                  child: Text(s.requestIgnore),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: FilledButton(onPressed: onAccept, child: Text(s.requestAccept)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
