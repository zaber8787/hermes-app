import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';

class FakeRepo extends HermesRepository {
  @override
  Future<SessionActivity> sessionActivity(String sid) async {
    if (activityError != null) throw activityError!;
    return SessionActivity.quiet(sid);
  }
  FakeRepo() : super('http://test.invalid', 'fake');

  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async =>
      {'id': sid, 'message_count': 0}; // R1 sync clock: quiet by default
  final events = StreamController<SseEvent>();
  List<Message> history = [];
  int sends = 0, reads = 0, statusCalls = 0;
  String? stopped;
  int stopCalls = 0;
  Object? stopError; // set to ApiException(…, 409/404/…) to script the reply
  Object? activityError; // when set, the ACTIVITY snapshot read fails this way
  Json Function(String runId) status = (_) => {'status': 'running'};
  @override
  Stream<SseEvent> chat(String sid, String input) {
    sends++;
    return events.stream;
  }

  @override
  Future<List<Message>> messages(
    String sid, {
    int offset = 0,
    int limit = 200,
  }) async {
    reads++;
    return history;
  }

  @override
  Future<Json> runStatus(String runId) async {
    statusCalls++;
    return status(runId);
  }

  @override
  Future<void> stop(String runId) async {
    stopCalls++;
    if (stopError != null) throw stopError!;
    stopped = runId;
  }

  @override
  void cancelStream(String sid) => unawaited(events.close());
}

