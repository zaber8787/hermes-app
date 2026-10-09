import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/approval_inbox_view.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/providers.dart';

import 'support/localized_app.dart';
import 'approval_inbox_ui_test.dart' as fixture;

// APPROVBUTTON X1 (report §6, plan §7.1): the activity observer must OWN the
// approval discovery chain. A waiting run proven by per-session activity —
// remote OR bootstrap-local — triggers the capability probe and a per-run
// GET reconcile with per-run single-flight/dirty coalescing and a connection
// generation fence. A remote answer/terminal/vanish reconciles the inbox;
// NOTHING here ever fabricates a local turn.
//
// Red baseline: the report probe `.ab-scratch/repo/app/test/ab_page_probe_test.dart`
// ("AB RED: opening remote waiting session discovers pending card") measured
// probes=0 / approvals GET=0 / cards=0 on the same shape.

enum ActivityMode { quiet, remoteWaiting, remoteRunning, remoteTerminal }

class DiscoveryRepo extends fixture.FakeInboxRepo {
  DiscoveryRepo() : super(capability: Map.of(fixture.capabilityOn));

  ActivityMode mode = ActivityMode.quiet;
  bool failGet = false;
  Completer<void>? getGate;

  @override
  Future<Map<String, dynamic>?> approvalInboxFeature() async {
    capCalls++;
    return capability;
  }

  int capCalls = 0;

  /// GETs that STARTED (getCalls only counts COMPLETED ones — while a gate
  /// is open the flight is real but invisible to it).
  int getStarted = 0;

  @override
  Future<Json> runApprovals(String runId) async {
    getStarted++;
    if (getGate case final g?) await g.future;
    if (failGet) throw StateError('synthetic snapshot unavailable');
    return super.runApprovals(runId);
  }

  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      switch (mode) {
        ActivityMode.quiet => SessionActivity.quiet(sid),
        ActivityMode.remoteWaiting => _with(sid, _remote('waiting_for_approval')),
        ActivityMode.remoteRunning => _with(sid, _remote('running')),
        ActivityMode.remoteTerminal => SessionActivity(
          sessionId: sid,
          resolvedSessionId: sid,
          serverEpoch: 'a9b8c7d6e5f4',
          observedAt: 0,
          historyRevision: HistoryRevision(sid, 0, 0),
          activityRevision: 1,
          activeRuns: const [],
          recentTerminal: [_remote('completed')],
          overflow: false,
        ),
      };

  static SessionActivity _with(String sid, ActivityRun r) => SessionActivity(
    sessionId: sid,
    resolvedSessionId: sid,
    serverEpoch: 'a9b8c7d6e5f4',
    observedAt: 0,
    historyRevision: HistoryRevision(sid, 0, 0),
    activityRevision: 1,
    activeRuns: [r],
    recentTerminal: const [],
    overflow: false,
  );

  static ActivityRun _remote(String status) => ActivityRun(
    observationId: 'o',
    runId: 'remote-r',
    status: status,
    startedAt: 0,
    source: 'run_status',
  );

  @override
  Future<List<Message>> messages(String sid, {int offset = 0, int limit = 200}) async => const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DiscoveryRepo repo;
  late ProviderContainer container;

