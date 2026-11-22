mod store;

pub use store::{
    ChannelStatus, DeviceChannel, DeviceLog, DeviceLogKind, DiscoveredDevice, HttpChannel,
    StatefulDevice,
};

use crate::http::client::{ClientError, LsHttpClientV2};
use crate::http::dto_v2::{RegisterDtoV2, RegisterResponseDtoV2};
use crate::model::discovery::{MulticastMessageV2, ProtocolType};
use crate::multicast::{self, MulticastConfig, MulticastDevice, MulticastEvent, MulticastHandle};
use crate::util::error::ErrorChain;
use crate::util::interface::InterfaceFilter;
use futures_util::StreamExt;
use std::collections::HashSet;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime};
use store::DeviceStore;
use tokio::sync::{mpsc, oneshot};

/// The default timeout of the register requests sent by discovery, matching
/// the Flutter app's default discovery timeout. Discovery only talks to LAN
/// peers, which answer quickly or not at all.
pub const DEFAULT_DISCOVERY_TIMEOUT: Duration = Duration::from_millis(500);

/// shareMe: timeout of register requests to known channels in the CGNAT range
/// `100.64.0.0/10`, which Tailscale hands out. The first request to such a peer
/// often has to set up the tunnel before TLS can start (a WireGuard handshake;
/// over mobile data 50–180 ms per round trip), which regularly exceeds
/// [`DEFAULT_DISCOVERY_TIMEOUT`]. The next attempt then succeeds, so the peer
/// only showed up after a manual refresh (measured 2026-11-13). Subnet scans
/// keep the short timeout; they never reach these addresses.
pub const OVERLAY_DISCOVERY_TIMEOUT: Duration = Duration::from_secs(3);

/// Whether `host` is an overlay address: an IPv4 address in `100.64.0.0/10`,
/// the range Tailscale (and other overlay networks) assign, or an IPv6
/// address in Tailscale's `fd7a:115c:a1e0::/48`.
fn is_overlay_host(host: &str) -> bool {
    match host.parse::<IpAddr>() {
        Ok(IpAddr::V4(ip)) => ip.octets()[0] == 100 && ip.octets()[1] & 0xC0 == 64,
        Ok(IpAddr::V6(ip)) => ip.segments()[..3] == [0xfd7a, 0x115c, 0xa1e0],
        Err(_) => false,
    }
}

/// shareMe: whether a confirmation over `device`'s channel shows that the
/// local network itself works, i.e. it did not come over an overlay
/// (Tailscale) address.
fn is_local_confirmation(device: &DiscoveredDevice) -> bool {
    match &device.channel {
        DeviceChannel::Http(http) => !is_overlay_host(&http.host),
    }
}

/// Capacity of the internal multicast event channel.
const MULTICAST_CHANNEL_SIZE: usize = 64;

/// How many hosts a subnet scan probes at once, matching the Flutter app's
/// legacy HTTP discovery.
const SCAN_CONCURRENCY: usize = 50;

/// This device's TLS identity, sent as client certificate with every register
/// request (client certificates are mandatory in HTTPS mode).
///
/// Its fingerprint is the one carried in [`MulticastDevice::fingerprint`].
#[derive(Clone)]
pub struct DeviceIdentity {
    /// PEM-encoded certificate.
    pub cert_pem: String,

    /// PEM-encoded private key.
    pub private_key_pem: String,
}

/// Configuration of the discovery.
pub struct DiscoveryConfig {
    /// The multicast group to join, usually [`multicast::DEFAULT_MULTICAST_GROUP`].
    pub group: Ipv4Addr,

    /// The IPv6 multicast group to additionally join, usually
    /// [`multicast::DEFAULT_MULTICAST_GROUP_V6`]. `None` disables IPv6 discovery.
    pub group_v6: Option<Ipv6Addr>,

    /// The multicast port to bind, usually [`multicast::DEFAULT_PORT`].
    pub port: u16,

    /// Restricts the network interfaces that are used.
    pub interface_filter: InterfaceFilter,

    /// The device information announced to the network and sent in register
    /// requests.
    pub device: MulticastDevice,

    /// The TLS identity used for the register requests.
    pub identity: DeviceIdentity,

