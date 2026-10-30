
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/l10n/app_locale.dart';

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
  final ts = DateTime.now().millisecondsSinceEpoch / 1000.0 - 120;
  final calls = [for (var i = 1; i <= n; i++) ToolCall('C$i', 't$i', '{"i":$i}')];
  return [
    Message(id: '1', role: 'user', content: '舊話', timestamp: ts - 100),
    Message(id: '2', role: 'user', content: q, timestamp: ts),
    Message(id: '3', role: 'assistant', toolCalls: calls, timestamp: ts),
    for (var i = 1; i <= n; i++)
      Message(
        id: '${3 + i}',
        role: 'tool',
        toolCallId: 'C$i',
        toolName: 't$i',
        content: 'out$i',
        timestamp: ts,
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


  testWidgets('TIMELINEDUP: durable terminal + live [skill_view, terminal] renders each step once, in order', (tester) async {
    await store.setDetailed('http://test.invalid', 's', true);
    repo.history = const [];
    await openPage(tester);
    await sendUi(tester, q);
    repo.events.add(const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'));
    await tester.pump();
    for (final n in ['skill_view', 'terminal']) {
      repo.events.add(SseEvent('tool.started', '{"tool_name":"$n","args":{"n":"$n"}}'));
      await tester.pump();
    }
    final ts = DateTime.now().millisecondsSinceEpoch / 1000.0;
    repo.post([
      Message(id: '1', role: 'user', content: q, timestamp: ts),
      Message(id: '2', role: 'assistant', timestamp: ts, toolCalls: [ToolCall('C2', 'terminal', '{"n":"terminal"}')]),
      Message(id: '3', role: 'tool', toolCallId: 'C2', toolName: 'terminal', content: 'ok', timestamp: ts),
    ]);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(find.text('terminal').evaluate().length, 1, reason: 'terminal duplicated');
    expect(find.text('skill_view').evaluate().length, 1);
    final sy = tester.getTopLeft(find.text('skill_view')).dy;
    final ty = tester.getTopLeft(find.text('terminal')).dy;
    expect(sy < ty, isTrue, reason: 'skill_view ran first, must be above terminal');
    await closeAll(tester);
  });

  testWidgets('TIMELINEDUP: long stream (>200 steps), durable prefix landed, each step once', (tester) async {
    await store.setDetailed('http://test.invalid', 's', true);
    repo.history = const [];
    await openPage(tester);
    await sendUi(tester, q);
    repo.events.add(const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'));
    await tester.pump();
    const n = 230;
    for (var i = 1; i <= n; i++) {
      repo.events.add(SseEvent('tool.started', '{"tool_name":"s$i","args":{"i":$i}}'));
    }
    await tester.pump();
    final ts = DateTime.now().millisecondsSinceEpoch / 1000.0;
    repo.post([
      Message(id: '1', role: 'user', content: q, timestamp: ts),
      Message(id: '2', role: 'assistant', timestamp: ts, toolCalls: [
        for (var i = 1; i <= 205; i++) ToolCall('C$i', 's$i', '{"i":$i}'),
      ]),
    ]);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(ctrl().live!.tools.length, n);
    final shown = tester.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? '').where((d) => RegExp(r'^s\d+$').hasMatch(d)).toList();
    expect(shown.length, shown.toSet().length, reason: 'a step rendered twice');
    await closeAll(tester);
  });

  test('TIMELINEDUP: mergeMessages dedups by id and keeps execution order for out-of-order pages', () {
    Message m(String id, double ts) => Message(id: id, role: 'assistant', content: 'x$id', timestamp: ts);
    final merged = mergeMessages([m('3', 3), m('1', 1)], [m('2', 2), m('3', 3), m('1', 1)]);
    expect(merged.map((e) => e.id).toList(), ['1', '2', '3']);
  });
}
