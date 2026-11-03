/// Browser bridge socket: no header can ride the upgrade, so the key buys a
/// single-use ticket over HTTP first (gateway_ws_ticket.dart). Liveness is the
/// bridge's own keepalive ping, which the browser answers by itself.
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import 'gateway_ws_socket.dart';
import 'gateway_ws_ticket.dart';

const supported = true;

class _WebWsSocket implements WsSocket {
  _WebWsSocket(this._ws) {
    _ws.onopen = ((web.Event _) {
      if (!_opened.isCompleted) _opened.complete();
    }).toJS;
    // A refused upgrade surfaces as error + close with no status to read.
    _ws.onerror = ((web.Event _) => _failOpen()).toJS;
    _ws.onmessage = ((web.MessageEvent e) {
      final data = e.data;
      if (data.isA<JSString>() && !_messages.isClosed) {
        _messages.add((data as JSString).toDart);
      }
    }).toJS;
    _ws.onclose = ((web.CloseEvent _) {
      _failOpen();
      if (!_messages.isClosed) unawaited(_messages.close());
    }).toJS;
  }

  final web.WebSocket _ws;
  final _opened = Completer<void>();
  final _messages = StreamController<String>();

  void _failOpen() {
    if (!_opened.isCompleted) {
      _opened.completeError(StateError('bridge socket did not open'));
    }
  }

  @override
  Stream<String> get messages => _messages.stream;

  @override
  void send(String text) => _ws.send(text.toJS);

  @override
  Future<void> close([int code = 1000]) async {
    try {
      _ws.close(code);
    } catch (_) {
      // Already closed.
    }
  }
}

/// Open a browser socket on [url] (its ticket included); fails when the
/// upgrade does not open.
Future<WsSocket> openBrowserSocket(Uri url) async {
  final socket = _WebWsSocket(web.WebSocket(url.toString()));
  try {
    await socket._opened.future.timeout(const Duration(seconds: 10));
  } catch (_) {
    await socket.close();
    rethrow;
  }
  return socket;
}

Future<WsSocket> connect(Uri url, String key) async {
  final client = http.Client();
  try {
    return await connectWithTicket(
      url,
      key,
      client: client,
      open: openBrowserSocket,
    );
  } finally {
    client.close();
  }
}
