import 'package:localsend_app/model/persistence/receive_history_entry.dart';
import 'package:localsend_app/model/persistence/sent_history_entry.dart';
import 'package:localsend_app/pages/shareme_history_page.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:test/test.dart';

ReceiveHistoryEntry _rx(String id, DateTime time, {String alias = 'PC', String? batch, bool message = false, FileType type = FileType.image}) {
  return ReceiveHistoryEntry(
    id: id,
    fileName: message ? 'hello' : '$id.jpg',
    fileType: message ? FileType.text : type,
    path: null,
    savedToGallery: !message,
    isMessage: message,
    fileSize: 100,
    senderAlias: alias,
    timestamp: time,
    batchId: batch,
  );
}

SentHistoryEntry _tx(
  String id,
  DateTime time, {
  String? message,
  List<SentHistoryFile> files = const [],
  SentHistoryResult result = SentHistoryResult.delivered,
}) {
  return SentHistoryEntry(
    id: id,
    targetAlias: 'Phone',
    targetFingerprint: 'FP',
    timestamp: time,
    files: files,
    message: message,
    result: result,
    errorMessage: null,
  );
}

bool _all({required bool isMessage, required FileType type}) => true;

void main() {
  final t0 = DateTime.utc(2026, 11, 10, 12);

  test('received files of one session become one record', () {
    final records = buildHistoryRecords(
      [
        _rx('a', t0, batch: 's1'),
        _rx('b', t0.add(const Duration(seconds: 5)), batch: 's1'),
        _rx('c', t0.add(const Duration(minutes: 1)), batch: 's2'),
      ],
      const [],
      _all,
    );
    expect(records.length, 2);
    expect(records.last.frames.map((f) => f.fileName), ['a.jpg', 'b.jpg']); // in the order received
    expect(records.last.bytes, 200);
  });

  test('legacy entries without batch id are grouped by sender within 2 minutes', () {
    final records = buildHistoryRecords(
      [
        _rx('a', t0),
        _rx('b', t0.add(const Duration(minutes: 1))),
        _rx('c', t0.add(const Duration(minutes: 10))),
        _rx('d', t0.add(const Duration(minutes: 10, seconds: 30)), alias: 'Other'),
      ],
      const [],
      _all,
    );
    expect(records.map((r) => r.frames.length), [1, 1, 2]);
  });

  test('messages are always their own record', () {
    final records = buildHistoryRecords(
      [
        _rx('a', t0, batch: 's1', message: true),
        _rx('b', t0, batch: 's1'),
      ],
      const [],
      _all,
    );
    expect(records.length, 2);
    expect(records.where((r) => r.message == 'hello').length, 1);
  });

  test('sent and received are merged newest first', () {
    final records = buildHistoryRecords(
      [_rx('a', t0, batch: 's1')],
      [_tx('x', t0.add(const Duration(minutes: 5)), message: 'hi')],
      _all,
    );
    expect(records.map((r) => r.outgoing), [true, false]);
  });

  test('filter keeps only matching files of a sent batch', () {
    final files = [
      const SentHistoryFile(fileName: 'a.jpg', fileType: FileType.image, size: 1, path: null, assetId: '1', delivered: true),
      const SentHistoryFile(fileName: 'b.pdf', fileType: FileType.pdf, size: 2, path: '/b.pdf', assetId: null, delivered: false),
    ];
    bool media({required bool isMessage, required FileType type}) => !isMessage && (type == FileType.image || type == FileType.video);
    final records = buildHistoryRecords(const [], [_tx('x', t0, files: files, result: SentHistoryResult.partial)], media);
    expect(records.single.frames.map((f) => f.fileName), ['a.jpg']);
    expect(records.single.undelivered, 1);
    expect(records.single.failed, false);
  });

  test('a declined send is failed', () {
    final records = buildHistoryRecords(const [], [_tx('x', t0, message: 'hi', result: SentHistoryResult.declined)], _all);
    expect(records.single.failed, true);
  });

  test('search matches file names, text and device names, ignoring case', () {
    final records = buildHistoryRecords(
      [_rx('IMG_0042', t0, batch: 's1', alias: 'OFFICE-PC')],
      [_tx('x', t0.add(const Duration(minutes: 5)), message: 'Meeting at 3pm')],
      _all,
    );
    List<bool> hits(String q) => records.map((r) => r.matches(q.toLowerCase())).toList(); // newest first: [sent text, received photo]
    expect(hits('img_00'), [false, true]);
    expect(hits('MEETING'), [true, false]);
    expect(hits('office'), [false, true]);
    expect(hits('phone'), [true, false]);
    expect(hits('nothing'), [false, false]);
  });

  test('sent entry survives a JSON round trip', () {
    final entry = _tx(
      'x',
      t0,
      files: [const SentHistoryFile(fileName: 'a.jpg', fileType: FileType.image, size: 1, path: '/a.jpg', assetId: '9', delivered: true)],
    );
    final back = SentHistoryEntry.fromJson(entry.toJson());
    expect(back, entry);
  });
}
