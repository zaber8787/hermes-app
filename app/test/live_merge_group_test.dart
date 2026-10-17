import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'package:hermes_app/l10n/message_key.dart';

import 'support/localized_app.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/chat/chat_controller.dart'
    show ChatController;
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/providers.dart';

import 'audit_cross_device_sync_test.dart' show FakeSyncRepo;

/// LIVE-MERGE gate: while a run is in flight and PART of its steps are
/// already durable (sync landed mid-run), the timeline must present ONE
/// honest step-summary row for the run — not a durable M001 next to a
/// live M010. zaber flagged the double row twice; the old design
/// deliberately kept two "honest counts" cards (toolcard_dup T4) — that
/// decision is hereby reversed by the user.

const q = '幫我整理這份報告的重點';

class MRepo extends FakeSyncRepo {
  @override
  Future<void> stop(String runId) async => stopCalls++;
}

ActivityRun runOf({String? runId, String status = 'running', String? userText}) =>
    ActivityRun(
      observationId: 'o1',
      runId: runId,
      status: status,
      startedAt: 1,
      source: 'runs_api',
      user: userText == null ? null : ActivityUser(text: userText, afterId: null),
    );

/// Durable MID-run shape: user row + one assistant with n calls + result
/// rows — and NO final assistant row (the run is still going).
List<Message> durableMidRun(int n) {
  final calls = [for (var i = 1; i <= n; i++) ToolCall('C$i', 't$i', '{"i":$i}')];
  return [
    const Message(id: '1', role: 'user', content: '舊話', timestamp: 1),
    Message(id: '2', role: 'user', content: q, timestamp: 100),
    Message(id: '3', role: 'assistant', toolCalls: calls, timestamp: 100),
    for (var i = 1; i <= n; i++)
      Message(
        id: '${3 + i}',
        role: 'tool',
        toolCallId: 'C$i',
        toolName: 't$i',
        content: 'out$i',
        timestamp: 100,
      ),
  ];
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

  ChatController ctrl() => container.read(chatProvider('s'));

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

  /// Every rendered step-summary row, whichever key (M001/M010) carries
  /// it. This is the gate's assertion primitive: the run may show at most
  /// ONE such row at all times.
  int stepSummaryRows(WidgetTester tester) {
    // M001 and M010 resolve to the SAME localized string — dedupe by text,
    // else every rendered row counts twice.
    final strings = <String>{};
    for (final key in [MessageKey.timelineM001, MessageKey.timelineM010]) {
      for (var c = 1; c <= 12; c++) {
        strings.add(t(key, count: c));
      }
    }
    return tester.widgetList<Text>(find.byType(Text))
        .where((w) => strings.contains(w.data))
        .length;
  }

  Future<void> addStarted(WidgetTester tester, int i) async {
    repo.events.add(
      SseEvent(
        'tool.started',
        '{"tool_name":"t$i","args":{"i":$i},"seq":$i}',
      ),
    );
    await tester.pump();
  }

  /// Mid-run window: 2 steps durable (sync landed), live streaming the
  /// same 2 plus 2 new ones. Expect ONE summary row counting all 4.
  Future<void> midRunWindow(WidgetTester tester) async {
    repo.history = const [];
    await openPage(tester);
    await sendUi(tester, q);
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
    );
    await tester.pump();
    for (var i = 1; i <= 4; i++) {
      await addStarted(tester, i);
    }
    // now sync catches up mid-run: steps 1-2 already persisted
    repo.post(durableMidRun(2));
    repo.active = [runOf(runId: 'r1', userText: q)];
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(ctrl().live, isNotNull, reason: 'run still in flight');
  }

  testWidgets('mid-run partial durable: EXACTLY ONE step-summary row (count 4)', (
    tester,
  ) async {
    await midRunWindow(tester);
    expect(stepSummaryRows(tester), 1, reason: 'double row — the zaber bug');
    expect(find.text(t(MessageKey.timelineM001, count: 4)).evaluate().length, 1);
    await closeAll(tester);
  });

  testWidgets('the merged row grows honestly with each new step.started', (
    tester,
  ) async {
    await midRunWindow(tester);
    await addStarted(tester, 5);
    await tester.pump();
    expect(stepSummaryRows(tester), 1);
    expect(find.text(t(MessageKey.timelineM001, count: 5)).evaluate().length, 1);
    await closeAll(tester);
  });

  testWidgets('detailed toggle over the merged window shows every step once', (
    tester,
  ) async {
    await midRunWindow(tester);
    // The toolbar toggle shows short_text while collapsed (chat_page
    // 1588-1611: `c.detailed ? view_agenda : short_text`).
    final btn = find.byIcon(Icons.short_text).first;
    await tester.tap(btn);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(stepSummaryRows(tester), 0, reason: 'detailed lists steps flat');
    for (var i = 1; i <= 4; i++) {
      expect(
        find.text('t$i').evaluate().length,
        1,
        reason: 'step t$i rendered exactly once',
      );
    }
    await closeAll(tester);
  });
}
