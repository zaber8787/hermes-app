/// Transport seam for the voice call (PLAN-VOICEUI §4.8). The controller
/// only ever sees this interface, which is what makes it unit-testable
/// with a fake socket. Messages arrive as ONE stream: `String` = JSON
/// events, `Uint8List` = raw PCM frames (§3.1 — the socket is a single
/// ordered bytestream, so frame/event interleaving is preserved).
library;

import 'dart:typed_data';

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

// TODO(call7b): defaultGatewayConnector — conditional import of
// gateway_socket_io.dart (dart:io WebSocket, 5s connect timeout, no
// pingInterval: app-layer ping instead, §4.1/D22) and
// gateway_socket_web.dart (package:web WebSocket, binaryType
// 'arraybuffer'), following the transport.dart:1 import pattern.
