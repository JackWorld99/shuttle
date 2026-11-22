import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/state/network_state.dart';
import 'package:localsend_app/util/shareme_pairing/pair_crypto.dart';
import 'package:localsend_app/util/shareme_pairing/pair_protocol.dart';

// Self-signed certificate for tests only (generated with openssl, used only here, unrelated to any real device)
const _hostFp = '2EF791611AAD09370EBBE1D39C01B2FE4CFA8A1BD2BBA33809419277D68896B0';
final _guestFp = 'AB' * 32;

PairPeerInfo _host() => const PairPeerInfo(
  fingerprint: _hostFp,
  alias: '书房电脑',
  model: 'Windows',
  type: 'desktop',
  port: 53317,
  https: true,
  addresses: ['192.168.9.20', '100.88.1.2'],
);

PairPeerInfo _guest([String? fp]) => PairPeerInfo(
  fingerprint: fp ?? _guestFp,
  alias: '小米手机',
  model: 'Xiaomi',
  type: 'mobile',
  port: 53317,
  https: true,
  addresses: const ['192.168.9.128', '100.101.102.103'],
);

Future<(PairHost, List<(PairPeerInfo, String, Uint8List)>)> _startHost({
  Duration nearbyRequestIdle = const Duration(seconds: 15),
  List<String> caps = pairCaps,
}) async {
  final saved = <(PairPeerInfo, String, Uint8List)>[];
  final host = PairHost(
    self: _host(),
    certificatePem: File('test/fixtures/shareme_pairing/host-test-only.crt').readAsStringSync(),
    privateKeyPem: File('test/fixtures/shareme_pairing/host-test-only.key').readAsStringSync(),
    ips: ['127.0.0.1'],
    loopbackOnly: true,
    preferredPort: 0, // not the real pairing port, so a Shuttle pairing page open on this machine doesn't conflict
    nearbyRequestIdle: nearbyRequestIdle,
    caps: caps,
    onPaired: (peer, ip, secret) async => saved.add((peer, ip, secret)),
  );
  await host.start();
  return (host, saved);
}

/// Waits until the condition holds (at most 2 seconds)
Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

Matcher _fails(PairFailure f) => throwsA(isA<PairException>().having((e) => e.failure, 'failure', f));

PairInvite _invite(PairHost host) => PairInvite.tryParse(host.state.value.qr!)!;

/// A 6-digit code that is not [code] (its first digit changed)
String _otherCode(String code) {
  final d = code.replaceAll(' ', '');
  return '${(int.parse(d[0]) + 1) % 10}${d.substring(1)}';
}

/// The "other computer" in computer-to-computer pairing
PairPeerInfo _otherComputer([String? fp]) => PairPeerInfo(
  fingerprint: fp ?? 'CE' * 32,
  alias: '客厅电脑',
  model: 'Windows',
  type: 'desktop',
  port: 53317,
  https: true,
  addresses: const ['192.168.9.30'],
);

/// Connects from "Nearby": address and fingerprint are the ones seen in "Nearby".
/// With the "Add device" page open on the other side, the request must be accepted there: if [accept] is true,
/// it is accepted on their behalf as soon as it is pending.
Future<PairGuestSession> _nearby(
  PairHost host, {
  PairPeerInfo? self,
  String fingerprint = _hostFp,
  bool accept = true,
  void Function()? onWaiting,
  bool Function()? cancelled,
}) => PairGuest(self: self ?? _otherComputer(), pollInterval: const Duration(milliseconds: 20)).connectNearby(
  host: '127.0.0.1',
  port: host.port!,
  fingerprint: fingerprint,
  onWaitingForAccept: () {
    onWaiting?.call();
    if (accept) host.acceptNearby();
  },
  cancelled: cancelled,
);

