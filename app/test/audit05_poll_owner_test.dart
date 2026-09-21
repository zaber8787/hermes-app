import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/providers.dart';

/// AUDIT-05 regression suite (TASK-WAVE1 §05, the four mandated scenarios):
/// every non-terminal exit of _pollRun keeps the schedule or lands in
/// uncertain with a REAL retry — asserted on timer/request counts + phase.
class FakePollRepo extends HermesRepository {
  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  FakePollRepo() : super('http://test.invalid', 'fake');

  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async =>
      {'id': sid, 'message_count': 0}; // R1 sync clock: quiet by default
  final events = StreamController<SseEvent>();
  Json Function(String runId) status = (_) => {'status': 'running'};
  Object? messagesError; // when set, EVERY history GET fails
  List<Message> Function()? messagesFn;
  List<Message> history = const [];
  int sends = 0, statusCalls = 0, messagesCalls = 0, approvalCalls = 0;
  @override
  Stream<SseEvent> chat(String sid, String input) {
    sends++;
    return events.stream;
  }

  @override
  void cancelStream(String sid) => unawaited(events.close());

  @override
  Future<Json> runStatus(String runId) async {
    statusCalls++;
    return status(runId);
  }

  @override
  Future<void> resolveApproval(String runId, String choice) async {
    approvalCalls++;
    status = (_) => {'status': 'completed'}; // the answer lands: run finishes
  }

  @override
  Future<List<Message>> messages(
    String sid, {
    int offset = 0,
    int limit = 200,
  }) async {
    messagesCalls++;
    if (messagesError != null) throw messagesError!;
    return messagesFn?.call() ?? history;
  }
}

class _NetDown implements Exception {
  const _NetDown();
}

