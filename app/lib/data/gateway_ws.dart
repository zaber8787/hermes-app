/// TASK-WSAPP §1: JSON-RPC over WebSocket onto the app-facing bridge
/// (compat/wsbridge.py), which relays an allowlisted method set to the
/// gateway's ticketed `/api/ws` (PLAN-WSATTACH).
///
/// One [GatewayWs] owns one bridge connection: request/response pairing by
/// id, `method:"event"` frames decoded into [WsEvent]s
/// (gateway/session_events.py:37-75: type, session_id, payload,
/// replay_epoch, seq plus the execution stamp), reconnect with backoff, and
/// after every reconnect a `session.resume` replay of every session this
/// client attached, because a write on a connection that never resumed the
/// session is `permission_denied` (gateway/session_controls.py:752-753).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/message.dart' show Json;
import 'gateway_ws_socket.dart';

export '../models/message.dart' show Json;
export 'gateway_ws_socket.dart' show WsSocket, WsConnector, wsSupported;

/// The bridge (or the owner behind it) answered a JSON-RPC error. [reason]
/// is the structured `data.reason` when present, else the message: the
/// bridge refuses non-allowlisted writes with `session_not_allowlisted`.
class GatewayRpcError implements Exception {
  const GatewayRpcError(this.code, this.message, [this.data]);
  final int? code;
  final String message;
  final Json? data;
  String get reason => (data?['reason'] as String?) ?? message;

  /// The bridge lost the answer with its upstream: the request may or may
  /// not have landed (wsbridge.py `outcome: unknown`).
  bool get outcomeUnknown =>
      data?['outcome'] == 'unknown' ||
      reason == 'upstream_unavailable' ||
      reason == 'upstream_disconnected' ||
      reason == 'upstream_timeout';

  @override
  String toString() => 'GatewayRpcError($code, $reason)';
}

/// No usable bridge link right now (never connected, dropped, or the
/// gateway behind the bridge is reconnecting). A request that failed this
/// way may have reached the server only when [outcomeUnknown] is true.
class WsUnavailable implements Exception {
  const WsUnavailable({this.outcomeUnknown = false});
  final bool outcomeUnknown;
  @override
  String toString() => 'WsUnavailable(outcomeUnknown: $outcomeUnknown)';
}

/// One `method:"event"` frame. [admissionId]/[executionGeneration] come from
/// the execution stamp the owner merges into params
/// (gateway/session_authority.py:1089-1091).
class WsEvent {
  const WsEvent({
    required this.type,
    required this.sessionId,
    this.payload = const {},
    this.replayEpoch,
    this.seq,
    this.admissionId,
    this.executionGeneration,
  });
  final String type, sessionId;
  final Json payload;
  final String? replayEpoch;
  final int? seq;
  final String? admissionId;
  final int? executionGeneration;

  static WsEvent? fromParams(Object? raw) {
    if (raw is! Map) return null;
    final params = Map<String, dynamic>.from(raw);
    final type = params['type'];
    final sid = params['session_id'];
    if (type is! String || sid is! String) return null;
    final payload = params['payload'];
    return WsEvent(
      type: type,
      sessionId: sid,
      payload: payload is Map ? Map<String, dynamic>.from(payload) : const {},
      replayEpoch: params['replay_epoch']?.toString(),
      seq: switch (params['seq']) {
        final num n => n.toInt(),
        _ => null,
      },
      admissionId:
          (params['admission_id'] ??
                  (payload is Map ? payload['admission_id'] : null))
              ?.toString(),
      executionGeneration: switch (params['execution_generation']) {
        final int g => g,
        _ => null,
      },
    );
  }
}

/// What the last `session.resume` (or the bridge's replayed resume) said
/// about one session (gateway/session_controls.py:636-648).
class ResumeState {
  const ResumeState({
    required this.requestedId,
    required this.sessionId,
    this.executionGeneration,
    this.lastSequence,
    this.replayEpoch,
    this.running = false,
    this.pending = 0,
    this.messageCount,
  });
  final String requestedId;

  /// The id the owner answered with (a messaging continuation maps to its
  /// lineage root); events name this id.
  final String sessionId;
  final int? executionGeneration;
  final int? lastSequence;
  final String? replayEpoch;
  final bool running;

  /// Admissions still waiting in the owner's FIFO.
  final int pending;
  final int? messageCount;

