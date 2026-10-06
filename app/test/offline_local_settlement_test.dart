import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/chat/local_attempt.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'stuck_busy_recovery_test.dart' show SBRepo;

/// OFFLINE-SEND R2 §4.2: the LOCAL settlement transaction. Every exit here
/// posts NOTHING — the zero-POST ledger (repo.sends / repo.stopCalls /
/// wake acks) is asserted in every scenario.
class WakeCountingRepo extends SBRepo {
  int wakeAcks = 0;
  @override
  Future<void> wakeAck(
    String sid,
    String batchId,
    String state, {
    String? runId,
  }) async {
    wakeAcks++;
  }
}

/// Stops INSIDE claimPending so a /stop can land while the claim mint is
/// still in flight (§4.3 "claim 尚未完成時先標記停止意圖").
class _GatedClaims extends LocalStore {
  _GatedClaims(super.prefs);
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<String?> claimPending(
    String server,
    String sid, {
    required String userText,
    required String turnId,
    DateTime? startedAt,
    int? historyAfterId,
    String? origin,
    String? wakeBatchId,
    Duration lease = LocalStore.pendingLease,
  }) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return super.claimPending(
      server,
      sid,
      userText: userText,
      turnId: turnId,
      startedAt: startedAt,
      historyAfterId: historyAfterId,
      origin: origin,
      wakeBatchId: wakeBatchId,
      lease: lease,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late LocalStore store;
  late SBRepo repo;
  late DateTime t;
  final t0 = DateTime.utc(2026, 1, 1);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = LocalStore(prefs);
    repo = SBRepo();
    t = t0;
  });
  tearDown(() {
    LocalStore.debugEndAttemptHook = null;
    LocalStore.debugFailAttemptWrites = false;
    repo.close();
  });

  ChatController scripted({LocalStore? s, HermesRepository? r}) => ChatController(
    r ?? repo,
    s ?? store,
    's',
    watchInterval: const Duration(milliseconds: 1),
    now: () => t,
  );

  Map<String, Object?> snapshot() => {
    for (final k in prefs.getKeys()) k: prefs.get(k),
  };

  /// A human attempt mid-recovery whose budget was stamped at t0 (so the
  /// scripted t0+61 bootstrap lands the honest uncertain shape).
  Future<String> seedWaitingTurn(
    String userText, {
    String? draft,
    Duration lease = LocalStore.pendingLease,
  }) async {
    final token = await store.claimPending(
      repo.baseUrl,
      's',
      userText: userText,
      turnId: 't1',
      lease: lease,
    );
    await store.beginPendingRecovery(
      repo.baseUrl,
      's',
      token: token,
      now: t0,
    );
    if (draft != null) await store.saveDraft(repo.baseUrl, 's', draft);
    return token!;
  }

  test('local end: journal-first, zero POSTs, abandoned tombstone, verbatim draft', () async {
    // i18n-exempt: draft-preservation fixture bytes, not UI text.
    const raw = ' 打完的草稿😀 \n第二行 ';
    final token = await seedWaitingTurn('問題一', draft: raw);
    final attemptId = store.loadPending(repo.baseUrl, 's')!.attemptId!;
    t = t0.add(const Duration(seconds: 61));
    final c = scripted();
    await c.bootstrap();
    expect(c.phase, ChatPhase.uncertain);
    expect(c.canEndLocalWaiting, isTrue);
    final f1 = c.stop();
    final f2 = c.stop();
    expect(identical(f1, f2), isTrue); // double-tap JOINS, never lies twice
    final r = await f1;
    expect(r.kind, StopResultKind.localWaitingEnded);
    expect(r.success, isTrue);
    expect(r.attemptId, attemptId);
    expect(r.cleanup, 'done');
    expect(r.restoreDraft, raw); // verbatim, never trimmed
    expect(store.loadPending(repo.baseUrl, 's'), isNull);
    final tomb = store.loadAttempt(repo.baseUrl, 's', attemptId)!;
    expect(tomb.disposition, AttemptDisposition.abandoned);
    expect(tomb.origin, 'human');
    expect(tomb.rawDraft, raw);
    expect(tomb.terminalEvidence?['ended_by_token'], token);
    expect(c.phase, ChatPhase.idle);
    expect((c.error! as UiLocal).key, MessageKey.chatLocalWaitingEnded);
    expect(repo.sends, 0);
    expect(repo.stopCalls, 0);
    c.dispose();
  });

  test('stop during claim ends its OWN claim before any repo.chat', () async {
    final gated = _GatedClaims(prefs);
    final c = scripted(s: gated);
    final sending = c.send('問題一');
    final stop = c.stop(); // while the claim mint is still in flight
    await gated.entered.future;
    gated.release.complete();
    final r = await stop;
    await sending;
    expect(r.kind, StopResultKind.localWaitingEnded);
    expect(r.success, isTrue);
    expect(repo.sends, 0); // the POST never happened, in either direction
    expect(store.loadPending(repo.baseUrl, 's'), isNull);
    final attempts = store.listAttempts(repo.baseUrl, 's');
    expect(attempts, hasLength(1));
    expect(attempts.single.disposition, AttemptDisposition.abandoned);
    expect(c.sendOutcome, SendOutcome.localSettled);
    expect(c.phase, ChatPhase.idle);
    c.dispose();
  });

  test('crash between journal and delete: cleanup-only residue, one retry clears it', () async {
    const raw = 'A 草稿  ';
    final token = await seedWaitingTurn('問題一', draft: raw);
    final attemptId = store.loadPending(repo.baseUrl, 's')!.attemptId!;
    LocalStore.debugEndAttemptHook = (phase) async {
      if (phase == 'afterJournal') {
        LocalStore.debugEndAttemptHook = null;
        throw StateError('crash after the tombstone write');
      }
    };
    t = t0.add(const Duration(seconds: 61));
    final c = scripted();
    await c.bootstrap();
    final r = await c.stop();
    expect(r.kind, StopResultKind.localWaitingEnded);
    expect(r.cleanup, 'pending'); // tombstone landed, delete did not
    expect(store.loadPending(repo.baseUrl, 's'), isNotNull);
    expect(store.loadPending(repo.baseUrl, 's')!.token, token);
    expect(
      store.loadAttempt(repo.baseUrl, 's', attemptId)!.disposition,
      AttemptDisposition.abandoned,
    );
    c.dispose();

    // A fresh bootstrap sees the matching tombstone: NO re-armed window,
    // no timers, no auto-restore — only the local cleanup retry.
    final d = scripted();
    await d.bootstrap();
    expect(d.phase, ChatPhase.uncertain);
    expect((d.error! as UiLocal).key, MessageKey.chatStateM025);
    expect(d.localCleanupRetryAvailable, isTrue);
    expect(d.canStop, isFalse);
    expect(d.canEndLocalWaiting, isFalse);
    expect(d.recoverySecondsRemaining, isNull);
    expect(d.recoveryRetryAvailable, isFalse);
    expect(store.draft(repo.baseUrl, 's'), raw); // never silently restored
    final gets = repo.statusCalls + repo.reads;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(repo.statusCalls + repo.reads, gets); // zero polling, zero timers
    final q = await d.retryLocalCleanup();
    expect(q.kind, StopResultKind.localWaitingEnded);
    expect(q.cleanup, 'done');
    expect(store.loadPending(repo.baseUrl, 's'), isNull);
    expect(d.phase, ChatPhase.idle);
    expect(repo.sends, 0);
    expect(repo.stopCalls, 0);
    d.dispose();
  });

  test('journal refusal writes NOTHING and stays retryable', () async {
    final token = await seedWaitingTurn('問題一', draft: '草稿');
    final attemptId = store.loadPending(repo.baseUrl, 's')!.attemptId!;
    LocalStore.debugFailAttemptWrites = true;
    t = t0.add(const Duration(seconds: 61));
    final c = scripted();
    await c.bootstrap();
    final before = snapshot();
    final r = await c.stop();
    expect(r.kind, StopResultKind.failure);
    expect((r.message! as UiLocal).key, MessageKey.chatRecoveryStorageFailed);
    expect(snapshot(), before); // not one key moved
    expect(store.loadPending(repo.baseUrl, 's')!.token, token);
    expect(
      store.loadAttempt(repo.baseUrl, 's', attemptId)!.disposition,
      AttemptDisposition.waiting,
    );
    expect(c.phase, ChatPhase.uncertain); // never settled over a failed journal
    expect(c.busy, isTrue);
    LocalStore.debugFailAttemptWrites = false;
    final r2 = await c.stop(); // the gate never locked: retry works
    expect(r2.kind, StopResultKind.localWaitingEnded);
    expect(r2.cleanup, 'done');
    expect(store.loadPending(repo.baseUrl, 's'), isNull);
    expect(repo.sends, 0);
    c.dispose();
  });

  test('takeover mid-flight: M021, the moved record survives untouched', () async {
    final token = await seedWaitingTurn('問題一', lease: const Duration(milliseconds: 1));
    t = t0.add(const Duration(seconds: 61));
    final c = scripted();
    await c.bootstrap();
    expect(c.phase, ChatPhase.uncertain);
    final other = LocalStore(prefs); // a different tab identity
    final token2 = await other.claimPending(
      repo.baseUrl,
      's',
      userText: '新回合',
      turnId: 'z2',
    );
    expect(token2, isNotNull);
    expect(store.loadPending(repo.baseUrl, 's')!.token, token2);
    final before = snapshot();
    final r = await c.stop();
    expect(r.kind, StopResultKind.failure);
    expect((r.message! as UiLocal).key, MessageKey.chatStateM021);
    expect(r.success, isFalse);
    expect(snapshot(), before); // zero writes onto the new claim
    expect(store.loadPending(repo.baseUrl, 's')!.token, token2);
    expect(c.phase, ChatPhase.idle); // the stale page retires; the record stays
    expect(token, isNotNull);
    c.dispose();
  });

  test('autoWake record without a run: human local end never consumes it', () async {
    final wake = WakeCountingRepo();
    repo = wake;
    final token = await store.claimPending(
      wake.baseUrl,
      's',
      userText: 'wake',
      turnId: 'w1',
      origin: 'autoWake',
      wakeBatchId: 'b1',
    );
    await store.beginPendingRecovery(wake.baseUrl, 's', token: token, now: t0);
    t = t0.add(const Duration(seconds: 61));
    final c = scripted(r: wake);
    await c.bootstrap();
    final r = await c.stop();
    expect(r.kind, StopResultKind.noTurn);
    expect(r.success, isFalse);
    expect((c.error! as UiLocal).key, MessageKey.chatStateM029);
    expect(wake.wakeAcks, 0);
    expect(wake.sends, 0);
    expect(wake.stopCalls, 0);
    expect(store.loadPending(wake.baseUrl, 's')!.token, token);
    expect(c.busy, isTrue); // the wake keeps its own ledger handling
    c.dispose();
  });

  test('stop with nothing outstanding: noTurn, zero writes', () async {
    final c = scripted();
    await c.bootstrap();
    expect(c.phase, ChatPhase.idle);
    final before = snapshot();
    final r = await c.stop();
    expect(r.kind, StopResultKind.noTurn);
    expect(r.success, isFalse);
    expect(snapshot(), before);
    expect(repo.sends, 0);
    expect(repo.stopCalls, 0);
    c.dispose();
  });
}
