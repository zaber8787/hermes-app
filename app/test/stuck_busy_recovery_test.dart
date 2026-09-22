import 'dart:async';
// (dart:async provides Completer for the hung-GET fixture)
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/l10n/ui_message.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// STUCK-BUSY plan B5 fixtures. Phase 1: the shared folded matcher wired into
/// bootstrap/claim/pendingDelivered. Later phases extend this file with the
/// persisted recovery budget and the terminal-evidence integration.
class SBRepo extends HermesRepository {
  SBRepo() : super('http://test.invalid', 'fake');
  final events = StreamController<SseEvent>();
  List<Message> history = [];
  int sends = 0, reads = 0, statusCalls = 0;
  List<Message> Function()? messagesOverride;
  FutureOr<Json> Function(String runId) status = (_) => {'status': 'running'};
  SessionActivity Function(String) activity = SessionActivity.quiet;
  Object? activityError;
  int stopCalls = 0;
  @override
  Future<void> stop(String runId) async {
    stopCalls++;
  }

  @override
  Future<SessionActivity> sessionActivity(String sid) async {
    if (activityError != null) throw activityError!;
    return activity(sid);
  }

  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async =>
      {'id': sid, 'message_count': 0};
  @override
  Stream<SseEvent> chat(String sid, String input) {
    sends++;
    return events.stream;
  }

  @override
  Future<List<Message>> messages(String sid, {int offset = 0, int limit = 200}) async {
    reads++;
    if (messagesOverride != null) return messagesOverride!();
    return history;
  }

  @override
  Future<Json> runStatus(String runId) async {
    statusCalls++;
    return await status(runId);
  }

  @override
  void cancelStream(String sid) => unawaited(events.close());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  late SBRepo repo;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    repo = SBRepo();
  });
  tearDown(() => repo.close());

  ChatController reloaded() => ChatController(
    repo,
    store,
    's',
    watchInterval: const Duration(milliseconds: 1),
  );

  test('bootstrap anchors folded (Discord-reformatted) user text', () async {
    // i18n-exempt: cross-device persistence fixture (Discord reformat), not UI text.
    await store.savePending(repo.baseUrl, 's', userText: '部署 完成 [附件: log.txt]');
    repo.history = const [
      Message(id: '1', role: 'user', content: '部署 完成\n[附件: log.txt]'),
      Message(id: '2', role: 'assistant', content: '好了'),
    ];
    final c = reloaded();
    await c.bootstrap();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.phase, ChatPhase.idle); // red before the shared fold
    expect(store.loadPending(repo.baseUrl, 's'), isNull);
    expect(repo.sends, 0);
    c.dispose();
  });

  test('pendingDelivered hides the bubble on folded-equal history rows', () async {
    final c = ChatController(repo, store, 's');
    final sending = c.send('部署 完成 [附件: log.txt]');
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
    );
    await Future<void>.delayed(Duration.zero);
    repo.history = const [
      Message(id: '1', role: 'user', content: '部署 完成\n[附件: log.txt]'),
    ];
    await c.reconcileForeground();
    expect(c.pendingDelivered, isTrue); // red before the shared fold
    expect(c.pendingBubbleText, isNull);
    repo.events.add(
      const SseEvent('run.completed', '{"completed":true,"messages":[]}'),
    );
    await repo.events.close();
    await sending;
    c.dispose();
  });

  test('live reconcile anchors via the same folded matcher', () async {
    final c = ChatController(repo, store, 's');
    final sending = c.send('問題 一');
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
    );
    await Future<void>.delayed(Duration.zero);
    repo.history = const [
      // i18n-exempt: cross-device persistence fixture, not UI text.
      Message(id: '1', role: 'user', content: '問題\n一 [附件: a.txt]'),
      Message(id: '2', role: 'assistant', content: '答案'),
    ];
    await c.reconcileForeground();
    expect(c.phase, ChatPhase.idle);
    await repo.events.close();
    await sending;
    c.dispose();
  });

  test('duplicate same-text candidates never settle on the older turn', () async {
    // Two identical user rows inside the floor window: ambiguous → neither
    // the old nor the new final may fake a settle for this turn.
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    await store.savePending(repo.baseUrl, 's', userText: '重複問題');
    repo.history = [
      Message(id: '1', role: 'user', content: '重複問題', timestamp: now),
      Message(id: '2', role: 'assistant', content: '舊答案'),
      Message(id: '3', role: 'user', content: '重複問題', timestamp: now + 1),
      Message(id: '4', role: 'assistant', content: '新答案'),
    ];
    final c = reloaded();
    await c.bootstrap();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.busy, isTrue); // ambiguous: keep observing, pick neither
    expect(c.phase, isNot(ChatPhase.idle));
    c.dispose();
  });

  test('unsupported gateway (activity 404) is never treated as quiet-idle', () async {
    await store.savePending(repo.baseUrl, 's', userText: '問題一', runId: 'gone_run');
    repo.status = (_) => throw const ApiException('gone', 404);
    repo.activityError = const ApiException.local(MessageKey.apiM005, status: 404);
    repo.history = const [Message(id: '1', role: 'user', content: '問題一')];
    final c = reloaded();
    await c.bootstrap();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // No confirmed quiet evidence: observation continues, never an
    // incomplete-terminal settle.
    expect(c.busy, isTrue);
    expect(store.loadPending(repo.baseUrl, 's'), isNotNull);
    repo.history = const [
      Message(id: '1', role: 'user', content: '問題一'),
      Message(id: '2', role: 'assistant', content: '完成'),
    ];
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.phase, ChatPhase.idle);
    c.dispose();
  });

  phase2Main();
}


