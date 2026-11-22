//! shareMe: which connections the server serves, judged by the local address
//! they arrived at. Only connections over the local network (Wi-Fi, Ethernet,
//! hotspot, USB tethering) or Tailscale are served.
//!
//! The listeners are bound to the wildcard addresses, so they also answer on
//! the mobile data interface: its public IPv6 address may be reachable from the
//! internet, its IPv4 address from within the carrier network. Binding only the
//! addresses of the local network instead would mean rebinding on every network
//! change, while this check always sees the current interfaces.
//!
//! Interfaces are recognized by name with the same rules as the app
//! (`app/lib/util/shareme_net_interface.dart`, after WebRTC's
//! `GetAdapterTypeFromName` and Tailscale's `isTailscaleInterface`). Both sides
//! test against `tests/fixtures/interface_kinds.json`.

use std::fmt;
use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// What kind of network an interface connects to, judged by its name: the
/// kernel's name on Android (`wlan0`, `rmnet_data0`, `tun0`), the connection's
/// name on Windows (`Wi-Fi`, `Ethernet 2`, `Tailscale`).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum InterfaceKind {
    /// Mobile data. Other devices on it are strangers in the carrier network.
    Cellular,

    /// A VPN tunnel. On Android every VPN app's interface is a `tun`,
    /// Tailscale's included.
    Vpn,

    /// Tailscale's own interface (`Tailscale` on Windows, `tailscale0` on Linux).
    Tailscale,

    /// A network inside this computer (WSL, Hyper-V's default switch,
    /// VMware / VirtualBox host-only), only reachable from its virtual machines.
    HostOnly,

    /// Wi-Fi, Ethernet, hotspot, USB tethering, and every name not recognized.
    Other,
}

/// Name prefixes (compared case-insensitively) of mobile data interfaces:
/// Qualcomm `rmnet*` (`r_rmnet` / `rev_rmnet` carry Wi-Fi calling), MediaTek
/// `ccmni*`, the 464XLAT interfaces `v4-rmnet*` / `v4-ccmni*` / `clat*`, and
/// the default names of a mobile broadband connection on Windows.
const CELLULAR_PREFIXES: [&str; 9] = [
    "rmnet",
    "r_rmnet",
    "rev_rmnet",
    "v4-rmnet",
    "ccmni",
    "v4-ccmni",
    "clat",
    "cellular",
    "手机网络",
];

/// VPN interfaces: one of these prefixes followed by nothing but digits
/// (`tun0`, `utun3`), like WebRTC.
const VPN_PREFIXES: [&str; 4] = ["tun", "utun", "tap", "ipsec"];

/// Name prefixes (compared case-insensitively) of the default networks inside
/// a Windows computer. An external Hyper-V switch (`vEthernet (<any name>)`)
/// carries the real local network and is not one of them.
const HOST_ONLY_PREFIXES: [&str; 4] = [
    "vethernet (wsl",
    "vethernet (default switch",
    "vmware network adapter",
    "virtualbox host-only",
];

pub(crate) fn interface_kind(name: &str) -> InterfaceKind {
    let lower = name.to_lowercase();
    let starts_with_any = |prefixes: &[&str]| prefixes.iter().any(|prefix| lower.starts_with(prefix));

    if lower.starts_with("tailscale") {
        InterfaceKind::Tailscale
    } else if starts_with_any(&CELLULAR_PREFIXES) {
        InterfaceKind::Cellular
    } else if is_vpn_name(name) {
        InterfaceKind::Vpn
    } else if starts_with_any(&HOST_ONLY_PREFIXES) {
        InterfaceKind::HostOnly
    } else {
        InterfaceKind::Other
    }
}

fn is_vpn_name(name: &str) -> bool {
    VPN_PREFIXES.iter().any(|prefix| {
        name.strip_prefix(prefix)
            .is_some_and(|rest| rest.bytes().all(|byte| byte.is_ascii_digit()))
    })
}

