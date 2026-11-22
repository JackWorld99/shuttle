import 'dart:async';

import 'package:intl/date_symbol_data_local.dart';
import 'package:localsend_app/model/persistence/receive_history_entry.dart';
import 'package:localsend_app/provider/receive_history_provider.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:test/test.dart';

import '../../mocks.mocks.dart';

void main() {
  late MockPersistenceService persistenceService;

  setUpAll(() async {
    await initializeDateFormatting();
  });

  setUp(() {
    persistenceService = MockPersistenceService();
    when(persistenceService.isSaveToHistory()).thenReturn(true);
  });

  test('Should add an entry', () async {
    final history = ReceiveHistoryService(persistenceService);
    final service = ReduxNotifier.test(
      redux: history,
    );

    final entry = _createEntry('1');

    service.dispatch(
      AddHistoryEntryAction(
        entryId: entry.id,
        fileName: entry.fileName,
        fileType: entry.fileType,
        path: entry.path,
        savedToGallery: entry.savedToGallery,
        isMessage: entry.isMessage,
        fileSize: entry.fileSize,
        senderAlias: entry.senderAlias,
        timestamp: entry.timestamp,
      ),
    );

    expect(service.state, [entry]);
    await history.flushSave();
    verify(persistenceService.setReceiveHistory([entry]));
  });

  test('Should not add an entry if disabled', () async {
    when(persistenceService.isSaveToHistory()).thenReturn(false);

    final history = ReceiveHistoryService(persistenceService);
    final service = ReduxNotifier.test(
      redux: history,
    );

    final entry = _createEntry('1');

    service.dispatch(
      AddHistoryEntryAction(
        entryId: entry.id,
        fileName: entry.fileName,
        fileType: entry.fileType,
        path: entry.path,
        savedToGallery: entry.savedToGallery,
        isMessage: entry.isMessage,
        fileSize: entry.fileSize,
        senderAlias: entry.senderAlias,
        timestamp: entry.timestamp,
      ),
    );

    expect(service.state, []);
    await history.flushSave();
    verifyNever(persistenceService.setReceiveHistory(any));
  });

  // Shuttle: the limit was raised from 30 to 500
  test('Should remove the 500th entry when adding another', () async {
    final history = ReceiveHistoryService(persistenceService);
    final service = ReduxNotifier.test(
      redux: history,
      initialState: List.generate(500, (index) => _createEntry(index.toString())),
    );

    expect(service.state.length, 500);
    expect(service.state.first, _createEntry('0'));
    expect(service.state.last, _createEntry('499'));

    final entry = _createEntry('AAA');

    service.dispatch(
      AddHistoryEntryAction(
        entryId: entry.id,
        fileName: entry.fileName,
        fileType: entry.fileType,
        path: entry.path,
        savedToGallery: entry.savedToGallery,
        isMessage: entry.isMessage,
        fileSize: entry.fileSize,
        senderAlias: entry.senderAlias,
        timestamp: entry.timestamp,
      ),
    );

    expect(service.state.length, 500);
    expect(service.state.first, entry);
    expect(service.state.first, _createEntry('AAA'));
    expect(service.state[1], _createEntry('0'));
    expect(service.state.last, _createEntry('498'));
  });

  test('Should remove an entry', () async {
    final history = ReceiveHistoryService(persistenceService);
    final service = ReduxNotifier.test(
      redux: history,
      initialState: [
        _createEntry('1'),
        _createEntry('2'),
        _createEntry('3'),
      ],
    );

    expect(service.state.length, 3);

    service.dispatch(RemoveHistoryEntryAction('2'));

    expect(service.state.length, 2);
    expect(service.state, [
      _createEntry('1'),
      _createEntry('3'),
    ]);
    await history.flushSave();
    verify(
      persistenceService.setReceiveHistory([
        _createEntry('1'),
        _createEntry('3'),
      ]),
    );
  });

  test('Should not remove an entry if not found', () async {
    final history = ReceiveHistoryService(persistenceService);
    final service = ReduxNotifier.test(
      redux: history,
      initialState: [
        _createEntry('1'),
        _createEntry('2'),
        _createEntry('3'),
      ],
    );

    expect(service.state.length, 3);

    service.dispatch(RemoveHistoryEntryAction('4'));

    expect(service.state.length, 3);
    expect(service.state, [
      _createEntry('1'),
      _createEntry('2'),
      _createEntry('3'),
    ]);
    await history.flushSave();
    verifyNever(persistenceService.setReceiveHistory(any));
  });

  test('Should remove all entries', () async {
    final history = ReceiveHistoryService(persistenceService);
    final service = ReduxNotifier.test(
      redux: history,
      initialState: [
        _createEntry('1'),
        _createEntry('2'),
        _createEntry('3'),
      ],
    );

    expect(service.state.length, 3);

    service.dispatch(RemoveAllHistoryEntriesAction());

    expect(service.state.length, 0);
    await history.flushSave();
    verify(persistenceService.setReceiveHistory([]));
  });

  // Shuttle: when several files finished together, a later one used to overwrite an earlier one with a stale list,
  // and every file rewrote the whole settings file.
  test('50 files finishing at the same time: none is lost, and they are saved together', () async {
    final writes = <List<ReceiveHistoryEntry>>[];
    when(persistenceService.setReceiveHistory(any)).thenAnswer((invocation) async {
      writes.add(List.of(invocation.positionalArguments.first as List<ReceiveHistoryEntry>));
      await Future<void>.delayed(const Duration(milliseconds: 20)); // slow disk / Android's async storage
    });
    final history = ReceiveHistoryService(persistenceService);
    final service = ReduxNotifier.test(redux: history, initialState: <ReceiveHistoryEntry>[]);

    // Like ReceiveController.onFileUploadResult: each file is handled on its own, without waiting for the others
    await Future.wait([
      for (var i = 0; i < 50; i++)
        Future<void>(() async {
          await Future<void>.delayed(Duration(milliseconds: i % 7));
          service.dispatch(_addAction(_createEntry('$i')));
        }),
    ]);

    expect(service.state.length, 50);
    expect(service.state.map((e) => e.id).toSet(), {for (var i = 0; i < 50; i++) '$i'});
    expect(writes, isEmpty, reason: 'saved within a second, all at once');

    await history.flushSave();
    expect(writes.length, 1);
    expect(writes.single.map((e) => e.id).toSet(), {for (var i = 0; i < 50; i++) '$i'});
  });

  test('saves by itself within about a second', () async {
    final history = ReceiveHistoryService(persistenceService);
    final service = ReduxNotifier.test(redux: history, initialState: <ReceiveHistoryEntry>[]);

    service.dispatch(_addAction(_createEntry('1')));
    service.dispatch(_addAction(_createEntry('2')));
    verifyNever(persistenceService.setReceiveHistory(any));

    await Future<void>.delayed(const Duration(milliseconds: 1300));
    verify(persistenceService.setReceiveHistory([_createEntry('2'), _createEntry('1')])).called(1);
  });

  test('an entry added while a save is running is saved right after it', () async {
    final writes = <List<String>>[];
    final firstWrite = Completer<void>();
    when(persistenceService.setReceiveHistory(any)).thenAnswer((invocation) async {
      writes.add([for (final e in invocation.positionalArguments.first as List<ReceiveHistoryEntry>) e.id]);
      if (writes.length == 1) await firstWrite.future;
    });
    final history = ReceiveHistoryService(persistenceService);
    final service = ReduxNotifier.test(redux: history, initialState: <ReceiveHistoryEntry>[]);

    service.dispatch(_addAction(_createEntry('1')));
    final saving = history.flushSave();
    await Future<void>.delayed(Duration.zero);
    service.dispatch(_addAction(_createEntry('2'))); // the first save hasn't finished yet
    final second = history.flushSave();
    firstWrite.complete();
    await saving;
    await second;

    expect(writes, [
      ['1'],
      ['2', '1'],
    ]);
  });
}

ReceiveHistoryEntry _createEntry(String id) {
  return ReceiveHistoryEntry(
    id: id,
    fileName: 'fileName',
    fileType: FileType.image,
    path: 'path',
    savedToGallery: true,
    isMessage: false,
    fileSize: 123,
    senderAlias: 'senderAlias',
    timestamp: DateTime(2021, 1, 1),
  );
}

AddHistoryEntryAction _addAction(ReceiveHistoryEntry entry) {
  return AddHistoryEntryAction(
    entryId: entry.id,
    fileName: entry.fileName,
    fileType: entry.fileType,
    path: entry.path,
    savedToGallery: entry.savedToGallery,
    isMessage: entry.isMessage,
    fileSize: entry.fileSize,
    senderAlias: entry.senderAlias,
    timestamp: entry.timestamp,
  );
}
