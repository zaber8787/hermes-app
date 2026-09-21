import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/http.dart' show AbortableStreamedRequest, RequestAbortedException;

import 'transport.dart';

/// Browser transport: fetch under the hood (package:http's browser client),
/// with AbortController wiring so cancelStream() can cut a live SSE.
class WebHttpPort implements HttpPort {
  WebHttpPort({this.headersTimeout = const Duration(seconds: 15)});
  final http.Client _client = http.Client();
  // AUDIT-10: fetch has no metadata deadline of its own; abort the request
  // when the headers deadline expires (long SSE/chat paths opt out per-call).
  final Duration headersTimeout;

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
    // One abort gate: external cancel (detach) OR the headers deadline.
    final gate = Completer<void>();
    if (abortTrigger != null) {
      unawaited(
        abortTrigger.then((_) =>
            gate.isCompleted ? null : gate.complete()),
      );
    }
    final request =
        AbortableStreamedRequest(method, uri, abortTrigger: gate.future);
    request.headers.addAll(headers);
    if (contentLength != null) request.contentLength = contentLength;
    if (body != null) {
      // fetch buffers the request body; drain the stream into it.
      unawaited(() async {
        try {
          await for (final chunk in body) {
            request.sink.add(chunk);
          }
          await request.sink.close();
        } catch (_) {
          // Aborted mid-drain (detach/timeout): the sink is already dead.
        }
      }());
    } else {
      request.sink.close();
    }
    var timedOut = false;
    final deadline = headersTimeout ?? this.headersTimeout;
    final timer = Timer(deadline, () {
      timedOut = true;
      if (!gate.isCompleted) gate.complete();
    });
    try {
      final response = await _client.send(request);
      return PortResponse(
        response.statusCode,
        response.headers,
        response.stream,
      );
    } on RequestAbortedException {
      if (timedOut) throw const PortTimeout();
      rethrow;
    } finally {
      timer.cancel(); // headers are in: the body budget is the reader's now.
    }
  }

  @override
  void close() => _client.close();
}

HttpPort newPort() => WebHttpPort();
