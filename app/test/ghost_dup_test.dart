import 'dart:async';
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
import 'package:hermes_app/features/chat/copy_actions.dart'
    show CopyMenuButton;
import 'package:hermes_app/features/chat/message_content.dart'
    show formatMessageTimestamp;
import 'package:hermes_app/features/chat/message_timeline.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/providers.dart';

import 'audit_cross_device_sync_test.dart' show FakeSyncRepo;

/// GHOST-DUP regressions (GHOST-DUP-PLAN C1): a locally sent turn must never
/// render a SECOND user bubble while it runs. Identity axes are the EntryView
/// ids themselves — durable numeric, `pending`, `remote:epoch:observation` —
/// never icons or text heuristics (plan B4). Every case drives the REAL
/// call-site (page, timers, SSE frames); no test-side manual refresh, no
/// notify, no projection poke.

const q = '幫我整理這份報告的重點';

class GRepo extends FakeSyncRepo {
  int stopCalls = 0;

  /// When set, every LATEST-page history GET waits on this future
  /// (listener-hole rigs).
  Completer<List<Message>>? historyGate;

  /// When set, older-page GETs (loadOlder) return these rows.
  List<Message>? olderPage;

  @override
  Future<List<Message>> messages(
    String sid, {
      int offset = 0,
      int limit = 200,
    }) {
    if (offset > 0 && olderPage != null) {
      historyReads++;
      return Future.value(olderPage);
    }
    final g = historyGate;
    if (g == null) return super.messages(sid, offset: offset, limit: limit);
    historyReads++;
    return g.future;
  }

  @override
  Future<void> stop(String runId) async {
    stopCalls++; // a display fix must never POST chat/stop (C1)
  }

  int statusCalls = 0;
  @override
  Future<Json> runStatus(String runId) async {
    statusCalls++;
    return {'run_id': runId, 'status': 'running'};
  }
}

/// The app compares observation.startedAt against real wall time
/// (DateTime.now in the controller), so the fixture stamps it the same way.
double nowSec(WidgetTester _) => DateTime.now().millisecondsSinceEpoch / 1000;

