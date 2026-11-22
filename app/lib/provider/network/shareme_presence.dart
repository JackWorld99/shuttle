import 'dart:async';

import 'package:collection/collection.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/persistence/paired_record.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/model/state/server/receive_session_state.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/paired_devices_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/shareme_pairing/pair_crypto.dart' show isTailscaleIp;
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/rust/api/http.dart' show RsHttpClient;
import 'package:localsend_isolates/rust/api/model.dart' show ProtocolType;
import 'package:localsend_isolates/util/rust.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';

// Shuttle: devices that can't be reached are shown as "offline".
//
// LocalSend's discovery only says "I'm here", never "I'm gone": a found device stayed in the list until "Refresh" or a network
// change, so after Shuttle on the PC was closed, the phone kept showing it as online and a send only revealed it by failing.
//
// Following Warpinator (Linux Mint's LAN file-transfer tool), "my devices" are periodically asked whether they are still there:
// - Only "my devices" are asked. Asking unknown "Nearby" devices too would send them this device's name and fingerprint every
//   20 seconds and let them log when you are online.
// - Each is asked at its current address plus its other remembered addresses (LAN, Tailscale), even while offline, so it
//   comes back online as soon as it answers.
// - Asking means one LocalSend register request ("Nearby" discovery uses it too; the peer answers with its info). With
//   encryption on, the peer's certificate fingerprint is pinned.
// - Online PCs are asked every 20 s, online phones every 60 s (each ask wakes the phone's radio, which costs more on mobile
//   data), offline devices every 5 min (they register themselves when they come back, within about 2 s in testing, so this is
//   only a fallback).
// - If no address answers within 5 s, ask again after 2 s; only if that fails too is the device removed from the list (shown as
//   "offline"). A brief drop (phone Wi-Fi power saving) doesn't count.
// - Devices with an active transfer aren't asked: they are obviously online, and a slow moment in a large transfer shouldn't
//   count as offline.
// - While the LAN address is in use, ask only it first and skip Tailscale if it answers; while on Tailscale, ask all addresses
//   at once, so the LAN path is picked up again after returning to the same Wi-Fi.
// - The phone only asks while Shuttle is in the foreground (saves battery) and asks everyone once on returning to it; the PC
//   asks all the time (see home_page.dart).

final _logger = Logger('Presence');

/// How often the timer ticks; also the interval for online PCs (Warpinator uses 20 seconds while online as well)
const presenceInterval = Duration(seconds: 20);

/// How often an online phone is asked
const presenceMobileInterval = Duration(seconds: 60);

/// How often an offline device from "my devices" is asked
const presenceOfflineInterval = Duration(minutes: 5);

/// How long a single ask may go unanswered before it counts as no answer
const presenceTimeout = Duration(seconds: 5);

/// Delay before asking again after the first missing answer
const presenceRetryDelay = Duration(seconds: 2);

typedef PresenceAddress = ({String ip, int port});

/// One device to ask in a presence round
class PresenceTarget {
  final String fingerprint;
  final bool https;

  /// Addresses to ask, with the one currently used in the list first
  final List<PresenceAddress> addresses;

  /// Its current list entry (shown as "online"); null means it is currently shown as "offline"
  final Device? listed;

  const PresenceTarget({required this.fingerprint, required this.https, required this.addresses, required this.listed});
}

/// Devices with an active transfer (outgoing: connecting or sending; incoming: awaiting acceptance or receiving)
Set<String> busyFingerprints(Iterable<SendSessionState> sends, ReceiveSessionState? receive) {
  bool active(SessionStatus s) => s == SessionStatus.waiting || s == SessionStatus.sending;
  return {
    for (final s in sends)
      if (active(s.status)) s.target.fingerprint,
    if (receive != null && active(receive.status)) receive.sender.fingerprint,
  };
}

/// How often to ask this device: [presenceInterval] for an online PC, [presenceMobileInterval] for an online phone,
/// [presenceOfflineInterval] when offline
Duration presenceIntervalFor(PresenceTarget target) {
  final listed = target.listed;
  if (listed == null) return presenceOfflineInterval;
  return listed.deviceType == DeviceType.mobile ? presenceMobileInterval : presenceInterval;
}

