import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:localsend_isolates/model/device.dart';

// Shuttle: whether to scan again for a direct LAN connection when the app returns to the foreground
// (onlyViaTailscaleOnLan / RescanForLanAction). Seen in practice: for about a minute after the phone rejoined Wi-Fi it couldn't
// reach the computer, so both scans after the network change found it only via Tailscale, and it kept showing "via Tailscale".

const _pc = 'CD';

Device _device(String ip, {String fingerprint = _pc}) => Device(
  signalingId: null,
  ip: ip,
  version: '2.1',
  port: 53317,
  https: true,
  fingerprint: fingerprint,
  alias: 'Great Tomato',
  deviceModel: 'Windows',
  deviceType: DeviceType.desktop,
  download: false,
  channels: const [],
);

void main() {
  const lanIps = ['192.168.0.11'];
  const trusted = {_pc};

  test('a paired device only over Tailscale while on Wi-Fi: rescan', () {
    expect(onlyViaTailscaleOnLan(nearby: [_device('100.110.20.30')], trusted: trusted, lanIps: lanIps), isTrue);
  });

  test('the paired device is already on the LAN: no rescan', () {
    expect(onlyViaTailscaleOnLan(nearby: [_device('192.168.0.10')], trusted: trusted, lanIps: lanIps), isFalse);
  });

  test('no LAN to scan (mobile data only): no rescan', () {
    expect(onlyViaTailscaleOnLan(nearby: [_device('100.110.20.30')], trusted: trusted, lanIps: const []), isFalse);
  });

  test('a stranger over Tailscale does not count', () {
    expect(
      onlyViaTailscaleOnLan(
        nearby: [_device('100.101.1.2', fingerprint: 'EF')],
        trusted: trusted,
        lanIps: lanIps,
      ),
      isFalse,
    );
  });

  test('nothing found at all: no rescan (the normal scan handles that)', () {
    expect(onlyViaTailscaleOnLan(nearby: const [], trusted: trusted, lanIps: lanIps), isFalse);
  });
}