    /// Timeout of each register request sent by discovery, usually
    /// [`DEFAULT_DISCOVERY_TIMEOUT`]. Bounds how long an unresponsive host
    /// stalls a subnet scan, so keep it short.
    pub timeout: Duration,

    /// Channel on which discovery events are emitted. `None` when the
    /// application only polls [`DiscoveryHandle::devices`].
    pub event_tx: Option<mpsc::Sender<DiscoveryEvent>>,
}

/// An event emitted by the discovery. Every confirmation is also logged in
/// [`StatefulDevice::logs`]; the accumulated state is read from
/// [`DiscoveryHandle::devices`].
#[derive(Clone, Debug)]
pub enum DiscoveryEvent {
    /// A device was confirmed over one of its channels for the first time
    /// in this run.
    Discovered {
        /// The device as it was confirmed, i.e. carrying only the channel
        /// the confirmation happened on.
        device: DiscoveredDevice,
    },

    /// An already known device was confirmed again: it re-announced itself
    /// or was re-discovered, at a known or a new address.
    Updated {
        /// The device as it was confirmed, like in
        /// [`DiscoveryEvent::Discovered`].
        device: DiscoveredDevice,
    },

    /// The multicast sockets failed permanently, e.g. because the OS
    /// invalidated them while the application was suspended (iOS reclaims the
    /// sockets of suspended apps). Announcements are no longer heard or sent;
    /// the application should restart discovery to rebind the sockets.
    /// HTTP-based discovery (probes and subnet scans) keeps working.
    MulticastFailed,
}

struct DiscoveryState {
    device: MulticastDevice,
    identity: DeviceIdentity,
    timeout: Duration,
    store: DeviceStore,
    event_tx: Option<mpsc::Sender<DiscoveryEvent>>,

    /// Whether announcements of other devices are answered, see
    /// [`DiscoveryHandle::set_answer_announcements`].
    answering: AtomicBool,

    /// The interface addresses a subnet scan is currently running for.
    scanning: std::sync::Mutex<HashSet<Ipv4Addr>>,

    /// Number of confirmations in this run over local (non-overlay) channels,
    /// on which [`DiscoveryHandle::discover_staged`] decides whether to
    /// escalate. shareMe: confirmations over Tailscale do not count, see
    /// [`is_local_confirmation`].
    local_confirmations: AtomicU64,
}

impl DiscoveryState {
    fn register_dto(&self) -> RegisterDtoV2 {
        RegisterDtoV2 {
            alias: self.device.alias.clone(),
            version: self.device.version.clone(),
            device_model: self.device.device_model.clone(),
            device_type: self.device.device_type.clone(),
            fingerprint: self.device.fingerprint.clone(),
            port: self.device.port,
            protocol: self.device.protocol,
            download: self.device.download,
        }
    }

    /// A client accepting any valid certificate, for peers whose fingerprint
    /// is not known before they answer. The fingerprint is then read off the
    /// handshake and pinned by connections that transfer data.
    fn unpinned_client(&self) -> Result<LsHttpClientV2, ClientError> {
        self.unpinned_client_with(self.timeout)
    }

    fn unpinned_client_with(&self, timeout: Duration) -> Result<LsHttpClientV2, ClientError> {
        LsHttpClientV2::try_new(
            &self.identity.private_key_pem,
            &self.identity.cert_pem,
            None,
            Some(timeout),
        )
    }

    /// shareMe: the timeout for probing a known channel at an overlay address,
    /// see [`OVERLAY_DISCOVERY_TIMEOUT`]. Never shorter than the configured one.
    fn overlay_timeout(&self) -> Duration {
        self.timeout.max(OVERLAY_DISCOVERY_TIMEOUT)
    }

    /// Registers with `host:port` and, when a device answers, puts it into
    /// the store. Returns the device's stored state after the merge, or
    /// `None` when the answer carried this device's own fingerprint.
    async fn probe(
        &self,
        client: &LsHttpClientV2,
        host: &str,
        port: u16,
        protocol: ProtocolType,
    ) -> Result<Option<StatefulDevice>, ClientError> {
        let response = client
            .register(protocol, host, port, self.register_dto())
            .await?;

        // In HTTPS mode the certificate is the peer's identity; the
        // fingerprint claimed in the body only counts without encryption.
        let fingerprint = match protocol {
            ProtocolType::Https => response
                .cert_fingerprint
                .clone()
                .ok_or_else(|| anyhow::anyhow!("HTTPS response carried no peer certificate"))?,
            ProtocolType::Http => response.body.fingerprint.clone(),
        };
        if fingerprint == self.device.fingerprint {
            return Ok(None);
        }

        let device = confirmed_device(response.body, host.to_string(), port, protocol, fingerprint);
        let (_, merged) = self.found(device).await;
        Ok(Some(merged))
    }

