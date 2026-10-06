import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/chat/remote_stop.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// CROSSDEV-STOP R2 (§5.1/§5.2, §7 V02–V07, V10–V12, V15, V16): the remote
/// stop FLIGHT — preflight-gated, exactly-targeted, bounded and
/// reconciliation-only. Every fake here keeps a POST LEDGER recording
/// method + exact runId + counts (stop, stopWithDeadline, wake receipts,
/// chat) — chatCalls alone can never prove "no stop happened".
const url = 'http://test.invalid';
const sid = 's';

class RSRepo extends HermesRepository {
  RSRepo() : super(url, 'fake');
  final events = StreamController<SseEvent>();

  // The LEDGERS — method+runId+counts, never chatCalls-only.
  final stopLocal = <String>[]; // Future<void> stop(runId) — LOCAL path only
  final stopRemote = <String>[]; // stopWithDeadline(runId) — remote POSTs
  int chatCalls = 0, statusCalls = 0, historyReads = 0, activityReads = 0;
  int wakeAcks = 0, wakeReleases = 0, wakeAdmits = 0;

  // Activity fixture (field-built snapshot answers when unscripted).
  String resolved = sid;
  String epoch = 'e1';
  bool overflow = false;
  List<ActivityRun> active = const [], recent = const [];
  int? activityFail; // when set: unscripted GETs throw this status
  int failNext = 0; // the next N unscripted GETs throw 503
  final script = <Future<SessionActivity>>[]; // scripted answers, in order

  // stopWithDeadline answers: scripted futures first, then `stopGate`
  // (park ONE call), then `stopFail` (throw this status), else success.
  final stopAnswers = <Future<void>>[];
  Completer<void>? stopGate;
  int? stopFail;

  // runStatus answers.
  Completer<Json>? statusGate;
  Object? statusError;
  Json Function(String runId) status = (_) => {'status': 'running'};

