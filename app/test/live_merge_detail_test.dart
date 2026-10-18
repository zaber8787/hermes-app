import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'package:hermes_app/l10n/message_key.dart';

import 'support/localized_app.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/providers.dart';

import 'audit_cross_device_sync_test.dart' show FakeSyncRepo;
import 'live_merge_group_test.dart' show durableMidRun, runOf;

/// Regression coverage for raw live tools with no durable transcript.
const q = '幫我整理這份報告的重點';

class MRepo extends FakeSyncRepo {
  @override
  Future<void> stop(String runId) async => stopCalls++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MRepo repo;
  late LocalStore store;
  late ProviderContainer container;
  final session = Session(
    id: 's',
    title: 'A',
    count: 0,
    startedAt: 0,
    activity: 0,
    source: 'api_server',
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repo = MRepo();
    store = LocalStore(await SharedPreferences.getInstance());
    container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        localStoreProvider.overrideWithValue(store),
        initialSettingsProvider.overrideWith(
          (ref) => const AppSettings(url: 'http://test.invalid', key: 'k'),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<void> openPage(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 12000);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedWrap(ChatPage(session: session), locale: AppLocale.en),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Future<void> sendUi(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
  }

  Future<void> closeAll(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await repo.events.close();
    await tester.pump();
  }

  for (final detailed in [false, true]) {
    testWidgets('live tools: no epoch timestamp (detailed=$detailed)', (
      tester,
    ) async {
      await store.setDetailed('http://test.invalid', 's', detailed);
      await openPage(tester);
      await sendUi(tester, q);
      repo.events.add(
        const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
      );
      for (var i = 1; i <= 3; i++) {
        repo.events.add(
          SseEvent(
            'tool.started',
            '{"tool_name":"t$i","args":{"i":$i},"seq":$i}',
          ),
        );
      }
      await tester.pump();
      if (!detailed) {
        await tester.tap(find.text(t(MessageKey.timelineM001, count: 3)));
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(
        tester
            .widgetList<Text>(find.byType(Text))
            .where((w) => (w.data ?? '').contains('1/1')),
        isEmpty,
      );
      for (var i = 1; i <= 3; i++) {
        expect(find.text('t$i'), findsOneWidget);
      }
      await closeAll(tester);
    });
  }

  testWidgets(
    're-entry mid-run (detailed ON, tools already durable): every step once',
    (tester) async {
      // The zaber symptom: open a session that is RUNNING right now with
      // detailed mode saved ON. Durable rows land first, live attaches after.
      await store.setDetailed('http://test.invalid', 's', true);
      repo.history = durableMidRun(4);
      await openPage(tester);
      repo.events.add(
        const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
      );
      for (var i = 1; i <= 4; i++) {
        repo.events.add(
          SseEvent(
            'tool.started',
            '{"tool_name":"t$i","args":{"i":$i},"seq":$i}',
          ),
        );
      }
      repo.active = [runOf(runId: 'r1', userText: q)];
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      for (var i = 1; i <= 4; i++) {
        expect(
          find.text('t$i').evaluate().length,
          1,
          reason: 'step t$i must render exactly once in detailed re-entry',
        );
      }
      expect(
        tester
            .widgetList<Text>(find.byType(Text))
            .where((t) => (t.data ?? '').contains('1/1')),
        isEmpty,
        reason: 'no epoch-time artifact on durable/live rows',
      );
      await closeAll(tester);
    },
  );
}
