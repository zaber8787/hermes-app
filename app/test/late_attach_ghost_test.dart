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

/// LATEATTACH: 「發起對話的那邊底下還是會出現上方已經完成過了的幽靈執行紀錄，
/// 重新整理後就好」.
///
/// The provisional `live-tools` row at the END of the timeline is built from
/// `live.tools` — everything THIS client has seen since it attached. A client
/// that attaches mid-run (page refresh, app reopened, another tab taking the
/// turn over) never receives the earlier steps' frames, so its live list is a
/// SUFFIX of the turn while the durable history carries the WHOLE turn.
///
/// Every ownership test in the fold compares durable-head against live-head
/// (RUNORDER path b = name prefix, LIVE-MERGE path L = ordered subsequence,
/// exit (a) = k > live length). A suffix fails all of them, the fold stands
/// down, and the live row re-renders steps that already sit in the timeline as
/// durable cards — a ghost pile under the real one. A reload clears it because
/// a reload drops `live` entirely, which is exactly the reported "refresh
/// fixes it".
///
/// The fix adds a count-based hand-back: up to min(durable tools in the turn,
/// COMPLETED live rows) live slots go back, always from the head, because
/// frames arrive in order so the completed prefix IS the landed prefix. Durable
/// cards are never hidden, so what disappears is bounded by the durable cards
/// already on screen — worst case a step goes briefly invisible until its own
/// durable row lands, never a lost record.

const q = '幫我看看這個';

class LGRepo extends FakeSyncRepo {
  @override
  Future<void> stop(String runId) async => stopCalls++;
}

ActivityRun runOf() => ActivityRun(
  observationId: 'o1',
  runId: 'r1',
  status: 'running',
  startedAt: 1,
  source: 'runs_api',
  user: ActivityUser(text: q, afterId: 1),
);

/// user(1) + this turn's user row(2) + n × (assistant carrying a call → tool
/// result row). Tool args are `{"i":<n>}` on the durable side.
List<Message> durableTurn(List<String> names) {
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
  late LGRepo repo;
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
    repo = LGRepo();
    store = LocalStore(await SharedPreferences.getInstance());
    await store.setDetailed('http://test.invalid', 's', true);
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

  Future<void> closeAll(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await repo.events.close();
    await tester.pump();
  }

  Future<void> sendAndStart(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField), q);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
    );
    await tester.pump();
  }

  Future<void> started(WidgetTester tester, String name, int arg) async {
    repo.events.add(
      SseEvent(
        'tool.started',
        '{"tool_name":"$name","args":{"i":$arg},"seq":$arg}',
      ),
    );
    await tester.pump();
  }

  Future<void> completed(WidgetTester tester, String name) async {
    repo.events.add(
      SseEvent('tool.completed', '{"tool_name":"$name","preview":"done"}'),
    );
    await tester.pump();
  }

  /// The observation poll now reports the run; durable rows land.
  Future<void> landDurable(WidgetTester tester, List<String> names) async {
    repo.post(durableTurn(names));
    repo.active = [runOf()];
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
  }

  int shown(WidgetTester tester, String name) =>
      find.text(name).evaluate().length;

  testWidgets(
    'a client that attached mid-run does not re-render the steps that '
    'already landed as durable cards',
    (tester) async {
      repo.history = const [];
      await openPage(tester);
      await sendAndStart(tester);
      // 'read_file' ran and landed BEFORE this client attached — its frames
      // are simply absent here. 'terminal' finished after attach, and a third
      // call is still in flight.
      await started(tester, 'terminal', 99);
      await completed(tester, 'terminal');
      await landDurable(tester, ['read_file', 'terminal']);
      await started(tester, 'web_search', 7);
      expect(
        ctrl().observedActivity?.activeRuns.map((r) => r.runId).toList(),
        ['r1'],
        reason: 'precondition: the run is observed and still in flight',
      );

      expect(
        shown(tester, 'terminal'),
        1,
        reason:
            'ghost: the durable terminal card PLUS a live copy at the bottom',
      );
      expect(
        shown(tester, 'read_file'),
        1,
        reason: 'never rendered twice from the live side',
      );
      expect(
        shown(tester, 'web_search'),
        1,
        reason: 'the in-flight step must stay visible while it runs',
      );
      await closeAll(tester);
    },
  );

  testWidgets(
    'nothing is handed back while no live step has finished (a live-only '
    'step is never swallowed)',
    (tester) async {
      repo.history = const [];
      await openPage(tester);
      await sendAndStart(tester);
      await landDurable(tester, ['read_file', 'terminal']);
      await started(tester, 'web_search', 7);
      await started(tester, 'browser', 8);

      expect(shown(tester, 'web_search'), 1);
      expect(shown(tester, 'browser'), 1);
      await closeAll(tester);
    },
  );
}
