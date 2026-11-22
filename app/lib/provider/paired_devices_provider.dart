import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/persistence/paired_record.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/util/coalesced_save.dart';
import 'package:localsend_app/util/shareme_net_interface.dart';
import 'package:localsend_app/util/shareme_pairing/pair_crypto.dart';
import 'package:localsend_app/util/shareme_pairing/pair_protocol.dart';
import 'package:localsend_app/widget/shareme/device_avatar.dart' show rememberDeviceType;
import 'package:localsend_isolates/model/device.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';

final _logger = Logger('PairedDevices');

/// Shuttle: the actions used to be async — they built the new list from the list at that moment and only updated the state
/// after writing to disk. A [LearnPairedAddressAction] dispatched without awaiting when a paired device is discovered could run
/// at about the same time as [SavePairedRecordAction] from pairing; the later one still built on the old list and overwrote the
/// earlier one, so a freshly paired record could be lost (refena doesn't queue async actions). Now all actions are synchronous
/// and update memory immediately; saving is left to [CoalescedSave]: one save at a time, always of the latest list. Changes are
/// rare, so instead of batching for 1 second it saves on the next event-loop turn.
final pairedDevicesProvider = ReduxProvider<PairedDevicesService, List<PairedRecord>>((ref) {
  return PairedDevicesService(ref.read(persistenceProvider));
});

class PairedDevicesService extends ReduxNotifier<List<PairedRecord>> {
  final PersistenceService _persistence;

  /// Reads [state] only when saving, so the latest list is always saved
  late final _save = CoalescedSave(() => _persistence.setPairedRecords(state), delay: Duration.zero);

  PairedDevicesService(this._persistence);

  @override
  List<PairedRecord> init() => _persistence.getPairedRecords();

  /// Saves now and waits until done (changes normally save themselves right away; before exiting see [CoalescedSave.flushAllBeforeExit])
  Future<void> flushSave() => _save.flush();
}

/// Saves a record (replacing an older one with the same fingerprint)
class SavePairedRecordAction extends ReduxAction<PairedDevicesService, List<PairedRecord>> {
  final PairedRecord record;

  SavePairedRecordAction(this.record);

  @override
  List<PairedRecord> reduce() {
    final updated = [...state.where((r) => r.fingerprint != record.fingerprint), record];
    notifier._save.schedule();
    return updated;
  }
}

/// Shuttle: maximum number of LAN addresses kept in a pairing record (same limit as for the addresses reported when pairing)
const maxPairedLanAddresses = 3;

/// Shuttle: a paired device was confirmed at LAN address [ip] (encrypted connection, matching certificate fingerprint). Moves
/// this address to the front of the record's LAN addresses, keeping at most [maxPairedLanAddresses] (dropping the least
/// recently confirmed); Tailscale addresses are kept as they are. Returns the new address list, or null if nothing changes.
///
/// Why: the pairing record stores the addresses from the Wi-Fi used on the day of pairing, and they never change afterwards.
/// A laptop that is on the office Wi-Fi by day and the home Wi-Fi in the evening finds none of its stored LAN addresses
/// reachable at home and only reaches the peer via Tailscale — the slow path, although both are on the same Wi-Fi. With the
/// new address remembered, the device is found directly by address on that Wi-Fi next time, without waiting for multicast or
/// a scan.
/// Not learned: Tailscale / carrier-grade NAT addresses in 100.64.0.0/10 (Tailscale addresses are known from pairing and don't
/// change), IPv6 (link-local addresses with an interface index mean nothing on another network), loopback and addresses such
/// as 169.254 that only mean something locally ([isUsableIpv4]).
List<String>? withLearnedLanAddress(List<String> addresses, String ip) {
  if (!isUsableIpv4(ip) || inCgnatRange(ip)) return null;
  final updated = [
    ...[ip, ...addresses.where((a) => a != ip && !isTailscaleIp(a))].take(maxPairedLanAddresses),
    ...addresses.where(isTailscaleIp),
  ];
  return const ListEquality<String>().equals(updated, addresses) ? null : updated;
}

/// Shuttle: remembers the LAN address a paired device was just confirmed at, see [withLearnedLanAddress]. Does nothing for
/// unpaired devices or when the address is already first. Only call it with addresses confirmed over an encrypted connection:
/// without encryption anyone can fake the reported fingerprint.
class LearnPairedAddressAction extends ReduxAction<PairedDevicesService, List<PairedRecord>> {
  final String fingerprint;
  final String ip;

  LearnPairedAddressAction({required this.fingerprint, required this.ip});

  @override
  List<PairedRecord> reduce() {
    final record = state.firstWhereOrNull((r) => r.fingerprint == fingerprint);
    final addresses = record == null ? null : withLearnedLanAddress(record.addresses, ip);
    if (record == null || addresses == null) return state;
    final updated = [
      for (final r in state)
        r.fingerprint == fingerprint
            ? PairedRecord(
                fingerprint: r.fingerprint,
                secret: r.secret,
                pairedAt: r.pairedAt,
                addresses: addresses,
                method: r.method,
                version: r.version,
              )
            : r,
    ];
    notifier._save.schedule();
    _logger.info('Paired device ${fingerprint.substring(0, 8)} learned LAN address $ip: $addresses');
    return updated;
  }
}

