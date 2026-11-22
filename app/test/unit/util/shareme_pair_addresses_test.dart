import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/state/network_state.dart';
import 'package:localsend_app/util/shareme_pairing/pair_crypto.dart';

// Shuttle: when pairing, only tell the peer addresses it can actually reach (it stores them in the pairing record and tries
// them later when not on the same Wi-Fi). Found in practice and in a security review: the phone's record held its VoLTE
// mobile address (10.73.x), which is never reachable; a carrier-grade NAT mobile address can also be in 100.64.0.0/10 and,
// judged by range alone, used to be stored as Tailscale, so other people's devices got probed later. Now the interface decides.
// Tests for the interface classification itself are in shareme_net_interface_test.dart.

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
    test('Wi-Fi + Tailscale + mobile data all on: only Wi-Fi and Tailscale are reported, neither the data nor the VoLTE address', () {
      final network = _net({
        '192.168.1.23': 'wlan0',
        '10.73.20.5': 'rmnet_data1',
        '100.70.8.9': 'rmnet_data0',
        '100.101.102.103': 'tun0',
      });
      expect(pairAddresses(network), ['192.168.1.23', '100.101.102.103']);
    });

    test('mobile data only (no Wi-Fi, no Tailscale): nothing is reported', () {
      expect(pairAddresses(_net({'10.73.20.5': 'rmnet_data1', '100.70.8.9': 'rmnet_data0'})), isEmpty);
    });

    test('mobile data + Tailscale (away from home): only Tailscale is reported', () {
      expect(pairAddresses(_net({'10.73.20.5': 'rmnet_data2', '100.101.102.103': 'tun0'})), ['100.101.102.103']);
    });

    test('mobile data interface with a 100.64.x address (carrier-grade NAT): not taken for Tailscale, not reported', () {
      expect(pairAddresses(_net({'100.70.8.9': 'rmnet_data0'})), isEmpty);
      expect(pairAddresses(_net({'100.80.1.2': 'ccmni0'})), isEmpty, reason: 'mobile data interface on MediaTek phones');
      expect(pairAddresses(_net({'192.0.0.4': 'v4-rmnet_data0'})), isEmpty, reason: 'translated address on an IPv6-only mobile network');
    });

    test('Wi-Fi itself hands out 100.64.x (some routers and hotel networks do): reported as a LAN address, ahead of Tailscale', () {
      expect(pairAddresses(_net({'100.101.102.103': 'tun0', '100.64.10.20': 'wlan0'})), ['100.64.10.20', '100.101.102.103']);
    });

    test('another VPN running (a proxy app tun interface with a fake address): not reported', () {
      expect(pairAddresses(_net({'192.168.1.23': 'wlan0', '172.19.0.1': 'tun0'})), ['192.168.1.23']);
      expect(pairAddresses(_net({'100.115.92.5': 'tun0'})), isEmpty, reason: 'the small block ChromeOS uses for VMs, never assigned by Tailscale');
    });

    test('phone hotspot and USB tethering are LANs: reported', () {
      final network = _net({'192.168.43.1': 'wlan2', '192.168.42.129': 'rndis0', '10.73.20.5': 'rmnet_data1'});
      expect(pairAddresses(network), ['192.168.43.1', '192.168.42.129']);
    });
  });

  group('computer (Windows network connection names)', () {
    test('Wi-Fi + Tailscale + WSL virtual adapter + unplugged Ethernet port: only Wi-Fi and Tailscale are reported', () {
      final network = _net({
        '192.168.1.50': 'Wi-Fi',
        '172.17.208.1': 'vEthernet (WSL (Hyper-V firewall))',
        '169.254.12.3': 'Ethernet 2',
        '100.88.1.2': 'Tailscale',
      });
      expect(pairAddresses(network), ['192.168.1.50', '100.88.1.2']);
    });

    test('internal networks of VMware, VirtualBox and Hyper-V Default Switch are not reported; an active mobile hotspot is', () {
      final network = _net({
        '192.168.1.50': '以太网',
        '192.168.56.1': 'VirtualBox Host-Only Network',
        '192.168.80.1': 'VMware Network Adapter VMnet8',
        '172.30.48.1': 'vEthernet (Default Switch)',
        '192.168.137.1': 'Local Area Connection* 10',
      });
      expect(pairAddresses(network), ['192.168.1.50', '192.168.137.1']);
    });

    test('Tailscale not connected (only 169.254 on its interface): not reported', () {
      expect(pairAddresses(_net({'192.168.1.50': 'Wi-Fi', '169.254.83.107': 'Tailscale'})), ['192.168.1.50']);
    });
  });

  group('limits and fallback', () {
    test('at most 3 LAN and 2 Tailscale addresses, duplicates counted once', () {
      const network = NetworkState(
        localIps: ['192.168.1.2', '192.168.1.2', '10.0.0.2', '10.0.1.2', '10.0.2.2', '100.64.0.1', '100.64.0.2', '100.64.0.3'],
        interfaceNames: {
          '192.168.1.2': 'wlan0',
          '10.0.0.2': 'eth0',
          '10.0.1.2': 'eth1',
          '10.0.2.2': 'eth2',
          '100.64.0.1': 'tun0',
          '100.64.0.2': 'tun1',
          '100.64.0.3': 'tun2',
        },
        initialized: true,
      );
      expect(pairAddresses(network), ['192.168.1.2', '10.0.0.2', '10.0.1.2', '100.64.0.1', '100.64.0.2']);
    });

    test('unknown interface: judged by address range as before (keeps Tailscale addresses); known mobile data interfaces still skipped', () {
      final network = _net({'192.168.1.23': null, '10.73.20.5': 'rmnet_data1', '100.101.102.103': null});
      expect(pairAddresses(network), ['192.168.1.23', '100.101.102.103']);
    });
  });
}
