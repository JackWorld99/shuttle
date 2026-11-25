import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/shareme_own_page.dart';

void main() {
  late BuildContext transfer;
  var declined = 0;

  Widget transferPage() => Builder(
    builder: (context) {
      transfer = context;
      return const Scaffold(body: Text('Delivered'));
    },
  );

  Widget requestPage() => PopScope(
    onPopInvokedWithResult: (didPop, _) => declined++,
    child: const Scaffold(body: Text('Request')),
  );

  Future<NavigatorState> start(WidgetTester tester) async {
    declined = 0;
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('Home'))));
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute<void>(builder: (_) => transferPage()));
    await tester.pumpAndSettle();
    expect(find.text('Delivered'), findsOneWidget);
    return navigator;
  }

  void toRoot() => Navigator.of(transfer).popUntil((route) => route.isFirst);

  testWidgets('goes home when nothing is on top', (tester) async {
    await start(tester);
    closeOwnPage(transfer, toRoot);
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Delivered'), findsNothing);
  });

  testWidgets('leaves a request that opened in the meantime alone', (tester) async {
    final navigator = await start(tester);
    navigator.push(MaterialPageRoute<void>(builder: (_) => requestPage()));
    await tester.pumpAndSettle();
    closeOwnPage(transfer, toRoot);
    await tester.pumpAndSettle();
    expect(find.text('Request'), findsOneWidget);
    expect(declined, 0);

    // The transfer page is gone: back from the request leads home
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(declined, 1);
  });

  testWidgets('takes its own open sheet with it', (tester) async {
    final navigator = await start(tester);
    unawaited(showModalBottomSheet<void>(context: transfer, builder: (_) => const Text('Stop sending?')));
    await tester.pumpAndSettle();
    closeOwnPage(transfer, toRoot, ownSheet: true);
    await tester.pumpAndSettle();
    expect(find.text('Stop sending?'), findsNothing);
    expect(find.text('Home'), findsOneWidget);
    expect(navigator.canPop(), isFalse);
  });

  testWidgets('does nothing once it is closing', (tester) async {
    final navigator = await start(tester);
    navigator.pop();
    await tester.pump();
    navigator.push(MaterialPageRoute<void>(builder: (_) => requestPage()));
    closeOwnPage(transfer, toRoot);
    await tester.pumpAndSettle();
    expect(find.text('Request'), findsOneWidget);
    expect(declined, 0);
  });
}
