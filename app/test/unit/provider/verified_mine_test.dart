import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/persistence/paired_record.dart';
import 'package:localsend_app/pages/shareme_verify_device.dart';
import 'package:localsend_app/provider/paired_devices_provider.dart';
import 'package:localsend_app/util/shareme_sender_identity.dart';
import 'package:localsend_isolates/model/device.dart';

// Shuttle: only verified "My devices" get automatic receive and automatic copy.
// Devices added via "Add" / "Add without checking" / the "Add to My devices" box when receiving stay in "My devices", but are asked.

FavoriteDevice _favorite(String fingerprint) => FavoriteDevice.fromValues(fingerprint: fingerprint, ip: '192.168.0.2', port: 53317, alias: 'PC');

PairedRecord _record(String fingerprint, {String method = pairMethodQr}) =>
    PairedRecord(fingerprint: fingerprint, secret: 's', pairedAt: 1, method: method);

void main() {
  group('isVerifiedMine', () {
    test('a device added with "Add" (no pairing record) is not verified', () {
      expect(isVerifiedMine(favorites: [_favorite('AA')], paired: const [], fingerprint: 'AA'), isFalse);
    });

    test('a device paired by QR code or nearby pairing is verified', () {
      expect(isVerifiedMine(favorites: [_favorite('AA')], paired: [_record('AA')], fingerprint: 'AA'), isTrue);
      expect(
        isVerifiedMine(
          favorites: [_favorite('BB')],
          paired: [_record('BB', method: pairMethodNearby)],
          fingerprint: 'BB',
        ),
        isTrue,
      );
    });

    test('a pairing record alone is not enough once the device left My devices', () {
      expect(isVerifiedMine(favorites: const [], paired: [_record('AA')], fingerprint: 'AA'), isFalse);
    });

    test('the record has to be for the same fingerprint', () {
      expect(isVerifiedMine(favorites: [_favorite('AA'), _favorite('BB')], paired: [_record('BB')], fingerprint: 'AA'), isFalse);
    });

    test('an unknown pairing method does not count', () {
      expect(
        isVerifiedMine(
          favorites: [_favorite('AA')],
          paired: [_record('AA', method: 'manual')],
          fingerprint: 'AA',
        ),
        isFalse,
      );
    });

    test('a sender without a certificate never matches, even if it claims a paired fingerprint', () {
      final claimed = verifiedSenderFingerprint(certFingerprint: null, claimed: 'AA');
      expect(isVerifiedMine(favorites: [_favorite('AA')], paired: [_record('AA')], fingerprint: claimed), isFalse);
    });
  });

  test('verifiedFingerprints keeps only verified pairing methods', () {
    expect(verifiedFingerprints([_record('AA'), _record('BB', method: pairMethodNearby), _record('CC', method: 'manual')]), {'AA', 'BB'});
  });

  group('verifyRouteFor', () {
    test('phone verifies a computer by scanning its QR code', () {
      expect(verifyRouteFor(thisIsDesktop: false, peerType: DeviceType.desktop, peerOnline: true), VerifyRoute.scan);
      // never seen online: most devices added on a phone are computers
      expect(verifyRouteFor(thisIsDesktop: false, peerType: null, peerOnline: false), VerifyRoute.scan);
    });

    test('phone and phone cannot pair', () {
      expect(verifyRouteFor(thisIsDesktop: false, peerType: DeviceType.mobile, peerOnline: true), isNull);
    });

    test('computer shows a QR code for a phone', () {
      expect(verifyRouteFor(thisIsDesktop: true, peerType: DeviceType.mobile, peerOnline: true), VerifyRoute.host);
    });

    test('computer pairs an online computer nearby, an offline one through the QR page', () {
      expect(verifyRouteFor(thisIsDesktop: true, peerType: DeviceType.desktop, peerOnline: true), VerifyRoute.nearby);
      expect(verifyRouteFor(thisIsDesktop: true, peerType: DeviceType.desktop, peerOnline: false), VerifyRoute.host);
    });

    test('web, command line and server clients cannot pair', () {
      for (final type in [DeviceType.web, DeviceType.headless, DeviceType.server]) {
        expect(verifyRouteFor(thisIsDesktop: true, peerType: type, peerOnline: true), isNull);
        expect(verifyRouteFor(thisIsDesktop: false, peerType: type, peerOnline: true), isNull);
      }
    });
  });
}
