import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/widget/shareme/content_stack.dart';
import 'package:localsend_app/widget/shareme/film_strip.dart';
import 'package:localsend_isolates/model/file_type.dart';

void main() {
  Future<List<int>> pump(WidgetTester tester, int n) async {
    final opened = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [ShareMeColors.light]),
        home: Scaffold(
          body: SingleChildScrollView(
            child: MediaMosaic(
              frames: [for (var i = 0; i < n; i++) FilmFrame(fileName: 'p$i.jpg', fileType: FileType.image, path: null)],
              onTap: opened.add,
            ),
          ),
        ),
      ),
    );
    return opened;
  }

  testWidgets('every picture of four or fewer opens', (tester) async {
    final opened = await pump(tester, 4);
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byType(FileThumb).at(i));
    }
    expect(opened, [0, 1, 2, 3]);
  });

  testWidgets('the last tile unfolds the rest', (tester) async {
    final opened = await pump(tester, 10);
    expect(find.byType(FileThumb), findsNWidgets(4));
    await tester.tap(find.text('+6'));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(find.byType(FileThumb), findsNWidgets(10));
    expect(find.textContaining('+'), findsNothing);
    await tester.tap(find.byType(FileThumb).at(9));
    expect(opened, [9]);
  });

  testWidgets('unfolds hundreds of pictures step by step', (tester) async {
    final opened = await pump(tester, 200);
    await tester.tap(find.text('+196'));
    await tester.pumpAndSettle();
    expect(find.byType(FileThumb), findsNWidgets(60));
    await tester.scrollUntilVisible(find.text('+140'), 400);
    await tester.tap(find.text('+140'));
    await tester.pumpAndSettle();
    expect(find.byType(FileThumb), findsNWidgets(120));
    expect(opened, isEmpty);
  });
}
