// DETAIL-BLACKOUT (field report 2026-10-24): a long history opened in
// DETAILED mode could park the viewport at the bottom of pure placeholder
// arithmetic with no real row ever materializing — “the whole render is
// broken”: header and composer paint, the conversation area is black.
//
// Root-cause family pinned by this suite:
//  1. _MeasuredRowDelegate.estimateMaxScrollOffset must GROW with
//     lastIndex (monotone) — non-monotone forms poison the framework's
//     index→offset probing and can stop layout before the tail exists.
//  2. the cold-open landing may not settle on a landing band that is 100%
//     placeholders; the real floor must stream upward (a chunk per tick)
//     until real rows are under the reader.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_app/features/chat/message_timeline.dart';
import 'package:hermes_app/models/message.dart';

import 'support/localized_app.dart';

Message longMsg(int i) => Message(
      id: 'm$i',
      role: i.isEven ? 'user' : 'assistant',
      // English prose renders MUCH shorter per char than the placeholder
      // estimate scale assumes — the scale mismatch is the whole hazard
      // this suite guards (the field session is hundreds of turns deep).
      content: 'Entry $i. ${'the quick brown fox jumps over the lazy dog ' * 150}',
      timestamp: 1761100000 + i * 60,
      toolName: i % 5 == 0 ? 'terminal' : null,
    );

void main() {
  testWidgets('detailed cold-open over a scale-mismatched history lands on REAL rows',
      (tester) async {
    final msgs = [for (var i = 0; i < 120; i++) longMsg(i)];
    await tester.pumpWidget(localizedApp(
      SizedBox(
        width: 400,
        height: 800,
        child: Material(
          child: CustomScrollView(
            slivers: [MessageTimelineSliver(messages: msgs, detailed: true)],
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    final state = tester.state<ScrollableState>(find.byType(Scrollable).first);
    // Park at the bottom — the cold-open landing position.
    state.position.jumpTo(state.position.maxScrollExtent);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);
    // The page must NOT be a black placeholder field: at least one REAL
    // row box must intersect the viewport.
    var inViewport = 0;
    for (final el in find.byType(EntryView).evaluate()) {
      final b = el.renderObject;
      if (b is! RenderBox || !b.attached) continue;
      final dy = b.localToGlobal(Offset.zero).dy;
      if (dy < 799 && dy + b.size.height > 1) inViewport++;
    }
    expect(inViewport, greaterThan(0),
        reason: 'cold-open must land on real content, not placeholders');
  });
}
