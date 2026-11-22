import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_isolates/model/device.dart';

// Shuttle security: while encryption is enabled on this device, "My devices" are only trusted over encrypted connections.
// An unencrypted connection can't verify the peer's fingerprint: anyone on the same Wi-Fi could announce "I'm your computer, use HTTP"
// and trick you into sending them your files.

final _pc = 'AA' * 32;
final _stranger = 'BB' * 32;

Device _device({required String fingerprint, required bool https}) => Device(
  signalingId: null,
  ip: '192.168.9.168',
  version: '2.1',
  port: 53317,
  https: https,
  fingerprint: fingerprint,
  alias: 'Great Tomato',
  deviceModel: 'Windows',
  deviceType: DeviceType.desktop,
  download: false,
  channels: const [],
);

void main() {
  test('claims to be one of my devices but has only an unencrypted address: rejected', () {
    expect(
      isInsecureTrustedDevice(
        device: _device(fingerprint: _pc, https: false),
        httpsEnabled: true,
        trustedFingerprints: {_pc},
      ),
      isTrue,
    );
  });

  test('my device over an encrypted connection: fine', () {
    expect(
      isInsecureTrustedDevice(
        device: _device(fingerprint: _pc, https: true),
        httpsEnabled: true,
        trustedFingerprints: {_pc},
      ),
      isFalse,
    );
  });

  test('an unknown device using HTTP: not blocked here (sending to it needs a manual choice and approval by the peer anyway)', () {
    expect(
      isInsecureTrustedDevice(
        device: _device(fingerprint: _stranger, https: false),
        httpsEnabled: true,
        trustedFingerprints: {_pc},
      ),
      isFalse,
    );
  });

  test('encryption turned off in settings by the user: not blocked (their choice)', () {
    expect(
      isInsecureTrustedDevice(
        device: _device(fingerprint: _pc, https: false),
        httpsEnabled: false,
        trustedFingerprints: {_pc},
      ),
      isFalse,
    );
  });
}
