/// The browser's way onto the bridge: `GET /bridge/ticket` with the bearer
/// key, then upgrade with the single-use `?ticket=` (compat/wsbridge.py
/// `TicketStore`). Platform-neutral so the mint/retry rules run under a fake
/// client; gateway_ws_socket_web.dart supplies the real socket.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'gateway_ws_socket.dart';

const _wsPath = '/api/bridge/ws';
const _ticketPath = '/bridge/ticket';  // the bridge's own path; a Serve mount in
// front of it STRIPS its prefix before forwarding, so the public URL is
// '$mount$_ticketPath' — the mount appears twice: once for the proxy, once
// for the bridge. Dropping it once (68ade6d) made the mint arrive as
// '/ticket' and 404; minting straight off a direct bridge URL still works
// because there the path already is the bridge's own.
const _mintTimeout = Duration(seconds: 10);

/// The ticket endpoint beside [wsUrl], same host and mount; null for a URL
/// that does not name the bridge's socket path.
Uri? ticketEndpoint(Uri wsUrl) {
  if (!wsUrl.path.endsWith(_wsPath)) return null;
  final mount = wsUrl.path.substring(0, wsUrl.path.length - _wsPath.length);
  return Uri(
    scheme: wsUrl.scheme == 'wss' ? 'https' : 'http',
    host: wsUrl.host,
    port: wsUrl.hasPort ? wsUrl.port : null,
    path: '$mount$_ticketPath',
  );
}

class _MintRejected implements Exception {
  const _MintRejected();
}

Future<String> _mint(http.Client client, Uri endpoint, String key) async {
  final http.Response response;
  try {
    response = await client
        .get(endpoint, headers: {'Authorization': 'Bearer $key'})
        .timeout(_mintTimeout);
  } catch (_) {
    throw const WsBridgeRefused('ticket_unreachable', transient: true);
  }
  if (response.statusCode == 401 || response.statusCode == 403) {
    throw const _MintRejected();
  }
  if (response.statusCode != 200) {
    throw WsBridgeRefused('ticket_status_${response.statusCode}');
  }
  try {
    final ticket = (jsonDecode(response.body) as Map)['ticket'];
    if (ticket is String && ticket.isNotEmpty) return ticket;
  } catch (_) {
    // Falls through to the refusal below.
  }
  throw const WsBridgeRefused('ticket_malformed');
}

/// Mint, then open. A rejection (401/403 on the mint, or an upgrade that did
/// not open: a browser hides the upgrade's status) mints once more with a
/// fresh ticket; the second one throws [WsBridgeRefused].
Future<WsSocket> connectWithTicket(
  Uri url,
  String key, {
  required http.Client client,
  required Future<WsSocket> Function(Uri) open,
}) async {
  final endpoint = ticketEndpoint(url);
  if (endpoint == null) throw const WsBridgeRefused('not_a_bridge_url');
  for (var attempt = 0; attempt < 2; attempt++) {
    final String ticket;
    try {
      ticket = await _mint(client, endpoint, key);
    } on _MintRejected {
      continue;
    }
    try {
      return await open(
        url.replace(
          queryParameters: {...url.queryParameters, 'ticket': ticket},
        ),
      );
    } catch (_) {
      continue;
    }
  }
  throw const WsBridgeRefused('ticket_rejected');
}
