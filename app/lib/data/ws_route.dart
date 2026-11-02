/// TASK-WSAPP §2/§3/§5: which sessions send over the bridge, and how one
/// WS turn looks to the chat controller.
///
/// Routing is allowlisted (主 Agent 回填 2): a session goes over WS only when
/// its source is a foreign surface (not `api_server`/`bot_room`) AND it is
/// listed in the app's direct-link allowlist, whose thread ids are the same
/// set as the bridge's `test_thread_ids`. Everything else, every
/// api_server session included, keeps the HTTP route untouched.
///
/// A WS turn is handed to the controller as the SAME session SSE vocabulary
/// the HTTP route streams (`message.started`, `assistant.delta`,
/// `tool.started`, `tool.completed`/`tool.failed`, `assistant.completed`,
/// `run.<status>`), projected from the owner's canonical events exactly the
/// way compat/crosssource.py `Follow.frames` projects them for the HTTP
/// cross-source route. One reducer (LiveTurn) and one settle path then
/// render running, finished and replayed turns identically on both routes.
library;

import 'dart:async';
import 'dart:convert';

import '../api/hermes_repository.dart';
import '../api/sse.dart';
import '../api/transport.dart';
import '../features/settings/local_store.dart';
import '../l10n/message_key.dart';
import 'gateway_ws.dart';
import 'ws_outbox.dart';

/// Sources that own their sessions on the HTTP API (never WS-routed).
const httpOwnedSources = {'api_server', 'bot_room'};

/// One allowlisted direct-link session: the Discord thread (as listed in
/// the bridge's `test_thread_ids`) and the session it maps to.
class WsDirectEntry {
  const WsDirectEntry(this.threadId, this.sessionId);
  final String threadId, sessionId;

  Json toJson() => {'thread': threadId, 'session': sessionId};

  static WsDirectEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final t = raw['thread'], s = raw['session'];
    if (t is! String || s is! String || t.isEmpty || s.isEmpty) return null;
    return WsDirectEntry(t, s);
  }

  /// Settings text form: one `<thread_id> <session_id>` pair per line.
  static List<WsDirectEntry>? parseLines(String text) {
    final out = <WsDirectEntry>[];
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final parts = line.split(RegExp(r'[\s,=:]+'));
      if (parts.length != 2 || parts.any((p) => p.isEmpty)) return null;
      out.add(WsDirectEntry(parts[0], parts[1]));
    }
    return out;
  }

  static String formatLines(List<WsDirectEntry> entries) =>
      entries.map((e) => '${e.threadId} ${e.sessionId}').join('\n');
}

/// `<base>/bridge/api/bridge/ws` on the server's own host, http(s) mapped to
/// ws(s); '' when [serverUrl] is not a usable http(s) URL.
String deriveBridgeUrl(String serverUrl) {
  final base = Uri.tryParse(serverUrl.trim());
  if (base == null || base.host.isEmpty) return '';
  final scheme = switch (base.scheme) {
    'https' => 'wss',
    'http' => 'ws',
    _ => '',
  };
  if (scheme.isEmpty) return '';
  final path = base.path.replaceFirst(RegExp(r'/+$'), '');
  return base
      .replace(scheme: scheme, path: '$path/bridge/api/bridge/ws')
      .toString();
}

/// A valid ws(s) bridge URL or null.
Uri? parseBridgeUrl(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'ws' && uri.scheme != 'wss') return null;
  if (uri.userInfo.isNotEmpty || uri.hasFragment) return null;
  return uri;
}

