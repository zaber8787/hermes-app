import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';

void main() {
  test(
    'HTTP session paging advances raw offset and deduplicates overlapping IDs',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final offsets = <String>[];
      var authorized = true;
      server.listen((request) async {
        authorized &=
            request.headers.value('Authorization') == 'Bearer fake-test-key';
        offsets.add(request.uri.queryParameters['offset']!);
        final first = request.uri.queryParameters['offset'] == '0';
        final ids = first ? List.generate(500, (i) => i) : [499, 500];
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': ids
                .map(
                  (i) => {
                    'id': '$i',
                    'title': 'test',
                    'message_count': 0,
                    'started_at': i,
                  },
                )
                .toList(),
          }),
        );
        await request.response.close();
      });
      final repo = HermesRepository(
        'http://127.0.0.1:${server.port}',
        'fake-test-key',
      );
      try {
        final sessions = await repo.sessions();
        expect(offsets, ['0', '500']);
        expect(sessions.length, 501);
        expect(sessions.first.id, '500');
        expect(authorized, isTrue);
      } finally {
        repo.close();
        await server.close(force: true);
      }
    },
  );
  test('HTTP errors never expose a reflected API key', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.statusCode = 401;
      request.response.write('fake-sensitive-key');
      await request.response.close();
    });
    final repo = HermesRepository(
      'http://127.0.0.1:${server.port}',
      'fake-sensitive-key',
    );
    try {
      await expectLater(
        repo.skills(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.toString(),
            'redacted',
            isNot(contains('fake-sensitive-key')),
          ),
        ),
      );
    } finally {
      repo.close();
      await server.close(force: true);
    }
  });
  test(
    'recent activity uses last message timestamp, not session creation time',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var historyReads = 0;
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/api/sessions') {
          request.response.write(
            jsonEncode({
              'data': [
                {'id': 'old', 'message_count': 1, 'started_at': 1},
                {'id': 'new', 'message_count': 1, 'started_at': 2},
              ],
            }),
          );
        } else {
          historyReads++;
          expect(request.uri.queryParameters['limit'], '1');
          final old = request.uri.path.contains('/old/');
          request.response.write(
            jsonEncode({
              'data': [
                {
                  'id': old ? 10 : 3,
                  'role': 'assistant',
                  'content': 'ok',
                  'timestamp': old ? 10 : 3,
                },
              ],
            }),
          );
        }
        await request.response.close();
      });
      final repo = HermesRepository('http://127.0.0.1:${server.port}', 'fake');
      try {
        expect((await repo.sessions()).first.id, 'old');
        expect((await repo.sessions()).first.id, 'old');
        expect(historyReads, 2); // Unchanged counts reuse activity cache.
      } finally {
        repo.close();
        await server.close(force: true);
      }
    },
  );
  // CROSSDEV-STOP R2 §5.2: the LOCAL stop path carries no metadata deadline
  // at all (port default headers only), while the REMOTE reconciliation path
  // (stopWithDeadline) pays the SAME POST under metadataTimeout. A slow
  // gateway must never turn the local path into a timeout, and the bounded
  // path must time out WITHOUT a silent re-POST (one dispatch, proven).
  test(
    'stop ignores metadataTimeout while stopWithDeadline bounds the same POST',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final paths = <String>[];
      server.listen((request) async {
        paths.add('${request.method} ${request.uri.path}');
        await Future<void>.delayed(const Duration(milliseconds: 400));
        request.response.statusCode = 200;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{}');
        await request.response.close();
      });
      final repo = HermesRepository(
        'http://127.0.0.1:${server.port}',
        'fake',
        metadataTimeout: const Duration(milliseconds: 100),
      );
      try {
        await repo.stop('r-local'); // No deadline: 400ms gateway is fine.
        expect(paths, ['POST /v1/runs/r-local/stop']);
        await expectLater(
          repo.stopWithDeadline('r-remote'),
          throwsA(
            isA<ApiException>().having(
              (e) => (e.uiMessage as UiLocal).key,
              'bounded headers budget',
              MessageKey.apiM005,
            ),
          ),
        );
        // Timeout AFTER dispatch: exactly one POST for r-remote, ever.
        expect(paths.where((p) => p.endsWith('/r-remote/stop')).length, 1);
      } finally {
        repo.close();
        await server.close(force: true);
      }
    },
  );
}