/// Whether `ip` is one of Tailscale's addresses: 100.64.0.0/10 without
/// ChromeOS's 100.115.92.0/23 (Tailscale's `IsTailscaleIPv4`), or
/// fd7a:115c:a1e0::/48. Carrier-grade NAT uses the same IPv4 range, so only
/// the interface can tell the two apart.
pub(crate) fn in_tailscale_range(ip: IpAddr) -> bool {
    match ip.to_canonical() {
        IpAddr::V4(ip) => {
            let [a, b, c, _] = ip.octets();
            a == 100 && (64..=127).contains(&b) && !(b == 115 && (c == 92 || c == 93))
        }
        IpAddr::V6(ip) => ip.segments()[..3] == [0xfd7a, 0x115c, 0xa1e0],
    }
}

/// The address that 464XLAT gives IPv4 on an IPv6-only mobile network (192.0.0.0/29).
fn is_xlat_address(ip: Ipv4Addr) -> bool {
    let [a, b, c, d] = ip.octets();
    a == 192 && b == 0 && c == 0 && d < 8
}

/// Why a connection is not served.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum Refusal {
    /// It arrived at a public IPv6 address, which anyone on the internet may
    /// reach. Shuttle itself only uses IPv4, link-local and Tailscale addresses.
    PublicIpv6,

    /// It arrived at the address of 464XLAT, which only mobile data uses.
    XlatAddress,

    /// It arrived over mobile data (the name of the interface).
    Cellular(String),

    /// It arrived over a VPN at an address outside Tailscale's ranges, e.g.
    /// the fake network of a proxy app (the name of the interface).
    OtherVpn(String),
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Refusal::PublicIpv6 => write!(f, "it is a public IPv6 address"),
            Refusal::XlatAddress => write!(f, "it is the 464XLAT address of mobile data"),
            Refusal::Cellular(name) => write!(f, "it is on the mobile data interface {name}"),
            Refusal::OtherVpn(name) => {
                write!(f, "it is on the VPN interface {name}, outside Tailscale")
            }
        }
    }
}

/// Decides whether a connection that arrived at the local address `ip` is
/// served. `interfaces` are the names of the interfaces that have the address:
/// several when they share it, none when it is not known.
pub(crate) fn decide(ip: IpAddr, interfaces: &[String]) -> Result<(), Refusal> {
    let ip = ip.to_canonical();
    decide_by_address(ip).unwrap_or_else(|| decide_by_interfaces(ip, interfaces))
}

/// The verdict that the address alone gives, `None` when it depends on the interface.
fn decide_by_address(ip: IpAddr) -> Option<Result<(), Refusal>> {
    if ip.is_loopback() {
        return Some(Ok(()));
    }
    match ip {
        IpAddr::V4(ip) => is_xlat_address(ip).then_some(Err(Refusal::XlatAddress)),
        // Neither can be reached from the internet: link-local addresses are
        // what LocalSend's IPv6 discovery answers to, Tailscale's IPv6 range
        // is one of the unique local ones.
        IpAddr::V6(ip) if ip.is_unicast_link_local() || ip.is_unique_local() => None,
        IpAddr::V6(_) => Some(Err(Refusal::PublicIpv6)),
    }
}

/// The verdict for an address that the address rules leave to its interfaces.
/// When an interface shares the address with another one, the stricter wins.
fn decide_by_interfaces(ip: IpAddr, interfaces: &[String]) -> Result<(), Refusal> {
    for name in interfaces {
        match interface_kind(name) {
            InterfaceKind::Cellular => return Err(Refusal::Cellular(name.clone())),
            InterfaceKind::Vpn if !in_tailscale_range(ip) => {
                return Err(Refusal::OtherVpn(name.clone()))
            }
            InterfaceKind::Vpn
            | InterfaceKind::Tailscale
            | InterfaceKind::HostOnly
            | InterfaceKind::Other => {}
        }
    }
    // An address that no interface is known to have (the enumeration failed,
    // or the network has just changed) is served as before: the address rules
    // keep out the internet regardless.
    Ok(())
}

/// An address of a local interface.
#[derive(Clone, Debug)]
pub(crate) struct InterfaceAddress {
    pub(crate) name: String,
    pub(crate) ip: IpAddr,

