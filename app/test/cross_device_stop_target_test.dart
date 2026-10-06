import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/chat/remote_stop.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// CROSSDEV-STOP R1 (§3/§4): the remote stop target is derived ONLY from a
/// trustworthy activity snapshot — never from previews, text or time-window
/// guesses. Freshness is age-checked AT THE READ; a late or older response
/// never overwrites newer evidence; the existing local getters (sendBlocked,
/// canStop, canEndLocalWaiting, activeRunId) keep their exact meaning, and
/// NOTHING here ever POSTs: stopCalls / chatCalls stay at zero through
/// every evaluation (the two local-representation setups ride one
/// explicitly-documented setup chat/stop and then stay frozen).
const url = 'http://test.invalid';
const sid = 's';

class XRepo extends HermesRepository {
  XRepo() : super(url, 'fake');
  final events = StreamController<SseEvent>();

  int historyReads = 0, activityReads = 0, chatCalls = 0, stopCalls = 0;
  int statusCalls = 0;
  final stopRunIds = <String>[];
  List<Message> history = const [];

  // Activity fixture knobs (snapshot shape).
  String snapshotSessionId = sid;
  String resolved = sid;
  String epoch = 'e1';
  bool overflow = false;
  List<ActivityRun> active = const [], recent = const [];
  int? activityFail; // when set: every unscripted GET throws this status
  int failNext = 0; // the next N unscripted GETs throw 503

  // Deterministic response timing: scripted futures answer calls in order
  // (Completers let the test land answers OUT OF ORDER), then `hangNext`
  // holds the following call, then the field-built snapshot answers.
  final script = <Future<SessionActivity>>[];
  Completer<SessionActivity>? hangNext;
  Completer<Json>? statusGate; // runStatus parks here (no GET storm)

  @override
  Future<SessionActivity> sessionActivity(String s) async {
    activityReads++;
    if (script.isNotEmpty) return await script.removeAt(0);
    final h = hangNext;
    if (h != null) {
      hangNext = null;
      return await h.future;
    }
    if (failNext > 0) {
      failNext--;
      throw ApiException('activity down', 503);
    }
    if (activityFail != null) throw ApiException('activity down', activityFail);
    return SessionActivity(
      sessionId: snapshotSessionId,
      resolvedSessionId: resolved,
      serverEpoch: epoch,
      observedAt: 0,
      historyRevision: HistoryRevision(resolved, 3, 3),
      activityRevision: 0,
      activeRuns: active,
      recentTerminal: recent,
      overflow: overflow,
    );
  }

  @override
  Future<List<Message>> messages(String s, {int offset = 0, int limit = 200}) async {
    historyReads++;
    return history;
  }

  @override
  Future<Json> sessionDetail(String s) async => {'id': s, 'message_count': 0};

  @override
  Stream<SseEvent> chat(String s, String input, {String? wakeBatch}) {
    chatCalls++;
    return events.stream;
  }

  @override
  Future<void> stop(String runId) async {
    stopCalls++;
    stopRunIds.add(runId);
  }

  @override
  Future<Json> runStatus(String runId) async {
    statusCalls++;
    final g = statusGate;
    if (g != null) return g.future;
    return {'status': 'running'};
  }

  @override
  Future<void> checkCapabilities() async {}
  @override
  void cancelStream(String s) => unawaited(events.close());
}

ActivityRun rrun({
  String obs = 'o1',
  String? runId = 'rremote',
  String status = 'running',
}) => ActivityRun(
  observationId: obs,
  runId: runId,
  status: status,
  startedAt: 1,
  source: runId == null ? 'session_sync' : 'runs_api',
);

SessionActivity snap({String epoch = 'e1', bool overflow = false}) =>
    SessionActivity(
      sessionId: sid,
      resolvedSessionId: sid,
      serverEpoch: epoch,
      observedAt: 0,
      historyRevision: HistoryRevision(sid, 3, 3),
      activityRevision: 0,
      activeRuns: const [],
      recentTerminal: const [],
      overflow: overflow,
    );

final _ctx = {
  'now': DateTime.utc(2026, 2, 2, 12),
  'lastActivitySuccess': DateTime.utc(2026, 2, 2, 12),
  'syncInterval': const Duration(seconds: 6),
  'requestedSessionId': sid,
  'snapshotSessionId': sid,
  'resolvedSessionId': sid,
  'epoch': 'srv-epoch-9',
  'isLocallyRepresented': false,
};