// ---- Phase 2: persisted recovery budget (B3) + terminal evidence (B5) -----

SessionActivity quietSnap({int count = 3, String epoch = 'e1', bool overflow = false}) =>
    SessionActivity(
      sessionId: 's',
      resolvedSessionId: 's',
      serverEpoch: epoch,
      observedAt: 0,
      historyRevision: HistoryRevision('s', count, count),
      activityRevision: 0,
      activeRuns: const [],
      recentTerminal: const [],
      overflow: overflow,
    );

// i18n-exempt: incident-shaped history fixtures (protocol data), not UI text.
const incidentRows = [
  Message(id: '1', role: 'user', content: '問題一'),
  Message(
    id: '2',
    role: 'assistant',
    content: '',
    toolCalls: [ToolCall('t1', 'review', '{}')],
  ),
  Message(id: '3', role: 'tool', content: 'review_input_budget_exhausted', toolCallId: 't1'),
];

void c2dispose(ChatController a, ChatController b) {
  a.dispose();
  b.dispose();
}

void phase2Main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late LocalStore store;
  late SBRepo repo;
  late DateTime t;
  DateTime step([int seconds = 1]) => t = t.add(Duration(seconds: seconds));
  final t0 = DateTime.utc(2026, 1, 1);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = LocalStore(prefs);
    repo = SBRepo();
    t = t0;
  });
  tearDown(() => repo.close());

  ChatController scripted() => ChatController(
    repo,
    store,
    's',
    watchInterval: const Duration(milliseconds: 1),
    now: () => t,
  );

  Future<void> settleWithin(ChatController c) async {
    for (var i = 0; i < 300 && c.busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('budget-exhausted tool-tail settles idle with chatTurnIncomplete once',
      () async {
    await store.savePending(
      repo.baseUrl,
      's',
      userText: '問題一',
      runId: 'r',
      startedAt: t0,
    );
    repo.history = incidentRows;
    repo.status = (_) {
      step();
      throw const ApiException('gone', 404);
    };
    repo.activity = (_) {
      step();
      return quietSnap();
    };
    final c = scripted();
    await c.bootstrap();
    await settleWithin(c);
    expect(c.phase, ChatPhase.idle);
    expect((c.error! as UiLocal).key, MessageKey.chatTurnIncomplete);
    expect(c.recoveryNotice, isNull);
    expect(store.loadPending(repo.baseUrl, 's'), isNull);
    expect(repo.sends, 0);
    expect(repo.stopCalls, 0);
    expect(c.messages, incidentRows); // history untouched, nothing appended
    // rebuild over the SAME prefs: idle, no zombie polling
    final calls = repo.statusCalls;
    final reads = repo.reads;
    final d = scripted();
    await d.bootstrap();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(d.phase, ChatPhase.idle);
    expect(repo.statusCalls, calls);
    expect(repo.reads, reads + 1); // the single bootstrap history read
    c.dispose();
    d.dispose();
  });

  test('same shape WITHOUT runId: quiet evidence lands incomplete fast',
      () async {
    await store.savePending(repo.baseUrl, 's', userText: '問題\n一', startedAt: t0);
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
    repo.activity = (_) {
      step();
      return quietSnap();
    };
    final c = scripted();
    await c.bootstrap();
    await settleWithin(c);
    expect(c.phase, ChatPhase.idle);
    expect((c.error! as UiLocal).key, MessageKey.chatTurnIncomplete);
    expect(store.loadPending(repo.baseUrl, 's'), isNull);
    expect(repo.statusCalls, 0); // no run: never invents status polling
    c.dispose();
  });

  test('reload adopts the REMAINING budget; expiry lands uncertain; one retry',
      () async {
    await store.savePending(
      repo.baseUrl,
      's',
      userText: '問題一',
      runId: 'r',
      startedAt: t0,
    );
    repo.history = const []; // anchor never appears: pure unknown
    repo.status = (_) {
      step();
      throw const ApiException('gone', 404);
    };
    repo.activity = (_) => quietSnap();
    final c = scripted();
    await c.bootstrap();
    expect(c.phase, ChatPhase.recovering);
    expect(
      store.loadPending(repo.baseUrl, 's')!.recoveryDeadline,
      t0.add(const Duration(seconds: 60)),
    );
    c.dispose();

    t = t0.add(const Duration(seconds: 40));
    final d = scripted();
    await d.bootstrap();
    expect(d.recoverySecondsRemaining, lessThanOrEqualTo(20)); // not re-armed
    d.dispose();

    t = t0.add(const Duration(seconds: 61));
    final e = scripted();
    await e.bootstrap(); // persisted budget already spent
    expect(e.phase, ChatPhase.uncertain);
    expect((e.error! as UiLocal).key, MessageKey.chatRecoveryUncertain);
    final frozen = repo.statusCalls + repo.reads;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(repo.statusCalls + repo.reads, frozen); // zero polling when expired
    // the ONE retry: persisted consume, re-arms 30s
    final atRetry = t;
    await e.retryReconcile();
    expect(e.phase, ChatPhase.recovering);
    expect(store.loadPending(repo.baseUrl, 's')!.recoveryRetryUsed, isTrue);
    expect(
      store.loadPending(repo.baseUrl, 's')!.recoveryDeadline,
      atRetry.add(const Duration(seconds: 30)),
    );
    // let the shared 30s window expire, THEN retry again: no re-arm ever
    t = t.add(const Duration(seconds: 31));
    for (var i = 0; i < 200 && e.phase == ChatPhase.recovering; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(e.phase, ChatPhase.uncertain);
    final during = repo.statusCalls;
    await e.retryReconcile();
    expect(e.phase, ChatPhase.uncertain);
    expect((e.error! as UiLocal).key, MessageKey.chatRecoveryExhausted);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(repo.statusCalls, during);
    // reload after exhaustion: still no fresh window
    final f = scripted();
    await f.bootstrap();
    expect(f.phase, ChatPhase.uncertain);
    expect((f.error! as UiLocal).key, MessageKey.chatRecoveryExhausted);
    c2dispose(e, f);
  });

  test('legacy pending migrates on first recovery, never twice', () async {
    await store.savePending(repo.baseUrl, 's', userText: '問題一', runId: 'r');
    repo.history = const [];
    repo.status = (_) {
      step();
      throw const ApiException('gone', 404);
    };
    final c = scripted();
    await c.bootstrap();
    expect(
      store.loadPending(repo.baseUrl, 's')!.recoveryDeadline,
      t0.add(const Duration(seconds: 60)),
    );
    c.dispose();
    t = t0.add(const Duration(seconds: 10));
    final d = scripted();
    await d.bootstrap();
    expect(
      store.loadPending(repo.baseUrl, 's')!.recoveryDeadline,
      t0.add(const Duration(seconds: 60)), // NOT t+60
    );
    d.dispose();
  });

  test('60s cap: hung GET still lands uncertain at the deadline, late 200 dies',
      () async {
    await store.savePending(
      repo.baseUrl,
      's',
      userText: '問題一',
      runId: 'r',
      startedAt: t0,
    );
    repo.history = const [Message(id: '1', role: 'user', content: '問題一')];
    final hang = Completer<Json>();
    var calls = 0;
    repo.status = (_) {
      calls++;
      if (calls == 1) return hang.future;
      return {'status': 'running'};
    };
    // clock advances 50ms per READ so the deadline is crossed while the
    // single-flight GET is still hanging.
    final c = ChatController(
      repo,
      store,
      's',
      watchInterval: const Duration(milliseconds: 1),
      now: () => t = t.add(const Duration(milliseconds: 50)),
    );
    await c.bootstrap();
    expect(c.phase, ChatPhase.recovering);
    for (var i = 0; i < 400 && c.phase == ChatPhase.recovering; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(c.phase, ChatPhase.uncertain);
    hang.complete({'status': 'running'}); // late answer
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(c.phase, ChatPhase.uncertain); // late GET must not re-arm
    expect(store.loadPending(repo.baseUrl, 's'), isNotNull); // not deleted
    c.dispose();
  });

  for (final (label, breakQuiet) in [
    ('activity 500',
        (SBRepo r) {
          r.activityError = const ApiException('boom', 500);
        }),
    ('unsupported gateway',
        (SBRepo r) {
          r.activityError = const ApiException.local(MessageKey.apiM005, status: 404);
        }),
    ('overflow',
        (SBRepo r) {
          r.activity = (_) {
            step();
            return quietSnap(overflow: true);
          };
        }),
    ('revision moves',
        (SBRepo r) {
          var n = 0;
          r.activity = (_) {
            step();
            return quietSnap(count: n++ % 2 == 0 ? 3 : 4);
          };
        }),
  ]) {
    test('quiet evidence insufficient ($label): never an incomplete settle',
        () async {
      await store.savePending(
        repo.baseUrl,
        's',
        userText: '問題一',
        runId: 'r',
        startedAt: t0,
      );
      repo.history = incidentRows;
      repo.status = (_) {
        step();
        throw const ApiException('gone', 404);
      };
      repo.activity = (_) {
        step();
        return quietSnap();
      };
      breakQuiet(repo);
      final c = scripted();
      await c.bootstrap();
      await settleWithin(c);
      expect(c.busy, isTrue);
      expect(c.phase, isNot(ChatPhase.idle));
      expect(
        (c.error as UiLocal?)?.key,
        isNot(MessageKey.chatTurnIncomplete),
      );
      expect(store.loadPending(repo.baseUrl, 's'), isNotNull);
      expect(repo.sends, 0);
      c.dispose();
    });
  }

  test('active run never expires on the budget timer', () async {
    await store.savePending(
      repo.baseUrl,
      's',
      userText: '問題一',
      runId: 'r',
      startedAt: t0,
    );
    repo.history = const [Message(id: '1', role: 'user', content: '問題一')];
    repo.status = (_) => {'status': 'running'}; // confirmed working
    final c = scripted();
    await c.bootstrap();
    for (var i = 0; i < 120 && c.phase == ChatPhase.recovering; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      t = t.add(const Duration(seconds: 1)); // beyond 60s virtual
    }
    expect(t.isAfter(t0.add(const Duration(seconds: 60))), isTrue);
    expect(c.phase, ChatPhase.recovering); // 仍在執行, not uncertain
    c.dispose();
  });

  test('external user-less rows cannot fake a settle', () async {
    await store.savePending(
      repo.baseUrl,
      's',
      userText: '本輪問題',
      runId: 'r',
      startedAt: t0,
    );
    // i18n-exempt: cross-platform rows without user bubbles (protocol test).
    repo.history = const [
      Message(id: '1', role: 'assistant', content: '別的裝置的回復'),
      Message(
        id: '2',
        role: 'assistant',
        content: '',
        toolCalls: [ToolCall('t', 'x', '{}')],
      ),
    ];
    repo.status = (_) {
      step();
      return {'status': 'running'};
    };
    final c = scripted();
    await c.bootstrap();
    await settleWithin(c);
    expect(c.busy, isTrue);
    expect(c.phase, ChatPhase.recovering);
    expect(store.loadPending(repo.baseUrl, 's'), isNotNull);
    c.dispose();
  });

  test('clear local waiting record: idle, cleared, zero POSTs, drafts kept',
      () async {
    await store.savePending(
      repo.baseUrl,
      's',
      userText: '問題一',
      runId: 'r',
      startedAt: t0,
    );
    await store.saveDraft(repo.baseUrl, 's', '打到一半');
    repo.history = const [];
    repo.status = (_) {
      step();
      throw const ApiException('gone', 404);
    };
    final c = scripted();
    await c.bootstrap();
    t = t0.add(const Duration(seconds: 61));
    await c.retryReconcile(); // consumes the one retry → recovering
    expect(c.phase, ChatPhase.recovering);
    t = t.add(const Duration(seconds: 31));
    for (var i = 0; i < 200 && c.phase == ChatPhase.recovering; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(c.phase, ChatPhase.uncertain);
    await c.clearLocalWaitingRecord();
    expect(c.phase, ChatPhase.idle);
    expect(store.loadPending(repo.baseUrl, 's'), isNull);
    expect(store.draft(repo.baseUrl, 's'), '打到一半');
    expect(repo.sends, 0);
    c.dispose();
  });

  test('clear never deletes another tab’s new claim', () async {
    await store.savePending(
      repo.baseUrl,
      's',
      userText: '問題一',
      runId: 'r',
      startedAt: t0,
    );
    repo.history = const [];
    repo.status = (_) => throw const ApiException('gone', 404);
    final c = scripted();
    await c.bootstrap();
    t = t0.add(const Duration(seconds: 61));
    await c.retryReconcile(); // consumed → recovering
    t = t.add(const Duration(seconds: 31));
    for (var i = 0; i < 200 && c.phase == ChatPhase.recovering; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(c.phase, ChatPhase.uncertain);
    // the OTHER tab claims the slot for its own new turn
    final token2 = await store.claimPending(
      repo.baseUrl,
      's',
      userText: '新回合',
      turnId: 'z9',
    );
    await c.clearLocalWaitingRecord();
    expect(c.phase, ChatPhase.idle);
    final rec = store.loadPending(repo.baseUrl, 's');
    expect(rec, isNotNull);
    expect(rec!.token, token2);
    expect(repo.sends, 0);
    c.dispose();
  });

  test('storage that refuses the budget: uncertain + honest error, no window',
      () async {
    await store.savePending(
      repo.baseUrl,
      's',
      userText: '問題一',
      runId: 'r',
      startedAt: t0,
    );
    final failing = _BeginFails(prefs);
    final c = ChatController(
      repo,
      failing,
      's',
      watchInterval: const Duration(milliseconds: 1),
      now: () => t,
    );
    await c.bootstrap();
    expect(c.phase, ChatPhase.uncertain);
    expect((c.error! as UiLocal).key, MessageKey.chatRecoveryStorageFailed);
    expect(store.loadPending(repo.baseUrl, 's'), isNotNull);
    expect(repo.statusCalls, 0);
    c.dispose();
  });

  test('explicit terminals settle regardless of the history read', () async {
    for (final state in ['completed', 'cancelled', 'failed']) {
      for (final historyFails in [false, true]) {
        SharedPreferences.setMockInitialValues({});
        final st = LocalStore(await SharedPreferences.getInstance());
        final rp = SBRepo();
        await st.savePending(
          rp.baseUrl,
          's',
          userText: '問題一',
          runId: 'r',
          startedAt: t0,
        );
        rp.history = incidentRows;
        var reads = 0;
        rp.messagesOverride = () {
          reads++;
          if (historyFails && reads > 1) throw const ApiException('boom', 500);
          return incidentRows;
        };
        rp.status = (_) => {'status': state};
        final ctrl = ChatController(
          rp,
          st,
          's',
          watchInterval: const Duration(milliseconds: 1),
          now: () => t,
        );
        await ctrl.bootstrap();
        await settleWithin(ctrl);
        expect(ctrl.phase, ChatPhase.idle, reason: '$state fail=$historyFails');
        expect(st.loadPending(rp.baseUrl, 's'), isNull);
        expect(ctrl.busy, isFalse);
        if (state == 'cancelled') {
          expect(ctrl.stopNoticeKind, StopNotice.serverEnded);
        }
        ctrl.dispose();
        rp.close();
      }
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}

class _BeginFails extends LocalStore {
  _BeginFails(super.prefs);
  @override
  Future<PendingRecoveryResult> beginPendingRecovery(
    String server,
    String sid, {
    String? token,
    Duration initialWindow = const Duration(seconds: 60),
    DateTime? now,
  }) async {
    throw const PendingPersistenceFailure();
  }
}

