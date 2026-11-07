import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'package:hermes_app/l10n/message_key.dart';

import 'support/localized_app.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/data/gateway_ws.dart';
import 'package:hermes_app/data/ws_route.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/chat/chat_controller.dart'
    show ChatController;
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/providers.dart';

import 'audit_cross_device_sync_test.dart' show FakeSyncRepo;

/// RUNORDER: mid-run on the web surface the group rendered EVERY thinking
/// line first and ALL tool cards after them ("5 steps": 5 narration rows,
/// then 5 cards). Root cause: the live fold excluded the whole durable tail
/// past the anchor (live_merge_fold.dart:61 at the HEAD this test was
/// written against) while chat_page.dart appended one synthetic row with
/// the run's ENTIRE live tool list after `messages`. Durable cards moved to
/// the bottom, narration stayed put.
///
/// The fix keeps durable cards in place and drops only the FIRST k live
/// rows (k = durable tools past the anchor), so narration and execution
/// interleave again. These tests read the ORDER of children inside the
/// collapsed step-summary group — the only place the bug was visible
/// (detailed mode never builds a group: message_timeline.dart:225).

const q = '幫我整理這份報告的重點';

class RORepo extends FakeSyncRepo {
  @override
  Future<void> stop(String runId) async => stopCalls++;
}

ActivityRun runOf({String? runId, String? userText}) => ActivityRun(
  observationId: 'o1',
  runId: runId,
  status: 'running',
  startedAt: 1,
  source: 'runs_api',
  user: userText == null ? null : ActivityUser(text: userText, afterId: null),
);