/// Whether to ask it this round: never asked, [force] (the phone just returned to the foreground), or enough time since the last
/// ask. The interval has 2 seconds of slack: the timer ticks every 20 seconds, so without it a 60-second interval would become 80.
bool presenceDue(PresenceTarget target, DateTime? lastAsked, DateTime now, {bool force = false}) {
  if (force || lastAsked == null) return true;
  return now.difference(lastAsked) >= presenceIntervalFor(target) - const Duration(seconds: 2);
}

/// Devices and addresses that may be asked this round: only "my devices" (online ones at their current address, plus their other
/// remembered addresses). Devices with an active transfer are skipped.
List<PresenceTarget> presenceTargets({
  required Iterable<Device> nearby,
  required List<FavoriteDevice> favorites,
  required List<PairedRecord> paired,
  required bool https,
  Set<String> busy = const {},
}) {
  List<PresenceAddress> known(String fingerprint) {
    final f = favorites.firstWhereOrNull((f) => f.fingerprint == fingerprint);
    if (f == null) return const [];
    final r = paired.firstWhereOrNull((r) => r.fingerprint == fingerprint);
    return [(ip: f.ip, port: f.port), for (final a in r?.addresses ?? const <String>[]) (ip: a, port: f.port)];
  }

  List<PresenceAddress> unique(List<PresenceAddress> list) {
    final seen = <String>{};
    return [
      for (final a in list)
        if (a.ip.isNotEmpty && seen.add('${a.ip}:${a.port}')) a,
    ];
  }

  final done = <String>{...busy};
  final targets = <PresenceTarget>[];
  for (final f in favorites) {
    if (!done.add(f.fingerprint)) continue;
    final d = nearby.firstWhereOrNull((d) => d.fingerprint == f.fingerprint && d.ip != null);
    if (d != null) {
      targets.add(
        PresenceTarget(
          fingerprint: f.fingerprint,
          https: d.https,
          addresses: unique([(ip: d.ip!, port: d.port), ...known(f.fingerprint)]),
          listed: d,
        ),
      );
      continue;
    }
    final addresses = unique(known(f.fingerprint));
    if (addresses.isEmpty) continue;
    targets.add(PresenceTarget(fingerprint: f.fingerprint, https: https, addresses: addresses, listed: null));
  }
  return targets;
}

/// Asks one address: returns the device that answered (with a matching fingerprint), or null on no answer, an error or a wrong fingerprint
typedef PresenceProbe = Future<Device?> Function(PresenceTarget target, PresenceAddress address);

/// Asks a device's addresses and uses the one that answered.
/// - On a LAN address: ask only that one first and stop if it answers (don't wake up the Tailscale path); otherwise ask the
///   other addresses together.
/// - On Tailscale, or offline: ask all addresses at once; if both LAN and Tailscale answer, use LAN (faster) — so the device
///   switches back to LAN once it is on the same Wi-Fi again.
Future<Device?> probeAllAddresses(PresenceTarget target, PresenceProbe probe) async {
  // Errors (unreachable, timeout, wrong certificate) count as no answer. Not using catchError: it requires the handler's return
  // type to match the future exactly, which easily fails at runtime
  Future<Device?> ask(PresenceAddress a) async {
    try {
      return await probe(target, a);
    } catch (_) {
      return null;
    }
  }

  Device? pick(List<Device?> results) {
    final answered = results.whereType<Device>().toList();
    return answered.firstWhereOrNull((d) => !isTailscaleIp(d.ip ?? '')) ?? answered.firstOrNull;
  }

  final listedIp = target.listed?.ip;
  final lanFirst = listedIp != null && !isTailscaleIp(listedIp) && target.addresses.isNotEmpty && target.addresses.first.ip == listedIp;
  if (lanFirst) {
    final first = await ask(target.addresses.first);
    if (first != null) return first;
    return pick(await Future.wait([for (final a in target.addresses.skip(1)) ask(a)]));
  }
  return pick(await Future.wait([for (final a in target.addresses) ask(a)]));
}

