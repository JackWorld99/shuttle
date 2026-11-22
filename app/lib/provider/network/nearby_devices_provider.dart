import 'dart:async';

import 'package:collection/collection.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/state/nearby_devices_state.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_app/provider/paired_devices_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/shareme_pairing/pair_crypto.dart' show isTailscaleIp;
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// This provider is responsible for:
/// - Scanning the network for other LocalSend instances
/// - Keeping track of all found devices (they are only stored in RAM)
///
/// Use [scanProvider] to have a high-level API to perform discovery operations.
final nearbyDevicesProvider = ReduxProvider<NearbyDevicesService, NearbyDevicesState>((ref) {
  return NearbyDevicesService(
    isolateController: ref.notifier(parentIsolateProvider),
    favoriteService: ref.notifier(favoritesProvider),
    discoveryLogs: ref.notifier(discoveryLoggerProvider),
    settingsService: ref.notifier(settingsProvider),
    pairedDevices: ref.notifier(pairedDevicesProvider),
  );
});

class NearbyDevicesService extends ReduxNotifier<NearbyDevicesState> {
  final IsolateController _isolateController;
  final FavoritesService _favoriteService;
  final DiscoveryLogger _discoveryLogger;
  final SettingsService _settingsService;
  final PairedDevicesService _pairedDevices;

  NearbyDevicesService({
    required IsolateController isolateController,
    required FavoritesService favoriteService,
    required DiscoveryLogger discoveryLogs,
    required SettingsService settingsService,
    required PairedDevicesService pairedDevices,
  }) : _discoveryLogger = discoveryLogs,
       _isolateController = isolateController,
       _favoriteService = favoriteService,
       _settingsService = settingsService,
       _pairedDevices = pairedDevices;

  @override
  NearbyDevicesState init() => const NearbyDevicesState(
    runningFavoriteScan: false,
    runningIps: {},
    devices: {},
    signalingDevices: {},
  );
}

/// Starts the discovery (which binds the UDP port) and registers every
/// confirmed device: answered announcements, scan results and devices fed in
/// via [IsolateDiscoveryAddDeviceAction] all arrive on this one stream.
/// This should run forever as long as the app is running.
class StartDiscoveryListener extends AsyncReduxAction<NearbyDevicesService, NearbyDevicesState> {
  @override
  Future<NearbyDevicesState> reduce() async {
    final stream = external(notifier._isolateController).dispatchTakeResult(IsolateDiscoveryListenAction());
    await for (final device in stream) {
      await dispatchAsync(RegisterDeviceAction(device));
      notifier._discoveryLogger.addLog('[DISCOVER] ${device.alias} (${device.ip}, model: ${device.deviceModel})');
    }
    return state;
  }
}

/// Removes all found devices from the state.
class ClearFoundDevicesAction extends ReduxAction<NearbyDevicesService, NearbyDevicesState> {
  @override
  NearbyDevicesState reduce() {
    return state.copyWith(
      devices: {},
    );
  }
}

/// Shuttle: the device didn't answer either attempt of a periodic presence check, so remove it from the list and show it as
/// "offline" (see shareme_presence.dart). If it was confirmed again after the check started ([since]), e.g. it just re-announced
/// or registered itself, it is still around and stays. When it comes back it re-enters the list through normal discovery (its
/// startup announcement, its own registration, or the next presence check).
class RemoveUnreachableDeviceAction extends ReduxAction<NearbyDevicesService, NearbyDevicesState> {
  final String fingerprint;
  final DateTime since;

  RemoveUnreachableDeviceAction({required this.fingerprint, required this.since});

  @override
  NearbyDevicesState reduce() {
    if (!state.devices.containsKey(fingerprint)) return state;
    final last = _lastConfirmed[fingerprint];
    if (last != null && last.isAfter(since)) return state;
    notifier._discoveryLogger.addLog('[OFFLINE] ${state.devices[fingerprint]!.alias} (${state.devices[fingerprint]!.ip}) did not answer');
    return state.copyWith(devices: {...state.devices}..remove(fingerprint));
  }
}

/// Shuttle: when each address (fingerprint@IP) was last confirmed; kept in memory only.
/// Used to tell whether a device's LAN address is still "fresh", see [RegisterDeviceAction].
final _confirmedAt = <String, DateTime>{};

/// Shuttle: when each device (by fingerprint) was last confirmed, on any address. [RemoveUnreachableDeviceAction] uses it to
/// tell whether the device was confirmed elsewhere after a failed check (e.g. it just re-announced).
final _lastConfirmed = <String, DateTime>{};

