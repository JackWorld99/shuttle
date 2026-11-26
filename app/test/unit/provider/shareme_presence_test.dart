import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/persistence/paired_record.dart';
import 'package:localsend_app/provider/network/shareme_presence.dart';
import 'package:localsend_isolates/model/device.dart';

// Shuttle: unreachable devices are shown as offline. Checked every 20 seconds: whom to ask, at which addresses,
// and how many unanswered checks make a device offline.

final _pcFp = 'AB' * 32;
final _phoneFp = 'CD' * 32;
final _strangerFp = 'EF' * 32;

Device _device(String fingerprint, String ip, {bool https = true, DeviceType type = DeviceType.desktop}) => Device(
  signalingId: null,
  ip: ip,
  version: '2.1',
  port: 53317,
  https: https,
  fingerprint: fingerprint,
  alias: '设备',
  deviceModel: null,
  deviceType: type,
  download: false,
  channels: const [],
);

FavoriteDevice _favorite(String fingerprint, String ip) => FavoriteDevice.fromValues(fingerprint: fingerprint, ip: ip, port: 53317, alias: '我的');

PairedRecord _paired(String fingerprint, List<String> addresses) =>
    PairedRecord(fingerprint: fingerprint, secret: 'x', pairedAt: 0, addresses: addresses);

