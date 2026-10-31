import 'dart:convert';

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
import 'package:hermes_app/features/chat/live_merge_fold.dart';
import 'package:hermes_app/features/chat/live_turn.dart';
import 'package:hermes_app/features/chat/tool_timeline_projection.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/providers.dart';

import 'audit_cross_device_sync_test.dart' show FakeSyncRepo;

/// GHOSTRUN: on the sender device, mid-run, the timeline showed every
/// already-durable tool in place AND a second "executed" copy of them at
/// the bottom (the raw live-tools row). state.db had no duplicate ids, so
/// the copy came from the live side: the live-merge fold — the only thing
/// that lets the live row own the durable tail — was switched off.
///
/// Root cause: compat's activity `after_id` is the session's last message
/// id read BEFORE the run's user row is written (compat.py
/// `_activity_stream_register` → `_activity_last_id`), i.e. a watermark.
/// The fold demanded `afterId == anchor.id`, which never holds once the
/// observation poll lists the run (user row id = after_id + 1 or later).
/// Every existing fold fixture used `afterId: null`, so no test saw it.

const q = '幫我看這張圖';

class GRRepo extends FakeSyncRepo {
  @override
  Future<void> stop(String runId) async => stopCalls++;
}

ActivityRun runOf({required String runId, String? userText, int? afterId}) =>
    ActivityRun(
      observationId: 'o1',
      runId: runId,
      status: 'running',
      startedAt: 1,
      source: 'session_stream',
      user: ActivityUser(text: userText, afterId: afterId),
    );

LiveTurn liveOf(String runId, List<String> tools) {
  final l = LiveTurn()..runId = runId;
  for (final t in tools) {
    l.tools.add(LiveTool(t, '{"n":"$t"}'));
  }
  return l;
}

