/// Transport seam for [GatewayWs] (TASK-WSAPP §1), same conditional-import
/// pattern as features/call/gateway_socket.dart. The bridge authenticates
/// the upgrade with `Authorization: Bearer <API_SERVER_KEY>`
/// (compat/wsbridge.py `Bridge.authorize`), which only dart:io can send: a
/// browser WebSocket cannot set headers, so on Web [wsSupported] is false
/// and every session stays on the HTTP route.
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

typedef WsConnector = Future<WsSocket> Function(Uri url, String key);

WsConnector get defaultWsConnector => impl.connect;

/// Whether this platform can open an authenticated bridge socket at all.
bool get wsSupported => impl.supported;
