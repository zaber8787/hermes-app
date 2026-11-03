/// Transport seam for [GatewayWs] (TASK-WSAPP §1), same conditional-import
/// pattern as features/call/gateway_socket.dart. The bridge authenticates
/// the upgrade with `Authorization: Bearer <API_SERVER_KEY>` or a single-use
/// `?ticket=` (compat/wsbridge.py `Bridge.authorize`). dart:io sends the
/// header; a browser WebSocket cannot set headers, so Web mints a ticket
/// first (gateway_ws_ticket.dart).
library;

import 'gateway_ws_socket_io.dart'
    if (dart.library.js_interop) 'gateway_ws_socket_web.dart'
    as impl;

abstract class WsSocket {
  /// Text frames in wire order; completes when the socket closes.
  Stream<String> get messages;
  void send(String text);
  Future<void> close([int code = 1000]);
}

/// A ticket connector gave up on the bridge: [GatewayWs] may then stop
/// dialing and hand the sessions back to the HTTP route. [transient] marks a
/// mint that never got an HTTP answer (offline looks the same as a blocked
/// request), which says nothing about a link that has already worked.
class WsBridgeRefused implements Exception {
  const WsBridgeRefused(this.reason, {this.transient = false});
  final String reason;
  final bool transient;
  @override
  String toString() => 'WsBridgeRefused($reason, transient: $transient)';
}

typedef WsConnector = Future<WsSocket> Function(Uri url, String key);

WsConnector get defaultWsConnector => impl.connect;

/// Whether this platform can open an authenticated bridge socket at all.
bool get wsSupported => impl.supported;
