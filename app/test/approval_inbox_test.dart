import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/features/chat/approval_inbox.dart';

// APPROVALPUSH B3 (spec R6): the inbox store keyed by
// (server,session,epoch,run,request). SSE and GET are two views of the SAME
// card; settlement is exact-id; unknown snapshots never claim "empty".

void main() {
  const now = 1000000.0;

  Map<String, dynamic> reqData(
    String rid, {
    String runId = 'r7',
    int epoch = 7,
    double? expires,
    List<String> choices = const ['once', 'deny'],
  }) => {
    'session_id': 's',
    'run_id': runId,
    'request_id': rid,
    'server_epoch': epoch,
    'command': 'rm -rf /tmp/scratch-$rid',
    'description': 'd',
    'choices': choices,
    'created_at': now,
    'expires_at': expires ?? now + 300,
    'deadline_estimated': true,
  };

  Map<String, dynamic> snapshot(
    List<Map<String, dynamic>> pend, {
    int epoch = 7,
    bool available = true,
    bool overflow = false,
    String runId = 'r7',
  }) => {
    'schema_version': 1,
    'run_id': runId,
    'session_id': 's',
    'server_epoch': epoch,
    'revision': 1,
    'pending': pend,
    'available': available,
    'overflow': overflow,
  };

  group('ApprovalInbox', () {
    test('duplicate SSE upsert keeps ONE card and one identity', () {
      final inbox = ApprovalInbox();
      final a = inbox.upsertEvent(
        serverUrl: 'http://s',
        data: reqData('q1'),
        now: now,
      );
      final b = inbox.upsertEvent(
        serverUrl: 'http://s',
        data: reqData('q1'),
        now: now + 1,
      );
      expect(identical(a, b), isTrue);
      expect(inbox.count, 1);
      expect(a!.serverEpoch, 7);
      expect(a.command, 'rm -rf /tmp/scratch-q1');
      expect(a.deadlineEstimated, isTrue);
    });

    test('GET snapshot merges the same request and adds unseen pending', () {
      final inbox = ApprovalInbox();
      inbox.upsertEvent(serverUrl: 'http://s', data: reqData('q1'), now: now);
      inbox.mergeSnapshot(
        serverUrl: 'http://s',
        runId: 'r7',
        snapshot: snapshot([reqData('q1'), reqData('q2')]),
        now: now,
      );
      expect(inbox.count, 2);
      expect(inbox.pendingFor(sessionId: 's').map((e) => e.requestId), [
        'q1',
        'q2',
      ]);
    });

    test('available snapshot is the truth: missing pending reconciles away', () {
      final inbox = ApprovalInbox();
      inbox.upsertEvent(serverUrl: 'http://s', data: reqData('q1'), now: now);
      inbox.upsertEvent(serverUrl: 'http://s', data: reqData('q2'), now: now);
      inbox.mergeSnapshot(
        serverUrl: 'http://s',
        runId: 'r7',
        snapshot: snapshot([reqData('q2')]),
        now: now,
      );
      expect(inbox.pendingFor(sessionId: 's').map((e) => e.requestId), ['q2']);
      final settled = inbox.find(runId: 'r7', requestId: 'q1')!;
      expect(settled.phase, ApprovalPhase.resolved);
      expect(settled.outcome, 'reconciled');
    });

    test('unavailable/overflow snapshot never claims empty and marks unconfirmed', () {
      final inbox = ApprovalInbox();
      inbox.upsertEvent(serverUrl: 'http://s', data: reqData('q1'), now: now);
      inbox.mergeSnapshot(
        serverUrl: 'http://s',
        runId: 'r7',
        snapshot: snapshot(const [], available: false, overflow: true),
        now: now,
      );
      expect(inbox.pendingFor(sessionId: 's').map((e) => e.requestId), ['q1']);
      expect(inbox.isUnconfirmed('r7'), isTrue);
      inbox.markConfirmed('r7');
      expect(inbox.isUnconfirmed('r7'), isFalse);
    });

    test('exact-id settle touches ONLY the named request', () {
      final inbox = ApprovalInbox();
      inbox.upsertEvent(serverUrl: 'http://s', data: reqData('q1'), now: now);
      inbox.upsertEvent(serverUrl: 'http://s', data: reqData('q2'), now: now);
      final settled = inbox.settle(runId: 'r7', requestId: 'q1', outcome: 'answered', choice: 'once');
      expect(settled, isNotNull);
      expect(settled!.phase, ApprovalPhase.resolved);
      expect(settled.choice, 'once');
      expect(inbox.pendingFor(sessionId: 's').map((e) => e.requestId), ['q2']);
    });

    test('settleRun ends every pending of ONE run, sibling runs survive', () {
      final inbox = ApprovalInbox();
      inbox.upsertEvent(
        serverUrl: 'http://s',
        data: reqData('q1', runId: 'r7'),
        now: now,
      );
      inbox.upsertEvent(
        serverUrl: 'http://s',
        data: reqData('q9', runId: 'r8'),
        now: now,
      );
      expect(inbox.settleRun(serverUrl: 'http://s', runId: 'r7', outcome: 'run_terminal'), 1);
      expect(inbox.pendingFor(runId: 'r7'), isEmpty);
      expect(inbox.pendingFor(runId: 'r8').length, 1);
    });

    test('remainingSeconds is a bounded estimate; gone is gone, not deny', () {
      final inbox = ApprovalInbox();
      final a = inbox.upsertEvent(
        serverUrl: 'http://s',
        data: reqData('q1', expires: now + 42.9),
        now: now,
      );
      expect(a!.remainingSeconds(now), 42);
      expect(a.remainingSeconds(now + 100), isNull);
      expect(a.expiredAt(now + 100), isTrue);
      expect(a.phase, ApprovalPhase.pending); // expiry is shown, never auto-denied
    });

    test('stale server_epoch upsert does not resurrect a settled card', () {
      final inbox = ApprovalInbox();
      final a = inbox.upsertEvent(serverUrl: 'http://s', data: reqData('q1'), now: now);
      inbox.settle(runId: 'r7', requestId: 'q1', outcome: 'answered');
      final again = inbox.upsertEvent(
        serverUrl: 'http://s',
        data: reqData('q1', epoch: 6),
        now: now + 1,
      );
      expect(identical(again, a), isTrue); // same identity object...
      expect(again!.phase, ApprovalPhase.resolved); // ...still settled, not revived
      expect(inbox.pendingFor(sessionId: 's'), isEmpty);
    });

    test('visible keeps pending + brief handled-elsewhere receipts', () {
      final inbox = ApprovalInbox();
      final a = inbox.upsertEvent(serverUrl: 'http://s', data: reqData('q1'), now: now);
      inbox.upsertEvent(serverUrl: 'http://s', data: reqData('q2'), now: now);
      inbox.settle(
        runId: 'r7',
        requestId: 'q1',
        outcome: 'answered_elsewhere',
        now: now,
      );
      expect(inbox.visible(now + 5).map((e) => e.requestId), ['q1', 'q2']);
      expect(inbox.visible(now + 7).map((e) => e.requestId), ['q2']);
      expect(a!.phase, ApprovalPhase.resolved);
    });

    test('key carries the full tuple', () {
      final inbox = ApprovalInbox();
      final a = inbox.upsertEvent(serverUrl: 'http://s', data: reqData('q1'), now: now);
      expect(a!.key, 'http://s|s|7|r7|q1');
    });
  });
}
