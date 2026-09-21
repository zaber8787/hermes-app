import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hermes_app/main.dart';
import 'package:hermes_app/features/chat/message_timeline.dart';
import 'package:hermes_app/models/message.dart';

void main() {
  testWidgets('unconfigured startup shows settings and hides key', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: HermesApp()));
    expect(find.text('連接你的 Hermes'), findsOneWidget);
    expect(find.text('測試連線'), findsOneWidget);
    expect(
      tester.widgetList<TextField>(find.byType(TextField)).last.obscureText,
      isTrue,
    );
  });
  testWidgets(
    'unknown system text and hidden content do not leak into timeline',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MessageTimeline(
              detailed: true,
              messages: [
                Message(
                  id: '1',
                  role: 'assistant',
                  content: 'hidden secret',
                  displayKind: 'hidden',
                ),
                Message(
                  id: '2',
                  role: 'user',
                  content: 'future event content',
                  displayKind: 'new_kind',
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('hidden secret'), findsNothing);
      expect(find.text('future event content'), findsNothing);
      expect(find.text('系統事件'), findsOneWidget);
      await tester.tap(find.text('系統事件'));
      await tester.pumpAndSettle();
      expect(find.text('future event content'), findsOneWidget);
    },
  );
}