ActivityRun runOf({
  String obs = 'o1',
  String? runId,
  String status = 'running',
  String? userText,
  int? afterId,
  double startedAt = 1,
  String source = 'runs_api',
}) => ActivityRun(
  observationId: obs,
  runId: runId,
  status: status,
  startedAt: startedAt,
  source: source,
  user: userText == null
      ? null
      : ActivityUser(text: userText, afterId: afterId),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GRepo repo;
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
    repo = GRepo();
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
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedWrap(
          ChatPage(session: session),
          locale: AppLocale.zhHant,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Future<void> sendUi(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump(); // the send button re-enables on the rebuilt frame
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump(); // busy state is observable before the first await
  }

  /// The GHOST-DUP assertion primitive: WHICH renderer draws each user
  /// bubble — durable ids, `pending`, or `remote:epoch:obs` (plan B4).
  List<String> userIds(WidgetTester tester) =>
      tester
          .widgetList<EntryView>(find.byType(EntryView))
          .where((e) => e.entry.kind == EntryKind.user)
          .map((e) => e.entry.message.id)
          .toList();

  group('Phase 1 — claim ledger is idempotent (B2)', () {
    testWidgets('R3 an active claim survives repeated identical ticks', (
      tester,
    ) async {
      repo.history = [
        const Message(id: '1', role: 'user', content: '舊話'),
        const Message(id: '2', role: 'user', content: q),
      ];
      repo.revCount = 2;
      repo.revLatest = 2;
      repo.active = [runOf(runId: 'runX', userText: q, afterId: 1)];
      await openPage(tester);
      expect(userIds(tester), ['1', '2']); // claim retires the preview
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 6));
        expect(
          userIds(tester),
          ['1', '2'],
          reason: 'tick $i: a settled claim must never respawn a preview',
        );
      }
      expect(ctrl().remoteRows, isEmpty);
    });

    testWidgets('R6 a claimed observation never re-takes another row; old '
        'same-text turns stay visible', (tester) async {
      repo.history = [
        const Message(id: '1', role: 'user', content: q), // older same-text
        const Message(id: '2', role: 'user', content: q),
      ];
      repo.revCount = 2;
      repo.revLatest = 2;
      repo.active = [
        runOf(obs: 'o1', runId: 'rA', userText: q, afterId: 1, startedAt: 1),
      ];
      await openPage(tester);
      expect(userIds(tester), ['1', '2']); // o1 owns row 2; row 1 stays
      // A second turn arrives: new observation AND a new durable row.
      repo.history = [
        ...repo.history,
        const Message(id: '3', role: 'user', content: q),
      ];
      repo.revCount = 3;
      repo.revLatest = 3;
      repo.active = [
        runOf(obs: 'o1', runId: 'rA', userText: q, afterId: 1, startedAt: 1),
        runOf(obs: 'o2', runId: 'rB', userText: q, afterId: 2, startedAt: 2),
      ];
      await tester.pump(const Duration(seconds: 6));
      expect(
        userIds(tester),
        ['1', '2', '3'],
        reason: 'o1 keeps row 2, o2 claims row 3, no preview, no stealing',
      );
    });

    testWidgets('R8 a claim stands when its row leaves the loaded window', (
      tester,
    ) async {
      repo.history = [
        const Message(id: '1', role: 'user', content: '舊話'),
        const Message(id: '2', role: 'user', content: q),
      ];
      repo.revCount = 2;
      repo.revLatest = 2;
      repo.active = [runOf(runId: 'runX', userText: q, afterId: 1)];
      await openPage(tester);
      expect(userIds(tester), ['1', '2']);
      // Compaction: the claimed row leaves the 200-row window; revision moves.
      repo.history = [const Message(id: '1', role: 'user', content: '舊話')];
      repo.revCount = 3;
      repo.revLatest = 2;
      await tester.pump(const Duration(seconds: 6));
      expect(
        userIds(tester),
        ['1'],
        reason: 'gone from the window is not "never persisted" (B2)',
      );
      expect(repo.stopCalls, 0);
    });
  });

  /// C1 discipline: a test that ends mid-run must unmount the page, close
  /// the fake stream and dispose the controller BEFORE the teardown check
  /// (a running turn keeps lease/silence timers alive by contract).
  Future<void> closeAll(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose(); // provider family -> controller.dispose()
    await repo.events.close(); // now safely drained: turn already retired
    await tester.pump();
  }

  group('Phase 1 — identity retire on the same tick (B3 refresh)', () {
    testWidgets('R2a run.started retires the local preview immediately, '
        'with no extra activity/history tick', (tester) async {
      repo.history = [];
      await openPage(tester);
      await sendUi(tester, q);
      expect(userIds(tester), ['pending']);
      // The run shows up in activity BEFORE run.started names it — the
      // plan §A3 race: identity unknown, so the filter cannot exclude it.
      repo.active = [runOf(obs: 'oL', runId: 'rLocal', userText: q)];
      await tester.pump(const Duration(seconds: 6));
      expect(
        userIds(tester),
        containsAllInOrder(['remote:e1:oL', 'pending']),
        reason: 'reproduction: the incident shape (remote twin + pending)',
      );
      // Identity lands. The NEXT FRAME must drop the ghost — no tick needed.
      repo.events.add(
        const SseEvent('run.started', '{"run_id":"rLocal","session_id":"s"}'),
      );
      await tester.pump();
      await tester.pump();
      expect(userIds(tester), ['pending']);
      expect(ctrl().remoteRows, isEmpty);
      expect(repo.chatCalls, 1); // display-only fix: no second POST
      await closeAll(tester);
    });
  });

  group('Phase 2 — history commits publish projections together (B1)', () {
    testWidgets('R1 local send, run confirmed, history already carries the '
        'row: exactly ONE user entry, still sending', (tester) async {
      repo.history = [];
      await openPage(tester);
      await sendUi(tester, q);
      repo.events.add(
        const SseEvent('run.started', '{"run_id":"rLocal","session_id":"s"}'),
      );
      await tester.pump();
      repo.post([Message(id: '2', role: 'user', content: q)]);
      repo.active = [runOf(obs: 'oL', runId: 'rLocal', userText: q)];
      await tester.pump(const Duration(seconds: 6)); // tick: rev moved, GET
      await tester.pump(); // the commit frame (B1: must be published NOW)
      expect(userIds(tester), ['2']);
      expect(ctrl().busy, isTrue);
      expect(repo.chatCalls, 1);
      await tester.pump(const Duration(seconds: 6));
      expect(userIds(tester), ['2']);
      await closeAll(tester);
    });

    testWidgets('R2b listener hole: the history GET landing repaints by '
        'itself — no tick, no SSE, no manual notify', (tester) async {
      repo.history = [];
      await openPage(tester);
      await sendUi(tester, q);
      repo.events.add(
        const SseEvent('run.started', '{"run_id":"rLocal","session_id":"s"}'),
      );
      await tester.pump();
      await tester.pump();
      repo.history = [Message(id: '2', role: 'user', content: q)];
      repo.revCount = 1;
      repo.revLatest = 1;
      final gate = Completer<List<Message>>();
      repo.historyGate = gate;
      await tester.pump(const Duration(seconds: 6)); // revision tick: notify
      await tester.pump(); // one stale frame — the GET is still pending
      expect(userIds(tester), ['pending']); // the frame the user stares at
      gate.complete(repo.history);
      await tester.pump(); // ONLY a frame pump: nothing else may carry the
      // refresh — the GET commit itself must notify (B1).
      expect(userIds(tester), ['2'], reason: 'durable wins, pending retires');
      await closeAll(tester);
    });

    testWidgets('R9a loadOlder merges rows the remote observation can '
        'claim: the preview retires on the merge', (tester) async {
      repo.history = [
        for (var i = 100; i < 300; i++)
          Message(id: '$i', role: 'assistant', content: 'r$i'),
      ];
      repo.revCount = 200;
      repo.revLatest = 200;
      repo.olderPage = [const Message(id: '300', role: 'user', content: q)];
      repo.active = [
        runOf(obs: 'oR', runId: 'rZ', userText: q, afterId: 299),
      ];
      await openPage(tester);
      expect(userIds(tester), contains('remote:e1:oR'));
      await ctrl().loadOlder(); // the REAL call-site
      await tester.pump();
      final ids = userIds(tester);
      expect(ids, contains('300'));
      expect(
        ids,
        isNot(contains('remote:e1:oR')),
        reason: 'merged history must re-project before the paint',
      );
    });

    testWidgets('R9b a bootstrap-adopted pending run never previews itself',
        (tester) async {
      await store.savePending(
        'http://test.invalid',
        's',
        userText: q,
        runId: 'rBoot',
      );
      repo.active = [runOf(obs: 'oB', runId: 'rBoot', userText: q)];
      await openPage(tester);
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(userIds(tester), isNot(contains('remote:e1:oB')));
      expect(repo.chatCalls, 0); // read-only adoption
      await closeAll(tester);
    });
  });

  group('Phase 2 — unknown-identity preview arbitration (B3)', () {
    testWidgets('R4/R7a an unknown same-text observation for THIS send is '
        'held while the pending bubble shows; durable settles it', (
      tester,
    ) async {
      repo.history = [const Message(id: '1', role: 'user', content: '舊話')];
      repo.revCount = 1;
      repo.revLatest = 1;
      await openPage(tester);
      await sendUi(tester, q);
      repo.active = [
        runOf(
          obs: 'oU',
          userText: q,
          startedAt: nowSec(tester),
          source: 'session_sync',
        ),
      ];
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(
        userIds(tester),
        ['1', 'pending'],
        reason: 'one bubble for one turn — the preview overlaps pending',
      );
      repo.post([const Message(id: '2', role: 'user', content: q)]);
      await tester.pump(const Duration(seconds: 6)); // rev moved -> GET
      await tester.pump();
      expect(userIds(tester), ['1', '2']); // durable claims it
      await tester.pump(const Duration(seconds: 6));
      expect(userIds(tester), ['1', '2']); // and stays settled
      await closeAll(tester);
    });

    testWidgets('R7b a different runId revealed later restores the '
        'independent preview', (tester) async {
      repo.history = [const Message(id: '1', role: 'user', content: '舊話')];
      repo.revCount = 1;
      repo.revLatest = 1;
      await openPage(tester);
      await sendUi(tester, q);
      repo.active = [
        runOf(
          obs: 'oU',
          userText: q,
          startedAt: nowSec(tester),
          source: 'session_sync',
        ),
      ];
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(userIds(tester), ['1', 'pending']);
      // Identity reveals: that observation belongs to ANOTHER run.
      repo.active = [
        runOf(
          obs: 'oU',
          runId: 'rOther',
          userText: q,
          startedAt: nowSec(tester),
          source: 'session_sync',
        ),
      ];
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(
        userIds(tester),
        containsAllInOrder(['remote:e1:oU', 'pending']),
        reason: 'a different run is a different turn: BOTH rows show',
      );
      await closeAll(tester);
    });

    testWidgets('R7c/d out-of-window or different-source observations are '
        'never swallowed by the local pending', (tester) async {
      repo.history = [const Message(id: '1', role: 'user', content: '舊話')];
      repo.revCount = 1;
      repo.revLatest = 1;
      await openPage(tester);
      await sendUi(tester, q);
      repo.active = [
        runOf(obs: 'oOld', userText: q, startedAt: 1, source: 'session_sync'),
        runOf(
          obs: 'oW',
          runId: 'rW',
          userText: '另一問',
          startedAt: nowSec(tester),
          source: 'session_stream',
        ),
      ];
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      final ids = userIds(tester);
      expect(
        ids,
        containsAllInOrder(['remote:e1:oOld', 'pending']),
        reason: 'the stale same-text observation is NOT ours to hide',
      );
      expect(ids, contains('remote:e1:oW')); // different text: never hidden
      expect(ctrl().remoteBusy, isTrue); // the gate stays honest
      await closeAll(tester);
    });
  });

  group('Phase 2 — renderer boundaries (B4)', () {
    testWidgets('R5 Discord observation: preview once, durable once, no '
        'resurrection while running, terminal-without-row retires', (
      tester,
    ) async {
      repo.history = [const Message(id: '1', role: 'user', content: 'x')];
      repo.revCount = 1;
      repo.revLatest = 1;
      repo.active = [
        runOf(obs: 'oD', runId: 'rD', userText: '遠端話', afterId: 1),
      ];
      await openPage(tester);
      expect(userIds(tester), containsAllInOrder(['1', 'remote:e1:oD']));
      repo.post([const Message(id: '2', role: 'user', content: '遠端話')]);
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(userIds(tester), ['1', '2']);
      await tester.pump(const Duration(seconds: 6));
      await tester.pump(const Duration(seconds: 6));
      expect(
        userIds(tester),
        ['1', '2'],
        reason: 'running stays settled: no ghost resurrection',
      );
      // Terminal without a window-resident row retires (existing rule).
      repo.active = [];
      repo.recent = [
        runOf(
          obs: 'oG',
          runId: 'rG',
          status: 'completed',
          userText: '查無此列',
          afterId: 2,
        ),
      ];
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(userIds(tester), ['1', '2']);
    });

    testWidgets('R10 renderer identity: copy everywhere, timestamps only '
        'where durable, EntryView ids prove the source', (tester) async {
      final ts = nowSec(tester);
      repo.history = [
        Message(id: '1', role: 'user', content: '有時間', timestamp: ts),
        const Message(id: '2', role: 'user', content: '零時間'),
      ];
      repo.revCount = 2;
      repo.revLatest = 2;
      repo.active = [
        runOf(obs: 'o1', runId: 'rR', userText: '遠端列', afterId: 2),
      ];
      // A busy shape WITHOUT a local send (a remote run would gate the
      // send button): bootstrap-adopted pending supplies the `pending` id.
      await store.savePending(
        'http://test.invalid',
        's',
        userText: q,
        runId: 'rAdm',
      );
      await openPage(tester);
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      final ids = userIds(tester);
      expect(ids, containsAllInOrder(['1', '2', 'remote:e1:o1', 'pending']));
      expect(ids.toSet().length, ids.length); // every renderer is distinct
      expect(
        find.byType(CopyMenuButton),
        findsNWidgets(ids.length),
        reason: 'copy lives on EVERY user bubble — it marks no provenance',
      );
      expect(
        find.text(formatMessageTimestamp(ts)),
        findsOneWidget,
        reason: 'only the durable row carries a time',
      );
      await closeAll(tester);
    });

    testWidgets('R11 a completed transcript never doubles the turn’s user '
        'row while history is still landing', (tester) async {
      repo.history = [];
      await openPage(tester);
      await sendUi(tester, q);
      repo.events.add(
        const SseEvent('run.started', '{"run_id":"rLocal","session_id":"s"}'),
      );
      await tester.pump();
      final gate = Completer<List<Message>>();
      repo.historyGate = gate;
      repo.events.add(
        const SseEvent('run.completed', '''
            {"completed":true,"session_id":"s","messages":[
              {"id":"7","role":"user","content":"$q"},
              {"id":"8","role":"assistant","content":"答"}]}
            '''),
      );
      await tester.pump(); // transcript up; stream closes -> settle starts
      await repo.events.close();
      await tester.pump(); // settlement GET pending behind the gate
      expect(
        userIds(tester),
        ['pending'],
        reason: 'transcript user row is represented by the pending bubble',
      );
      gate.complete([
        Message(id: '7', role: 'user', content: q, timestamp: nowSec(tester)),
        const Message(id: '8', role: 'assistant', content: '答'),
      ]);
      await tester.pump();
      await tester.pump();
      expect(userIds(tester), ['7']); // settled durable: still exactly one
    });
  });
}
