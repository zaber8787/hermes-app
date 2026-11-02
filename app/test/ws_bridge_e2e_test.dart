import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/data/gateway_ws.dart';
import 'package:hermes_app/data/gateway_ws_socket.dart';
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

/// TASK-WSAPP acceptance, end to end: the app's own client, outbox and
/// controller against a real compat/wsbridge.py on a private port with a
/// throwaway key, onto the live gateway. It costs real agent turns, so it
/// skips unless every WSAPP_E2E_* variable is set; ids live only there.
///
///   WSAPP_E2E_PYTHON         python with the bridge's dependencies
///   WSAPP_E2E_AGENT          hermes-agent checkout (PYTHONPATH)
///   WSAPP_E2E_DB             state.db, read-only, for the messages rows
///   WSAPP_E2E_THREAD         test thread the private bridge may write to
///   WSAPP_E2E_SESSION        session of that thread
///   WSAPP_E2E_REFUSED_THREAD test thread the private bridge does NOT list
///   WSAPP_E2E_REFUSED_SESSION session of that thread
final _env = Platform.environment;
String _need(String name) => _env[name] ?? '';
const _vars = [
  'WSAPP_E2E_PYTHON',
  'WSAPP_E2E_AGENT',
  'WSAPP_E2E_DB',
  'WSAPP_E2E_THREAD',
  'WSAPP_E2E_SESSION',
  'WSAPP_E2E_REFUSED_THREAD',
  'WSAPP_E2E_REFUSED_SESSION',
];

class LocalBridge {
  LocalBridge(this.port, this.key, this.config);
  final int port;
  final String key;
  final String config;
  Process? _process;

  Uri get url => Uri.parse('ws://127.0.0.1:$port/api/bridge/ws');

  Future<void> start() async {
    final script = '${Directory.current.parent.path}/compat/wsbridge.py';
    final process = await Process.start(
      _need('WSAPP_E2E_PYTHON'),
      [script, '--config', config, '--host', '127.0.0.1', '--port', '$port'],
      environment: {
        'PYTHONPATH': _need('WSAPP_E2E_AGENT'),
        'API_SERVER_KEY': key,
      },
    );
    _process = process;
    process.stdout.drain<void>().ignore();
    process.stderr.drain<void>().ignore();
  }

  Future<void> stop() async {
    final process = _process;
    _process = null;
    if (process == null) return;
    process.kill();
    await process.exitCode;
  }
}

/// Every row of [session] whose text carries [nonce], oldest first, read
/// straight from the owner's messages table.
Future<List<String>> landed(String session, String nonce, String role) async {
  final r = await Process.run('sqlite3', [
    '-readonly',
    '-json',
    _need('WSAPP_E2E_DB'),
    "SELECT content FROM messages WHERE session_id='$session' AND role='$role' "
        "AND content LIKE '%$nonce%' ORDER BY id",
  ]);
  if (r.exitCode != 0) throw StateError('sqlite3 failed: ${r.stderr}');
  final out = (r.stdout as String).trim();
  if (out.isEmpty) return const [];
  return [for (final row in jsonDecode(out) as List) row['content'] as String];
}

class DbRepo extends HermesRepository {
  DbRepo() : super('http://e2e.invalid', 'unused');
  int httpSends = 0;

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
    return const Stream.empty();
  }

  @override
  Future<List<Message>> messages(
    String s, {
    int offset = 0,
    int limit = 200,
  }) async => const [];
}

class MapPersistence implements WsOutboxPersistence {
  String? value;
  @override
  String? read() => value;
  @override
  Future<void> write(String? v) async => value = v;
}

