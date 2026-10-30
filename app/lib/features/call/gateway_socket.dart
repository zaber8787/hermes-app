/// Transport seam for the voice call (PLAN-VOICEUI §4.8). The controller
/// only ever sees this interface, which is what makes it unit-testable
/// with a fake socket. Messages arrive as ONE stream: `String` = JSON
/// events, `Uint8List` = raw PCM frames (§3.1 — the socket is a single
/// ordered bytestream, so frame/event interleaving is preserved).
library;

import 'dart:typed_data';

import 'gateway_socket_io.dart'
    if (dart.library.js_interop) 'gateway_socket_web.dart' as impl;

abstract class GatewaySocket {
  /// Interleaved text and binary frames in wire order.
  Stream<Object> get messages;

  void sendText(String s);
  void sendBytes(Uint8List b);

  /// [close] requests a close with the given code (§3.3); resolves once
  /// the socket is fully closed.
  Future<void> close([int code = 1000, String reason = '']);

  /// The close code observed, or null while open / closed by the peer
  /// without a recognisable code.
  int? get closeCode;
}

typedef GatewayConnector = Future<GatewaySocket> Function(Uri url);

/// Platform default connector (§4.8): dart:io on Android/desktop, the
/// browser WebSocket on Web. 5s connect timeout both sides; no socket
/// pingInterval — the controller pings at the app layer (§4.1/D22).
GatewayConnector get defaultGatewayConnector => impl.connect;
