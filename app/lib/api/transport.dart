import 'transport_io.dart' if (dart.library.js_interop) 'transport_web.dart' as impl;

/// Platform-neutral HTTP plumbing the repository speaks through, so the same
/// code runs on dart:io devices and in the browser (fetch). Kept deliberately
/// narrow: one send call, one response shape.
class PortResponse {
  PortResponse(this.statusCode, this.headers, this.stream);
  final int statusCode;
  final Map<String, String> headers; // lowercase keys
  final Stream<List<int>> stream;

  String? get mimeType => headers['content-type']?.split(';').first.trim();
}

/// AUDIT-10: the application-layer deadline fired while waiting for response
/// headers, and the underlying request was genuinely cancelled. The
/// repository maps this to a distinguishable retry-able error.
class PortTimeout implements Exception {
  const PortTimeout();
  @override
  String toString() => 'PortTimeout(headers)';
}

/// Effectively "no application deadline" — used where the contract demands a
/// long budget (SSE streams / chat POST, contract §1 ≥600s), so headers-time
/// logic never shortens those paths.
const unboundedTimeout = Duration(days: 30);

abstract class HttpPort {
  /// [headersTimeout] is the deadline for receiving RESPONSE HEADERS (it
  /// starts with the request and ends on the first response byte; the body
  /// read has its own budget in the repository). `null` = the port default;
  /// pass [unboundedTimeout] on long-lived SSE/chat paths.
  Future<PortResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Stream<List<int>>? body,
    int? contentLength,
    Future<void>? abortTrigger,
    Duration? headersTimeout,
  });
  void close();
}

HttpPort newHttpPort() => impl.newPort();
