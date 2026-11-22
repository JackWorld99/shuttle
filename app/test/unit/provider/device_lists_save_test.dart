import 'dart:async';
import 'dart:typed_data';

import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/persistence/paired_record.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/paired_devices_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/util/shareme_pairing/pair_protocol.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:test/test.dart';

// Shuttle: the "My devices" and paired-record actions used to be async: build the new list from the old one and update the
// state only after the disk write. The automatic rename (UpdateFavoriteAction) / address learning (LearnPairedAddressAction) on
// discovery could run at about the same time as the save during pairing; whichever finished last overwrote the other, so a
// freshly paired device could be lost. A slow fake disk forces that overlap here.

const _phoneFp = 'PHONE-FINGERPRINT';
const _pcFp = 'PC-FINGERPRINT';

final _phone = FavoriteDevice(id: 'phone-id', fingerprint: _phoneFp, ip: '192.168.9.129', port: 53317, alias: 'Phone');
final _pc = FavoriteDevice(id: 'pc-id', fingerprint: _pcFp, ip: '192.168.0.20', port: 53317, alias: 'PC');

const _phoneRecord = PairedRecord(fingerprint: _phoneFp, secret: 's1', pairedAt: 1, addresses: ['192.168.9.129', '100.90.10.20']);
const _pcRecord = PairedRecord(fingerprint: _pcFp, secret: 's2', pairedAt: 2, addresses: ['192.168.0.20', '100.110.20.30']);

/// PairedRecord has no ==, so compare fingerprint and addresses (as lists, not records: lists inside a record aren't compared by content)
List<List<Object>> _records(List<PairedRecord> records) => [
  for (final r in records) [r.fingerprint, r.addresses],
];

