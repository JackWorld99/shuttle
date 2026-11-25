import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/widget/shareme/message_sheet.dart';

Future<void> _pump(WidgetTester tester, String message) async {
  tester.view.physicalSize = const Size(1080, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildShareMeTheme(Brightness.light),
      home: Scaffold(
        body: SmMessageView(message: message, isLink: false, sealFingerprint: null, deviceType: null, header: const Text('x'), footnote: null),
      ),
    ),
  );
}

void main() {
  testWidgets('a short text is shown whole, without a note', (tester) async {
    await _pump(tester, 'Hello');
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text(t.shareme.text.excerpt), findsNothing);
  });

  testWidgets('of a very long text only the beginning is laid out, but all of it is copied', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    // One word: it took 6 seconds to lay out
    final message = 'abcdefgh' * (32 * 1024);
    await _pump(tester, message);
    final shown = tester.widget<SelectableText>(find.byType(SelectableText)).data!;
    expect(shown.length, 8001);
    expect(find.text(t.shareme.text.excerpt), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text(t.shareme.text.copy));
    await tester.pump();
    expect(copied, message);
  });
}