/// Deleted together with the device when it is removed from "my devices"
class RemovePairedRecordAction extends ReduxAction<PairedDevicesService, List<PairedRecord>> {
  final String fingerprint;

  RemovePairedRecordAction(this.fingerprint);

  @override
  List<PairedRecord> reduce() {
    if (state.none((r) => r.fingerprint == fingerprint)) return state;
    final updated = state.where((r) => r.fingerprint != fingerprint).toList();
    notifier._save.schedule();
    return updated;
  }
}

/// Pairing methods that count as "verified": QR pairing and PC-to-PC pairing from Nearby both have each side check the 12-digit code
const verifiedPairMethods = {pairMethodQr, pairMethodNearby};

/// Fingerprints of devices with a verification record (used for the small check mark in the UI and to decide on auto-accept)
Set<String> verifiedFingerprints(Iterable<PairedRecord> paired) => {
  for (final r in paired)
    if (verifiedPairMethods.contains(r.method)) r.fingerprint,
};

/// Shuttle: whether [fingerprint] is a verified one of "my devices" — listed in "my devices" and with a verification record.
/// Only such devices get files auto-accepted, text auto-copied and no Mark of the Web on the PC.
/// Devices added via "Add", "Add without checking" or "Add to My devices" when receiving are still listed in "my devices"
/// and can be sent to, but receiving from them asks first.
/// [fingerprint] must be the certificate-verified one (senderFingerprint in receive_controller), not a self-reported one.
bool isVerifiedMine({
  required Iterable<FavoriteDevice> favorites,
  required Iterable<PairedRecord> paired,
  required String fingerprint,
}) {
  return favorites.any((f) => f.fingerprint == fingerprint) && verifiedFingerprints(paired).contains(fingerprint);
}

/// [isVerifiedMine], reading the current "my devices" and verification records from [ref]
bool isVerifiedMineDevice(Ref ref, String fingerprint) {
  return isVerifiedMine(favorites: ref.read(favoritesProvider), paired: ref.read(pairedDevicesProvider), fingerprint: fingerprint);
}

/// Called once both sides have confirmed the pairing: adds (or updates) the peer in "my devices", then saves the verification result.
/// [customName] is the name the user gave the peer on the verification page (empty = use the peer's own name).
/// [method] is the verification method ([pairMethodQr] QR code / [pairMethodNearby] PC-to-PC pairing from Nearby), only kept in the record.
Future<void> savePairing(Ref ref, PairPeerInfo peer, String ip, Uint8List secret, {String? customName, String method = pairMethodQr}) async {
  // Remember the peer's device type (it is in the pairing message anyway). It used to be known only once the peer showed up in
  // "Nearby": in PC-to-PC pairing the host had never seen the peer there, so the paired page and "my devices" drew the other PC
  // as a phone
  final type = DeviceType.values.firstWhereOrNull((t) => t.name == peer.type);
  if (type != null) rememberDeviceType(peer.fingerprint, type);
  final typed = customName?.trim() ?? '';
  // The name field on the verification page is prefilled with the peer's own name; unchanged, it doesn't count as a custom name,
  // so later renames by the peer are followed here
  final custom = typed.isNotEmpty && typed != peer.alias;
  final existing = ref.read(favoritesProvider).firstWhereOrNull((f) => f.fingerprint == peer.fingerprint);
  if (existing == null) {
    final added = FavoriteDevice.fromValues(fingerprint: peer.fingerprint, ip: ip, port: peer.port, alias: custom ? typed : peer.alias);
    ref.redux(favoritesProvider).dispatch(AddFavoriteAction(custom ? added.copyWith(customAlias: true) : added));
  } else {
    final keepOwnName = existing.customAlias && !custom && typed.isEmpty;
    ref
        .redux(favoritesProvider)
        .dispatch(
          UpdateFavoriteAction(
            existing.copyWith(
              ip: ip,
              port: peer.port,
              alias: custom ? typed : (keepOwnName ? existing.alias : peer.alias),
              customAlias: custom || keepOwnName,
            ),
          ),
        );
  }
  ref
      .redux(pairedDevicesProvider)
      .dispatch(
        SavePairedRecordAction(
          PairedRecord(
            fingerprint: peer.fingerprint,
            secret: b64u(secret),
            pairedAt: DateTime.now().millisecondsSinceEpoch,
            addresses: peer.addresses,
            method: method,
          ),
        ),
      );
  // Memory is already updated; return once both are written to disk (the pairing page then shows "paired")
  await Future.wait([ref.notifier(favoritesProvider).flushSave(), ref.notifier(pairedDevicesProvider).flushSave()]);
}
