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
import 'package:localsend_app/widget/shareme/pair_widgets.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Shuttle: "Pair a new device" on the PC. Shows a QR code, waits for the phone to scan it, then both compare the pairing seal.
/// Nothing is saved until the PC user clicks "Same, pair".
/// Another PC can also pair directly from "Nearby" (no QR code); the verify text then says to look at that PC's screen.
/// That PC's request first shows as "X wants to pair with this computer: Ignore / Accept"; verification only starts after
/// "Accept". Until then the QR code can still be scanned (so someone on the same Wi-Fi can't occupy pairing with a request
/// and downgrade QR pairing to a visual-only check).
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

  void _newCode() {
    _name.clear();
    _host?.renew();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final s = t.shareme.pair;
    final host = _host;
    return Scaffold(
      appBar: AppBar(title: Text(s.hostTitle)),
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
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(ShareMeSize.radiusGroup)),
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
            const SizedBox(height: 20),
            Text(
              s.pairHostHint,
              style: ShareMeText.body.copyWith(color: c.ink),
              textAlign: TextAlign.center,
            ),
            if (host.acceptsNearby) ...[
              const SizedBox(height: 10),
              Text(
                s.nearbyHostHint,
                style: ShareMeText.body.copyWith(color: c.ink),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 10),
            Text(
              s.hostOneUse,
              style: ShareMeText.meta.copyWith(color: c.ink2),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            Text(
              s.expiresIn(time: '$mm:$ss'),
              style: ShareMeText.data.copyWith(color: c.ink2),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: _newCode, child: Text(s.newCode)),
          ],
        );
      case PairHostStage.verifying:
        final peer = st.peer!;
        return Column(
          children: [
            Text(
              s.verifyTitle,
              style: ShareMeText.display.copyWith(color: c.ink),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              peer.model == null ? peer.alias : s.peerLine(name: peer.alias, model: peer.model!),
              style: ShareMeText.meta.copyWith(color: c.ink2),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 22),
            PairCheckPanel(sas: st.sas!),
            const SizedBox(height: 18),
            Text(
              st.nearby ? s.verifyHostNearby(name: peer.alias) : s.verifyHost,
              style: ShareMeText.body.copyWith(color: c.ink2),
              textAlign: TextAlign.center,
            ),
            if (st.intruder) ...[
              const SizedBox(height: 14),
              Text(
                st.nearby ? s.intruderNearby(name: peer.alias) : s.intruder,
                style: ShareMeText.body.copyWith(color: c.warn, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 18),
            TextField(
              controller: _name,
              enabled: !st.hostConfirmed,
              maxLength: 32,
              decoration: InputDecoration(labelText: s.nameIt, counterText: ''),
            ),
            const SizedBox(height: 20),
            if (st.hostConfirmed)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Text(
                    st.nearby ? s.waitPeer(name: peer.alias) : s.waitPhone,
                    style: ShareMeText.body.copyWith(color: c.ink2),
                  ),
                ],
              )
            else
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: host.reject,
                      style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(ShareMeSize.buttonH)),
                      child: Text(s.different),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton(onPressed: () async => host.confirm(), child: Text(s.sameHost)),
                  ),
                ],
              ),
          ],
        );
      case PairHostStage.paired:
        final settings = context.watch(settingsProvider);
        final me = context.read(securityProvider).certificateHash;
        final name = _name.text.trim().isEmpty ? st.peer!.alias : _name.text.trim();
        return Column(
          children: [
            const SizedBox(height: 12),
            PairedDuo(myFingerprint: me, myName: host.self.alias, theirFingerprint: st.peer!.fingerprint, theirName: name),
            const SizedBox(height: 22),
            Text(s.doneTitle, style: ShareMeText.display.copyWith(color: c.ink)),
            const SizedBox(height: 10),
            Text(
              settings.quickSave || settings.quickSaveFromFavorites ? s.doneAuto(name: name) : s.doneAsk(name: name),
              style: ShareMeText.body.copyWith(color: c.ink2),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: () => Navigator.of(context).pop(), child: Text(s.done)),
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: BoxDecoration(
        color: c.group,
        borderRadius: BorderRadius.circular(ShareMeSize.radiusGroup),
        boxShadow: c.cardShadow,
      ),
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
