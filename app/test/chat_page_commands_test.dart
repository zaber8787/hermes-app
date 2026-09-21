import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/providers.dart';

class FakeCmdRepo extends HermesRepository {
  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  FakeCmdRepo() : super('http://test.invalid', 'fake');

  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async =>
      {'id': sid, 'message_count': 0}; // R1 sync clock: quiet by default
  final events = StreamController<SseEvent>.broadcast();
  List<Message> history = [];
  Json Function(String runId) status = (_) => {'status': 'running'};
  int sends = 0, stopCalls = 0;
  String? stopped;
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
  }) async => history;

  @override
  Future<Json> runStatus(String runId) async => status(runId);

  @override
  Future<void> stop(String runId) async {
    stopCalls++;
    stopped = runId;
  }

  @override
  void cancelStream(String sid) => unawaited(events.close());
}

/// /status 落地（缺陷 3）＋ bootstrap 觀察中的 /stop 入口（缺陷 1 的 UI 面）：
/// 指令一律不進模型（chat POST==0），結果顯示 runId／session id。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  late FakeCmdRepo repo;
  late ProviderContainer container;
  const url = 'http://test.invalid';
  final sessionA = Session(
    id: 's',
    title: 'A',
    count: 1,
    startedAt: 0,
    activity: 0,
    source: 'api_server',
  );

  Future<void> openPage(WidgetTester tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: ChatPage(session: sessionA)),
    ));
    await tester.pump();
    await tester.pump();
  }

  Future<void> submit(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump(); // rebuild so the send button re-evaluates gating
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    repo = FakeCmdRepo();
    container = ProviderContainer(
      overrides: [
        localStoreProvider.overrideWithValue(store),
        initialSettingsProvider.overrideWithValue(
          const AppSettings(url: url, key: 'fake'),
        ),
        repositoryProvider.overrideWithValue(repo),
        skillsProvider.overrideWith((ref) async => []),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    if (!repo.events.isClosed) unawaited(repo.events.close());
    repo.close();
  });

  testWidgets('/status when idle shows the long card, zero chat POSTs', (
    tester,
  ) async {
    await openPage(tester);
    await submit(tester, '/status');
    expect(find.text('/status'), findsWidgets); // dialog 標題
    expect(find.textContaining('工作階段：s'), findsOneWidget);
    expect(find.textContaining('空閒'), findsOneWidget);
    expect(find.textContaining('目前沒有執行中的 run'), findsOneWidget);
    expect(find.textContaining('重新連線次數'), findsOneWidget);
    expect(repo.sends, 0); // 絕不進模型
    await tester.tap(find.text('關閉'));
    await tester.pumpAndSettle();
  });

  testWidgets('/status during bootstrap observation: SnackBar names runId', (
    tester,
  ) async {
    await store.savePending(url, 's', userText: '問題一', runId: 'r1');
    repo.history = const [Message(id: '1', role: 'user', content: '問題一')];
    await openPage(tester);
    expect(find.text('進行中'), findsOneWidget); // busy：觀察中
    await submit(tester, '/status'); // busy 時按鈕對 worksWhileBusy 放行
    expect(find.textContaining('r1'), findsWidgets); // 簡版 SnackBar 帶 runId
    expect(repo.sends, 0);
    // 收尾：让观察轮询正常结束，不留 timer。
    repo.status = (_) => {'status': 'completed'};
    repo.history = const [
      Message(id: '1', role: 'user', content: '問題一'),
      Message(id: '2', role: 'assistant', content: '已完成'),
    ];
    await tester.pump(const Duration(seconds: 5, milliseconds: 100));
    expect(find.text('進行中'), findsNothing);
  });

  testWidgets('stop button is live during bootstrap observation', (
    tester,
  ) async {
    await store.savePending(url, 's', userText: '問題一', runId: 'r9');
    repo.history = const [Message(id: '1', role: 'user', content: '問題一')];
    await openPage(tester);
    await tester.tap(find.text('停止'));
    await tester.pump();
    expect(repo.stopped, 'r9'); // 舊版 canControl 一刀切時這裡是無聲 no-op
    repo.status = (_) => {'status': 'cancelled'};
    await tester.pump(const Duration(seconds: 5, milliseconds: 100));
    expect(find.text('進行中'), findsNothing);
    expect(store.loadPending(url, 's'), isNull);
    expect(repo.sends, 0);
  });

  testWidgets('/stop without a runId surfaces why, never hits the model', (
    tester,
  ) async {
    repo.history = const [Message(id: '1', role: 'user', content: '問題一')];
    await openPage(tester);
    await submit(tester, '/stop');
    expect(find.textContaining('沒有可停止'), findsOneWidget);
    expect(repo.stopCalls, 0);
    expect(repo.sends, 0); // 不可 stop 也不能掉進一般訊息路徑
  });
}
