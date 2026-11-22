import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/state/network_state.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';

// Shuttle: if no nearby device is found within 1 second, every address in the subnet of each local address (254 addresses) is
// asked in turn. Each request sends this device's name, model and certificate fingerprint to whoever answers, so only real LANs
// are scanned (subnetScanIps). On mobile data only, the phone used to ask 254 strangers in the carrier's subnet
// (10.73.x.1–254), and with a proxy app running it also scanned the proxy's fake subnet.

/// A device's current network: address → interface name (null = interface unknown). The order is that of the local address list.
NetworkState _net(Map<String, String?> ipToInterface) => NetworkState(
  localIps: ipToInterface.keys.toList(),
  interfaceNames: {
    for (final e in ipToInterface.entries)
      if (e.value != null) e.key: e.value!,
  },
  initialized: true,
);

void main() {
  group('phone (Android interface names)', () {
    test('Wi-Fi + mobile data + Tailscale all on: only the Wi-Fi subnet is scanned', () {
      final network = _net({
        '192.168.1.23': 'wlan0',
        '10.73.20.5': 'rmnet_data1',
        '100.70.8.9': 'rmnet_data0',
        '100.101.102.103': 'tun0',
      });
      expect(subnetScanIps(network), ['192.168.1.23']);
    });

    test('mobile data only: nothing is scanned (devices in the carrier subnet belong to strangers)', () {
      expect(subnetScanIps(_net({'10.73.20.5': 'rmnet_data1', '100.70.8.9': 'rmnet_data0'})), isEmpty);
      expect(subnetScanIps(_net({'10.20.30.40': 'ccmni0'})), isEmpty, reason: 'mobile data interface on MediaTek phones');
    });

    test('mobile data + Tailscale (away from home): no Tailscale subnet scan either (paired devices are reached at stored addresses)', () {
      expect(subnetScanIps(_net({'10.73.20.5': 'rmnet_data1', '100.101.102.103': 'tun0'})), isEmpty);
    });

    test('proxy app running (fake address on the VPN interface): its subnet is not scanned', () {
      expect(subnetScanIps(_net({'192.168.1.23': 'wlan0', '172.19.0.1': 'tun0'})), ['192.168.1.23']);
    });

    test('phone hotspot, USB tethering, Wi-Fi itself on 100.64.x: all LANs, all scanned', () {
      final network = _net({'192.168.43.1': 'wlan2', '192.168.42.129': 'rndis0', '100.64.10.20': 'wlan0'});
      expect(subnetScanIps(network), ['192.168.43.1', '192.168.42.129', '100.64.10.20']);
    });
  });

  group('computer (Windows network connection names)', () {
    test('Wi-Fi + Tailscale + WSL virtual adapter + unplugged Ethernet port: only the Wi-Fi subnet is scanned', () {
      final network = _net({
        '192.168.1.50': 'Wi-Fi',
        '172.17.208.1': 'vEthernet (WSL (Hyper-V firewall))',
        '169.254.12.3': 'Ethernet 2',
        '100.88.1.2': 'Tailscale',
      });
      expect(subnetScanIps(network), ['192.168.1.50']);
    });

    test('VMware, VirtualBox, Hyper-V Default Switch skipped; Ethernet (Chinese-locale name) and an active mobile hotspot scanned', () {
      final network = _net({
        '192.168.1.50': '以太网',
        '192.168.56.1': 'VirtualBox Host-Only Network',
        '192.168.80.1': 'VMware Network Adapter VMnet8',
        '172.30.48.1': 'vEthernet (Default Switch)',
        '192.168.137.1': 'Local Area Connection* 10',
      });
      expect(subnetScanIps(network), ['192.168.1.50', '192.168.137.1']);
    });
  });

  group('interface name unavailable', () {
    test('a regular LAN address is scanned (it can only be the one reported by the system Wi-Fi API)', () {
      expect(subnetScanIps(_net({'192.168.1.23': null})), ['192.168.1.23']);
    });

    test('addresses in 100.64.0.0/10 are skipped: Tailscale, carrier-grade NAT and Wi-Fi cannot be told apart', () {
      expect(subnetScanIps(_net({'100.70.8.9': null, '192.168.1.23': null})), ['192.168.1.23']);
    });
  });

  test('duplicate addresses are scanned once, order preserved', () {
    const network = NetworkState(
      localIps: ['192.168.1.2', '10.73.20.5', '192.168.1.2', '10.0.0.2'],
      interfaceNames: {'192.168.1.2': 'wlan0', '10.73.20.5': 'rmnet_data1', '10.0.0.2': 'eth0'},
      initialized: true,
    );
    expect(subnetScanIps(network), ['192.168.1.2', '10.0.0.2']);
  });
}
