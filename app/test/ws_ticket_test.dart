import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/data/gateway_ws.dart';
import 'package:hermes_app/data/gateway_ws_ticket.dart';
import 'package:hermes_app/data/ws_outbox.dart';
import 'package:hermes_app/data/ws_route.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/platform/connectivity_hint.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The browser's ticket route onto the bridge: mint, connect, re-mint on a
/// rejection, degrade to HTTP. A fake HTTP client answers like
/// compat/wsbridge.py `answer_ticket_request`.
const sid = 'discord-session';
const server = 'https://host.test';
const key = 'test-only-key';
final wsUrl = Uri.parse('wss://host.test/bridge/api/bridge/ws');

class SilentSocket implements WsSocket {
  final _frames = StreamController<String>();
  @override
  Stream<String> get messages => _frames.stream;
  @override
  void send(String text) {}
  @override
  Future<void> close([int code = 1000]) => _frames.close();
}

/// Scripted mint answers (status, or null for no HTTP answer at all) and
/// scripted upgrade outcomes; records every request and every socket URL.
class FakeTicketBridge {
  FakeTicketBridge({this.mints = const [], this.upgrades = const []});
  final List<int?> mints;
  final List<bool> upgrades;
  final requests = <http.Request>[];
  final opened = <Uri>[];

  late final client = MockClient((request) async {
    final index = requests.length;
    requests.add(request);
    final status = index < mints.length ? mints[index] : 200;
    if (status == null) throw http.ClientException('offline');
    if (status != 200) return http.Response('{"error":"x"}', status);
    return http.Response(
      jsonEncode({'ticket': 't${index + 1}', 'expires_in': 60}),
      200,
    );
  });

  Future<WsSocket> open(Uri url) async {
    final index = opened.length;
    opened.add(url);
    if (index < upgrades.length && !upgrades[index]) {
      throw StateError('bridge socket did not open');
    }
    return SilentSocket();
  }

  Future<WsSocket> connect(Uri url, String k) =>
      connectWithTicket(url, k, client: client, open: open);
}

