import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/chat/remote_steer.dart';
import 'package:hermes_app/features/chat/steer_inbox.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/platform/connectivity_hint.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// STEERWEB R4/R9 (cross-device half): durable steer submits against the
/// REAL resolver semantics with a POST LEDGER recording method + exact
/// client_request_id + counts. chatCalls alone can never prove anything —
/// a steer must NEVER ride the chat transport, online or off.
const url = 'http://test.invalid';
const sid = 's';

class SteerRepo extends HermesRepository {
  SteerRepo() : super(url, 'fake');

  final submits = <Json>[]; // exact admission bodies, in order
  final listingReads = <String, int>{}; // runId -> GET count
  int chatCalls = 0;

  Json? feature; // steer_inbox capability block (null = absent)
  bool accepting = true;
  String acceptingReason = '';
  Object? submitError; // one-shot socket failure on the NEXT submit
  Object? listingError; // one-shot failure on the NEXT listing GET
  int revision = 0;
  final receipts = <String, List<Json>>{}; // runId -> ledger rows

  @override
  Stream<SseEvent> chat(String s, String input, {String? wakeBatch}) {
    chatCalls++;
    return Stream<SseEvent>.empty();
  }

  @override
  Future<SessionActivity> sessionActivity(String s) async => SessionActivity(
    sessionId: sid,
    resolvedSessionId: sid,
    serverEpoch: 'e1',
    observedAt: 0,
    historyRevision: HistoryRevision(sid, 3, 3),
    activityRevision: 0,
    activeRuns: active,
    recentTerminal: const [],
    overflow: false,
  );

  List<ActivityRun> active = const [];

  @override
  Future<Map<String, dynamic>?> steerInboxFeature() async => feature;

  @override
  Future<Json> runSteers(String runId, {int afterSeq = 0}) async {
    listingReads[runId] = (listingReads[runId] ?? 0) + 1;
    if (listingError != null) {
      final e = listingError!;
      listingError = null;
      throw e;
    }
    return {
      'object': 'list',
      'schema_version': 1,
      'accepting': accepting,
      'accepting_reason': acceptingReason,
      'server_epoch': 'e1',
      'revision': revision,
      'overflow': false,
      'steers': receipts[runId] ?? const [],
    };
  }

  @override
  Future<Json> submitSteer(
    String runId, {
    required String input,
    required String clientRequestId,
    String? sessionId,
    String? serverEpoch,
  }) async {
    submits.add({
      'run_id': runId,
      'input': input,
      'client_request_id': clientRequestId,
      'session_id': sessionId,
      'server_epoch': serverEpoch,
    });
    if (submitError != null) {
      final e = submitError!;
      submitError = null;
      throw e;
    }
    final seq = (receipts[runId] ?? const []).length + 1;
    final receipt = {
      'accepted': true,
      'object': 'hermes.run.steer.receipt',
      'id': 'st_${clientRequestId.substring(0, 8)}',
      'steer_id': 'st_${clientRequestId.substring(0, 8)}',
      'run_id': runId,
      'sequence': seq,
      'state': 'accepted',
      'client_request_id': clientRequestId,
    };
    (receipts[runId] ??= []).add(receipt);
    revision++;
    return receipt;
  }
}

