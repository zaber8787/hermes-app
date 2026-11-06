import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/data/gateway_ws.dart';
import 'package:hermes_app/data/ws_outbox.dart';
import 'package:hermes_app/data/ws_route.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/platform/connectivity_hint.dart';
import 'package:hermes_app/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/localized_app.dart';

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

  /// What `session.resume` reports about the owner right now.
  bool resumeRunning = false;
  List<Json> resumePending = const [];
  String? refuseResume;

  /// TASK-RUNLIVENESS: the first N resumes go unanswered, the way a lost or
  /// timed-out answer looks to the page.
  int loseResumes = 0;

  /// `session.liveness` asks seen, and the one row the owner's live list holds
  /// (null: no row, so every poll says `listed: false`). Never mirrors
  /// [resumeRunning]: a test that only works because the poll answers needs the
  /// two to disagree at least once.
  int lists = 0;
  String? liveStatus;
  bool livenessMissing = false;
  String? refuseLiveness;

  /// The bridge's own replay of a resume (wsbridge.py `replay`).
  void replayResume(String session) {
    socket?.push({
      'jsonrpc': '2.0',
      'method': 'bridge.resumed',
      'params': {
        'session_id': session,
        'result': {
          'session_id': session,
          'messages': const [],
          'running': resumeRunning,
          'execution_generation': generation,
          'replay_epoch': 'e1',
          'last_sequence': 0,
          'pending': resumePending,
        },
      },
    });
  }

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
    void err(String reason, [Json data = const {}, int code = 4001]) => s.push({
      'id': id,
      'error': {
        'code': code,
        'message': reason,
        'data': {'reason': reason, ...data},
      },
    });
    switch (method) {
      case 'session.resume':
        resumes.add(params['session_id'] as String);
        if (loseResumes > 0) {
          loseResumes--; // the answer is simply never sent: a lost one
          return;
        }
        if (refuseResume != null) {
          err(refuseResume!);
          return;
        }
        s.resumed.add(params['session_id'] as String);
        ok({
          'session_id': params['session_id'],
          'messages': const [],
          'running': resumeRunning,
          'execution_generation': generation,
          'replay_epoch': 'e1',
          'last_sequence': 0,
          'pending': resumePending,
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
      case 'session.liveness':
        lists++;
        if (livenessMissing) {
          err('method_not_found', const {}, -32601);
        } else if (refuseLiveness != null) {
          err(refuseLiveness!);
        } else {
          ok({
            'session_id': params['session_id'],
            'listed': liveStatus != null,
            'status': liveStatus,
          });
        }
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

GatewayWs newWs(
  FakeBridge bridge, {
  Duration callTimeout = const Duration(seconds: 30),
}) => GatewayWs(
  url: Uri.parse('ws://test.invalid/bridge/api/bridge/ws'),
  apiKey: 'test-only',
  connector: bridge.connect,
  callTimeout: callTimeout,
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

  group('TASK-WSAUTO: the server mark routes, no setup', () {
    const foreignRow = {
      'id': sid,
      'title': 'from discord',
      'source': 'discord',
      'started_at': 1.0,
      'foreign_source': true,
      'thread_id': '1544350912389189704',
    };

    test('every Session copy keeps the mark; only true sets it', () {
      final s = Session.fromJson(foreignRow);
      expect(s.foreignSource, isTrue);
      expect(s.withActivity(2).foreignSource, isTrue);
      expect(s.withTitle('x').foreignSource, isTrue);
      expect(s.withHidden(true).foreignSource, isTrue);
      expect(s.withPinned(true).foreignSource, isTrue);
      expect(
        Session.fromJson(const {'id': 'a', 'source': 'discord'}).foreignSource,
        isFalse,
        reason: 'a server without the field stays on HTTP',
      );
    });

    test('the mark alone routes; a threadless source needs nothing else', () {
      final bridge = FakeBridge();
      final ws = newWs(bridge);
      final router = WsRouter(
        ws: ws,
        outbox: WsOutbox(ws, MapPersistence()),
        supported: true,
      );
      addTearDown(router.dispose);
      expect(router.routes('cron-1', 'cron', foreignSource: true), isTrue);
      expect(router.routes('cron-1', 'cron'), isFalse);
      expect(router.routes(sid, 'api_server'), isFalse);
      expect(
        WsRouter.disabled().routes(sid, 'x', foreignSource: true),
        isFalse,
      );
    });

    test('a fresh install builds a live router and dials nothing', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      final bridge = FakeBridge();
      final router = buildWsRouter(
        store,
        url,
        'test-only',
        connector: bridge.connect,
        supported: true,
      );
      addTearDown(router.dispose);
      expect(router.routes(sid, 'discord', foreignSource: true), isTrue);
      expect(router.routes(sid, 'api_server'), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(bridge.dials, 0, reason: 'only a routed session opens the link');
    });

    test('an upgrade keeps its saved allowlist in the union', () async {
      SharedPreferences.setMockInitialValues({
        'ws.direct': jsonEncode([
          {'thread': 'thread-1', 'session': sid},
        ]),
      });
      final store = LocalStore(await SharedPreferences.getInstance());
      final router = buildWsRouter(
        store,
        url,
        'test-only',
        connector: FakeBridge().connect,
        supported: true,
      );
      addTearDown(router.dispose);
      expect(router.routes(sid, 'discord'), isTrue);
      expect(router.routes('other', 'discord', foreignSource: true), isTrue);
      expect(router.routes('other', 'discord'), isFalse);
      expect(router.routes(sid, 'api_server'), isFalse);
    });

    test('a platform without the bridge stays disabled', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      final router = buildWsRouter(store, url, 'test-only', supported: false);
      expect(router.routes(sid, 'discord', foreignSource: true), isFalse);
    });

    group('a list row opened in the real page', () {
      late FakeBridge bridge;
      late FakeRepo repo;
      late WsRouter router;
      late ProviderContainer container;

      setUp(() async {
        SharedPreferences.setMockInitialValues({});
        final store = LocalStore(await SharedPreferences.getInstance());
        bridge = FakeBridge();
        repo = FakeRepo();
        final ws = newWs(bridge);
        router = WsRouter(
          ws: ws,
          outbox: WsOutbox(ws, MapPersistence()),
          supported: true,
        );
        container = ProviderContainer(
          overrides: [
            localStoreProvider.overrideWithValue(store),
            initialSettingsProvider.overrideWithValue(
              const AppSettings(url: url, key: 'fake'),
            ),
            repositoryProvider.overrideWithValue(repo),
            skillsProvider.overrideWith((ref) async => []),
            wsRouterProvider.overrideWithValue(router),
          ],
        );
      });
      tearDown(() {
        container.dispose();
        router.dispose();
        repo.close();
      });

      Future<void> settle(WidgetTester tester) async {
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump();
        }
      }

      Future<void> openAndSend(WidgetTester tester, Json row) async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: localizedWrap(
              ChatPage(session: Session.fromJson(row)),
              locale: AppLocale.zhHant,
            ),
          ),
        );
        await settle(tester);
      }

      Future<void> send(WidgetTester tester, String text) async {
        await tester.enterText(find.byType(TextField), text);
        await tester.pump();
        await tester.tap(find.byIcon(Icons.arrow_upward));
        await settle(tester);
      }

      testWidgets('foreign_source: the link opens and the send goes over WS', (
        tester,
      ) async {
        repo.history = const [
          Message(id: '1', role: 'user', content: 'hi'),
          Message(id: '2', role: 'assistant', content: 'pong'),
        ];
        await openAndSend(tester, foreignRow);
        expect(bridge.dials, 1, reason: 'opening the page opens the link');
        await send(tester, 'hi');
        expect(bridge.userRows, ['hi']);
        expect(repo.httpSends, 0);
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
      });

      testWidgets(
        'a turn already running shows in progress and can be stopped',
        (tester) async {
          bridge.resumeRunning = true;
          await openAndSend(tester, foreignRow);
          expect(bridge.resumes, [sid], reason: 'opening asks the owner');
          expect(find.text('進行中'), findsOneWidget);
          final stop = find.widgetWithIcon(
            TextButton,
            Icons.stop_circle_outlined,
          );
          expect(tester.widget<TextButton>(stop).onPressed, isNotNull);

          await tester.tap(stop);
          await settle(tester);
          expect(bridge.interrupts, hasLength(1));

          bridge.event('message.complete', {
            'text': '',
            'status': 'interrupted',
          }, admission: 'discord-adm');
          await settle(tester);
          expect(find.text('進行中'), findsNothing);
          await tester.pumpWidget(const SizedBox());
          await settle(tester);
        },
      );

      testWidgets('no mark: an api_server row stays on HTTP, zero WS', (
        tester,
      ) async {
        await openAndSend(tester, const {
          'id': sid,
          'title': 'mine',
          'source': 'api_server',
          'started_at': 1.0,
        });
        await send(tester, 'hi');
        expect(repo.httpSends, 1);
        expect(bridge.dials, 0);
        await tester.pumpWidget(const SizedBox());
        // The HTTP turn never ends here: its controller holds live timers.
        container.dispose();
        await tester.pump(const Duration(minutes: 2));
      });
    });
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

    test(
      'overlapping resumes share one request, then the slot frees',
      () async {
        final bridge = FakeBridge();
        final ws = newWs(bridge);
        addTearDown(ws.dispose);
        ws.start();
        await until(() => ws.connected);

        final first = ws.resume(sid), second = ws.ensureResumed(sid);
        expect((await first).sessionId, (await second).sessionId);
        expect(bridge.resumes, [
          sid,
        ], reason: 'the answer is the whole history');

        await ws.resume(sid);
        expect(bridge.resumes, [
          sid,
          sid,
        ], reason: 'a later ask is a fresh one');

        bridge.refuseResume = 'session_superseded';
        await expectLater(ws.resume(sid), throwsA(isA<GatewayRpcError>()));
        bridge.refuseResume = null;
        await ws.resume(sid);
        expect(bridge.resumes, hasLength(4), reason: 'a refusal frees it too');
      },
    );

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

    // i18n-exempt: matching-rule fixtures (protocol), not UI text.
    const prefixed = {
      '製作 Ch5': '[zaber] 製作 Ch5',
      '[PUBWSTEST] ok': '[zaber] [PUBWSTEST] ok',
      '[附件: x]': '[zaber] [附件: x]',
    };
    for (final MapEntry(key: typed, value: row) in prefixed.entries) {
      test('the prefixed row "$row" retires the pending bubble', () async {
        await attachUp();
        bridge.autoTurn = false;
        unawaited(c.send(typed));
        await until(() => c.canControl, reason: 'turn admitted');
        expect(c.turnIsAttemptBacked, isTrue, reason: 'the WS route');
        expect(c.pendingBubbleText, typed);

        repo.history = [Message(id: '67541', role: 'user', content: row)];
        await c.reconcileForeground();
        expect(c.pendingDelivered, isTrue);
        expect(c.pendingBubbleText, isNull);
        expect(c.messages.where((m) => m.isUserTurn), hasLength(1));

        bridge.event('message.complete', {'text': 'ok', 'status': 'complete'});
        await until(() => !c.busy, reason: 'turn settled');
      });
    }

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

    // TASK-RUNSTATE: the owner already runs a turn this page never sent (a
    // Discord message, or this page's own turn before a reload).
    group('a turn the page did not send', () {
      const foreign = 'discord-adm';

      ChatController reopen({
        DateTime Function()? now,
        Duration? poll,
        bool noPoll = false,
        List<Duration>? retry,
        Duration? gap,
      }) {
        final next = ChatController(
          repo,
          store,
          sid,
          serverUrl: url,
          now: now,
          wait: (_) => Future<void>.delayed(const Duration(milliseconds: 1)),
          watchInterval: const Duration(milliseconds: 5),
          connectivity: () => ConnectivityHint.unknown,
          wsRouter: router,
          wsOwnerPollInterval: noPoll ? null : (poll ?? const Duration(seconds: 10)),
          wsOwnerRetryDelays: retry ?? const [
            Duration(seconds: 2),
            Duration(seconds: 5),
            Duration(seconds: 10),
            Duration(seconds: 30),
            Duration(seconds: 30),
            Duration(seconds: 30),
            Duration(minutes: 5),
          ],
          wsOwnerConfirmGap: gap ?? const Duration(minutes: 2),
        );
        addTearDown(next.dispose);
        return next;
      }

      /// A controller on its own link, with the RUNLIVENESS seams at test
      /// speed: a 5 ms poll unless `noPoll`, millisecond retry steps, and an
      /// explicit confirm gap — every default a written number (EGM M2/M3),
      /// because the production ladder is longer than `until`'s patience.
      /// The link the last seamed controller opened: a test that must watch a
      /// frame land subscribes here before the frame is sent.
      late GatewayWs lastSeamedWs;

      ChatController seamed({
        bool noPoll = false,
        Duration poll = const Duration(milliseconds: 5),
        List<Duration>? retry,
        Duration gap = const Duration(milliseconds: 1),
        Duration callTimeout = const Duration(seconds: 30),
      }) {
        final ws2 = newWs(bridge, callTimeout: callTimeout);
        lastSeamedWs = ws2; // so a test can subscribe before a frame lands
        final router2 = WsRouter(
          ws: ws2,
          outbox: WsOutbox(ws2, MapPersistence()),
          allow: const [WsDirectEntry('thread-1', sid)],
          supported: true,
        );
        final next = ChatController(
          repo,
          store,
          sid,
          serverUrl: url,
          wait: (_) => Future<void>.delayed(const Duration(milliseconds: 1)),
          watchInterval: const Duration(milliseconds: 5),
          connectivity: () => ConnectivityHint.unknown,
          wsRouter: router2,
          wsOwnerPollInterval: noPoll ? null : poll,
          wsOwnerRetryDelays: retry ?? const [
            Duration(milliseconds: 1),
            Duration(milliseconds: 1),
            Duration(milliseconds: 1),
            Duration(milliseconds: 1),
          ],
          wsOwnerConfirmGap: gap,
        );
        addTearDown(() {
          next.dispose();
          router2.dispose();
        });
        return next;
      }

      Future<void> up(ChatController c2) async {
        c2.attachSessionSource('discord');
        await until(() => bridge.socket != null, reason: 'seamed link up');
      }

      group('RUNLIVENESS', () {
        // T1: B1's core claim, with the poll switched off so B2 cannot fake-green it.
        test('first resume answer lost', () async {
          bridge
            ..loseResumes = 1
            ..resumeRunning = true;
          final c2 = seamed(
            noPoll: true,
            callTimeout: const Duration(milliseconds: 20),
          );
          await up(c2);
          await until(() => c2.wsRemoteRunning, reason: 'the second ask answered');
          expect(bridge.resumes.length, greaterThanOrEqualTo(2));
          expect(bridge.lists, 0, reason: 'the poll was off: the retry alone lit it');
        });

        // T2: the completion frame that is NOT a turn (EGM fact 6's shape) may
        // not strand the flag down while the owner runs: the poll relights it.
        test('owner running survives a completion frame', () async {
          bridge
            ..resumeRunning = true
            ..liveStatus = 'working';
          final c2 = seamed(poll: const Duration(milliseconds: 20));
          final completed = lastSeamedWs.events.firstWhere(
            (e) => e.type == 'message.complete',
          );
          await up(c2);
          await until(() => c2.wsRemoteRunning, reason: 'running shown');
          final base = bridge.lists;
          bridge.event('message.complete', {
            'text': '',
            'content': '',
            'admission_id': 'adm-x',
            'outcome': 'cancelled',
          }, admission: foreign);
          await completed; // the frame must reach the controller before asserting
          await until(
            () => bridge.lists > base && c2.wsRemoteRunning,
            reason: 'the next poll says working again',
          );
        });

        // T3: an idle page pays polls, not resumes.
        test('the poll carries an idle page', () async {
          final c2 = seamed();
          await up(c2);
          await until(() => bridge.lists >= 5, reason: 'the poll runs on its own');
          expect(bridge.resumes, [sid], reason: 'one resume, never a growing one');
        });

        // T4 (guard, naturally green): an unrouted session sends nothing.
        test('unrouted session sends nothing', () async {
          c.attachSessionSource('api_server');
          unawaited(c.send('hi').catchError((_) {}));
          await until(() => repo.httpSends == 1, reason: 'HTTP route');
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(bridge.lists, 0);
          expect(bridge.dials, 0);
        });

        // T5: the poll raises on working and lowers on idle (pending 0).
        test('lost completion frame, idle poll lowers', () async {
          bridge.liveStatus = 'working';
          final c2 = seamed();
          await up(c2);
          await until(
            () => c2.wsRemoteRunning && bridge.lists > 0,
            reason: 'the poll says working',
          );
          bridge.liveStatus = 'idle';
          await until(
            () => !c2.wsRemoteRunning && bridge.lists > 0,
            reason: 'an idle poll with pending 0 lowers',
          );
        });

        // T6: a turn of our own outranks the list (set working only after the
        // turn is admitted, so the raise cannot come before live exists).
        test('own live turn ignores the poll', () async {
          bridge.autoTurn = false;
          final c2 = seamed();
          await up(c2);
          unawaited(c2.send('hi'));
          await until(() => c2.canControl, reason: 'turn admitted');
          bridge.liveStatus = 'working';
          final base = bridge.lists;
          await until(() => bridge.lists > base + 3, reason: 'polls ran');
          expect(
            c2.wsRemoteRunning,
            isFalse,
            reason: 'our own live turn is not the owner running',
          );
          bridge.event('message.complete', {'text': 'ok', 'status': 'complete'});
          await until(() => !c2.busy, reason: 'turn settled');
        });

        // T7: absence is no evidence; two absent polls change neither flag nor resumes.
        test('an absent row leaves the flag', () async {
          bridge.resumeRunning = true;
          final c2 = seamed(poll: const Duration(milliseconds: 50));
          await up(c2);
          await until(() => c2.wsRemoteRunning, reason: 'running shown');
          final base = bridge.lists;
          // One absent poll lands before the resume answer settles the flag,
          // so base+1 is at most the second absence: below the confirm line.
          await until(() => bridge.lists >= base + 1, reason: 'an absent poll');
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(c2.wsRemoteRunning, isTrue, reason: 'absence is no evidence');
          expect(bridge.resumes, [sid], reason: 'below three, no confirming ask');
        });

        // T8: the third absence asks once; the gap throttles every ask after.
        test('absent three times asks once', () async {
          bridge.resumeRunning = true;
          final c2 = seamed(
            poll: const Duration(milliseconds: 10),
            gap: const Duration(minutes: 5),
          );
          await up(c2);
          await until(() => c2.wsRemoteRunning, reason: 'running shown');
          final base = bridge.lists;
          await until(
            () => bridge.lists - base >= 3,
            reason: 'three absent polls',
          );
          expect(
            bridge.resumes,
            [sid, sid],
            reason: 'absent three times asks exactly once',
          );
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(bridge.resumes, hasLength(2), reason: 'the gap throttles the rest');
        });

        // T9: idle with pending>0 never lowers directly; the confirming resume decides.
        test('idle with pending never lowers directly', () async {
          bridge
            ..resumeRunning = true
            ..resumePending = const [
              {'admission_id': foreign, 'status': 'unknown'},
            ]
            ..liveStatus = 'idle';
          final c2 = seamed(gap: const Duration(milliseconds: 1));
          await up(c2);
          await until(
            () => c2.wsRemoteRunning && bridge.lists > 0,
            reason: 'pending shows, polls ran',
          );
          expect(
            c2.wsRemoteRunning,
            isTrue,
            reason: 'idle lists an `unknown` admission, it did not end',
          );
          await until(
            () => bridge.resumes.length >= 3,
            reason: 'the polls kept confirming with the owner',
          );
          bridge.resumePending = const [];
          final base = bridge.lists;
          await until(
            () => bridge.lists > base && !c2.wsRemoteRunning,
            reason: 'idle with a pending-0 answer lowers',
          );
        });

        // T10: an old bridge quiets the poll until the next link; B1 stands alone.
        test('old bridge stops the poll till next link', () async {
          bridge.livenessMissing = true;
          final c2 = seamed(callTimeout: const Duration(milliseconds: 20));
          await up(c2);
          await until(() => bridge.lists > 0, reason: 'asked once');
          final stopped = bridge.lists;
          await Future<void>.delayed(const Duration(milliseconds: 80));
          expect(bridge.lists, stopped, reason: '-32601 quiets the poll');
          bridge
            ..loseResumes = 1
            ..resumeRunning = true;
          bridge.drop();
          await until(
            () => bridge.resumes.length >= 2,
            reason: 'the reconnect replay was asked (and lost)',
          );
          await until(
            () => c2.wsRemoteRunning,
            reason: 'B1 asks again with no poll to help',
          );
          expect(bridge.lists, stopped + 1, reason: 'one probe per link up, then quiet');
        });

        // T11: a refusal core asks to retry is not an answer.
        test('storage_unavailable is asked again', () async {
          bridge.refuseResume = 'storage_unavailable';
          final c2 = seamed(noPoll: true);
          await up(c2);
          await until(() => bridge.resumes.isNotEmpty, reason: 'the refusal landed');
          bridge.refuseResume = null;
          await until(
            () => bridge.resumes.length >= 2,
            reason: 'a retryable refusal re-enters the queue',
          );
          expect(c2.wsRemoteRunning, isFalse, reason: 'an idle answer settled it');
          expect(bridge.lists, 0);
        });

        // X3: an unavailable owner is the same kind of non-answer.
        test('upstream_unavailable is asked again', () async {
          bridge.refuseResume = 'upstream_unavailable';
          final c2 = seamed(noPoll: true);
          await up(c2);
          await until(
            () => bridge.resumes.length >= 3,
            reason: 'outcome-unknown keeps asking',
          );
          bridge.refuseResume = null;
          bridge.resumeRunning = true;
          await until(() => c2.wsRemoteRunning, reason: 'and stops when answered');
          expect(bridge.resumes.length, greaterThanOrEqualTo(4));
        });

        // X4 (guard): a definite refusal is an answer; nothing asks again.
        test('a definite refusal asks no second time', () async {
          bridge.refuseResume = 'session_superseded';
          final c2 = seamed(noPoll: true);
          await up(c2);
          await Future<void>.delayed(const Duration(milliseconds: 60));
          expect(bridge.resumes, [sid], reason: 'no retry storm behind a refusal');
        });

        // T13: an event lighting the flag does not retire the retry.
        test('events alone keep the retry going', () async {
          bridge.loseResumes = 1;
          final c2 = seamed(
            noPoll: true,
            callTimeout: const Duration(milliseconds: 20),
          );
          await up(c2);
          bridge.event('tool.start', {'tool_name': 'x'}, admission: foreign);
          await until(() => c2.wsRemoteRunning, reason: 'the event lights it');
          await until(
            () => bridge.resumes.length >= 2,
            reason: 'the lost answer is still asked again',
          );
          await Future<void>.delayed(const Duration(milliseconds: 60));
          expect(
            bridge.resumes.where((s) => s == sid).length,
            greaterThanOrEqualTo(2),
          );
          expect(bridge.resumes.length, lessThanOrEqualTo(3), reason: 'it stops on the answer');
        });

        // T14: popped pages and hidden apps send nothing at all.
        test('detach and background stop every timer', () async {
          bridge.liveStatus = 'working';
          final c2 = seamed();
          await up(c2);
          await until(() => bridge.lists > 2, reason: 'polling');
          c2.detach();
          final base = bridge.lists;
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(bridge.lists, base, reason: 'a popped page asks nothing');
          c2.attachSessionSource('discord');
          await until(() => bridge.lists > base, reason: 'a reopened page asks again');
          c2.dispose(); // its 5 ms poll would keep counting against c3's phase

          final c3 = seamed();
          await up(c3);
          await until(() => bridge.lists > base + 2, reason: 'polling again');
          final base3 = bridge.lists;
          c3.didChangeAppLifecycleState(AppLifecycleState.paused);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(bridge.lists, base3, reason: 'a hidden app asks nothing');
          c3.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await until(
            () => bridge.lists > base3,
            reason: 'back on screen the poll re-arms',
          );
        });
      });

      test(
        'resume says running: in progress, the composer stays open',
        () async {
          bridge.resumeRunning = true;
          await attachUp();
          await c.bootstrap();
          await until(() => c.displayBusy, reason: 'running shown');
          expect(bridge.resumes, [sid]);
          expect(c.busy, isFalse, reason: 'no local turn was invented');
          expect(
            c.sendBlocked,
            isFalse,
            reason: 'the owner queues a new prompt',
          );
          expect(c.canStop, isTrue);
        },
      );

      test('an earlier stop record never suppresses a live turn', () async {
        await store.saveStop(url, sid, 'old-run', 'accepted');
        bridge.resumeRunning = true;
        final next = reopen();
        expect(next.stopNoticeKind, StopNotice.previousStopRecord);
        next.attachSessionSource('discord');
        await next.bootstrap();
        await until(() => next.displayBusy, reason: 'running shown');
        expect(
          next.stopNoticeKind,
          StopNotice.previousStopRecord,
          reason: 'the banner may stay, it just does not win',
        );
      });

      test('an admission still queued counts as running', () async {
        bridge.resumePending = const [
          {'admission_id': foreign, 'status': 'unknown'},
        ];
        await attachUp();
        await until(() => c.displayBusy, reason: 'pending shown');
      });

      test('an idle owner stays idle, one resume only', () async {
        await attachUp();
        await c.bootstrap();
        await until(() => bridge.resumes.isNotEmpty, reason: 'asked');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(c.displayBusy, isFalse);
        expect(c.canStop, isFalse);
        expect(bridge.resumes, [sid]);
      });

      test('the link comes up after the page opened', () async {
        bridge
          ..up = false
          ..resumeRunning = true;
        c.attachSessionSource('discord');
        await c.bootstrap();
        expect(c.displayBusy, isFalse);
        bridge.up = true;
        await until(() => c.displayBusy, reason: 'asked once the link is up');
        expect(bridge.resumes, [sid]);
      });

      test(
        'a page reopened on a live link asks again, never the cache',
        () async {
          await attachUp();
          await until(() => bridge.resumes.length == 1, reason: 'first ask');
          await Future<void>.delayed(const Duration(milliseconds: 5));
          expect(c.displayBusy, isFalse);
          bridge.resumeRunning = true;
          c.attachSessionSource('discord');
          await until(() => c.displayBusy, reason: 'fresh answer');
          expect(bridge.resumes, [sid, sid]);
        },
      );

      test('its message.complete ends it', () async {
        bridge.resumeRunning = true;
        await attachUp();
        await until(() => c.displayBusy, reason: 'running shown');
        repo.history = const [
          Message(id: '2', role: 'assistant', content: 'x'),
        ];
        bridge.event('message.complete', {
          'text': 'x',
          'status': 'complete',
        }, admission: foreign);
        await until(() => !c.displayBusy, reason: 'back to idle');
        await until(() => c.messages.isNotEmpty, reason: 'reply loaded');
        expect(c.canStop, isFalse);
      });

      test('a turn that starts while the page sits idle shows too', () async {
        await attachUp();
        await until(() => bridge.resumes.isNotEmpty, reason: 'asked');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(c.displayBusy, isFalse);
        bridge.event('tool.start', {'tool_name': 'x'}, admission: foreign);
        await until(() => c.displayBusy, reason: 'running shown');
        bridge.event('message.complete', {
          'text': '',
          'status': 'complete',
        }, admission: foreign);
        await until(() => !c.displayBusy, reason: 'back to idle');
      });

      test('a notice outside a turn does not count as running', () async {
        await attachUp();
        await until(() => bridge.resumes.isNotEmpty, reason: 'asked');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        bridge.event('status.update', {'kind': 'goal'}, admission: foreign);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(c.displayBusy, isFalse);
      });

      test(
        'a dropped link is no evidence; the reconnect answer decides',
        () async {
          bridge.resumeRunning = true;
          await attachUp();
          await until(() => c.displayBusy, reason: 'running shown');

          bridge.up = false;
          bridge.drop();
          await until(() => !c.displayBusy, reason: 'no link, no claim');

          bridge
            ..resumeRunning = false
            ..up = true;
          await until(() => bridge.resumes.length == 2, reason: 'replayed');
          await until(() => ws.connected, reason: 'link back');
          await Future<void>.delayed(const Duration(milliseconds: 5));
          expect(c.displayBusy, isFalse, reason: 'it ended while we were away');

          bridge.drop();
          bridge.resumeRunning = true;
          await until(
            () => c.displayBusy,
            reason: 'still running after a drop',
          );
        },
      );

      test('the bridge replaying a resume updates the state', () async {
        bridge.resumeRunning = true;
        await attachUp();
        await until(() => c.displayBusy, reason: 'running shown');
        bridge
          ..resumeRunning = false
          ..replayResume(sid);
        await until(() => !c.displayBusy, reason: 'the replay says idle');
        bridge
          ..resumeRunning = true
          ..replayResume(sid);
        await until(() => c.displayBusy, reason: 'the replay says running');
      });

      test('stop interrupts the session over the link', () async {
        bridge.resumeRunning = true;
        await attachUp();
        await until(() => c.canStop, reason: 'stoppable');
        final stopped = await c.stop();
        expect(stopped.kind, StopResultKind.serverStopRequested);
        expect(bridge.interrupts.single['execution_generation'], 7);
        expect(c.displayBusy, isTrue, reason: 'the terminal ends it, not us');
        bridge.event('message.complete', {
          'text': '',
          'status': 'interrupted',
        }, admission: foreign);
        await until(() => !c.displayBusy, reason: 'terminal seen');
      });

      test('this page\'s own live turn never raises it', () async {
        await attachUp();
        bridge.autoTurn = false;
        unawaited(c.send('hi'));
        await until(() => c.canControl, reason: 'admitted');
        bridge.event('message.delta', {'text': 'po'});
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(c.wsRemoteRunning, isFalse);
        bridge.event('message.complete', {'text': 'ok', 'status': 'complete'});
        await until(() => !c.busy, reason: 'turn settled');
        expect(c.displayBusy, isFalse);
      });

      test('a send while it runs still goes in over the link', () async {
        bridge
          ..resumeRunning = true
          ..autoTurn = false;
        await attachUp();
        await until(() => c.displayBusy, reason: 'running shown');
        unawaited(c.send('next'));
        await until(() => c.canControl, reason: 'admitted');
        expect(bridge.userRows, ['next']);
        bridge.event('message.complete', {
          'text': '',
          'status': 'complete',
        }, admission: foreign);
        await until(() => !c.wsRemoteRunning, reason: 'the other one ended');
        expect(c.busy, isTrue, reason: 'our own turn is still on');
        bridge.event('message.complete', {'text': 'ok', 'status': 'complete'});
        await until(() => !c.busy, reason: 'turn settled');
        expect(c.displayBusy, isFalse);
      });

      group('a WS turn the page reloads into', () {
        // The real session's shape: every assistant row so far carries tool
        // calls, so history alone reads as "ended without a final answer".
        const midTurn = [
          Message(id: '1', role: 'user', content: 'hi'),
          Message(
            id: '2',
            role: 'assistant',
            toolCalls: [ToolCall('t1', 'terminal', '{}')],
          ),
          Message(id: '3', role: 'tool', toolCallId: 't1', content: 'ok'),
        ];

        Future<void> sendThenReload() async {
          await attachUp();
          bridge.autoTurn = false;
          unawaited(c.send('hi'));
          await until(() => c.canControl, reason: 'turn admitted');
          c.dispose();
          expect(store.loadPending(url, sid), isNotNull);
          repo.history = midTurn;
        }

        test('running: never settled as incomplete, pending kept', () async {
          await sendThenReload();
          bridge.resumeRunning = true;
          final next = reopen();
          next.attachSessionSource('discord');
          await next.bootstrap();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(next.busy, isTrue);
          expect(next.displayBusy, isTrue);
          expect(next.error, isNull);
          expect(store.loadPending(url, sid), isNotNull);

          repo.history = const [
            ...midTurn,
            Message(id: '4', role: 'assistant', content: 'done'),
          ];
          bridge.event('message.complete', {
            'text': 'done',
            'status': 'complete',
          });
          await until(() => !next.displayBusy, reason: 'settled');
          expect(next.error, isNull);
          expect(store.loadPending(url, sid), isNull);
        });

        test('no answer yet: quiet activity alone settles nothing', () async {
          await sendThenReload();
          bridge.resumeRunning = true;
          bridge.up = false;
          bridge.drop();
          await until(() => !ws.connected, reason: 'link gone');
          final next = reopen();
          next.attachSessionSource('discord');
          await next.bootstrap();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(next.busy, isTrue, reason: 'the owner has not answered');
          expect(next.error, isNull);
          expect(store.loadPending(url, sid), isNotNull);

          bridge.up = true;
          await until(() => next.wsRemoteRunning, reason: 'answer arrived');
          expect(next.busy, isTrue);
        });

        test('owner idle: the existing incomplete settle still runs', () async {
          await sendThenReload();
          final next = reopen();
          next.attachSessionSource('discord');
          await next.bootstrap();
          await until(() => !next.busy, reason: 'settled');
          expect((next.error! as UiLocal).key, MessageKey.chatTurnIncomplete);
          expect(next.displayBusy, isFalse);
        });

        test('a long turn outlives the recovery budget', () async {
          await sendThenReload();
          bridge.resumeRunning = true;
          var clock = DateTime.now();
          final next = reopen(now: () => clock);
          next.attachSessionSource('discord');
          await next.bootstrap();
          await until(() => next.wsRemoteRunning, reason: 'answer arrived');
          clock = clock.add(const Duration(minutes: 13));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(next.phase, ChatPhase.recovering);
          expect(next.error, isNull);
        });

        test('a refused resume falls back to the existing reads', () async {
          await sendThenReload();
          bridge.refuseResume = 'session_superseded';
          final next = reopen();
          next.attachSessionSource('discord');
          await next.bootstrap();
          await until(() => !next.busy, reason: 'not stuck on the owner');
          expect((next.error! as UiLocal).key, MessageKey.chatTurnIncomplete);
          expect(next.displayBusy, isFalse);
        });

        // T12 (RUNLIVENESS, lives here for sendThenReload — EGM B5): the poll
        // answers all day and never opens the settle at the bootstrap tick:
        // only the owner's resume may (`_wsOwnerAnswered`, chat_controller.dart).
        test('the poll never sets answered', () async {
          await sendThenReload();
          bridge.liveStatus = 'idle'; // M4: working would hold the gate by itself
          final base = bridge.lists;
          bridge.loseResumes = 99; // every ask after this goes unanswered (M4)
          final next = seamed(
            poll: const Duration(milliseconds: 10),
            retry: const [Duration(seconds: 5)], // B1 stays asleep: the poll alone runs
            gap: const Duration(minutes: 5),
          );
          next.attachSessionSource('discord');
          await next.bootstrap();
          await until(() => bridge.lists > base + 5, reason: 'the poll is answering');
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(next.busy, isTrue, reason: 'quiet polls prove nothing about a WS turn');
          expect(next.error, isNull, reason: 'never settled as incomplete');
          expect(store.loadPending(url, sid), isNotNull);
        });

        test(
          'stop reaches the owner instead of ending only the wait',
          () async {
            await sendThenReload();
            bridge.resumeRunning = true;
            final next = reopen();
            next.attachSessionSource('discord');
            await next.bootstrap();
            await until(() => next.wsRemoteRunning, reason: 'answer arrived');
            final stopped = await next.stop();
            expect(stopped.kind, StopResultKind.serverStopRequested);
            expect(bridge.interrupts, hasLength(1));
            expect(store.loadPending(url, sid), isNotNull);
          },
        );
      });
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