/// 比照既有模式：一組 fake，「reload」＝ dispose 第一個 controller，
/// 用同一份 SharedPreferences mock 建全新 controller（冷啟動、無記憶體態）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  late FakeRepo repo;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    repo = FakeRepo();
  });
  tearDown(() => repo.close());

  ChatController reloaded() => ChatController(
    repo,
    store,
    's',
    watchInterval: const Duration(milliseconds: 1),
  );

  /// The pre-reload controller, disposed like F5 kills the Dart runtime
  /// (同份 prefs mock 接一個全新 controller，就是 reload)。
  void reloadPast() {
    reloaded().dispose();
  }

  test('tail user without pending/lost stays idle with zero polling', () async {
    repo.history = const [Message(id: '1', role: 'user', content: '早先提問')];
    reloadPast();
    final c = reloaded();
    await c.bootstrap();
    expect(c.phase, ChatPhase.idle);
    expect(c.busy, isFalse);
    final reads = repo.reads;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(repo.reads, reads); // 現況快照：一次讀，不輪詢
    expect(repo.statusCalls, 0);
    c.dispose();
  });

  test('pending without runId waits on history then lands exactly one final',
      () async {
    await store.savePending(repo.baseUrl, 's', userText: '問題一');
    repo.history = [];
    reloadPast();
    final c = reloaded();
    await c.bootstrap();
    expect(c.busy, isTrue); // 等待結果，不是 idle
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(c.phase, ChatPhase.recovering);
    expect(c.busy, isTrue); // history 還沒有本輪：繼續等，不誤判
    repo.history = const [
      Message(id: '1', role: 'user', content: '問題一'),
      Message(id: '2', role: 'assistant', content: '答復'),
    ];
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.phase, ChatPhase.idle);
    expect(
      c.messages.where((m) => m.role == 'assistant' && m.toolCalls.isEmpty),
      hasLength(1),
    ); // 訊息恰一份 final
    expect(store.loadPending(repo.baseUrl, 's'), isNull); // pending 清空
    expect(repo.sends, 0);
    c.dispose();
  });

  test('stopped run + leftover pending settles idle on first 404 (zombie fix)',
      () async {
    // Regression: 按停止只寫了 stop record、沒清 pending → 之後每次進頁面
    // 都輪詢一個 gateway 已遺忘的 runId，歷史又永遠不會有 final（該輪被
    // 使用者自己停掉），phase 卡在 busy → 輸入框鎖死「可輸入 /stop」。
    await store.savePending(
      repo.baseUrl,
      's',
      userText: '確認一下這什麼問題',
      runId: 'run_stopped',
    );
    await store.saveStop(repo.baseUrl, 's', 'run_stopped', 'accepted');
    repo.history = const [Message(id: '1', role: 'user', content: '確認一下這什麼問題')];
    repo.status = (_) => throw const ApiException('gone', 404);
    reloadPast();
    final c = reloaded();
    await c.bootstrap();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(c.phase, ChatPhase.idle);
    expect(c.busy, isFalse); // 輸入解鎖
    expect(c.stopNoticeKind, StopNotice.accepted);
    expect(store.loadPending(repo.baseUrl, 's'), isNull); // 殭屍紀錄被清
    expect(repo.sends, 0);
    c.dispose();
  });

  test('404 without a stop record keeps history observation (no regression)',
      () async {
    // STUCK-BUSY B5: the observation-keeps protection now needs an EXPLICIT
    // unknown fixture — a legacy gateway whose activity view answers 404 is
    // never "confirmed quiet", so no-final must not fake a settle either
    // way. (With confirmed-quiet evidence the same shape settles as
    // incomplete; see stuck_busy_recovery_test.)
    await store.savePending(
      repo.baseUrl,
      's',
      userText: '問題一',
      runId: 'run_vanished',
    );
    repo.activityError = const ApiException('gateway too old', 404);
    repo.history = const [Message(id: '1', role: 'user', content: '問題一')];
    repo.status = (_) => throw const ApiException('gone', 404);
    reloadPast();
    final c = reloaded();
    await c.bootstrap();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(c.busy, isTrue); // 沒有停止證據 → 維持觀察，不武斷結帳
    repo.history = const [
      Message(id: '1', role: 'user', content: '問題一'),
      Message(id: '2', role: 'assistant', content: '完成'),
    ];
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.phase, ChatPhase.idle);
    c.dispose();
  });

  test('stop clears the pending record so reload cannot resurrect the run',
      () async {
    final c = ChatController(repo, store, 's', watchInterval: const Duration(milliseconds: 1));
    final sending = c.send('hello');
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"run_x","session_id":"s"}'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(store.loadPending(repo.baseUrl, 's'), isNotNull);
    await c.stop();
    expect(store.loadPending(repo.baseUrl, 's'), isNull);
    expect(store.stopRecord(repo.baseUrl, 's'), contains('run_x'));
    repo.history = const [Message(id: '1', role: 'user', content: 'hello')];
    repo.events.add(
      const SseEvent('run.completed', '{"completed":true,"messages":[]}'),
    );
    await repo.events.close();
    await sending;
    expect(c.phase, ChatPhase.idle);
    expect(store.loadPending(repo.baseUrl, 's'), isNull);
    c.dispose();
  });

  test('pending with runId polls status to completion with zero POSTs',
      () async {
    await store.savePending(
      repo.baseUrl,
      's',
      userText: '問題一',
      runId: 'r1',
    );
    repo.history = const [Message(id: '1', role: 'user', content: '問題一')];
    repo.status = (_) => {'status': 'running'};
    reloadPast();
    final c = reloaded();
    await c.bootstrap();
    expect(c.busy, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.statusCalls, greaterThan(0));
    expect(c.phase, ChatPhase.recovering);
    final reads = repo.reads; // runId 模式只靠 status，不重讀歷史
    repo.history = const [
      Message(id: '1', role: 'user', content: '問題一'),
      Message(id: '2', role: 'assistant', content: '完成'),
    ];
    repo.status = (_) => {'status': 'completed'};
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.phase, ChatPhase.idle);
    expect(c.messages.last.content, '完成'); // completed 後對帳歷史
    expect(store.loadPending(repo.baseUrl, 's'), isNull);
    expect(repo.sends, 0); // 整個過程零 chat POST（reload 不重送）
    expect(repo.reads, reads + 1); // 只有 terminal 對帳那一次
    c.dispose();
  });

  test('stale lost + final clears the persisted flag AND the banner', () async {
    await store.markLost(repo.baseUrl, 's');
    await store.saveStop(repo.baseUrl, 's', 'r9', 'accepted');
    repo.history = const [
      Message(id: '1', role: 'user', content: '問題一'),
      Message(id: '2', role: 'assistant', content: '早就完成了'),
    ];
    reloadPast();
    final c = reloaded();
    expect(c.stopNoticeKind, StopNotice.previousStopRecord); // 進頁瞬間 banner 還在
    await c.bootstrap();
    expect(c.stopNoticeKind, StopNotice.none); // 紅燈點：清 lost 要同時清 banner
    expect(store.lostNotice(repo.baseUrl, 's'), isNull); // lost 清空
    c.dispose();
  });

  test('stop during bootstrap observation POSTs the pending runId and settles',
      () async {
    await store.savePending(repo.baseUrl, 's', userText: '問題一', runId: 'r1');
    repo.history = const [Message(id: '1', role: 'user', content: '問題一')];
    repo.status = (_) => {'status': 'running'};
    reloadPast();
    final c = reloaded();
    await c.bootstrap();
    expect(c.busy, isTrue);
    expect(c.canStop, isTrue); // bootstrap 觀察中也能停止
    expect(await c.stop(), isTrue);
    expect(repo.stopped, 'r1');
    expect(repo.stopCalls, 1);
    expect(c.stopNoticeKind, StopNotice.accepted);
    expect(store.loadPending(repo.baseUrl, 's'), isNull); // 200 → 清 pending
    expect(c.error, isNull); // 409/失敗都不允許在這裡報錯
    // run 還沒終態：繼續觀察，不提前 idle
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(c.busy, isTrue);
    expect(repo.stopCalls, 1); // 重複 tick 不得再次 POST stop
    repo.status = (_) => {'status': 'completed'};
    repo.history = const [
      Message(id: '1', role: 'user', content: '問題一'),
      Message(id: '2', role: 'assistant', content: '停在此處'),
    ];
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.phase, ChatPhase.idle);
    expect(c.messages.last.content, '停在此處'); // settle 用歷史對帳
    expect(repo.sends, 0);
    c.dispose();
  });

  test('stop 409 is treated as already-requested, polls to terminal, no error',
      () async {
    await store.savePending(repo.baseUrl, 's', userText: '問題一', runId: 'r1');
    repo.history = const [Message(id: '1', role: 'user', content: '問題一')];
    repo.status = (_) => {'status': 'running'};
    repo.stopError = const ApiException('already stopping', 409);
    reloadPast();
    final c = reloaded();
    await c.bootstrap();
    expect(await c.stop(), isTrue); // 409 不報錯
    expect(c.error, isNull);
    expect(c.stopNoticeKind, StopNotice.requested);
    // pending 保留（reload 可續查），觀察輪詢接管
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(c.busy, isTrue);
    expect(repo.stopCalls, 1);
    repo.stopError = null;
    repo.status = (_) => {'status': 'cancelled'};
    repo.history = const [
      Message(id: '1', role: 'user', content: '問題一'),
    ];
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.phase, ChatPhase.idle); // 終態收斂，歷史只有 user 也結案
    expect(c.stopNoticeKind, StopNotice.accepted); // 使用者來源不被覆寫
    expect(store.loadPending(repo.baseUrl, 's'), isNull);
    expect(store.stopRecord(repo.baseUrl, 's'), contains('requested'));
    expect(repo.sends, 0);
    c.dispose();
  });

  test('stop 404 settles immediately from history without claiming a kill',
      () async {
    await store.savePending(repo.baseUrl, 's', userText: '問題一', runId: 'r1');
    repo.history = const [Message(id: '1', role: 'user', content: '問題一')];
    repo.stopError = const ApiException('forgotten', 404);
    reloadPast();
    final c = reloaded();
    await c.bootstrap();
    expect(await c.stop(), isTrue);
    expect(c.phase, ChatPhase.idle);
    expect(c.busy, isFalse);
    expect(c.error, isNull);
    expect(c.stopNoticeKind, StopNotice.notFound);
    expect(store.loadPending(repo.baseUrl, 's'), isNull);
    expect(repo.sends, 0);
    c.dispose();
  });

  test('stop without any runId is a visible no-op, never a chat POST',
      () async {
    repo.history = const [Message(id: '1', role: 'user', content: '問題一')];
    reloadPast();
    final c = reloaded();
    await c.bootstrap();
    expect(c.canStop, isFalse);
    expect(await c.stop(), isFalse);
    expect((c.error! as UiLocal).key, MessageKey.chatStateM029);
    expect(repo.stopCalls, 0);
    expect(repo.sends, 0);
    expect(c.phase, ChatPhase.idle);
    c.dispose();
    // idle（非忙碌）時同樣零副作用
    final d = reloaded();
    expect(d.canStop, isFalse);
    expect(await d.stop(), isFalse);
    expect(repo.stopCalls, 0);
    d.dispose();
  });
}
