import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/paired_record.dart';

// Shuttle: the pairing record stores which kind of pairing it was. Computer-to-computer "nearby" pairing used to be stored as a scan (qr+sas).

void main() {
  test('a nearby pairing is stored and read back as nearby', () {
    const record = PairedRecord(fingerprint: 'AB', secret: 'x', pairedAt: 1, method: pairMethodNearby);
    final back = PairedRecord.fromJson(record.toJson());
    expect(back.method, 'nearby+sas');
  });

  test('scan pairing stays the default, also for old records without the field', () {
    expect(const PairedRecord(fingerprint: 'AB', secret: 'x', pairedAt: 1).method, 'qr+sas');
    expect(PairedRecord.fromJson({'fingerprint': 'AB', 'secret': 'x', 'pairedAt': 1}).method, 'qr+sas');
  });
}
