// R3 §7: IO-transport dispatch evidence against REAL loopback sockets.
// The four evidence points (dispatchInvoked / headersReceived / firstEvent /
// failedBeforeDispatch) must hold on the dart:io stack exactly as the
// contract states: the openUrl CALL is the dispatch, headers are recorded
// before any body byte, and only a synchronous argument throw may claim
// "never dispatched".
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/transport.dart';
import 'package:hermes_app/api/transport_io.dart';
import 'package:hermes_app/api/hermes_repository.dart';

class _SequencedObservation extends DispatchObservation {
  final log = <String>[];
  @override
  void dispatchInvoked() {
    log.add('dispatchInvoked<${stage.name}');
    super.dispatchInvoked();
  }

  @override
  void headersReceived(int status) {
    log.add('headersReceived<${stage.name},$status');
    super.headersReceived(status);
  }

  @override
  void firstEvent(String type) {
    log.add('firstEvent<${stage.name},$type');
    super.firstEvent(type);
  }

  @override
  void failedBeforeDispatch(String failureKind) {
    log.add('failedBeforeDispatch(${stage.name},$failureKind)');
    super.failedBeforeDispatch(failureKind);
  }
}

void main() {
  setUp(() => HttpOverrides.global = null);

  test('connection refused: dispatch WAS invoked — never "not dispatched"',
      () async {
    // Bind then CLOSE a loopback port so the kernel answers RST: nothing
    // can ever be served there while we connect.
    final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = dead.port;
    await dead.close(force: true);
    final repo = HermesRepository(
      'http://127.0.0.1:$deadPort',
      'k',
      port: IoHttpPort(connectTimeout: const Duration(seconds: 2)),
    );
    addTearDown(repo.close);
    final obs = _SequencedObservation();
    repo.stageChatObservation('s', obs);
    await expectLater(
      repo.chat('s', 'hi').first,
      throwsA(anything),
      reason: 'refused surfaces as a stream error',
    );
    // The openUrl call RETURNED a future: bytes may have been in flight.
    expect(obs.stage, TransportStage.dispatchInvoked);
    expect(obs.neverDispatched, isFalse); // THE red line: never a lie here
    expect(obs.failureKind, isNull);
    expect(obs.httpStatus, isNull);
    expect(
      obs.log,
      ['dispatchInvoked<prepared'],
      reason: 'only the invocation point fired — no headers, no failure',
    );
  });

  test('live SSE: dispatchInvoked -> headersReceived(200) -> firstEvent, in '
      'order; rewinds and restatements are no-ops', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var posts = 0;
    server.listen((req) async {
      if (req.method == 'POST' && req.uri.path.endsWith('/chat/stream')) posts++;
      req.response.headers.contentType = ContentType('text', 'event-stream');
      req.response
        ..write('event: run.started\ndata: {"run_id":"r-io"}\n\n')
        ..write('event: done\ndata: {}\n\n');
      await req.response.flush();
      await req.response.close();
    });
    final repo = HermesRepository(
      'http://127.0.0.1:${server.port}',
      'k',
      port: IoHttpPort(
        connectTimeout: const Duration(seconds: 2),
        headersTimeout: const Duration(seconds: 5),
      ),
    );
    addTearDown(repo.close);
    final obs = _SequencedObservation();
    repo.stageChatObservation('s', obs);
    final types = <String>[];
    await for (final e in repo.chat('s', 'hi')) {
      types.add(e.type);
    }
    expect(types, contains('run.started'));
    expect(posts, 1, reason: 'one send = one ledger-visible POST');
    expect(obs.httpStatus, 200);
    expect(obs.firstEventType, 'run.started');
    expect(obs.stage, TransportStage.firstEvent);
    expect(
      obs.log,
      [
        'dispatchInvoked<prepared',
        'headersReceived<dispatchInvoked,200',
        'headersReceived<headersReceived,200',
        'firstEvent<headersReceived,run.started',
        'firstEvent<firstEvent,done',
      ],
      reason: 'each point saw the PREVIOUS stage: strict forward order; '
          'the restated headers fact from the repo is a recorded no-op',
    );
    // Post-hoc restatements are lies — none may rewrite history:
    expect(obs.advance(TransportStage.prepared), isFalse);
    obs.dispatchInvoked();
    obs.failedBeforeDispatch('lateCancel');
    obs.headersReceived(500);
    obs.firstEvent('evil');
    expect(obs.stage, TransportStage.firstEvent);
    expect(obs.httpStatus, 200);
    expect(obs.firstEventType, 'run.started');
    expect(obs.neverDispatched, isFalse); // a late cancel NEVER unwinds
  });

  test('empty-host URL: the SYNCHRONOUS throw is the only provable '
      'never-dispatched failure on IO', () async {
    final port = IoHttpPort();
    addTearDown(port.close);
    final obs = _SequencedObservation();
    await expectLater(
      port.send(
        'POST',
        Uri.parse('http://'),
        headers: const {'authorization': 'k'},
        observation: obs,
      ),
      throwsArgumentError,
    );
    expect(obs.log, ['failedBeforeDispatch(prepared,requestSetup)']);
    expect(obs.stage, TransportStage.prepared); // never advanced
    expect(obs.neverDispatched, isTrue);
    expect(obs.failureKind, 'requestSetup');
    expect(obs.httpStatus, isNull);
  });

  test('observation is optional: a null sink changes nothing (contract '
      'bytes still flow)', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) {
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write('{"ok":true}');
      req.response.close();
    });
    final port = IoHttpPort(connectTimeout: const Duration(seconds: 2));
    addTearDown(port.close);
    final r = await port.send('GET', Uri.parse('http://127.0.0.1:${server.port}/'));
    expect(r.statusCode, 200);
    await utf8.decoder.bind(r.stream).join();
  });
}

