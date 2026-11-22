// Shuttle: classifies the kind of network interface a local address is on (Wi-Fi / mobile data / VPN / Tailscale / host-only).
// Used for the addresses reported to the peer when pairing (pairAddresses) and for the subnets scanned for nearby devices (subnetScanIps).
// Interface names come from dart:io's NetworkInterface.list() and are stored in NetworkState.interfaceNames.
// The name lists follow WebRTC's GetAdapterTypeFromName (rtc_base/network.cc) and Tailscale's isTailscaleInterface
// (net/netmon/state.go) and IsTailscaleIPv4 (net/tsaddr/tsaddr.go).
// The receiving server (Rust, packages/core/src/http/server/local_network.rs) uses the same lists to decide whether to accept a
// connection: change both together; the tests on both sides share packages/core/tests/fixtures/interface_kinds.json.

/// Rough interface category, based only on the system's interface name: the kernel interface name on Android (wlan0, rmnet_data0,
/// tun0, ...), the name shown in "Network Connections" on Windows (Wi-Fi, Ethernet, Tailscale, ...).
enum NetInterfaceKind {
  /// Mobile data (cellular): a carrier-internal address that other devices can't reach; the same subnet holds other customers' devices
  cellular,

  /// A VPN's virtual interface (on Android every VPN app's interface is named tun0, tun1, ..., Tailscale's included)
  vpn,

  /// Tailscale's own interface (named Tailscale on Windows, tailscale0 on Linux)
  tailscale,

  /// A virtual network inside the PC (WSL, Hyper-V Default Switch, VMware / VirtualBox host-only networks) that other devices can't reach
  hostOnly,

  /// Everything else: Wi-Fi, wired, mobile hotspot, USB tethering, and unrecognized names
  other,
}

/// Cellular interface name prefixes: Qualcomm rmnet* (rmnet_data0, ...; VoLTE uses these too; r_rmnet / rev_rmnet are the reverse
/// channel for Wi-Fi calling), MediaTek ccmni*, the 464XLAT interfaces v4-rmnet* / v4-ccmni* / clat*, and the default name of the
/// Windows cellular connection (English / Chinese; untested, as no PC with a 4G modem was available)
final _cellularName = RegExp(r'^(rmnet|r_rmnet|rev_rmnet|v4-rmnet|ccmni|v4-ccmni|clat|cellular|手机网络)', caseSensitive: false);

/// VPN interface names: tun0, utun3, tap0, ipsec0 (as in WebRTC, only digits may follow the prefix)
final _vpnName = RegExp(r'^(tun|utun|tap|ipsec)\d*$');

/// Default connection names of host-only virtual networks. External switches (`vEthernet (custom name)`) carry the real LAN and
/// are not included.
final _hostOnlyName = RegExp(r'^(vEthernet \((WSL|Default Switch)|VMware Network Adapter|VirtualBox Host-Only)', caseSensitive: false);

NetInterfaceKind netInterfaceKindOf(String name) {
  if (name.toLowerCase().startsWith('tailscale')) return NetInterfaceKind.tailscale;
  if (_cellularName.hasMatch(name)) return NetInterfaceKind.cellular;
  if (_vpnName.hasMatch(name)) return NetInterfaceKind.vpn;
  if (_hostOnlyName.hasMatch(name)) return NetInterfaceKind.hostOnly;
  return NetInterfaceKind.other;
}

final _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');

/// The four octets of an IPv4 address; null if it isn't IPv4
List<int>? _octets(String ip) {
  if (!_ipv4.hasMatch(ip)) return null;
  final p = ip.split('.').map(int.parse).toList();
  return p.every((o) => o <= 255) ? p : null;
}

/// An IPv4 address other devices can use. Excluded: 0.x, loopback 127.x, link-local 169.254.x (what disconnected adapters and a
/// disconnected Tailscale get on Windows) and 464XLAT's 192.0.0.0/29; these only mean something on this host or this link.
/// IPv6 isn't used for now and doesn't count either.
bool isUsableIpv4(String ip) {
  final p = _octets(ip);
  if (p == null) return false;
  return !(p[0] == 0 || p[0] == 127 || (p[0] == 169 && p[1] == 254) || (p[0] == 192 && p[1] == 0 && p[2] == 0 && p[3] < 8));
}

/// Within 100.64.0.0/10 (used by Tailscale, and also by carrier-grade NAT)
bool inCgnatRange(String ip) {
  final p = _octets(ip);
  return p != null && p[0] == 100 && p[1] >= 64 && p[1] <= 127;
}

/// Tailscale's own address check (IsTailscaleIPv4): 100.64.0.0/10 minus 100.115.92.0/23, which ChromeOS uses for VMs.
/// The range alone can't tell Tailscale from carrier-grade NAT; it must be checked together with the interface.
bool inTailscaleRange(String ip) {
  if (!inCgnatRange(ip)) return false;
  final p = _octets(ip)!;
  return !(p[1] == 115 && (p[2] == 92 || p[2] == 93));
}
