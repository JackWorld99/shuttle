import 'dart:async';

import 'package:localsend_app/util/coalesced_save.dart';
import 'package:test/test.dart';

// Shuttle: history saves are "batched for a moment, one save at a time" (coalesced_save.dart).

void main() {
  test('many changes within the delay are saved once', () async {
    var saves = 0;
    final save = CoalescedSave(() async => saves++, delay: const Duration(milliseconds: 30));

    for (var i = 0; i < 20; i++) {
      save.schedule();
    }
    expect(saves, 0);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(saves, 1);
    expect(save.hasPendingChanges, isFalse);
  });

  test('never two saves at once; a change during a save gets one more save afterwards', () async {
    var running = 0;
    var maxRunning = 0;
    var saves = 0;
    final gate = Completer<void>();
    final save = CoalescedSave(() async {
      running++;
      maxRunning = running > maxRunning ? running : maxRunning;
      saves++;
      if (saves == 1) await gate.future;
      running--;
    }, delay: const Duration(milliseconds: 10));

    save.schedule();
    final first = save.flush();
    await Future<void>.delayed(Duration.zero);
    save.schedule(); // the first save is still running
    final second = save.flush();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(saves, 1, reason: 'the second save waits for the first one');
    gate.complete();
    await first;
    await second;

    expect(saves, 2);
    expect(maxRunning, 1);
  });

  test('a failed save does not stop later saves', () async {
    var calls = 0;
    final save = CoalescedSave(() async {
      calls++;
      if (calls == 1) throw StateError('disk full');
    });

    save.schedule();
    await save.flush();
    save.schedule();
    await save.flush();
    expect(calls, 2);
  });

  test('flush without changes does nothing', () async {
    var saves = 0;
    final save = CoalescedSave(() async => saves++);
    await save.flush();
    expect(saves, 0);
  });

  test('before exit: pending saves run right away (the synchronous part finishes before returning)', () {
    final written = <String>[];
    final a = CoalescedSave(() async => written.add('a'));
    final b = CoalescedSave(() async => written.add('b'));
    final idle = CoalescedSave(() async => written.add('idle'));

    a.schedule();
    b.schedule();
    expect(idle.hasPendingChanges, isFalse);

    CoalescedSave.flushAllBeforeExit();

    expect(written, unorderedEquals(['a', 'b']));
    expect(CoalescedSave.pendingCountForTest, 0);
  });
}