Message liveTailOf(LiveTurn l) => Message(
  id: 'live-tools',
  role: 'assistant',
  content: '',
  timestamp: 0,
  toolCalls: [
    for (var i = 0; i < l.tools.length; i++)
      ToolCall('live#$i', l.tools[i].name, l.tools[i].arguments),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('fold gate (unit)', () {
    final durable = [
      const Message(id: '1', role: 'user', content: '舊話', timestamp: 1),
      const Message(id: '2', role: 'user', content: q, timestamp: 2),
      const Message(
        id: '3',
        role: 'assistant',
        timestamp: 3,
        toolCalls: [ToolCall('C1', 'vision_analyze', '{"n":"vision_analyze"}')],
      ),
      const Message(
        id: '4',
        role: 'tool',
        toolCallId: 'C1',
        toolName: 'vision_analyze',
        content: 'a cat',
        timestamp: 4,
      ),
    ];

    Set<String> fold(List<ActivityRun> runs, {Message? own}) {
      final l = liveOf('r1', ['vision_analyze', 'terminal']);
      final p = projectToolOverlap(sessionId: 's', history: durable, live: l);
      return liveMergeFoldExclusions(
        live: l,
        activeRuns: runs,
        durableTail: durable,
        projection: p,
        liveTail: [liveTailOf(l)],
        ownAnchor: own,
      );
    }

    test('after_id watermark (last row before the user row) folds the tail', () {
      expect(
        fold([runOf(runId: 'r1', userText: q, afterId: 1)]),
        {'s#3#c0'},
        reason: 'activity lists the run with after_id=1, user row is 2',
      );
    });

    test('after_id at/after the anchor is not this run: no fold', () {
      expect(fold([runOf(runId: 'r1', userText: q, afterId: 2)]), isEmpty);
      expect(fold([runOf(runId: 'r1', userText: q, afterId: 9)]), isEmpty);
    });

    test('a second user row after the watermark breaks ownership', () {
      // after_id=0 → rows 1 and 2 are BOTH past the watermark: the run's
      // own user row is ambiguous, so the fold must stand down.
      expect(fold([runOf(runId: 'r1', userText: q, afterId: 0)]), isEmpty);
    });

    test('no after_id keeps the text rule; own-anchor path untouched', () {
      expect(fold([runOf(runId: 'r1', userText: q)]), {'s#3#c0'});
      expect(fold([runOf(runId: 'r1', userText: 'other')]), isEmpty);
      expect(fold(const [], own: durable[1]), {'s#3#c0'});
    });
  });

  group('widget', () {
    late GRRepo repo;
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
      repo = GRRepo();
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

    List<String> toolTexts(WidgetTester tester, RegExp pat) => tester
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .where(pat.hasMatch)
        .toList();

    testWidgets(
      'GHOSTRUN R1: own turn in flight, activity lists run (after_id '
      'watermark), durable tail landed: each tool renders once',
      (tester) async {
        await store.setDetailed('http://test.invalid', 's', true);
        final ts0 = DateTime.now().millisecondsSinceEpoch / 1000.0 - 60;
        repo.history = [
          Message(id: '1', role: 'user', content: '舊話', timestamp: ts0),
        ];
        repo.revCount = repo.revLatest = 1;
        await openPage(tester);
        await sendUi(tester, q);
        repo.events.add(
          const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
        );
        await tester.pump();
        for (final n in ['vision_analyze', 'terminal']) {
          repo.events.add(
            SseEvent('tool.started', '{"tool_name":"$n","args":{"n":"$n"}}'),
          );
          await tester.pump();
        }
        repo.events.add(
          const SseEvent(
            'tool.completed',
            '{"tool_name":"vision_analyze","preview":"a cat"}',
          ),
        );
        await tester.pump();
        final ts = DateTime.now().millisecondsSinceEpoch / 1000.0;
        repo.active = [runOf(runId: 'r1', userText: q, afterId: 1)];
        repo.post([
          Message(id: '2', role: 'user', content: q, timestamp: ts),
          Message(
            id: '3',
            role: 'assistant',
            timestamp: ts,
            toolCalls: [
              ToolCall('C1', 'vision_analyze', '{"n":"vision_analyze"}'),
            ],
          ),
          Message(
            id: '4',
            role: 'tool',
            toolCallId: 'C1',
            toolName: 'vision_analyze',
            content: 'a cat',
            timestamp: ts,
          ),
        ]);
        await tester.pump(const Duration(seconds: 6));
        await tester.pump();
        expect(
          ctrl().observedActivity?.activeRuns.map((r) => r.runId).toList(),
          ['r1'],
          reason: 'precondition: the observation poll lists the run',
        );
        expect(
          find.text('vision_analyze').evaluate().length,
          1,
          reason: 'ghost: durable vision_analyze + live copy at the bottom',
        );
        expect(find.text('terminal').evaluate().length, 1);
        await closeAll(tester);
      },
    );

    testWidgets(
      'GHOSTRUN R3: 5 tools back-to-back + turn settles: exactly 5 rows, '
      'execution order, nothing appended at the bottom',
      (tester) async {
        await store.setDetailed('http://test.invalid', 's', true);
        final ts0 = DateTime.now().millisecondsSinceEpoch / 1000.0 - 60;
        repo.history = [
          Message(id: '1', role: 'user', content: '舊話', timestamp: ts0),
        ];
        repo.revCount = repo.revLatest = 1;
        await openPage(tester);
        await sendUi(tester, q);
        repo.events.add(
          const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
        );
        await tester.pump();
        final names = [for (var i = 1; i <= 5; i++) 'step$i'];
        final pat = RegExp(r'^step\d$');
        final ts = DateTime.now().millisecondsSinceEpoch / 1000.0;
        Message call(int i) => Message(
          id: '${1 + 2 * i}',
          role: 'assistant',
          timestamp: ts,
          toolCalls: [ToolCall('C$i', 'step$i', '{"n":"step$i"}')],
        );
        Message result(int i) => Message(
          id: '${2 + 2 * i}',
          role: 'tool',
          toolCallId: 'C$i',
          toolName: 'step$i',
          content: 'out$i',
          timestamp: ts,
        );

        void expectFive(String when) {
          final shown = toolTexts(tester, pat);
          expect(shown, names, reason: '$when: rows = execution order, once');
          final ys = [
            for (final n in names) tester.getTopLeft(find.text(n)).dy,
          ];
          for (var i = 1; i < ys.length; i++) {
            expect(ys[i - 1] < ys[i], isTrue, reason: '$when: ${names[i]}');
          }
        }

        for (final n in names) {
          repo.events.add(
            SseEvent('tool.started', '{"tool_name":"$n","args":{"n":"$n"}}'),
          );
          await tester.pump();
          repo.events.add(
            SseEvent('tool.completed', '{"tool_name":"$n","preview":"out"}'),
          );
          await tester.pump();
        }
        // Mid-run: the run is listed and the first 3 steps are durable.
        repo.active = [runOf(runId: 'r1', userText: q, afterId: 1)];
        repo.post([
          Message(id: '2', role: 'user', content: q, timestamp: ts),
          for (var i = 1; i <= 3; i++) ...[call(i), result(i)],
        ]);
        await tester.pump(const Duration(seconds: 6));
        await tester.pump();
        expect(ctrl().observedActivity?.activeRuns.length, 1);
        expectFive('mid-run, 3 durable');

        // All 5 durable, still running.
        repo.post([
          for (var i = 4; i <= 5; i++) ...[call(i), result(i)],
        ]);
        await tester.pump(const Duration(seconds: 6));
        await tester.pump();
        expectFive('mid-run, 5 durable');

        // Turn settles: terminal frame with the transcript, final reply.
        final transcript = [
          {'role': 'user', 'content': q},
          for (var i = 1; i <= 5; i++) ...[
            {
              'role': 'assistant',
              'content': '',
              'tool_calls': [
                {
                  'id': 'C$i',
                  'function': {'name': 'step$i', 'arguments': '{"n":"step$i"}'},
                },
              ],
            },
            {
              'role': 'tool',
              'tool_call_id': 'C$i',
              'tool_name': 'step$i',
              'content': 'out$i',
            },
          ],
          {'role': 'assistant', 'content': 'done'},
        ];
        repo.events.add(
          SseEvent(
            'run.completed',
            jsonEncode({
              'run_id': 'r1',
              'session_id': 's',
              'messages': transcript,
            }),
          ),
        );
        repo.active = [];
        repo.post([
          Message(id: '13', role: 'assistant', content: 'done', timestamp: ts),
        ]);
        await tester.pump();
        expectFive('terminal frame');
        await tester.pump(const Duration(seconds: 6));
        await tester.pump();
        expectFive('settled');
        await closeAll(tester);
      },
    );
  });
}
