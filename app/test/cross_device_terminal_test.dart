import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/auto_wake.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/chat/live_turn.dart';
import 'package:hermes_app/features/chat/remote_stop.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// CROSSDEV-STOP R3 (§6, §7 V08/V09/V15): the SENDER (device A) converges
/// on every known terminal — SSE frame or runStatus — with honest
/// provenance, and the dual-device regression proves device B stays
/// side-effect-free. TWO SEPARATE LocalStore instances (separate prefs
/// backends) + ONE shared fake server ledger recording chat POSTs, stop
/// POSTs BY runId, runStatus reads, history reads, SSE scripts and wake
/// acks. A shared store would never prove "device".
const url = 'http://test.invalid';
const sid = 's';

/// The shared "server": every controller talks to THIS one ledger.
class TermRepo extends HermesRepository {
  TermRepo() : super(url, 'fake');

  // A's SSE script LANES: each chat POST gets its own single-subscription
  // stream; openLane starts the next one (a settled turn's stream is closed
  // by cancelStream, exactly like the real socket).
  StreamController<SseEvent>? _cur;
  StreamController<SseEvent> get events =>
      _cur ??= StreamController<SseEvent>();
  void openLane() {
    final c = _cur;
    if (c != null && !c.isClosed) unawaited(c.close());
    _cur = StreamController<SseEvent>();
  }

  // THE LEDGERS — method + exact runId + counts, never chatCalls-only.
  int chatCalls = 0;
  final stopLocal = <String>[]; // stop(runId) — the LOCAL path
  final stopRemote = <String>[]; // stopWithDeadline(runId) — the R2 remote path
  int statusCalls = 0, historyReads = 0, activityReads = 0;
  final wakeAcks = <(String, String)>[]; // (batchId, state) in order

  // Answers.
  Json Function(String runId) status = (_) => {'status': 'running'};
  Object? statusError; // when set: every runStatus read throws this
  Object? historyError; // when set: every history GET throws this
  Completer<List<Message>>? historyGate; // when set: the GET parks here
  String? resolved;
  String epoch = 'e1';
  List<ActivityRun> active = const [], recent = const [];

  @override
  Stream<SseEvent> chat(String s, String input, {String? wakeBatch}) {
    chatCalls++;
    return events.stream; // grabs (creating) the current lane
  }

  @override
  Future<void> stop(String runId) async => stopLocal.add(runId);

  @override
  Future<void> stopWithDeadline(String runId) async => stopRemote.add(runId);

  @override
  Future<Json> runStatus(String runId) async {
    statusCalls++;
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
    if (historyError != null) throw historyError!;
    final g = historyGate;
    if (g != null) return g.future;
    return const [];
  }

  @override
  Future<SessionActivity> sessionActivity(String s) async {
    activityReads++;
    return SessionActivity(
      sessionId: sid,
      resolvedSessionId: resolved ?? sid,
      serverEpoch: epoch,
      observedAt: 0,
      historyRevision: HistoryRevision(sid, 3, 3),
      activityRevision: 0,
      activeRuns: active,
      recentTerminal: recent,
      overflow: false,
    );
  }

  @override
  Future<Json> sessionDetail(String s) async => {'id': s, 'message_count': 3};

  @override
  Future<void> wakeAck(
    String s,
    String batchId,
    String state, {
    String? runId,
  }) async {
    wakeAcks.add((batchId, state));
  }

  @override
  Future<void> checkCapabilities() async {}

  @override
  void cancelStream(String s) {
    if (!events.isClosed) unawaited(events.close());
  }
}

ActivityRun aRun({String obs = 'o1', String? runId = 'r1', String status = 'running'}) =>
    ActivityRun(
      observationId: obs,
      runId: runId,
      status: status,
      startedAt: 1,
      source: 'runs_api',
    );

