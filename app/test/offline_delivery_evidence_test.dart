import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/transport.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/chat/local_attempt.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';
import 'package:hermes_app/platform/connectivity_hint.dart';
import 'package:hermes_app/platform/stream_keepalive.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// OFFLINE-SEND R3 §5.5: delivery EVIDENCE through a REAL HermesRepository
/// over a fake HttpPort with a POST/GET ledger and per-stage injectable
/// failures. Every classification asserted here comes from the journal's
/// structured evidence — never from an exception string.

/// Transport-shaped failure whose toString WOULD match the repository's
/// legacy string hints — classification must stay structural all the same.
class SocketErrorFake implements Exception {
  const SocketErrorFake(this.why);
  final String why;
  @override
  String toString() => 'SocketException (fake): $why';
}

class LedgerPort implements HttpPort {
  LedgerPort({required this.mode});

  String mode;
  int chatPosts = 0, uploadPosts = 0, stopPosts = 0, gets = 0;
  final chatBodies = <String>[];
  // mode=ackDelayed: the test pushes SSE bytes through this controller.
  StreamController<List<int>>? sse;

  @override
  Future<PortResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Stream<List<int>>? body,
    int? contentLength,
    Future<void>? abortTrigger,
    Duration? headersTimeout,
    DispatchObservation? observation,
  }) async {
    final isChat = method == 'POST' && uri.path.endsWith('/chat/stream');
    if (isChat) {
      if (mode == 'syncThrowBeforeRecord') {
        // SYNCHRONOUSLY before recording anything: the underlying call is
        // provably never invoked. The ONLY legal before-dispatch failure a
        // port may report.
        observation?.failedBeforeDispatch('requestSetup');
        throw ArgumentError('bad url');
      }
      chatPosts++; // RECORDED FIRST — ledger truth, whatever happens next
      final chunks = <List<int>>[];
      if (body != null) {
        await for (final c in body) {
          chunks.add(c);
        }
      }
      chatBodies.add(utf8.decode(chunks.expand((c) => c).toList()));
      observation?.dispatchInvoked(); // the call WAS invoked: everything
      // from here on can only ever be outcomeUnknown-or-stronger.
      switch (mode) {
        case 'throwAfterInvoke':
          throw const SocketErrorFake('connection refused');
        case 'acceptedDrop':
          return PortResponse(
            200,
            {'content-type': 'text/event-stream'},
            Stream.error(const SocketErrorFake('socket closed after accept')),
          );
        case 'headersGarbage':
          return PortResponse(
            200,
            {'content-type': 'application/octet-stream'},
            Stream.value(utf8.encode('not sse at all garbage')),
          );
        case 'sseGarbage':
          return PortResponse(
            200,
            {'content-type': 'text/event-stream'},
            Stream.value(utf8.encode('this is not an SSE frame\n\n')),
          );
        case 'heartbeatEof':
          return PortResponse(
            200,
            {'content-type': 'text/event-stream'},
            Stream.value(utf8.encode(': keepalive\n\n')),
          );
        case 'ackThenDrop':
          return PortResponse(
            200,
            {'content-type': 'text/event-stream'},
            Stream.value(
              utf8.encode(
                'event: run.started\n'
                'data: {"run_id":"r-7","session_id":"s"}\n\n',
              ),
            ),
          );
        case 'ackDelayed':
          final controller = StreamController<List<int>>();
          sse = controller;
          return PortResponse(
            200,
            {'content-type': 'text/event-stream'},
            controller.stream,
          );
        case 'err400':
          return PortResponse(
            400,
            {'content-type': 'application/json'},
            Stream.value(utf8.encode('{"error":{"message":"rejected"}}')),
          );
        case 'err400DrainThrows':
          // Headers (400) land NOW; the body throws WHILE being drained.
          return PortResponse(
            400,
            {'content-type': 'application/json'},
            Stream.error(const SocketErrorFake('drain exploded')),
          );
        case 'headersHang':
          final done = Completer<PortResponse>();
          // Honor the abort channel exactly like the real ports: a detach
          // AFTER dispatch errors the call — never a before-dispatch fact.
          abortTrigger?.then((_) {
            if (!done.isCompleted) {
              done.completeError(const SocketErrorFake('aborted'));
            }
          });
          return done.future;
      }
      return PortResponse(
        200,
        {'content-type': 'text/event-stream'},
        Stream.value(
          utf8.encode(
            'event: run.started\n'
            'data: {"run_id":"r-7","session_id":"s"}\n\n'
            'event: run.completed\ndata: {"status":"completed"}\n\n',
          ),
        ),
      );
    }
    if (method == 'POST' && uri.path.endsWith('/artifacts/upload')) {
      uploadPosts++;
    }
    if (method == 'POST' && uri.path.endsWith('/stop')) stopPosts++;
    if (method == 'GET') gets++;
    if (uri.path.endsWith('/messages')) {
      return _json(200, {'data': const <Map<String, Object?>>[]});
    }
    if (uri.path.endsWith('/activity')) {
      return _json(200, _quietActivity('s'));
    }
    if (uri.path.contains('/runs/')) {
      return _json(200, {'run': {'status': 'queued'}});
    }
    if (uri.path.endsWith('/capabilities')) {
      return _json(200, {
        'auth': {'required': true},
        'features': {'session_chat_streaming': true},
      });
    }
    if (method == 'GET' && uri.path.contains('/api/sessions/')) {
      return _json(200, {
        'session': {'id': 's', 'message_count': 0},
      });
    }
    return _json(404, {'error': 'none'});
  }

  @override
  void close() {}
}

