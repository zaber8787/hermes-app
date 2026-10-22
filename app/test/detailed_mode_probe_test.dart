// Detailed-mode render shape probe: field report 2026-10-22 says toggling
// detailed mode scrambles the whole app — never covered by a widget test.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_app/features/chat/message_timeline.dart';
import 'package:hermes_app/models/message.dart';

import 'support/localized_app.dart';

void main() {
  List<Message> messages() => [
    for (var i = 0; i < 30; i++)
      Message(
        id: 'm$i',
        role: i.isEven ? 'user' : 'assistant',
        content: '訊息 $i ${'內容' * 20}',
        timestamp: 1761100000 + i * 60,
        toolName: i % 5 == 0 ? 'terminal' : null,
        reasoning: i.isOdd ? '思考過程' * 12 : '',
      ),
  ];

  testWidgets('detailed timeline scrolls without throwing', (tester) async {
    await tester.pumpWidget(
      localizedApp(
        SizedBox(
          width: 400,
          height: 800,
          child: Material(
            child: CustomScrollView(
              slivers: [MessageTimelineSliver(messages: messages(), detailed: true)],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    final state = tester.state<ScrollableState>(find.byType(Scrollable).first);
    final max = state.position.maxScrollExtent;
    for (var off = 0.0; off <= max; off += 200) {
      state.position.jumpTo(off);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'at offset $off');
    }
  });

  testWidgets('flipping detailed on a settled timeline lays out cleanly', (
    tester,
  ) async {
    await tester.pumpWidget(
      localizedApp(
        SizedBox(
          width: 400,
          height: 800,
          child: Material(
            child: CustomScrollView(
              slivers: [MessageTimelineSliver(messages: messages(), detailed: false)],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // Flip the toggle mid-life — rows regroup between grouped and per-entry
    // shapes; extent memory and geometry caches must survive it.
    await tester.pumpWidget(
      localizedApp(
        SizedBox(
          width: 400,
          height: 800,
          child: Material(
            child: CustomScrollView(
              slivers: [MessageTimelineSliver(messages: messages(), detailed: true)],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final state = tester.state<ScrollableState>(find.byType(Scrollable).first);
    final max = state.position.maxScrollExtent;
    for (var off = 0.0; off <= max; off += 200) {
      state.position.jumpTo(off);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'at offset $off');
    }
  });
}
