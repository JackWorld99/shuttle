import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/widget/shareme/transfer_scene.dart';
import 'package:localsend_app/widget/shareme/transfer_stage.dart';

/// The scene of the send and receive pages: what is shown when while something arrives
void main() {
  Widget stage(ScenePhase phase, {double progress = 0, bool reduceMotion = false}) => MaterialApp(
    theme: buildShareMeTheme(Brightness.light),
    home: MediaQuery(
      data: MediaQueryData(size: const Size(400, 800), disableAnimations: reduceMotion),
      child: Scaffold(
        body: TransferStage(
          phase: phase,
          progress: progress,
          from: (size) => SizedBox.square(dimension: size),
          to: (size) => SizedBox.square(dimension: size),
          frames: const [],
          text: Text(phase == ScenePhase.done ? 'arrived' : 'moving', key: ValueKey(phase)),
          arrivingText: const Text('arriving', key: ValueKey('arriving')),
          bottom: phase == ScenePhase.done ? const Text('button') : null,
        ),
      ),
    ),
  );

  testWidgets('the result and the buttons wait until the content has landed', (tester) async {
    await tester.pumpWidget(stage(ScenePhase.moving, progress: 0.9));
    expect(find.text('moving'), findsOneWidget);
    await tester.pumpWidget(stage(ScenePhase.done));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('arriving'), findsOneWidget);
    expect(find.text('arrived'), findsNothing);
    expect(find.text('button'), findsNothing);
    await tester.pump(TransferStage.flight);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('arrived'), findsOneWidget);
    expect(find.text('arriving'), findsNothing);
    expect(find.text('button'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('opened after the fact, the result is there at once', (tester) async {
    await tester.pumpWidget(stage(ScenePhase.done));
    expect(find.text('arrived'), findsOneWidget);
    expect(find.text('button'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('without animations nothing is held back', (tester) async {
    await tester.pumpWidget(stage(ScenePhase.moving, reduceMotion: true));
    await tester.pumpWidget(stage(ScenePhase.done, reduceMotion: true));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('arrived'), findsOneWidget);
    expect(find.text('button'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });
}
