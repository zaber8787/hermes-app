// OFFLINE-SEND R1: bounded recovery + local bootstrap.
//
// Everything runs on an injected clock (never a real 60s sleep). The fake
// repo ledger counts chat POSTs, stop POSTs and history reads so every
// bounded-wait claim is checked against "zero mutations" too.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';
import 'package:hermes_app/models/message.dart';

import 'stuck_busy_recovery_test.dart' show SBRepo;

final t0 = DateTime.utc(2026, 1, 1);
final kKey = '${Uri.encodeComponent('http://test.invalid')}.s.pending';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late LocalStore store;
  late SBRepo repo;
  late DateTime t;
  DateTime clock() => t;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = LocalStore(prefs);
    repo = SBRepo();
    t = t0;
  });
  tearDown(() => repo.close());

  Future<void> settle([int ms = 20]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  ChatController ctl() => ChatController(
    repo,
    store,
    's',
    watchInterval: const Duration(milliseconds: 1),
    now: clock,
  );

  MessageKey keyOf(UiMessage? m) => (m! as UiLocal).key;

  // ---- §3.2 persistence migration table (each row measured) --------------
  group('begin-once migration table', () {
    test('watermark-only record (id 77) is NOT a budget: begins 60s once',
        () async {
      prefs.remove(kKey);
      await store.savePending('http://test.invalid', 's', userText: 'q');
      prefs.setString(
        kKey,
        '{"user_text":"q","started_at":"${t0.toIso8601String()}",'
        '"history_after_id":77}',
      );
      expect(
        (store.loadPending('http://test.invalid', 's'))!.hasRecoveryBudget,
        isFalse,
      );
      final b = await store.beginPendingRecovery(
        'http://test.invalid',
        's',
        now: t0,
      );
      expect(b.outcome, PendingRecoveryOutcome.begun);
      expect(b.record!.recoveryDeadline, t0.add(const Duration(seconds: 60)));
      expect(b.record!.historyAfterId, 77); // watermark survived
      // reload: same deadline verbatim (begin never re-arms).
      final again = await store.beginPendingRecovery(
        'http://test.invalid',
        's',
        now: t0.add(const Duration(seconds: 40)),
      );
      expect(again.outcome, PendingRecoveryOutcome.alreadyPresent);
      expect(
        again.record!.recoveryDeadline,
        t0.add(const Duration(seconds: 60)),
      );
    });

    test('empty pending begins 60s from FIRST recovery, not startedAt',
        () async {
      prefs.remove(kKey);
      await store.savePending(
        'http://test.invalid',
        's',
        userText: 'q',
        startedAt: t0.subtract(const Duration(days: 1)),
      );
      final b = await store.beginPendingRecovery(
        'http://test.invalid',
        's',
        now: t0,
      );
      expect(b.outcome, PendingRecoveryOutcome.begun);
      expect(b.record!.recoveryDeadline, t0.add(const Duration(seconds: 60)));
    });

    test('valid deadline kept verbatim; missing started back-computed',
        () async {
      final d = t0.add(const Duration(seconds: 20));
      prefs.remove(kKey);
      prefs.setString(
        kKey,
        '{"user_text":"q","started_at":"${t0.toIso8601String()}",'
        '"recovery_deadline":"${d.toIso8601String()}"}',
      );
      final b = await store.beginPendingRecovery(
        'http://test.invalid',
        's',
        now: t0.add(const Duration(hours: 5)),
      );
      expect(b.outcome, PendingRecoveryOutcome.alreadyPresent);
      expect(b.record!.recoveryDeadline, d);
      expect(
        b.record!.recoveryStartedAt,
        d.subtract(const Duration(seconds: 60)),
      );
    });

    test('started-only migrates to started+60 — expired stays expired',
        () async {
      final start = t0.subtract(const Duration(seconds: 120));
      prefs.remove(kKey);
      prefs.setString(
        kKey,
        '{"user_text":"q","started_at":"${t0.toIso8601String()}",'
        '"recovery_started_at":"${start.toIso8601String()}"}',
      );
      final b = await store.beginPendingRecovery(
        'http://test.invalid',
        's',
        now: t0,
      );
      expect(b.outcome, PendingRecoveryOutcome.begun);
      expect(b.record!.recoveryDeadline, start.add(const Duration(seconds: 60)));
      // NOT rebased to now+60 — the window already expired.
      expect(
        b.record!.recoveryDeadline!.isBefore(t0),
        isTrue,
      );
    });

    test('retry-used WITHOUT deadline migrates EXPIRED, never a fresh 30s',
        () async {
      prefs.remove(kKey);
      prefs.setString(
        kKey,
        '{"user_text":"q","started_at":"${t0.toIso8601String()}",'
        '"recovery_retry_used":true}',
      );
      final b = await store.beginPendingRecovery(
        'http://test.invalid',
        's',
        now: t0,
      );
      expect(b.outcome, PendingRecoveryOutcome.begun);
      expect(b.record!.recoveryRetryUsed, isTrue); // flag survived
      expect(b.record!.recoveryDeadline, t0); // already due
      final c = await store.consumeRecoveryRetry(
        'http://test.invalid',
        's',
        now: t0,
      );
      expect(c.outcome, RecoveryRetryOutcome.alreadyUsed);
      expect(c.record!.recoveryDeadline, t0); // no 30s window minted
    });

    test('consume without any valid budget never mints a window', () async {
      prefs.remove(kKey);
      await store.savePending('http://test.invalid', 's', userText: 'q');
      final c = await store.consumeRecoveryRetry(
        'http://test.invalid',
        's',
        now: t0,
      );
      expect(c.outcome, RecoveryRetryOutcome.alreadyUsed);
      expect(store.loadPending('http://test.invalid', 's')!.recoveryDeadline,
          isNull);
    });

    test('two stores consuming the allowance: exactly one wins', () async {
      prefs.remove(kKey);
      await store.savePending('http://test.invalid', 's', userText: 'q');
      await store.beginPendingRecovery('http://test.invalid', 's', now: t0);
      final b = LocalStore(prefs); // second "tab", same backing store
      final r1 = await store.consumeRecoveryRetry(
        'http://test.invalid',
        's',
        now: t0.add(const Duration(seconds: 40)),
      );
      final r2 = await b.consumeRecoveryRetry(
        'http://test.invalid',
        's',
        now: t0.add(const Duration(seconds: 41)),
      );
      final outcomes = [r1.outcome, r2.outcome];
      expect(
        outcomes.where((o) => o == RecoveryRetryOutcome.consumed).length,
        1,
      );
      expect(
        outcomes.where((o) => o == RecoveryRetryOutcome.alreadyUsed).length,
        1,
      );
      expect(
        r1.record!.recoveryDeadline,
        r2.record!.recoveryDeadline,
      ); // both see the SAME persisted deadline
    });

    test('missing record / foreign token: no write, old observation ends',
        () async {
      prefs.remove(kKey);
      final m = await store.beginPendingRecovery(
        'http://test.invalid',
        's',
        now: t0,
      );
      expect(m.outcome, PendingRecoveryOutcome.missing);
      await store.savePending('http://test.invalid', 's', userText: 'q');
      final tok = (await store.claimPending(
        'http://test.invalid',
        's',
        userText: 'q',
        turnId: '9',
      ))!;
      final bad = await store.beginPendingRecovery(
        'http://test.invalid',
        's',
        token: 'not-mine|1',
        now: t0,
      );
      expect(bad.outcome, PendingRecoveryOutcome.mismatch);
      expect(
        store.loadPending('http://test.invalid', 's')!.hasRecoveryBudget,
        isFalse,
      );
      expect(await store.clearPending('http://test.invalid', 's', token: tok),
          isTrue);
    });
  });

  // ---- §3.3 timer & control-flow contract ----------------------------------
  group('bounded waits with injected clock', () {
    test('60.000s expires, 59.999s does not; late 200 dies; zero POSTs',
        () async {
      await store.savePending(
        'http://test.invalid',
        's',
        userText: '問題一',
        runId: 'r',
      );
      repo.history = const [Message(id: '1', role: 'user', content: '問題一')];
      final hang = Completer<Map<String, dynamic>>();
      var released = false;
      repo.status = (runId) {
        if (released) return {'status': 'running'};
        return hang.future;
      };
      final c = ctl();
      await c.bootstrap();
      expect(c.phase, ChatPhase.recovering);
      t = t0.add(const Duration(seconds: 59)).add(const Duration(milliseconds: 999));
      await settle(30);
      expect(c.phase, ChatPhase.recovering); // not yet
      t = t0.add(const Duration(seconds: 60)); // exact boundary counts
      await settle(30);
      expect(c.phase, ChatPhase.uncertain);
      expect(keyOf(c.error), MessageKey.chatRecoveryUncertain);
      expect(c.busy, isTrue);
      released = true;
      hang.complete({'status': 'running'}); // the late 200
      await settle(30);
      expect(c.phase, ChatPhase.uncertain); // revived? NO
      expect(repo.sends, 0);
      c.dispose();
    });

    test('GET black hole: without runId still expires on schedule', () async {
      await store.savePending('http://test.invalid', 's', userText: '問題一');
      final hang = Completer<List<Message>>();
      repo.messagesOverride = () => hang.future;
      final c = ctl();
      await c.bootstrap();
      expect(c.busy, isTrue);
      t = t0.add(const Duration(seconds: 61));
      await settle(30);
      expect(c.phase, ChatPhase.uncertain); // expiry never awaits the GET
      expect(repo.sends, 0);
      c.dispose();
    });

    test('reload adopts the REMAINING budget (20s left), then expires',
        () async {
      await store.savePending(
        'http://test.invalid',
        's',
        userText: '問題一',
        runId: 'r',
      );
      await store.beginPendingRecovery('http://test.invalid', 's', now: t0);
      final hang = Completer<Map<String, dynamic>>();
      repo.status = (_) => hang.future; // no positive evidence at all
      t = t0.add(const Duration(seconds: 40));
      final c = ctl();
      await c.bootstrap();
      expect(c.phase, ChatPhase.recovering);
      expect(c.recoverySecondsRemaining, 20); // not a fresh 60
      t = t0.add(const Duration(seconds: 60));
      await settle(30);
      expect(c.phase, ChatPhase.uncertain);
      expect(c.recoverySecondsRemaining, 0);
      expect(repo.sends, 0);
      c.dispose();
    });

    test('started-only expired record lands uncertain immediately', () async {
      final start = t0.subtract(const Duration(seconds: 120));
      await store.savePending(
        'http://test.invalid',
        's',
        userText: '問題一',
        runId: 'r',
      );
      prefs.setString(kKey, jsonEncodeFor(start));
      repo.status = (_) => {'status': 'running'};
      final c = ctl();
      await c.bootstrap();
      expect(c.phase, ChatPhase.uncertain); // no fresh window reopened
      expect(keyOf(c.error), MessageKey.chatRecoveryUncertain);
      final p = store.loadPending('http://test.invalid', 's')!;
      expect(
        p.recoveryDeadline,
        start.add(const Duration(seconds: 60)),
      );
      expect(repo.sends, 0);
      c.dispose();
    });

    test('retry-used broken record: immediate EXHAUSTED, no second 30s',
        () async {
      await store.savePending(
        'http://test.invalid',
        's',
        userText: '問題一',
        runId: 'r',
      );
      prefs.setString(
        kKey,
        '{"user_text":"問題一","started_at":"${t0.toIso8601String()}",'
        '"recovery_retry_used":true}',
      );
      final c = ctl();
      await c.bootstrap();
      expect(c.phase, ChatPhase.uncertain);
      expect(keyOf(c.error), MessageKey.chatRecoveryExhausted);
      expect(c.recoveryRetryAvailable, isFalse);
      await c.retryReconcile(); // the button must not reopen anything
      expect(c.phase, ChatPhase.uncertain);
      final p = store.loadPending('http://test.invalid', 's')!;
      expect(p.recoveryRetryUsed, isTrue);
      expect(
        p.recoveryDeadline!.isAfter(t0),
        isFalse,
      ); // never re-armed
      expect(repo.sends, 0);
      expect(repo.stopCalls, 0);
      c.dispose();
    });

    test('fresh active defers the deadline; no zero-delay spin', () async {
      await store.savePending(
        'http://test.invalid',
        's',
        userText: '問題一',
        runId: 'r',
      );
      repo.status = (_) => {'status': 'running'};
      final c = ctl();
      await c.bootstrap();
      // Poll on the fake clock so the last positive sighting is 60s-fresh,
      // then cross the deadline: active outranks the timer, and the re-armed
      // timer is the POSITIVE activeSeen+60 edge, never a Duration.zero loop
      // against the stale persisted deadline.
      t = t0.add(const Duration(seconds: 59));
      await settle(10);
      t = t0.add(const Duration(seconds: 60)); // deadline edge, seen 1s old
      await settle(30);
      expect(c.phase, ChatPhase.recovering); // active outranks the timer
      expect(c.recoveryActiveConfirmed, isTrue);
      t = t0.add(const Duration(seconds: 118)); // still inside seen+60
      await settle(30);
      expect(c.phase, ChatPhase.recovering);
      expect(c.recoverySecondsRemaining, 0); // countdown hits zero...
      expect(c.busy, isTrue); // ...but fresh active keeps observing
      expect(repo.sends, 0);
      c.dispose();
    });

    test('unknown status string is NOT active: expires on schedule', () async {
      await store.savePending(
        'http://test.invalid',
        's',
        userText: '問題一',
        runId: 'r',
      );
      repo.status = (_) => {'status': 'chaotic'};
      final c = ctl();
      await c.bootstrap();
      await settle(10);
      expect(c.recoveryActiveConfirmed, isFalse); // never counted active
      t = t0.add(const Duration(seconds: 61));
      await settle(30);
      expect(c.phase, ChatPhase.uncertain);
      expect(repo.sends, 0);
      c.dispose();
    });

    test('foreground refresh consumes NOTHING (uncertain stays spent)',
        () async {
      await store.savePending(
        'http://test.invalid',
        's',
        userText: '問題一',
        runId: 'r',
      );
      final hang = Completer<Map<String, dynamic>>();
      repo.status = (_) => hang.future;
      final c = ctl();
      await c.bootstrap();
      t = t0.add(const Duration(seconds: 61));
      await settle(30);
      expect(c.phase, ChatPhase.uncertain);
      await c.reconcileForeground(); // resume-equivalent refresh
      await settle(10);
      expect(c.phase, ChatPhase.uncertain); // no silent re-arming
      expect(
        store.loadPending('http://test.invalid', 's')!.recoveryRetryUsed,
        isFalse,
      );
      expect(repo.sends, 0);
      c.dispose();
    });

    test('stop watch is bounded: landed stop cannot mean endless busy',
        () async {
      await store.savePending(
        'http://test.invalid',
        's',
        userText: '問題一',
        runId: 'r',
      );
      repo.history = const [Message(id: '1', role: 'user', content: '問題一')];
      repo.status = (_) => {'status': 'running'}; // never reports 'stopping'
      final c = ctl();
      await c.bootstrap();
      expect((await c.stop()).success, isTrue);
      expect(repo.stopCalls, 1);
      expect(store.loadPending('http://test.invalid', 's'), isNotNull);
      t = t0.add(const Duration(seconds: 61));
      await settle(30);
      expect(c.phase, ChatPhase.uncertain); // bounded, not forever busy
      // The human re-check spends the ONE 30s allowance, then the terminal
      // settles and compare-clears the pending.
      await c.retryReconcile();
      expect(c.phase, ChatPhase.recovering);
      expect(
        store.loadPending('http://test.invalid', 's')!.recoveryRetryUsed,
        isTrue,
      );
      repo.status = (_) => {'status': 'completed'};
      repo.history = const [
        Message(id: '1', role: 'user', content: '問題一'),
        Message(id: '2', role: 'assistant', content: '停在此處'),
      ];
      await settle(30);
      expect(c.phase, ChatPhase.idle);
      expect(store.loadPending('http://test.invalid', 's'), isNull);
      expect(repo.stopCalls, 1); // still exactly one stop POST ever
      expect(repo.sends, 0);
      c.dispose();
    });

    test('bootstrap publishes local state BEFORE any GET completes',
        () async {
      // A2: history keeps failing; the pending record must still be adopted,
      // budgeted and visible — no silent idle, no hidden exits.
      await store.savePending('http://test.invalid', 's', userText: '問題一');
      repo.messagesOverride = () => Future.error(const ApiException('blackout'));
      final c = ctl();
      await c.bootstrap(); // completes WITHOUT a successful GET
      expect(c.phase, ChatPhase.recovering); // local budget is in flight
      expect(store.loadPending('http://test.invalid', 's'), isNotNull);
      await settle(30); // later GETs keep failing: still observing
      expect(c.busy, isTrue); // inside the persisted budget, zero mutations
      expect(store.loadPending('http://test.invalid', 's'), isNotNull);
      expect(repo.sends, 0);
      c.dispose();
    });
  });

  group('watermark M06 end-to-end', () {
    test('claim77 -> begin -> reload -> expire keeps deadline & water mark',
        () async {
      final tok = (await store.claimPending(
        'http://test.invalid',
        's',
        userText: '問題一',
        turnId: '1',
        startedAt: t0,
        historyAfterId: 77,
      ))!;
      final b = await store.beginPendingRecovery(
        'http://test.invalid',
        's',
        token: tok,
        now: t0,
      );
      expect(b.record!.recoveryDeadline, isNotNull);
      expect(b.record!.historyAfterId, 77);
      repo.status = (_) => {'status': 'running'};
      final c = ctl(); // "reload": same prefs, fresh controller
      await c.bootstrap();
      expect(c.phase, ChatPhase.recovering);
      t = t0.add(const Duration(seconds: 60));
      await settle(30);
      expect(c.phase, ChatPhase.uncertain); // >=60s, no dots (UI suite)
      expect(repo.sends, 0);
      c.dispose();
    });
  });
}

String jsonEncodeFor(DateTime start) =>
    '{"user_text":"問題一","started_at":"${start.add(const Duration(seconds: 120)).toIso8601String()}",'
    '"run_id":"r","recovery_started_at":"${start.toIso8601String()}"}';