    /// Puts a device into the store, logging the confirmation on it, and
    /// emits the resulting event. Returns whether the device is new, and
    /// its stored state after the merge.
    async fn found(&self, device: DiscoveredDevice) -> (bool, StatefulDevice) {
        if is_local_confirmation(&device) {
            self.local_confirmations.fetch_add(1, Ordering::Relaxed);
        }
        let (event, merged) = self.store.upsert(device, SystemTime::now());
        let is_new = matches!(event, DiscoveryEvent::Discovered { .. });
        if let Some(event_tx) = &self.event_tx {
            // Never wait for the application here. A subnet scan confirms up to
            // 255 devices in a burst, far more than the channel holds, and
            // every confirmation runs inside the scan's own concurrency limit:
            // blocking on a full channel would stall the scan for good and
            // leave its `ScanGuard` held, so the interface could never be
            // scanned again.
            //
            // Dropping an event only costs a refresh. The device is in the
            // store before the event is emitted, so it is still returned by
            // the scan and by `devices()`.
            if let Err(err) = event_tx.try_send(event) {
                tracing::debug!("Dropped a discovery event: {err}");
            }
        }
        (is_new, merged)
    }
}

/// A handle to a running discovery: the store of discovered devices and the
/// application-initiated operations.
pub struct DiscoveryHandle {
    /// The multicast side, or the reason it could not be started; discovery
    /// keeps working without it, see [`DiscoveryHandle::multicast_error`].
    multicast: Result<MulticastHandle, anyhow::Error>,
    state: Arc<DiscoveryState>,
}

impl DiscoveryHandle {
    /// Announces this device to the network, which makes every other LocalSend
    /// device on it register with this device over HTTP.
    ///
    /// Devices registering in response arrive at the application as server
    /// events, not here: discovery only learns about peers that announce
    /// themselves. Feed them back via [`DiscoveryHandle::add_device`].
    ///
    /// Returns once the whole announcement burst has been sent, which takes a
    /// few seconds, or immediately once discovery has been stopped or
    /// multicast is unavailable.
    pub async fn announce(&self) {
        if let Ok(multicast) = &self.multicast {
            multicast.announce().await;
        }
    }

    /// The reason the multicast sockets could not be bound (e.g. the port is
    /// taken, or there is no usable network interface), when they could not.
    ///
    /// Discovery then neither hears nor sends announcements; it still learns
    /// about devices through [`DiscoveryHandle::discover`],
    /// [`DiscoveryHandle::scan_subnet`] and [`DiscoveryHandle::add_device`].
    pub fn multicast_error(&self) -> Option<&anyhow::Error> {
        self.multicast.as_ref().err()
    }

    /// Discovers a device at a known address, e.g. a favorite or a peer that
    /// multicast does not reach, by sending it a register request.
    ///
    /// On success the device is put into the store (and emitted, as
    /// `Discovered` or `Updated`), and its full stored state — all known
    /// channels and logs — is returned.
    /// Returns `None` when the address answered with this device's own
    /// fingerprint, i.e. the device discovered itself.
    pub async fn discover(
        &self,
        host: &str,
        port: u16,
        protocol: ProtocolType,
    ) -> Result<Option<StatefulDevice>, ClientError> {
        let client = if is_overlay_host(host) {
            self.state.unpinned_client_with(self.state.overlay_timeout())?
        } else {
            self.state.unpinned_client()?
        };
        self.state.probe(&client, host, port, protocol).await
    }