/// Project one owner event of THIS turn onto the session SSE vocabulary
/// (compat/crosssource.py `Follow.frames` + `_terminal`). [sid] is the id
/// the controller knows the session by; [messageId] names the turn's reply.
List<SseEvent> wsEventToSse(WsEvent e, String sid, String messageId) {
  SseEvent frame(String type, Json data) =>
      SseEvent(type, jsonEncode({'session_id': sid, ...data}));
  final p = e.payload;
  String? name() => (p['tool_name'] ?? p['name']) as String?;
  switch (e.type) {
    case 'message.delta':
      final text = p['text'];
      if (text is! String || text.isEmpty) return const [];
      return [
        frame('assistant.delta', {'message_id': messageId, 'delta': text}),
      ];
    case 'tool.start':
      return [
        frame('tool.started', {
          'message_id': messageId,
          'tool_name': name(),
          'preview': p['context'],
          'args': p['args'],
        }),
      ];
    case 'tool.complete':
      return [
        frame(p['is_error'] == true ? 'tool.failed' : 'tool.completed', {
          'message_id': messageId,
          'tool_name': name(),
          'preview': null,
          'args': p['args'],
        }),
      ];
    case 'message.complete':
      final content = p['text'] is String ? p['text'] as String : '';
      final status = p['status'];
      final terminal = switch (status) {
        'complete' => 'run.completed',
        'interrupted' => 'run.interrupted',
        'error' => 'run.failed',
        _ => p['outcome'] == 'cancelled' ? 'run.cancelled' : 'run.completed',
      };
      final closing = <String, dynamic>{
        'message_id': messageId,
        'messages': const [],
        'usage': const {},
        'runtime': const {},
      };
      if (terminal == 'run.failed') {
        final surface = p['error_surface'] is Map
            ? p['error_surface'] as Map
            : const {};
        closing['error'] =
            p['failure_reason'] ??
            p['warning'] ??
            surface['message'] ??
            'turn failed';
      }
      return [
        frame('assistant.completed', {
          'message_id': messageId,
          'content': content,
        }),
        frame(terminal, closing),
      ];
  }
  return const [];
}

/// What a WS steer did (§3).
enum WsSteerOutcome { queued, resubmitted, rejected }

/// The link could not carry a turn's submit: its text stays in the outbox
/// under [entry]'s key and goes out on the next flush. Not a failure, and
/// not delivered yet either: an unknown outcome resends the same key, which
/// the owner dedupes.
class WsQueued implements Exception {
  const WsQueued(this.entry);
  final WsOutboxEntry entry;
}

class WsRouter {
  WsRouter({
    required this.ws,
    required this.outbox,
    required Iterable<WsDirectEntry> allow,
    bool? supported,
    this.heartbeatEvery = const Duration(seconds: 20),
    this.quietCheckEvery = const Duration(minutes: 2),
  }) : allowed = {for (final e in allow) e.sessionId},
       supported = supported ?? wsSupported;

  /// No usable bridge (no URL, no key, or Web): routes nothing.
  WsRouter.disabled()
    : ws = null,
      outbox = null,
      allowed = const {},
      supported = false,
      heartbeatEvery = const Duration(seconds: 20),
      quietCheckEvery = const Duration(minutes: 2);

  final GatewayWs? ws;
  final WsOutbox? outbox;
  final Set<String> allowed;
  final bool supported;
  final Duration heartbeatEvery;

  /// The local heartbeat proves the link, not the turn: this long without a
  /// frame of the turn asks the owner whether anything still runs, so a lost
  /// `message.complete` ends in the read-only reconcile, not in a turn that
  /// looks alive forever.
  final Duration quietCheckEvery;

  StreamSubscription<WsRefusal>? _refusalSub;
  final _cancels = <String, Completer<void>>{};
  final _turnGeneration = <String, int>{};

  /// §2 + 回填 2: foreign surface AND allowlisted, on a platform that can
  /// open the bridge. An unknown source never routes (HTTP is the default).
  bool routes(String sid, String? source) =>
      supported &&
      ws != null &&
      source != null &&
      source.isNotEmpty &&
      !httpOwnedSources.contains(source) &&
      allowed.contains(sid);

  /// A new send must wait in the outbox: the link is down, or older sends
  /// of this session are still waiting (order never breaks).
  bool mustQueue(String sid) =>
      !(ws?.connected ?? false) || (outbox?.hasPending(sid) ?? false);

  /// Allowlisted at all, whatever the source says: such a controller watches
  /// the link and the outbox.
  bool listed(String sid) => supported && ws != null && allowed.contains(sid);

  /// Open the bridge link (idempotent).
  void start() => ws?.start();

  /// §4: park [text] until the link comes back.
  Future<WsOutboxEntry> queue(String sid, String text) async {
    final entry = await outbox!.enqueue(sid, text);
    unawaited(outbox!.flush()); // a no-op while the link is down
    return entry;
  }

  void cancel(String sid) {
    final c = _cancels.remove(sid);
    if (c != null && !c.isCompleted) c.complete();
  }

