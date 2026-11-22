import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/shareme_sender_identity.dart';

// Shuttle security: who sent something is decided only by the TLS certificate.

const _pc = 'AA00AA00AA00AA00AA00AA00AA00AA00AA00AA00AA00AA00AA00AA00AA00AA00';

void main() {
  test('with a certificate: its fingerprint is used', () {
    final fp = verifiedSenderFingerprint(certFingerprint: _pc, claimed: 'whatever');
    expect(fp, _pc);
    expect(isUnverifiedFingerprint(fp), isFalse);
  });

  test('no certificate, claims to be my computer: does not match the fingerprint of my computer, marked unverified', () {
    final fp = verifiedSenderFingerprint(certFingerprint: null, claimed: _pc);
    expect(fp, isNot(_pc));
    expect(isUnverifiedFingerprint(fp), isTrue);
    expect({_pc}.contains(fp), isFalse); // never taken for one of "My devices"
  });

  test('when the server verifies client certificates', () {
    expect(serverVerifiesClients(https: true, webShareActive: false), isTrue);
    expect(serverVerifiesClients(https: true, webShareActive: true), isFalse); // link page open: browsers have no certificate, so it is optional
    expect(serverVerifiesClients(https: false, webShareActive: false), isFalse); // encryption turned off by the user
  });
}