  factory ResumeState.fromResult(String requested, Json r) => ResumeState(
    requestedId: requested,
    sessionId: (r['session_id'] as String?) ?? requested,
    executionGeneration: switch (r['execution_generation']) {
      final int g => g,
      _ => null,
    },
    lastSequence: switch (r['last_sequence']) {
      final num n => n.toInt(),
      _ => null,
    },
    replayEpoch: r['replay_epoch']?.toString(),
    running: r['running'] == true,
    pending: switch (r['pending']) {
      final List p => p.length,
      _ => 0,
    },
    messageCount: switch (r['messages']) {
      final List m => m.length,
      _ => (r['message_count'] as num?)?.toInt(),
    },
  );
}

enum WsLinkState { idle, connecting, connected, disconnected }

class GatewayWs extends ChangeNotifier {
  GatewayWs({
    required this.url,
    required this.apiKey,
    WsConnector? connector,
    this.backoff = const [
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
    ],
    this.callTimeout = const Duration(seconds: 30),
    Future<void> Function(Duration)? wait,
  }) : _connector = connector ?? defaultWsConnector,
       _wait = wait ?? ((d) => Future<void>.delayed(d));

  final Uri url;
  final String apiKey;
  final List<Duration> backoff;
  final Duration callTimeout;
  final WsConnector _connector;
  final Future<void> Function(Duration) _wait;

  WsLinkState _state = WsLinkState.idle;
  WsLinkState get state => _state;

  /// True only while the socket is open AND the bridge's upstream is ready:
  /// during a `bridge.upstream: reconnecting` stretch writes would only wait
  /// and then answer `upstream_unavailable`, so callers queue instead.
  bool get connected => _state == WsLinkState.connected && _upstreamReady;
  bool _upstreamReady = false;

  WsSocket? _socket;
  bool _disposed = false;
  bool _started = false;
  int _nextId = 0;
  final _pending = <int, Completer<Json>>{};
  final _events = StreamController<WsEvent>.broadcast();
  final _links = StreamController<bool>.broadcast();

  /// requested id -> last resume answer; replayed in insertion order after
  /// every reconnect.
  final _attached = <String, ResumeState>{};

  /// resolved id -> newest execution generation seen (resume or event stamp).
  final _generation = <String, int>{};

  Stream<WsEvent> get events => _events.stream;

  /// `true` each time the link becomes usable (after the resume replay),
  /// `false` each time it stops being usable.
  Stream<bool> get linkChanges => _links.stream;

  ResumeState? resumed(String sid) => _attached[sid];
  String resolvedId(String sid) => _attached[sid]?.sessionId ?? sid;
  int? generation(String sid) => _generation[resolvedId(sid)];

