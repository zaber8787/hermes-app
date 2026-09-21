import 'dart:async';
import 'dart:io';

import 'transport.dart';

class IoHttpPort implements HttpPort {
  IoHttpPort({
    Duration connectTimeout = const Duration(seconds: 20),
    Duration headersTimeout = const Duration(seconds: 15),
  }) {
    _client.connectionTimeout = connectTimeout;
    _headersTimeout = headersTimeout;
  }
  final HttpClient _client = HttpClient();
  // AUDIT-10: application deadline for RESPONSE HEADERS, distinct from the
  // connect timeout above and the body-read budget in the repository. Long
  // SSE/chat requests override this per-call with [unboundedTimeout].
  late final Duration _headersTimeout;

  @override
  Future<PortResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Stream<List<int>>? body,
    int? contentLength,
    Future<void>? abortTrigger,
    Duration? headersTimeout,
  }) async {
    final request = await _client.openUrl(method, uri);
    request.followRedirects = false; // Never forward credentials cross-host.
    if (contentLength != null) request.contentLength = contentLength;
    headers.forEach((k, v) => request.headers.set(k, v));
    final deadline = headersTimeout ?? _headersTimeout;
    Future<HttpClientResponse> closing;
    if (body != null) {
      // close() before addStream finishes throws; chain the two instead.
      closing = request
          .addStream(
            body.timeout(const Duration(seconds: 60), onTimeout: (s) => s.close()),
          )
          .then((_) => request.close());
    } else {
      closing = request.close();
    }
    final HttpClientResponse response;
    try {
      // AUDIT-10: bound the wait for headers and ABORT the socket on expiry,
      // so a half-dead Tailscale peer can't leave the request spinning.
      response = await closing.timeout(deadline);
    } on TimeoutException {
      try {
        request.abort(const PortTimeout());
      } catch (_) {}
      throw const PortTimeout();
    }
    if (abortTrigger != null) {
      // detachSocket+destroy is the only dart:io way to cut a live response.
      unawaited(abortTrigger.then((_) async {
        try {
          (await response.detachSocket()).destroy();
        } catch (_) {}
      }));
    }
    final flat = <String, String>{};
    response.headers.forEach((name, values) => flat[name] = values.join(','));
    return PortResponse(response.statusCode, flat, response);
  }

  @override
  void close() => _client.close(force: true);
}

HttpPort newPort() => IoHttpPort();
