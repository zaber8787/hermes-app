/// Browser build: no way to put the bearer key on the upgrade request, so
/// the WS route is unavailable and sessions stay on HTTP.
library;

import 'gateway_ws_socket.dart';

const supported = false;

Future<WsSocket> connect(Uri url, String key) =>
    Future.error(UnsupportedError('bridge WebSocket needs request headers'));
