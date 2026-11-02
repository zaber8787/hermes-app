import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/data/gateway_ws.dart';
import 'package:hermes_app/data/ws_outbox.dart';
import 'package:hermes_app/data/ws_route.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/platform/connectivity_hint.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// TASK-WSAPP: the app side of the bridge, against a fake that speaks the
/// wire shape of compat/wsbridge.py (id pairing, `method:"event"` frames,
/// `resume_required`, `session_not_allowlisted`, submission_id dedupe).
const sid = 'discord-session';
const url = 'http://test.invalid';

class FakeSocket implements WsSocket {
  FakeSocket(this.bridge);
  final FakeBridge bridge;
  final _frames = StreamController<String>();
  final resumed = <String>{};

  @override
  Stream<String> get messages => _frames.stream;

  @override
  void send(String text) => bridge.receive(this, text);

  void push(Json frame) {
    if (!_frames.isClosed) _frames.add(jsonEncode(frame));
  }

  @override
  Future<void> close([int code = 1000]) async {
    if (!_frames.isClosed) await _frames.close();
  }
}

class FakeBridge {
  bool up = true;
  FakeSocket? socket;
  int dials = 0;
  int generation = 7;

  /// Resumes in wire order, over every connection.
  final resumes = <String>[];

  /// The owner's messages table: one row per distinct submission id.
  final userRows = <String>[];
  final submissionIds = <String>[];
  final steers = <Json>[];
  final interrupts = <Json>[];
  final seenKeys = <String>{};

  /// Next submit: land it, then lose the connection before the answer.
  bool dropAfterNextSubmit = false;
  String? refuseSubmit;
  Json steerAnswer = const {'status': 'queued', 'delivered': true};

  /// Submits run a turn on their own unless a test drives it by hand.
  bool autoTurn = true;

  Future<WsSocket> connect(Uri u, String key) async {
    dials++;
    if (!up) throw StateError('bridge down');
    return socket = FakeSocket(this);
  }

  void drop() {
    final s = socket;
    socket = null;
    unawaited(s?.close());
  }

  void event(String type, Json payload, {String admission = 'adm1'}) {
    socket?.push({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {
        'type': type,
        'session_id': sid,
        'payload': payload,
        'replay_epoch': 'e1',
        'seq': 1,
        'admission_id': admission,
        'execution_generation': generation,
      },
    });
  }

  void receive(FakeSocket s, String raw) {
    final frame = jsonDecode(raw) as Json;
    final id = frame['id'];
    final method = frame['method'] as String;
    final params = Map<String, dynamic>.from(frame['params'] as Map);
    void ok(Json result) => s.push({'id': id, 'result': result});
    void err(String reason, [Json data = const {}]) => s.push({
      'id': id,
      'error': {
        'code': 4001,
        'message': reason,
        'data': {'reason': reason, ...data},
      },
    });
    switch (method) {
      case 'session.resume':
        resumes.add(params['session_id'] as String);
        s.resumed.add(params['session_id'] as String);
        ok({
          'session_id': params['session_id'],
          'messages': const [],
          'running': false,
          'execution_generation': generation,
          'replay_epoch': 'e1',
          'last_sequence': 0,
          'pending': const [],
        });
      case 'prompt.submit':
        if (!s.resumed.contains(params['session_id'])) {
          err('permission_denied', {'detail': 'resume_required'});
          return;
        }
        if (refuseSubmit != null) {
          err(refuseSubmit!);
          return;
        }
        final key = params['submission_id'] as String;
        submissionIds.add(key);
        if (seenKeys.add(key)) userRows.add(params['text'] as String);
        if (dropAfterNextSubmit) {
          dropAfterNextSubmit = false;
          drop();
          return;
        }
        ok({
          'admission_id': 'adm1',
          'status': 'queued',
          'outcome': 'admitted',
          'execution_generation': generation,
        });
        if (autoTurn) {
          event('message.delta', {'text': 'po'});
          event('message.complete', {'text': 'pong', 'status': 'complete'});
        }
      case 'session.steer':
        steers.add(params);
        ok(steerAnswer);
      case 'session.interrupt':
        interrupts.add(params);
        ok({'status': 'interrupted'});
      default:
        err('method_not_found');
    }
  }
}

class MapPersistence implements WsOutboxPersistence {
  String? value;
  @override
  String? read() => value;
  @override
  Future<void> write(String? v) async => value = v;
}