Future<void> until(bool Function() cond, String why, {int tries = 800}) async {
  for (var i = 0; i < tries && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  if (!cond()) throw StateError('timeout waiting for: $why');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TermRepo repo;
  late LocalStore storeA, storeB;

  setUp(() async {
    repo = TermRepo();
    // TWO SEPARATE prefs backends = two devices' storage. A shared store is
    // FORBIDDEN as cross-device evidence, so every test re-seeds twice.
    SharedPreferences.setMockInitialValues({});
    storeA = LocalStore(await SharedPreferences.getInstance());
    SharedPreferences.setMockInitialValues({});
    storeB = LocalStore(await SharedPreferences.getInstance());
  });
  tearDown(() => repo.close());

  ChatController ctrlA() => ChatController(
    repo,
    storeA,
    sid,
    watchInterval: const Duration(milliseconds: 1),
    wait: (_) async {},
  );
  ChatController ctrlB() => ChatController(
    repo,
    storeB,
    sid,
    watchInterval: const Duration(milliseconds: 1),
    wait: (_) async {},
  );

  Future<ChatController> attached(ChatController c) async {
    c.attach();
    await until(
      () => c.activityEvidenceFreshNow && c.observedActivity != null,
      'first fresh snapshot',
    );
    return c;
  }

  MessageKey keyOf(UiMessage? m) => (m! as UiLocal).key;

  Map<String, Object?> snapshot(LocalStore store) =>
      {for (final k in store.prefs.getKeys()) k: store.prefs.get(k)};

  // ---- LiveTurn: the shared terminal update path (pure) -------------------

  group('LiveTurn terminal variants', () {
    const frames = {
      'completed': 'run.completed',
      'cancelled': 'run.cancelled',
      'failed': 'run.failed',
      'interrupted': 'run.interrupted',
    };

    test('each known terminal event sets terminalStatus + completed once', () {
      for (final entry in frames.entries) {
        final t = LiveTurn()..runId = 'r1';
        t.apply(
          SseEvent(entry.value, '{"run_id":"r1","session_id":"s","messages":[]}'),
          sid,
        );
        expect(t.terminalStatus, entry.key, reason: entry.value);
        expect(t.completed, isTrue);
      }
    });

    test('status is CARRIED, never flattened: the four never agree', () {
      final byStatus = <String, LiveTurn>{};
      for (final entry in frames.entries) {
        byStatus[entry.key] = LiveTurn()
          ..runId = 'r1'
          ..apply(
            SseEvent(
              entry.value,
              '{"run_id":"r1","session_id":"s","messages":[],'
              '"error":"boom"}',
            ),
            sid,
          );
      }
      expect(byStatus['completed']!.terminalStatus, 'completed');
      expect(byStatus['cancelled']!.terminalStatus, 'cancelled');
      expect(byStatus['failed']!.terminalStatus, 'failed');
      expect(byStatus['failed']!.terminalDetail, 'boom');
      expect(byStatus['interrupted']!.terminalStatus, 'interrupted');
      // Wording downstream keys off terminalStatus, so a failed frame can
      // never masquerade as a completed one.
      expect(byStatus['failed']!.completed, byStatus['completed']!.completed);
    });

    test('duplicate terminal — same seq AND re-delivery — updates once', () {
      final t = LiveTurn()
        ..runId = 'r1'
        ..apply(
          const SseEvent(
            'run.cancelled',
            '{"run_id":"r1","session_id":"s","seq":7,"messages":['
            '{"id":"1","role":"assistant","content":"first"}]}',
          ),
          sid,
        );
      final transcript = t.transcript;
      // Same seq: the dedupe set rejects it before the switch.
      t.apply(
        const SseEvent(
          'run.failed',
          '{"run_id":"r1","session_id":"s","seq":7,"messages":[]}',
        ),
        sid,
      );
      // Re-delivered with a FRESH seq: terminal-once rejects it.
      t.apply(
        const SseEvent(
          'run.interrupted',
          '{"run_id":"r1","session_id":"s","seq":8,"messages":[]}',
        ),
        sid,
      );
      expect(t.terminalStatus, 'cancelled');
      expect(t.transcript, same(transcript));
    });

    test('wrong runId contradicts the known identity → ignored', () {
      final t = LiveTurn()
        ..runId = 'r1'
        ..apply(
          const SseEvent('run.cancelled', '{"run_id":"OTHER","seq":1}'),
          sid,
        );
      expect(t.terminalStatus, isNull);
      expect(t.completed, isFalse);
      // The right one still lands.
      t.apply(
        const SseEvent('run.cancelled', '{"run_id":"r1","seq":2}'),
        sid,
      );
      expect(t.terminalStatus, 'cancelled');
    });

    test('session contradiction keeps throwing exactly as before', () {
      final t = LiveTurn()..runId = 'r1';
      expect(
        () => t.apply(
          const SseEvent('run.cancelled', '{"session_id":"other"}'),
          sid,
        ),
        throwsA(isA<AppFormatException>()),
      );
    });
  });

  // ---- Controller: the terminal frame settles through ONE gate -----------

  test('A: terminal frame settles once; wrong-runId frame is ignored; a '
      'late stale-identity frame never touches the current turn', () async {
    final a = ctrlA();
    final sending = a.send('問題一');
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
    );
    await until(() => a.activeRunId == 'r1', 'run.started');
    // A frame naming a DIFFERENT run: not this turn's end.
    repo.events.add(
      const SseEvent('run.cancelled', '{"run_id":"OTHER","session_id":"s"}'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(a.busy, isTrue, reason: 'contradicting identity cannot settle');
    expect(a.phase, ChatPhase.sending);
    final readsBefore = repo.historyReads;
    repo.events.add(
      const SseEvent('run.cancelled', '{"run_id":"r1","session_id":"s"}'),
    );
    await until(() => !a.busy, 'cancelled frame settles');
    await sending;
    final status = repo.statusCalls;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(a.phase, ChatPhase.idle);
    expect(storeA.loadPending(url, sid), isNull, reason: 'one normal settle');
    // ONE settle: exactly one best-effort history merge, no recovery re-reads.
    expect(repo.historyReads, readsBefore + 1);
    expect(repo.statusCalls, status, reason: 'a frame needs no status probe');
    // A second turn on a NEW socket: the old run's terminal identity is
    // stale for it — only its own run may settle it.
    repo.openLane();
    final second = a.send('第二');
    repo.events
      ..add(const SseEvent('run.started', '{"run_id":"r2","session_id":"s"}'))
      ..add(const SseEvent('run.cancelled', '{"run_id":"r1","session_id":"s"}'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(a.busy, isTrue, reason: 'r1 is stale identity for turn r2');
    repo.events.add(
      const SseEvent('run.cancelled', '{"run_id":"r2","session_id":"s"}'),
    );
    await until(() => !a.busy, 'r2 settles');
    await second;
    a.dispose();
  });

  test('A: terminal frame then history GET 500 → settles, never busy, '
      'bounded (no recovery loop)', () async {
    repo.historyError = const ApiException('history down', 500);
    final a = ctrlA();
    final sending = a.send('問題一');
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
    );
    await until(() => a.activeRunId == 'r1', 'run.started');
    repo.events.add(
      const SseEvent('run.cancelled', '{"run_id":"r1","session_id":"s"}'),
    );
    await until(() => !a.busy, 'settle before history can block');
    await sending;
    expect(a.phase, ChatPhase.idle);
    expect(a.busy, isFalse);
    expect(keyOf(a.error), MessageKey.chatStateM024); // honest unreadable note
    final reads = repo.historyReads;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(a.phase, ChatPhase.idle, reason: 'a failing GET never re-opens busy');
    expect(a.reconnects, 0, reason: 'and never extends recovery');
    expect(repo.historyReads, reads, reason: 'exactly one best-effort GET');
    a.dispose();
  });

  test('A: terminal frame then a NEVER-COMPLETING history GET → settled, not '
      'busy, nothing pending (Completer parked forever)', () async {
    final gate = Completer<List<Message>>();
    repo.historyGate = gate;
    final a = ctrlA();
    unawaited(a.send('問題一')); // deliberately never awaited: the GET parks
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
    );
    await until(() => a.activeRunId == 'r1', 'run.started');
    repo.events.add(
      const SseEvent('run.failed', '{"run_id":"r1","session_id":"s",'
          '"error":"model exploded"}'),
    );
    await until(() => !a.busy, 'settle ahead of the hung GET');
    expect(a.phase, ChatPhase.idle);
    expect(keyOf(a.error), MessageKey.chatStateM018); // failed says failed
    expect(
      (a.error! as UiLocal).args['detail'],
      isA<UiRaw>()
          .having((r) => r.text, 'text', 'model exploded'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(a.phase, ChatPhase.idle, reason: 'the hung GET changed nothing');
    expect(a.reconnects, 0);
    // No timer of ours is armed: the settle already cancelled every
    // scheduler; the parked GET is a plain future with NO retry armed.
    expect(a.recoverySecondsRemaining, isNull);
    gate.complete(const []);
    await until(
      () => keyOf(a.error) == MessageKey.chatStateM018,
      'late merge keeps the failed wording',
    );
    a.dispose();
  });

  // ---- EOF paths ----------------------------------------------------------

  test('A: EOF only + runStatus cancelled → known-terminal convergence, '
      'neutral server-ended wording, never 「已由你停止」', () async {
    final a = ctrlA();
    repo.status = (_) => {'status': 'cancelled'};
    final sending = a.send('問題一');
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
    );
    await until(() => a.activeRunId == 'r1', 'run.started');
    await repo.events.close();
    await sending;
    expect(a.phase, ChatPhase.idle);
    expect(a.stopNoticeKind, StopNotice.serverEnded);
    expect(keyOf(a.stopNoticeMessage), MessageKey.chatStateM012);
    expect(
      a.stopNoticeMessage,
      isNot((UiLocal m) => m.key == MessageKey.chatStateStoppedByYou),
      reason: 'A never pressed stop — the server ended it (§6)',
    );
    expect(storeA.stopRecord(url, sid), isNull);
    expect(repo.statusCalls, 1, reason: 'ONE read of the SAME run');
    a.dispose();
  });

  test('A: EOF only + runStatus unreachable → EXISTING bounded unconfirmed '
      'recovery, untouched (recovering → uncertain, same phases)', () async {
    repo.statusError = const ApiException('status down', 503);
    final a = ctrlA();
    final phases = <ChatPhase>{};
    a.addListener(() => phases.add(a.phase));
    final sending = a.send('問題一');
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
    );
    await until(() => a.activeRunId == 'r1', 'run.started');
    await repo.events.close();
    await sending; // the failed probe falls through to recover(streamEnded)
    expect(
      phases,
      containsAll([ChatPhase.recovering, ChatPhase.uncertain]),
      reason: 'the same observed-stream-end ladder as reload_recovery',
    );
    expect(a.phase, ChatPhase.uncertain);
    // The EXISTING three-state landing check refines the wording to the
    // honest "delivered, reply loading" (the run's identity was positively
    // acknowledged) — exactly the reload_recovery/stuck_busy terminus.
    expect(
      keyOf(a.error),
      anyOf(
        MessageKey.chatStreamUnavailable,
        MessageKey.chatDeliveredReplyLoading,
      ),
    );
    expect(repo.statusCalls, 1, reason: 'ONE probe; recovery polls no status');
    expect(storeA.loadPending(url, sid), isNotNull, reason: 'retry evidence kept');
    a.dispose();
  });

  // ---- V09 matrix: every status, both discovery paths ---------------------

  group('V09 terminals × paths', () {
    for (final (frame, status, notice, errKey) in [
      ('run.completed', 'completed', StopNotice.none, null),
      ('run.cancelled', 'cancelled', StopNotice.serverEnded, null),
      ('run.failed', 'failed', StopNotice.none, MessageKey.chatStateM018),
      ('run.interrupted', 'interrupted', StopNotice.none, MessageKey.chatStateM018),
    ]) {
      test('$frame frame path', () async {
        final a = ctrlA();
        final sending = a.send('問題一');
        repo.events.add(
          const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
        );
        await until(() => a.activeRunId == 'r1', 'run.started');
        repo.events.add(
          SseEvent(frame, '{"run_id":"r1","session_id":"s"}'),
        );
        await repo.events.close();
        await until(() => !a.busy, 'frame settle');
        await sending;
        expect(a.phase, ChatPhase.idle, reason: frame);
        expect(a.stopNoticeKind, notice);
        if (errKey == null) {
          expect(a.error, isNull);
        } else {
          expect(keyOf(a.error), errKey, reason: '$frame keeps its own status');
        }
        expect(storeA.loadPending(url, sid), isNull);
        a.dispose();
      });

      test('$status EOF + status path', () async {
        final a = ctrlA();
        repo.status = (_) => {'status': status};
        final sending = a.send('問題一');
        repo.events.add(
          const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
        );
        await until(() => a.activeRunId == 'r1', 'run.started');
        await repo.events.close(); // EOF, NO terminal frame
        await sending;
        expect(a.phase, ChatPhase.idle, reason: status);
        expect(a.stopNoticeKind, notice);
        if (errKey == null) {
          expect(a.error, isNull);
        } else {
          expect(keyOf(a.error), errKey, reason: '$status keeps its own status');
        }
        expect(storeA.loadPending(url, sid), isNull);
        a.dispose();
      });
    }
  });

  test('A pressed stop ITSELF: the cancelled frame keeps the accepted-record '
      'wording (M030 path), not the neutral one', () async {
    final a = ctrlA();
    final sending = a.send('問題一');
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
    );
    await until(() => a.activeRunId == 'r1', 'run.started');
    final stop = await a.stop();
    expect(stop.success, isTrue);
    expect(storeA.stopRecord(url, sid), contains('r1'));
    repo.events.add(
      const SseEvent('run.cancelled', '{"run_id":"r1","session_id":"s"}'),
    );
    await until(() => !a.busy, 'own-stop provenance settle');
    await sending;
    expect(a.phase, ChatPhase.idle);
    expect(a.stopNoticeKind, StopNotice.accepted);
    expect(keyOf(a.stopNoticeMessage), MessageKey.chatStateStoppedByYou);
    expect(storeA.stopRecord(url, sid), contains('accepted'));
    expect(repo.stopLocal, ['r1']);
    a.dispose();
  });

  // ---- V08: dual device — B stops, A converges, B stays inert ------------

  test('V08: B stops A\'s run once; A settles ONCE from the cancelled frame; '
      'B has zero settle/journal/StopRecord/wake side effects', () async {
    repo.active = [aRun()]; // A's run, visible to the shared activity view
    final a = ctrlA();
    final b = await attached(ctrlB());
    final bBefore = snapshot(storeB);

    final sending = a.send('長任務');
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
    );
    await until(() => a.activeRunId == 'r1', 'A run.started');
    expect(repo.chatCalls, 1, reason: 'A created the run with ONE chat POST');

    // B: no live turn, no pending — discovers and stops the EXACT runId.
    expect(b.busy, isFalse);
    final target = b.remoteStopCandidates.single;
    expect(target.runId, 'r1');
    final out = await b.stopRemote(target);
    expect(out.kind, RemoteStopKind.requested);

    // The server scripts the cancelled frame onto A's still-open stream.
    repo.events.add(
      const SseEvent('run.cancelled', '{"run_id":"r1","session_id":"s"}'),
    );
    await until(() => !a.busy, 'A settles from the frame');
    await sending;

    // A: ONE normal settle — pending cleared, no stop POST, wake acks per
    // A's OWN rules (no batch here → zero).
    expect(a.phase, ChatPhase.idle);
    expect(storeA.loadPending(url, sid), isNull);
    expect(a.stopNoticeKind, StopNotice.serverEnded);
    expect(keyOf(a.stopNoticeMessage), MessageKey.chatStateM012);
    expect(repo.stopLocal, isEmpty, reason: 'A never stopped locally');

    // Ledger: EXACTLY one stop POST total — and it is B's remote one, aimed
    // at r1; a 200 means reconciliation is GETs only.
    expect(repo.stopRemote, ['r1'], reason: 'exactly ONE stop POST, right run');
    expect(repo.stopLocal, isEmpty);

    // B: side-effect-free, checked in B's OWN store.
    expect(storeB.loadPending(url, sid), isNull);
    expect(storeB.listAttempts(url, sid), isEmpty);
    expect(storeB.stopRecord(url, sid), isNull);
    expect(storeB.wakeState(url, sid), isNull);
    expect(snapshot(storeB), equals(bBefore),
        reason: 'B\'s device persisted NOTHING');
    expect(b.busy, isFalse);
    expect(b.stopNoticeKind, StopNotice.none);
    expect(b.phase, ChatPhase.idle);
    expect(repo.wakeAcks, isEmpty, reason: 'B never acked (§7 V15)');

    // The observer then converges from GETs alone (still one POST).
    repo.status = (_) => {'status': 'cancelled'};
    await until(
      () => b.remoteStopPhaseState == RemoteStopPhaseState.ended,
      'B observer sees terminal via GETs',
    );
    expect(repo.stopRemote, ['r1'], reason: 'convergence is read-only');
    a.dispose();
    b.dispose();
  });

  // ---- V15: wake cleanup rides the terminal path unchanged ---------------

  test('wake batch: the terminal frame acks terminal per EXISTING rules; '
      'device B contributes zero acks', () async {
    storeA.setAutoWakeEnabled(url, true);
    await storeA.saveWakeState(url, sid, {
      'batches': [
        {
          'batch_id': 'wb_1',
          'state': 'dispatched',
          'anchor_after_id': 5,
          'canonical_input': AutoWakeContract.canonicalInput,
          'delivery_keys': ['k1'],
          'items': [
            {'dk': 'k1', 'order': 6},
          ],
          'at': '2026-10-02T00:00:00.000Z',
        },
      ],
    });
    final a = ctrlA();
    await a.load(); // commits history through the wake observer (arms _wake)
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final b = ctrlB();
    b.attach();
    final sending = a.send(
      AutoWakeContract.canonicalInput,
      wakeBatch: 'wb_1',
      suppressPending: true,
    );
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
    );
    await until(() => a.activeRunId == 'r1', 'wake run.started');
    repo.events.add(
      const SseEvent('run.cancelled', '{"run_id":"r1","session_id":"s"}'),
    );
    await until(() => !a.busy, 'wake turn settles');
    await sending;
    expect(a.phase, ChatPhase.idle);
    expect(a.stopNoticeKind, StopNotice.serverEnded); // A pressed nothing
    // EXISTING rules: run.started acked 'accepted', the settle acks
    // 'terminal' — exactly what the completed path does (wake_dispatch).
    expect(
      repo.wakeAcks,
      containsAllInOrder([
        ('wb_1', 'accepted'),
        ('wb_1', 'terminal'),
      ]),
    );
    // B touched no ledger: its own store carries no wake state at all.
    expect(storeB.wakeState(url, sid), isNull);
    expect(storeB.loadPending(url, sid), isNull);
    expect(snapshot(storeB), isEmpty);
    a.dispose();
    b.dispose();
  });
}