    /// Discovers devices at known addresses, e.g. the favorites, by sending
    /// each channel a register request: [`DiscoveryHandle::discover`] for a
    /// whole list, probed concurrently.
    ///
    /// Channels that do not answer are skipped; returns the stored state of
    /// the devices that answered, in completion order.
    pub async fn discover_known_http_channels(
        &self,
        channels: Vec<HttpChannel>,
    ) -> Result<Vec<StatefulDevice>, ClientError> {
        let client = self.state.unpinned_client()?;
        // shareMe: overlay (Tailscale) channels wait longer, see OVERLAY_DISCOVERY_TIMEOUT
        let overlay_client = if channels.iter().any(|c| is_overlay_host(&c.host)) {
            Some(self.state.unpinned_client_with(self.state.overlay_timeout())?)
        } else {
            None
        };

        let state = &self.state;
        let client = &client;
        let overlay_client = overlay_client.as_ref();
        let found = futures_util::stream::iter(channels)
            .map(|channel| async move {
                let client = match overlay_client {
                    Some(overlay) if is_overlay_host(&channel.host) => overlay,
                    _ => client,
                };
                state
                    .probe(client, &channel.host, channel.port, channel.protocol)
                    .await
                    .ok()
                    .flatten()
            })
            .buffer_unordered(SCAN_CONCURRENCY)
            .filter_map(std::future::ready)
            .collect()
            .await;

        Ok(found)
    }

    /// Discovers devices in stages, cheapest first: announces this device to
    /// the network and probes `known_channels` (e.g. the favorites), then
    /// falls back to scanning the `/24` subnets of the local interface
    /// addresses `interface_ips`, for networks that do not carry multicast.
    ///
    /// The fallback only runs when nothing was confirmed over the local
    /// network until `grace` after the known channels have been probed: any
    /// such confirmation — a new device or a known one — proves that the cheap
    /// stages work on this network.
    ///
    /// shareMe: a confirmation over an overlay (Tailscale) address proves
    /// nothing about the local network, so it does not stop the fallback. A
    /// paired device that changed networks since pairing is first found over
    /// Tailscale only (its stored LAN address is stale); skipping the scan
    /// then kept two devices on the same Wi-Fi talking over Tailscale, at a
    /// fraction of the LAN speed (measured 2026-11-14).
    ///
    /// The found devices are put into the store (and emitted) as they answer;
    /// returns once every stage has finished, including the whole
    /// announcement burst.
    pub async fn discover_staged(
        &self,
        known_channels: Vec<HttpChannel>,
        interface_ips: Vec<Ipv4Addr>,
        port: u16,
        protocol: ProtocolType,
        grace: Duration,
    ) -> Result<(), ClientError> {
        let confirmations = self.state.local_confirmations.load(Ordering::Relaxed);
        let escalate = async {
            self.discover_known_http_channels(known_channels).await?;
            tokio::time::sleep(grace).await;

            if self.state.local_confirmations.load(Ordering::Relaxed) == confirmations {
                futures_util::future::try_join_all(
                    interface_ips
                        .into_iter()
                        .map(|ip| self.scan_subnet(ip, port, protocol)),
                )
                .await?;
            }
            Ok(())
        };

        let (_, escalated) = tokio::join!(self.announce(), escalate);
        escalated
    }

    /// Scans the `/24` subnet of the local interface address `interface_ip`
    /// by sending every other host a register request,
    /// for networks that do not carry multicast.
    ///
    /// At most one scan runs per interface: a call for an address that is
    /// still being scanned returns an empty list immediately.
    pub async fn scan_subnet(
        &self,
        interface_ip: Ipv4Addr,
        port: u16,
        protocol: ProtocolType,
    ) -> Result<Vec<StatefulDevice>, ClientError> {
        if !self.state.scanning.lock().unwrap().insert(interface_ip) {
            return Ok(Vec::new());
        }
        let _guard = ScanGuard {
            state: &self.state,
            interface_ip,
        };

        let client = self.state.unpinned_client()?;
        let base = interface_ip.octets();

        let state = &self.state;
        let client = &client;
        let found = futures_util::stream::iter(
            (0..=255u8)
                .map(|host| Ipv4Addr::new(base[0], base[1], base[2], host))
                .filter(|ip| *ip != interface_ip),
        )
        .map(|ip| async move {
            state
                .probe(client, &ip.to_string(), port, protocol)
                .await
                .ok()
                .flatten()
        })
        .buffer_unordered(SCAN_CONCURRENCY)
        .filter_map(std::future::ready)
        .collect()
        .await;

        Ok(found)
    }

