import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/transport.dart';
import 'package:hermes_app/api/transport_io.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';

/// AUDIT-10 regression: application-layer deadlines on the IO transport.
/// Real loopback sockets — a peer that accepts but never answers headers,
/// and one whose body freezes mid-flight — must produce BOUNDED, retryable
/// errors that genuinely cancel the underlying request. SSE paths keep the
/// contract's long budget (never shortened by the metadata deadline).
void main() {
  Future<ServerSocket> silentPeer(void Function(Socket) onAccept) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final open = <Socket>[];
    server.listen((s) {
      open.add(s);
      onAccept(s);
    });
    addTearDown(() async {
      for (final s in open) {
        s.destroy();
      }
      await server.close();
    });
    return server;
  }

  test('headers that never arrive: PortTimeout in bounded time, socket cut',
      () async {
    final sawConnection = Completer<Socket>();
    final socketClosed = Completer<void>();
    final server = await silentPeer((s) {
      if (!sawConnection.isCompleted) sawConnection.complete(s);
      s.listen(
        (_) {},
        onDone: () => socketClosed.isCompleted ? null : socketClosed.complete(),
        onError: (_) => socketClosed.isCompleted ? null : socketClosed.complete(),
      );
    });
    final port = IoHttpPort(
      connectTimeout: const Duration(seconds: 2),
      headersTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(port.close);
    final started = DateTime.now();
    await expectLater(
      port.send('GET', Uri.parse('http://127.0.0.1:${server.port}/x')),
      throwsA(isA<PortTimeout>()),
    );
    expect(
      DateTime.now().difference(started),
      lessThan(const Duration(seconds: 5)),
      reason: 'the wait for headers must be bounded, not eternal',
    );
    await sawConnection.future.timeout(const Duration(seconds: 3));
    await socketClosed.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => fail('timeout must ABORT the underlying request'),
    );
  });

  test('repository surfaces the header deadline as a retryable ApiException',
      () async {
    final server = await silentPeer((s) => s.listen((_) {}));
    final repo = HermesRepository(
      'http://127.0.0.1:${server.port}',
      'k',
      port: IoHttpPort(
        connectTimeout: const Duration(seconds: 2),
        headersTimeout: const Duration(milliseconds: 200),
      ),
      metadataTimeout: const Duration(milliseconds: 300),
    );
    addTearDown(repo.close);
    await expectLater(
      repo.runStatus('r1'),
      throwsA(
        isA<ApiException>().having(
          (e) => (e.uiMessage as UiLocal).key,
          'uiMessage.key',
          MessageKey.apiM005,
        ),
      ),
    );
    // Mutation semantics: a POST cut on headers is never auto-resent — the
    // peer must have seen EXACTLY one connection for the one call.
    var connections = 0;
    final counted = await silentPeer((s) {
      connections++;
      s.listen((_) {});
    });
    final repo2 = HermesRepository(
      'http://127.0.0.1:${counted.port}',
      'k',
      port: IoHttpPort(
        connectTimeout: const Duration(seconds: 2),
        headersTimeout: const Duration(milliseconds: 200),
      ),
    );
    addTearDown(repo2.close);
    await expectLater(repo2.stop('r9'), throwsA(isA<ApiException>()));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(connections, 1, reason: 'AUDIT-10: never auto-retry a mutation');
  });

  test('body frozen mid-flight lands as a retryable timeout, not a spinner',
      () async {
    final server = await silentPeer((s) {
      s.listen((_) {}); // swallow the request bytes
      s.write(
        'HTTP/1.1 200 OK\r\n'
        'content-type: application/json\r\n'
        'transfer-encoding: chunked\r\n'
        '\r\n'
        '5\r\n{"dat\r\n', // starts the JSON, then NEVER finishes
      );
      s.flush();
    });
    final repo = HermesRepository(
      'http://127.0.0.1:${server.port}',
      'k',
      port: IoHttpPort(
        connectTimeout: const Duration(seconds: 2),
        headersTimeout: const Duration(seconds: 2),
      ),
      metadataTimeout: const Duration(milliseconds: 300),
    );
    addTearDown(repo.close);
    await expectLater(
      repo.runStatus('r1'),
      throwsA(
        isA<ApiException>().having(
          (e) => (e.uiMessage as UiLocal).key,
          'uiMessage.key',
          MessageKey.apiM008,
        ),
      ),
    );
  });

  test('SSE keeps the long budget: late headers survive short defaults',
      () async {
    final server = await silentPeer((s) async {
      s.listen((_) {});
      // Headers only arrive AFTER the port's 150ms default would have fired.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      s.write(
        'HTTP/1.1 200 OK\r\n'
        'content-type: text/event-stream\r\n'
        '\r\n'
        'event: run.started\n'
        'data: {"run_id":"r","session_id":"s"}\n\n',
      );
      await s.flush();
      await s.close();
    });
    final repo = HermesRepository(
      'http://127.0.0.1:${server.port}',
      'k',
      port: IoHttpPort(
        connectTimeout: const Duration(seconds: 2),
        headersTimeout: const Duration(milliseconds: 150),
      ),
    );
    addTearDown(repo.close);
    final first = await repo
        .chat('s', 'hi')
        .first
        .timeout(const Duration(seconds: 5));
    expect(first.type, 'run.started'); // contract §1: never shorten chat SSE
  });

  test('port-level deadlines stay finite for everything else (no regress)',
      () async {
    // Sanity: a normal answered request is unaffected by the new plumbing.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((r) {
      r.response.headers.contentType = ContentType.json;
      r.response.write('{"status":"completed"}');
      r.response.close();
    });
    final repo = HermesRepository(
      'http://127.0.0.1:${server.port}',
      'k',
      port: IoHttpPort(
        connectTimeout: const Duration(seconds: 2),
        headersTimeout: const Duration(seconds: 5),
      ),
      metadataTimeout: const Duration(seconds: 5),
    );
    addTearDown(repo.close);
    expect(await repo.runStatus('ok'), {'status': 'completed'});
    expect(await repo.health(), isTrue);
  });
}
