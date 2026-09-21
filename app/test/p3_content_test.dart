import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'support/localized_app.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:hermes_app/features/chat/message_content.dart';
import 'package:hermes_app/features/chat/message_timeline.dart';
import 'package:hermes_app/models/message.dart';

void main() {
  test('timestamps use local same-day clock and month/day for older dates', () {
    final now = DateTime(2026, 9, 11, 18);
    double epoch(DateTime d) => d.millisecondsSinceEpoch / 1000;
    expect(
      formatMessageTimestamp(epoch(DateTime(2026, 9, 11, 9, 5)), now: now),
      '09:05',
    );
    expect(
      formatMessageTimestamp(epoch(DateTime(2026, 9, 10, 23, 59)), now: now),
      '9/10 23:59',
    );
    expect(
      formatMessageTimestamp(epoch(DateTime(2025, 9, 11, 9, 5)), now: now),
      '9/11 09:05',
    );
    expect(formatMessageTimestamp(0, now: now), '');
    expect(formatMessageTimestamp(double.nan), '');
  });
  test('MEDIA and attachment receipts split into typed content blocks', () {
    final parts = splitMessageContent(
      'hello\nMEDIA:"/server/a b.pdf"\nMEDIA:https://test/image.png?q=1\n[附件: ${'a' * 32} report.pdf]',
    );
    final media = parts.where((p) => p.media).toList();
    expect(media.map((p) => p.value), [
      '/server/a b.pdf',
      'https://test/image.png?q=1',
      'a' * 32,
    ]);
    expect(media.last.filename, 'report.pdf');
    expect(isImageReference(media[1].value), isTrue);
    expect(isImageReference('/server/image.png'), isFalse);
  });
  test('server MEDIA paths are download-eligible, other refs are not', () {
    expect(looksLikeServerPath('/server/a b.pdf'), isTrue);
    expect(looksLikeServerPath(r'C:\Users\me\file.pdf'), isTrue);
    expect(looksLikeServerPath('https://test/image.png'), isFalse);
    expect(looksLikeServerPath('relative/file.pdf'), isFalse);
    expect(looksLikeServerPath('a' * 32), isFalse);
  });
  testWidgets('user and final markdown, code copy, and timestamp smoke', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    await tester.pumpWidget(
      ProviderScope(
        child: localizedHome(
          locale: AppLocale.zhHant,
          home: Scaffold(
            body: SingleChildScrollView(
              child: MessageTimeline(
                detailed: true,
                messages: [
                  Message(
                    id: '1',
                    role: 'user',
                    content: '**bold**',
                    timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
                  ),
                  const Message(
                    id: '2',
                    role: 'assistant',
                    content: '# Heading\n```dart\nprint(42);\n```',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(GptMarkdown), findsNWidgets(2));
    expect(find.byType(MessageTime), findsNWidgets(2));
    await tester.tap(find.byTooltip('複製程式碼'));
    expect(copied, contains('print(42);'));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });
  testWidgets('server path renders as downloadable attachment; no raw MEDIA token', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: localizedHome(
          locale: AppLocale.zhHant,
          home: Scaffold(body: MessageContent('MEDIA:/server/report.pdf')),
        ),
      ),
    );
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('從伺服器下載'), findsOneWidget);
    expect(find.byTooltip('下載附件'), findsOneWidget);
    expect(find.textContaining('MEDIA:'), findsNothing);
  });
  testWidgets(
    'data image opens full screen and malformed data degrades gracefully',
    (tester) async {
      const pixel =
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=';
      await tester.pumpWidget(
        ProviderScope(
          child: localizedHome(
          locale: AppLocale.zhHant,
            home: Scaffold(body: MessageContent('![image]($pixel)')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MessageImage), findsOneWidget);
      await tester.tap(find.byType(MessageImage));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await tester.pumpWidget(
        localizedHome(
          locale: AppLocale.zhHant,
          home: Scaffold(body: MessageImage('data:image/png;base64,%%%')),
        ),
      );
      expect(find.text('圖片資料無效'), findsOneWidget);
    },
  );
}
