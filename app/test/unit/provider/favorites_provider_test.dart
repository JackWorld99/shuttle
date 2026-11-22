import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:test/test.dart';

import '../../mocks.mocks.dart';

void main() {
  late MockPersistenceService persistenceService;

  setUp(() {
    persistenceService = MockPersistenceService();
  });

  test('Should add a favorite device', () async {
    final favorites = FavoritesService(persistenceService);
    final service = ReduxNotifier.test(
      redux: favorites,
    );

    expect(service.state, []);

    final device = _createDevice('1');

    service.dispatch(AddFavoriteAction(device));
    await favorites.flushSave();

    expect(service.state, [device]);
    verify(persistenceService.setFavorites([device]));
  });

  test('Should update a favorite device', () async {
    final initialDevice = _createDevice('1', alias: 'A');
    final favorites = FavoritesService(persistenceService);
    final service = ReduxNotifier.test(
      redux: favorites,
      initialState: [initialDevice],
    );

    // Sanity check
    expect(service.state, [initialDevice]);
    expect(service.state.first.alias, 'A');

    final updatedDevice = _createDevice('1', alias: 'B');
    service.dispatch(UpdateFavoriteAction(updatedDevice));
    await favorites.flushSave();

    expect(service.state, [updatedDevice]);
    expect(service.state.first.alias, 'B');
    verify(persistenceService.setFavorites([updatedDevice]));
  });

  test('Should not update a favorite device if unknown id', () async {
    final initialDevice = _createDevice('1', alias: 'A');
    final favorites = FavoritesService(persistenceService);
    final service = ReduxNotifier.test(
      redux: favorites,
      initialState: [initialDevice],
    );

    // Sanity check
    expect(service.state, [initialDevice]);
    expect(service.state.first.alias, 'A');

    final updatedDevice = _createDevice('2', alias: 'B');
    service.dispatch(UpdateFavoriteAction(updatedDevice));
    await favorites.flushSave();

    expect(service.state, [initialDevice]);
    expect(service.state.first.alias, 'A');
    verifyNever(persistenceService.setFavorites(any));
  });

  test('Should delete favorite device', () async {
    final initialDevice = _createDevice('1', fingerprint: '111');
    final favorites = FavoritesService(persistenceService);
    final service = ReduxNotifier.test(
      redux: favorites,
      initialState: [initialDevice],
    );

    // Sanity check
    expect(service.state, [initialDevice]);

    service.dispatch(RemoveFavoriteAction(deviceFingerprint: '111'));
    await favorites.flushSave();

    expect(service.state, []);
    verify(persistenceService.setFavorites([]));
  });

  test('Should not delete favorite device if unknown fingerprint', () async {
    final initialDevice = _createDevice('1', fingerprint: '111');
    final favorites = FavoritesService(persistenceService);
    final service = ReduxNotifier.test(
      redux: favorites,
      initialState: [initialDevice],
    );

    // Sanity check
    expect(service.state, [initialDevice]);

    service.dispatch(RemoveFavoriteAction(deviceFingerprint: '222'));
    await favorites.flushSave();

    expect(service.state, [initialDevice]);
    verifyNever(persistenceService.setFavorites(any));
  });
}

FavoriteDevice _createDevice(
  String id, {
  String fingerprint = '123',
  String alias = 'A',
}) {
  return FavoriteDevice(
    id: id,
    fingerprint: fingerprint,
    ip: '1.2.3.4',
    port: 123,
    alias: alias,
  );
}