    /// Sets whether announcements of other devices are answered with a
    /// register request (the answer is what makes the announcing device
    /// enter the store). On by default.
    ///
    /// An application whose server is not running turns this off: the answer
    /// would advertise an HTTP port that nobody listens on.
    pub fn set_answer_announcements(&self, answer: bool) {
        self.state.answering.store(answer, Ordering::Relaxed);
    }

    /// Puts a device confirmed outside of discovery into the store, e.g. one
    /// that answered an announcement by registering with this device's HTTP
    /// server. The confirmation is emitted as `Discovered` or `Updated`;
    /// returns `true` when the device is new.
    pub async fn add_device(&self, device: DiscoveredDevice) -> bool {
        self.state.found(device).await.0
    }

    /// All discovered devices in discovery order.
    pub fn devices(&self) -> Vec<StatefulDevice> {
        self.state.store.devices()
    }

    pub fn device_by_fingerprint(&self, fingerprint: &str) -> Option<StatefulDevice> {
        self.state.store.by_fingerprint(fingerprint)
    }

    /// Waits until discovery has terminated and the multicast sockets have
    /// been closed, so that the port can be bound again.
    /// Must be called after requesting a stop via the stop channel.
    /// Returns immediately when multicast is unavailable.
    pub async fn wait_stopped(&self) {
        if let Ok(multicast) = &self.multicast {
            multicast.wait_stopped().await;
        }
    }
}

/// Releases the interface of a finished subnet scan, also when the scan is
/// cancelled by dropping its future.
struct ScanGuard<'a> {
    state: &'a DiscoveryState,
    interface_ip: Ipv4Addr,
}

impl Drop for ScanGuard<'_> {
    fn drop(&mut self) {
        self.state
            .scanning
            .lock()
            .unwrap()
            .remove(&self.interface_ip);
    }
}

/// Binds the multicast sockets and starts answering announcements of other
/// devices. Nothing is announced until [`DiscoveryHandle::announce`] is called.
///
/// Starting cannot fail: when no multicast socket could be bound, e.g. because
/// the port is already bound by another process or because there is no network
/// at all, discovery runs without multicast.
pub async fn start(config: DiscoveryConfig, stop_rx: oneshot::Receiver<()>) -> DiscoveryHandle {
    let (multicast_tx, mut multicast_rx) = mpsc::channel(MULTICAST_CHANNEL_SIZE);

    // On failure `multicast_tx` is dropped, which ends the answering task.
    let multicast = multicast::start(
        MulticastConfig {
            group: config.group,
            group_v6: config.group_v6,
            port: config.port,
            interface_filter: config.interface_filter,
            device: config.device.clone(),
            event_tx: multicast_tx,
        },
        stop_rx,
    )
    .await;

    let state = Arc::new(DiscoveryState {
        device: config.device,
        identity: config.identity,
        timeout: config.timeout,
        store: DeviceStore::new(),
        event_tx: config.event_tx,
        answering: AtomicBool::new(true),
        scanning: std::sync::Mutex::new(HashSet::new()),
        local_confirmations: AtomicU64::new(0),
    });

    // Ends once discovery is stopped: the multicast side then drops its
    // sender and the channel closes.
    tokio::spawn({
        let state = state.clone();
        async move {
            while let Some(event) = multicast_rx.recv().await {
                match event {
                    MulticastEvent::Discovered {
                        ip,
                        scope_id,
                        message,
                    } => {
                        if !state.answering.load(Ordering::Relaxed) {
                            continue;
                        }

                        // The register request may take a while (up to the timeout),
                        // so announcements are answered concurrently.
                        tokio::spawn(answer_announcement(state.clone(), ip, scope_id, message));
                    }
                    MulticastEvent::SocketsFailed => {
                        if let Some(event_tx) = &state.event_tx {
                            let _ = event_tx.try_send(DiscoveryEvent::MulticastFailed);
                        }
                    }
                }
            }
        }
    });

    DiscoveryHandle { multicast, state }
}

