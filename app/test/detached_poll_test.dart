import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';

/// Fake with controllable run-status polling and stream cancellation.
class FakeRepo2 extends HermesRepository {
  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  FakeRepo2() : super('http://test.invalid', 'fake');

  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async =>
      {'id': sid, 'message_count': 0}; // R1 sync clock: quiet by default
  final events = StreamController<SseEvent>();
  List<Message> history = [];
  int sends = 0, statusCalls = 0, cancels = 0;
  Json Function(String runId) status = (_) => {'status': 'running'};
  @override
  Stream<SseEvent> chat(String sid, String input) {
    sends++;
    return events.stream;
  }

  @override
  void cancelStream(String sid) {
    cancels++;
    // Real repo cuts the socket mid-iteration; closing the stream ends the
    // generator loop the same way.
    unawaited(events.close());
  }

  @override
  Future<Json> runStatus(String runId) async {
    statusCalls++;
    return status(runId);
  }

  @override
  Future<List<Message>> messages(String sid, {int offset = 0, int limit = 200}) async => history;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  late FakeRepo2 repo;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    repo = FakeRepo2();
  });
  tearDown(() => repo.close());

  test('detach cuts the SSE and polling completes the run from status',
      () async {
    final c = ChatController(repo, store, 's',
        watchInterval: const Duration(milliseconds: 1));
    final sending = c.send('hello');
    repo.events.add(
        const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'));
    await Future<void>.delayed(Duration.zero);
    expect(c.live?.runId, 'r1');

    repo.status = (_) => {'status': 'running'};
    c.detach();
    expect(repo.cancels, 1);
    expect(c.detached, isTrue);

    // Run finishes server-side while no socket is attached.
    repo.history = const [
      Message(id: '1', role: 'user', content: 'hello'),
      Message(id: '2', role: 'assistant', content: 'done while away'),
    ];
    repo.status = (_) => {'status': 'completed'};
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sending;

    expect(c.phase, ChatPhase.idle);
    expect(c.detached, isFalse);
    expect(c.messages.last.content, 'done while away');
    expect(repo.sends, 1); // never re-sent
    c.dispose();
  });

  test('detach restores the approval card from polled status', () async {
    final c = ChatController(repo, store, 's',
        watchInterval: const Duration(milliseconds: 1));
    final sending = c.send('hello');
    repo.events.add(
        const SseEvent('run.started', '{"run_id":"r2","session_id":"s"}'));
    await Future<void>.delayed(Duration.zero);
    repo.status = (_) => {
          'status': 'waiting_for_approval',
          'approval': {'command': 'rm -rf /tmp/x', 'description': 'danger'},
        };
    c.detach();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(c.live?.approval, isNotNull);
    expect(c.live?.approval?.containsKey('command'), isTrue);
    c.dispose();
    await sending;
  });

  test('attach stops the timer and finishes a completed run in one poll',
      () async {
    final c = ChatController(repo, store, 's',
        watchInterval: const Duration(seconds: 3600));
    final sending = c.send('hello');
    repo.events.add(
        const SseEvent('run.started', '{"run_id":"r3","session_id":"s"}'));
    await Future<void>.delayed(Duration.zero);
    repo.history = const [
      Message(id: '1', role: 'user', content: 'hello'),
      Message(id: '2', role: 'assistant', content: 'final'),
    ];
    repo.status = (_) => {'status': 'completed'};
    c.detach();
    c.attach(); // long interval never fires; attach must poll once
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await sending;
    expect(c.phase, ChatPhase.idle);
    expect(c.messages.last.content, 'final');
    expect(c.detached, isFalse);
    c.dispose();
  });

  test('pending bubble hides once history carries the sent row', () async {
    final c = ChatController(repo, store, 's',
        watchInterval: const Duration(milliseconds: 1));
    final sending = c.send('hello');
    await Future<void>.delayed(Duration.zero);
    expect(c.pendingDelivered, isFalse);
    repo.history = const [Message(id: '1', role: 'user', content: 'hello')];
    c.detach(); // no run.started yet → poll reconciles history instead
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(c.pendingDelivered, isTrue); // dedup signal for the UI
    expect(c.busy, isTrue); // still mid-run, bubble suppressed not finished
    c.dispose();
    await sending;
  });

  test('polling gives up after repeated transport misses', () async {
    final c = ChatController(repo, store, 's',
        watchInterval: const Duration(milliseconds: 1));
    final sending = c.send('hello');
    repo.events.add(
        const SseEvent('run.started', '{"run_id":"r4","session_id":"s"}'));
    await Future<void>.delayed(Duration.zero);
    c.detach();
    // Simulate a dead network: runStatus throws non-Api (transport) errors.
    repo.events.close();
    repo.status = (_) => throw const SocketErrorShim();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.busy, isTrue); // still mid-run, not falsely finished
    c.dispose();
    await sending;
  });
}

class SocketErrorShim implements Exception {
  const SocketErrorShim();
}