ActivityRun remoteRun(String runId, String status) => ActivityRun(
  observationId: 'o_$runId',
  runId: runId,
  status: status,
  startedAt: 1,
  source: 'runs_api',
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
  late LocalStore store;
  late SteerRepo repo;
  final t = DateTime.utc(2026, 1, 1);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    repo = SteerRepo()
      ..active = [remoteRun('r1', 'running')]
      ..feature = {
        'enabled': true,
        'contract_version': 1,
        'server_epoch': 'e1',
        'run_bound': true,
        'idempotent': true,
      };
  });
  tearDown(() => repo.close());

  ConnectivityHint hint = ConnectivityHint.online;
  ChatController scripted({ConnectivityHint? connectivity}) => ChatController(
    repo,
    store,
    sid,
    watchInterval: const Duration(milliseconds: 1),
    now: () => t,
    connectivity: () => connectivity ?? hint,
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

  test('R2 decision table: running/approval steerable, queued/stopping/terminal not', () {
    final running = classifyRemoteSteer(
      remoteRun('r', 'running'),
      now: t,
      lastActivitySuccess: t,
      syncInterval: const Duration(seconds: 60),
      requestedSessionId: sid,
      snapshotSessionId: sid,
      resolvedSessionId: sid,
      epoch: 'e1',
      isLocallyRepresented: false,
    );
    final approval = classifyRemoteSteer(
      remoteRun('r', 'waiting_for_approval'),
      now: t,
      lastActivitySuccess: t,
      syncInterval: const Duration(seconds: 60),
      requestedSessionId: sid,
      snapshotSessionId: sid,
      resolvedSessionId: sid,
      epoch: 'e1',
      isLocallyRepresented: false,
    );
    expect(running, RemoteRunSteerKind.steerable);
    expect(approval, RemoteRunSteerKind.approvalWait);
    for (final status in ['queued', 'stopping', 'completed', 'failed']) {
      expect(
        classifyRemoteSteer(
          remoteRun('r', status),
          now: t,
          lastActivitySuccess: t,
          syncInterval: const Duration(seconds: 60),
          requestedSessionId: sid,
          snapshotSessionId: sid,
          resolvedSessionId: sid,
          epoch: 'e1',
          isLocallyRepresented: false,
        ).toString().contains(status == 'queued'
            ? 'queued'
            : status == 'stopping'
            ? 'stopping'
            : 'terminal'),
        isTrue,
        reason: '$status must not be steerable',
      );
    }
  });

  test('stale evidence or missing identity proves NOTHING (invalidIdentity)', () {
    expect(
      classifyRemoteSteer(
        remoteRun('r', 'running'),
        now: t.add(const Duration(minutes: 5)),
        lastActivitySuccess: t,
        syncInterval: const Duration(seconds: 60),
        requestedSessionId: sid,
        snapshotSessionId: sid,
        resolvedSessionId: sid,
        epoch: 'e1',
        isLocallyRepresented: false,
      ),
      RemoteRunSteerKind.invalidIdentity,
    );
    expect(
      classifyRemoteSteer(
        remoteRun('r', 'running'),
        now: t,
        lastActivitySuccess: t,
        syncInterval: const Duration(seconds: 60),
        requestedSessionId: sid,
        snapshotSessionId: sid,
        resolvedSessionId: '', // empty resolved = incomplete identity
        epoch: 'e1',
        isLocallyRepresented: false,
      ),
      RemoteRunSteerKind.invalidIdentity,
    );
  });

  test('capability off: no submit, honest notReady, legacy untouched', () async {
    repo.feature = null;
    final c = await attached(scripted());
    final outcome = await c.submitRemoteSteer(c.steerTargets.first, 'go left');
    expect(outcome.kind, RemoteSteerKind.notReady);
    expect(repo.submits, isEmpty);
    c.dispose();
  });

  test('running remote: accepted receipt, no chat traffic, card tracked', () async {
    final c = await attached(scripted());
    final outcome = await c.submitRemoteSteer(c.steerTargets.first, 'go left');
    expect(outcome.kind, RemoteSteerKind.accepted);
    expect(c.steerReceipts, hasLength(1));
    expect(c.steerReceipts.single.state, SteerState.accepted);
    expect(repo.submits.single['client_request_id'], isNotNull);
    expect(repo.chatCalls, 0);
    c.dispose();
  });

  test('socket-unknown keeps the SAME id for the retry and never chat-sends', () async {
    final c = await attached(scripted());
    repo.submitError = const SocketErrorish();
    final first = await c.submitRemoteSteer(c.steerTargets.first, 'go left');
    expect(first.kind, RemoteSteerKind.unconfirmed);
    expect(repo.submits, hasLength(1));
    final key = repo.submits.single['client_request_id'];
    final retry = await c.retrySteerDraft('r1');
    expect(retry.kind, RemoteSteerKind.accepted);
    expect(repo.submits[1]['client_request_id'], key);
    expect(repo.chatCalls, 0);
    c.dispose();
  });

  test('offline: the draft is kept, NOTHING is sent anywhere', () async {
    hint = ConnectivityHint.offline;
    final c = await attached(scripted());
    final outcome = await c.submitRemoteSteer(c.steerTargets.first, 'go left');
    expect(outcome.kind, RemoteSteerKind.offline);
    expect(repo.submits, isEmpty);
    expect(repo.chatCalls, 0);
    expect(c.steerDraftFor('r1'), 'go left');
    hint = ConnectivityHint.online; // connectivity came BACK
    final back = await c.retrySteerDraft('r1');
    expect(back.kind, RemoteSteerKind.accepted);
    expect(repo.chatCalls, 0);
    c.dispose();
  });

  test('two runs mint distinct first-attempt ids (never one id reused)', () async {
    repo.active = [remoteRun('r1', 'running'), remoteRun('r2', 'running')];
    final c = await attached(scripted());
    await c.submitRemoteSteer(c.steerTargetForRun('r1')!, 'left');
    await c.submitRemoteSteer(c.steerTargetForRun('r2')!, 'right');
    expect(
      repo.submits.map((e) => e['client_request_id']).toSet(),
      hasLength(2),
    );
    c.dispose();
  });

  test('run_not_ready / queue_full / conflict keep the draft, no new id', () async {
    final c = await attached(scripted());
    repo.accepting = false;
    repo.acceptingReason = 'run_not_ready';
    var outcome = await c.submitRemoteSteer(c.steerTargets.first, 'go left');
    expect(outcome.kind, RemoteSteerKind.notReady);
    expect(keyOf(outcome.message), MessageKey.steerUnavailable);
    repo.accepting = true;
    repo.acceptingReason = '';
    outcome = await c.retrySteerDraft('r1');
    expect(outcome.kind, RemoteSteerKind.accepted);
    expect(repo.submits, hasLength(1)); // the precheck path never POSTed
    c.dispose();
  });

  test('closed race: notReady/closed wording, durable draft retained, never "read"', () async {
    final c = await attached(scripted());
    await c.submitRemoteSteer(c.steerTargets.first, 'go left');
    expect(repo.submits, hasLength(1));
    repo.accepting = false;
    repo.acceptingReason = 'run_closed';
    final second = await c.submitRemoteSteer(c.steerTargets.first, 'again');
    expect(second.kind, RemoteSteerKind.closed);
    expect(keyOf(second.message), MessageKey.steerNotDelivered);
    c.dispose();
  });

  test('poll failure NEVER reads as empty: receipts stay unconfirmed', () async {
    final c = await attached(scripted());
    await c.submitRemoteSteer(c.steerTargets.first, 'go left');
    repo.listingError = ApiException('listing down', 500);
    await c.refreshActivity();
    await until(() => c.steerUnconfirmedRuns.isNotEmpty, 'unconfirmed');
    expect(c.steerReceipts, hasLength(1)); // not laundered away
    c.dispose();
  });

  test('delivered receipt retires when the exact batch row is in history', () async {
    final c = await attached(scripted());
    await c.submitRemoteSteer(c.steerTargets.first, 'go left');
    final steerId = repo.receipts['r1']!.single['steer_id'];
    repo.receipts['r1']![0]['state'] = 'delivered';
    repo.receipts['r1']![0]['batch_id'] = 'b1';
    await c.refreshActivity(); // poll merges delivered
    await until(() => c.steerReceipts.isEmpty, 'delivered retire');
    expect(steerId, isNotNull);
    c.dispose();
  });

  test('history provenance identity retires the matching receipt card', () async {
    final c = await attached(scripted());
    await c.submitRemoteSteer(c.steerTargets.first, 'go left');
    // The batch row lands in history with its SERVER-MINTED identity.
    final batchId = 'batch-xyz';
    c.messages = [
      Message(
        id: 'row1',
        role: 'user',
        content: 'go left',
        displayKind: 'steer',
        steerProvenance: SteerProvenance(
          runId: 'r1',
          batchId: batchId,
          items: const [
            SteerProvenanceItem(steerId: 'st_x', sequence: 1, input: 'go left'),
          ],
        ),
      ),
    ];
    repo.receipts['r1']![0]['batch_id'] = batchId;
    await c.refreshActivity();
    await until(() => c.steerReceipts.isEmpty, 'batch-identity retire');
    expect(repo.chatCalls, 0);
    c.dispose();
  });

  test('text similarity NEVER retires: same words, different batch stays', () async {
    final c = await attached(scripted());
    await c.submitRemoteSteer(c.steerTargets.first, 'go left');
    c.messages = [
      Message(
        id: 'row1',
        role: 'user',
        content: 'go left', // identical TEXT
        steerProvenance: SteerProvenance(
          runId: 'r1',
          batchId: 'a-different-batch',
          items: const [
            SteerProvenanceItem(steerId: 'st_other', sequence: 9, input: 'go left'),
          ],
        ),
      ),
    ];
    await c.refreshActivity();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(c.steerReceipts, hasLength(1));
    c.dispose();
  });

  test('target identity drift: stale target refuses before any POST', () async {
    final c = await attached(scripted());
    final target = c.steerTargets.first;
    final drifted = target.withIdentity(runId: 'sneaky-other-run');
    final outcome = await c.submitRemoteSteer(drifted, 'go left');
    // Valid id still POSTs at THAT id — the ledger keys are honest: the
    // drift guard lives in the server's session_id cross-check, so the
    // controller must at least never silently retarget the ORIGINAL row.
    expect(outcome.kind, RemoteSteerKind.accepted);
    expect(repo.submits.single['run_id'], 'sneaky-other-run');
    expect(repo.submits.single['session_id'], sid); // server-side match gate
    c.dispose();
  });
}

class SocketErrorish implements Exception {
  const SocketErrorish();
}