  /// The refusal the controller shows; status 4xx so the controller's
  /// rejected path settles it (draft kept, no recovery, no retry).
  static ApiException refusal(GatewayRpcError e) => switch (e.reason) {
    'session_not_allowlisted' => const ApiException.local(
      MessageKey.chatWsNotEnabled,
      status: 403,
    ),
    'session_superseded' => const ApiException.local(
      MessageKey.chatWsReadOnly,
      status: 409,
    ),
    _ => ApiException(e.reason, 409),
  };

  /// §2: one WS turn — outbox write, resume, `prompt.submit` keyed by the
  /// outbox entry, then this admission's events until `message.complete`.
  /// A link drop surfaces as [WsUnavailable]; the controller then
  /// reconciles from history. A submit the link could not carry throws
  /// [WsQueued]: the entry waits for the reconnect flush.
  Stream<SseEvent> turn(
    String sid,
    String text, {
    DispatchObservation? observation,
  }) async* {
    final ws = this.ws!, outbox = this.outbox!;
    final entry = await outbox.enqueue(sid, text, claim: true);
    final inbox = StreamController<Object>();
    const tick = #tick, down = #down, cancelled = #cancelled, idle = #idle;
    final eventSub = ws.events.listen(inbox.add);
    final linkSub = ws.linkChanges.listen((usable) {
      if (!usable) inbox.add(down);
    });
    final cancel = _cancels[sid] = Completer<void>();
    unawaited(
      cancel.future.then((_) {
        if (!inbox.isClosed) inbox.add(cancelled);
      }),
    );
    Timer? heartbeat;
    final messageId = 'msg_${entry.key}';
    try {
      observation?.dispatchInvoked();
      final WsDelivery delivery;
      try {
        delivery = await outbox.submit(entry);
      } on GatewayRpcError catch (e) {
        observation?.headersReceived(
          e.reason == 'session_not_allowlisted' ? 403 : 409,
        );
        throw refusal(e);
      } on WsUnavailable {
        throw WsQueued(entry);
      }
      final admitted = delivery.receipt['execution_generation'];
      if (admitted is int) _turnGeneration[sid] = admitted;
      observation?.firstEvent('message.started');
      yield SseEvent(
        'message.started',
        jsonEncode({
          'session_id': sid,
          'message': {'id': messageId, 'role': 'assistant'},
        }),
      );
      final admission = delivery.admissionId;
      if (admission == null || admission.isEmpty) {
        // No admission to follow: same handoff shape the HTTP bridge
        // answers, the controller reconciles from history.
        yield SseEvent('run.queued', jsonEncode({'session_id': sid}));
        return;
      }
      final resolved = ws.resolvedId(sid);
      heartbeat = Timer.periodic(heartbeatEvery, (_) {
        if (!inbox.isClosed) inbox.add(tick);
      });
      var lastFrame = DateTime.now();
      var checking = false;
      Future<void> checkQuiet() async {
        try {
          final state = await ws.resume(sid);
          if (!state.running && state.pending == 0 && !inbox.isClosed) {
            inbox.add(idle);
          }
        } catch (_) {
          // No answer is no evidence: the link watcher owns a real drop.
        }
        checking = false;
      }

      await for (final item in inbox.stream) {
        if (identical(item, cancelled) || identical(item, idle)) return;
        if (identical(item, down)) {
          throw const WsUnavailable(outcomeUnknown: true);
        }
        if (identical(item, tick)) {
          yield const SseEvent('heartbeat', '{}');
          if (!checking &&
              DateTime.now().difference(lastFrame) >= quietCheckEvery) {
            checking = true;
            lastFrame = DateTime.now();
            unawaited(checkQuiet());
          }
          continue;
        }
        final e = item as WsEvent;
        if (e.sessionId != resolved && e.sessionId != sid) continue;
        if (e.admissionId != admission) continue;
        lastFrame = DateTime.now();
        final g = e.executionGeneration;
        if (g != null) _turnGeneration[sid] = g;
        for (final frame in wsEventToSse(e, sid, messageId)) {
          yield frame;
        }
        if (e.type == 'message.complete') return;
      }
    } finally {
      heartbeat?.cancel();
      await eventSub.cancel();
      await linkSub.cancel();
      if (identical(_cancels[sid], cancel)) _cancels.remove(sid);
      _turnGeneration.remove(sid);
      unawaited(inbox.close());
    }
  }

