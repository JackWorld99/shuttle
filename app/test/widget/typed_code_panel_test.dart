import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/shareme_pairing/pair_protocol.dart';
import 'package:localsend_app/widget/shareme/pair_widgets.dart';

/// Computer-to-computer pairing: the panel where each person types the code shown on the other computer
void main() {
  /// Pumps the panel; [answers] are what the check returns for each submitted code, in order
  Future<List<String>> pumpPanel(WidgetTester tester, List<PairCodeResult> answers) async {
    final typed = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildShareMeTheme(Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: TypedCodePanel(
              myCode: '482 109',
              peerName: 'Office PC',
              onSubmit: (code) async {
                typed.add(code);
                return answers[typed.length - 1];
              },
              onCancel: () {},
            ),
          ),
        ),
      ),
    );
    return typed;
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    // the check runs asynchronously; two frames let it finish and rebuild
    await tester.pump();
    await tester.pump();
  }

  testWidgets("shows this computer's code and checks once all six digits are typed", (tester) async {
    final typed = await pumpPanel(tester, [PairCodeResult.match]);
    expect(find.text('482 109'), findsOneWidget);
    await type(tester, '12345');
    expect(typed, isEmpty, reason: 'not before the sixth digit');
    await type(tester, '123456');
    expect(typed, ['123456']);
    expect(find.text(t.shareme.pair.typedChecked(name: 'Office PC')), findsOneWidget);
    expect(find.text(t.shareme.settings.cancel), findsNothing, reason: 'this side is done; it waits for the other computer');
  });

  testWidgets('a wrong code clears the field and says how many tries are left', (tester) async {
    final typed = await pumpPanel(tester, [PairCodeResult.wrong, PairCodeResult.match]);
    await type(tester, '000000');
    expect(find.text(t.shareme.pair.typedWrong(name: 'Office PC', n: pairCodeTries - 1)), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    await type(tester, '482109');
    expect(typed, ['000000', '482109']);
  });

  testWidgets('only digits can be typed', (tester) async {
    final typed = await pumpPanel(tester, [PairCodeResult.match]);
    await type(tester, 'ab12cd');
    expect(typed, isEmpty);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '12');
  });
}
