import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/hermes_repository.dart';

/// WAVE3 R3 acceptance pieces not covered by the proxy suites:
/// R3a — /api/model/options parsing with MIXED str/dict model entries
///       (old code threw on the first String element) + global current;
/// R3b — provider-level map parse of /v1/skills elements (enabled absent =
///       on) and the PATCH toggle URL/body;
/// R3c — /api/memories list + PUT round-trip through the repository.

Future<HermesRepository> repoWith(
  Future<void> Function(
    HttpRequest req,
    void Function(int, Object) reply,
  )
  handle,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    void replyWith(int code, Object body) {
      request.response.statusCode = code;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body));
      request.response.close();
    }

    await handle(request, replyWith);
  });
  addTearDown(() => server.close(force: true));
  final repo = HermesRepository('http://127.0.0.1:${server.port}', 'k');
  addTearDown(repo.close);
  return repo;
}

void main() {
  test('R3a: mixed string/dict model entries parse; global current surfaces',
      () async {
    final repo = await repoWith((req, reply) async {
      reply(200, {
        'model': 'gpt-6-astra',
        'provider': 'nous',
        'providers': [
          {
            'slug': 'nous',
            'name': 'Nous',
            'is_current': false,
            'models': ['gpt-6-astra', 'default'],
          },
          {
            'slug': 'openai',
            'name': 'OpenAI',
            'is_current': true,
            'models': [
              {'id': 'gpt-5'},
              {'slug': 'o-temp', 'is_current': true},
            ],
          },
        ],
      });
    });
    final catalog = await repo.modelCatalog();
    expect(catalog.global, 'gpt-6-astra');
    expect(catalog.models.map((m) => m['model']), [
      'gpt-6-astra',
      'default',
      'gpt-5',
      'o-temp',
    ]);
    expect(catalog.models.map((m) => m['current']), [
      false,
      false, // string rows are never current unless the provider is
      true, // provider is_current
      true, // dict is_current
    ]);
    expect(await repo.modelOptions(), catalog.models);
  });

  test('R3b: skills map parse (enabled absent = on) + PATCH toggle', () async {
    final calls = <String>[];
    final repo = await repoWith((req, reply) async {
      if (req.method == 'GET') {
        reply(200, {
          'object': 'list',
          'data': [
            {'name': 'alpha', 'description': 'A', 'category': 'tools'},
            {'name': 'beta', 'description': 'B', 'category': null,
             'enabled': false},
          ],
        });
      } else {
        calls.add('${req.method} ${req.uri.path} '
            '${jsonEncode(jsonDecode(await utf8.decoder.bind(req).join()))}');
        reply(200, {'name': 'beta', 'enabled': true});
      }
    });
    final skills = await repo.skills();
    expect(skills.map((s) => s.enabled), [true, false]);
    expect(skills.first.category, 'tools');
    await repo.setSkillEnabled('beta', true);
    expect(calls.single, 'PATCH /api/skills/beta {"enabled":true}');
  });

  test('R3c: memories list parse + saveMemory PUT body', () async {
    final calls = <String>[];
    final repo = await repoWith((req, reply) async {
      if (req.method == 'GET') {
        reply(200, {
          'object': 'list',
          'files': [
            {'name': 'MEMORY.md', 'chars': 2, 'limit': 2200,
             'content': '嗯嗯', 'mtime': 1758000000.0},
            {'name': 'USER.md', 'chars': 0, 'limit': 1375, 'content': null,
             'mtime': null},
          ],
        });
      } else {
        calls.add('${req.method} ${req.uri.path} '
            '${jsonEncode(jsonDecode(await utf8.decoder.bind(req).join()))}');
        reply(200, {'name': 'USER.md', 'chars': 3});
      }
    });
    final files = await repo.memories();
    expect(files.length, 2);
    expect(files.first['content'], '嗯嗯');
    expect(files.last['content'], isNull);
    await repo.saveMemory('USER.md', '你好\n');
    expect(calls.single, contains('PUT /api/memories/USER.md'));
    expect(calls.single, contains('"content":"你好\\n"'));
  });

  test('R4: resolveApproval POSTs the choice to the run approval route',
      () async {
    final calls = <String>[];
    final repo = await repoWith((req, reply) async {
      calls.add('${req.method} ${req.uri.path} '
          '${await utf8.decoder.bind(req).join()}');
      reply(200, {'ok': true});
    });
    await repo.resolveApproval('r/7', 'once');
    expect(calls.single, 'POST /v1/runs/r%2F7/approval {"choice":"once"}');
  });
}