/// Interleaved durable shape: user + n × (assistant WITH narration text and
/// reasoning, one call → result row). R6: a fixture without assistant text
/// or reasoning projects NO narration entry, and the bug is invisible then.
List<Message> durablePairs(List<String> names) {
  final ts = DateTime.now().millisecondsSinceEpoch / 1000.0 - 120;
  return [
    Message(id: '1', role: 'user', content: '舊話', timestamp: ts - 100),
    Message(id: '2', role: 'user', content: q, timestamp: ts),
    for (var i = 1; i <= names.length; i++) ...[
      Message(
        id: '${1 + 2 * i}',
        role: 'assistant',
        content: 'n$i',
        reasoning: 'r$i',
        toolCalls: [ToolCall('C$i', names[i - 1], '{"i":$i}')],
        timestamp: ts,
      ),
      Message(
        id: '${2 + 2 * i}',
        role: 'tool',
        toolCallId: 'C$i',
        toolName: names[i - 1],
        content: 'out$i',
        timestamp: ts,
      ),
    ],
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RORepo repo;
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
    repo = RORepo();
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

  Future<void> addStarted(WidgetTester tester, String name, int i) async {
    repo.events.add(
      SseEvent(
        'tool.started',
        '{"tool_name":"$name","args":{"i":$i},"seq":$i}',
      ),
    );
    await tester.pump();
  }

  /// The window under test: send, run.started, the live tools stream in,
  /// then the first k durable pairs land mid-run.
  Future<void> midRun(
    WidgetTester tester, {
    required List<String> live,
    required List<String> durable,
  }) async {
    repo.history = const [];
    await openPage(tester);
    await sendUi(tester, q);
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
    );
    await tester.pump();
    for (var i = 1; i <= live.length; i++) {
      await addStarted(tester, live[i - 1], i);
    }
    repo.post(durablePairs(durable));
    repo.active = [runOf(runId: 'r1', userText: q)];
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(ctrl().live, isNotNull, reason: 'run still in flight');
  }

  /// Group titles are the only place a count appears; collapsed groups do
  /// not build their children (no maintainState on the ExpansionTile), so
  /// every positional assertion is preceded by opening the group.
  Future<void> openGroup(WidgetTester tester, int steps) async {
    await tester.tap(find.text(t(MessageKey.timelineM001, count: steps)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Rendered rows inside the open group, in visual order, labelled 'N'
  /// (the narration header, timelineM008) and 'T' (a tool card by name).
  String childOrder(WidgetTester tester, RegExp tools) {
    final cells = <(double, String)>[];
    for (final w in tester.widgetList<Text>(find.byType(Text))) {
      final d = w.data ?? '';
      if (d == t(MessageKey.timelineM008)) {
        cells.add((tester.getTopLeft(find.byWidget(w)).dy, 'N'));
      } else if (tools.hasMatch(d) && d != q) {
        cells.add((tester.getTopLeft(find.byWidget(w)).dy, 'T'));
      }
    }
    cells.sort((a, b) => a.$1.compareTo(b.$1));
    return cells.map((c) => c.$2).join();
  }

  testWidgets(
    'RUNORDER A: 3 durable pairs + 3 live tools — the group alternates '
    'narration/tool instead of stacking every card last',
    (tester) async {
      await midRun(
        tester,
        live: ['t1', 't2', 't3'],
        durable: ['t1', 't2', 't3'],
      );
      expect(find.text(t(MessageKey.timelineM001, count: 3)).evaluate().length, 1);
      await openGroup(tester, 3);
      expect(
        childOrder(tester, RegExp(r'^t\d$')),
        'NTNTNT',
        reason: 'the zaber bug: narration all first, tools all last (NNNTTT)',
      );
      await closeAll(tester);
    },
  );

  testWidgets(
    'RUNORDER B: durable 3 + live 5 — five steps, and the first durable '
    'tool still sits above the LAST narration',
    (tester) async {
      await midRun(
        tester,
        live: ['t1', 't2', 't3', 't4', 't5'],
        durable: ['t1', 't2', 't3'],
      );
      expect(find.text(t(MessageKey.timelineM001, count: 5)).evaluate().length, 1);
      await openGroup(tester, 5);
      for (var i = 1; i <= 5; i++) {
        expect(find.text('t$i').evaluate().length, 1, reason: 'step t$i twice');
      }
      final ys = [
        for (var i = 1; i <= 5; i++) tester.getTopLeft(find.text('t$i')).dy,
      ];
      for (var i = 1; i < ys.length; i++) {
        expect(ys[i - 1] < ys[i], isTrue, reason: 't$i out of order');
      }
      var lastNarration = 0.0;
      for (final w in tester.widgetList<Text>(find.byType(Text))) {
        if ((w.data ?? '') == t(MessageKey.timelineM008)) {
          final y = tester.getTopLeft(find.byWidget(w)).dy;
          if (y > lastNarration) lastNarration = y;
        }
      }
      expect(
        ys.first < lastNarration,
        isTrue,
        reason: 't1 was pushed below all thinking — the bug',
      );
      await closeAll(tester);
    },
  );

  testWidgets(
    'RUNORDER E1: the live stream missed a durable step — the fold stands '
    'down (k > live.tools.length) and NOTHING is swallowed',
    (tester) async {
      await store.setDetailed('http://test.invalid', 's', true);
      await midRun(
        tester,
        live: ['t1', 't2'],
        durable: ['t1', 't2', 't3'],
      );
      expect(
        find.text('t3').evaluate().length,
        1,
        reason: 'a durable step the live list never carried must still show',
      );
      expect(
        find.text('t1').evaluate().length,
        2,
        reason: 'no evidence to pair → BOTH render (a duplicated step is safe)',
      );
      await closeAll(tester);
    },
  );

  testWidgets(
    'RUNORDER E2: names disagree with the durable side — the fold stands '
    'down instead of hiding the durable steps',
    (tester) async {
      await store.setDetailed('http://test.invalid', 's', true);
      await midRun(
        tester,
        live: ['x1', 'x2', 'x3'],
        durable: ['t1', 't2', 't3'],
      );
      expect(find.text('t1').evaluate().length, 1);
      expect(find.text('x1').evaluate().length, 1);
      await closeAll(tester);
    },
  );

  testWidgets(
    'RUNORDER WS-GAP: the WS lane never yields run.started, so the fold '
    'gate cannot open and BOTH copies render. KNOWN GAP: a later '
    'RUNROUTE/RUNLIVENESS ticket gives the WS path run identity and will '
    'REVERSE this assertion — do not weaken it here and do not skip it.',
    (tester) async {
      await store.setDetailed('http://test.invalid', 's', true);
      repo.history = const [];
      await openPage(tester);
      await sendUi(tester, q);
      // The frame exactly as the WS router projects it — ws_route.dart
      // yields message.started/run.queued/heartbeat and never a run.started,
      // so LiveTurn.runId (set only by 'run.started', live_turn.dart:89-90)
      // stays null for the whole turn.
      repo.events.add(
        wsEventToSse(
          const WsEvent(
            type: 'tool.start',
            sessionId: 's',
            payload: {'tool_name': 't1', 'args': {'i': 1}},
          ),
          's',
          'm1',
        ).single,
      );
      await tester.pump();
      expect(
        ctrl().live?.runId,
        isNull,
        reason: 'precondition: the WS lane carries no run identity',
      );
      repo.post(durablePairs(['t1']));
      repo.active = [runOf(runId: 'r1', userText: q)];
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(find.text('t1').evaluate().length, 2);
      await closeAll(tester);
    },
  );
}
