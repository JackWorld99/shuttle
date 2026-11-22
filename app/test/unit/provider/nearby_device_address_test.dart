import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_isolates/model/device.dart';

// Shuttle: which address the list keeps when the same device is found both on the LAN and via Tailscale (pickDeviceAddress).
// Problem seen in practice: after the phone switched to mobile data, the computer kept its stale Wi-Fi address and sending failed.

Device _device(String ip) => Device(
  signalingId: null,
  ip: ip,
  version: '2.1',
  port: 53317,
  https: true,
  fingerprint: 'AB' * 32,
  alias: '明亮的南瓜',
  deviceModel: 'Xiaomi',
  deviceType: DeviceType.mobile,
  download: false,
  channels: const [],
);

void main() {
  final now = DateTime(2026, 11, 13, 15, 30);
  final lan = _device('192.168.9.130');
  final tailscale = _device('100.90.10.20');

  test('LAN address just confirmed in the same scan: keep the LAN (faster)', () {
    final picked = pickDeviceAddress(old: lan, incoming: tailscale, oldConfirmedAt: now.subtract(const Duration(seconds: 3)), now: now);
    expect(picked.ip, lan.ip);
  });

  test('LAN address not confirmed for a long time (the peer probably left that Wi-Fi): switch to Tailscale', () {
    final picked = pickDeviceAddress(old: lan, incoming: tailscale, oldConfirmedAt: now.subtract(const Duration(minutes: 40)), now: now);
    expect(picked.ip, tailscale.ip);
  });

  test('unknown when the LAN address was confirmed (e.g. before an app restart): switch to Tailscale', () {
    final picked = pickDeviceAddress(old: lan, incoming: tailscale, oldConfirmedAt: null, now: now);
    expect(picked.ip, tailscale.ip);
  });

  test('exactly at expiry the LAN is no longer preferred', () {
    final picked = pickDeviceAddress(old: lan, incoming: tailscale, oldConfirmedAt: now.subtract(lanStillFresh), now: now);
    expect(picked.ip, tailscale.ip);
  });

  test('the newly confirmed address is on the LAN: always use it', () {
    final picked = pickDeviceAddress(old: tailscale, incoming: lan, oldConfirmedAt: now, now: now);
    expect(picked.ip, lan.ip);
  });

  test('old and new are both Tailscale addresses: use the new one', () {
    final newer = _device('100.90.10.21');
    final picked = pickDeviceAddress(old: tailscale, incoming: newer, oldConfirmedAt: now, now: now);
    expect(picked.ip, newer.ip);
  });
}
