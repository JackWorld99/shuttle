import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/shareme_net_interface.dart';

// Shuttle: the receiving server on phone and computer (Rust, packages/core/src/http/server/local_network.rs) classifies network
// interfaces by the same rules to decide whether to accept a connection. Both test suites read the same data: if the lists change
// on one side only, this test or the Rust one fails. flutter test runs in app/.
const _sharedCases = '../packages/core/tests/fixtures/interface_kinds.json';

void main() {
  final cases = jsonDecode(File(_sharedCases).readAsStringSync()) as Map<String, dynamic>;

  test('interface classification matches the receiving server', () {
    final kinds = cases['kinds'] as Map<String, dynamic>;
    expect(kinds.keys.toSet(), {for (final kind in NetInterfaceKind.values) kind.name});
    kinds.forEach((kind, names) {
      for (final name in (names as List).cast<String>()) {
        expect(netInterfaceKindOf(name), NetInterfaceKind.values.byName(kind), reason: name);
      }
    });
  });

  test('Tailscale address ranges match the receiving server', () {
    final ranges = cases['tailscaleIpv4'] as Map<String, dynamic>;
    for (final ip in (ranges['in'] as List).cast<String>()) {
      expect(inTailscaleRange(ip), isTrue, reason: ip);
    }
    for (final ip in (ranges['out'] as List).cast<String>()) {
      expect(inTailscaleRange(ip), isFalse, reason: ip);
    }
  });
}