/// Checks one device: an online one that doesn't answer is asked again after [retryDelay]; an offline one is asked once
/// (it will be asked again in a later round)
Future<Device?> checkPresence(PresenceTarget target, PresenceProbe probe, {Duration retryDelay = presenceRetryDelay}) async {
  final first = await probeAllAddresses(target, probe);
  if (first != null || target.listed == null) return first;
  await Future<void>.delayed(retryDelay);
  return probeAllAddresses(target, probe);
}

/// One set of fingerprint-pinned clients per certificate identity, so they aren't rebuilt every 20 seconds (when the local
/// certificate changes, httpProvider provides a new instance and these follow)
final _pinnedClients = Expando<Map<String, RsHttpClient>>();

/// Runs one presence round; only one round runs at a time. [presenceDue] decides per device whether it is asked this round;
/// [force] asks every device (the phone returned to the foreground).
class CheckPresenceAction extends AsyncGlobalAction {
  final bool force;

  CheckPresenceAction({this.force = false});

  static bool _running = false;

  /// When each device (by fingerprint) was last asked
  static final _lastAsked = <String, DateTime>{};

  @override
  Future<void> reduce() async {
    if (_running) return;
    _running = true;
    try {
      await _check();
    } finally {
      _running = false;
    }
  }

  Future<void> _check() async {
    final since = DateTime.now();
    final settings = ref.read(settingsProvider);
    final targets = presenceTargets(
      nearby: ref.read(nearbyDevicesProvider).devices.values,
      favorites: ref.read(favoritesProvider),
      paired: ref.read(pairedDevicesProvider),
      https: settings.https,
      busy: busyFingerprints(ref.read(sendProvider).values, ref.read(serverProvider)?.session),
    ).where((t) => presenceDue(t, _lastAsked[t.fingerprint], since, force: force)).toList();
    if (targets.isEmpty) return;
    for (final t in targets) {
      _lastAsked[t.fingerprint] = since;
    }

    final http = ref.read(httpProvider);
    final pinned = _pinnedClients[http] ??= {};
    final payload = ref.read(deviceFullInfoProvider).toRegisterDto();
    Future<Device?> probe(PresenceTarget t, PresenceAddress a) async {
      // With encryption, pin the certificate: another device that takes over the address can't fake "it's still there"
      final client = t.https ? pinned[t.fingerprint] ??= http.pinnedTo(t.fingerprint, timeoutMs: presenceTimeout.inMilliseconds) : http.discovery;
      final response = await client
          .register(protocol: t.https ? ProtocolType.https : ProtocolType.http, ip: a.ip, port: a.port, payload: payload)
          .timeout(presenceTimeout + const Duration(seconds: 1));
      final device = response.body.toDevice(a.ip, a.port, t.https);
      return device.fingerprint == t.fingerprint ? device : null;
    }

    await Future.wait([
      for (final t in targets) checkPresence(t, probe).then((found) => _apply(t, found, since)),
    ]);
  }

  void _apply(PresenceTarget t, Device? found, DateTime since) {
    final listed = t.listed;
    if (found == null) {
      if (listed == null) return;
      _logger.info('${listed.alias} (${listed.ip}) did not answer twice: offline');
      ref.redux(nearbyDevicesProvider).dispatch(RemoveUnreachableDeviceAction(fingerprint: t.fingerprint, since: since));
      return;
    }
    final ip = found.ip!;
    if (listed != null && listed.ip == ip) {
      markDeviceSeen(found.fingerprint, ip);
      return;
    }
    // Back online, or at a new address: hand it to discovery to merge (as when it registers itself), from where it enters the list
    _logger.info('${found.alias} answered at $ip: online');
    ref.redux(parentIsolateProvider).dispatch(IsolateDiscoveryAddDeviceAction(device: found));
  }
}
