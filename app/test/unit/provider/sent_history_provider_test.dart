import 'package:localsend_app/model/persistence/sent_history_entry.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/sent_history_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:test/test.dart';

// Shuttle: like the receive history, the sent history is updated in memory at once and saved at most once a second (sent_history_provider.dart).

void main() {
  test('two batches finishing at the same time are both kept and saved together', () async {
    final persistence = _FakePersistence();
    final history = SentHistoryService(persistence);
    final service = ReduxNotifier.test(redux: history, initialState: <SentHistoryEntry>[]);

    await Future.wait([
      for (final id in ['a', 'b', 'c'])
        Future<void>(() async {
          await Future<void>.delayed(Duration.zero);
          service.dispatch(AddSentHistoryAction(_entry(id)));
        }),
    ]);

    expect(service.state.map((e) => e.id).toSet(), {'a', 'b', 'c'});
    expect(persistence.writes, isEmpty);
    await history.flushSave();
    expect(persistence.writes.length, 1);
    expect(persistence.writes.single.map((e) => e.id).toSet(), {'a', 'b', 'c'});
  });

  test('the same session recorded again replaces its old entry', () async {
    final persistence = _FakePersistence();
    final history = SentHistoryService(persistence);
    final service = ReduxNotifier.test(redux: history, initialState: [_entry('a'), _entry('b')]);

    service.dispatch(AddSentHistoryAction(_entry('b', message: 'again')));

    expect(service.state.map((e) => e.id), ['b', 'a']);
    expect(service.state.first.message, 'again');
  });

  test('nothing is recorded when history is turned off', () async {
    final persistence = _FakePersistence()..saveToHistory = false;
    final history = SentHistoryService(persistence);
    final service = ReduxNotifier.test(redux: history, initialState: <SentHistoryEntry>[]);

    service.dispatch(AddSentHistoryAction(_entry('a')));
    await history.flushSave();

    expect(service.state, isEmpty);
    expect(persistence.writes, isEmpty);
  });

  test('remove one / remove all', () async {
    final persistence = _FakePersistence();
    final history = SentHistoryService(persistence);
    final service = ReduxNotifier.test(redux: history, initialState: [_entry('a'), _entry('b')]);

    service.dispatch(RemoveSentHistoryAction('a'));
    expect(service.state.map((e) => e.id), ['b']);
    service.dispatch(RemoveSentHistoryAction('missing'));
    service.dispatch(RemoveAllSentHistoryAction());
    expect(service.state, isEmpty);

    await history.flushSave();
    expect(persistence.writes.length, 1);
    expect(persistence.writes.single, isEmpty);
  });
}

SentHistoryEntry _entry(String id, {String? message}) {
  return SentHistoryEntry(
    id: id,
    targetAlias: 'Phone',
    targetFingerprint: 'F' * 64,
    timestamp: DateTime.utc(2026, 11, 20),
    files: const [],
    message: message ?? 'hello',
    result: SentHistoryResult.delivered,
    errorMessage: null,
  );
}

/// Implements only what the sent history needs (the generated MockPersistenceService has no setSentHistory yet)
class _FakePersistence implements PersistenceService {
  bool saveToHistory = true;
  final writes = <List<SentHistoryEntry>>[];

  @override
  bool isSaveToHistory() => saveToHistory;

  @override
  List<SentHistoryEntry> getSentHistory() => [];

  @override
  Future<void> setSentHistory(List<SentHistoryEntry> entries) async {
    writes.add(List.of(entries));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
