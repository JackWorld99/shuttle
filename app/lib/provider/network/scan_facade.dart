import 'dart:async';

import 'package:localsend_app/model/state/network_state.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/paired_devices_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/shareme_net_interface.dart';
import 'package:localsend_app/util/shareme_pairing/pair_crypto.dart' show isTailscaleIp;
import 'package:localsend_isolates/model/device.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';

final _logger = Logger('ScanFacade');

/// Shuttle: the local addresses whose subnet gets probed "door to door" when no device was found within 1 second (all 254
/// addresses of the subnet). Each probe uses a connection without certificate pinning and sends this device's name, model and
/// certificate fingerprint to whatever answers at that address, so only real LANs are probed (Wi-Fi, Ethernet, phone hotspot,
/// USB tethering). Never probed:
/// - mobile data: the subnet holds other people's devices on the carrier network; yours are never there;
/// - VPN and Tailscale: Tailscale addresses are assigned at random, so the subnet holds practically none of your devices (paired
///   devices are still found directly at their stored addresses); a proxy app's VPN interface might also route these requests out;
/// - virtual networks inside the PC (WSL, Hyper-V, VMware, VirtualBox), and addresses such as 169.254 that only mean something
///   locally.
/// An address with an unknown interface (only ever the one from the system Wi-Fi API) is still probed, unless it falls within
/// 100.64.0.0/10: that can't be told apart from carrier-grade NAT.
List<String> subnetScanIps(NetworkState network) {
  return [
    for (final ip in network.localIps.toSet())
      if (isUsableIpv4(ip) && _isLanInterface(ip, network.interfaceNames[ip])) ip,
  ];
}

bool _isLanInterface(String ip, String? interfaceName) {
  if (interfaceName == null || interfaceName.isEmpty) return !inCgnatRange(ip);
  return netInterfaceKindOf(interfaceName) == NetInterfaceKind.other;
}

/// Logs which addresses' subnets were skipped (for checking on the phone)
void _logSkipped(NetworkState network, List<String> scanned) {
  final skipped = [
    for (final ip in network.localIps.toSet())
      if (!scanned.contains(ip)) network.interfaceNames[ip] == null ? ip : '$ip (${network.interfaceNames[ip]})',
  ];
  if (skipped.isNotEmpty) _logger.info('Subnet scan skips (not a LAN): ${skipped.join(', ')}');
}

/// Discovers devices in stages, cheapest first: multicast announcement and
/// favorite probes right away, http-based discovery on the subnets only when
/// nothing was confirmed within 1 second.
class StartSmartScan extends AsyncGlobalAction {
  /// Maximum number of interfaces to scan.
  /// If there are more interfaces, the first ones will be used or the user needs to select one.
  static const maxInterfaces = 3;

  @override
  Future<void> reduce() async {
    final favorites = ref.read(favoritesProvider);
    // Shuttle: for paired devices, also try the addresses they reported when pairing (e.g. a Tailscale 100.x), so they are found
    // even when not on the same Wi-Fi
    final paired = ref.read(pairedDevicesProvider);
    final extra = [
      for (final f in favorites)
        for (final r in paired)
          if (r.fingerprint == f.fingerprint)
            for (final a in r.addresses)
              if (a != f.ip) f.copyWith(ip: a),
    ];
    final settings = ref.read(settingsProvider);
    // Shuttle: only scan real LANs, never mobile-data, VPN or Tailscale subnets (subnetScanIps)
    final network = ref.read(localIpProvider);
    final lanIps = subnetScanIps(network);
    _logSkipped(network, lanIps);
    final networkInterfaces = lanIps.take(maxInterfaces).toList();

    await ref
        .redux(nearbyDevicesProvider)
        .dispatchAsync(
          StartStagedScan(
            favorites: [...favorites, ...extra],
            interfaces: networkInterfaces,
            port: settings.port,
            https: settings.https,
            grace: const Duration(seconds: 1),
          ),
        );
  }
}

/// Shuttle: whether to scan again for a direct LAN connection: this device is on a LAN ([lanIps] not empty) and one of
/// "my devices" ([trusted]) is currently connected only via Tailscale. See [RescanForLanAction].
bool onlyViaTailscaleOnLan({required Iterable<Device> nearby, required Set<String> trusted, required List<String> lanIps}) {
  return lanIps.isNotEmpty && nearby.any((d) => trusted.contains(d.fingerprint) && isTailscaleIp(d.ip));
}

/// Shuttle: called when the app returns to the foreground. If one of "my devices" is connected only via Tailscale while this
/// device is on a LAN, scan again (at most once a minute) without clearing the list: the Tailscale entry stays usable until the
/// device is found on the LAN, which then replaces it automatically (`pickDeviceAddress`).
/// Why: for roughly the first minute after the phone joins a Wi-Fi network, its own connections to a PC on the LAN often fail
/// (observed: for about a minute after reconnecting, curl on the phone couldn't reach the PC's port 53317 while the PC could reach
/// the phone; it recovered afterwards). The two scans at 2 s and 10 s after a network change both fall into that window and only
/// find the PC via Tailscale; with no later scan the list kept showing "via Tailscale" and sends took the slow path. Scanning
/// again on resume usually finds it right away at the remembered LAN address.
class RescanForLanAction extends AsyncGlobalAction {
  static const minInterval = Duration(minutes: 1);
  static DateTime? _last;

  @override
  Future<void> reduce() async {
    final now = DateTime.now();
    final last = _last;
    if (last != null && now.difference(last) < minInterval) return;
    final trusted = ref.read(favoritesProvider).map((f) => f.fingerprint).toSet();
    final nearby = ref.read(nearbyDevicesProvider).devices.values;
    if (!onlyViaTailscaleOnLan(nearby: nearby, trusted: trusted, lanIps: subnetScanIps(ref.read(localIpProvider)))) return;
    _last = now;
    _logger.info('Rescan for a LAN path: a paired device is only reachable over Tailscale');
    await dispatchAsync(StartSmartScan());
  }
}

/// HTTP based discovery on a fixed set of subnets.
class StartLegacySubnetScan extends AsyncGlobalAction {
  final List<String> subnets;

  StartLegacySubnetScan({
    required this.subnets,
  });

  @override
  Future<void> reduce() async {
    final settings = ref.read(settingsProvider);
    final port = settings.port;
    final https = settings.https;

    // send announcement in parallel
    ref.redux(nearbyDevicesProvider).dispatch(StartMulticastScan());

    // Shuttle: manually chosen subnets are also limited to real LANs (subnetScanIps). Shuttle's UI currently has no entry point
    // for this; the check is there in case one is added later.
    final lanIps = subnetScanIps(ref.read(localIpProvider));
    final refused = subnets.where((s) => !lanIps.contains(s)).toList();
    if (refused.isNotEmpty) _logger.info('Subnet scan refused (not a LAN): ${refused.join(', ')}');

    await Future.wait<void>([
      for (final subnet in subnets)
        if (lanIps.contains(subnet)) ref.redux(nearbyDevicesProvider).dispatchAsync(StartLegacyScan(port: port, localIp: subnet, https: https)),
    ]);
  }
}