    /// The index of the interface, which is the scope of its link-local addresses.
    pub(crate) index: Option<u32>,
}

fn system_interfaces() -> io::Result<Vec<InterfaceAddress>> {
    Ok(if_addrs::get_if_addrs()?
        .into_iter()
        .map(|interface| InterfaceAddress {
            ip: interface.ip(),
            index: interface.index,
            name: interface.name,
        })
        .collect())
}

/// The name of the interface with the index `index`, asked from the system.
///
/// Android does not list IPv6 link-local addresses to apps (an app's
/// `getifaddrs` only returned the IPv4 addresses and `::1`, measured on
/// Android 12), but tells the name of an interface index.
#[cfg(unix)]
fn system_interface_name(index: u32) -> Option<String> {
    let mut name = [0 as libc::c_char; libc::IF_NAMESIZE];
    // SAFETY: the buffer has the IF_NAMESIZE bytes that if_indextoname needs.
    let result = unsafe { libc::if_indextoname(index, name.as_mut_ptr()) };
    if result.is_null() {
        return None;
    }
    // SAFETY: on success, if_indextoname wrote a NUL-terminated name into the buffer.
    let name = unsafe { std::ffi::CStr::from_ptr(name.as_ptr()) };
    Some(name.to_string_lossy().into_owned())
}

/// Windows lists link-local addresses with their interface index, so the
/// enumeration answers by itself.
#[cfg(not(unix))]
fn system_interface_name(_index: u32) -> Option<String> {
    None
}

/// The scope of a local address: the index of the interface that a link-local
/// address belongs to, and so the one the connection arrived on.
fn scope_of(local: SocketAddr) -> Option<u32> {
    match local {
        SocketAddr::V6(local) if local.scope_id() != 0 => Some(local.scope_id()),
        _ => None,
    }
}

/// The names of the interfaces that have the local address `local`.
fn interfaces_with(interfaces: &[InterfaceAddress], local: SocketAddr) -> Vec<String> {
    let ip = local.ip().to_canonical();
    // The same link-local address can be on several interfaces; the scope of
    // the connection tells which one it arrived on.
    let scope = scope_of(local);
    let names = |in_scope_only: bool| -> Vec<String> {
        interfaces
            .iter()
            .filter(|interface| interface.ip.to_canonical() == ip)
            .filter(|interface| !in_scope_only || interface.index == scope)
            .map(|interface| interface.name.clone())
            .collect()
    };

    match scope.map(|_| names(true)) {
        Some(in_scope) if !in_scope.is_empty() => in_scope,
        _ => names(false),
    }
}

/// How long enumerated interfaces are used. Enumerating is a system call (a
/// few milliseconds on Windows), not repeated for each of the connections that
/// a transfer or a browser opens at once.
const SNAPSHOT_MAX_AGE: Duration = Duration::from_secs(2);

/// An address that the enumeration does not know (e.g. of a network that has
/// just come up) enumerates again, but not more often than this.
const SNAPSHOT_MIN_AGE_FOR_UNKNOWN: Duration = Duration::from_millis(200);

/// Whether interfaces enumerated `age` ago must be enumerated again, given
/// whether they had the address being looked up.
fn needs_enumeration(age: Duration, address_known: bool) -> bool {
    age >= SNAPSHOT_MAX_AGE || (!address_known && age >= SNAPSHOT_MIN_AGE_FOR_UNKNOWN)
}

type Enumerate = dyn Fn() -> io::Result<Vec<InterfaceAddress>> + Send + Sync;
type NameOfIndex = dyn Fn(u32) -> Option<String> + Send + Sync;

/// Decides about incoming connections with [decide], looking up the interfaces
/// of their local addresses.
pub(crate) struct LocalNetworkGuard {
    enumerate: Arc<Enumerate>,

    /// The name of an interface by its index, [system_interface_name] outside tests.
    name_of_index: Box<NameOfIndex>,

    /// The last enumeration and when it was taken.
    snapshot: Mutex<Option<(Instant, Arc<[InterfaceAddress]>)>>,

    /// Whether a failed enumeration has been reported already.
    enumeration_failure_reported: AtomicBool,
}

