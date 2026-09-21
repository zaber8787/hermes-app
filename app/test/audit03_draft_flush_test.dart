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

/// AUDIT-03 regression: the 400ms draft debounce must never swallow the
/// last keystrokes — dispose() flushes the current snapshot. Leaving inside
/// the debounce window (0/100/399ms) and re-entering keeps the FULL text;
/// after a send the box stays empty (no ghost resurrection).
class FakeFlushRepo extends HermesRepository {
  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  FakeFlushRepo() : super('http://test.invalid', 'fake');

  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async =>
      {'id': sid, 'message_count': 0}; // R1 sync clock: quiet by default
  final events = StreamController<SseEvent>();
  List<Message> history = [];
  Json Function(String runId) status = (_) => {'status': 'running'};
  int sends = 0;
  @override
  Stream<SseEvent> chat(String sid, String input) {
    sends++;
    return events.stream;
  }

  @override
  void cancelStream(String sid) => unawaited(events.close());

  @override
  Future<Json> runStatus(String runId) async => status(runId);

  @override
  Future<List<Message>> messages(
    String sid, {
    int offset = 0,
    int limit = 200,
  }) async => history;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const url = 'http://test.invalid';
  late LocalStore store;
  late FakeFlushRepo repo;
  late ProviderContainer container;

  final sessionA = Session(
    id: 's',
    title: 'A',
    count: 0,
    startedAt: 0,
    activity: 0,
    source: 'api_server',
  );

  String inputText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).last).controller!.text;

  Widget app() => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(home: ChatPage(session: sessionA)),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    repo = FakeFlushRepo();
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
    repo.close();
  });

  Future<void> leavePage(WidgetTester tester) async {
    await tester.pumpWidget(const Placeholder());
    await tester.pump(); // flushes the dispose-time saveDraft
  }

  // AUDIT-03回归：編輯後 0/100/399ms 離頁再開仍保留完整文字。
  for (final ms in [0, 100, 399]) {
    testWidgets('leaving $ms ms after typing keeps the full draft', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pump();
      await tester.enterText(find.byType(TextField), '貼上的一大段草稿-$ms');
      await tester.pump();
      await tester.pump(Duration(milliseconds: ms));
      expect(store.draft(url, 's'), isEmpty); // debounce NOT yet fired

      await leavePage(tester);
      expect(store.draft(url, 's'), '貼上的一大段草稿-$ms'); // dispose flushed

      await tester.pumpWidget(app());
      await tester.pump();
      expect(inputText(tester), '貼上的一大段草稿-$ms');
      await leavePage(tester);
    });
  }

  testWidgets('mid-debounce edits are flushed, not the older snapshot', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pump();
    await tester.enterText(find.byType(TextField), '前半段');
    await tester.pump(const Duration(milliseconds: 400)); // first save lands
    expect(store.draft(url, 's'), '前半段');
    await tester.enterText(find.byType(TextField), '前半段+後半段');
    await tester.pump(const Duration(milliseconds: 100)); // still debouncing

    await leavePage(tester);
    await tester.pumpWidget(app());
    await tester.pump();
    expect(inputText(tester), '前半段+後半段');
    expect(store.draft(url, 's'), '前半段+後半段');
    await leavePage(tester);
  });

  // Sent text must NOT come back: dispose only ever flushes the now-empty
  // box, and the ghost-draft rule on re-entry stays intact.
  testWidgets('leaving after a send keeps the box empty', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();
    await tester.enterText(find.byType(TextField), '已經送出的文字');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump();
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
    );
    await tester.pump();

    await leavePage(tester); // dispose flushes the CLEARED box, not the ghost
    expect(store.draft(url, 's'), isEmpty);

    await tester.pumpWidget(app());
    await tester.pump();
    expect(inputText(tester), isEmpty);
    // Settle the away run so the detach poll timer ends before teardown.
    repo.history = const [
      Message(id: '1', role: 'user', content: '已經送出的文字'),
      Message(id: '2', role: 'assistant', content: 'done'),
    ];
    repo.status = (_) => {'status': 'completed'};
    await leavePage(tester); // dispose → detach polls ONCE → terminal
    await tester.pump(const Duration(milliseconds: 100));
  });
}
