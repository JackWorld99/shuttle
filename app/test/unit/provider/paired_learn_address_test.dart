import 'package:localsend_app/provider/paired_devices_provider.dart';
import 'package:test/test.dart';

/// Shuttle: after a paired device switches Wi-Fi, remember its new LAN address (e.g. a laptop on 192.168.9.x at the office and
/// 192.168.0.x at home: all stored addresses were the office ones, so at home, on the same Wi-Fi, it was only found via Tailscale).
void main() {
  group('withLearnedLanAddress', () {
    // The computer's addresses as stored on the phone (paired at the office): Wi-Fi, WSL, Tailscale
    const pcAtPairing = ['192.168.9.168', '172.17.96.1', '100.110.20.30'];

    test('a new LAN address goes first, Tailscale stays', () {
      expect(
        withLearnedLanAddress(pcAtPairing, '192.168.0.10'),
        ['192.168.0.10', '192.168.9.168', '172.17.96.1', '100.110.20.30'],
      );
    });

    test('keeps at most three LAN addresses, dropping the oldest', () {
      final home = withLearnedLanAddress(pcAtPairing, '192.168.0.10')!;
      expect(
        withLearnedLanAddress(home, '10.0.0.5'),
        ['10.0.0.5', '192.168.0.10', '192.168.9.168', '100.110.20.30'],
      );
    });

    test('an address seen again moves back to the front', () {
      final home = withLearnedLanAddress(pcAtPairing, '192.168.0.10')!;
      expect(
        withLearnedLanAddress(home, '192.168.9.168'),
        ['192.168.9.168', '192.168.0.10', '172.17.96.1', '100.110.20.30'],
      );
    });

    test('nothing to change when the address is already first', () {
      expect(withLearnedLanAddress(pcAtPairing, '192.168.9.168'), isNull);
    });

    test('Tailscale and carrier-grade NAT addresses are not learned', () {
      expect(withLearnedLanAddress(pcAtPairing, '100.110.20.30'), isNull);
      expect(withLearnedLanAddress(pcAtPairing, '100.90.10.20'), isNull);
    });

    test('IPv6 and addresses that only mean something on this host are not learned', () {
      expect(withLearnedLanAddress(pcAtPairing, 'fe80::1%11'), isNull);
      expect(withLearnedLanAddress(pcAtPairing, 'fd7a:115c:a1e0::1c36:b568'), isNull);
      expect(withLearnedLanAddress(pcAtPairing, '127.0.0.1'), isNull);
      expect(withLearnedLanAddress(pcAtPairing, '169.254.10.20'), isNull);
    });

    test('a record without addresses (paired before addresses were stored) learns one', () {
      expect(withLearnedLanAddress(const [], '192.168.0.11'), ['192.168.0.11']);
    });

    test('the phone record keeps its old VoLTE address until it is the oldest', () {
      // The phone's addresses as stored on the computer (at pairing time): VoLTE, office Wi-Fi, Tailscale
      const phone = ['10.73.145.176', '192.168.9.129', '100.90.10.20'];
      final home = withLearnedLanAddress(phone, '192.168.0.11')!;
      expect(home, ['192.168.0.11', '10.73.145.176', '192.168.9.129', '100.90.10.20']);
      expect(withLearnedLanAddress(home, '192.168.0.23'), ['192.168.0.23', '192.168.0.11', '10.73.145.176', '100.90.10.20']);
    });
  });
}