Future<void> until(
  bool Function() condition, {
  required String reason,
  Duration within = const Duration(minutes: 4),
}) async {
  final deadline = DateTime.now().add(within);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('never held: $reason');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<void> untilAsync(
  Future<bool> Function() condition, {
  required String reason,
  Duration within = const Duration(minutes: 4),
}) async {
  final deadline = DateTime.now().add(within);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) fail('never held: $reason');
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

void main() {
  final missing = _vars.where((v) => _need(v).isEmpty).toList();
  final skip = missing.isEmpty ? false : 'needs ${missing.join(', ')}';

  group('live bridge', skip: skip, () {
    final session = _need('WSAPP_E2E_SESSION');
    final nonce = Random.secure().nextInt(1 << 32).toRadixString(16);
    late LocalBridge bridge;
    late GatewayWs ws;
    late WsOutbox outbox;
    late WsRouter router;
    late DbRepo repo;
    late ChatController chat;
    late Directory temp;
    final seen = <String>[];

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      HttpOverrides.global = null; // the real socket, not the test mock
      temp = await Directory.systemTemp.createTemp('wsapp-e2e');
      final config = File('${temp.path}/bridge.json');
      await config.writeAsString(
        jsonEncode({
          'test_thread_ids': [_need('WSAPP_E2E_THREAD')],
        }),
      );
      final probe = await ServerSocket.bind('127.0.0.1', 0);
      final port = probe.port;
      await probe.close();
      final key = List.generate(
        32,
        (_) => Random.secure().nextInt(16).toRadixString(16),
      ).join();
      bridge = LocalBridge(port, key, config.path);
      await bridge.start();

      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      repo = DbRepo();
      ws = GatewayWs(
        url: bridge.url,
        apiKey: key,
        connector: defaultWsConnector,
      );
      ws.events.listen((e) => seen.add(e.type));
      outbox = WsOutbox(ws, MapPersistence());
      router = WsRouter(
        ws: ws,
        outbox: outbox,
        allow: [
          WsDirectEntry(_need('WSAPP_E2E_THREAD'), session),
          WsDirectEntry(
            _need('WSAPP_E2E_REFUSED_THREAD'),
            _need('WSAPP_E2E_REFUSED_SESSION'),
          ),
        ],
        supported: true,
      );
      chat = ChatController(
        repo,
        store,
        session,
        serverUrl: repo.baseUrl,
        wait: (d) => Future<void>.delayed(const Duration(milliseconds: 200)),
        connectivity: () => ConnectivityHint.unknown,
        wsRouter: router,
      );
      chat.attachSessionSource('discord');
      await until(
        () => ws.connected,
        reason: 'link to the private bridge',
        within: const Duration(seconds: 30),
      );
    });

    tearDownAll(() async {
      chat.dispose();
      router.dispose();
      repo.close();
      await bridge.stop();
      await temp.delete(recursive: true);
    });

    test(
      'a send lands as a user row and the turn settles from real events',
      timeout: const Timeout(Duration(minutes: 6)),
      () async {
        final text = '[WSAPP-E2E $nonce online] Reply with exactly: ok';
        seen.clear();
        await chat.send(text);
        await until(() => !chat.busy, reason: 'turn settled');
        expect(repo.httpSends, 0, reason: 'never the HTTP route');
        expect(chat.sendOutcome, SendOutcome.accepted);
        expect(chat.error, isNull);
        expect(outbox.entries, isEmpty);
        // The owner prefixes a shared thread's rows with the sender.
        expect(await landed(session, '$nonce online', 'user'), [
          endsWith(text),
        ]);
        expect(seen, contains('message.complete'));
        // ignore: avoid_print
        print('event types: ${seen.toSet()}');
      },
    );

    test(
      'bridge down: queued notice; bridge back: delivered in order',
      timeout: const Timeout(Duration(minutes: 8)),
      () async {
        await bridge.stop();
        await until(
          () => !ws.connected,
          reason: 'link noticed the drop',
          within: const Duration(seconds: 30),
        );
        final one = '[WSAPP-E2E $nonce queued one] Reply with exactly: ok';
        final two = '[WSAPP-E2E $nonce queued two] Reply with exactly: ok';
        await chat.send(one);
        await chat.send(two);
        expect(chat.busy, isFalse);
        expect(chat.error, isNull);
        expect((chat.wsNotice! as UiLocal).key, MessageKey.chatWsQueued);
        expect(chat.wsQueuedTexts, [one, two]);
        expect(await landed(session, '$nonce queued', 'user'), isEmpty);

        await bridge.start();
        await until(() => outbox.entries.isEmpty, reason: 'outbox drained');
        expect(chat.wsNotice, isNull);
        await untilAsync(
          () async =>
              (await landed(session, '$nonce queued', 'user')).length >= 2,
          reason: 'both rows in the messages table',
        );
        expect(await landed(session, '$nonce queued', 'user'), [
          endsWith(one),
          endsWith(two),
        ]);
        await untilAsync(
          () async =>
              (await landed(session, nonce, 'user')).length == 3 &&
              (await ws.resume(session)).running == false,
          reason: 'owner idle again',
        );
        expect(repo.httpSends, 0);
      },
    );

    test(
      'steer reaches the running turn with its generation',
      timeout: const Timeout(Duration(minutes: 6)),
      () async {
        final text =
            '[WSAPP-E2E $nonce steer] Without using any tool, write a '
            '400-word story about a lighthouse.';
        seen.clear();
        unawaited(chat.send(text));
        await until(() => chat.canControl, reason: 'turn admitted');
        await until(
          () => seen.contains('message.start'),
          reason: 'turn started',
          within: const Duration(minutes: 2),
        );
        await chat.steer('[WSAPP-E2E $nonce steered] also say: steered');
        expect(chat.error, isNull);
        await until(() => !chat.busy, reason: 'turn settled');
        expect(repo.httpSends, 0);
      },
    );

    test(
      'a session the bridge does not list is refused, not faked',
      timeout: const Timeout(Duration(minutes: 2)),
      () async {
        final refused = _need('WSAPP_E2E_REFUSED_SESSION');
        final attempt = '[WSAPP-E2E $nonce refused] must never land';
        SharedPreferences.setMockInitialValues({});
        final other = ChatController(
          repo,
          LocalStore(await SharedPreferences.getInstance()),
          refused,
          serverUrl: repo.baseUrl,
          wait: (d) => Future<void>.delayed(const Duration(milliseconds: 200)),
          connectivity: () => ConnectivityHint.unknown,
          wsRouter: router,
        );
        addTearDown(other.dispose);
        other.attachSessionSource('discord');
        await until(() => ws.connected, reason: 'link up');
        await other.send(attempt);
        await until(() => !other.busy, reason: 'refusal settled');
        expect(other.sendOutcome, SendOutcome.rejected);
        final shown = other.error as UiLocal;
        expect(
          (shown.args['error']! as UiLocal).key,
          MessageKey.chatWsNotEnabled,
        );
        expect(await landed(refused, '$nonce refused', 'user'), isEmpty);
      },
    );
  });
}
