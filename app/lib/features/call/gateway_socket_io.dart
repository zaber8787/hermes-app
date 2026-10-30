/// dart:io WebSocket impl of the call socket (PLAN-VOICEUI §4.8, the
/// transport.dart:1 conditional-import pattern). Android ships TLS with the
/// system trust store, which carries the tailnet certificate (§4.1 point 4).
/// No socket-level pingInterval: the controller pings at the app layer so
/// the RTT lands in the §5.3 stats line instead of a hidden frame (D22).
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'gateway_socket.dart';

class IoGatewaySocket implements GatewaySocket {
  IoGatewaySocket(this._ws);

  final WebSocket _ws;

  @override
  Stream<Object> get messages => _ws.map<Object>(
      (m) => m is String ? m : Uint8List.fromList(m as List<int>));

  @override
  void sendText(String s) => _ws.add(s);

  @override
  void sendBytes(Uint8List b) => _ws.add(b);

  @override
  Future<void> close([int code = 1000, String reason = '']) =>
      _ws.close(code, reason);

  @override
  int? get closeCode => _ws.closeCode;
}

Future<GatewaySocket> connect(Uri url) async {
  final ws = await WebSocket.connect(url.toString())
      .timeout(const Duration(seconds: 5));
  return IoGatewaySocket(ws);
}
