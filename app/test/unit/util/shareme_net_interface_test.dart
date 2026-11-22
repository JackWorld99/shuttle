import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/util/shareme_net_interface.dart';

// Shuttle: which kind of network interface each local address is on. The addresses reported to the peer when pairing
// and the subnets scanned for nearby devices both depend on it.

class _FakeInterface implements NetworkInterface {
  @override
  final String name;

  @override
  final List<InterfaceAddress> addresses;

  @override
  int get index => 0;

  _FakeInterface(this.name, List<String> ips) : addresses = [for (final ip in ips) _FakeAddress(InternetAddress(ip))];
}

/// Implements only address and type; the tests don't use the other members
class _FakeAddress implements InterfaceAddress {
  final InternetAddress _a;

  _FakeAddress(this._a);

  @override
  String get address => _a.address;

  @override
  InternetAddressType get type => _a.type;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('interface kind: by name only', () {
    const expected = {
      // Android
      'wlan0': NetInterfaceKind.other,
      'wlan1': NetInterfaceKind.other,
      'swlan0': NetInterfaceKind.other,
      'ap0': NetInterfaceKind.other,
      'eth0': NetInterfaceKind.other,
      'rndis0': NetInterfaceKind.other,
      'rmnet_data0': NetInterfaceKind.cellular,
      'rmnet_data12': NetInterfaceKind.cellular,
      'rmnet0': NetInterfaceKind.cellular,
      'r_rmnet_data0': NetInterfaceKind.cellular,
      'ccmni4': NetInterfaceKind.cellular,
      'v4-rmnet_data0': NetInterfaceKind.cellular,
      'clat4': NetInterfaceKind.cellular,
      'tun0': NetInterfaceKind.vpn,
      'tun1': NetInterfaceKind.vpn,
      'ipsec0': NetInterfaceKind.vpn,
      'tunnel': NetInterfaceKind.other,
      // Windows
      'Wi-Fi': NetInterfaceKind.other,
      'WLAN': NetInterfaceKind.other,
      '以太网': NetInterfaceKind.other,
      'Ethernet 2': NetInterfaceKind.other,
      'Local Area Connection* 10': NetInterfaceKind.other,
      'Tailscale': NetInterfaceKind.tailscale,
      'Cellular': NetInterfaceKind.cellular,
      '手机网络': NetInterfaceKind.cellular,
      'vEthernet (WSL)': NetInterfaceKind.hostOnly,
      'vEthernet (WSL (Hyper-V firewall))': NetInterfaceKind.hostOnly,
      'vEthernet (Default Switch)': NetInterfaceKind.hostOnly,
      'vEthernet (External Switch)': NetInterfaceKind.other,
      'VMware Network Adapter VMnet1': NetInterfaceKind.hostOnly,
      'VirtualBox Host-Only Network #2': NetInterfaceKind.hostOnly,
      // Linux
      'tailscale0': NetInterfaceKind.tailscale,
    };
    expect({for (final name in expected.keys) name: netInterfaceKindOf(name)}, expected);
  });

  test('IPv4 addresses usable by other devices: not loopback, 169.254, 0.x, 464XLAT translation addresses or IPv6', () {
    for (final ip in ['192.168.1.23', '10.73.20.5', '172.17.208.1', '100.64.0.1', '192.0.0.8']) {
      expect(isUsableIpv4(ip), isTrue, reason: ip);
    }
    for (final ip in ['127.0.0.1', '0.0.0.0', '169.254.83.107', '192.0.0.4', 'fe80::1', '1.2.3', '256.1.1.1', ' 1.2.3.4', '']) {
      expect(isUsableIpv4(ip), isFalse, reason: ip);
    }
  });

  test('Tailscale range: 100.64.0.0/10 minus the small ChromeOS block', () {
    expect(inTailscaleRange('100.64.0.1'), isTrue);
    expect(inTailscaleRange('100.127.255.254'), isTrue);
    expect(inTailscaleRange('100.115.94.1'), isTrue);
    expect(inTailscaleRange('100.115.92.5'), isFalse);
    expect(inTailscaleRange('100.115.93.255'), isFalse);
    expect(inTailscaleRange('100.128.0.1'), isFalse);
    expect(inTailscaleRange('10.0.0.1'), isFalse);
    expect(inCgnatRange('100.115.92.5'), isTrue, reason: 'still inside the carrier-grade NAT range');
  });

  test('the local address list records the interface of each IPv4 address (IPv6 ignored)', () {
    final interfaces = [
      _FakeInterface('wlan0', ['192.168.1.23', 'fe80::1']),
      _FakeInterface('rmnet_data1', ['10.73.20.5']),
      _FakeInterface('tun0', ['100.101.102.103', 'fd7a:115c:a1e0::1']),
    ];
    expect(ipv4InterfaceNames(interfaces), {'192.168.1.23': 'wlan0', '10.73.20.5': 'rmnet_data1', '100.101.102.103': 'tun0'});
  });
}