void main() {
  group('whom to ask, at which addresses', () {
    test('online "My devices": the address currently listed first, then the other stored addresses (no duplicates)', () {
      final targets = presenceTargets(
        nearby: [_device(_pcFp, '192.168.9.20')],
        favorites: [_favorite(_pcFp, '192.168.9.20')],
        paired: [
          _paired(_pcFp, ['192.168.9.20', '100.88.1.2']),
        ],
        https: true,
      );
      expect(targets.single.addresses.map((a) => a.ip), ['192.168.9.20', '100.88.1.2']);
      expect(targets.single.listed, isNotNull);
    });

    test('offline "My devices" are asked too (back online once they answer), at all stored addresses', () {
      final targets = presenceTargets(
        nearby: const [],
        favorites: [_favorite(_phoneFp, '192.168.9.128')],
        paired: [
          _paired(_phoneFp, ['192.168.9.128', '100.101.102.103']),
        ],
        https: true,
      );
      expect(targets.single.fingerprint, _phoneFp);
      expect(targets.single.listed, isNull);
      expect(targets.single.https, isTrue);
      expect(targets.single.addresses.map((a) => a.ip), ['192.168.9.128', '100.101.102.103']);
    });

    test('nearby unknown devices are not asked (that used to send them our name and fingerprint every 20 s, revealing when we are online)', () {
      final targets = presenceTargets(nearby: [_device(_strangerFp, '192.168.9.50')], favorites: const [], paired: const [], https: true);
      expect(targets, isEmpty);
    });

    test('devices in an active transfer are not asked (clearly online; a slow moment in a big transfer must not count as offline)', () {
      final targets = presenceTargets(
        nearby: [_device(_pcFp, '192.168.9.20'), _device(_phoneFp, '192.168.9.128')],
        favorites: [_favorite(_pcFp, '192.168.9.20'), _favorite(_phoneFp, '192.168.9.128')],
        paired: const [],
        https: true,
        busy: {_pcFp},
      );
      expect(targets.map((t) => t.fingerprint), [_phoneFp]);
    });
  });

  group('how often to ask', () {
    final now = DateTime(2026, 11, 20, 18);
    PresenceTarget target({Device? listed}) =>
        PresenceTarget(fingerprint: _pcFp, https: true, addresses: const [(ip: '192.168.9.20', port: 53317)], listed: listed);

    test('online computers every 20 s, online phones every 60 s (each check wakes up the phone network), offline devices every 5 min', () {
      expect(presenceIntervalFor(target(listed: _device(_pcFp, '192.168.9.20'))), const Duration(seconds: 20));
      expect(presenceIntervalFor(target(listed: _device(_phoneFp, '192.168.9.128', type: DeviceType.mobile))), const Duration(seconds: 60));
      expect(presenceIntervalFor(target()), const Duration(minutes: 5));
    });

    test('never asked: ask; interval not reached: skip; phone back in the foreground (force): ask all', () {
      final phone = target(listed: _device(_phoneFp, '192.168.9.128', type: DeviceType.mobile));
      expect(presenceDue(phone, null, now), isTrue);
      expect(presenceDue(phone, now.subtract(const Duration(seconds: 20)), now), isFalse);
      expect(presenceDue(phone, now.subtract(const Duration(seconds: 60)), now), isTrue, reason: 'the 20 s timer asks on its third tick');
      final offline = target();
      expect(presenceDue(offline, now.subtract(const Duration(minutes: 1)), now), isFalse);
      expect(presenceDue(offline, now.subtract(const Duration(minutes: 1)), now, force: true), isTrue);
    });

    test('an offline device with something waiting in the send queue is asked every minute; online ones as before', () {
      expect(presenceIntervalFor(target(), waiting: true), const Duration(minutes: 1));
      expect(presenceIntervalFor(target(listed: _device(_pcFp, '192.168.9.20')), waiting: true), const Duration(seconds: 20));
      final offline = target();
      expect(presenceDue(offline, now.subtract(const Duration(seconds: 40)), now, waiting: true), isFalse);
      expect(presenceDue(offline, now.subtract(const Duration(minutes: 1)), now, waiting: true), isTrue);
    });
  });

  group('how many misses mean offline', () {
    final listed = PresenceTarget(
      fingerprint: _pcFp,
      https: true,
      addresses: const [(ip: '192.168.9.20', port: 53317), (ip: '100.88.1.2', port: 53317)],
      listed: _device(_pcFp, '192.168.9.20'),
    );

    test('both LAN and Tailscale answer: use the LAN (faster)', () async {
      final found = await probeAllAddresses(listed, (t, a) async => _device(t.fingerprint, a.ip));
      expect(found!.ip, '192.168.9.20');
    });

    test('only Tailscale answers (e.g. left that Wi-Fi): still online, use the Tailscale address', () async {
      final found = await probeAllAddresses(listed, (t, a) async => a.ip.startsWith('100.') ? _device(t.fingerprint, a.ip) : null);
      expect(found!.ip, '100.88.1.2');
    });

    test('the LAN address in use answers: Tailscale is not asked (no need to wake up that path)', () async {
      final asked = <String>[];
      final found = await probeAllAddresses(listed, (t, a) async {
        asked.add(a.ip);
        return _device(t.fingerprint, a.ip);
      });
      expect(found!.ip, '192.168.9.20');
      expect(asked, ['192.168.9.20']);
    });

    test('on Tailscale: all addresses are asked together; if the LAN answers too, switch back to it (back on the same Wi-Fi)', () async {
      final viaTailscale = PresenceTarget(
        fingerprint: _pcFp,
        https: true,
        addresses: const [(ip: '100.88.1.2', port: 53317), (ip: '192.168.9.20', port: 53317)],
        listed: _device(_pcFp, '100.88.1.2'),
      );
      final asked = <String>[];
      final found = await probeAllAddresses(viaTailscale, (t, a) async {
        asked.add(a.ip);
        return _device(t.fingerprint, a.ip);
      });
      expect(found!.ip, '192.168.9.20');
      expect(asked.toSet(), {'100.88.1.2', '192.168.9.20'});
    });

    test('errors (refused, timeout, wrong certificate) count as no answer', () async {
      final found = await probeAllAddresses(listed, (t, a) async => throw Exception('connection refused'));
      expect(found, isNull);
    });

    test('an online device misses once, then answers shortly after: still online (a brief drop does not count)', () async {
      var calls = 0;
      final found = await checkPresence(listed, (t, a) async {
        calls++;
        return calls > listed.addresses.length ? _device(t.fingerprint, a.ip) : null;
      }, retryDelay: Duration.zero);
      expect(found, isNotNull);
    });

    test('an online device misses twice: offline', () async {
      var calls = 0;
      final found = await checkPresence(listed, (t, a) async {
        calls++;
        return null;
      }, retryDelay: Duration.zero);
      expect(found, isNull);
      expect(calls, listed.addresses.length * 2, reason: 'each address is asked twice');
    });

    test('a device that is already offline is asked only once (a later round asks again)', () async {
      final offline = PresenceTarget(fingerprint: _phoneFp, https: true, addresses: const [(ip: '192.168.9.128', port: 53317)], listed: null);
      var calls = 0;
      final found = await checkPresence(offline, (t, a) async {
        calls++;
        return null;
      }, retryDelay: Duration.zero);
      expect(found, isNull);
      expect(calls, 1);
    });
  });
}