/// Shuttle: a periodic presence check got an answer on the address the device currently uses in the list: only record the time
/// (so the LAN address stays "fresh" and isn't swapped for Tailscale), without touching the list, the settings or the discovery
/// log (this happens as often as every 20 seconds, see shareme_presence.dart).
void markDeviceSeen(String fingerprint, String ip) {
  final now = DateTime.now();
  _confirmedAt['$fingerprint@$ip'] = now;
  _lastConfirmed[fingerprint] = now;
}

/// Within one scan the LAN and Tailscale confirmations usually arrive within seconds of each other; a LAN address not confirmed
/// again within this time is no longer preferred.
const lanStillFresh = Duration(seconds: 90);

/// Shuttle: the same device was confirmed again ([incoming]); decides which address the list keeps.
/// When the device is reachable at both a LAN and a Tailscale address, keep the LAN one (faster) — but only if the LAN address
/// was also confirmed recently. Otherwise the peer has most likely left this Wi-Fi and the old address is dead (observed: after
/// the phone switched to mobile data, the PC kept sending to the phone's stale Wi-Fi address).
Device pickDeviceAddress({required Device old, required Device incoming, required DateTime? oldConfirmedAt, required DateTime now}) {
  if (!isTailscaleIp(incoming.ip) || isTailscaleIp(old.ip)) return incoming;
  return oldConfirmedAt != null && now.difference(oldConfirmedAt) < lanStillFresh ? old : incoming;
}

/// Shuttle security: while encryption is on locally, "my devices" are only accepted over encrypted connections.
/// A peer announcing itself as unencrypted (HTTP) has no certificate to check, so anyone can impersonate the fingerprint it
/// reports (fingerprints are public in announcements anyway); trusting it would send content meant for "my devices" in
/// plaintext to the impostor. Unknown devices aren't blocked here: sending to them is a deliberate choice and the receiver
/// has to accept. Nothing is blocked when the user turned encryption off in settings; that's the user's choice.
bool isInsecureTrustedDevice({required Device device, required bool httpsEnabled, required Set<String> trustedFingerprints}) {
  return httpsEnabled && !device.https && trustedFingerprints.contains(device.fingerprint);
}

/// Registers a device in the state.
/// It will override any existing device with the same fingerprint: the
/// incoming device is the merged store state, so it already carries every
/// address the device was confirmed on.
class RegisterDeviceAction extends AsyncReduxAction<NearbyDevicesService, NearbyDevicesState> {
  final Device device;

  RegisterDeviceAction(this.device);

  @override
  bool get trackOrigin => false;

  @override
  Future<NearbyDevicesState> reduce() async {
    assert(device.ip?.isNotEmpty ?? false, 'IP must not be empty');

    // Shuttle security: reject a device claiming to be one of "my devices" that only has an unencrypted address (its reported
    // name must not rename the favorite either).
    final trusted = notifier._favoriteService.state.map((f) => f.fingerprint).toSet();
    if (isInsecureTrustedDevice(device: device, httpsEnabled: notifier._settingsService.state.https, trustedFingerprints: trusted)) {
      notifier._discoveryLogger.addLog(
        '[SECURITY] ignored ${device.alias} (${device.ip}): claims to be one of My devices over an unencrypted connection',
      );
      return state;
    }

    final favoriteDevice = notifier._favoriteService.state.firstWhereOrNull((e) => e.fingerprint == device.fingerprint);
    // Shuttle: only update when the name really changed (UpdateFavoriteAction writes the settings file every time; devices are
    // confirmed as often as every 20 seconds, see shareme_presence.dart)
    // Shuttle: both actions dispatched here (UpdateFavoriteAction, LearnPairedAddressAction) are now synchronous (memory is
    // updated at once, the save is queued), so they can no longer overwrite the saves made during pairing
    if (favoriteDevice != null && !favoriteDevice.customAlias && favoriteDevice.alias != device.alias) {
      // Update existing favorite with new alias
      external(notifier._favoriteService).dispatch(UpdateFavoriteAction(favoriteDevice.copyWith(alias: device.alias)));
    }
    // Shuttle: a paired device was confirmed at a new LAN address (e.g. a laptop back on the home Wi-Fi after the office): record
    // it in the pairing record so it is found directly by address next time. Encrypted connections only: without encryption the
    // reported fingerprint can't be verified. device.ip is the address just confirmed (the Rust side puts the most recent first).
    final ip = device.ip;
    if (device.https && ip != null) {
      external(notifier._pairedDevices).dispatch(LearnPairedAddressAction(fingerprint: device.fingerprint, ip: ip));
    }
    await Future.microtask(() {});
    final now = DateTime.now();
    _confirmedAt['${device.fingerprint}@${device.ip}'] = now;
    _lastConfirmed[device.fingerprint] = now;
    return state.copyWith(
      devices: {...state.devices}
        ..update(
          device.fingerprint,
          (old) => pickDeviceAddress(old: old, incoming: device, oldConfirmedAt: _confirmedAt['${old.fingerprint}@${old.ip}'], now: now),
          ifAbsent: () => device,
        ),
    );
  }
}