impl LocalNetworkGuard {
    pub(crate) fn new() -> Self {
        Self::with_sources(system_interfaces, system_interface_name)
    }

    pub(crate) fn with_sources(
        enumerate: impl Fn() -> io::Result<Vec<InterfaceAddress>> + Send + Sync + 'static,
        name_of_index: impl Fn(u32) -> Option<String> + Send + Sync + 'static,
    ) -> Self {
        Self {
            enumerate: Arc::new(enumerate),
            name_of_index: Box::new(name_of_index),
            snapshot: Mutex::new(None),
            enumeration_failure_reported: AtomicBool::new(false),
        }
    }

    /// Decides whether a connection that arrived at the local address `local` is served.
    pub(crate) async fn check(&self, local: SocketAddr) -> Result<(), Refusal> {
        let ip = local.ip().to_canonical();
        match decide_by_address(ip) {
            Some(verdict) => verdict,
            None => decide_by_interfaces(ip, &self.interfaces_with(local).await),
        }
    }

    async fn interfaces_with(&self, local: SocketAddr) -> Vec<String> {
        // A link-local address names its interface by its scope.
        if let Some(name) = scope_of(local).and_then(|scope| (self.name_of_index)(scope)) {
            return vec![name];
        }

        let snapshot = self.snapshot.lock().unwrap().clone();
        if let Some((taken_at, interfaces)) = snapshot {
            let names = interfaces_with(&interfaces, local);
            if !needs_enumeration(taken_at.elapsed(), !names.is_empty()) {
                return names;
            }
        }

        let interfaces: Arc<[InterfaceAddress]> = self.enumerate().await.into();
        *self.snapshot.lock().unwrap() = Some((Instant::now(), interfaces.clone()));
        interfaces_with(&interfaces, local)
    }

