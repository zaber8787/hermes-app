import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/localized_app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/providers.dart';

/// Fake with controllable SSE frames and run status (FakeRepo2 pattern).
class FakeGhostRepo extends HermesRepository {
  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  FakeGhostRepo() : super('http://test.invalid', 'fake');

  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async =>
      {'id': sid, 'message_count': 0}; // R1 sync clock: quiet by default
  final events = StreamController<SseEvent>();
  List<Message> history = [];
  int sends = 0;
  Json Function(String runId) status = (_) => {'status': 'running'};
  @override
  Stream<SseEvent> chat(String sid, String input) {
    sends++;
    return events.stream;
  }

  @override
  void cancelStream(String sid) {
    // Real repo cuts the socket mid-iteration; closing the stream ends the
    // consumer loop the same way.
    unawaited(events.close());
  }

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
  const url = 'http://test.invalid';
  const ghost = '幽靈文字別再回來';
  late LocalStore store;
  late FakeGhostRepo repo;
  late ProviderContainer container;

  String inputText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).last).controller!.text;

  Widget app(Session session) => UncontrolledProviderScope(
    container: container,
    child: localizedWrap(ChatPage(session: session)),
  );

  final sessionA = Session(
    id: 's',
    title: 'A',
    count: 1,
    startedAt: 0,
    activity: 0,
    source: 'api_server',
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    repo = FakeGhostRepo();
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

  Future<void> typeAndSend(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump(); // rebuild so the send button picks up the new text
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump();
  }

  Future<void> leavePage(WidgetTester tester) async {
    await tester.pumpWidget(const Placeholder());
    await tester.pump();
  }

  // Requirement ①: send → dispose while the run streams → reopen.
  testWidgets('re-entry mid-run shows an empty box (run still streaming)', (
    tester,
  ) async {
    await tester.pumpWidget(app(sessionA));
    await tester.pump();
    await typeAndSend(tester, ghost);
    expect(store.draft(url, 's'), ghost); // pre-send crash-save in flight
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
    );
    await tester.pump();

    await leavePage(tester); // dispose → detach cuts the SSE
    await tester.pumpWidget(app(sessionA));
    await tester.pump();

    expect(inputText(tester), isEmpty);
    expect(store.draft(url, 's'), isEmpty);
    // Let the backgrounded run land so no poll timer outlives the test.
    repo.history = const [
      Message(id: '1', role: 'user', content: ghost),
      Message(id: '2', role: 'assistant', content: 'done'),
    ];
    repo.status = (_) => {'status': 'completed'};
    await leavePage(tester);
    await tester.pump(const Duration(seconds: 5, milliseconds: 100));
  });

  // Requirement ②: send → leave → run COMPLETES while away → reopen.
  // The early-return on detach is bypassed here (stream EOF'd → recover
  // backoff → poll takes over), so the old page's post-send draft clearing
  // only runs long after the reopened page already loaded the stale draft.
  testWidgets('re-entry after the run finished while away shows an empty box', (
    tester,
  ) async {
    await tester.pumpWidget(app(sessionA));
    await tester.pump();
    await typeAndSend(tester, ghost);
    expect(store.draft(url, 's'), ghost); // crash-save still there
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r9","session_id":"s"}'),
    );
    await tester.pump();
    // Gateway closes the stream early; the run keeps going server-side and
    // the controller enters its recover backoff.
    await repo.events.close();
    await tester.pump();

    repo.history = const [
      Message(id: '1', role: 'user', content: ghost),
      Message(id: '2', role: 'assistant', content: '好的，處理完了'),
    ];
    repo.status = (_) => {'status': 'completed'};
    await leavePage(tester); // detach hands the outcome to the poll pass
    await tester.pumpWidget(app(sessionA));
    await tester.pump();

    expect(inputText(tester), isEmpty);
    expect(store.draft(url, 's'), isEmpty);
    await leavePage(tester);
    await tester.pump(const Duration(seconds: 2)); // drain recover backoff
  });

  // Requirement ③: typed but never sent → draft survives re-entry.
  testWidgets('unsent typed text is preserved across re-entry', (tester) async {
    await tester.pumpWidget(app(sessionA));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '打到一半的筆記');
    await tester.pump(const Duration(milliseconds: 400)); // debounce persists
    expect(store.draft(url, 's'), '打到一半的筆記');

    await leavePage(tester);
    await tester.pumpWidget(app(sessionA));
    await tester.pump();

    expect(inputText(tester), '打到一半的筆記');
    expect(store.draft(url, 's'), '打到一半的筆記');
    await leavePage(tester);
  });

  // Ghost-forever variant: no SSE frame ever surfaced (transport died at
  // connect) yet the server persisted the user row; the abandoned send()
  // never clears the draft (its error stays non-null), so without the
  // re-entry ghost filter the text haunts the input indefinitely.
  testWidgets('delivered draft whose stream never surfaced is dropped', (
    tester,
  ) async {
    await tester.pumpWidget(app(sessionA));
    await tester.pump();
    await typeAndSend(tester, ghost);
    repo.history = const [Message(id: '1', role: 'user', content: ghost)];
    await repo.events.close(); // EOF before any frame
    await tester.pump();
    // Recover's first reconcile (after 1s backoff) sees the delivered row.
    await tester.pump(const Duration(seconds: 1));

    await leavePage(tester); // detach → poll watches via history
    await tester.pumpWidget(app(sessionA));
    await tester.pump();

    expect(inputText(tester), isEmpty);
    expect(store.draft(url, 's'), isEmpty);
    // Deliver the final so the detached reconcile/poll settles its timer.
    repo.history = const [
      Message(id: '1', role: 'user', content: ghost),
      Message(id: '2', role: 'assistant', content: 'done'),
    ];
    await leavePage(tester);
    await tester.pump(const Duration(seconds: 6)); // drain backoff + poll
  });
}
