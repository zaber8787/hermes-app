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

/// OFFLINE-SEND R3 §5.1: how far a single dispatch attempt demonstrably
/// got. STRICTLY monotonic per [DispatchObservation] — a reconnect, an
/// offline event, or a later exception can never rewind it. Stage evidence
/// (plus [DispatchObservation.failureKind]) is the ONLY source allowed to
/// classify an attempt's delivery; never an exception string and never a
/// connectivity hint.
enum TransportStage { prepared, dispatchInvoked, headersReceived, firstEvent }

/// One observer per DISPATCH ATTEMPT (OFFLINE-SEND R3 §5.1). Created by the
/// repository's `chat` caller (threaded per session through the port call)
/// and invoked by the transport/parser at exactly these points:
/// * [dispatchInvoked] — synchronously before the underlying client call
///   (browser fetch / dart:io openUrl). On Web this is all the client can
///   ever prove: fetch has no bytes-sent visibility.
/// * [headersReceived] — when the RESPONSE HEADERS are known (both 2xx and
///   error paths, BEFORE any body drain).
/// * [firstEvent] — the repository's SSE parser records the first parsed
///   event (heartbeat included; the parser, never the transport, speaks
///   SSE events).
/// * [failedBeforeDispatch] — ONLY when the underlying call is PROVEN never
///   invoked (a synchronous pre-call failure that could not have sent a
///   byte). A throw from the invoked call itself — connection refused, DNS,
///   CORS, abort — is NOT before-dispatch evidence: the stage then stays
///   dispatchInvoked and the delivery stays outcomeUnknown.
class DispatchObservation {
  TransportStage _stage = TransportStage.prepared;
  int? _httpStatus;
  String? _firstEventType;
  String? _failureKind;
  bool _neverDispatched = false;

  TransportStage get stage => _stage;

  /// First recorded response status; later records never overwrite it (a
  /// failed body drain must not erase a known status).
  int? get httpStatus => _httpStatus;
  String? get firstEventType => _firstEventType;
  String? get failureKind => _failureKind;

  /// True only while a structured before-dispatch failure stands AND no
  /// dispatch has since been invoked — the single structured fact allowed
  /// to classify a LIVE attempt as not dispatched.
  bool get neverDispatched =>
      _neverDispatched &&
      _stage.index < TransportStage.dispatchInvoked.index;

  /// Monotonic compare-and-set: advances the stage, never rewinds it.
  bool advance(TransportStage next) {
    if (next.index <= _stage.index) return false;
    _stage = next;
    return true;
  }

  void dispatchInvoked() => advance(TransportStage.dispatchInvoked);

  void headersReceived(int status) {
    _httpStatus ??= status;
    advance(TransportStage.headersReceived);
  }

  void firstEvent(String type) {
    _firstEventType ??= type;
    advance(TransportStage.firstEvent);
  }

  /// A no-op (never rewrites history) once dispatch was invoked: after the
  /// call started, nothing may claim "never sent".
  void failedBeforeDispatch(String failureKind) {
    if (_stage.index >= TransportStage.dispatchInvoked.index) return;
    _failureKind ??= failureKind;
    _neverDispatched = true;
  }
}

abstract class HttpPort {
  /// [headersTimeout] is the deadline for receiving RESPONSE HEADERS (it
  /// starts with the request and ends on the first response byte; the body
  /// read has its own budget in the repository). `null` = the port default;
  /// pass [unboundedTimeout] on long-lived SSE/chat paths.
  ///
  /// R3: [observation] is an OPTIONAL per-attempt dispatch evidence sink.
  /// Every implementation honors the same four points; a null observation
  /// costs nothing and changes no timing (610s body contract, 30-day
  /// headers, PortTimeout semantics all stay byte-compatible).
  Future<PortResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Stream<List<int>>? body,
    int? contentLength,
    Future<void>? abortTrigger,
    Duration? headersTimeout,
    DispatchObservation? observation,
  });
  void close();
}

HttpPort newHttpPort() => impl.newPort();
