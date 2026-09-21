// Explicit opt-in live smoke. Creates only a temporary session and deletes it.
// API key is read at runtime and NEVER printed or passed on a command line.
import 'dart:convert';
import 'dart:io';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/models/message.dart';
import 'runtime_config.dart';

Future<void> main() async {
  final cfg = RuntimeConfig();
  final key = cfg.apiKey();
  final url = cfg.liveBaseUrl();
  final repo = HermesRepository(url, key);
  final setup = HttpClient();
  String? sid;
  Future<Json> fixtureRequest(
    String method,
    String path, {
    Json? body,
    int expected = 200,
  }) async {
    final req = await setup.openUrl(method, Uri.parse('$url$path'));
    req.headers.set('Authorization', 'Bearer $key');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final resp = await req.close().timeout(const Duration(seconds: 610));
    final text = await utf8.decoder.bind(resp).join();
    stdout.writeln('$method $path -> ${resp.statusCode}');
    if (resp.statusCode != expected) throw StateError('Unexpected HTTP status');
    return Map<String, dynamic>.from(jsonDecode(text));
  }

  try {
    await repo.checkCapabilities();
    stdout.writeln('GET /v1/capabilities: compatible');
    stdout.writeln('GET /health: ${await repo.health()}');
    final sessions = await repo.sessions();
    stdout.writeln(
      'GET /api/sessions (all pages): ${sessions.length} unique sessions',
    );
    final skills = await repo.skills();
    stdout.writeln('GET /v1/skills: ${skills.length} entries');
    final nonempty = sessions.firstWhere((s) => s.count > 0);
    final messages = await repo.messages(nonempty.id);
    stdout.writeln(
      'GET messages?order=latest&limit=200: ${messages.length} rows; ${projectMessages(messages).length} display entries',
    );
    final created = await fixtureRequest(
      'POST',
      '/api/sessions',
      body: {'title': 'P1 temporary Dart smoke'},
      expected: 201,
    );
    sid = created['session']['id'] as String;
    final types = <String, int>{};
    var completed = false;
    await for (final event in repo.chat(
      sid,
      '這是串流 API 驗證。請用 terminal 執行 printf SMOKE_OK，最後只回覆 SMOKE_OK。',
    )) {
      types.update(event.type, (n) => n + 1, ifAbsent: () => 1);
      if (event.type == 'run.started') {
        if (event.json['session_id'] != sid || event.json['run_id'] == null) {
          throw StateError('Missing run mapping');
        }
        stdout.writeln('run.started: valid session_id/run_id binding');
      }
      if (event.type == 'assistant.completed') {
        stdout.writeln('assistant.completed received');
      }
      if (event.type == 'run.completed') {
        completed = true;
        stdout.writeln(
          'run.completed: ${(event.json['messages'] as List).length} transcript rows',
        );
      }
    }
    if (!completed) throw StateError('No run.completed');
    stdout.writeln('SSE event counts: ${jsonEncode(types)}');
    stdout.writeln(
      'Persisted history: ${(await repo.messages(sid)).length} rows',
    );
    stdout.writeln('LIVE SMOKE PASSED');
  } finally {
    if (sid != null) {
      await fixtureRequest('DELETE', '/api/sessions/$sid');
      await fixtureRequest('GET', '/api/sessions/$sid', expected: 404);
    }
    repo.close();
    setup.close(force: true);
  }
}
