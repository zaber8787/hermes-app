import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';

class FakeRepo extends HermesRepository {
  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  FakeRepo() : super('http://test.invalid', 'fake');

  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async =>
      {'id': sid, 'message_count': 0}; // R1 sync clock: quiet by default
  final events = StreamController<SseEvent>();
  List<Message> history = [];
  int sends = 0, reads = 0;
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
  }) async {
    reads++;
    return history;
  }

  @override
  Future<void> stop(String runId) async {
    stopped = runId;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  late FakeRepo repo;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    repo = FakeRepo();
  });
  tearDown(() {
    repo.close();
  });
  test(
    'foreground bypasses recovery delay and stale SSE cannot overwrite new turn',
    () async {
      final delay = Completer<void>();
      final c = ChatController(repo, store, 's', wait: (_) => delay.future);
      final sending = c.send('hello');
      final recovery = c.recover();
      c.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(c.backgrounded, isTrue);
      repo.history = const [
        Message(id: '1', role: 'user', content: 'hello'),
        Message(id: '2', role: 'assistant', content: 'final'),
      ];
      c.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await c.reconcileForeground();
      expect(repo.reads, 1);
      expect(c.phase, ChatPhase.idle);
      expect(c.backgrounded, isFalse);
      repo.events.add(const SseEvent('assistant.delta', '{"delta":"stale"}'));
      delay.complete();
      await recovery;
      await repo.events.close();
      await sending;
      expect(c.phase, ChatPhase.idle);
      expect(c.messages.last.content, 'final');
      expect(repo.sends, 1);
      expect(store.lostNotice(repo.baseUrl, 's'), isNull);
      c.dispose();
    },
  );

  test('foreground keeps live SSE open when history is incomplete', () async {
    final c = ChatController(repo, store, 's');
    final sending = c.send('hello');
    c.didChangeAppLifecycleState(AppLifecycleState.hidden);
    c.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await c.reconcileForeground();
    await pumpEventQueue(); // D2: the SSE subscribe now queues behind the
    // cross-tab claim; the contract this test guards (foreground must not
    // cut a live stream) is about what happens AFTER, not this hop.
    expect(repo.reads, 1);
    expect(c.phase, ChatPhase.sending);
    expect(repo.events.hasListener, isTrue);
    repo.events.add(
      const SseEvent('run.completed', '{"completed":true,"messages":[]}'),
    );
    await repo.events.close();
    await sending;
    expect(repo.sends, 1);
    c.dispose();
  });

  test('explicit stop remains local even when server says completed', () async {
    final c = ChatController(repo, store, 's');
    final sending = c.send('hello');
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r","session_id":"s"}'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(c.canControl, isTrue);
    await c.stop();
    expect(repo.stopped, 'r');
    repo.history = const [Message(id: '1', role: 'user', content: 'hello')];
    repo.events.add(
      const SseEvent(
        'assistant.completed',
        '{"content":null,"interrupted":false}',
      ),
    );
    repo.events.add(
      const SseEvent('run.completed', '{"completed":true,"messages":[]}'),
    );
    await repo.events.close();
    await sending;
    expect(c.phase, ChatPhase.idle);
    expect(c.stopNotice, contains('已由你停止'));
    expect(store.stopRecord(repo.baseUrl, 's'), contains('accepted'));
    final reopened = ChatController(repo, store, 's');
    expect(reopened.stopNotice, contains('accepted'));
    c.dispose();
    reopened.dispose();
  });
  test('disconnect reconnects reads without replaying chat POST', () async {
    final delays = <int>[];
    final c = ChatController(
      repo,
      store,
      's',
      wait: (d) async {
        delays.add(d.inSeconds);
      },
    );
    final sending = c.send('hello');
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r","session_id":"s"}'),
    );
    repo.history = const [
      Message(id: '1', role: 'user', content: 'hello'),
      Message(id: '2', role: 'assistant', content: 'persisted final'),
    ];
    repo.events.addError(StateError('connection lost'));
    await sending;
    expect(repo.sends, 1);
    expect(delays, [1]);
    expect(c.phase, ChatPhase.idle);
    expect(c.messages.last.content, 'persisted final');
    await repo.events.close();
    c.dispose();
  });
  test(
    'ambiguous disconnect is bounded, 1→30s, and prevents duplicate send',
    () async {
      final delays = <int>[];
      final c = ChatController(
        repo,
        store,
        's',
        wait: (d) async {
          delays.add(d.inSeconds);
        },
      );
      final sending = c.send('hello');
      repo.events.addError(StateError('connection lost before run.started'));
      await sending;
      expect(delays, [1, 2, 4, 8, 16, 30]);
      expect(c.phase, ChatPhase.uncertain);
      await c.send('hello');
      expect(repo.sends, 1);
      await repo.events.close();
      c.dispose();
    },
  );
  test(
    'history narration followed by another tool call is not recovered as final',
    () async {
      final c = ChatController(repo, store, 's', wait: (_) async {});
      repo.history = const [
        Message(id: '1', role: 'user', content: 'hello'),
        Message(id: '2', role: 'assistant', content: 'still working'),
        Message(
          id: '3',
          role: 'assistant',
          toolCalls: [ToolCall('t', 'terminal', '{}')],
        ),
      ];
      final sending = c.send('hello');
      repo.events.addError(StateError('disconnected'));
      await sending;
      expect(c.phase, ChatPhase.uncertain);
      expect(repo.sends, 1);
      await repo.events.close();
      c.dispose();
    },
  );
}