class FakeRepo extends HermesRepository {
  FakeRepo() : super(server, 'fake');
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
  }) async => const [];
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ticketEndpoint', () {
    test('stays on the Serve mount, https for wss', () {
      expect(
        ticketEndpoint(wsUrl).toString(),
        'https://host.test/bridge/bridge/ticket',
      );
    });
    test('a bridge on its own port, no mount, http for ws', () {
      expect(
        ticketEndpoint(
          Uri.parse('ws://127.0.0.1:8650/api/bridge/ws'),
        ).toString(),
        'http://127.0.0.1:8650/bridge/ticket',
      );
    });
    test('a URL that is not the bridge socket has none', () {
      expect(ticketEndpoint(Uri.parse('wss://host.test/other')), isNull);
    });
  });

  group('connectWithTicket', () {
    test('mints with the bearer key, connects with the ticket only', () async {
      final b = FakeTicketBridge();
      await b.connect(wsUrl, key);
      expect(b.requests.single.method, 'POST');
      expect(
        b.requests.single.url.toString(),
        'https://host.test/bridge/bridge/ticket',
      );
      expect(b.requests.single.headers['Authorization'], 'Bearer $key');
      expect(
        b.opened.single.toString(),
        'wss://host.test/bridge/api/bridge/ws?ticket=t1',
      );
      expect(b.opened.single.toString(), isNot(contains(key)));
    });

    for (final status in [401, 403]) {
      test('a $status mint is minted again once', () async {
        final b = FakeTicketBridge(mints: [status]);
        await b.connect(wsUrl, key);
        expect(b.requests, hasLength(2));
        expect(b.opened.single.queryParameters['ticket'], 't2');
      });
    }

    test('an upgrade that did not open re-mints a fresh ticket', () async {
      final b = FakeTicketBridge(upgrades: [false]);
      await b.connect(wsUrl, key);
      expect(b.requests, hasLength(2));
      expect(b.opened.map((u) => u.queryParameters['ticket']), ['t1', 't2']);
    });

    test('a second rejection gives up: two mints, then refused', () async {
      final b = FakeTicketBridge(mints: [401, 401]);
      await expectLater(
        b.connect(wsUrl, key),
        throwsA(
          isA<WsBridgeRefused>().having((e) => e.transient, 'transient', false),
        ),
      );
      expect(b.requests, hasLength(2));
      expect(b.opened, isEmpty);

      final c = FakeTicketBridge(upgrades: [false, false]);
      await expectLater(c.connect(wsUrl, key), throwsA(isA<WsBridgeRefused>()));
      expect(c.requests, hasLength(2));
      expect(c.opened, hasLength(2));
    });

    test('a bridge without the endpoint is refused at once', () async {
      final b = FakeTicketBridge(mints: [502]);
      await expectLater(
        b.connect(wsUrl, key),
        throwsA(
          isA<WsBridgeRefused>().having((e) => e.transient, 'transient', false),
        ),
      );
      expect(b.requests, hasLength(1));
    });

    test('no HTTP answer at all is transient', () async {
      final b = FakeTicketBridge(mints: [null]);
      await expectLater(
        b.connect(wsUrl, key),
        throwsA(
          isA<WsBridgeRefused>().having((e) => e.transient, 'transient', true),
        ),
      );
    });
  });

  group('degrading', () {
    late LocalStore store;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      store = LocalStore(await SharedPreferences.getInstance());
    });

    GatewayWs newWs(WsConnector connector) => GatewayWs(
      url: wsUrl,
      apiKey: key,
      connector: connector,
      backoff: const [Duration(milliseconds: 1)],
      wait: (_) => Future<void>.delayed(const Duration(milliseconds: 1)),
    );

    test('a refused first dial stops dialing and stops routing', () async {
      var dials = 0;
      final ws = newWs((_, _) async {
        dials++;
        throw const WsBridgeRefused('ticket_rejected');
      });
      final router = WsRouter(
        ws: ws,
        outbox: WsOutbox(ws, _Memory()),
        supported: true,
      );
      addTearDown(router.dispose);
      expect(router.routes(sid, 'discord', foreignSource: true), isTrue);
      router.start();
      await until(() => ws.degraded);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(dials, 1);
      expect(router.routes(sid, 'discord', foreignSource: true), isFalse);
    });

    test('a link that worked survives transient failures', () async {
      var dials = 0;
      SilentSocket? first;
      final ws = newWs((_, _) async {
        if (++dials == 1) return first = SilentSocket();
        throw const WsBridgeRefused('ticket_unreachable', transient: true);
      });
      addTearDown(ws.dispose);
      ws.start();
      await until(() => ws.connected);
      await first!.close();
      await until(() => dials > 10, reason: 'keeps dialing');
      expect(ws.degraded, isFalse);
    });

    test(
      'a link that worked degrades after a full backoff of refusals',
      () async {
        var dials = 0;
        SilentSocket? first;
        final ws = GatewayWs(
          url: wsUrl,
          apiKey: key,
          connector: (_, _) async {
            if (++dials == 1) return first = SilentSocket();
            throw const WsBridgeRefused('ticket_rejected');
          },
          backoff: const [Duration(milliseconds: 1), Duration(milliseconds: 1)],
          wait: (_) => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
        addTearDown(ws.dispose);
        ws.start();
        await until(() => ws.connected);
        await first!.close();
        await until(() => ws.degraded);
        // The drop's own backoff slept once (attempt 0 -> 1), then refusals at
        // attempts 1 and 2: the second one spends the list of two.
        expect(dials, 3);
      },
    );

    test(
      'a queued text returns to its draft and the send goes over HTTP',
      () async {
        final refuse = Completer<void>();
        final router = buildWsRouter(
          store,
          server,
          key,
          supported: true,
          connector: (_, _) async {
            await refuse.future;
            throw const WsBridgeRefused('ticket_rejected');
          },
        );
        final repo = FakeRepo();
        final c = ChatController(
          repo,
          store,
          sid,
          serverUrl: server,
          wait: (_) => Future<void>.delayed(const Duration(milliseconds: 1)),
          connectivity: () => ConnectivityHint.unknown,
          wsRouter: router,
        );
        addTearDown(() {
          c.dispose();
          router.dispose();
          repo.close();
        });

        c.attachSessionSource('discord', foreignSource: true);
        await c.send('typed while dialing');
        expect(repo.httpSends, 0, reason: 'link still dialing: it queues');
        expect(router.outbox!.entries, hasLength(1));

        refuse.complete();
        await until(() => router.ws!.degraded);
        await until(() => router.outbox!.entries.isEmpty);
        await until(() => store.draft(server, sid) == 'typed while dialing');
        expect(c.wsNotice, isNotNull, reason: 'the user is told');

        unawaited(c.send('next one'));
        await until(() => repo.httpSends == 1, reason: 'HTTP route');
      },
    );

    test(
      'the header connector path never degrades on a plain failure',
      () async {
        var dials = 0;
        final ws = newWs((_, _) async {
          dials++;
          throw StateError('connection refused');
        });
        addTearDown(ws.dispose);
        ws.start();
        await until(() => dials > 5);
        expect(ws.degraded, isFalse);
      },
    );
  });
}

class _Memory implements WsOutboxPersistence {
  String? value;
  @override
  String? read() => value;
  @override
  Future<void> write(String? v) async => value = v;
}
