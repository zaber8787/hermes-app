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
    DispatchObservation? observation,
  }) async {
    // One abort gate: external cancel (detach) OR the headers deadline.
    final gate = Completer<void>();
    if (abortTrigger != null) {
      unawaited(
        abortTrigger.then((_) =>
            gate.isCompleted ? null : gate.complete()),
      );
    }
    // R3 §5.2 (Web): building the request can still fail SYNCHRONOUSLY
    // (bad URL/arguments) — provably before any fetch existed. Once the
    // request object exists, later failures (CORS, network, abort) are
    // post-invoke: fetch gives the client NO bytes-sent visibility, so
    // Web never claims a byte went out.
    final AbortableStreamedRequest request;
    try {
      request = AbortableStreamedRequest(method, uri, abortTrigger: gate.future);
    } on Object {
      observation?.failedBeforeDispatch('requestSetup');
      rethrow;
    }
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
    // JS timers are 32-bit: a budget above setTimeout's ~24.8-day ceiling
    // (unboundedTimeout is 30 days) would OVERFLOW and fire immediately —
    // which would abort a perfectly healthy SSE open as a fake "headers
    // timeout". Arm in legal chunks; the deadline only counts when the
    // cumulative wait has genuinely elapsed.
    const chunkMax = Duration(milliseconds: 0x7FFFFFF0);
    Timer? timer;
    void arm(Duration remaining) {
      timer = Timer(remaining > chunkMax ? chunkMax : remaining, () {
        if (remaining > chunkMax) {
          arm(remaining - chunkMax);
          return;
        }
        timedOut = true;
        if (!gate.isCompleted) gate.complete();
      });
    }

    arm(deadline);
    try {
      observation?.dispatchInvoked(); // synchronously BEFORE fetch
      final response = await _client.send(request);
      observation?.headersReceived(response.statusCode); // before any body
      return PortResponse(
        response.statusCode,
        response.headers,
        response.stream,
      );
    } on RequestAbortedException {
      if (timedOut) throw const PortTimeout();
      rethrow;
    } finally {
      timer?.cancel(); // headers are in: the body budget is the reader's now.
    }
  }

  @override
  void close() => _client.close();
}

HttpPort newPort() => WebHttpPort();