    async fn enumerate(&self) -> Vec<InterfaceAddress> {
        let enumerate = self.enumerate.clone();
        match tokio::task::spawn_blocking(move || enumerate()).await {
            Ok(Ok(interfaces)) => interfaces,
            Ok(Err(err)) => {
                if !self.enumeration_failure_reported.swap(true, Ordering::Relaxed) {
                    tracing::warn!(
                        "Cannot enumerate the network interfaces, judging connections by their address only: {err:#}"
                    );
                }
                Vec::new()
            }
            // The runtime is shutting down, and the connection with it.
            Err(err) => {
                tracing::debug!("Enumerating the network interfaces failed: {err:#}");
                Vec::new()
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap()
    }

    fn names(names: &[&str]) -> Vec<String> {
        names.iter().map(|name| name.to_string()).collect()
    }

    /// Shared with the app's tests, so that both classify the same way.
    fn fixture() -> serde_json::Value {
        serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/interface_kinds.json"
        )))
        .unwrap()
    }

    #[test]
    fn interfaces_are_recognized_like_the_app_does() {
        let fixture = fixture();
        let kinds = fixture["kinds"].as_object().unwrap();
        assert_eq!(kinds.len(), 5);
        for (kind, names) in kinds {
            let expected = match kind.as_str() {
                "cellular" => InterfaceKind::Cellular,
                "vpn" => InterfaceKind::Vpn,
                "tailscale" => InterfaceKind::Tailscale,
                "hostOnly" => InterfaceKind::HostOnly,
                "other" => InterfaceKind::Other,
                kind => panic!("unknown kind {kind}"),
            };
            for name in names.as_array().unwrap() {
                let name = name.as_str().unwrap();
                assert_eq!(interface_kind(name), expected, "{name}");
            }
        }
    }

    #[test]
    fn tailscale_ranges_are_the_apps() {
        let fixture = fixture();
        for (key, expected) in [("in", true), ("out", false)] {
            for address in fixture["tailscaleIpv4"][key].as_array().unwrap() {
                let address = address.as_str().unwrap();
                assert_eq!(in_tailscale_range(ip(address)), expected, "{address}");
            }
        }
        assert!(in_tailscale_range(ip("fd7a:115c:a1e0::1")));
        assert!(in_tailscale_range(ip("fd7a:115c:a1e0:ab12:4843:cd96:625e:2f0b")));
        assert!(in_tailscale_range(ip("::ffff:100.101.102.103")));
        assert!(!in_tailscale_range(ip("fd7a:115c:a1e1::1")));
        assert!(!in_tailscale_range(ip("fd00::1")));
    }

    #[test]
    fn local_network_and_loopback_are_served() {
        for (address, interface) in [
            ("127.0.0.1", vec![]),
            ("::1", vec![]),
            ("192.168.1.23", names(&["wlan0"])),
            ("10.0.0.5", names(&["eth0"])),
            ("192.168.43.1", names(&["wlan1"])),
            ("192.168.42.129", names(&["rndis0"])),
            ("192.168.1.23", names(&["Wi-Fi"])),
            ("192.168.137.1", names(&["Local Area Connection* 10"])),
            ("172.17.208.1", names(&["vEthernet (WSL (Hyper-V firewall))"])),
            // An address on a public network is still the local network.
            ("18.21.0.7", names(&["Ethernet"])),
            ("fe80::1", names(&["wlan0"])),
            ("fd12:3456:789a::1", names(&["wlan0"])),
        ] {
            assert_eq!(decide(ip(address), &interface), Ok(()), "{address} {interface:?}");
        }
    }

    #[test]
    fn tailscale_is_served() {
        for (address, interface) in [
            // Android: Tailscale is a VPN app.
            ("100.101.102.103", "tun0"),
            ("fd7a:115c:a1e0::1", "tun0"),
            ("100.64.0.1", "Tailscale"),
            ("fd7a:115c:a1e0:ab12::1", "Tailscale"),
            ("100.101.102.103", "tailscale0"),
        ] {
            assert_eq!(decide(ip(address), &names(&[interface])), Ok(()), "{address} {interface}");
        }
    }

    #[test]
    fn mobile_data_is_refused() {
        for (address, interface) in [
            ("10.73.20.5", "rmnet_data1"),
            // Carrier-grade NAT shares Tailscale's range.
            ("100.80.1.2", "rmnet_data0"),
            ("10.20.30.40", "ccmni0"),
            ("10.20.30.40", "Cellular"),
            ("10.20.30.40", "手机网络"),
            ("fe80::1", "rmnet_data0"),
            ("fd00::1", "rmnet_data0"),
        ] {
            assert_eq!(
                decide(ip(address), &names(&[interface])),
                Err(Refusal::Cellular(interface.to_string())),
                "{address} {interface}"
            );
        }
        assert_eq!(
            decide(ip("::ffff:10.73.20.5"), &names(&["rmnet_data1"])),
            Err(Refusal::Cellular("rmnet_data1".to_string()))
        );
        // 464XLAT, whatever the interface is called.
        for interface in [names(&["v4-rmnet_data0"]), names(&["seth_lte0"]), vec![]] {
            assert_eq!(
                decide(ip("192.0.0.4"), &interface),
                Err(Refusal::XlatAddress)
            );
        }
    }

    #[test]
    fn public_ipv6_addresses_are_refused_on_every_interface() {
        for interface in [
            names(&["rmnet_data0"]),
            names(&["wlan0"]),
            names(&["Wi-Fi"]),
            names(&["Tailscale"]),
            // Not known which interface has the address.
            vec![],
        ] {
            for address in ["2409:8a1e:6c34:1d20::1", "2a00:1450:4001:82a::200e", "2001:db8::1"] {
                assert_eq!(
                    decide(ip(address), &interface),
                    Err(Refusal::PublicIpv6),
                    "{address} {interface:?}"
                );
            }
        }
    }

    #[test]
    fn other_vpns_are_refused() {
        for (address, interface) in [
            ("172.19.0.1", "tun0"),
            ("198.18.0.1", "tun0"),
            ("10.8.0.2", "tun1"),
            // ChromeOS's part of the range is not Tailscale's.
            ("100.115.92.5", "tun0"),
            ("fd00::1", "tun0"),
            ("fe80::1", "tun0"),
        ] {
            assert_eq!(
                decide(ip(address), &names(&[interface])),
                Err(Refusal::OtherVpn(interface.to_string())),
                "{address} {interface}"
            );
        }
    }

    #[test]
    fn an_address_shared_with_mobile_data_is_refused() {
        assert_eq!(
            decide(ip("10.0.0.5"), &names(&["wlan0", "rmnet_data0"])),
            Err(Refusal::Cellular("rmnet_data0".to_string()))
        );
    }

    #[test]
    fn an_address_of_no_known_interface_is_judged_by_the_address_alone() {
        assert_eq!(decide(ip("10.0.0.5"), &[]), Ok(()));
        assert_eq!(decide(ip("fe80::1"), &[]), Ok(()));
        assert_eq!(decide(ip("2001:db8::1"), &[]), Err(Refusal::PublicIpv6));
    }

    fn interface(name: &str, address: &str, index: u32) -> InterfaceAddress {
        InterfaceAddress {
            name: name.to_string(),
            ip: ip(address),
            index: Some(index),
        }
    }

    #[test]
    fn the_scope_tells_which_interface_a_link_local_address_is_on() {
        let interfaces = [
            interface("wlan0", "fe80::1", 3),
            interface("rmnet_data0", "fe80::1", 9),
            interface("wlan0", "192.168.1.23", 3),
        ];
        let local = |s: &str| -> SocketAddr { s.parse().unwrap() };

        assert_eq!(interfaces_with(&interfaces, local("[fe80::1%3]:53317")), names(&["wlan0"]));
        assert_eq!(
            interfaces_with(&interfaces, local("[fe80::1%9]:53317")),
            names(&["rmnet_data0"])
        );
        // Without a usable scope, every interface with the address counts.
        for address in ["[fe80::1]:53317", "[fe80::1%7]:53317"] {
            assert_eq!(
                interfaces_with(&interfaces, local(address)),
                names(&["wlan0", "rmnet_data0"])
            );
        }
        assert_eq!(
            interfaces_with(&interfaces, local("192.168.1.23:53317")),
            names(&["wlan0"])
        );
        assert_eq!(
            interfaces_with(&interfaces, local("[::ffff:192.168.1.23]:53317")),
            names(&["wlan0"])
        );
        assert!(interfaces_with(&interfaces, local("10.0.0.1:53317")).is_empty());
    }

    #[test]
    fn interfaces_are_enumerated_again_when_old_or_missing_the_address() {
        assert!(!needs_enumeration(Duration::ZERO, true));
        assert!(!needs_enumeration(Duration::from_millis(1999), true));
        assert!(needs_enumeration(Duration::from_secs(2), true));
        assert!(!needs_enumeration(Duration::from_millis(199), false));
        assert!(needs_enumeration(Duration::from_millis(200), false));
    }

    /// A guard whose interfaces are `interfaces` and whose interface indexes
    /// have the names `indexes`, counting the enumerations.
    fn counting_guard(
        interfaces: Vec<InterfaceAddress>,
        indexes: &[(u32, &str)],
    ) -> (LocalNetworkGuard, Arc<AtomicUsize>) {
        let count = Arc::new(AtomicUsize::new(0));
        let indexes: Vec<(u32, String)> = indexes
            .iter()
            .map(|(index, name)| (*index, name.to_string()))
            .collect();
        let guard = LocalNetworkGuard::with_sources(
            {
                let count = count.clone();
                move || {
                    count.fetch_add(1, Ordering::SeqCst);
                    Ok(interfaces.clone())
                }
            },
            move |index| {
                indexes
                    .iter()
                    .find(|(known, _)| *known == index)
                    .map(|(_, name)| name.clone())
            },
        );
        (guard, count)
    }

    /// Makes the last enumeration of `guard` older by `age`.
    fn age_snapshot(guard: &LocalNetworkGuard, age: Duration) {
        let mut snapshot = guard.snapshot.lock().unwrap();
        let (taken_at, _) = snapshot.as_mut().unwrap();
        *taken_at = taken_at.checked_sub(age).unwrap();
    }

    #[tokio::test]
    async fn enumerations_are_reused() {
        let (guard, count) = counting_guard(
            vec![
                interface("wlan0", "192.168.1.23", 3),
                interface("rmnet_data1", "10.73.20.5", 9),
            ],
            &[],
        );
        let wifi: SocketAddr = "192.168.1.23:53317".parse().unwrap();
        let mobile: SocketAddr = "10.73.20.5:53317".parse().unwrap();
        let unknown: SocketAddr = "10.0.0.5:53317".parse().unwrap();

        assert_eq!(guard.check(wifi).await, Ok(()));
        assert_eq!(
            guard.check(mobile).await,
            Err(Refusal::Cellular("rmnet_data1".to_string()))
        );
        assert_eq!(count.load(Ordering::SeqCst), 1);

        // The address rules need no interfaces.
        assert_eq!(guard.check("127.0.0.1:53317".parse().unwrap()).await, Ok(()));
        assert_eq!(
            guard.check("[2001:db8::1]:53317".parse().unwrap()).await,
            Err(Refusal::PublicIpv6)
        );
        assert_eq!(count.load(Ordering::SeqCst), 1);

        // An unknown address enumerates again, but not right after an enumeration.
        assert_eq!(guard.check(unknown).await, Ok(()));
        assert_eq!(count.load(Ordering::SeqCst), 1);
        age_snapshot(&guard, SNAPSHOT_MIN_AGE_FOR_UNKNOWN);
        assert_eq!(guard.check(unknown).await, Ok(()));
        assert_eq!(count.load(Ordering::SeqCst), 2);

        // Known addresses use the enumeration until it is too old.
        age_snapshot(&guard, SNAPSHOT_MIN_AGE_FOR_UNKNOWN);
        assert_eq!(guard.check(wifi).await, Ok(()));
        assert_eq!(count.load(Ordering::SeqCst), 2);
        age_snapshot(&guard, SNAPSHOT_MAX_AGE);
        assert_eq!(guard.check(wifi).await, Ok(()));
        assert_eq!(count.load(Ordering::SeqCst), 3);
    }

    #[tokio::test]
    async fn link_local_addresses_are_judged_by_the_interface_of_their_scope() {
        // What an app sees on Android 12 (a Xiaomi phone): no IPv6 link-local
        // addresses in the enumeration, but names for interface indexes.
        let (guard, count) = counting_guard(
            vec![
                interface("wlan0", "192.168.0.11", 11),
                interface("rmnet_data1", "10.73.145.176", 26),
            ],
            &[(11, "wlan0"), (25, "rmnet_data0")],
        );
        assert_eq!(
            guard.check("[fe80::5cb8:4b4b:841c:324b%25]:53317".parse().unwrap()).await,
            Err(Refusal::Cellular("rmnet_data0".to_string()))
        );
        assert_eq!(
            guard.check("[fe80::8cf5:baff:fe68:6b9%11]:53317".parse().unwrap()).await,
            Ok(())
        );
        assert_eq!(count.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn without_names_for_indexes_the_enumeration_tells_the_interface() {
        // Windows: link-local addresses are enumerated with their index.
        let (guard, _) = counting_guard(
            vec![
                interface("Wi-Fi", "fe80::1", 3),
                interface("Cellular", "fe80::1", 9),
            ],
            &[],
        );
        assert_eq!(guard.check("[fe80::1%3]:53317".parse().unwrap()).await, Ok(()));
        assert_eq!(
            guard.check("[fe80::1%9]:53317".parse().unwrap()).await,
            Err(Refusal::Cellular("Cellular".to_string()))
        );
    }

    #[tokio::test]
    async fn without_interfaces_only_the_address_rules_apply() {
        let guard = LocalNetworkGuard::with_sources(
            || Err(io::Error::other("no netlink")),
            |_| None,
        );
        assert_eq!(guard.check("10.73.20.5:53317".parse().unwrap()).await, Ok(()));
        assert_eq!(
            guard.check("[2409:8a1e:6c34:1d20::1]:53317".parse().unwrap()).await,
            Err(Refusal::PublicIpv6)
        );
        assert_eq!(
            guard.check("192.0.0.4:53317".parse().unwrap()).await,
            Err(Refusal::XlatAddress)
        );
    }
}