/// Registers a new device found via signaling.
class RegisterSignalingDeviceAction extends ReduxAction<NearbyDevicesService, NearbyDevicesState> {
  final Device device;

  RegisterSignalingDeviceAction(this.device);

  @override
  NearbyDevicesState reduce() {
    final Set<Device> existingDevices = state.signalingDevices[device.fingerprint]?.toSet() ?? {};
    final existingDevice = existingDevices.firstWhereOrNull((e) => e.signalingId == device.signalingId);
    if (existingDevice != null) {
      existingDevices.remove(existingDevice);
    }
    existingDevices.add(device);

    return state.copyWith(
      signalingDevices: {
        ...state.signalingDevices,
        device.fingerprint: existingDevices,
      },
    );
  }
}

class UnregisterSignalingDeviceAction extends ReduxAction<NearbyDevicesService, NearbyDevicesState> {
  final String signalingId;

  UnregisterSignalingDeviceAction(this.signalingId);

  @override
  NearbyDevicesState reduce() {
    return state.copyWith(
      signalingDevices: {
        for (final entry in state.signalingDevices.entries) entry.key: entry.value.where((e) => e.signalingId != signalingId).toSet(),
      },
    );
  }
}

/// It does not really "scan".
/// It just sends an announcement which will cause a response on every other LocalSend member of the network.
class StartMulticastScan extends ReduxAction<NearbyDevicesService, NearbyDevicesState> {
  @override
  NearbyDevicesState reduce() {
    external(notifier._isolateController).dispatch(IsolateDiscoveryAnnouncementAction());
    return state;
  }
}

/// Scans one particular subnet with traditional HTTP/TCP discovery.
/// This method awaits until the scan is finished.
class StartLegacyScan extends AsyncReduxAction<NearbyDevicesService, NearbyDevicesState> {
  final int port;
  final String localIp;
  final bool https;

  StartLegacyScan({
    required this.port,
    required this.localIp,
    required this.https,
  });

  @override
  Future<NearbyDevicesState> reduce() async {
    if (state.runningIps.contains(localIp)) {
      // already running for the same localIp
      await Future.microtask(() {});
      return state;
    }

    dispatch(_SetRunningIpsAction({...state.runningIps, localIp}));

    // The found devices arrive on the [StartDiscoveryListener] stream;
    // this stream only signals when the scan is finished.
    await external(notifier._isolateController)
        .dispatchTakeResult(
          IsolateDiscoverySubnetScanAction(
            networkInterface: localIp,
            port: port,
            https: https,
          ),
        )
        .drain<void>();

    return state.copyWith(
      runningIps: state.runningIps.where((ip) => ip != localIp).toSet(),
    );
  }
}

/// Discovers devices in stages, cheapest first: multicast announcement and
/// favorite probes right away, a subnet scan of [interfaces] only when
/// nothing was confirmed within the grace period.
/// This method awaits until every stage is finished.
class StartStagedScan extends AsyncReduxAction<NearbyDevicesService, NearbyDevicesState> {
  final List<FavoriteDevice> favorites;
  final List<String> interfaces;
  final int port;
  final bool https;
  final Duration grace;

  StartStagedScan({
    required this.favorites,
    required this.interfaces,
    required this.port,
    required this.https,
    required this.grace,
  });

  @override
  Future<NearbyDevicesState> reduce() async {
    dispatch(_SetRunningFavoriteScanAction(true));

    // The found devices arrive on the [StartDiscoveryListener] stream;
    // this stream only signals when every stage has finished.
    await external(notifier._isolateController)
        .dispatchTakeResult(
          IsolateDiscoveryStagedScanAction(
            favorites: favorites.map((e) => (e.ip, e.port)).toList(),
            networkInterfaces: interfaces,
            port: port,
            https: https,
            grace: grace,
          ),
        )
        .drain<void>();

    return state.copyWith(
      runningFavoriteScan: false,
    );
  }
}

class _SetRunningIpsAction extends ReduxAction<NearbyDevicesService, NearbyDevicesState> {
  final Set<String> runningIps;

  _SetRunningIpsAction(this.runningIps);

  @override
  NearbyDevicesState reduce() {
    return state.copyWith(
      runningIps: runningIps,
    );
  }
}

class _SetRunningFavoriteScanAction extends ReduxAction<NearbyDevicesService, NearbyDevicesState> {
  final bool running;

  _SetRunningFavoriteScanAction(this.running);

  @override
  NearbyDevicesState reduce() {
    return state.copyWith(
      runningFavoriteScan: running,
    );
  }
}