const _userRow = [
  Message(id: 'u1', role: 'user', content: 'hi', timestamp: 1),
];
const _finalRows = [
  Message(id: 'u1', role: 'user', content: 'hi', timestamp: 1),
  Message(id: 'a1', role: 'assistant', content: 'done', timestamp: 2),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  late FakePollRepo repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    repo = FakePollRepo();
  });
  tearDown(() => repo.close());

  // Scenario ① — attach's OWN snapshot poll hits the dead network, recovers.
  test('attach first poll failing re-arms the schedule and settles', () async {
    final c = ChatController(repo, store, 's',
        watchInterval: const Duration(milliseconds: 20));
    final sending = c.send('hi');
    repo.events.add(
        const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'));
    await Future<void>.delayed(Duration.zero);
    var calls = 0; // call #1 = detach's snapshot, #2 = attach's snapshot
    repo.status = (_) {
      calls++;
      if (calls == 2) throw const _NetDown();
      return {'status': 'running'};
    };
    c.detach();
    c.attach(); // cancels the timer, polls once — that poll (call 2) misses
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(c.busy, isTrue);
    expect(c.phase, isNot(ChatPhase.uncertain));
    final stranded = repo.statusCalls;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(repo.statusCalls, greaterThan(stranded),
        reason: 'the single failed poll must NOT strand busy with no timer');
    repo.status = (_) => {'status': 'completed'};
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(c.phase, ChatPhase.idle);
    expect(repo.sends, 1);
    c.dispose();
    await sending;
  });

  // Scenario ①b — attach's snapshot sees waiting_for_approval: the card
  // waits WITH a live scheduler, and answering reaches terminal.
  test('approval after attach keeps polling and settles on answer', () async {
    final c = ChatController(repo, store, 's',
        watchInterval: const Duration(milliseconds: 10));
    final sending = c.send('hi');
    repo.events.add(
        const SseEvent('run.started', '{"run_id":"r2","session_id":"s"}'));
    await Future<void>.delayed(Duration.zero);
    var calls = 0;
    repo.status = (_) {
      calls++;
      return calls == 1
          ? {'status': 'running'} // detach's snapshot
          : {
              'status': 'waiting_for_approval', // attach's snapshot onward
              'approval': {'command': 'ls'},
            };
    };
    c.detach();
    c.attach();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(c.live?.approval, isNotNull);
    final afterAttach = repo.statusCalls;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(repo.statusCalls, greaterThan(afterAttach),
        reason: 'waiting_for_approval must keep a live scheduler (AUDIT-05①)');
    await c.resolveApproval('once');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(repo.approvalCalls, 1);
    expect(c.phase, ChatPhase.idle);
    c.dispose();
    await sending;
  });

  // Scenario ② — 13th transport error: stop hammering, but land in uncertain
  // whose 「重新核對」 resumes the REAL status poll (timer counts prove it).
  test('transport cap lands in uncertain and retry resumes polling', () async {
    final c = ChatController(repo, store, 's',
        watchInterval: const Duration(milliseconds: 10));
    final sending = c.send('hi');
    repo.events.add(
        const SseEvent('run.started', '{"run_id":"r3","session_id":"s"}'));
    await Future<void>.delayed(Duration.zero);
    repo.status = (_) => throw const _NetDown();
    c.detach();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(c.phase, ChatPhase.uncertain);
    expect(c.error, contains('重新核對'));
    final frozen = repo.statusCalls;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(repo.statusCalls, frozen, reason: 'capped: no timer keeps running');
    repo.status = (_) => {'status': 'completed'};
    await c.retryReconcile();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(repo.statusCalls, greaterThan(frozen),
        reason: 'retry must issue REAL status polls, not just repaint');
    expect(c.phase, ChatPhase.idle);
    c.dispose();
    await sending;
  });

  // Scenario ③ — terminal status but the history GET 500s: settle idle with a
  // retry hint, NEVER busy-with-empty-schedule; pull-to-refresh works again.
  test('terminal with failing history settles idle and stays retryable',
      () async {
    final c = ChatController(repo, store, 's',
        watchInterval: const Duration(milliseconds: 10));
    final sending = c.send('hi');
    repo.events.add(
        const SseEvent('run.started', '{"run_id":"r4","session_id":"s"}'));
    await Future<void>.delayed(Duration.zero);
    repo.messagesError = const ApiException('boom', 500);
    repo.status = (_) => {'status': 'completed'};
    c.detach();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(c.phase, ChatPhase.idle);
    expect(c.busy, isFalse);
    expect(c.error, contains('歷史載入失敗'));
    final frozen = repo.statusCalls;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(repo.statusCalls, frozen, reason: 'no scheduler may outlive settle');
    // The hint is honest: load() is no longer blocked by a stuck busy, and a
    // refresh now lands the history.
    repo.messagesError = null;
    repo.history = _finalRows;
    await c.load();
    expect(c.error, isNull);
    expect(c.messages.last.content, 'done');
    c.dispose();
    await sending;
  });

  // Scenario ①c — the fourth variant of the same root cause: attach's single
  // snapshot with a runId-less turn whose HISTORY read fails. The error must
  // stay inside the schedule discipline; it used to escape _pollRun and leave
  // busy with an empty schedule plus an unhandled async error.
  test('attach + failing history read keeps polling until settle', () async {
    final c = ChatController(repo, store, 's',
        watchInterval: const Duration(milliseconds: 20));
    final sending = c.send('hi'); // no run.started ever surfaces
    await Future<void>.delayed(Duration.zero);
    repo.messagesFn = () => _userRow; // delivered, still no final
    c.detach(); // runId null → polls reconcile history
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(c.busy, isTrue);
    repo.messagesError = const ApiException('boom', 500);
    c.attach(); // clears the timer; this snapshot's history GET fails
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final stranded = repo.messagesCalls;
    repo.messagesError = null; // network recovers
    repo.messagesFn = () => _finalRows;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(repo.messagesCalls, greaterThan(stranded),
        reason: 'failed snapshot poll must re-arm, not strand busy');
    expect(c.phase, ChatPhase.idle);
    c.dispose();
    await sending;
  });

  // AUDIT-05② UI face: the uncertain error row really surfaces 「重新核對」.
  testWidgets('uncertain phase surfaces the 重新核對 button', (tester) async {
    final container = ProviderContainer(overrides: [
      localStoreProvider.overrideWithValue(store),
      initialSettingsProvider.overrideWithValue(
        const AppSettings(url: 'http://test.invalid', key: 'fake'),
      ),
      repositoryProvider.overrideWithValue(repo),
      skillsProvider.overrideWith((ref) async => []),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: ChatPage(
          session: Session(
            id: 's',
            title: 'A',
            count: 1,
            startedAt: 0,
            activity: 0,
            source: 'api_server',
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    final page = container.read(chatProvider('s'));
    page.phase = ChatPhase.uncertain;
    page.error = '背景任務進度暫時查不到，請按「重新核對」重試。';
    page.notifyListeners();
    await tester.pump();
    expect(find.text('重新核對'), findsOneWidget);
    expect(find.text('重試'), findsNothing); // busy: load() would no-op anyway
    // Park the controller idle BEFORE unmount: a forced-busy page leaving
    // would legitimately arm detach()'s 5s poll timer and never drain it.
    page.phase = ChatPhase.idle;
    page.error = null;
    page.notifyListeners();
    await tester.pumpWidget(const Placeholder());
    await tester.pump();
  });
}
