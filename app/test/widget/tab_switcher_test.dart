import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/widget/shareme/motion.dart';

class _Tab extends StatefulWidget {
  final String name;
  final List<String> log;

  const _Tab(this.name, this.log);

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> with SmTabState {
  var _taps = 0;

  @override
  void initState() {
    super.initState();
    widget.log.add('${widget.name} built');
  }

  @override
  void onTabShown() => widget.log.add('${widget.name} shown');

  @override
  void dispose() {
    widget.log.add('${widget.name} gone');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => setState(() => _taps++),
    child: SizedBox.expand(child: Text('${widget.name} $_taps')),
  );
}

void main() {
  Future<void> show(WidgetTester tester, int index, List<String> log) => tester.pumpWidget(
    MaterialApp(
      home: SmTabSwitcher(
        index: index,
        children: [
          for (final n in const ['A', 'B', 'C']) _Tab(n, log),
        ],
      ),
    ),
  );

  testWidgets('tabs keep their state and are told when they are shown', (tester) async {
    final log = <String>[];
    await show(tester, 0, log);
    expect(log, ['A built', 'A shown']);
    await tester.tap(find.text('A 0'));
    await tester.pump();

    await show(tester, 1, log);
    await tester.pumpAndSettle();
    expect(log.skip(2), ['B built', 'B shown']);
    expect(find.text('A 1'), findsNothing); // hidden
    expect(find.text('B 0'), findsOneWidget);

    await show(tester, 0, log);
    await tester.pumpAndSettle();
    expect(log.skip(4), ['A shown']); // not built again
    expect(find.text('A 1'), findsOneWidget);
  });

  testWidgets('the other tabs are built ahead, without being told they are shown', (tester) async {
    final log = <String>[];
    await show(tester, 0, log);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.pump();
    }
    expect(log, containsAll(['B built', 'C built']));
    expect(log, isNot(contains('B shown')));
    expect(find.text('B 0'), findsNothing);
    expect(find.text('B 0', skipOffstage: false), findsOneWidget);
  });

  testWidgets('old and new tab overlap while they change', (tester) async {
    final log = <String>[];
    await show(tester, 0, log);
    await show(tester, 1, log);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('A 0'), findsOneWidget);
    expect(find.text('B 0'), findsOneWidget);
    // Only the new one can be tapped
    await tester.tapAt(tester.getCenter(find.byType(SmTabSwitcher)));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('B 1'), findsOneWidget);
    expect(find.text('A 1', skipOffstage: false), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('A 0'), findsNothing);
  });
}