class FakeRepo extends HermesRepository {
  FakeRepo() : super(url, 'fake');
  List<Message> history = const [];
  int httpSends = 0;
  final events = StreamController<SseEvent>();

  @override
  Future<SessionActivity> sessionActivity(String s) async =>
      SessionActivity.quiet(s);

  @override
  Future<Map<String, dynamic>> sessionDetail(String s) async => {
    'id': s,
    'message_count': 0,
  };

  @override
  Stream<SseEvent> chat(String s, String input, {String? wakeBatch}) {
    httpSends++;
    return events.stream;
  }

  @override
  Future<List<Message>> messages(
    String s, {
    int offset = 0,
    int limit = 200,
  }) async => history;
}

Future<void> until(bool Function() condition, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition never held: ${reason ?? ''}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

GatewayWs newWs(FakeBridge bridge) => GatewayWs(
  url: Uri.parse('ws://test.invalid/bridge/api/bridge/ws'),
  apiKey: 'test-only',
  connector: bridge.connect,
  wait: (_) => Future<void>.delayed(const Duration(milliseconds: 1)),
);

WsRouter newRouter(GatewayWs ws, WsOutbox outbox) => WsRouter(
  ws: ws,
  outbox: outbox,
  allow: const [WsDirectEntry('thread-1', sid)],
  supported: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('routing is an allowlist', () {
    late WsRouter router;
    setUp(() {
      final bridge = FakeBridge();
      final ws = newWs(bridge);
      router = newRouter(ws, WsOutbox(ws, MapPersistence()));
      addTearDown(router.dispose);
    });

    test('only an allowlisted foreign session routes', () {
      expect(router.routes(sid, 'discord'), isTrue);
      expect(router.routes('other', 'discord'), isFalse);
      expect(router.routes(sid, 'api_server'), isFalse);
      expect(router.routes(sid, 'bot_room'), isFalse);
      expect(router.routes(sid, ''), isFalse);
      expect(router.routes(sid, null), isFalse);
    });

    test('a platform without the bridge routes nothing', () {
      final bridge = FakeBridge();
      final ws = newWs(bridge);
      final off = WsRouter(
        ws: ws,
        outbox: WsOutbox(ws, MapPersistence()),
        allow: const [WsDirectEntry('thread-1', sid)],
        supported: false,
      );
      addTearDown(off.dispose);
      expect(off.routes(sid, 'discord'), isFalse);
      expect(WsRouter.disabled().routes(sid, 'discord'), isFalse);
    });
  });

  test('the bridge URL derives from the server URL unless overridden', () {
    expect(
      deriveBridgeUrl('https://bot.example.net'),
      'wss://bot.example.net/bridge/api/bridge/ws',
    );
    expect(
      deriveBridgeUrl('http://10.0.0.2:8642/'),
      'ws://10.0.0.2:8642/bridge/api/bridge/ws',
    );
    expect(deriveBridgeUrl('not a url'), '');
    expect(parseBridgeUrl('https://nope.example'), isNull);
    expect(parseBridgeUrl('wss://ok.example/x'), isNotNull);
  });

  test('allowlist text parses pairs and refuses a malformed line', () {
    final ok = WsDirectEntry.parseLines('111 s-1\n\n222 s-2\n')!;
    expect(ok.map((e) => e.sessionId), ['s-1', 's-2']);
    expect(WsDirectEntry.formatLines(ok), '111 s-1\n222 s-2');
    expect(WsDirectEntry.parseLines('only-one-token'), isNull);
  });

  group('GatewayWs', () {
    test('pairs answers by id and decodes event frames', () async {
      final bridge = FakeBridge();
      final ws = newWs(bridge);
      addTearDown(ws.dispose);
      final seen = <WsEvent>[];
      ws.events.listen(seen.add);
      ws.start();
      await until(() => ws.connected);

      final resumed = await ws.resume(sid);
      expect(resumed.executionGeneration, 7);
      bridge.event('message.delta', {'text': 'x'});
      await until(() => seen.isNotEmpty);
      expect(seen.single.type, 'message.delta');
      expect(seen.single.admissionId, 'adm1');
      expect(seen.single.replayEpoch, 'e1');
      expect(ws.generation(sid), 7);
    });

    test('a reconnect replays the resume of every attached session', () async {
      final bridge = FakeBridge();
      final ws = newWs(bridge);
      addTearDown(ws.dispose);
      ws.start();
      await until(() => ws.connected);
      await ws.resume(sid);
      expect(bridge.resumes, [sid]);

      bridge.drop();
      await until(() => bridge.resumes.length == 2, reason: 'replayed resume');
      expect(bridge.resumes, [sid, sid]);
      expect(bridge.dials, 2);
    });

    test('a pending call fails as unknown when the link drops', () async {
      final bridge = FakeBridge()..dropAfterNextSubmit = true;
      final ws = newWs(bridge);
      addTearDown(ws.dispose);
      ws.start();
      await until(() => ws.connected);
      await ws.resume(sid);
      await expectLater(
        ws.call('prompt.submit', {
          'session_id': sid,
          'submission_id': 'k',
          'text': 't',
        }),
        throwsA(
          isA<WsUnavailable>().having(
            (e) => e.outcomeUnknown,
            'outcomeUnknown',
            isTrue,
          ),
        ),
      );
    });
  });

  group('WsOutbox', () {
    test('survives a restart and flushes in the order typed', () async {
      final bridge = FakeBridge()..up = false;
      final disk = MapPersistence();
      final ws = newWs(bridge);
      final outbox = WsOutbox(ws, disk);
      await outbox.enqueue(sid, 'first');
      await outbox.enqueue(sid, 'second');
      outbox.dispose();
      ws.dispose();

      final again = newWs(bridge);
      final revived = WsOutbox(again, disk);
      addTearDown(() {
        revived.dispose();
        again.dispose();
      });
      expect(revived.entries.map((e) => e.text), ['first', 'second']);
      again.start();
      bridge.up = true;
      await until(() => bridge.userRows.length == 2, reason: 'flush');
      expect(bridge.userRows, ['first', 'second']);
      await until(() => revived.entries.isEmpty, reason: 'drained');
      expect(disk.value, isNull);
    });

    test('a lost answer resends the same key and lands once', () async {
      final bridge = FakeBridge()
        ..dropAfterNextSubmit = true
        ..autoTurn = false;
      final ws = newWs(bridge);
      final outbox = WsOutbox(ws, MapPersistence());
      addTearDown(() {
        outbox.dispose();
        ws.dispose();
      });
      ws.start();
      await until(() => ws.connected);
      await outbox.enqueue(sid, 'once');
      unawaited(outbox.flush());
      await until(() => bridge.submissionIds.length == 2, reason: 'resend');
      expect(bridge.submissionIds[0], bridge.submissionIds[1]);
      expect(bridge.userRows, ['once']);
      await until(() => outbox.entries.isEmpty, reason: 'drained');
    });

    test('a definitive refusal drops only that entry', () async {
      final bridge = FakeBridge()..refuseSubmit = 'session_not_allowlisted';
      final ws = newWs(bridge);
      final outbox = WsOutbox(ws, MapPersistence());
      addTearDown(() {
        outbox.dispose();
        ws.dispose();
      });
      final refused = <WsRefusal>[];
      outbox.refusals.listen(refused.add);
      ws.start();
      await until(() => ws.connected);
      await outbox.enqueue(sid, 'nope');
      await outbox.flush();
      await until(() => refused.isNotEmpty);
      expect(refused.single.entry.text, 'nope');
      expect(outbox.entries, isEmpty);
    });
  });

  group('the four render states match the HTTP projection', () {
    // compat/crosssource.py `_terminal`: same inputs, same terminal names.
    const cases = {
      'complete': 'run.completed',
      'interrupted': 'run.interrupted',
      'error': 'run.failed',
    };
    for (final MapEntry(key: status, value: terminal) in cases.entries) {
      test('$status ends in $terminal', () {
        final frames = wsEventToSse(
          WsEvent(
            type: 'message.complete',
            sessionId: sid,
            payload: {'text': 'done', 'status': status},
          ),
          sid,
          'm1',
        );
        expect(frames.map((f) => f.type), ['assistant.completed', terminal]);
        expect(frames.first.json['content'], 'done');
        expect(frames.last.json['messages'], isEmpty);
      });
    }

    test('a cancelled outcome without a status is run.cancelled', () {
      final frames = wsEventToSse(
        const WsEvent(
          type: 'message.complete',
          sessionId: sid,
          payload: {'outcome': 'cancelled'},
        ),
        sid,
        'm1',
      );
      expect(frames.last.type, 'run.cancelled');
    });

    test('a failed turn carries its reason', () {
      final frames = wsEventToSse(
        const WsEvent(
          type: 'message.complete',
          sessionId: sid,
          payload: {'status': 'error', 'failure_reason': 'boom'},
        ),
        sid,
        'm1',
      );
      expect(frames.last.json['error'], 'boom');
    });

    test('tools project to the SSE names', () {
      List<SseEvent> of(String type, Json payload) => wsEventToSse(
        WsEvent(type: type, sessionId: sid, payload: payload),
        sid,
        'm1',
      );
      expect(of('tool.start', {'tool_name': 'x'}).single.type, 'tool.started');
      expect(
        of('tool.complete', {'tool_name': 'x'}).single.type,
        'tool.completed',
      );
      expect(
        of('tool.complete', {'tool_name': 'x', 'is_error': true}).single.type,
        'tool.failed',
      );
      expect(of('message.delta', {'text': ''}), isEmpty);
    });
  });

  group('ChatController over the bridge', () {
    late LocalStore store;
    late FakeRepo repo;
    late FakeBridge bridge;
    late GatewayWs ws;
    late WsOutbox outbox;
    late WsRouter router;
    late ChatController c;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      store = LocalStore(await SharedPreferences.getInstance());
      repo = FakeRepo();
      bridge = FakeBridge();
      ws = newWs(bridge);
      outbox = WsOutbox(ws, MapPersistence());
      router = newRouter(ws, outbox);
      c = ChatController(
        repo,
        store,
        sid,
        serverUrl: url,
        wait: (_) => Future<void>.delayed(const Duration(milliseconds: 1)),
        connectivity: () => ConnectivityHint.unknown,
        wsRouter: router,
      );
      addTearDown(() {
        c.dispose();
        router.dispose();
        repo.close();
      });
    });

    Future<void> attachUp() async {
      c.attachSessionSource('discord');
      await until(() => ws.connected, reason: 'link up');
    }

    test('an allowlisted send goes over WS, never over HTTP', () async {
      await attachUp();
      repo.history = const [
        Message(id: '1', role: 'user', content: 'hi'),
        Message(id: '2', role: 'assistant', content: 'pong'),
      ];
      await c.send('hi');
      await until(() => !c.busy, reason: 'turn settled');
      expect(repo.httpSends, 0);
      expect(bridge.resumes, [sid], reason: 'resume precedes the submit');
      expect(bridge.userRows, ['hi']);
      expect(outbox.entries, isEmpty);
      expect(c.sendOutcome, SendOutcome.accepted);
      expect(c.messages.last.content, 'pong');
    });

    test('an api_server session stays on HTTP, zero WS traffic', () async {
      c.attachSessionSource('api_server');
      unawaited(c.send('hi'));
      await until(() => repo.httpSends == 1, reason: 'HTTP route');
      expect(bridge.dials, 0);
      expect(outbox.entries, isEmpty);
    });

    test('a session the page never named stays on HTTP', () async {
      unawaited(c.send('hi'));
      await until(() => repo.httpSends == 1, reason: 'HTTP route');
      expect(bridge.dials, 0);
    });

    test('bridge down: queued notice, then delivered in order', () async {
      bridge.up = false;
      c.attachSessionSource('discord');
      await c.send('one', draft: 'one');
      await c.send('two', draft: 'two');
      expect(repo.httpSends, 0);
      expect(c.busy, isFalse);
      expect(c.error, isNull);
      expect(c.sendOutcome, SendOutcome.accepted);
      expect((c.wsNotice! as UiLocal).key, MessageKey.chatWsQueued);
      expect(c.wsQueuedTexts, ['one', 'two']);

      bridge.up = true;
      await until(() => bridge.userRows.length == 2, reason: 'flush');
      expect(bridge.userRows, ['one', 'two']);
      await until(() => c.wsNotice == null, reason: 'notice clears');
      expect(c.wsQueuedTexts, isEmpty);
    });

    test('a new send never overtakes one still waiting', () async {
      await attachUp();
      await outbox.enqueue(sid, 'older');
      await c.send('newer');
      await until(() => bridge.userRows.length == 2, reason: 'both landed');
      expect(bridge.userRows, ['older', 'newer']);
      await until(() => outbox.entries.isEmpty, reason: 'drained');
    });

    test('the link dying under a live submit parks it, same key', () async {
      await attachUp();
      bridge.dropAfterNextSubmit = true;
      await store.saveDraft(url, sid, 'parked');
      await c.send('parked', draft: 'parked');
      await until(() => !c.busy, reason: 'turn retired');
      expect(c.error, isNull, reason: 'no failure card for a queued send');
      expect(store.draft(url, sid), '');
      expect(store.loadPending(url, sid), isNull);
      expect(store.listAttempts(url, sid), isEmpty);

      await until(() => outbox.entries.isEmpty, reason: 'flushed');
      expect(bridge.submissionIds.length, 2);
      expect(bridge.submissionIds[0], bridge.submissionIds[1]);
      expect(bridge.userRows, ['parked'], reason: 'owner dedupes the key');
    });

    test(
      'the link dying mid-turn reconciles from history, no failure',
      () async {
        await attachUp();
        bridge.autoTurn = false;
        repo.history = const [Message(id: '1', role: 'user', content: 'hi')];
        unawaited(c.send('hi'));
        await until(() => c.canControl, reason: 'turn admitted');
        expect(bridge.userRows, ['hi']);

        bridge.drop();
        repo.history = const [
          Message(id: '1', role: 'user', content: 'hi'),
          Message(id: '2', role: 'assistant', content: 'pong'),
        ];
        await until(() => !c.busy, reason: 'recovered');
        expect(c.messages.last.content, 'pong');
        expect(c.failedCard, isNull);
        expect(c.sendOutcome, SendOutcome.accepted);
        expect(outbox.entries, isEmpty, reason: 'admitted, never resent');
        await until(() => ws.connected, reason: 'link back');
        expect(bridge.submissionIds.length, 1);
        expect(repo.httpSends, 0);
      },
    );

    test('a bridge refusal says not enabled and keeps the draft', () async {
      await attachUp();
      bridge.refuseSubmit = 'session_not_allowlisted';
      await store.saveDraft(url, sid, 'nope');
      await c.send('nope', draft: 'nope');
      await until(() => !c.busy, reason: 'refusal settled');
      expect(c.sendOutcome, SendOutcome.rejected);
      expect(store.draft(url, sid), 'nope');
      expect(outbox.entries, isEmpty);
      final shown = c.error as UiLocal;
      expect(shown.key, MessageKey.chatStateM023);
      expect(
        (shown.args['error']! as UiLocal).key,
        MessageKey.chatWsNotEnabled,
      );
    });

    test('steer names the generation; no HTTP steer', () async {
      await attachUp();
      bridge.autoTurn = false;
      unawaited(c.send('hi'));
      await until(() => c.canControl, reason: 'turn admitted');
      await c.steer('turn left');
      expect(bridge.steers.single['text'], 'turn left');
      expect(bridge.steers.single['execution_generation'], 7);
      expect(c.error, isNull);
      bridge.event('message.complete', {'text': 'ok', 'status': 'complete'});
      await until(() => !c.busy, reason: 'turn settled');
    });

    test('steer rejected and undelivered goes in as a submit', () async {
      await attachUp();
      bridge
        ..autoTurn = false
        ..steerAnswer = const {'status': 'rejected', 'delivered': false};
      unawaited(c.send('hi'));
      await until(() => c.canControl, reason: 'turn admitted');
      await c.steer('turn left');
      await until(
        () => bridge.userRows.length == 2,
        reason: 'steer resubmitted',
      );
      expect(bridge.userRows, ['hi', 'turn left']);
      bridge.event('message.complete', {'text': 'ok', 'status': 'complete'});
      await until(() => !c.busy, reason: 'turn settled');
    });

    test('stop interrupts the session, the terminal ends the turn', () async {
      await attachUp();
      bridge.autoTurn = false;
      unawaited(c.send('hi'));
      await until(() => c.canControl, reason: 'turn admitted');
      final stopped = await c.stop();
      expect(stopped.kind, StopResultKind.serverStopRequested);
      expect(bridge.interrupts.single['execution_generation'], 7);
      bridge.event('message.complete', {'text': '', 'status': 'interrupted'});
      await until(() => !c.busy, reason: 'turn settled');
    });
  });
}
