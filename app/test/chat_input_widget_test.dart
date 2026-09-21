import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:hermes_app/platform/chat_input_platform.dart';
import 'package:hermes_app/providers.dart';

class FakeInputRepo extends HermesRepository {
  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  FakeInputRepo() : super('http://test.invalid', 'fake');

  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async =>
      {'id': sid, 'message_count': 0}; // R1 sync clock: quiet by default
  final events = StreamController<SseEvent>.broadcast();
  List<Message> history = [];
  int sends = 0;
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
  void cancelStream(String sid) => unawaited(events.close());
}

/// 真 ChatPage/TextField：平台鍵語意、換行插入、IME action 走完整回調鏈，
/// 不只測 helper。debugChatInputPlatform 讓行動/桌面兩種語意在同一支
/// 二進位內都可測（Web 由條件匯入在編譯期固定桌面策略，另有 Chrome 跑）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  late FakeInputRepo repo;
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

  String inputText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).last).controller!.text;

  Future<void> openPage(WidgetTester tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: ChatPage(session: sessionA)),
    ));
    await tester.pump();
    await tester.pump();
  }

  Future<void> keyCombo(
    WidgetTester tester, {
    bool shift = false,
  }) async {
    if (shift) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    if (shift) {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    }
    await tester.pump();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    repo = FakeInputRepo();
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
    debugChatInputPlatform = null;
    container.dispose();
    if (!repo.events.isClosed) unawaited(repo.events.close());
    repo.close();
  });

  testWidgets('mobile: Enter and Shift+Enter insert newlines, never send', (
    tester,
  ) async {
    debugChatInputPlatform = TargetPlatform.android;
    await openPage(tester);
    await tester.showKeyboard(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '第一行');
    await tester.pump();
    await keyCombo(tester);
    expect(inputText(tester), '第一行\n'); // 換行落地在 TextField 內容上
    await keyCombo(tester, shift: true);
    expect(inputText(tester), '第一行\n\n');
    expect(repo.sends, 0);
  });

  testWidgets('desktop: plain Enter sends, Shift+Enter breaks a line', (
    tester,
  ) async {
    debugChatInputPlatform = TargetPlatform.macOS;
    await openPage(tester);
    await tester.showKeyboard(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '多行內容');
    await tester.pump();
    await keyCombo(tester, shift: true);
    // 換行落地在引擎（multiline 常態），sendKeyEvent 途徑只保證「不送出」
    expect(repo.sends, 0);
    await keyCombo(tester); // 純 Enter＝送出
    await tester.pump();
    await tester.pump();
    expect(repo.sends, 1);
    repo.events.add(
      const SseEvent('run.completed', '{"completed":true,"messages":[]}'),
    );
    await repo.events.close();
    await tester.pump();
  });

  testWidgets(
    'IME send action: composing blocks (zero POST, candidates kept), '
    'committing then sending posts exactly once',
    (tester) async {
      debugChatInputPlatform = TargetPlatform.android;
      await openPage(tester);
      await tester.showKeyboard(find.byType(TextField));
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '中文候選',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange(start: 0, end: 4),
        ),
      );
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(repo.sends, 0); // 選字未確認：零 POST
      expect(inputText(tester), contains('中文候選')); // 候選文字保留
      // 提交選字（composing 清空）後才准送
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '中文候選確定',
          selection: TextSelection.collapsed(offset: 6),
          composing: TextRange.empty,
        ),
      );
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      await tester.pump();
      expect(repo.sends, 1);
      repo.events.add(
        const SseEvent('run.completed', '{"completed":true,"messages":[]}'),
      );
      await tester.pump();
    },
  );

  testWidgets('mobile hint states Enter=newline, send key=send', (tester) async {
    debugChatInputPlatform = TargetPlatform.android;
    await openPage(tester);
    final field = tester.widget<TextField>(find.byType(TextField).last);
    expect(field.decoration!.hintText, contains('Enter 換行'));
    expect(field.keyboardType, TextInputType.multiline);
  });
}
