import 'package:localsend_app/model/persistence/sent_history_entry.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/util/coalesced_save.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Shuttle: one entry is one batch, so 200 entries cover several months (the received history counts files and keeps 500).
const _maxSentEntries = 200;

/// Shuttle: sent history (LocalSend has none). Stored locally like [receiveHistoryProvider], and controlled by the same
/// "save to history" setting.
///
/// Like the received history, it uses synchronous actions with saves batched to one per second (two batches finishing at the
/// same time used to overwrite each other, see receive_history_provider.dart).
final sentHistoryProvider = ReduxProvider<SentHistoryService, List<SentHistoryEntry>>((ref) {
  return SentHistoryService(ref.read(persistenceProvider));
});

class SentHistoryService extends ReduxNotifier<List<SentHistoryEntry>> {
  final PersistenceService _persistence;

  /// Reads [state] only when saving, so the latest list is always saved
  late final _save = CoalescedSave(() => _persistence.setSentHistory(state));

  SentHistoryService(this._persistence);

  @override
  List<SentHistoryEntry> init() => _persistence.getSentHistory();

  /// Saves now and waits until done (changes normally save themselves within 1 second; before exiting see [CoalescedSave.flushAllBeforeExit])
  Future<void> flushSave() => _save.flush();
}

class AddSentHistoryAction extends ReduxAction<SentHistoryService, List<SentHistoryEntry>> {
  final SentHistoryEntry entry;

  AddSentHistoryAction(this.entry);

  @override
  List<SentHistoryEntry> reduce() {
    if (!notifier._persistence.isSaveToHistory()) {
      return state;
    }
    final updated = [entry, ...state.where((e) => e.id != entry.id)].take(_maxSentEntries).toList();
    notifier._save.schedule();
    return updated;
  }
}

/// Removes only the entry, not the files.
class RemoveSentHistoryAction extends ReduxAction<SentHistoryService, List<SentHistoryEntry>> {
  final String id;

  RemoveSentHistoryAction(this.id);

  @override
  List<SentHistoryEntry> reduce() {
    final updated = state.where((e) => e.id != id).toList();
    if (updated.length == state.length) {
      return state;
    }
    notifier._save.schedule();
    return updated;
  }
}

class RemoveAllSentHistoryAction extends ReduxAction<SentHistoryService, List<SentHistoryEntry>> {
  @override
  List<SentHistoryEntry> reduce() {
    notifier._save.schedule();
    return [];
  }
}
