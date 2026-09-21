import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/localized_app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'package:hermes_app/main.dart';
import 'package:hermes_app/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/features/chat/message_timeline.dart';
import 'package:hermes_app/models/message.dart';

void main() {
  testWidgets('unconfigured startup shows settings and hides key', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 2200);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ProviderScope(child: HermesApp()));
    // Default-en contract: a fresh install shows English regardless of
    // host language (no Chinese can leak into first-run UI).
    expect(find.text('Connect your Hermes'), findsOneWidget);
    expect(find.text('Test connection'), findsOneWidget);
    expect(
      tester.widgetList<TextField>(find.byType(TextField)).last.obscureText,
      isTrue,
    );
  });
  testWidgets('saved zh-Hant startup shows the Chinese settings page', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 2200);
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'ui.locale': 'zh-Hant'});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localStoreProvider.overrideWithValue(LocalStore(prefs)),
          initialLocaleProvider.overrideWithValue(AppLocale.zhHant),
        ],
        child: const HermesApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('連接你的 Hermes'), findsOneWidget);
    expect(find.text('測試連線'), findsOneWidget);
  });
  testWidgets(
    'unknown system text and hidden content do not leak into timeline',
    (tester) async {
      await tester.pumpWidget(
        localizedHome(
          locale: AppLocale.zhHant,
          home: const Scaffold(
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
