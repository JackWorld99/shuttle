import 'package:localsend_app/model/persistence/receive_history_entry.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/util/coalesced_save.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:refena_flutter/refena_flutter.dart';

// Shuttle: LocalSend keeps only 30 files (a batch of 12 photos already takes 12 of them); raised to 500
const _maxHistoryEntries = 500;

/// This provider stores the history of received files.
/// It automatically saves the history to the device's storage.
///
/// Shuttle: upstream's actions were async — they built the new list from the list at that moment and only updated the state
/// after writing to disk. When several files finished together, a later action still built on the old list and overwrote the
/// earlier one (refena doesn't queue async actions). Now all actions are synchronous and update memory immediately; saves are
/// batched to one per second ([CoalescedSave]) instead of rewriting 500 entries and the whole settings file for every file.
final receiveHistoryProvider = ReduxProvider<ReceiveHistoryService, List<ReceiveHistoryEntry>>((ref) {
  return ReceiveHistoryService(ref.read(persistenceProvider));
});

class ReceiveHistoryService extends ReduxNotifier<List<ReceiveHistoryEntry>> {
  final PersistenceService _persistence;

  /// Reads [state] only when saving, so the latest list is always saved
  late final _save = CoalescedSave(() => _persistence.setReceiveHistory(state));

  ReceiveHistoryService(this._persistence);

  @override
  List<ReceiveHistoryEntry> init() => _persistence.getReceiveHistory();

  /// Saves now and waits until done (changes normally save themselves within 1 second; before exiting see [CoalescedSave.flushAllBeforeExit])
  Future<void> flushSave() => _save.flush();
}

/// Adds a history entry.
class AddHistoryEntryAction extends ReduxAction<ReceiveHistoryService, List<ReceiveHistoryEntry>> {
  final String entryId;
  final String fileName;
  final FileType fileType;
  final String? path;
  final bool savedToGallery;
  final bool isMessage;
  final int fileSize;
  final String senderAlias;
  final DateTime timestamp;
  final String? senderFingerprint; // Shuttle
  final bool? checksumVerified; // Shuttle
  final String? batchId; // Shuttle

  AddHistoryEntryAction({
    required this.entryId,
    required this.fileName,
    required this.fileType,
    required this.path,
    required this.savedToGallery,
    required this.isMessage,
    required this.fileSize,
    required this.senderAlias,
    required this.timestamp,
    this.senderFingerprint,
    this.checksumVerified,
    this.batchId,
  });

  @override
  List<ReceiveHistoryEntry> reduce() {
    if (!notifier._persistence.isSaveToHistory()) {
      return state;
    }

    final updated = [
      ReceiveHistoryEntry(
        id: entryId,
        fileName: fileName,
        fileType: fileType,
        path: path,
        savedToGallery: savedToGallery,
        isMessage: isMessage,
        fileSize: fileSize,
        senderAlias: senderAlias,
        timestamp: timestamp,
        senderFingerprint: senderFingerprint,
        checksumVerified: checksumVerified,
        batchId: batchId,
      ),
      ...state,
    ].take(_maxHistoryEntries).toList();
    notifier._save.schedule();
    return updated;
  }
}

/// Removes a history entry.
class RemoveHistoryEntryAction extends ReduxAction<ReceiveHistoryService, List<ReceiveHistoryEntry>> {
  final String entryId;

  RemoveHistoryEntryAction(this.entryId);

  @override
  List<ReceiveHistoryEntry> reduce() {
    final index = state.indexWhere((e) => e.id == entryId);
    if (index == -1) {
      return state;
    }
    final updated = [...state]..removeAt(index);
    notifier._save.schedule();
    return updated;
  }
}

/// Shuttle: removes several entries at once (a history row can be a whole batch of files). Removes only the entries, not the files.
class RemoveHistoryEntriesAction extends ReduxAction<ReceiveHistoryService, List<ReceiveHistoryEntry>> {
  final Set<String> entryIds;

  RemoveHistoryEntriesAction(this.entryIds);

  @override
  List<ReceiveHistoryEntry> reduce() {
    final updated = state.where((e) => !entryIds.contains(e.id)).toList();
    if (updated.length == state.length) {
      return state;
    }
    notifier._save.schedule();
    return updated;
  }
}

/// Removes all history entries.
class RemoveAllHistoryEntriesAction extends ReduxAction<ReceiveHistoryService, List<ReceiveHistoryEntry>> {
  @override
  List<ReceiveHistoryEntry> reduce() {
    notifier._save.schedule();
    return [];
  }
}