RemoteRunKind k(ActivityRun e, {Map<String, Object?>? over}) {
  final c = <String, Object?>{..._ctx, ...?over};
  return classifyRemoteRun(
    e,
    now: c['now']! as DateTime,
    lastActivitySuccess: c['lastActivitySuccess'] as DateTime?,
    syncInterval: c['syncInterval']! as Duration,
    requestedSessionId: c['requestedSessionId']! as String,
    snapshotSessionId: c['snapshotSessionId']! as String,
    resolvedSessionId: c['resolvedSessionId']! as String,
    epoch: c['epoch']! as String,
    isLocallyRepresented: c['isLocallyRepresented']! as bool,
  );
}

Future<void> until(
  bool Function() cond,
  String why, {
  int tries = 400,
}) async {
  for (var i = 0; i < tries && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  if (!cond()) throw StateError('timeout waiting for: $why');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  late XRepo repo;
  late DateTime t;
  DateTime step([int seconds = 0, int ms = 0]) =>
      t = t.add(Duration(seconds: seconds, milliseconds: ms));
  final t0 = DateTime.utc(2026, 1, 1);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    repo = XRepo();
    t = t0;
  });
  tearDown(() => repo.close());

  ChatController scripted() => ChatController(
    repo,
    store,
    sid,
    watchInterval: const Duration(milliseconds: 1),
    now: () => t,
  );

  void countsFrozen(void Function() reads) {
    final a = repo.activityReads,
        h = repo.historyReads,
        s = repo.statusCalls,
        c = repo.chatCalls,
        p = repo.stopCalls;
    reads();
    reads();
    reads();
    expect(
      (repo.activityReads, repo.historyReads, repo.statusCalls),
      (a, h, s),
      reason: 'target evaluation is pure derivation: zero GETs',
    );
    expect((repo.chatCalls, repo.stopCalls), (c, p), reason: 'zero POSTs');
  }

  // ---- 1. pure classifier: statuses ----------------------------------------

  test('classify: all four live statuses stoppable, stopping is NOT', () {
    for (final s in ['queued', 'running', 'waiting_for_approval']) {
      expect(k(rrun(status: s)), RemoteRunKind.stoppable, reason: s);
    }
    expect(k(rrun(status: 'stopping')), RemoteRunKind.stopping);
    expect(
      ActivityRun.liveStatuses,
      {'queued', 'running', 'waiting_for_approval', 'stopping'},
    );
  });

  test('classify: all four known terminal statuses', () {
    for (final s in ['completed', 'failed', 'cancelled', 'interrupted']) {
      expect(k(rrun(status: s)), RemoteRunKind.terminal, reason: s);
    }
    expect(
      ActivityRun.terminalStatuses,
      {'completed', 'failed', 'cancelled', 'interrupted'},
    );
  });

  test('classify: unknown status never becomes a target', () {
    expect(k(rrun(status: 'transpiring')), RemoteRunKind.unknownStatus);
    expect(k(rrun(status: '')), RemoteRunKind.unknownStatus);
  });

  // ---- 2. pure classifier: runId disclosure --------------------------------

  test('classify: null / empty / whitespace-only runId never POST-targetable',
      () {
    expect(k(rrun(runId: null)), RemoteRunKind.noRunId);
    expect(k(rrun(runId: '')), RemoteRunKind.noRunId);
    expect(k(rrun(runId: '   ')), RemoteRunKind.noRunId);
    // A non-empty id is NEVER trimmed into another id: ' r7 ' is kept and
    // must equal exactly ' r7 ' downstream.
    expect(k(rrun(runId: ' r7 ')), RemoteRunKind.stoppable);
  });

  // ---- 3. pure classifier: identity context --------------------------------

  test('classify: session / resolved / epoch identity must be complete', () {
    expect(k(rrun(), over: {'resolvedSessionId': ''}),
        RemoteRunKind.invalidIdentity);
    expect(k(rrun(), over: {'epoch': ''}), RemoteRunKind.invalidIdentity);
    expect(k(rrun(), over: {'epoch': '  '}), RemoteRunKind.invalidIdentity);
    expect(k(rrun(), over: {'snapshotSessionId': 'other'}),
        RemoteRunKind.invalidIdentity);
    expect(k(rrun(), over: {'requestedSessionId': ''}),
        RemoteRunKind.invalidIdentity);
  });

  test('classify: local representation outranks the status view', () {
    expect(k(rrun(), over: {'isLocallyRepresented': true}),
        RemoteRunKind.locallyRepresented);
    expect(
      k(rrun(status: 'stopping'), over: {'isLocallyRepresented': true}),
      RemoteRunKind.locallyRepresented,
    );
  });

  test('classify: expired evidence authenticates nothing (age boundary)', () {
    final now = DateTime.utc(2026, 2, 2, 12);
    expect(
      k(rrun(), over: {
        'now': now,
        'lastActivitySuccess': now.subtract(const Duration(seconds: 6)),
      }),
      RemoteRunKind.stoppable,
      reason: 'exactly syncInterval old is still fresh (<=)',
    );
    expect(
      k(rrun(), over: {
        'now': now,
        'lastActivitySuccess':
            now.subtract(const Duration(seconds: 6, milliseconds: 1)),
      }),
      RemoteRunKind.invalidIdentity,
      reason: 'syncInterval + 1ms is expired',
    );
    expect(
      k(rrun(), over: {'lastActivitySuccess': null}),
      RemoteRunKind.invalidIdentity,
    );
  });

  // ---- 4. RemoteStopTarget invariants ---------------------------------------

  test('RemoteStopTarget: blank ids invalid, verbatim ids equal verbatim', () {
    const ok = RemoteStopTarget(
      connectionGeneration: 3,
      accountGeneration: 3,
      requestedSessionId: 's',
      resolvedSessionId: 's',
      serverEpoch: 'srv-epoch-9',
      observationId: 'o1',
      runId: 'run7',
    );
    expect(ok.isValid, isTrue);
    expect(ok.sameIdentityAs(ok), isTrue);
    expect(
      ok.withIdentity(runId: 'run7 ').isValid,
      isTrue,
      reason: 'non-empty stays verbatim (never trimmed into another id)',
    );
    expect(ok.withIdentity(runId: 'run8').sameIdentityAs(ok), isFalse);
    expect(ok.withIdentity(runId: '').isValid, isFalse);
    expect(ok.withIdentity(runId: ' \t ').isValid, isFalse);
    expect(ok.withIdentity(serverEpoch: '').isValid, isFalse);
    expect(ok.withIdentity(resolvedSessionId: '').isValid, isFalse);
  });

  test('RemoteStopTarget: toString is log-safe (no keys, no previews)', () {
    const target = RemoteStopTarget(
      connectionGeneration: 1,
      accountGeneration: 1,
      requestedSessionId: 'session-abcdef0123456789',
      resolvedSessionId: 'session-abcdef0123456789',
      serverEpoch: 'epoch-secret-material-xyz',
      observationId: 'o1',
      runId: 'run-fedcba9876543210',
    );
    final s = target.toString();
    expect(s, isNot(contains('secret-material')));
    expect(s, isNot(contains('fedcba9876543210')));
    expect(s, isNot(contains('key')));
  });

  // ---- 5. controller: candidates only while fresh NOW ----------------------

  group('controller', () {
    Future<ChatController> attachedFresh(ChatController c) async {
      c.attach();
      await until(
          () => c.activityFreshness == ActivityFreshness.fresh &&
              c.observedActivity != null,
          'first snapshot');
      return c;
    }

    test('fresh SSE remote run: exact target, zero POSTs, gates unchanged',
        () async {
      final c = scripted();
      repo.active = [rrun(runId: 'rremote')];
      await attachedFresh(c);
      final targets = c.remoteStopCandidates;
      expect(targets, hasLength(1));
      expect(targets.single.runId, 'rremote');
      expect(targets.single.requestedSessionId, sid);
      expect(targets.single.resolvedSessionId, sid);
      expect(targets.single.serverEpoch, 'e1');
      expect(targets.single.isValid, isTrue);
      expect(targets.single.connectionGeneration, c.connectionGeneration);
      expect(c.canRequestRemoteStop, isTrue);
      expect(c.remoteBlockReason, RemoteStopBlock.none);
      // The existing gates keep their exact meaning: a confirmed remote run
      // locks the send (same as audit_cross_device_sync expects).
      expect(c.sendBlocked, isTrue);
      expect(c.canStop, isFalse);
      expect(c.canEndLocalWaiting, isFalse);
      expect(c.activeRunId, isNull);
      expect(c.remoteActiveRuns, hasLength(1));
      countsFrozen(() {
        c.remoteStopCandidates;
        c.canRequestRemoteStop;
        c.remoteBlockReason;
        c.remoteCandidatesOverflowed;
      });
      expect(repo.stopCalls, 0);
      expect(repo.chatCalls, 0);
      c.dispose();
    });

    test('STOP freshness ages out on the injected clock at exactly 6s+1ms',
        () async {
      final c = scripted();
      repo.active = [rrun(runId: 'rremote')];
      await attachedFresh(c);
      step(6); // exactly syncInterval old: still fresh (<=)
      expect(c.activityEvidenceFreshNow, isTrue);
      expect(c.remoteStopCandidates, hasLength(1));
      expect(c.remoteBlockReason, RemoteStopBlock.none);
      step(0, 1);
      // The `fresh` enum alone never expires on its own — the STOP view
      // re-derives age at read time and drops the target.
      expect(c.activityFreshness, ActivityFreshness.fresh);
      expect(c.activityEvidenceFreshNow, isFalse);
      expect(c.remoteStopCandidates, isEmpty);
      expect(c.canRequestRemoteStop, isFalse);
      expect(c.remoteBlockReason, RemoteStopBlock.stale);
      expect(repo.stopCalls, 0);
      c.dispose();
    });

    test('stopping rows are 核对-only: shown separately, never POST targets',
        () async {
      final c = scripted();
      repo.active = [rrun(obs: 'oa', runId: 'rstop', status: 'stopping')];
      await attachedFresh(c);
      expect(c.remoteStopCandidates, isEmpty);
      expect(c.canRequestRemoteStop, isFalse);
      expect(c.remoteStoppingRunIds, ['rstop']);
      expect(c.remoteBlockReason, RemoteStopBlock.noStoppableTarget);
      expect(c.sendBlocked, isTrue); // remote live run still locks send
      expect(repo.stopCalls, 0);
      c.dispose();
    });

    test('overflow: rows stay individually valid, generalization flagged',
        () async {
      final c = scripted();
      repo.active = [rrun(obs: 'oa', runId: 'ra'), rrun(obs: 'ob', runId: 'rb')];
      repo.overflow = true;
      await attachedFresh(c);
      expect(c.remoteStopCandidates.map((t) => t.runId), ['ra', 'rb']);
      expect(c.remoteCandidatesOverflowed, isTrue);
      expect(c.canRequestRemoteStop, isTrue);
      repo.active = [];
      await c.refreshActivity();
      expect(c.remoteCandidatesOverflowed, isTrue,
          reason: 'flag rides the fresh snapshot even with zero listed rows');
      expect(c.remoteStopCandidates, isEmpty);
      expect(repo.stopCalls, 0);
      c.dispose();
    });

    test('no targets for terminal-only, unknown status, null/empty runId',
        () async {
      final c = scripted();
      repo.active = [
        rrun(obs: 'o1', status: 'completed'),
        rrun(obs: 'o2', status: 'cancelled'),
        rrun(obs: 'o3', status: 'failed'),
        rrun(obs: 'o4', status: 'interrupted'),
        rrun(obs: 'o5', status: 'transpiring'),
        rrun(obs: 'o6', runId: null),
        rrun(obs: 'o7', runId: ''),
      ];
      await attachedFresh(c);
      expect(c.remoteStopCandidates, isEmpty);
      expect(c.canRequestRemoteStop, isFalse);
      expect(c.remoteStoppingRunIds, isEmpty);
      expect(c.remoteBlockReason, RemoteStopBlock.noStoppableTarget);
      expect(repo.stopCalls, 0);
      c.dispose();
    });

    test('identity moves kill the targets: snapshot session, empty epoch / '
        'resolved', () async {
      final c = scripted();
      repo.active = [rrun()];
      await attachedFresh(c);
      expect(c.remoteStopCandidates, hasLength(1));

      repo.snapshotSessionId = 'compacted-other';
      await c.refreshActivity();
      expect(c.remoteStopCandidates, isEmpty);
      expect(c.remoteBlockReason, RemoteStopBlock.noStoppableTarget);

      repo.snapshotSessionId = sid;
      repo.resolved = '';
      await c.refreshActivity();
      expect(c.remoteStopCandidates, isEmpty);

      repo.resolved = sid;
      repo.epoch = ''; // EMPTY EPOCH — incomplete identity
      await c.refreshActivity();
      expect(c.remoteStopCandidates, isEmpty);
      expect(repo.stopCalls, 0);
      c.dispose();
    });

    test('opaque non-numeric serverEpoch is tolerated verbatim', () async {
      final c = scripted();
      repo.epoch = 'boot-7d41a2c9-not-an-int';
      repo.active = [rrun()];
      await attachedFresh(c);
      final targets = c.remoteStopCandidates;
      expect(targets, hasLength(1));
      expect(targets.single.serverEpoch, 'boot-7d41a2c9-not-an-int');
      expect(repo.stopCalls, 0);
      c.dispose();
    });

    // ---- 6. local representation: three real paths -------------------------

    test('local class 1 — bootstrap-adopted pending (_bootRunId): excluded, '
        'zero POSTs', () async {
      await store.savePending(url, sid, userText: '我的輪次', runId: 'r-boot',
          startedAt: t0);
      repo.active = [rrun(obs: 'o1', runId: 'r-boot'), rrun(obs: 'o2', runId: 'r-x')];
      final c = scripted();
      await c.bootstrap();
      await until(() => c.busy && c.observedActivity != null,
          'pending adopted + first snapshot');
      expect(c.activeRunId, 'r-boot');
      expect(c.remoteStopCandidates.map((t) => t.runId), ['r-x'],
          reason: 'own boot run is locally represented');
      expect(c.canStop, isTrue); // baseline semantics untouched
      expect(c.canEndLocalWaiting, isFalse);
      countsFrozen(() => c.remoteStopCandidates);
      expect(repo.stopCalls, 0);
      expect(repo.chatCalls, 0);
      c.dispose();
    });

    test('local class 2 — live SSE turn (activeRunId + _localOwnedRunId): '
        'excluded; only the remote row is a target', () async {
      final c = scripted();
      await attachedFresh(c); // send gate opened by a fresh quiet snapshot
      final sending = c.send('獨白'); // SETUP ONLY: one scripted stream POST
      repo.events.add(
        const SseEvent('run.started', '{"run_id":"r-live","session_id":"s"}'),
      );
      await until(() => c.activeRunId == 'r-live', 'run.started named the run');
      repo.active = [rrun(obs: 'o1', runId: 'r-live'), rrun(obs: 'o2', runId: 'r-other')];
      await c.refreshActivity();
      expect(c.remoteStopCandidates.map((t) => t.runId), ['r-other']);
      expect(c.canRequestRemoteStop, isTrue);
      expect(c.sendBlocked, isTrue); // busy: exactly as before
      countsFrozen(() => c.remoteStopCandidates);
      repo.events
        ..add(const SseEvent('run.completed', '{"completed":true,"messages":[]}'))
        ..add(const SseEvent('done', '{}'));
      await repo.events.close();
      await sending;
      // The setup chat call stays exactly 1 forever after: evaluation never
      // adds calls.
      expect(repo.chatCalls, 1);
      expect(repo.stopCalls, 0);
      c.dispose();
    });

    test('local class 3 — stopping watch (_stopping/_stopRunId): excluded, '
        'canStop false as baseline', () async {
      await store.savePending(url, sid, userText: '停止中', runId: 'r-stopping',
          startedAt: t0);
      repo.active = [rrun(obs: 'o1', runId: 'r-stopping')];
      repo.statusGate = Completer<Json>(); // park the watch GETs (no storm)
      final c = scripted();
      await c.bootstrap();
      await until(() => c.busy && c.observedActivity != null,
          'pending adopted + first snapshot');
      final res = await c.stop(); // SETUP ONLY: the one local stop POST
      expect(res.success, isTrue);
      expect(repo.stopRunIds, ['r-stopping']);
      expect(c.activeRunId, 'r-stopping');
      expect(c.canStop, isFalse); // baseline: stopping blocks re-stop
      expect(c.remoteStopCandidates, isEmpty);
      expect(c.remoteStoppingRunIds, isEmpty);
      expect(c.remoteBlockReason, RemoteStopBlock.noStoppableTarget);
      countsFrozen(() {
        c.remoteStopCandidates;
        c.remoteStoppingRunIds;
      });
      expect(repo.stopCalls, 1, reason: 'setup stop only — evaluation adds none');
      expect(repo.chatCalls, 0);
      repo.statusGate!.complete({'status': 'running'});
      c.dispose();
    });

    // ---- 7. stale responses must never overwrite ----------------------------

    test('out-of-order: older request landing LAST never overwrites the newer '
        'epoch (real quiet-round overlap)', () async {
      // i18n-exempt: cross-platform persistence fixture, not UI text.
      await store.savePending(url, sid, userText: '問題\n一', startedAt: t0);
      // i18n-exempt: Discord-reformatted anchor fixture.
      repo.history = const [
        Message(id: '1', role: 'user', content: '問題 一 [附件: log.txt]'),
        Message(
          id: '2',
          role: 'assistant',
          content: '',
          toolCalls: [ToolCall('t1', 'review', '{}')],
        ),
      ];
      final c = scripted();
      await c.bootstrap();
      await until(() => c.observedActivity != null && c.busy,
          'first snapshot + adoption');
      expect(c.observedActivity!.serverEpoch, 'e1');
      final seen = repo.activityReads;
      final old = Completer<SessionActivity>();
      repo.hangNext = old; // the quiet round's DIRECT GET parks here
      await until(() => repo.activityReads > seen, 'quiet-round GET');
      // Newer evidence lands FIRST (its seq is strictly above the hang's):
      repo.epoch = 'e2';
      final refresh = c.refreshActivityForStopCheck();
      await until(() => c.observedActivity!.serverEpoch == 'e2', 'newer apply');
      expect((await refresh).result, ActivityRefreshResult.refreshed);
      // The OLD seq completes LAST — it must die at the guard, not
      // resurrect epoch e1.
      old.complete(snap(epoch: 'e1'));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(c.observedActivity!.serverEpoch, 'e2',
          reason: 'a late older response never overwrites');
      expect(repo.stopCalls, 0);
      expect(repo.chatCalls, 0);
      c.dispose();
    });

    test('out-of-order via raw overlap: seq guard alone rejects the late one',
        () async {
      final c = scripted();
      final a = Completer<SessionActivity>(), b = Completer<SessionActivity>();
      repo.script
        ..add(a.future)
        ..add(b.future);
      final f1 = c.debugActivitySnapshotRaw(); // seq 1
      final f2 = c.debugActivitySnapshotRaw(); // seq 2
      b.complete(snap(epoch: 'e-newer'));
      await f2;
      expect(c.observedActivity!.serverEpoch, 'e-newer');
      a.complete(snap(epoch: 'e-older')); // older lands LAST
      await f1;
      expect(c.observedActivity!.serverEpoch, 'e-newer');
      expect(c.remoteStopCandidates, isEmpty); // quiet snapshots
      expect(repo.stopCalls, 0);
      c.dispose();
    });

    test('late response after dispose never applies (and never notifies)',
        () async {
      final c = scripted();
      final g = Completer<SessionActivity>();
      repo.hangNext = g;
      c.attach();
      await until(() => repo.activityReads == 1, 'first GET in flight');
      c.dispose();
      g.complete(snap());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.observedActivity, isNull);
      expect(c.activityFreshness, ActivityFreshness.unknown);
      expect(c.remoteStopCandidates, isEmpty);
      expect(repo.stopCalls, 0);
    });

    test('late response after a turn/session identity handover never applies',
        () async {
      final c = scripted();
      c.debugMintTurnToken(); // a turn owns the page before the GET starts
      final g = Completer<SessionActivity>();
      repo.hangNext = g;
      c.attach();
      await until(() => repo.activityReads == 1, 'GET in flight');
      c.debugMintTurnToken(); // the turn/session identity moved
      g.complete(snap());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.observedActivity, isNull);
      expect(c.activityFreshness, ActivityFreshness.unknown);
      expect(c.remoteStopCandidates, isEmpty);
      expect(repo.stopCalls, 0);
      c.dispose();
    });

    test('late response after detach (activity epoch move) never applies',
        () async {
      final c = scripted();
      final g = Completer<SessionActivity>();
      repo.hangNext = g;
      c.attach();
      await until(() => repo.activityReads == 1, 'GET in flight');
      c.detach(); // page gone: the activity epoch retires the flight
      g.complete(snap());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.observedActivity, isNull);
      expect(repo.stopCalls, 0);
      c.dispose();
    });

    test('connection (URL/key) move: in-flight old-generation answer dies; '
        'targets carry the NEW generation', () async {
      final c = scripted();
      final g = Completer<SessionActivity>();
      repo.hangNext = g;
      c.attach();
      await until(() => repo.activityReads == 1, 'GET in flight');
      final g0 = c.connectionGeneration;
      c.debugBumpConnectionGeneration();
      expect(c.connectionGeneration, g0 + 1);
      g.complete(snap());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.observedActivity, isNull,
          reason: 'old-connection evidence cannot authenticate the new one');
      repo.active = [rrun()];
      c.attach(); // re-issue under the new generation
      await until(() => c.activityEvidenceFreshNow, 'new-generation snapshot');
      final targets = c.remoteStopCandidates;
      expect(targets, hasLength(1));
      expect(targets.single.connectionGeneration, g0 + 1);
      expect(repo.stopCalls, 0);
      c.dispose();
    });

    // ---- 8. refreshActivityForStopCheck -------------------------------------

    test('refresh issues a NEW request above every prior seq', () async {
      final c = scripted();
      await attachedFresh(c); // snapshot #1 (epoch e1)
      repo.script.add(Future.value(snap(epoch: 'e2')));
      final out = await c.refreshActivityForStopCheck();
      expect(out.result, ActivityRefreshResult.refreshed);
      expect(out.ok, isTrue);
      expect(c.observedActivity!.serverEpoch, 'e2');
      expect(repo.stopCalls, 0);
      c.dispose();
    });

    test('refresh waits for the in-flight flight then FAILS honestly — the '
        'pre-click snapshot is never laundered as this click\'s success',
        () async {
      final c = scripted();
      await attachedFresh(c); // snapshot #1 applied (fresh e1)
      final late = Completer<SessionActivity>();
      repo.script.add(late.future); // call #2 (pre-click): will answer e0
      repo.failNext = 1; // call #3 (this refresh's own): honest 503
      final pre = c.refreshActivity();
      await until(() => repo.activityReads == 2, 'pre-click call issued');
      final refresh = c.refreshActivityForStopCheck();
      await Future<void>.delayed(Duration.zero);
      late.complete(snap(epoch: 'e0')); // pre-click evidence lands
      await pre;
      final out = await refresh;
      expect(out.result, ActivityRefreshResult.failed);
      expect((out.error! as ApiException).status, 503);
      expect(c.observedActivity!.serverEpoch, 'e0',
          reason: 'the honest last apply — not disguised as a refresh');
      expect(c.activityFreshness, ActivityFreshness.stale);
      expect(c.remoteStopCandidates, isEmpty);
      expect(c.remoteBlockReason, RemoteStopBlock.stale);
      expect(repo.stopCalls, 0);
      c.dispose();
    });

    test('a pre-call flight rejected by an identity move never counts as '
        "this refresh's evidence — its own re-issue decides", () async {
      final c = scripted();
      c.debugMintTurnToken(); // snapshot below belongs to THIS identity
      final g = Completer<SessionActivity>();
      repo.hangNext = g;
      c.attach();
      await until(() => repo.activityReads == 1, 'flight in progress');
      final r = c.refreshActivityForStopCheck(); // awaits the in-flight one
      await Future<void>.delayed(Duration.zero);
      c.debugMintTurnToken(); // identity moves: the flight answer dies
      g.complete(snap());
      final out = await r;
      expect(out.result, ActivityRefreshResult.refreshed,
          reason: 'the refresh re-issued under the CURRENT identity');
      expect(repo.activityReads, 2,
          reason: 'the pre-call answer never counted — a new GET ran');
      expect(c.observedActivity, isNotNull);
      c.dispose();
      final disposed = await c.refreshActivityForStopCheck();
      expect(disposed.result, ActivityRefreshResult.disposed);
      expect(repo.stopCalls, 0);
    });

    test('unsupported gateway and cold-unknown read as blocks, never as '
        'stopppable silence', () async {
      final c = scripted();
      expect(c.remoteBlockReason, RemoteStopBlock.unknownState);
      repo.activityFail = 404;
      c.attach();
      await until(() =>
          c.activityFreshness == ActivityFreshness.unsupported, '404 seen');
      expect(c.remoteStopCandidates, isEmpty);
      expect(c.remoteBlockReason, RemoteStopBlock.unsupported);
      expect(c.canRequestRemoteStop, isFalse);
      expect(repo.stopCalls, 0);
      c.dispose();
    });
  });
}
