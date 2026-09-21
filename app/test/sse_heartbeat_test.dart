import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/settings/local_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test('keepalive comments become heartbeat events', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.set('Content-Type', 'text/event-stream');
      request.response.write(': keepalive\n\n');
      request.response.write('event: run.started\ndata: {"run_id":"r1"}\n\n');
      request.response.write(': keepalive\n\n');
      request.response.write('event: done\ndata: {}\n\n');
      await request.response.close();
    });
    final repo = HermesRepository('http://127.0.0.1:${server.port}', 'k');
    try {
      final types = <String>[];
      await for (final e in repo.chat('s', 'hi')) {
        types.add(e.type);
        if (e.type == 'done') break;
      }
      expect(
        types.where((t) => t == 'heartbeat').length,
        greaterThanOrEqualTo(2),
      );
    } finally {
      repo.close();
      await server.close(force: true);
    }
  });

  test('stream with interleaved keepalives completes without recover', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path.endsWith('/messages')) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'id': 'm1', 'role': 'user', 'content': 'hi', 'timestamp': 1},
              {'id': 'm2', 'role': 'assistant', 'content': '好', 'timestamp': 2},
            ],
          }),
        );
        await request.response.close();
        return;
      }
      request.response.headers.set('Content-Type', 'text/event-stream');
      request.response.write(
        'event: run.started\ndata: {"run_id":"r1","session_id":"s"}\n\n',
      );
      // 4s of pure keepalive silence: a heartbeat-blind client would sit dark
      // here; the run stays alive the whole time.
      await Future.delayed(const Duration(seconds: 4));
      request.response.write(': keepalive\n\n');
      await Future.delayed(const Duration(seconds: 4));
      request.response.write(': keepalive\n\n');
      request.response.write(
        'event: run.completed\ndata: {"run_id":"r1","session_id":"s","messages":[]}\n\n',
      );
      await request.response.close();
    });
    final repo = HermesRepository('http://127.0.0.1:${server.port}', 'k');
    final c = ChatController(repo, store, 's');
    try {
      await c.send('hi');
      expect(c.phase, ChatPhase.idle);
      expect(c.error, isNull);
    } finally {
      repo.close();
      await server.close(force: true);
      c.dispose();
    }
  }, timeout: const Timeout(Duration(seconds: 40)));
}
