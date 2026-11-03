// The real browser socket against a real compat/wsbridge.py. Without the
// fixture running these SKIP (never fail) — run it first:
//   PYTHONPATH=$HOME/.hermes/hermes-agent $HOME/.hermes/hermes-agent/.venv/bin/python \
//       ../tools/wsbridge_web_fixture.py
// then:  ../toolchain/flutter/bin/flutter test --no-pub --platform chrome \
//       test/browser/ws_ticket_web_test.dart
@TestOn('browser')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/data/gateway_ws_socket.dart';
import 'package:hermes_app/data/gateway_ws_socket_web.dart' as web_socket;
import 'package:http/http.dart' as http;

const _mintOrigin = 'http://127.0.0.1:18703';
const _bridgePort = 18702;
final _socketUrl = Uri.parse('ws://127.0.0.1:$_bridgePort/api/bridge/ws');

/// A ticket from the fixture's CORS side door: the test page is cross-origin
/// to the bridge, which rightly sends no CORS headers.
Future<String?> _ticket() async {
  try {
    final r = await http.post(Uri.parse('$_mintOrigin/mint'));
    return (jsonDecode(r.body) as Map)['ticket'] as String;
  } catch (_) {
    return null;
  }
}

Uri _withTicket(String t) => _socketUrl.replace(queryParameters: {'ticket': t});

void main() {
  test('platform flag: the browser can open the bridge', () {
    expect(wsSupported, isTrue);
  });

  test('a ticket opens a real socket and frames flow both ways', () async {
    final ticket = await _ticket();
    if (ticket == null) return markTestSkipped('fixture not running');
    final socket = await web_socket.openBrowserSocket(_withTicket(ticket));
    final first = socket.messages.first;
    socket.send('{"jsonrpc":"2.0","id":1,"method":"shell.exec","params":{}}');
    final frame = jsonDecode(await first.timeout(const Duration(seconds: 5)));
    expect(frame['id'], 1);
    expect(frame['error']['message'], 'method_not_found');
    await socket.close();
  });

  test('a spent ticket does not open, and the failure is seen', () async {
    final ticket = await _ticket();
    if (ticket == null) return markTestSkipped('fixture not running');
    final socket = await web_socket.openBrowserSocket(_withTicket(ticket));
    await socket.close();
    await expectLater(
      web_socket.openBrowserSocket(_withTicket(ticket)),
      throwsA(isA<StateError>()),
    );
  });

  test('messages ends when the socket closes', () async {
    final ticket = await _ticket();
    if (ticket == null) return markTestSkipped('fixture not running');
    final socket = await web_socket.openBrowserSocket(_withTicket(ticket));
    final done = socket.messages.drain<void>();
    await socket.close();
    await done.timeout(const Duration(seconds: 5));
  });

  test('a mint the browser may not read is transient', () async {
    if (await _ticket() == null) return markTestSkipped('fixture not running');
    await expectLater(
      web_socket.connect(_socketUrl, 'wrong-key'),
      throwsA(
        isA<WsBridgeRefused>().having((e) => e.transient, 'transient', true),
      ),
    );
  });
}
