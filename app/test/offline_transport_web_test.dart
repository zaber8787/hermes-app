// OFFLINE-SEND R3 §7: REAL-browser dispatch evidence against the ledger
// server (`test/support/offline_ledger_server.dart`). These are the plan's
// B-class rows run as automation: a real Chrome fetch stack (no mocks), and
// the POST ledger is read from the SERVER, never from a fake's counters.
// Without the server running they SKIP (never fail) — run it first:
//   ../toolchain/flutter/bin/dart run test/support/offline_ledger_server.dart \
//       --port 18701
// then:  ../toolchain/flutter/bin/flutter test --no-pub -p chrome
@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/api/transport.dart';

const base = 'http://127.0.0.1:18701';

Future<bool>? _upFuture;
Future<bool> _ledgerUp() => _upFuture ??= () async {
  final probe = HermesRepository(base, 'k');
  try {
    // A refused/absent ledger rejects the fetch immediately in Chrome, so
    // no timeout wrapper (whose late-error would leak unhandled).
    await probe.checkCapabilities();
    return true;
  } catch (_) {
    return false;
  } finally {
    probe.close();
  }
}();

Future<Map<String, Object?>> _reset(String mode) async {
  try {
    // A bodyless, headerless POST is a CORS-SIMPLE request: the harness's
    // own reset never pollutes the OPTIONS ledger.
    final r = await http.Client()
        .post(Uri.parse('$base/__test/reset?mode=$mode'))
        .timeout(const Duration(seconds: 5));
    return jsonDecode(r.body) as Map<String, Object?>;
  } catch (_) {
    return {}; // mode-switch response may be CORS-blocked; the RESET landed
  }
}

Future<Map<String, Object?>> _ledger() async {
  final r = await http.Client()
      .get(Uri.parse('$base/__test/ledger'))
      .timeout(const Duration(seconds: 5));
  return jsonDecode(r.body) as Map<String, Object?>;
}

void main() {
  HermesRepository? repo;

  tearDown(() => repo?.close());

  Future<bool> skipUnlessUp() async {
    if (await _ledgerUp()) return true;
    markTestSkipped(
      'offline_ledger_server not running on :18701 '
      '(dart run test/support/offline_ledger_server.dart --port 18701)',
    );
    return false;
  }

  test('B-success: exactly ONE chat POST, run accepted, the full stage '
      'ladder dispatchInvoked -> headers(200) -> firstEvent', () async {
    if (!await skipUnlessUp()) return;
    repo = HermesRepository(base, 'k');
    final obs = DispatchObservation();
    repo!.stageChatObservation('s', obs);
    await _reset('success');
    final events = <SseEvent>[];
    await repo!
        .chat('s', 'hi')
        .forEach(events.add)
        .timeout(const Duration(seconds: 20));
    final l = await _ledger();
    expect(l['chatPosts'], 1); // SERVER-side: exactly one mutation
    expect(l['acceptedRuns'], 1);
    expect(obs.stage, TransportStage.firstEvent);
    expect(obs.httpStatus, 200);
    expect(events.map((e) => e.type), contains('run.started'));
  });

  test('B-accepted-drop: server RECORDED the POST then the socket died — '
      'dispatch proven, outcome unknown, never "not dispatched"', () async {
    if (!await skipUnlessUp()) return;
    repo = HermesRepository(base, 'k');
    final obs = DispatchObservation();
    repo!.stageChatObservation('s', obs);
    await _reset('accepted-drop');
    await expectLater(
      repo!.chat('s', 'hi').toList().timeout(const Duration(seconds: 20)),
      throwsA(anything),
    );
    final l = await _ledger();
    expect(l['chatPosts'], 1); // the POST LANDED — a retry could duplicate
    expect(l['acceptedRuns'], 0);
    expect(obs.neverDispatched, isFalse); // THE red line on Web
    expect(obs.stage, TransportStage.dispatchInvoked); // no headers ever
  });

  test('B-cors preflight denied: zero chat POSTs server-side, yet the '
      'client (fetch was invoked) still never claims "not dispatched"',
      () async {
    if (!await skipUnlessUp()) return;
    repo = HermesRepository(base, 'k');
    final obs = DispatchObservation();
    repo!.stageChatObservation('s', obs);
    await _reset('cors-preflight-deny');
    // Chrome CACHES successful preflights per URL: use a never-preflighted
    // stream URL so the OPTIONS actually hits this (denying) server.
    final freshSid = 'deny-${DateTime.now().microsecondsSinceEpoch}';
    await expectLater(
      repo!
          .chat(freshSid, 'hi')
          .toList()
          .timeout(const Duration(seconds: 20)),
      throwsA(anything),
    );
    final l = await _ledger();
    expect(l['options'], greaterThanOrEqualTo(1)); // preflight was SEEN
    expect(l['chatPosts'], 0); // and the browser never sent the POST
    expect(obs.neverDispatched, isFalse); // fetch was invoked regardless
  });

  test('B-cors response denied: the POST REACHED the server even though '
      'the browser refuses to read the headerless response', () async {
    if (!await skipUnlessUp()) return;
    repo = HermesRepository(base, 'k');
    final obs = DispatchObservation();
    repo!.stageChatObservation('s', obs);
    await _reset('cors-response-deny');
    await expectLater(
      repo!.chat('s', 'hi').toList().timeout(const Duration(seconds: 20)),
      throwsA(anything),
    );
    final l = await _ledger();
    expect(l['chatPosts'], 1); // mutation happened; UI may NOT retry blindly
    expect(obs.neverDispatched, isFalse);
    expect(obs.stage, TransportStage.dispatchInvoked); // headers unreadable
  });

  test('B-headers-hang: headers never arrive -> stage stays dispatchInvoked, '
      'cancelStream ends it, the ledger still shows exactly one POST',
      () async {
    if (!await skipUnlessUp()) return;
    repo = HermesRepository(base, 'k');
    final obs = DispatchObservation();
    repo!.stageChatObservation('s', obs);
    await _reset('headers-hang');
    final events = <SseEvent>[];
    final done = Completer<Object?>();
    final sub = repo!
        .chat('s', 'hi')
        .listen(
          events.add,
          onError: (Object e) {
            if (!done.isCompleted) done.complete(e);
          },
          onDone: () {
            if (!done.isCompleted) done.complete(null);
          },
        );
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(events, isEmpty); // nothing was ever parsed
    expect(obs.stage, TransportStage.dispatchInvoked); // no headers
    expect(obs.neverDispatched, isFalse);
    // The app's honest "end waiting" cut FIRST: aborting the fetch is what
    // unwinds the generator (a bare subscription.cancel would deadlock on
    // the never-returning response await).
    repo!.cancelStream('s');
    await done.future.timeout(const Duration(seconds: 10));
    await sub.cancel();
    final l = await _ledger();
    expect(l['chatPosts'], 1); // one POST, no phantom second send
  });
}
