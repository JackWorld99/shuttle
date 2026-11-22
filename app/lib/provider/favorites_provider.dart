import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/util/coalesced_save.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// This provider stores the list of favorite devices.
/// It automatically saves the list to the device's storage.
///
/// Shuttle: upstream's actions were async — they built the new list from the list at that moment and only updated the state
/// after writing to disk. When two actions ran at about the same time (e.g. [UpdateFavoriteAction] for a rename seen in
/// discovery and [AddFavoriteAction] from pairing), the later one still built on the old list and overwrote the earlier one,
/// so a freshly paired device could vanish from "my devices" (refena doesn't queue async actions). Now all actions are
/// synchronous and update memory immediately; saving is left to [CoalescedSave]: one save at a time, always of the latest list.
/// Changes are rare, so instead of batching for 1 second it saves on the next event-loop turn.
final favoritesProvider = ReduxProvider<FavoritesService, List<FavoriteDevice>>((ref) {
  return FavoritesService(ref.read(persistenceProvider));
});

class FavoritesService extends ReduxNotifier<List<FavoriteDevice>> {
  final PersistenceService _persistence;

  /// Reads [state] only when saving, so the latest list is always saved
  late final _save = CoalescedSave(() => _persistence.setFavorites(state), delay: Duration.zero);

  FavoritesService(this._persistence);

  @override
  List<FavoriteDevice> init() => _persistence.getFavorites();

  /// Saves now and waits until done (changes normally save themselves right away; before exiting see [CoalescedSave.flushAllBeforeExit])
  Future<void> flushSave() => _save.flush();
}

/// Adds a favorite device.
class AddFavoriteAction extends ReduxAction<FavoritesService, List<FavoriteDevice>> {
  final FavoriteDevice device;

  AddFavoriteAction(this.device);

  @override
  List<FavoriteDevice> reduce() {
    final updated = List<FavoriteDevice>.unmodifiable([
      ...state,
      device,
    ]);
    notifier._save.schedule();
    return updated;
  }
}

/// Updates a favorite device.
class UpdateFavoriteAction extends ReduxAction<FavoritesService, List<FavoriteDevice>> {
  final FavoriteDevice device;

  UpdateFavoriteAction(this.device);

  @override
  List<FavoriteDevice> reduce() {
    final index = state.indexWhere((e) => e.id == device.id);
    if (index == -1) {
      // Unknown device
      return state;
    }
    final updated = List<FavoriteDevice>.unmodifiable(
      <FavoriteDevice>[
        ...state,
      ]..replaceRange(index, index + 1, [device]),
    );
    notifier._save.schedule();
    return updated;
  }
}

/// Removes a favorite device.
class RemoveFavoriteAction extends ReduxAction<FavoritesService, List<FavoriteDevice>> {
  final String deviceFingerprint;

  RemoveFavoriteAction({
    required this.deviceFingerprint,
  });

  @override
  List<FavoriteDevice> reduce() {
    final index = state.indexWhere((e) => e.fingerprint == deviceFingerprint);
    if (index == -1) {
      // Unknown device
      return state;
    }
    final updated = List<FavoriteDevice>.unmodifiable(
      <FavoriteDevice>[
        ...state,
      ]..removeAt(index),
    );
    notifier._save.schedule();
    return updated;
  }
}
