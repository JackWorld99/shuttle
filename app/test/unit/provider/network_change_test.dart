import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/state/network_state.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';

// Shuttle: when the network changes (Wi-Fi ↔ mobile data, Tailscale connects or disconnects), clear the old device list
// and rescan (localIpsChanged). Seen in practice: after the phone switched from Wi-Fi to mobile data, the computer under
// "My devices" kept showing "Same Wi-Fi · direct" until a manual refresh.

NetworkState _s(List<String> ips, {bool initialized = true}) => NetworkState(localIps: ips, initialized: initialized);

void main() {
  test('Wi-Fi switched to mobile data + Tailscale: changed', () {
    expect(localIpsChanged(_s(['192.168.0.7']), _s(['100.90.10.20', '10.73.145.176'])), isTrue);
  });

  test('Tailscale connected (one more address): changed', () {
    expect(localIpsChanged(_s(['192.168.0.7']), _s(['100.90.10.20', '192.168.0.7'])), isTrue);
  });

  test('offline (no addresses left): changed', () {
    expect(localIpsChanged(_s(['192.168.0.7']), _s([])), isTrue);
  });

  test('same addresses in a different order: not changed', () {
    expect(localIpsChanged(_s(['100.90.10.20', '192.168.0.7']), _s(['192.168.0.7', '100.90.10.20'])), isFalse);
  });

  test('network event without an address change (Android often fires several in a row): not changed', () {
    expect(localIpsChanged(_s(['192.168.0.7']), _s(['192.168.0.7'])), isFalse);
  });

  test('first addresses right after app start: not changed (a scan runs at startup anyway)', () {
    expect(localIpsChanged(_s([], initialized: false), _s(['192.168.0.7'])), isFalse);
  });
}