/// Answers an announcement with a register request, as the protocol requires.
/// The device enters the store only once that request succeeded, so that
/// everything in the store is known to be reachable.
async fn answer_announcement(
    state: Arc<DiscoveryState>,
    ip: IpAddr,
    scope_id: Option<u32>,
    message: MulticastMessageV2,
) {
    let host = match scope_id {
        Some(scope_id) => format!("{ip}%{scope_id}"),
        None => ip.to_string(),
    };

    // Pin the claimed fingerprint, so nothing is sent to a device that does
    // not hold the matching certificate.
    let expected_fingerprint = match message.protocol {
        ProtocolType::Https => Some(message.fingerprint.clone()),
        ProtocolType::Http => None,
    };
    let client = match LsHttpClientV2::try_new(
        &state.identity.private_key_pem,
        &state.identity.cert_pem,
        expected_fingerprint,
        Some(state.timeout),
    ) {
        Ok(client) => client,
        Err(err) => {
            tracing::error!(
                "Could not create the client to answer {host}: {}",
                ErrorChain(&err)
            );
            return;
        }
    };

    let result = client
        .register(message.protocol, &host, message.port, state.register_dto())
        .await;

    match result {
        Ok(response) => {
            // The pinned certificate identifies the peer, so the fingerprint
            // is taken from the announcement, not from the response body.
            let device = confirmed_device(
                response.body,
                host,
                message.port,
                message.protocol,
                message.fingerprint,
            );
            state.found(device).await;
        }
        Err(err) => {
            let url = format!("{}://{host}:{}", message.protocol.as_str(), message.port);
            tracing::debug!(
                "Could not register with announcing device {} ({url}): {}",
                message.alias,
                ErrorChain(&err),
            );
        }
    }
}

/// Builds the stored device from the register response of a peer confirmed
/// over HTTP.
fn confirmed_device(
    response: RegisterResponseDtoV2,
    host: String,
    port: u16,
    protocol: ProtocolType,
    fingerprint: String,
) -> DiscoveredDevice {
    DiscoveredDevice {
        alias: response.alias,
        version: response.version,
        device_model: response.device_model,
        device_type: response.device_type,
        fingerprint,
        channel: DeviceChannel::Http(HttpChannel {
            host,
            port,
            protocol,
        }),
        download: response.download,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn overlay_hosts_are_the_cgnat_range() {
        assert!(is_overlay_host("100.64.0.1"));
        assert!(is_overlay_host("100.90.10.20"));
        assert!(is_overlay_host("100.110.20.30"));
        assert!(is_overlay_host("100.127.255.254"));

        assert!(!is_overlay_host("100.63.255.255"));
        assert!(!is_overlay_host("100.128.0.1"));
        assert!(!is_overlay_host("192.168.9.130"));
        assert!(!is_overlay_host("10.73.96.188"));
        assert!(!is_overlay_host("example.local"));
    }

    #[test]
    fn overlay_hosts_include_tailscale_ipv6() {
        assert!(is_overlay_host("fd7a:115c:a1e0::3236:670b"));
        assert!(is_overlay_host("fd7a:115c:a1e0::1c36:b568"));

        assert!(!is_overlay_host("fd7a:115c:a1e1::1"));
        assert!(!is_overlay_host("fd00::1"));
        assert!(!is_overlay_host("fe80::1%11"));
        assert!(!is_overlay_host("2401:3c00::1"));
    }

    fn device_at(host: &str) -> DiscoveredDevice {
        DiscoveredDevice {
            alias: "Peer".to_string(),
            version: "2.1".to_string(),
            device_model: None,
            device_type: None,
            fingerprint: "peer".to_string(),
            channel: DeviceChannel::Http(HttpChannel {
                host: host.to_string(),
                port: 53317,
                protocol: ProtocolType::Https,
            }),
            download: false,
        }
    }

    #[test]
    fn only_lan_confirmations_count_as_local() {
        assert!(is_local_confirmation(&device_at("192.168.0.10")));
        assert!(is_local_confirmation(&device_at("10.0.0.5")));
        assert!(is_local_confirmation(&device_at("fe80::1%11")));

        assert!(!is_local_confirmation(&device_at("100.110.20.30")));
        assert!(!is_local_confirmation(&device_at("fd7a:115c:a1e0::1c36:b568")));
    }

    #[test]
    fn overlay_timeout_is_longer_than_the_lan_one() {
        assert!(OVERLAY_DISCOVERY_TIMEOUT > DEFAULT_DISCOVERY_TIMEOUT);
    }
}
