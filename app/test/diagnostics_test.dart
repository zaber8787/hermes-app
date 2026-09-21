import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/diagnostics/diagnostics.dart';
import 'package:hermes_app/diagnostics/diagnostics_store.dart';
import 'package:hermes_app/api/hermes_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test(
    'SSE file includes heartbeat, version, EOF and export snapshot without secrets',
    () async {
      final dir = await Directory.systemTemp.createTemp('hermes-log');
      final log = Diagnostics(
        newDiagnosticsStore('${dir.path}/sse.jsonl'),
        '0.2.2+4',
      );
      Diagnostics.current = log;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) async {
        await r.drain<void>();
        r.response.headers.contentType = ContentType('text', 'event-stream');
        r.response.write(
          ': keepalive\n\nevent: assistant.delta\ndata: {"delta":"PRIVATE"}\n\n',
        );
        await r.response.close();
      });
      final repo = HermesRepository(
        'http://127.0.0.1:${server.port}',
        'SECRET',
      );
      try {
        await repo.chat('private-session', 'PRIVATE INPUT').toList();
        await log.record('test.end');
        final raw = await File('${dir.path}/sse.jsonl').readAsString();
        final rows = raw
            .trim()
            .split('\n')
            .map((s) => jsonDecode(s) as Map)
            .toList();
        expect(rows.any((r) => r['event'] == 'heartbeat'), isTrue);
        expect(rows.any((r) => r['kind'] == 'sse.eof'), isTrue);
        expect(
          rows.every((r) => r['version'] == '0.2.2+4' && r['at'] != null),
          isTrue,
        );
        expect(raw, isNot(contains('PRIVATE')));
        expect(raw, isNot(contains('SECRET')));
        expect(raw, isNot(contains('private-session')));
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(Diagnostics.channel, (call) async {
              expect(call.method, 'export');
              expect(await File(call.arguments as String).readAsString(), raw);
              return true;
            });
        expect(await log.export(), isTrue);
      } finally {
        repo.close();
        await server.close(force: true);
        Diagnostics.current = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('hermes/diagnostics'),
              null,
            );
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'rotation preserves previous file and write errors do not escape',
    () async {
      final dir = await Directory.systemTemp.createTemp('hermes-log');
      try {
        final file = File('${dir.path}/sse.jsonl');
        await file.writeAsString('x' * (2 * 1024 * 1024));
        final log = Diagnostics(
          newDiagnosticsStore(file.path),
          'test',
        );
        await log.record('heartbeat');
        expect(await File('${file.path}.1').length(), 2 * 1024 * 1024);
        expect(await file.readAsString(), contains('heartbeat'));
        final broken = Diagnostics(
          newDiagnosticsStore('${file.path}/invalid'),
          'test',
        );
        await broken.record('test');
        expect(broken.failure, isNotNull);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
