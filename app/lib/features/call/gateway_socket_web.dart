/// Browser WebSocket impl of the call socket (PLAN-VOICEUI §4.8). The
/// browser API cannot set headers, which is why token + session_id ride in
/// the hello message (§3.2/D2). binaryType = 'arraybuffer' keeps binary PCM
/// frames as ArrayBuffer payloads; text frames stay JSON strings, both on
/// ONE stream so wire order is preserved (§3.1).
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'gateway_socket.dart';

class WebGatewaySocket implements GatewaySocket {
  WebGatewaySocket(this._ws);

  final web.WebSocket _ws;
  final _messages = StreamController<Object>();
  final _closed = Completer<void>();
  int? _closeCode;
  bool _opened = false;

  /// Wire the handlers before the (async) handshake resolves. [failure] is
  /// only ever used for the pre-open error path; post-open errors arrive as
  /// onclose with a code (§4.2's reconnect rows need the code, not a
  /// synthetic exception).
  void attach(void Function(Object) preOpenFailure) {
    _ws.binaryType = 'arraybuffer';
    _ws.onopen = ((web.Event _) {
      _opened = true;
      if (!_open.isCompleted) _open.complete();
    }).toJS;
    _ws.onerror = ((web.Event _) {
      if (!_opened && !_closed.isCompleted) {
        preOpenFailure(StateError('gateway socket open failed: ${_ws.url}'));
      }
    }).toJS;
    _ws.onmessage = ((web.MessageEvent e) {
      final data = e.data;
      if (data.isA<JSString>()) {
        _messages.add((data as JSString).toDart);
      } else if (data.isA<JSArrayBuffer>()) {
        _messages.add((data as JSArrayBuffer).toDart.asUint8List());
      } else if (data.isA<JSUint8Array>()) {
        _messages.add((data as JSUint8Array).toDart);
      }
    }).toJS;
    _ws.onclose = ((web.CloseEvent e) {
      _closeCode = e.code;
      if (!_closed.isCompleted) _closed.complete();
      if (!_messages.isClosed) _messages.close();
    }).toJS;
  }

  /// Completes once the socket has opened; errors (pre-open only) through
  /// the same future.
  Future<void> get opened => _open.future;
  final _open = Completer<void>();

  @override
  Stream<Object> get messages => _messages.stream;

  @override
  void sendText(String s) => _ws.send(s.toJS);

  @override
  void sendBytes(Uint8List b) => _ws.send(b.toJS);

  @override
  Future<void> close([int code = 1000, String reason = '']) {
    try {
      _ws.close(code, reason);
    } on Object {
      // Already CLOSED: close() on a dead socket is a no-op we never see.
    }
    return _closed.future;
  }

  @override
  int? get closeCode => _closeCode;
}

Future<GatewaySocket> connect(Uri url) async {
  final socket = WebGatewaySocket(web.WebSocket(url.toString()));
  socket.attach((e) {
    if (!socket._open.isCompleted) socket._open.completeError(e);
  });
  await socket.opened.timeout(const Duration(seconds: 5));
  return socket;
}