void main() {
  group('crypto', () {
    test('HKDF matches RFC 5869 test case 1', () {
      final okm = hkdf(
        ikm: List.filled(22, 0x0b),
        salt: fromHex('000102030405060708090A0B0C'),
        info: fromHex('F0F1F2F3F4F5F6F7F8F9'),
        length: 42,
      );
      expect(toHex(okm), '3CB25F25FAACD57A90434F64D0362F2A2D2D0A90CF1A5A4C5DB02D56ECC4C5BF34007208D5B887185865');
    });

    test('invite survives a round trip and rejects foreign codes', () {
      final invite = PairInvite(fingerprint: _hostFp, key: randomBytes(16), addresses: [(host: '192.168.1.23', port: 53999)]);
      final parsed = PairInvite.tryParse(invite.encode())!;
      expect(parsed.fingerprint, _hostFp);
      expect(parsed.key, invite.key);
      expect(parsed.addresses.single.host, '192.168.1.23');
      expect(invite.encode().length, lessThan(200));
      expect(PairInvite.tryParse('https://example.com/pair?v=1'), isNull);
      expect(PairInvite.tryParse('shuttle://pair?v=2&f=AA&k=AA&a=1.2.3.4:5'), isNull);
      expect(PairInvite.tryParse(invite.encode().replaceAll(RegExp(r'&a=.*'), '&a=evil.example:443')), isNull);
    });

    test('Tailscale addresses are recognised and offered next to the LAN ones', () {
      expect(isTailscaleIp('100.64.0.1'), isTrue);
      expect(isTailscaleIp('100.127.255.254'), isTrue);
      expect(isTailscaleIp('100.128.0.1'), isFalse);
      expect(isTailscaleIp('192.168.9.128'), isFalse);
      expect(isTailscaleIp(null), isFalse);
      // Without interface names only the address range counts (the old way); picking by interface (dropping mobile data etc.)
      // is tested in shareme_pair_addresses_test.dart
      expect(
        pairAddresses(
          const NetworkState(
            localIps: ['192.168.9.20', '127.0.0.1', '169.254.3.4', '100.88.1.2', '172.20.0.1', '10.0.0.5', '192.168.56.1'],
            initialized: true,
          ),
        ),
        ['192.168.9.20', '172.20.0.1', '10.0.0.5', '100.88.1.2'],
      );
    });

    test('pairing without a QR code uses its own labels, so its digits never match a QR pairing', () {
      final k = List.filled(16, 7);
      final n1 = List.filled(32, 1);
      final n2 = List.filled(32, 2);
      final qr = PairKeys.transcript(k: k, hostFingerprint: _hostFp, guestFingerprint: _guestFp, hostNonce: n1, guestNonce: n2);
      final nearby = PairKeys.transcript(k: k, hostFingerprint: _hostFp, guestFingerprint: _guestFp, hostNonce: n1, guestNonce: n2, nearby: true);
      expect(PairKeys.sas(qr).digits, isNot(PairKeys.sas(nearby).digits));
      expect(PairKeys.macKey(k), isNot(PairKeys.macKey(k, nearby: true)));
    });

    test('computer to computer: the host shows the first half of the code and the guest the second', () {
      final sas = PairKeys.sas(sha256Of([9, 9, 9]));
      final d = sas.digits.replaceAll(' ', '');
      expect(sas.hostCode, '${d.substring(0, 3)} ${d.substring(3, 6)}');
      expect(sas.guestCode, '${d.substring(6, 9)} ${d.substring(9)}');
      expect(PairSas.codeMatches(' ${d.substring(0, 6)} ', sas.hostCode), isTrue, reason: 'spaces are ignored');
      expect(PairSas.codeMatches(_otherCode(sas.hostCode), sas.hostCode), isFalse);
    });

    test('check code is 12 digits in three groups and deterministic', () {
      final t = sha256Of([1, 2, 3]);
      final a = PairKeys.sas(t);
      expect(a.digits, matches(RegExp(r'^\d{4} \d{4} \d{4}$')));
      expect(PairKeys.sas(t).digits, a.digits);
      expect(PairKeys.sas(sha256Of([1, 2, 4])).digits, isNot(a.digits));
    });
  });

  group('protocol', () {
    test('QR pairing: the computer confirms on its own once the phone proved it saw the code; both save the same secret', () async {
      final (host, saved) = await _startHost();
      addTearDown(host.close);
      final guest = PairGuest(self: _guest(), pollInterval: const Duration(milliseconds: 20));

      final session = await guest.connect(_invite(host));
      expect(host.state.value.stage, PairHostStage.verifying);
      expect(host.state.value.hostConfirmed, isTrue, reason: 'nobody has to compare digits on the computer any more');
      expect(host.state.value.legacyPeer, isFalse);
      expect(session.hostAutoQr, isTrue);
      expect(host.state.value.sas!.digits, session.sas.digits);
      expect(host.state.value.sas!.sealKey, session.sas.sealKey);
      expect(host.state.value.peer!.fingerprint, _guestFp);
      expect(session.peer.alias, '书房电脑');
      expect(saved, isEmpty, reason: 'nothing is saved before the phone confirms');

      var waited = false;
      await guest.confirm(session, onWaiting: () => waited = true);
      expect(waited, isFalse, reason: 'the computer had already confirmed');
      expect(host.state.value.stage, PairHostStage.paired);
      expect(saved.single.$1.fingerprint, _guestFp);
      expect(saved.single.$2, '127.0.0.1');
      expect(saved.single.$3, session.secret);
      // both sides get each other's addresses (Tailscale included), for later when not on the same Wi-Fi
      expect(saved.single.$1.addresses, ['192.168.9.128', '100.101.102.103']);
      expect(session.peer.addresses, ['192.168.9.20', '100.88.1.2']);
    });

    test('QR pairing: a phone with an older Shuttle still confirms by hand, and the computer shows it the digits', () async {
      final (host, saved) = await _startHost();
      addTearDown(host.close);
      final guest = PairGuest(self: _guest(), pollInterval: const Duration(milliseconds: 20), caps: const []);
      final session = await guest.connect(_invite(host));
      expect(host.state.value.legacyPeer, isTrue);
      expect(host.state.value.hostConfirmed, isTrue);
      expect(saved, isEmpty);
      await guest.confirm(session); // its "Same, pair"
      expect(saved.single.$1.fingerprint, _guestFp);
    });

    test('QR pairing: the phone notices an older computer (it then shows the digits to compare there)', () async {
      final (host, _) = await _startHost(caps: const []);
      addTearDown(host.close);
      final session = await PairGuest(self: _guest()).connect(_invite(host));
      expect(session.hostAutoQr, isFalse);
    });

    test('a phone pinned to another fingerprint refuses to talk (impostor computer)', () async {
      final (host, _) = await _startHost();
      addTearDown(host.close);
      final real = _invite(host);
      final forged = PairInvite(fingerprint: 'CD' * 32, key: real.key, addresses: real.addresses);
      await expectLater(
        const PairGuest(
          self: PairPeerInfo(fingerprint: 'AB', alias: 'x', model: null, type: 'mobile', port: 1, https: true),
        ).connect(forged),
        throwsA(isA<PairException>().having((e) => e.failure, 'failure', PairFailure.identity)),
      );
    });

    test('the code works once; a second device is refused and the computer warns', () async {
      final (host, _) = await _startHost();
      addTearDown(host.close);
      final invite = _invite(host);
      await PairGuest(self: _guest()).connect(invite);
      await expectLater(
        PairGuest(self: _guest('EF' * 32)).connect(invite),
        throwsA(isA<PairException>().having((e) => e.failure, 'failure', PairFailure.used)),
      );
      expect(host.state.value.intruder, isTrue);
    });

    test('someone without the code is rejected and does not use it up', () async {
      final (host, _) = await _startHost();
      addTearDown(host.close);
      final real = _invite(host);
      final guessed = PairInvite(fingerprint: real.fingerprint, key: randomBytes(16), addresses: real.addresses);
      await expectLater(
        PairGuest(self: _guest('EF' * 32)).connect(guessed),
        throwsA(isA<PairException>().having((e) => e.failure, 'failure', PairFailure.protocol)),
      );
      // the real phone still works
      final session = await PairGuest(self: _guest()).connect(real);
      expect(session.sas.digits, host.state.value.sas!.digits);
    });

    test('lots of wrong guesses do not end the pairing (only that address gets refused)', () async {
      // Security fix: more than 30 wrong guesses used to cancel the whole pairing, so anyone on the same Wi-Fi could keep disrupting it
      final (host, _) = await _startHost();
      addTearDown(host.close);
      final real = _invite(host);
      for (var i = 0; i < 35; i++) {
        final guessed = PairInvite(fingerprint: real.fingerprint, key: randomBytes(16), addresses: real.addresses);
        await expectLater(PairGuest(self: _guest('EF' * 32)).connect(guessed), throwsA(isA<PairException>()));
      }
      expect(host.state.value.stage, PairHostStage.showingCode);
      expect(host.state.value.failure, isNull);
    });

    test('"Cancel" on the computer ends it on the phone too', () async {
      final (host, saved) = await _startHost();
      addTearDown(host.close);
      final guest = PairGuest(self: _guest(), pollInterval: const Duration(milliseconds: 20));
      final session = await guest.connect(_invite(host));
      host.reject();
      await expectLater(
        guest.confirm(session),
        throwsA(isA<PairException>().having((e) => e.failure, 'failure', PairFailure.rejectedByPeer)),
      );
      expect(saved, isEmpty);
    });

    test('computer to computer: no QR code, both see the same digits and save the same secret', () async {
      final (host, saved) = await _startHost();
      addTearDown(host.close);
      final guest = PairGuest(self: _otherComputer(), pollInterval: const Duration(milliseconds: 20));
      var asked = false;
      final connecting = guest.connectNearby(
        host: '127.0.0.1',
        port: host.port!,
        fingerprint: _hostFp,
        onWaitingForAccept: () => asked = true,
      );
      // The "Add device" page first asks whether that computer may pair with this one; verification starts only after "Accept"
      await _until(() => asked);
      expect(host.state.value.request!.alias, '客厅电脑');
      expect(host.state.value.stage, PairHostStage.showingCode);
      expect(host.state.value.nearby, isFalse);
      host.acceptNearby();
      expect(host.state.value.request, isNull);
      expect(host.state.value.nearby, isTrue);
      final session = await connecting;
      expect(host.state.value.stage, PairHostStage.verifying);
      expect(host.state.value.nearby, isTrue);
      expect(host.state.value.sas!.digits, session.sas.digits);
      expect(host.state.value.peer!.alias, '客厅电脑');
      expect(session.invite, isNull);

      // Each person types the code shown on the other computer
      expect(await guest.checkCode(session, host.state.value.sas!.hostCode), PairCodeResult.match);
      final confirming = guest.confirm(session);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(saved, isEmpty, reason: 'nothing may be saved before the code is typed on this computer too');
      expect(host.checkCode(session.sas.guestCode), PairCodeResult.match);
      await confirming;
      expect(host.state.value.stage, PairHostStage.paired);
      expect(saved.single.$1.fingerprint, 'CE' * 32);
      expect(saved.single.$3, session.secret);
    });

    test('computer to computer: three wrong codes on this computer cancel the pairing on both sides', () async {
      final (host, saved) = await _startHost();
      addTearDown(host.close);
      final session = await _nearby(host);
      final guest = PairGuest(self: _otherComputer(), pollInterval: const Duration(milliseconds: 20));
      expect(await guest.checkCode(session, session.sas.hostCode), PairCodeResult.match);
      final confirming = expectLater(guest.confirm(session), _fails(PairFailure.rejectedByPeer));
      final wrong = _otherCode(session.sas.guestCode);
      expect(host.checkCode(wrong), PairCodeResult.wrong);
      expect(host.checkCode(wrong), PairCodeResult.wrong);
      expect(host.checkCode(wrong), PairCodeResult.exhausted);
      expect(host.state.value.failure, PairFailure.codeMismatch);
      await confirming;
      expect(saved, isEmpty);
    });

    test('computer to computer: three wrong codes on the other computer cancel it here too', () async {
      final (host, saved) = await _startHost();
      addTearDown(host.close);
      final session = await _nearby(host);
      final guest = PairGuest(self: _otherComputer());
      final wrong = _otherCode(session.sas.hostCode);
      expect(await guest.checkCode(session, wrong), PairCodeResult.wrong);
      expect(await guest.checkCode(session, wrong), PairCodeResult.wrong);
      expect(await guest.checkCode(session, wrong), PairCodeResult.exhausted);
      expect(host.state.value.failure, PairFailure.rejectedByPeer);
      expect(await guest.checkCode(session, session.sas.hostCode), PairCodeResult.exhausted, reason: 'too late for the right code');
      expect(saved, isEmpty);
    });

    test('computer to computer: confirming without typing the code is refused', () async {
      final (host, _) = await _startHost();
      addTearDown(host.close);
      final session = await _nearby(host);
      await expectLater(PairGuest(self: _otherComputer()).confirm(session), _fails(PairFailure.protocol));
      expect(host.state.value.guestConfirmed, isFalse);
    });

    test('computer to computer: an older computer is refused both ways, so there is no one-click fallback', () async {
      final (host, _) = await _startHost();
      addTearDown(host.close);
      // an older computer connecting to this one
      await expectLater(
        PairGuest(self: _otherComputer(), caps: const []).connectNearby(host: '127.0.0.1', port: host.port!, fingerprint: _hostFp),
        _fails(PairFailure.outdated),
      );
      expect(host.state.value.request, isNull, reason: 'it does not even get an "Accept" prompt');
      // this computer connecting to an older one
      final (old, _) = await _startHost(caps: const []);
      addTearDown(old.close);
      await expectLater(_nearby(old), _fails(PairFailure.outdated));
    });

    test('computer to computer: someone pretending to be that computer is refused (pinned fingerprint)', () async {
      final (host, _) = await _startHost();
      addTearDown(host.close);
      await expectLater(
        _nearby(host, fingerprint: 'CD' * 32),
        throwsA(isA<PairException>().having((e) => e.failure, 'failure', PairFailure.identity)),
      );
      expect(host.state.value.stage, PairHostStage.showingCode, reason: 'the handshake failed; the pairing page is unaffected');
    });

    test('computer to computer: only one at a time; a second computer and a phone are turned away', () async {
      final (host, _) = await _startHost();
      addTearDown(host.close);
      final first = await _nearby(host);
      await expectLater(
        _nearby(host, self: _otherComputer('DD' * 32)),
        throwsA(isA<PairException>().having((e) => e.failure, 'failure', PairFailure.used)),
      );
      expect(host.state.value.intruder, isFalse, reason: 'a second computer arriving late does not mean someone took the QR code');
      await expectLater(
        PairGuest(self: _guest()).connect(_invite(host)),
        throwsA(isA<PairException>().having((e) => e.failure, 'failure', PairFailure.used)),
      );
      expect(first.peer.fingerprint, _hostFp);
      expect(host.state.value.peer!.fingerprint, 'CE' * 32, reason: 'still verifying with the first one');
      // The computer used to stay silent here while the phone only saw "already used". Now the computer warns too
      // (the UI says a phone scanned this QR code)
      expect(host.state.value.intruder, isTrue);
    });

    test('computer to computer: nobody else can confirm without the session number', () async {
      final (host, saved) = await _startHost();
      addTearDown(host.close);
      final real = await _nearby(host);
      // A bystander on the same Wi-Fi knows address and fingerprint, but not the session number sent only over the encrypted connection
      final forged = PairGuestSession(
        invite: null,
        pin: _hostFp,
        address: real.address,
        sid: b64u(randomBytes(16)),
        peer: real.peer,
        sas: real.sas,
        transcript: real.transcript,
        secret: real.secret,
        macKey: randomBytes(32),
        nearby: true,
      )..codeChecked = true;
      await expectLater(PairGuest(self: _otherComputer('DD' * 32)).confirm(forged), throwsA(isA<PairException>()));
      expect(host.state.value.guestConfirmed, isFalse);
      expect(host.checkCode(real.sas.guestCode), PairCodeResult.match);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(saved, isEmpty, reason: 'the other computer has not confirmed yet');
    });

    test('computer to computer: a computer waiting for one peer turns everyone else away', () async {
      // When both sides tap "Pair", the one with the smaller fingerprint hosts for the moment and waits only for the computer it chose
      final host = PairHost(
        self: _host(),
        certificatePem: File('test/fixtures/shareme_pairing/host-test-only.crt').readAsStringSync(),
        privateKeyPem: File('test/fixtures/shareme_pairing/host-test-only.key').readAsStringSync(),
        ips: const [],
        loopbackOnly: true,
        preferredPort: 0,
        onlyGuest: 'CE' * 32,
        onPaired: (peer, ip, secret) async {},
      );
      await host.start();
      addTearDown(host.close);
      await expectLater(
        _nearby(host, self: _otherComputer('DD' * 32)),
        throwsA(isA<PairException>().having((e) => e.failure, 'failure', PairFailure.protocol)),
      );
      expect(host.state.value.stage, PairHostStage.showingCode, reason: 'the unknown computer could not take over');
      expect(host.state.value.request, isNull, reason: 'the unknown computer left no pending request either');
      var asked = false;
      final session = await _nearby(host, accept: false, onWaiting: () => asked = true);
      expect(asked, isFalse, reason: 'both sides tapped "Pair": the user already chose this computer, so no "Accept" prompt');
      expect(session.sas.digits, host.state.value.sas!.digits);
    });

    test('add-device page: a computer has to be accepted first; until then the phone can still scan', () async {
      // Anyone on the same Wi-Fi used to grab the pairing with one nearby-hello, and the phone scanning the code only saw "already used"
      final (host, saved) = await _startHost();
      addTearDown(host.close);
      var asked = false;
      final stranger = expectLater(_nearby(host, accept: false, onWaiting: () => asked = true), _fails(PairFailure.used));
      await _until(() => asked);
      expect(host.state.value.request!.fingerprint, 'CE' * 32);
      expect(host.state.value.stage, PairHostStage.showingCode);

      final phone = PairGuest(self: _guest(), pollInterval: const Duration(milliseconds: 20));
      final session = await phone.connect(_invite(host));
      expect(host.state.value.request, isNull, reason: 'the pending request is dropped as soon as the phone arrives');
      expect(host.state.value.nearby, isFalse);
      await stranger; // that computer gets "busy" the next time it asks
      expect(host.state.value.intruder, isFalse);

      await phone.confirm(session);
      expect(saved.single.$1.fingerprint, _guestFp, reason: 'the phone is saved, not that computer');
    });

    test('add-device page: "Ignore" turns that address away and the code still works', () async {
      final (host, _) = await _startHost();
      addTearDown(host.close);
      var asked = false;
      final ignored = expectLater(_nearby(host, accept: false, onWaiting: () => asked = true), _fails(PairFailure.declined));
      await _until(() => asked);
      host.ignoreNearby();
      expect(host.state.value.request, isNull);
      await ignored;
      // the same address with another fingerprint is refused too (the fingerprint is self-reported)
      await expectLater(_nearby(host, self: _otherComputer('DD' * 32)), _fails(PairFailure.declined));
      expect(host.state.value.request, isNull);
      expect(host.state.value.stage, PairHostStage.showingCode);
      final session = await PairGuest(self: _guest()).connect(_invite(host));
      expect(session.sas.digits, host.state.value.sas!.digits, reason: 'scanning is unaffected');
    });

    test('add-device page: one request at a time, and requests count toward the per-address limit', () async {
      final (host, _) = await _startHost();
      addTearDown(host.close);
      var asked = false;
      final first = expectLater(_nearby(host, accept: false, onWaiting: () => asked = true), _fails(PairFailure.protocol));
      await _until(() => asked);
      final failures = <PairFailure>[];
      for (var i = 0; i < 12; i++) {
        final fp = i.toRadixString(16).padLeft(2, '0').toUpperCase() * 32;
        try {
          await _nearby(host, self: _otherComputer(fp));
        } on PairException catch (e) {
          failures.add(e.failure);
        }
      }
      // While the first is pending, other computers get "busy"; after 10 requests (counting the first) this address always gets 429
      expect(failures.take(10), everyElement(PairFailure.used));
      expect(failures.skip(10), everyElement(PairFailure.protocol));
      expect(host.state.value.request!.fingerprint, 'CE' * 32, reason: 'the first computer is still pending; later ones could not replace it');
      await first; // the first one is refused too when it asks again (same address)
      expect(host.state.value.stage, PairHostStage.showingCode, reason: 'only this address is refused; the pairing page is unaffected');
      expect(host.state.value.nearby, isFalse);
    });

    test('add-device page: a request nobody asks about any more goes away', () async {
      final (host, _) = await _startHost(nearbyRequestIdle: const Duration(milliseconds: 150));
      addTearDown(host.close);
      var asked = false;
      var closed = false;
      final gone = expectLater(
        _nearby(host, accept: false, onWaiting: () => asked = true, cancelled: () => closed),
        _fails(PairFailure.rejectedHere),
      );
      await _until(() => asked);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(host.state.value.request, isNotNull, reason: 'the request stays while the other side keeps asking');
      closed = true; // that computer closed its pairing page
      await gone;
      await _until(() => host.state.value.request == null);
      expect(host.state.value.stage, PairHostStage.showingCode);
    });

    test('computer to computer: reaching itself is "not open yet", not an impostor', () async {
      // When both sides tap "Pair", the one with the smaller fingerprint waits on the pairing port and also connects to the other;
      // if the other's address points back to this machine (two Shuttles on one computer), it reaches itself and sees its own certificate
      final (host, _) = await _startHost();
      addTearDown(host.close);
      await expectLater(
        _nearby(host, self: _otherComputer(_hostFp), fingerprint: 'CE' * 32),
        throwsA(isA<PairException>().having((e) => e.failure, 'failure', PairFailure.unreachable)),
      );
      expect(host.state.value.stage, PairHostStage.showingCode, reason: 'connecting to itself does not affect the pairing page');
    });

    test('computer to computer: page not open yet means unreachable (the other side keeps trying)', () async {
      final (host, _) = await _startHost();
      final port = host.port!;
      await host.close();
      await expectLater(
        PairGuest(self: _otherComputer()).connectNearby(host: '127.0.0.1', port: port, fingerprint: _hostFp),
        throwsA(isA<PairException>().having((e) => e.failure, 'failure', PairFailure.unreachable)),
      );
    });

    test('"Cancel" on the phone ends it on the computer', () async {
      final (host, saved) = await _startHost();
      addTearDown(host.close);
      final guest = PairGuest(self: _guest());
      final session = await guest.connect(_invite(host));
      await guest.reject(session);
      expect(host.state.value.stage, PairHostStage.failed);
      expect(host.state.value.failure, PairFailure.rejectedByPeer);
      expect(saved, isEmpty);
    });
  });
}
