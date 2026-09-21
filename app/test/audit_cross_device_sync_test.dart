import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/l10n/app_locale.dart';

import 'support/localized_app.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/chat/message_timeline.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/providers.dart';

/// WAVE4 §5.1 regressions (rewrite of the R1 message_count suite): a visible
/// page observes GET /api/sessions/{sid}/activity every tick. The revision
/// inside the snapshot is the ONLY history trigger; a confirmed remote run
/// locks the send and shows a temp user row BEFORE the durable write is
/// visible; failure never fabricates idle. The old message_count poll must
/// fail this suite (sessionDetail goes unused; activity GETs go missing).

const url = 'http://test.invalid';

class FakeSyncRepo extends HermesRepository {
  FakeSyncRepo() : super(url, 'fake');
  final events = StreamController<SseEvent>.broadcast();
  List<Message> history = [];
  int historyReads = 0, detailReads = 0, activityReads = 0, chatCalls = 0;

  // The activity fixture: move `rev` whenever the durable side changes.
  int revCount = 0, revLatest = 0;
  String epoch = 'e1';
  List<ActivityRun> active = [], recent = [];
  int? activityFail; // when set, every activity GET throws this status

  /// "The other device" posts: durable rows appear AND the revision moves.
  void post(List<Message> rows) {
    history = [...history, ...rows];
    revCount += rows.length;
    revLatest += rows.length;
  }

  @override
  Stream<SseEvent> chat(String sid, String input) {
    chatCalls++;
    return events.stream;
  }

  @override
  Future<List<Message>> messages(
    String sid, {
    int offset = 0,
    int limit = 200,
  }) async {
    historyReads++;
    return history;
  }

  @override
  Future<Json> sessionDetail(String sid) async {
    detailReads++; // the OLD sync clock — WAVE4 must never call it
    return {'id': sid, 'message_count': revCount};
  }

  @override
  Future<SessionActivity> sessionActivity(String sid) async {
    activityReads++;
    if (activityFail != null) throw ApiException('activity down', activityFail);
    return SessionActivity(
      sessionId: sid,
      resolvedSessionId: sid,
      serverEpoch: epoch,
      observedAt: 0,
      historyRevision: HistoryRevision(sid, revCount, revLatest),
      activityRevision: 0,
      activeRuns: active,
      recentTerminal: recent,
      overflow: false,
    );
  }

  @override
  Future<List<Skill>> skills() async => const [];
  @override
  Future<void> checkCapabilities() async {}
  @override
  void cancelStream(String sid) {}
}