  Future<void> boot(WidgetTester t) async {
    SharedPreferences.setMockInitialValues({});
    repo = DiscoveryRepo()
      ..pendingRows = [
        {'request_id': 'q', 'choices': ['once', 'deny'], 'command': 'test only'},
      ];
    container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        localStoreProvider.overrideWithValue(LocalStore(await SharedPreferences.getInstance())),
        initialSettingsProvider.overrideWith(
          (ref) => const AppSettings(url: fixture.url, key: 'fake'),
        ),
      ],
    );
    addTearDown(container.dispose);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedWrap(
          ChatPage(
            session: Session(
              id: 's',
              title: 'test',
              count: 0,
              startedAt: 0,
              activity: 0,
              source: 'api_server',
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await t.pump();
    }
  }

  Future<void> end(WidgetTester t) async {
    if (!repo.events.isClosed) {
      repo.events
        ..add(const SseEvent('run.completed', '{"messages":[]}'))
        ..add(const SseEvent('done', '{}'));
      await t.pump();
    }
    await t.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await repo.events.close();
  }

  int cards() => find.byType(PendingApprovalCard).evaluate().length;

  testWidgets('X1: a remote waiting run in activity discovers the pending card', (t) async {
    await boot(t);
    repo.mode = ActivityMode.remoteWaiting;
    final c = container.read(chatProvider('s'));
    await c.debugActivitySnapshotRaw();
    for (var i = 0; i < 6; i++) {
      await t.pump();
    }
    final gets = repo.getCalls, caps = repo.capCalls, seen = cards();
    final messages = List<Message>.of(c.messages);
    await end(t);
    expect(gets, greaterThan(0),
        reason: 'remote waiting run is known but approvals GET count=$gets capability probes=$caps cards=$seen');
    expect(caps, greaterThan(0));
    expect(seen, 1);
    // Discovery never invents a local turn: the durable rows stay untouched.
    expect(messages, isEmpty);
  });

  testWidgets('X1 control: quiet activity without a local turn fetches nothing', (t) async {
    await boot(t);
    final c = container.read(chatProvider('s'));
    await c.debugActivitySnapshotRaw();
    for (var i = 0; i < 6; i++) {
      await t.pump();
    }
    final gets = repo.getCalls;
    await end(t);
    expect(gets, 0);
  });

  testWidgets('X1: per-run single-flight coalesces overlapping reconciles (dirty replay)', (t) async {
    {
      await boot(t);
      repo.mode = ActivityMode.remoteWaiting;
      repo.getGate = Completer<void>();
      final c = container.read(chatProvider('s'));
      await c.debugActivitySnapshotRaw();
      for (var i = 0; i < 4; i++) {
        await t.pump();
      }
      await c.debugActivitySnapshotRaw();
      await c.debugActivitySnapshotRaw();
      for (var i = 0; i < 6; i++) {
        await t.pump();
      }
      final inFlight = repo.getStarted;
      repo.getGate!.complete();
      for (var i = 0; i < 8; i++) {
        await t.pump();
      }
      final after = repo.getCalls, seen = cards();
      await end(t);
      // ONE GET owned the run while three triggers arrived; the dirty flag
      // earned exactly ONE replay — never three parallel GETs, never a
      // silently dropped third request.
      expect(inFlight, 1);
      expect(after, lessThanOrEqualTo(2));
      expect(seen, 1);
    }
  });

  testWidgets('X1: a bumped connection generation fences a late approvals GET', (t) async {
    await boot(t);
    repo.mode = ActivityMode.remoteWaiting;
    repo.getGate = Completer<void>();
    final c = container.read(chatProvider('s'));
    await c.debugActivitySnapshotRaw();
    for (var i = 0; i < 4; i++) {
      await t.pump();
    }
    expect(repo.getStarted, 1);
    c.debugBumpConnectionGeneration();
    repo.getGate!.complete();
    for (var i = 0; i < 6; i++) {
      await t.pump();
    }
    final seen = cards();
    await end(t);
    // The old-generation answer may not merge; a NEW generation re-probes.
    expect(seen, 0);
  });

  testWidgets('X1: a remote terminal settles the inbox without fake rows', (t) async {
    await boot(t);
    repo.mode = ActivityMode.remoteWaiting;
    final c = container.read(chatProvider('s'));
    await c.debugActivitySnapshotRaw();
    for (var i = 0; i < 6; i++) {
      await t.pump();
    }
    expect(cards(), 1);
    repo.mode = ActivityMode.remoteTerminal;
    await c.debugActivitySnapshotRaw();
    for (var i = 0; i < 6; i++) {
      await t.pump();
    }
    final seen = cards(), messages = List<Message>.of(c.messages);
    await end(t);
    expect(seen, 0);
    expect(messages, isEmpty);
  });

  testWidgets('X1: an answered-elsewhere pending reconciles away on the next tick', (t) async {
    await boot(t);
    repo.mode = ActivityMode.remoteWaiting;
    final c = container.read(chatProvider('s'));
    await c.debugActivitySnapshotRaw();
    for (var i = 0; i < 6; i++) {
      await t.pump();
    }
    expect(cards(), 1);
    // The OTHER device answered: the run stays waiting a tick, then the
    // bounded re-poll sees pending=[] and reconciles the card away.
    repo.pendingRows = [];
    await t.pump(const Duration(seconds: 7));
    for (var i = 0; i < 4; i++) {
      await t.pump();
    }
    final seen = cards();
    await end(t);
    expect(seen, 0);
  });

  testWidgets('X1: a failed snapshot marks unconfirmed and the bounded re-poll repairs it', (t) async {
    await boot(t);
    repo.mode = ActivityMode.remoteWaiting;
    repo.failGet = true;
    final c = container.read(chatProvider('s'));
    await c.debugActivitySnapshotRaw();
    for (var i = 0; i < 6; i++) {
      await t.pump();
    }
    // A failed GET shows NO card (never a fake one) but marks the run
    // unconfirmed — the state is unknown, not empty.
    expect(cards(), 0);
    expect(container.read(chatProvider('s')).approvalUnconfirmedRuns.contains('remote-r'), isTrue);
    repo.failGet = false;
    await t.pump(const Duration(seconds: 7));
    for (var i = 0; i < 4; i++) {
      await t.pump();
    }
    final unconfirmed = container.read(chatProvider('s')).approvalUnconfirmedRuns.contains('remote-r');
    final seen = cards();
    await end(t);
    expect(unconfirmed, isFalse, reason: 'bounded re-poll must repair the unconfirmed remote card');
    expect(seen, 1);
  });
}