/// Waits for the save timer to fire (it saves on the next event-loop turn)
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  group('My devices', () {
    test('an automatic rename while a new device is being saved: both stay, in memory and on disk', () async {
      final disk = _SlowDisk()..favorites = [_phone];
      final favorites = FavoritesService(disk);
      final service = ReduxNotifier.test(redux: favorites, initialState: [_phone]);

      disk.gate = Completer();
      service.dispatch(AddFavoriteAction(_pc)); // pairing: add to "My devices"
      await _settle();
      expect(disk.favoriteWrites, hasLength(1), reason: 'the first save started and is stuck on the slow disk');

      final renamed = _phone.copyWith(alias: 'Phone 2');
      service.dispatch(UpdateFavoriteAction(renamed)); // meanwhile "Nearby" sees that the phone was renamed
      expect(service.state, [renamed, _pc]);

      disk.gate!.complete();
      disk.gate = null;
      await favorites.flushSave();

      expect(disk.favorites, [renamed, _pc]);
      expect(disk.maxRunning['favorites'], 1, reason: 'one save at a time');
    });

    test('changes made in the same moment are written once, with the latest list', () async {
      final disk = _SlowDisk();
      final favorites = FavoritesService(disk);
      final service = ReduxNotifier.test(redux: favorites, initialState: [_phone]);

      service.dispatch(AddFavoriteAction(_pc));
      service.dispatch(UpdateFavoriteAction(_phone.copyWith(alias: 'Phone 2')));
      service.dispatch(RemoveFavoriteAction(deviceFingerprint: _pcFp));
      await favorites.flushSave();

      expect(disk.favoriteWrites, [
        [_phone.copyWith(alias: 'Phone 2')],
      ]);
    });
  });

  group('Paired records', () {
    // Both orders must work: the learned address is written first, or the new pairing is written first
    for (final learnFirst in [true, false]) {
      test('learning an address and saving a new pairing at the same time (${learnFirst ? 'learn' : 'save'} first): '
          'the new pairing stays', () async {
        final disk = _SlowDisk()..paired = [_phoneRecord];
        final paired = PairedDevicesService(disk);
        final service = ReduxNotifier.test(redux: paired, initialState: [_phoneRecord]);
        final learn = LearnPairedAddressAction(fingerprint: _phoneFp, ip: '192.168.0.11');
        final save = SavePairedRecordAction(_pcRecord);
        final (first, second) = learnFirst ? (learn, save) : (save, learn);

        disk.gate = Completer();
        service.dispatch(first);
        await _settle();
        expect(disk.pairedWrites, hasLength(1), reason: 'the first save started and is stuck on the slow disk');
        service.dispatch(second);

        final expected = [
          [
            _phoneFp,
            ['192.168.0.11', '192.168.9.129', '100.90.10.20'],
          ],
          [
            _pcFp,
            ['192.168.0.20', '100.110.20.30'],
          ],
        ];
        expect(_records(service.state), expected);

        disk.gate!.complete();
        disk.gate = null;
        await paired.flushSave();

        expect(_records(disk.paired), expected);
        expect(disk.maxRunning['paired'], 1, reason: 'one save at a time');
      });
    }

    test('removing a record is saved', () async {
      final disk = _SlowDisk()..paired = [_phoneRecord, _pcRecord];
      final paired = PairedDevicesService(disk);
      final service = ReduxNotifier.test(redux: paired, initialState: [_phoneRecord, _pcRecord]);

      service.dispatch(RemovePairedRecordAction(_pcFp));
      await paired.flushSave();

      expect(_records(disk.paired), [
        [_phoneFp, _phoneRecord.addresses],
      ]);
    });

    test('nothing to learn: no write', () async {
      final disk = _SlowDisk()..paired = [_phoneRecord];
      final paired = PairedDevicesService(disk);
      final service = ReduxNotifier.test(redux: paired, initialState: [_phoneRecord]);

      service.dispatch(LearnPairedAddressAction(fingerprint: _phoneFp, ip: '192.168.9.129')); // already first
      service.dispatch(LearnPairedAddressAction(fingerprint: 'UNKNOWN', ip: '192.168.0.11')); // never paired
      await paired.flushSave();

      expect(disk.pairedWrites, isEmpty);
    });
  });

  test('pairing while the phone is being confirmed nearby: the new pairing and the automatic updates all stay', () async {
    final disk = _SlowDisk()
      ..favorites = [_phone]
      ..paired = [_phoneRecord];
    final ref = RefenaContainer(overrides: [persistenceProvider.overrideWithValue(disk)]);
    expect(ref.read(favoritesProvider), [_phone]);
    expect(_records(ref.read(pairedDevicesProvider)), [
      [_phoneFp, _phoneRecord.addresses],
    ]);

    disk.gate = Completer();
    const peer = PairPeerInfo(
      fingerprint: _pcFp,
      alias: 'PC',
      model: null,
      type: 'desktop',
      port: 53317,
      https: true,
      addresses: ['192.168.0.20', '100.110.20.30'],
    );
    var pairingDone = false;
    final pairing = savePairing(ref, peer, '192.168.0.20', Uint8List(32), method: pairMethodNearby).then((_) => pairingDone = true);
    await _settle();

    // Right then "Nearby" confirms the phone again: it was renamed and switched Wi-Fi (the two automatic steps in RegisterDeviceAction)
    ref.redux(favoritesProvider).dispatch(UpdateFavoriteAction(_phone.copyWith(alias: 'Phone 2')));
    ref.redux(pairedDevicesProvider).dispatch(LearnPairedAddressAction(fingerprint: _phoneFp, ip: '192.168.0.11'));
    await _settle();
    expect(pairingDone, isFalse, reason: 'savePairing returns only after its changes are on disk');

    disk.gate!.complete();
    disk.gate = null;
    await pairing;
    await ref.notifier(favoritesProvider).flushSave();
    await ref.notifier(pairedDevicesProvider).flushSave();

    expect([for (final f in disk.favorites) (f.fingerprint, f.alias)], [(_phoneFp, 'Phone 2'), (_pcFp, 'PC')]);
    expect(_records(disk.paired), [
      [
        _phoneFp,
        ['192.168.0.11', '192.168.9.129', '100.90.10.20'],
      ],
      [
        _pcFp,
        ['192.168.0.20', '100.110.20.30'],
      ],
    ]);
    expect(disk.paired.last.method, pairMethodNearby);
    expect(disk.maxRunning['favorites'], 1);
    expect(disk.maxRunning['paired'], 1);
  });
}

/// Implements only what "My devices" and paired records need (the generated MockPersistenceService has no paired records yet).
/// While [gate] is not null, writes wait on it to simulate a slow disk; [favorites] / [paired] hold the disk contents once written.
class _SlowDisk implements PersistenceService {
  List<FavoriteDevice> favorites = [];
  List<PairedRecord> paired = [];

  /// What each write was asked to store (snapshot at call time)
  final favoriteWrites = <List<FavoriteDevice>>[];
  final pairedWrites = <List<PairedRecord>>[];

  Completer<void>? gate;
  final _running = <String, int>{};

  /// Highest number of concurrent writes seen per item
  final maxRunning = <String, int>{};

  Future<void> _write(String key, void Function() store) async {
    final running = (_running[key] ?? 0) + 1;
    _running[key] = running;
    if (running > (maxRunning[key] ?? 0)) maxRunning[key] = running;
    try {
      final g = gate;
      if (g != null) await g.future;
      store();
    } finally {
      _running[key] = _running[key]! - 1;
    }
  }

  @override
  List<FavoriteDevice> getFavorites() => favorites;

  @override
  Future<void> setFavorites(List<FavoriteDevice> entries) {
    final snapshot = List.of(entries);
    favoriteWrites.add(snapshot);
    return _write('favorites', () => favorites = snapshot);
  }

  @override
  List<PairedRecord> getPairedRecords() => paired;

  @override
  Future<void> setPairedRecords(List<PairedRecord> records) {
    final snapshot = List.of(records);
    pairedWrites.add(snapshot);
    return _write('paired', () => paired = snapshot);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
