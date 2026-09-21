import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/diagnostics/diagnostics_store.dart';
import 'package:hermes_app/diagnostics/diagnostics.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/platform/stream_keepalive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final calls = <MethodCall>[];
  late HttpServer server;
  late HermesRepository repo;
  late Directory directory;
  setUp(() async {
    calls.clear();
    directory = await Directory.systemTemp.createTemp('hermes-fgs');
    Diagnostics.current = Diagnostics(
      newDiagnosticsStore('${directory.path}/log'),
      '0.2.3+5',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(StreamKeepalive.channel, (call) async {
          calls.add(call);
          return null;
        });
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    repo = HermesRepository('http://127.0.0.1:${server.port}', 'secret');
  });
  tearDown(() async {
    repo.close();
    await server.close(force: true);
    await Diagnostics.current!.record('test.end');
    Diagnostics.current = null;
    await directory.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(StreamKeepalive.channel, null);
  });

  test(
    'successful open starts; run completion stops before socket EOF',
    () async {
      final response = Completer<HttpResponse>();
      server.listen((r) async {
        await r.drain<void>();
        r.response.bufferOutput = false;
        r.response.headers.contentType = ContentType('text', 'event-stream');
        r.response.write('event: run.completed\ndata: {}\n\n');
        await r.response.flush();
        response.complete(r.response);
      });
      final completed = Completer<void>();
      final reading = repo.chat('s', 'hello').listen((e) {
        expect(calls.map((c) => c.method), ['start', 'stop']);
        completed.complete();
      }).asFuture<void>();
      await completed.future;
      await (await response.future).close();
      await reading;
      expect(calls.map((c) => c.method), ['start', 'stop']);
      expect(calls.first.arguments, calls.last.arguments);
      await Diagnostics.current!.record('test.check');
      final raw = await File('${directory.path}/log').readAsString();
      expect(raw.indexOf('sse.open'), lessThan(raw.indexOf('fgs.start')));
    },
  );

  test('two sessions use distinct leases and release independently', () async {
    final responses = <HttpResponse>[];
    final opened = Completer<void>();
    var events = 0;
    server.listen((r) async {
      await r.drain<void>();
      r.response.bufferOutput = false;
      r.response.headers.contentType = ContentType('text', 'event-stream');
      responses.add(r.response);
      r.response.write('event: run.started\ndata: {}\n\n');
      await r.response.flush();
    });
    void event(dynamic _) {
      if (++events == 2) opened.complete();
    }

    final first = repo.chat('one', 'hello').listen(event).asFuture<void>();
    final second = repo.chat('two', 'hello').listen(event).asFuture<void>();
    await opened.future;
    expect(calls.map((c) => c.method), ['start', 'start']);
    expect(calls[0].arguments, isNot(calls[1].arguments));
    repo.releaseStreamKeepalive('one');
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((c) => c.method), ['start', 'start', 'stop']);
    for (final response in responses) {
      await response.close();
    }
    await Future.wait([first, second]);
    final starts = calls
        .where((c) => c.method == 'start')
        .map((c) => c.arguments)
        .toSet();
    final stops = calls
        .where((c) => c.method == 'stop')
        .map((c) => c.arguments)
        .toSet();
    expect(stops, starts);
    expect(calls.length, 4);
  });

  test('HTTP rejection never starts service', () async {
    server.listen((r) async {
      await r.drain<void>();
      r.response.statusCode = 401;
      await r.response.close();
    });
    await expectLater(
      repo.chat('s', 'hello').toList(),
      throwsA(isA<ApiException>()),
    );
    expect(calls, isEmpty);
  });

  test(
    'SSE error event and early EOF each release service exactly once',
    () async {
      server.listen((r) async {
        await r.drain<void>();
        r.response.bufferOutput = false;
        r.response.headers.contentType = ContentType('text', 'event-stream');
        r.response.write('event: error\ndata: {}\n\n');
        await r.response.close();
      });
      await repo.chat('s', 'hello').toList();
      expect(calls.map((c) => c.method), ['start', 'stop']);
    },
  );

  test('transport parse failure releases service', () async {
    server.listen((r) async {
      await r.drain<void>();
      r.response.bufferOutput = false;
      r.response.headers.contentType = ContentType('text', 'event-stream');
      r.response.add([255, 255]);
      await r.response.close();
    });
    await expectLater(repo.chat('s', 'hello').toList(), throwsFormatException);
    expect(calls.map((c) => c.method), ['start', 'stop']);
  });

  test('recovering stops service; history polling never restarts it', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    final response = Completer<HttpResponse>();
    var reads = 0;
    server.listen((r) async {
      await r.drain<void>();
      if (r.uri.path.endsWith('/messages')) {
        reads++;
        r.response.headers.contentType = ContentType.json;
        r.response.write('{"data":[]}');
        await r.response.close();
      } else {
        r.response.bufferOutput = false;
        r.response.headers.contentType = ContentType('text', 'event-stream');
        r.response.write(
          'event: run.started\ndata: {"run_id":"r","session_id":"s"}\n\n',
        );
        await r.response.flush();
        response.complete(r.response);
      }
    });
    final c = ChatController(repo, store, 's', wait: (_) async {});
    final opened = Completer<void>();
    c.addListener(() {
      if (c.canControl && !opened.isCompleted) opened.complete();
    });
    final sending = c.send('hello');
    await opened.future;
    await c.recover();
    expect(c.phase, ChatPhase.uncertain);
    expect(reads, 6);
    expect(calls.map((c) => c.method), ['start', 'stop']);
    await c.retryReconcile();
    expect(reads, 12);
    expect(calls.map((c) => c.method), ['start', 'stop']);
    c.dispose();
    await (await response.future).close();
    await sending;
  });

  test('foreground final reconciled to idle releases an open stream', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    final response = Completer<HttpResponse>();
    server.listen((r) async {
      await r.drain<void>();
      if (r.uri.path.endsWith('/messages')) {
        r.response.headers.contentType = ContentType.json;
        r.response.write(
          '{"data":[{"id":"u","role":"user","content":"hello"},{"id":"a","role":"assistant","content":"final"}]}',
        );
        await r.response.close();
      } else {
        r.response.bufferOutput = false;
        r.response.headers.contentType = ContentType('text', 'event-stream');
        r.response.write(
          'event: run.started\ndata: {"run_id":"r","session_id":"s"}\n\n',
        );
        await r.response.flush();
        response.complete(r.response);
      }
    });
    final c = ChatController(repo, store, 's');
    final opened = Completer<void>();
    c.addListener(() {
      if (c.canControl && !opened.isCompleted) opened.complete();
    });
    final sending = c.send('hello');
    await opened.future;
    await c.reconcileForeground();
    await Future<void>.delayed(Duration.zero);
    expect(c.phase, ChatPhase.idle);
    expect(calls.map((c) => c.method), ['start', 'stop']);
    await (await response.future).close();
    await sending;
    c.dispose();
  });

  test('failed service start logs fgs.error and chat continues', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(StreamKeepalive.channel, (call) async {
          calls.add(call);
          if (call.method == 'start') throw PlatformException(code: 'denied');
          return null;
        });
    server.listen((r) async {
      await r.drain<void>();
      r.response.bufferOutput = false;
      r.response.headers.contentType = ContentType('text', 'event-stream');
      r.response.write(
        'event: message.started\ndata: {}\n\nevent: done\ndata: {}\n\n',
      );
      await r.response.close();
    });
    expect(await repo.chat('s', 'hello').length, 2);
    await Diagnostics.current!.record('test.check');
    final log = await File('${directory.path}/log').readAsString();
    expect(log, contains('fgs.error'));
    expect(log, contains('message.started'));
    expect(log, contains('"event":"done"'));
    expect(log, isNot(contains('unknown')));
    expect(calls.map((c) => c.method), ['start', 'stop']);
  });

  test(
    'stop before open suppresses start; stop during promotion is ordered',
    () async {
      final early = StreamKeepalive(10);
      await early.stop();
      await early.start();
      expect(calls, isEmpty);
      final promoted = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(StreamKeepalive.channel, (call) async {
            calls.add(call);
            if (call.method == 'start') await promoted.future;
            return null;
          });
      final lease = StreamKeepalive(11);
      final starting = lease.start();
      final stopping = lease.stop();
      promoted.complete();
      await starting;
      await stopping;
      await lease.stop();
      expect(calls.map((c) => c.method), ['start', 'stop']);
    },
  );
}
