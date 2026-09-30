import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/chat/live_turn.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session_activity.dart';

// UPD-COMPAT P3 §4/§7: the live-owner handoff answers run.queued + done and
// the stream ends BY DESIGN while the owner's delivery is still open. The app
// must keep the delivery id, reconcile EOF read-only (never a re-POST, never
// a dropped-connection claim) and settle once the receipt lands in history.
class FakeRepo extends HermesRepository {
  FakeRepo() : super('http://test.invalid', 'fake');
  StreamController<SseEvent>? _cur;
  List<Message> history = [];
  int sends = 0, reads = 0;
  StreamController<SseEvent> get events => _cur!;
  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async =>
      {'id': sid, 'message_count': 0};
  @override
  Stream<SseEvent> chat(String sid, String input, {String? wakeBatch}) {
    sends++;
    _cur = StreamController<SseEvent>();
    return _cur!.stream;
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
  void cancelStream(String sid) => closeStream();

  void closeStream() {
    final c = _cur;
    if (c != null && !c.isClosed) unawaited(c.close());
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
  tearDown(() => repo.close());

  ChatController make(List<int> delays) => ChatController(
    repo,
    store,
    's',
    wait: (d) async {
      delays.add(d.inSeconds);
    },
  );

  Future<void> launch(ChatController c) async {
    // send() claims the persisted pending record before subscribing; let
    // that resolve so repo.chat() exists before the first event lands.
    await Future<void>.delayed(Duration.zero);
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r","session_id":"s"}'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(c.phase, ChatPhase.sending);
  }

  void queueTurn(ChatController c) {
    repo.events.add(
      const SseEvent(
        'run.queued',
        '{"status":"queued","delivery_id":"d-1","session_id":"s"}',
      ),
    );
  }

  test('LiveTurn: run.queued keeps delivery id and is never completion', () {
    final t = LiveTurn();
    t.apply(
      const SseEvent('run.started', '{"run_id":"r","session_id":"s"}'),
      's',
    );
    t.apply(
      const SseEvent(
        'run.queued',
        '{"status":"queued","delivery_id":"d-9","session_id":"s"}',
      ),
      's',
    );
    expect(t.completed, isFalse);
    expect(t.queued, isTrue);
    expect(t.deliveryId, 'd-9');
    t.apply(const SseEvent('done', '{}'), 's');
    expect(t.completed, isFalse); // done is transport-level; not an outcome
  });

  test('queued EOF reconciles read-only, settles on history, never re-POSTs',
      () async {
        final delays = <int>[];
        final c = make(delays);
        final sending = c.send('hello');
        await launch(c);
        queueTurn(c);
        await Future<void>.delayed(Duration.zero);
        expect(c.live!.queued, isTrue);
        expect(c.live!.deliveryId, 'd-1');
        repo.history = const [
          Message(id: '1', role: 'user', content: 'hello'),
          Message(id: '2', role: 'assistant', content: 'owner final'),
        ];
        repo.events.add(const SseEvent('done', '{}'));
        await repo.events.close();
        await sending;
        expect(repo.sends, 1); // the POST is never replayed for a queued turn
        expect(delays, [1]); // settled on the first neutral reconcile
        expect(c.phase, ChatPhase.idle);
        expect(c.messages.last.content, 'owner final');
        c.dispose();
      });

  test(
    'queued EOF exhaustion stays neutral (unconfirmed), never re-POSTs',
    () async {
      final delays = <int>[];
      final c = make(delays);
      final sending = c.send('hello');
      await launch(c);
      queueTurn(c);
      repo.history = const []; // receipt has not landed at all
      repo.events.add(const SseEvent('done', '{}'));
      await repo.events.close();
      await sending;
      expect(delays, [1, 2, 4, 8, 16, 30]);
      expect(repo.sends, 1);
      expect(c.phase, ChatPhase.uncertain);
      // WEBSYNC F1: this turn carries an acknowledged runId (run.started
      // arrived before run.queued), so the exhausted wording is DELIVERED
      // — F1 says a known run_id means the message was received, whatever
      // the transport did after. Still never M027, still never a re-POST.
      expect((c.error! as UiLocal).key, MessageKey.chatDeliveredReplyLoading);
      expect((c.error! as UiLocal).key, isNot(MessageKey.chatStateM027));
      c.dispose();
    },
  );

  test('tool.failed payload fixture closes the pending tool row (§4 A4)',
      () async {
        final c = make(<int>[]);
        final sending = c.send('hello');
        await launch(c);
        final turn = c.live!;
        repo.events.add(
          const SseEvent(
            'tool.started',
            '{"tool_name":"web","args":"{}","session_id":"s"}',
          ),
        );
        repo.events.add(
          const SseEvent(
            'tool.failed',
            '{"tool_name":"web","preview":"boom","session_id":"s"}',
          ),
        );
        repo.events.add(
          const SseEvent(
            'assistant.completed',
            '{"content":"done","session_id":"s"}',
          ),
        );
        repo.events.add(
          const SseEvent('run.completed', '{"completed":true,"messages":[]}'),
        );
        await repo.events.close();
        await sending;
        expect(turn.tools.single.completed, isTrue);
        expect(turn.tools.single.result, 'boom');
        expect(c.phase, ChatPhase.idle);
        c.dispose();
      });

  test('run.completed without messages keeps the finalText outcome', () async {
    final c = make(<int>[]);
    final sending = c.send('hello');
    await launch(c);
    final turn = c.live!;
    repo.events.add(
      const SseEvent(
        'assistant.completed',
        '{"content":"FINAL TEXT","session_id":"s"}',
      ),
    );
    repo.events.add(
      const SseEvent('run.completed', '{"completed":true,"session_id":"s"}'),
    );
    await repo.events.close();
    await sending;
    expect(turn.finalText, 'FINAL TEXT'); // empty transcript lost no text
    expect(c.phase, ChatPhase.idle);
    expect(repo.sends, 1);
    c.dispose();
  });
}