  /// Start the link loop once; later calls are no-ops. Returns immediately.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    unawaited(_loop());
  }

  Future<void> _loop() async {
    var attempt = 0;
    while (!_disposed) {
      _setState(WsLinkState.connecting);
      WsSocket? socket;
      try {
        socket = await _connector(url, apiKey);
      } catch (_) {
        socket = null;
      }
      if (_disposed) {
        await socket?.close();
        return;
      }
      if (socket != null) {
        attempt = 0;
        _socket = socket;
        _upstreamReady = true;
        final done = Completer<void>();
        final sub = socket.messages.listen(
          _onFrame,
          onError: (_) {
            if (!done.isCompleted) done.complete();
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
        _setState(WsLinkState.connected, announce: false);
        await _replayResumes();
        if (identical(_socket, socket) && !_disposed) _announce(connected);
        await done.future;
        await sub.cancel();
        _socket = null;
        _failPending(const WsUnavailable(outcomeUnknown: true));
        if (_disposed) return;
        _setState(WsLinkState.disconnected);
      } else {
        _setState(WsLinkState.disconnected);
      }
      await _wait(
        backoff[attempt < backoff.length ? attempt : backoff.length - 1],
      );
      attempt++;
    }
  }

  void _setState(WsLinkState next, {bool announce = true}) {
    if (_state == next) return;
    final was = connected;
    _state = next;
    if (announce && was != connected) _announce(connected);
    if (!_disposed) notifyListeners();
  }

  void _announce(bool usable) {
    if (!_links.isClosed) _links.add(usable);
    if (!_disposed) notifyListeners();
  }

  Future<void> _replayResumes() async {
    for (final requested in List.of(_attached.keys)) {
      if (_disposed || _socket == null) return;
      try {
        await resume(requested);
      } on GatewayRpcError catch (e) {
        // Deleted, superseded or no longer readable: stop replaying it.
        if (!e.outcomeUnknown) _attached.remove(requested);
      } catch (_) {
        return; // the link dropped mid-replay; the next connect replays again
      }
    }
  }

  void _failPending(Object error) {
    final waiting = List.of(_pending.values);
    _pending.clear();
    for (final c in waiting) {
      if (!c.isCompleted) c.completeError(error);
    }
  }

  void _onFrame(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final frame = Map<String, dynamic>.from(decoded);
    final method = frame['method'];
    if (method is String) {
      _onNotification(method, frame['params']);
      return;
    }
    final id = frame['id'];
    if (id is! int) return;
    final waiter = _pending.remove(id);
    if (waiter == null || waiter.isCompleted) return;
    final error = frame['error'];
    if (error is Map) {
      final data = error['data'];
      waiter.completeError(
        GatewayRpcError(
          (error['code'] as num?)?.toInt(),
          (error['message'] as String?) ?? 'error',
          data is Map ? Map<String, dynamic>.from(data) : null,
        ),
      );
      return;
    }
    final result = frame['result'];
    waiter.complete(
      result is Map ? Map<String, dynamic>.from(result) : <String, dynamic>{},
    );
  }

  void _onNotification(String method, Object? params) {
    switch (method) {
      case 'event':
        final event = WsEvent.fromParams(params);
        if (event == null) return;
        final g = event.executionGeneration;
        if (g != null) _generation[event.sessionId] = g;
        if (!_events.isClosed) _events.add(event);
      case 'bridge.upstream':
        // The gateway behind the bridge restarted or drained (1013): the
        // bridge redials and replays resumes itself (wsbridge.py upstream()).
        final ready = params is Map && params['state'] == 'ready';
        final was = connected;
        _upstreamReady = ready;
        if (was != connected) _announce(connected);
      case 'bridge.resumed':
        if (params is! Map) return;
        final sid = params['session_id'];
        final result = params['result'];
        if (sid is! String || result is! Map) return;
        _recordResume(sid, Map<String, dynamic>.from(result), replayed: true);
      case 'bridge.resume_failed':
        if (params is! Map) return;
        final sid = params['session_id'];
        if (sid is String) {
          _attached.removeWhere((k, v) => k == sid || v.sessionId == sid);
        }
    }
  }

  void _recordResume(String requested, Json result, {bool replayed = false}) {
    if (replayed) {
      // The bridge names the resolved id; keep the app's own key for it.
      final key = _attached.entries
          .firstWhere(
            (e) => e.value.sessionId == requested || e.key == requested,
            orElse: () => MapEntry(
              requested,
              ResumeState(requestedId: requested, sessionId: requested),
            ),
          )
          .key;
      requested = key;
    }
    final state = ResumeState.fromResult(requested, result);
    _attached[requested] = state;
    final g = state.executionGeneration;
    if (g != null) _generation[state.sessionId] = g;
  }

  /// One JSON-RPC request. Throws [WsUnavailable] when no socket is open (or
  /// it drops before the answer) and [GatewayRpcError] for an error answer.
  Future<Json> call(String method, Json params, {Duration? timeout}) {
    final socket = _socket;
    if (socket == null || _disposed) {
      return Future.error(const WsUnavailable());
    }
    final id = ++_nextId;
    final waiter = Completer<Json>();
    _pending[id] = waiter;
    try {
      socket.send(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': params,
        }),
      );
    } catch (_) {
      _pending.remove(id);
      return Future.error(const WsUnavailable());
    }
    return waiter.future.timeout(
      timeout ?? callTimeout,
      onTimeout: () {
        _pending.remove(id);
        throw const WsUnavailable(outcomeUnknown: true);
      },
    );
  }

  /// `session.resume`, remembered for the reconnect replay.
  Future<ResumeState> resume(String sid) async {
    final result = await call('session.resume', {'session_id': sid});
    _recordResume(sid, result);
    return _attached[sid]!;
  }

  /// Resume [sid] on this connection unless it already is.
  Future<ResumeState> ensureResumed(String sid) async =>
      _attached[sid] ?? await resume(sid);

  @override
  void dispose() {
    _disposed = true;
    final socket = _socket;
    _socket = null;
    _failPending(const WsUnavailable());
    unawaited(socket?.close());
    unawaited(_events.close());
    unawaited(_links.close());
    super.dispose();
  }
}