PortResponse _json(int status, Map<String, Object?> body) => PortResponse(
  status,
  {'content-type': 'application/json'},
  Stream.value(utf8.encode(jsonEncode(body))),
);

Map<String, Object?> _quietActivity(String sid) => {
  'object': 'hermes.session.activity',
  'schema_version': 1,
  'session_id': sid,
  'resolved_session_id': sid,
  'server_epoch': 'ledger-epoch',
  'observed_at': 0,
  'history_revision': {'session_id': sid, 'count': 0, 'latest_id': 0},
  'activity_revision': 0,
  'active_runs': const [],
  'recent_terminal': const [],
  'overflow': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late LocalStore store;
  late LedgerPort port;
  late HermesRepository repo;
  late DateTime t;
  final t0 = DateTime.utc(2026, 1, 1);

  void makeRepo({String mode = 'success'}) {
    port = LedgerPort(mode: mode);
    repo = HermesRepository('http://ledger.invalid', 'k', port: port);
  }

  setUp(() async {
    // The chat pipeline leases the foreground-service channel per stream;
    // answer it instantly so the process-wide command chain never strands
    // a stream mid-read on the web runner (VM: identical, faster).
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(StreamKeepalive.channel, (call) async => null);
    StreamKeepalive.resetCommandQueueForTest();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = LocalStore(prefs);
    t = t0;
    makeRepo();
  });
  tearDown(() {
    LocalStore.debugFailAttemptWrites = false;
    repo.close();
  });

  ChatController scripted({ConnectivityHint? hint}) => ChatController(
    repo,
    store,
    's',
    wait: (_) async {},
    watchInterval: const Duration(milliseconds: 1),
    now: () => t,
    connectivity: () => hint ?? ConnectivityHint.unknown,
  );

  LocalAttempt? attemptFor(ChatController c) {
    final id = store.loadPending(repo.baseUrl, 's')?.attemptId;
    if (id != null) return store.loadAttempt(repo.baseUrl, 's', id);
    final all = store.listAttempts(repo.baseUrl, 's');
    return all.isEmpty ? null : all.first;
  }

  Future<void> settleMicrotasks() async {
    // Enough event-loop yields for BOTH the VM microtask pump and the
    // browser's coarser stream scheduling (chrome lane runs the same
    // assertions — a fixed 8 starves ddc's longer queue).
    for (var i = 0; i < 25; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('offline hint: zero POSTs, blockedBeforeDispatch, input untouched', () async {
    final c = scripted(hint: ConnectivityHint.offline);
    const raw = '  multiline😀 draft  ';
    await c.send('multiline😀 draft', draft: 'multiline😀 draft', rawDraft: raw);
    await settleMicrotasks();
    expect(port.chatPosts, 0);
    expect(port.uploadPosts, 0);
    expect(port.stopPosts, 0);
    expect(port.gets, 0); // nothing networked AT ALL on the blocked path
    expect(c.phase, ChatPhase.idle);
    expect(c.pendingInput, isNull); // no ghost bubble: input stays visible
    final a = attemptFor(c)!;
    expect(a.origin, 'human');
    expect(a.disposition, AttemptDisposition.waiting);
    expect(a.delivery, AttemptDelivery.notDispatched);
    expect(a.rawDraft, raw); // VERBATIM — spaces, emoji, spacing kept
    expect(a.terminalEvidence?['stage'], 'prepared');
    expect(a.terminalEvidence?['decision'], 'blockedBeforeDispatch');
    expect(c.deliveryView, AttemptDeliveryView.notDispatched);
    expect((c.failedCard! as UiLocal).key, MessageKey.chatSendOffline);
    c.dispose();
  });

  test('synchronous before-dispatch failure: notDispatched, zero POSTs', () async {
    makeRepo(mode: 'syncThrowBeforeRecord');
    final c = scripted();
    await c.send('question one');
    await settleMicrotasks();
    expect(port.chatPosts, 0); // the ledger proves nothing was ever sent
    final a = attemptFor(c)!;
    expect(a.delivery, AttemptDelivery.notDispatched);
    expect(a.terminalEvidence?['decision'], 'failedBeforeDispatch');
    expect(c.deliveryView, AttemptDeliveryView.notDispatched);
    expect((c.failedCard! as UiLocal).key, MessageKey.chatSendNotDispatched);
    expect(c.phase, ChatPhase.idle);
    c.dispose();
  });

  test('dispatchInvoked then transport throw: outcomeUnknown, never notDispatched', () async {
    makeRepo(mode: 'throwAfterInvoke');
    final c = scripted();
    final sending = c.send('question one');
    await settleMicrotasks();
    expect(port.chatPosts, 1);
    final a = attemptFor(c)!;
    expect(a.delivery, AttemptDelivery.outcomeUnknown);
    expect(a.terminalEvidence?['stage'], 'dispatchInvoked');
    expect(c.deliveryView, AttemptDeliveryView.outcomeUnknown);
    expect(c.deliveryView, isNot(AttemptDeliveryView.notDispatched));
    expect(c.failedCard, isNull); // no retry affordance on an unknown
    await sending; // recovery lands honestly on uncertain (wait seam no-op)
    expect(c.phase, ChatPhase.uncertain);
    expect(attemptFor(c)!.delivery, AttemptDelivery.outcomeUnknown); // kept
    c.dispose();
  });

  test('SSE-shaped headers, garbage body until EOF: unknown with status kept', () async {
    makeRepo(mode: 'sseGarbage');
    final c = scripted();
    final sending = c.send('question one');
    await settleMicrotasks();
    final a = attemptFor(c)!;
    expect(a.delivery, AttemptDelivery.outcomeUnknown);
    expect(a.terminalEvidence?['httpStatus'], 200); // headers ARE recorded
    expect(a.terminalEvidence?['firstEventType'], isNull); // never a frame
    expect(c.deliveryView, AttemptDeliveryView.outcomeUnknown);
    expect(c.failedCard, isNull);
    final m = c.recoveryNotice ?? c.error; // no "delivered" wording anywhere
    expect(m is UiLocal && m.key == MessageKey.chatDeliveredReplyLoading, isFalse);
    await sending;
    c.dispose();
  });

  test('headers 200 but NOT event-stream: unknown, status kept, no draft loss', () async {
    makeRepo(mode: 'headersGarbage');
    final c = scripted();
    final sending = c.send('question one');
    await settleMicrotasks();
    final a = attemptFor(c)!;
    expect(a.delivery, AttemptDelivery.outcomeUnknown);
    expect(a.terminalEvidence?['httpStatus'], 200);
    expect(c.deliveryView, AttemptDeliveryView.outcomeUnknown);
    await sending;
    c.dispose();
  });

  test('heartbeat-only stream then EOF: firstEvent recorded, ack NOT set', () async {
    makeRepo(mode: 'heartbeatEof');
    final c = scripted();
    final sending = c.send('question one');
    await settleMicrotasks();
    final a = attemptFor(c)!;
    expect(a.terminalEvidence?['stage'], 'firstEvent');
    expect(a.terminalEvidence?['firstEventType'], 'heartbeat');
    expect(a.delivery, AttemptDelivery.outcomeUnknown); // NOT acknowledged
    expect(c.deliveryView, AttemptDeliveryView.outcomeUnknown);
    await sending;
    c.dispose();
  });

  test('business ack then drop: acknowledged + runId; observation never re-POSTs', () async {
    makeRepo(mode: 'ackThenDrop');
    final c = scripted();
    final sending = c.send('question one');
    await settleMicrotasks();
    var a = attemptFor(c)!;
    expect(a.delivery, AttemptDelivery.acknowledged);
    expect(a.runId, 'r-7');
    expect(a.terminalEvidence?['firstEventType'], 'run.started');
    expect(c.deliveryView, AttemptDeliveryView.acknowledged);
    await sending; // EOF → the bounded read-only observation runs to rest
    expect(port.chatPosts, 1); // STILL one — watchdog/recovery never re-POSTs
    expect(port.stopPosts, 0);
    expect(port.uploadPosts, 0);
    expect(port.gets, greaterThan(0)); // the observation is GETs only
    a = attemptFor(c)!;
    expect(a.delivery, AttemptDelivery.acknowledged); // never downgraded
    c.dispose();
  });

  test('400 whose body drain throws: rejected with the recorded status kept', () async {
    makeRepo(mode: 'err400DrainThrows');
    final c = scripted();
    await c.send('question one');
    await settleMicrotasks();
    final a = attemptFor(c)!;
    expect(a.delivery, AttemptDelivery.rejected);
    expect(a.terminalEvidence?['httpStatus'], 400); // the drain error did NOT
    // erase the header-proven status
    expect(c.deliveryView, AttemptDeliveryView.rejected);
    expect(port.chatPosts, 1);
    c.dispose();
  });

  test('plain 400: rejected through the existing M023 path, status recorded', () async {
    makeRepo(mode: 'err400');
    final c = scripted();
    await c.send('question one');
    await settleMicrotasks();
    final a = attemptFor(c)!;
    expect(a.delivery, AttemptDelivery.rejected);
    expect(a.terminalEvidence?['httpStatus'], 400);
    expect((c.error! as UiLocal).key, MessageKey.chatStateM023);
    expect(c.deliveryView, AttemptDeliveryView.rejected);
    c.dispose();
  });

  test('reload of a dispatchIntent-only record: unknown, never notDispatched', () async {
    final claim = await store.claimPending(
      repo.baseUrl,
      's',
      userText: 'question one',
      turnId: 't1',
    );
    final attemptId = store.loadPending(repo.baseUrl, 's')!.attemptId!;
    expect(
      await store.saveAttempt(
        repo.baseUrl,
        's',
        LocalAttempt(
          attemptId: attemptId,
          server: repo.baseUrl,
          sid: 's',
          createdAt: t0,
          origin: 'human',
          rawDraft: 'question one',
          terminalEvidence: const {
            'dispatchIntent': true,
            'stage': 'prepared',
          },
        ),
      ),
      isTrue,
    );
    expect(claim, isNotNull);
    await store.beginPendingRecovery(repo.baseUrl, 's', token: claim, now: t0);
    t = t0.add(const Duration(seconds: 61)); // the persisted budget is spent
    final c = scripted();
    await c.bootstrap();
    expect(c.phase, ChatPhase.uncertain);
    final a = store.loadAttempt(repo.baseUrl, 's', attemptId)!;
    expect(a.terminalEvidence?['dispatchIntent'], true);
    expect(c.deliveryView, AttemptDeliveryView.outcomeUnknown);
    expect(c.deliveryView, isNot(AttemptDeliveryView.notDispatched));
    expect(c.failedCard, isNull); // no retry affordance on a reload-unknown
    expect(port.chatPosts, 0); // the reload itself never re-dispatches
    c.dispose();
  });

  test('persist-ack failure keeps the in-memory positive evidence + notice', () async {
    makeRepo(mode: 'ackDelayed');
    final c = scripted();
    final sending = c.send('question one');
    await settleMicrotasks(); // claim + dispatchIntent + headers are on disk
    expect(attemptFor(c)!.terminalEvidence?['dispatchIntent'], true);
    LocalStore.debugFailAttemptWrites = true; // NOW every journal write dies
    port.sse!
      ..add(
        utf8.encode(
          'event: run.started\ndata: {"run_id":"r-7","session_id":"s"}\n\n',
        ),
      )
      ..close(); // …and the stream drops right after the ack
    await settleMicrotasks();
    // The disk refused this attempt's ack entry — but the OBSERVATION stands:
    final disk = attemptFor(c)!;
    expect(disk.attemptId, isNotEmpty);
    final derived = c.deliveryView;
    expect(derived, AttemptDeliveryView.acknowledged); // mirror kept (§5.2.7)
    expect((c.storageNotice! as UiLocal).key, MessageKey.chatRecoveryStorageFailed);
    LocalStore.debugFailAttemptWrites = false;
    await sending;
    expect(port.chatPosts, 1);
    c.dispose();
  });

  test('cancel/detach AFTER dispatch is never before-dispatch evidence', () async {
    makeRepo(mode: 'headersHang');
    final c = scripted();
    final sending = c.send('question one');
    await settleMicrotasks();
    expect(port.chatPosts, 1); // invoked — the record is dispatchIntent-live
    repo.cancelStream('s'); // a stop/detach landing AFTER the dispatch
    await settleMicrotasks();
    final a = attemptFor(c)!;
    expect(a.terminalEvidence?['decision'], isNot('failedBeforeDispatch'));
    expect(a.delivery, isNot(AttemptDelivery.notDispatched));
    expect(c.deliveryView, isNot(AttemptDeliveryView.notDispatched));
    await sending;
    expect(port.chatPosts, 1); // and the observation never re-POSTed
    c.dispose();
  });

  test('ledger-visible chat body is the contract POST, dispatched exactly once', () async {
    makeRepo(mode: 'success');
    final c = scripted();
    final sending = c.send('hello ledger');
    await c.waitEvidenceWrites();
    await settleMicrotasks();
    expect(port.chatPosts, 1);
    expect(jsonDecode(port.chatBodies.single)['input'], 'hello ledger');
    final a = store.listAttempts(repo.baseUrl, 's').single;
    expect(a.delivery, AttemptDelivery.acknowledged);
    expect(a.terminalEvidence?['stage'], 'firstEvent');
    expect(a.terminalEvidence?['httpStatus'], 200);
    expect(a.terminalEvidence?['dispatchIntent'], true); // preserved alongside
    await sending;
    c.dispose();
  });
}
