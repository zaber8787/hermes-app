/// dart:io bridge socket: the bearer key rides the upgrade request header.
library;

import 'dart:async';
import 'dart:io';

import 'gateway_ws_socket.dart';

const supported = true;

class _IoWsSocket implements WsSocket {
  _IoWsSocket(this._ws);
  final WebSocket _ws;

  @override
  Stream<String> get messages => _ws.where((m) => m is String).cast<String>();

  @override
  void send(String text) => _ws.add(text);

  @override
  Future<void> close([int code = 1000]) => _ws.close(code);
}

Future<WsSocket> connect(Uri url, String key) async {
  final ws = await WebSocket.connect(
    url.toString(),
    headers: {'Authorization': 'Bearer $key'},
  ).timeout(const Duration(seconds: 10));
  // App-level liveness: a wedged mobile socket must surface as a drop so
  // the link reconnects instead of waiting forever.
  ws.pingInterval = const Duration(seconds: 20);
  return _IoWsSocket(ws);
}
