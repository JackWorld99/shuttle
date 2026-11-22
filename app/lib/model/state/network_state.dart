import 'package:dart_mappable/dart_mappable.dart';

part 'network_state.mapper.dart';

@MappableClass()
class NetworkState with NetworkStateMappable {
  final List<String> localIps;

  /// Shuttle: the network interface of each local IPv4 address (address → interface name). On Android these are kernel interface
  /// names (wlan0, rmnet_data0, tun0); on Windows, the names shown in Network Connections (Wi-Fi, Tailscale). Pairing uses this
  /// to drop addresses the peer can't reach, such as the mobile-data interface (pairAddresses).
  /// Addresses that come only from the system Wi-Fi API and are missing from the interface list are not included.
  final Map<String, String> interfaceNames;
  final bool initialized;

  const NetworkState({
    required this.localIps,
    this.interfaceNames = const {},
    required this.initialized,
  });
}