ActivityRun remoteRun({
  String obs = 'o1',
  String? runId = 'runremote',
  String status = 'running',
  String? userText,
  int? afterId,
}) => ActivityRun(
  observationId: obs,
  runId: runId,
  status: status,
  startedAt: 1,
  source: runId == null ? 'session_sync' : 'runs_api',
  user: userText == null
      ? null
      : ActivityUser(text: userText, afterId: afterId),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeSyncRepo repo;
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
    repo = FakeSyncRepo();
    store = LocalStore(await SharedPreferences.getInstance());
    container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        localStoreProvider.overrideWithValue(store),
        initialSettingsProvider.overrideWith(
          (ref) => const AppSettings(url: url, key: 'k'),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<void> openPage(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedWrap(ChatPage(session: session), locale: AppLocale.zhHant),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('unchanged revision: ticks GET activity only, NEVER history', (
    tester,
  ) async {
    repo.history = const [Message(id: '1', role: 'user', content: '甲')];
    repo.revCount = 1;
    repo.revLatest = 1;
    await openPage(tester);
    expect(repo.historyReads, 1); // bootstrap's own load only
    expect(repo.detailReads, 0, reason: 'message_count poll must be gone');
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 6));
    expect(repo.activityReads, greaterThanOrEqualTo(3));
    expect(repo.historyReads, 1, reason: 'quiet sessions must not re-GET');
  });

  testWidgets('other device posts (revision moves): exactly ONE history GET', (
    tester,
  ) async {
    repo.post([const Message(id: '1', role: 'user', content: '甲')]);
    await openPage(tester);
    expect(repo.historyReads, 1);

    // The OTHER device sends (DB rows AND the revision move together).
    repo.post([
      const Message(id: '2', role: 'user', content: '來自另一裝置'),
      const Message(id: '3', role: 'assistant', content: '收到'),
    ]);
    await tester.pump(const Duration(seconds: 6));
    expect(repo.historyReads, 2, reason: 'one tick moved = one GET');
    expect(find.text('來自另一裝置'), findsOneWidget);
    expect(find.text('收到'), findsOneWidget);

    await tester.pump(const Duration(seconds: 6)); // applied baseline follows
    expect(repo.historyReads, 2, reason: 'no repeat once committed');
  });

  testWidgets(
    'remote run: temp user row before the durable write; send locked; '
    'a typed send fires ZERO POSTs and /stop never targets the remote run',
    (tester)
    async {
      repo.post([const Message(id: '1', role: 'user', content: '甲')]);
      repo.active = [
        remoteRun(userText: '來自另一裝置的提問', afterId: 1),
      ];
      await openPage(tester);
      final c = container.read(chatProvider('s'));
      expect(c.remoteBusy, isTrue);
      expect(c.sendBlocked, isTrue);
      expect(find.text('其他裝置進行中'), findsOneWidget);
      // The remote turn's user text shows even though history (rev 1) does
      // NOT carry it yet — temp row keyed by epoch+observation_id.
      expect(
        find.descendant(
          of: find.byType(MessageTimeline),
          matching: find.textContaining('來自另一裝置的提問'),
        ),
        findsOneWidget,
      );

      await tester.enterText(find.byType(TextField), '我也要講');
      await tester.pump();
      final sendButton = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.arrow_upward),
          matching: find.byType(IconButton),
        ).first,
      );
      expect(sendButton.onPressed, isNull, reason: 'send gate shut while remote');
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump();
      expect(repo.chatCalls, 0, reason: 'no POST ride-along');

      // /stop while only a REMOTE run exists: must not aim at the remote id.
      await tester.enterText(find.byType(TextField), '/stop');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump();
      expect(
        repo.chatCalls,
        0,
        reason: '/stop never targets a run this page does not own',
      );
    },
  );

  testWidgets('remote terminal folds into history: temp row disappears once '
      'the durable rows arrive (claim ledger dedupes by id)', (tester) async {
    repo.post([const Message(id: '1', role: 'user', content: '甲')]);
    repo.active = [
      remoteRun(userText: '另一裝置問', afterId: 1),
    ];
    await openPage(tester);
    expect(find.textContaining('另一裝置問'), findsOneWidget); // temp row

    // Server persists + the run lands in recent_terminal as completed.
    repo.post([
      const Message(id: '2', role: 'user', content: '另一裝置問'),
      const Message(id: '3', role: 'assistant', content: '答'),
    ]);
    repo.active = [];
    repo.recent = [
      remoteRun(status: 'completed', userText: '另一裝置問', afterId: 1),
    ];
    await tester.pump(const Duration(seconds: 6)); // tick: rev moved -> GET
    expect(find.text('另一裝置問'), findsOneWidget, reason: 'ONE row: durable');
    expect(
      find.textContaining('⋯（尚未於歷史確認）'),
      findsNothing,
      reason: 'confirmed by history — the temp bubble must retire',
    );
  });

  testWidgets('legacy gateway (404): no lock, no banner — pre-WAVE4 send', (
    tester,
  ) async {
    repo.activityFail = 404;
    await openPage(tester);
    final c = container.read(chatProvider('s'));
    expect(c.sendBlocked, isFalse);
    expect(find.text('其他裝置進行中'), findsNothing);

    await tester.enterText(find.byType(TextField), '照樣發');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump();
    expect(repo.chatCalls, 1);
    expect(c.busy, isTrue);
    repo.events
      ..add(const SseEvent('run.completed', '{"messages":[]}'))
      ..add(const SseEvent('done', '{}'));
    await repo.events.close();
    await tester.pump();
    await tester.pump();
    expect(c.busy, isFalse);
  });

  testWidgets('cross-platform observation claims by fold/position, never a '
      'permanent ghost (discord-run repro)', (tester) async {
    // The run lives on ANOTHER platform (discord): the persisted history row
    // is reformatted versus the live observation preview (attachment tags,
    // newlines). The old exact-text matcher strands "尚未於歷史確認" under
    // the timeline forever. History is the source of truth: claim it.
    repo.post([
      const Message(id: '1', role: 'user', content: '舊問題'),
      const Message(id: '5', role: 'user', content: '新問題 說明'),
      const Message(id: '6', role: 'assistant', content: '答'),
    ]);
    repo.recent = [
      remoteRun(
        obs: 'oX',
        status: 'completed',
        userText: '新問題\n[附件: 754d img.png]', // observed preview, rewrapped
        afterId: 1,
      ),
    ];
    await openPage(tester);
    await tester.pump(const Duration(seconds: 6));
    expect(
      find.textContaining('尚未於歷史確認'),
      findsNothing,
      reason: 'a durable row after the observation point folds the ghost',
    );
    expect(find.text('新問題 說明'), findsOneWidget); // history row shown once
  });

  testWidgets('fold match beats exact for whitespace/attachment decoration', (
    tester,
  ) async {
    repo.post([
      const Message(id: '1', role: 'user', content: '甲'),
      const Message(id: '7', role: 'user', content: '乙\n[附件: x.png]'),
    ]);
    repo.recent = [
      remoteRun(
        obs: 'oF',
        status: 'completed',
        userText: '乙 [附件: x.png]',
        afterId: 1,
      ),
    ];
    await openPage(tester);
    await tester.pump(const Duration(seconds: 6));
    expect(find.textContaining('尚未於歷史確認'), findsNothing);
    expect(find.textContaining('remote:'), findsNothing);
  });

  testWidgets('stale after a confirmed remote run: banner stays, send stays '
      'locked — a failed snapshot NEVER reads as idle', (tester) async {
    repo.active = [remoteRun()];
    await openPage(tester);
    final c = container.read(chatProvider('s'));
    expect(c.remoteBusy, isTrue);

    repo.activityFail = 503; // the observation path wedges
    await tester.pump(const Duration(seconds: 6));
    expect(c.activityFreshness, ActivityFreshness.stale);
    expect(c.remoteBusy, isTrue, reason: 'last-known state keeps gating');
    expect(c.sendBlocked, isTrue);
    expect(find.text('其他裝置進行中'), findsOneWidget);
    expect(find.textContaining('即時狀態擷取失敗'), findsOneWidget);
  });

  testWidgets('backgrounded: zero activity GETs; resume = one immediate tick, '
      'no stacked timers', (tester) async {
    await openPage(tester);
    await tester.pump(const Duration(seconds: 6));
    final seen = repo.activityReads;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 30)); // several intervals
    expect(repo.activityReads, seen, reason: 'hidden app pays nothing');

    // Framework-legal return chain (audit16 pattern): paused never jumps to
    // resumed directly.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(); // immediate catch-up tick
    expect(repo.activityReads, seen + 1);
    await tester.pump(const Duration(seconds: 6)); // ONE periodic beat only
    expect(repo.activityReads, seen + 2);
  });

  testWidgets('cold-start failure keeps the send locked (unknown is NOT idle)',
      (tester) async {
    repo.activityFail = 503;
    await openPage(tester);
    final c = container.read(chatProvider('s'));
    expect(c.activityFreshness, ActivityFreshness.unknown);
    expect(c.sendBlocked, isTrue, reason: 'an unverifiable session is not idle');
    await tester.enterText(find.byType(TextField), '發得嗎');
    await tester.pump();
    expect(find.text('狀態確認中，暫停送出'), findsOneWidget);
  });

  testWidgets('busy sending: revision move still merges; pending bubble dedup '
      'intact; own run row never becomes a remote projection', (tester) async {
    await openPage(tester);
    expect(repo.historyReads, 1);

    await tester.enterText(find.byType(TextField), '獨白');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump();
    final c = container.read(chatProvider('s'));
    expect(c.busy, isTrue);

    // Server persists THIS page's send while the SSE is still open: the
    // revision moves (own row!), but the snapshot names no foreign run.
    repo.post([const Message(id: '1', role: 'user', content: '獨白')]);
    await tester.pump(const Duration(seconds: 6));
    expect(repo.historyReads, 2);
    expect(c.pendingDelivered, isTrue);
    expect(
      find.descendant(
        of: find.byType(MessageTimeline),
        matching: find.text('獨白'),
      ),
      findsOneWidget,
      reason: 'exactly ONE user row, and no remote clone',
    );

    repo.events
      ..add(const SseEvent('run.completed', '{"messages":[]}'))
      ..add(const SseEvent('done', '{}'));
    await repo.events.close();
    await tester.pump();
    await tester.pump();
    expect(c.busy, isFalse);
  });
}
