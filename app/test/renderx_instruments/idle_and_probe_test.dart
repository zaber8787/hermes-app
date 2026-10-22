import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/features/chat/scroll_idle_gate.dart';
import 'frame_probe.dart';

void main() {
  test('early motion spike is retained even when final frames are quiet', () {
    expect(maxSampleStep([0, 2100, 2110, 2110, 2110]), 2100);
    expect(maxSampleStep([0, 10, 20, 20]), 10);
  });

  testWidgets('long drag never forces correction; idle resumes latest once', (
    tester,
  ) async {
    final scrolling = ValueNotifier(true);
    final gate = ScrollIdleGate();
    var old = 0;
    var latest = 0;
    gate.run(scrolling, () => old++);
    for (var i = 0; i < 300; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(old, 0);
    expect(
      tester.binding.hasScheduledFrame,
      isFalse,
      reason: 'waiting on scroll-end must not poll or schedule idle frames',
    );
    gate.run(scrolling, () => latest++);
    scrolling.value = false;
    await tester.pump();
    expect(old, 0);
    expect(latest, 1);
    scrolling.value = true;
    scrolling.value = false;
    await tester.pump();
    expect(latest, 1);
    gate.run(scrolling, () => latest++);
    gate.cancel();
    await tester.pump();
    expect(latest, 1, reason: 'disposed page must never receive a correction');
    scrolling.dispose();
  });
}