  @override
  Future<SessionActivity> sessionActivity(String s) async {
    activityReads++;
    if (script.isNotEmpty) return await script.removeAt(0);
    if (failNext > 0) {
      failNext--;
      throw ApiException('activity down', 503);
    }
    if (activityFail != null) throw ApiException('activity down', activityFail);
    return SessionActivity(
      sessionId: sid,
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
  Future<void> stop(String runId) async {
    stopLocal.add(runId);
  }

  @override
  Future<void> stopWithDeadline(String runId) async {
    stopRemote.add(runId);
    if (stopAnswers.isNotEmpty) {
      await stopAnswers.removeAt(0);
      return;
    }
    final g = stopGate;
    if (g != null) {
      stopGate = null;
      await g.future;
    }
    if (stopFail != null) throw ApiException('stop refused', stopFail);
  }

  @override
  Future<Json> runStatus(String runId) async {
    statusCalls++;
    final g = statusGate;
    if (g != null) return g.future;
    if (statusError != null) throw statusError!;
    return status(runId);
  }

  @override
  Future<List<Message>> messages(
    String s, {
    int offset = 0,
    int limit = 200,
  }) async {
    historyReads++;
    return const [];
  }

  @override
  Future<Json> sessionDetail(String s) async => {'id': s, 'message_count': 3};

  @override
  Stream<SseEvent> chat(String s, String input, {String? wakeBatch}) {
    chatCalls++;
    return events.stream;
  }

  @override
  Future<Json> wakeAdmit(String s, List<String> keys) async {
    wakeAdmits++;
    return {'status': 'ok'};
  }

  @override
  Future<void> wakeAck(String s, String b, String state, {String? runId}) async
      => wakeAcks++;

  @override
  Future<Json> wakeRelease(String s, String b) async {
    wakeReleases++;
    return {'status': 'ok'};
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

SessionActivity quietSnap() => SessionActivity(
  sessionId: sid,
  resolvedSessionId: sid,
  serverEpoch: 'e1',
  observedAt: 0,
  historyRevision: HistoryRevision(sid, 3, 3),
  activityRevision: 0,
  activeRuns: const [],
  recentTerminal: const [],
  overflow: false,
);

Future<void> until(
  bool Function() cond,
  String why, {
  int tries = 800,
}) async {
  for (var i = 0; i < tries && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  if (!cond()) throw StateError('timeout waiting for: $why');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late LocalStore store;
  late RSRepo repo;
  late DateTime t;
  DateTime step([int seconds = 0, int ms = 0]) =>
      t = t.add(Duration(seconds: seconds, milliseconds: ms));
  final t0 = DateTime.utc(2026, 1, 1);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = LocalStore(prefs);
    repo = RSRepo();
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

  Future<ChatController> attached(ChatController c) async {
    c.attach();
    await until(
      () => c.activityEvidenceFreshNow && c.observedActivity != null,
      'first fresh snapshot',
    );
    return c;
  }

  Map<String, Object?> snapshot() => {
    for (final k in prefs.getKeys()) k: prefs.get(k),
  };

  MessageKey keyOf(UiMessage? m) => (m! as UiLocal).key;

  // ---- V02: no-id / unknown-status rows never POST, never local-settle ----

  test('V02: null/empty runId and unknown status → no target, no POST, no '
      'local settle, honest block reasons', () async {
    repo.active = [
      rrun(obs: 'o1', runId: null),
      rrun(obs: 'o2', runId: ''),
      rrun(obs: 'o3', status: 'transpiring'),
    ];
    final c = await attached(scripted());
    expect(c.canRequestRemoteStop, isFalse);
    expect(c.remoteBlockReason, RemoteStopBlock.noStoppableTarget);
    // The null-id row exposes the readable reason the UI shows (V02/V17).
    expect(c.remoteDisabledReason, MessageKey.chatStopRemoteNoRunId);
    final r = await c.stop();
    expect(r.kind, StopResultKind.noTurn); // never a local settle
    expect(c.busy, isFalse);
    expect(c.phase, ChatPhase.idle);
    expect(store.loadPending(url, sid), isNull);
    expect(repo.stopRemote, isEmpty);
    expect(repo.stopLocal, isEmpty);
    expect(repo.chatCalls, 0);
    c.dispose();
  });

  // ---- V03: stale / unsupported / failed preflight — no POST until a NEW
  // successful preflight ----

  test('V03: aged-out evidence never POSTs; a failed NEW preflight never '
      'POSTs; only a successful fresh preflight may', () async {
    repo.active = [rrun()];
    final c = await attached(scripted());
    final target = c.remoteStopCandidates.single;
    step(7); // evidence older than syncInterval: the click has NO evidence
    expect(c.canRequestRemoteStop, isFalse);
    expect(c.remoteBlockReason, RemoteStopBlock.stale);
    expect((await c.stop()).kind, StopResultKind.noTurn);
    expect(repo.stopRemote, isEmpty);

    // Direct stopRemote must run a NEW preflight — and this one fails (503).
    repo.failNext = 1;
    final failed = await c.stopRemote(target);
    expect(failed.kind, RemoteStopKind.preflightFailed);
    expect(keyOf(failed.message), MessageKey.chatStopRemoteRefreshRequired);
    expect(repo.stopRemote, isEmpty, reason: 'no evidence, no POST (§5.1)');

    // A NEW successful preflight is what unlocks the POST.
    final ok = await c.stopRemote(target);
    expect(ok.kind, RemoteStopKind.requested);
    expect(repo.stopRemote, ['rremote']);
    c.dispose();
  });

  test('V03/unsupported: legacy gateway never offers a remote target', () async {
    repo.activityFail = 404;
    final c = scripted();
    c.attach();
    await until(
      () => c.activityFreshness == ActivityFreshness.unsupported,
      '404 seen',
    );
    expect(c.canRequestRemoteStop, isFalse);
    expect((await c.stop()).kind, StopResultKind.noTurn);
    expect(repo.stopRemote, isEmpty);
    c.dispose();
  });

  // ---- V04: chooser instead of guessing; local stays local-first ----------

  test('V04: two stoppable rows → chooser kind, NOTHING auto-picked', () async {
    repo.active = [rrun(obs: 'oa', runId: 'ra'), rrun(obs: 'ob', runId: 'rb')];
    final c = await attached(scripted());
    final r = await c.stop();
    expect(r.kind, StopResultKind.remoteChoice);
    expect(repo.stopRemote, isEmpty);
    expect(repo.stopLocal, isEmpty);
    expect(c.remoteStopPhaseState, RemoteStopPhaseState.none);
    // The chooser surface lists both rows with targets and no previews.
    final rows = c.remoteStopChooserRows;
    expect(rows, hasLength(2));
    expect(rows.every((e) => e.actionable), isTrue);
    c.dispose();
  });

  test('V04: overflow with one listed row → chooser + may-be-incomplete flag',
      () async {
    repo.active = [rrun(runId: 'ra')];
    repo.overflow = true;
    final c = await attached(scripted());
    expect(c.remoteCandidatesOverflowed, isTrue);
    final r = await c.stop();
    expect(r.kind, StopResultKind.remoteChoice);
    expect(repo.stopRemote, isEmpty);
    c.dispose();
  });

  test('V04: mixed local+remote → /stop stops the LOCAL run only; the remote '
      'row action stops the named remote run', () async {
    final c = await attached(scripted()); // QUIET first: the send gate opens
    final sending = c.send('獨白');
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r-live","session_id":"s"}'),
    );
    await until(() => c.activeRunId == 'r-live', 'run.started');
    repo.active = [
      rrun(obs: 'oa', runId: 'r-live'),
      rrun(obs: 'ob', runId: 'rremote'),
    ];
    await c.refreshActivity();
    expect(c.remoteStopCandidates.map((t) => t.runId), ['rremote']);
    // stop() is LOCAL-FIRST: only the own run's id is ever POSTed.
    repo.status = (id) => {'status': 'completed'};
    final r = await c.stop();
    expect(r.kind, StopResultKind.serverStopRequested);
    expect(r.success, isTrue);
    expect(repo.stopLocal, ['r-live']);
    expect(repo.stopRemote, isEmpty, reason: 'never aim at the other run');
    repo.events
      ..add(const SseEvent('run.completed', '{"completed":true,"messages":[]}'))
      ..add(const SseEvent('done', '{}'));
    await repo.events.close();
    await sending;
    c.dispose();
  });

  // ---- V05: terminal evidence ends tracking with ZERO POSTs ---------------

  test('V05: preflight shows the target in recentTerminal → ended, zero POSTs',
      () async {
    repo.active = [rrun()];
    final c = await attached(scripted());
    final target = c.remoteStopCandidates.single;
    // The click's NEW preflight answer: the run moved to recentTerminal.
    repo.script.add(
      Future.value(
        SessionActivity(
          sessionId: sid,
          resolvedSessionId: sid,
          serverEpoch: 'e1',
          observedAt: 0,
          historyRevision: HistoryRevision(sid, 3, 3),
          activityRevision: 0,
          activeRuns: const [],
          recentTerminal: [rrun(status: 'completed')],
          overflow: false,
        ),
      ),
    );
    final out = await c.stopRemote(target);
    expect(out.kind, RemoteStopKind.ended);
    expect(keyOf(out.message), MessageKey.chatStopRemoteEnded);
    expect(repo.stopRemote, isEmpty, reason: 'terminal needs no POST (V05)');
    expect(c.remoteStopPhaseState, RemoteStopPhaseState.ended);
    c.dispose();
  });

  test('V05: POST 200 then status terminal → observer ends (history failure '
      'cannot block it)', () async {
    repo.active = [rrun()];
    repo.status = (_) => {'status': 'cancelled'};
    final c = await attached(scripted());
    final out = await c.stop();
    expect(out.kind, StopResultKind.remoteResult);
    expect(out.remote!.kind, RemoteStopKind.requested);
    await until(
      () => c.remoteStopPhaseState == RemoteStopPhaseState.ended,
      'observer saw terminal',
    );
    expect(keyOf(c.remoteStopFeedback), MessageKey.chatStopRemoteEnded);
    expect(repo.stopRemote, ['rremote']);
    expect(store.stopRecord(url, sid), isNull, reason: 'no StopRecord (§5.2)');
    c.dispose();
  });

  // ---- V06: 404 → alreadyGone wording + refresh, other runs untouched -----

  test('V06: POST 404 → chatStopRemoteUnavailable path, other runs and the '
      'local machine untouched, nothing claimed', () async {
    repo.active = [rrun(runId: 'rremote'), rrun(obs: 'o9', runId: 'rother')];
    repo.stopFail = 404;
    final c = await attached(scripted());
    // Two rows → /stop opens the chooser (no guess); the ROW ACTION targets
    // the named run directly.
    expect((await c.stop()).kind, StopResultKind.remoteChoice);
    expect(repo.stopRemote, isEmpty);
    final out = await c.stopRemote(c.remoteTargetForRun('rremote')!);
    expect(out.kind, RemoteStopKind.alreadyGone);
    expect(keyOf(out.message), MessageKey.chatStopRemoteUnavailable);
    expect(c.remoteStopPhaseState, RemoteStopPhaseState.unavailable);
    expect(repo.stopRemote, ['rremote']);
    expect(c.busy, isFalse);
    expect(c.stopNoticeKind, StopNotice.none);
    expect(store.stopRecord(url, sid), isNull);
    expect(store.loadPending(url, sid), isNull);
    expect(
      c.observedActivity!.activeRuns.map((r) => r.runId),
      contains('rother'),
      reason: '404 never clears another run (§5.2 row 3)',
    );
    c.dispose();
  });

  // ---- V07: 409 run_not_active — non-error reconciliation, three fates ----

  test('V07: POST 409 → checkingConflict; status terminal ends without ever '
      'claiming a confirmed stop', () async {
    repo.active = [rrun()];
    repo.stopFail = 409;
    repo.status = (_) => {'status': 'completed'};
    final c = await attached(scripted());
    final out = await c.stop();
    expect(out.remote!.kind, RemoteStopKind.checkingConflict);
    expect(keyOf(out.remote!.message), MessageKey.chatStopRemoteChecking);
    expect(c.stopNoticeKind, StopNotice.none, reason: 'no red banner (§5.2)');
    await until(
      () => c.remoteStopPhaseState == RemoteStopPhaseState.ended,
      '409-then-terminal',
    );
    expect(repo.stopRemote, ['rremote'], reason: '409 never re-POSTs');
    expect(store.stopRecord(url, sid), isNull);
    expect(
      c.remoteStopFeedback,
      isNot((UiLocal m) => m.key == MessageKey.chatStateStoppedByYou),
      reason: 'never claim "stopped by you" on a 409',
    );
    c.dispose();
  });

  test('V07: 409 + status still running → bounded checking; 60s cap → '
      'unconfirmed, NO further POSTs', () async {
    repo.active = [rrun()];
    repo.stopFail = 409;
    final c = await attached(scripted());
    final out = await c.stop();
    expect(out.remote!.kind, RemoteStopKind.checkingConflict);
    expect(c.remoteStopPhaseState, RemoteStopPhaseState.checking);
    step(30);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.remoteStopPhaseState, RemoteStopPhaseState.checking,
        reason: 'still inside the window: honest checking only');
    step(31); // past remoteStopWindow (60s from start) — never extended
    await until(
      () => c.remoteStopPhaseState == RemoteStopPhaseState.unconfirmed,
      '60s cap → unconfirmed',
    );
    expect(keyOf(c.remoteStopFeedback), MessageKey.chatStopRemoteUnconfirmed);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    step(120);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(repo.stopRemote, ['rremote'], reason: 'the deadline never re-POSTs');
    expect(c.remoteStopPhaseState, RemoteStopPhaseState.unconfirmed);
    c.dispose();
  });

  test('V07: 409 + unreadable status (503) until the cap → unconfirmed, never '
      'a claim', () async {
    repo.active = [rrun()];
    repo.stopFail = 409;
    repo.statusError = ApiException('status down', 503);
    final c = await attached(scripted());
    final out = await c.stop();
    expect(out.remote!.kind, RemoteStopKind.checkingConflict);
    step(61);
    await until(
      () => c.remoteStopPhaseState == RemoteStopPhaseState.unconfirmed,
      'status-timeout → unconfirmed',
    );
    expect(repo.stopRemote, ['rremote']);
    expect(c.remoteStopFeedback,
        isNot((UiLocal m) => m.key == MessageKey.chatStopRemoteEnded));
    c.dispose();
  });

  // ---- V10: after a request, a NEW controller over the SAME prefs does '
  // ---- nothing but read: zero POSTs, zero persistence ---------------------

  test('V10: reload after a request — zero auto POSTs, no pending/journal/'
      'StopRecord; the stopping row reconciles from activity only', () async {
    repo.active = [rrun()];
    final a = await attached(scripted());
    final before = snapshot();
    final out = await a.stop();
    expect(out.remote!.kind, RemoteStopKind.requested);
    repo.statusGate = Completer<Json>(); // park the observer's GETs
    await until(() => repo.statusCalls > 0, 'observer GET issued');
    a.dispose();

    // Same prefs, brand-new controller: memory-only observer means NOTHING
    // to restore — activity/history alone describe the world (§5.2).
    expect(snapshot(), equals(before),
        reason: 'remote stop persisted NOTHING (§5.2): zero new keys');
    expect(store.stopRecord(url, sid), isNull);
    expect(store.loadPending(url, sid), isNull);
    expect(store.listAttempts(url, sid), isEmpty);

    repo.active = [rrun(status: 'stopping')];
    repo.statusGate = null;
    final b = scripted();
    b.attach();
    await until(
      () => b.activityEvidenceFreshNow && b.observedActivity != null,
      'B first snapshot',
    );
    final gets = repo.activityReads + repo.statusCalls + repo.historyReads;
    await b.refreshActivity(); // the page's own refresh: state from READs
    expect(b.remoteStoppingRunIds, ['rremote']);
    expect(b.remoteStopCandidates, isEmpty,
        reason: 'a stopping row is 核对-only, never a re-POST target');
    expect(b.remoteStopPhaseState, RemoteStopPhaseState.none,
        reason: 'the fresh page shows 核對中 purely from activity');
    expect(repo.stopLocal, isEmpty);
    expect(repo.stopRemote, ['rremote'], reason: 'still exactly A\'s one POST');
    expect(repo.activityReads + repo.statusCalls + repo.historyReads > gets,
        isTrue, reason: 'state comes from read-only activity/history GETs');
    expect(repo.stopLocal + repo.stopRemote, ['rremote']);
    b.dispose();
  });

  // ---- V11: identity moves — targetChanged; late answers write nothing ----

  test('V11: epoch moves before the POST → targetChanged, ZERO POSTs, no '
      'retarget onto the new run', () async {
    repo.active = [rrun()];
    final c = await attached(scripted());
    final target = c.remoteStopCandidates.single;
    // Gateway restart between mint and click: same row id, NEW epoch.
    repo.epoch = 'e2';
    repo.active = [rrun()];
    final out = await c.stopRemote(target);
    expect(out.kind, RemoteStopKind.targetChanged);
    expect(keyOf(out.message), MessageKey.chatStopRemoteTargetChanged);
    expect(repo.stopRemote, isEmpty,
        reason: 'an observed epoch move fences the POST out (§8.1)');
    c.dispose();
  });

  test('V11: connection moves WHILE the POST is parked → POST happened '
      'pre-change only; the late answer writes nothing', () async {
    repo.active = [rrun()];
    final c = await attached(scripted());
    final target = c.remoteStopCandidates.single;
    final gate = Completer<void>();
    repo.stopGate = gate;
    final flight = c.stopRemote(target);
    await until(() => repo.stopRemote.length == 1, 'POST parked');
    c.debugBumpConnectionGeneration(); // settings moved mid-flight
    gate.complete();
    final out = await flight;
    expect(out.kind, RemoteStopKind.targetChanged);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.remoteStopPhaseState, RemoteStopPhaseState.none);
    expect(repo.statusCalls, 0, reason: 'no observer may poll another scope');
    expect(repo.stopRemote, ['rremote'],
        reason: 'the POST happened after a VALID preflight, before the move');
    c.dispose();
  });

  test('V11: a stopped controller rejects every late completion', () async {
    repo.active = [rrun()];
    final c = await attached(scripted());
    final target = c.remoteStopCandidates.single;
    final gate = Completer<void>();
    repo.stopGate = gate;
    final flight = c.stopRemote(target);
    await until(() => repo.stopRemote.length == 1, 'POST parked');
    c.dispose();
    gate.complete();
    final out = await flight;
    expect(out.kind, RemoteStopKind.unconfirmed,
        reason: 'a disposed controller never reports a landed request');
    expect(repo.statusCalls, 0);
  });

  // ---- V12: singleflight, the 60s cap and an abortable hung status --------

  test('V12: rapid triple tap JOINS one flight — exactly ONE POST', () async {
    repo.active = [rrun()];
    final c = await attached(scripted());
    final target = c.remoteStopCandidates.single;
    final gate = Completer<void>();
    repo.stopGate = gate;
    final f1 = c.stopRemote(target);
    final f2 = c.stopRemote(target);
    final f3 = c.stopRemote(target);
    expect(identical(f1, f2) && identical(f2, f3), isTrue,
        reason: 'identical repeat taps share the one flight (§5.1)');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    gate.complete();
    await f1;
    expect(repo.stopRemote, ['rremote']);
    expect(repo.activityReads, lessThan(10), reason: 'no per-tap GET storm');
    c.dispose();
  });

  test('V12: hung status GET is abortable; the late completion is rejected '
      'by the generation', () async {
    repo.active = [rrun()];
    repo.stopFail = 409;
    final gate = Completer<Json>();
    repo.statusGate = gate; // the observer parks on its first read-only GET
    final c = await attached(scripted());
    final out = await c.stop();
    expect(out.remote!.kind, RemoteStopKind.checkingConflict);
    await until(() => repo.statusCalls > 0, 'status parked');
    c.cancelRemoteStopObserver(); // ending the local waiting leaks nothing
    gate.complete({'status': 'cancelled'});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(c.remoteStopPhaseState, RemoteStopPhaseState.none);
    expect(c.remoteStopFeedback, isNull);
    expect(repo.stopRemote, ['rremote'], reason: 'abort never re-POSTs');
    c.dispose();
  });

  // ---- V15/V16: no wake side effects; auth failures stay honest -----------

  test('V15: remote stop has ZERO wake side effects; the send gate stays '
      'activity-driven', () async {
    repo.active = [rrun()];
    repo.status = (_) => {'status': 'running'};
    final c = await attached(scripted());
    expect(c.sendBlocked, isTrue, reason: 'remote run still locks the send');
    final out = await c.stop(); // requested; observer keeps checking
    expect(out.remote!.kind, RemoteStopKind.requested);
    expect(repo.wakeAcks, 0);
    expect(repo.wakeReleases, 0);
    expect(repo.wakeAdmits, 0);
    expect(c.busy, isFalse, reason: 'a remote action never sets busy (§3)');
    expect(c.sendBlocked, isTrue,
        reason: 'the POST response may NOT idle the session (§3)');
    c.dispose();
  });

  test('V16: POST 401 → failed honestly — visible id never implies stoppable',
      () async {
    repo.active = [rrun()];
    repo.stopFail = 401;
    final c = await attached(scripted());
    final out = await c.stop();
    expect(out.remote!.kind, RemoteStopKind.failed);
    expect(keyOf(out.remote!.message), MessageKey.chatStateM032);
    expect(c.remoteStopPhaseState, RemoteStopPhaseState.none);
    expect(c.remoteStopFeedback,
        isNot((UiLocal m) => m.key == MessageKey.chatStopRemoteEnded));
    expect(repo.statusCalls, 0, reason: 'a 401 starts no reconciliation');
    expect(store.stopRecord(url, sid), isNull);
    c.dispose();
  });

  test('V16: status 403 during checking is NOT "stopped" — bounded, honest',
      () async {
    repo.active = [rrun()];
    repo.statusError = ApiException('forbidden', 403);
    final c = await attached(scripted());
    final out = await c.stop();
    expect(out.remote!.kind, RemoteStopKind.requested);
    step(61);
    await until(
      () => c.remoteStopPhaseState == RemoteStopPhaseState.unconfirmed,
      '403 until cap → unconfirmed',
    );
    expect(keyOf(c.remoteStopFeedback), MessageKey.chatStopRemoteUnconfirmed);
    c.dispose();
  });
}