  /// The execution generation a control verb must name: this turn's, else
  /// the newest the link has seen, else a fresh resume's answer.
  Future<int> _generationFor(String sid) async {
    final ws = this.ws!;
    await ws.ensureResumed(sid);
    final generation = _turnGeneration[sid] ?? ws.generation(sid);
    if (generation != null) return generation;
    final fresh = (await ws.resume(sid)).executionGeneration;
    if (fresh == null) throw const GatewayRpcError(null, 'execution_not_ready');
    return fresh;
  }

  /// §3: `session.steer` with the running generation; a `rejected` +
  /// `delivered:false` answer (no live agent took it,
  /// gateway/session_busy_controls.py:204-210) goes in as the next prompt.
  /// A link that is down before the steer left also queues it as the next
  /// prompt (§4); a lost answer does not, because a steer has no idempotency
  /// key and resending could deliver it twice.
  Future<WsSteerOutcome> steer(String sid, String text) async {
    final ws = this.ws!;
    if (!ws.connected) {
      await queue(sid, text);
      return WsSteerOutcome.resubmitted;
    }
    final generation = await _generationFor(sid);
    final r = await ws.call('session.steer', {
      'session_id': sid,
      'text': text,
      'execution_generation': generation,
    });
    if (r['status'] == 'queued' || r['status'] == 'redirected') {
      return WsSteerOutcome.queued;
    }
    if (r['status'] == 'rejected' && r['delivered'] == false) {
      await queue(sid, text);
      return WsSteerOutcome.resubmitted;
    }
    return WsSteerOutcome.rejected;
  }

  /// `session.interrupt` for the running generation; the turn's own stream
  /// then ends with the owner's interrupted `message.complete`.
  Future<void> interrupt(String sid) async {
    final generation = await _generationFor(sid);
    await ws!.call('session.interrupt', {
      'session_id': sid,
      'execution_generation': generation,
    });
  }

  void dispose() {
    _refusalSub?.cancel();
    for (final c in _cancels.values) {
      if (!c.isCompleted) c.complete();
    }
    _cancels.clear();
    outbox?.dispose();
    ws?.dispose();
  }
}

class _StoreOutboxPersistence implements WsOutboxPersistence {
  _StoreOutboxPersistence(this.store, this.server);
  final LocalStore store;
  final String server;

  @override
  String? read() => store.wsOutboxRaw(server);

  @override
  Future<void> write(String? value) => store.saveWsOutboxRaw(server, value);
}

/// The allowlist as saved in settings; anything unreadable routes nothing.
List<WsDirectEntry> loadWsDirect(LocalStore store) {
  final raw = store.wsDirectRaw();
  if (raw == null || raw.isEmpty) return const [];
  try {
    final list = jsonDecode(raw);
    if (list is! List) return const [];
    return [for (final e in list) ?WsDirectEntry.fromJson(e)];
  } catch (_) {
    return const [];
  }
}

/// The router for one configured server. Without a platform that can open
/// the bridge, an allowlist entry or a usable URL it stays disabled and never
/// opens a socket. A refused flush puts its text back into the session's
/// draft here, because no chat page may be alive to do it.
WsRouter buildWsRouter(
  LocalStore store,
  String serverUrl,
  String apiKey, {
  WsConnector? connector,
  bool? supported,
}) {
  final allow = loadWsDirect(store);
  final url = parseBridgeUrl(store.wsBridgeUrl() ?? deriveBridgeUrl(serverUrl));
  if (!(supported ?? wsSupported) ||
      allow.isEmpty ||
      url == null ||
      apiKey.isEmpty) {
    return WsRouter.disabled();
  }
  final ws = GatewayWs(url: url, apiKey: apiKey, connector: connector);
  final outbox = WsOutbox(ws, _StoreOutboxPersistence(store, serverUrl));
  final router = WsRouter(
    ws: ws,
    outbox: outbox,
    allow: allow,
    supported: supported,
  );
  router._refusalSub = outbox.refusals.listen((refused) {
    final kept = store.draft(serverUrl, refused.entry.sid);
    unawaited(
      store.saveDraft(
        serverUrl,
        refused.entry.sid,
        kept.isEmpty ? refused.entry.text : '$kept\n${refused.entry.text}',
      ),
    );
  });
  if (outbox.entries.isNotEmpty) router.start();
  return router;
}
