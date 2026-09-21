import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../features/attachments/attachment.dart';
import '../l10n/app_locale.dart';
import '../l10n/app_strings.dart';
import '../l10n/message_key.dart';
import '../l10n/ui_message.dart';
// AppFormatException lives in the pure l10n layer; re-exported so existing
// api-layer importers keep resolving it.
export '../l10n/ui_message.dart' show AppFormatException;
import '../models/message.dart';
import '../models/session.dart';
import '../models/session_activity.dart';
import 'sse.dart';
import 'transport.dart';
import '../diagnostics/diagnostics.dart';
import '../platform/stream_keepalive.dart';

/// Network/server error. Carries a locale-independent descriptor when the
/// text is app-created (I18N-PLAN §4.3); the legacy raw-string constructor
/// stays for server-origin/fake text. `toString()` is a technical,
/// locale-free representation for diagnostics — never a UI formatter; a
/// test/CLI that needs human output resolves [uiMessage] through the
/// English catalog explicitly via [message].
class ApiException implements Exception, UiCarriesMessage {
  const ApiException(String rawMessage, [this.status])
    : _rawMessage = rawMessage,
      _key = null,
      _args = null;

  const ApiException.local(
    MessageKey key, {
    this.status,
    Map<String, Object?> args = const {},
  }) : _rawMessage = null,
       _key = key,
       _args = args;

  final String? _rawMessage;
  final MessageKey? _key;
  final Map<String, Object?>? _args;
  final int? status;

  /// Bridge for descriptor-valued helpers: local hints keep their key,
  /// raw text keeps the legacy raw form.
  factory ApiException.fromUiMessage(UiMessage m, [int? status]) =>
      m is UiLocal
      ? ApiException.local(m.key, status: status, args: m.args)
      : ApiException((m as UiRaw).text, status);

  @override
  UiMessage get uiMessage {
    if (_key != null) return UiLocal(_key, args: _args ?? const {});
    if (_rawMessage == null) return const UiRaw('');
    return status == null
        ? UiRaw(_rawMessage)
        : UiRaw('$_rawMessage (HTTP $status)');
  }

  /// English resolution (or raw server text) for logs/CLI; UI code must
  /// render [uiMessage] with the current AppStrings instead.
  String get message =>
      _rawMessage ?? AppStrings(AppLocale.en).render(uiMessage);

  @override
  String toString() => _key != null
      ? 'ApiException(${_key.name}${status != null ? ', HTTP $status' : ''})'
      : status == null
      ? message
      : '$message (HTTP $status)';
}

// AppFormatException is defined in l10n/ui_message.dart (pure layer, so
// models can throw it without an api import); re-exported for existing
// call sites that import this file.

class HermesRepository {
  HermesRepository(
    this.baseUrl,
    this.key, {
    HttpPort? port,
    // AUDIT-10: short metadata GETs (sessions / capabilities / run status /
    // health) get a bounded budget; chat SSE + run body reads keep the
    // contract's >=600s path untouched. Injectable so tests stay fast.
    this.metadataTimeout = const Duration(seconds: 20),
  }) : _port = port ?? newHttpPort();
  static int _streamCounter = 0;
  final String baseUrl, key;
  final HttpPort _port;
  final _activityCache = <String, (int, double)>{};
  static const readTimeout = Duration(seconds: 610); // Contract §1 >=600s.
  final Duration metadataTimeout;
  final _keepalives = <String, Set<StreamKeepalive>>{};

  /// Active SSE streams that detach() can cut so the server sees a dropped
  /// viewer and arms its ntfy push path (runs survive the disconnect).
  final _streamCancels = <String, Completer<void>>{};

  /// Close sid's live SSE without killing the server-side run.
  void cancelStream(String sid) {
    _streamCancels.remove(sid)?.complete();
  }

  /// Pollable run status (GET /v1/runs/{id}); 404 once the gateway forgets it.
  Future<Json> runStatus(String runId) =>
      _json('GET', '/v1/runs/${Uri.encodeComponent(runId)}',
          deadline: metadataTimeout);

  void releaseStreamKeepalive(String sid) {
    final leases = _keepalives.remove(sid);
    for (final lease in leases ?? <StreamKeepalive>{}) {
      unawaited(lease.stop());
    }
  }

  void close() {
    for (final sid in _keepalives.keys.toList()) {
      releaseStreamKeepalive(sid);
    }
    _port.close();
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(baseUrl);
    return base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/$'), '')}$path',
      queryParameters: query,
      fragment: '',
    );
  }

  /// AUDIT-10: distinguish "Tailscale/IP unreachable" from "gateway didn't
  /// answer headers" (already surfaced as PortTimeout above) from a generic
  /// transport error, so the UI can suggest the right fix.
  static UiMessage _netHint(Object e) {
    final s = e.toString();
    if (e is TimeoutException) {
      return const UiMessage.local(MessageKey.apiM001);
    }
    if (s.contains('SocketException') ||
        s.contains('Failed host lookup') ||
        s.contains('Connection refused')) {
      return const UiMessage.local(MessageKey.apiM002);
    }
    if (s.contains('HandshakeException') || s.contains('CERT')) {
      return const UiMessage.local(MessageKey.apiM003);
    }
    return UiMessage.local(
      MessageKey.apiM004,
      args: {'detail': UiMessage.raw(s)},
    );
  }

  Future<PortResponse> _open(
    String method,
    String path, {
    Json? body,
    Map<String, String>? query,
    bool sse = false,
    Future<void>? abortTrigger,
    Duration? headersTimeout,
  }) async {
    final PortResponse response;
    try {
      response = await _port.send(
        method,
        _uri(path, query),
        headers: {
          'authorization': 'Bearer $key',
          if (sse) 'accept': 'text/event-stream',
          if (body != null) 'content-type': 'application/json',
        },
        body: body == null ? null : Stream.value(utf8.encode(jsonEncode(body))),
        contentLength: null,
        abortTrigger: abortTrigger,
        // SSE carries the contract's long budget; never shorten it here.
        headersTimeout: sse ? unboundedTimeout : headersTimeout,
      );
    } on PortTimeout {
      throw const ApiException.local(MessageKey.apiM005);
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException.fromUiMessage(_netHint(e));
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final budget = headersTimeout != null && headersTimeout < readTimeout
          ? headersTimeout
          : readTimeout;
      await response.stream.drain<void>().timeout(budget);
      // Do not expose reflected key or private server body in the UI/logs.
      throw ApiException.local(
        response.statusCode == 401 ? MessageKey.apiM006 : MessageKey.apiM007,
        status: response.statusCode,
      );
    }
    return response;
  }

  Future<Json> _json(
    String method,
    String path, {
    Json? body,
    Map<String, String>? query,
    Duration? deadline,
  }) async {
    final r = await _open(
      method,
      path,
      body: body,
      query: query,
      headersTimeout: deadline,
    );
    final String raw;
    try {
      raw = await utf8.decoder
          .bind(r.stream)
          .join()
          .timeout(deadline ?? readTimeout);
    } on TimeoutException {
      // AUDIT-10: a body that stops mid-flight must land as a retry-able
      // timeout error, not an eternal spinner.
      throw const ApiException.local(MessageKey.apiM008);
    }
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      throw const ApiException.local(MessageKey.apiM009);
    }
  }

  /// Contract §1: check compatibility BEFORE loading other resources.
  Future<void> checkCapabilities() async {
    final c = await _json('GET', '/v1/capabilities',
        deadline: metadataTimeout);
    if ((c['auth'] as Map?)?['required'] != true ||
        (c['features'] as Map?)?['session_chat_streaming'] != true) {
      throw const ApiException.local(MessageKey.apiM010);
    }
  }

  /// Contract §2: no auth required, but §1 permits sending auth on every request.
  Future<bool> health() async {
    try {
      await _json('GET', '/health', deadline: metadataTimeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Contract §2: fetch EVERY session page and de-duplicate by id.
  Future<List<Session>> sessions() async {
    final all = <String, Session>{};
    var offset = 0;
    while (true) {
      final json = await _json(
        'GET',
        '/api/sessions',
        query: {'limit': '500', 'offset': '$offset', 'order': 'latest'},
        deadline: metadataTimeout,
      );
      final page = (json['data'] as List).cast<Map>();
      for (final row in page) {
        final s = Session.fromJson(Map<String, dynamic>.from(row));
        all[s.id] = s;
      }
      offset += page.length;
      if (page.length < 500) break;
    }
    // Contract only guarantees started_at on session rows. Obtain the last
    // message timestamp (also contract §3) for actual recent-activity order.
    // Four readers bound load; unchanged counts reuse this repository cache.
    final pending = all.values.where((s) => s.count > 0).toList();
    var cursor = 0;
    await Future.wait(
      List.generate(4, (_) async {
        while (cursor < pending.length) {
          final session = pending[cursor++];
          try {
            var cached = _activityCache[session.id];
            if (cached == null || cached.$1 != session.count) {
              final last = await messages(session.id, limit: 1);
              cached = (
                session.count,
                last.isNotEmpty && last.last.timestamp > 0
                    ? last.last.timestamp
                    : session.startedAt,
              );
              _activityCache[session.id] = cached;
            }
            all[session.id] = session.withActivity(cached.$2);
          } catch (_) {
            // A deleted/unavailable individual history must not hide the list.
          }
        }
      }),
    );
    final list = all.values.toList()
      ..sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return b.activity.compareTo(a.activity);
      });
    return list;
  }

  /// R1: the session row ({"id","message_count",...}) — message_count is the
  /// cross-device sync clock; cheap enough to poll while a page is visible.
  Future<Json> sessionDetail(String sid) async {
    final json = await _json(
      'GET',
      '/api/sessions/${Uri.encodeComponent(sid)}',
      deadline: metadataTimeout,
    );
    final session = json['session'];
    if (session is! Map) throw const ApiException.local(MessageKey.apiM011);
    return Map<String, dynamic>.from(session);
  }

  /// WAVE4: the session's live activity snapshot (durable history revision +
  /// active remote runs). Metadata-class timeout; statuses stay separable —
  /// 404 = endpoint missing (legacy server), 503 = snapshot refused, 401/403
  /// auth — and a malformed body throws ApiException WITHOUT a status so the
  /// controller can never mistake any of them for a confirmed-idle answer.
  Future<SessionActivity> sessionActivity(String sid) async {
    final json = await _json(
      'GET',
      '/api/sessions/${Uri.encodeComponent(sid)}/activity',
      deadline: metadataTimeout,
    );
    try {
      return SessionActivity.fromJson(Map<String, dynamic>.from(json));
    } on FormatException {
      throw const ApiException.local(MessageKey.apiM012);
    }
  }

  /// Contract §2 + P0 envelope erratum: data[], latest page internally oldest→newest.
  Future<List<Message>> messages(
    String sid, {
    int offset = 0,
    int limit = 200,
  }) async {
    final json = await _json(
      'GET',
      '/api/sessions/${Uri.encodeComponent(sid)}/messages',
      query: {'order': 'latest', 'limit': '$limit', 'offset': '$offset'},
    );
    return (json['data'] as List)
        .map((e) => Message.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// Contract §2: run.started is the ONLY supported active run/session binding.
  /// Never automatically replay this POST after transport failure.
  Stream<SseEvent> chat(String sid, String input) async* {
    final stream = ++_streamCounter;
    final lease = StreamKeepalive(stream);
    final cancel = Completer<void>();
    _streamCancels[sid] = cancel;
    (_keepalives[sid] ??= {}).add(lease);
    unawaited(Diagnostics.current?.record('sse.connecting', stream: stream));
    try {
      final response = await _open(
        'POST',
        '/api/sessions/${Uri.encodeComponent(sid)}/chat/stream',
        body: {'input': input},
        sse: true,
        abortTrigger: cancel.future,
      );
      if (response.mimeType != 'text/event-stream') {
        await response.stream.drain<void>();
        throw const ApiException.local(MessageKey.apiM013);
      }
      unawaited(Diagnostics.current?.record('sse.open', stream: stream));
      await lease.start();
      final iterator = StreamIterator(parseSse(response.stream.timeout(readTimeout)));
      try {
        while (true) {
          // Race the next frame against detach(): completing `cancel` cuts the
          // socket so the server sees a dropped viewer (run survives, ntfy
          // arms) while this generator unwinds cleanly.
          final advanced = await Future.any([
            iterator.moveNext().then((moved) => moved ? 0 : 1),
            cancel.future.then((_) => 2),
          ]);
          if (advanced == 2) {
            unawaited(
              Diagnostics.current?.record('sse.cancelled', stream: stream),
            );
            break;
          }
          if (advanced == 1) break; // EOF
          final event = iterator.current;
          // Event names are server-controlled; only known names enter diagnostics.
          const known = {
            'heartbeat',
            'message.started',
            'done',
            'tool.failed',
            'run.started',
            'run.completed',
            'assistant.delta',
            'assistant.completed',
            'tool.started',
            'tool.completed',
            'tool.progress',
            'error',
          };
          unawaited(
            Diagnostics.current?.record(
              'sse.event',
              stream: stream,
              event: known.contains(event.type) ? event.type : 'unknown',
            ),
          );
          if (event.type == 'run.completed' ||
              event.type == 'done' ||
              event.type == 'error') {
            await lease.stop();
          }
          yield event;
        }
      } finally {
        await iterator.cancel();
      }
      unawaited(Diagnostics.current?.record('sse.eof', stream: stream));
    } catch (_) {
      unawaited(Diagnostics.current?.record('sse.error', stream: stream));
      rethrow;
    } finally {
      await lease.stop();
      _keepalives[sid]?.remove(lease);
      if (_keepalives[sid]?.isEmpty == true) _keepalives.remove(sid);
      if (identical(_streamCancels[sid], cancel)) _streamCancels.remove(sid);
      unawaited(Diagnostics.current?.record('sse.closed', stream: stream));
    }
  }

  Future<Json> artifactCapabilities() async {
    final c = await _json('GET', '/v1/capabilities',
        deadline: metadataTimeout);
    final browser =
        (c['features'] as Map?)?['browser_extension_control'] as Map?;
    return Map<String, dynamic>.from(browser ?? {});
  }

  ApiException _artifactError(int status, {bool download = false}) =>
      ApiException.local(
        switch (status) {
          404 => download
              ? MessageKey.apiM014
              : MessageKey.apiM015,
          413 => MessageKey.apiM016,
          415 => MessageKey.apiM017,
          400 => MessageKey.apiM018,
          410 => MessageKey.apiM019,
          401 => MessageKey.apiM020,
          403 => MessageKey.apiM021,
          429 => MessageKey.apiM022,
          _ => MessageKey.apiM023,
        },
        status: status,
      );

  Future<Json> uploadAttachment(
    AttachmentSource source,
    String filename,
  ) async {
    final caps = await artifactCapabilities();
    if (caps['enabled'] == false) throw _artifactError(404);
    final transport = caps['artifact_transport'] as Map?;
    final cap =
        (transport?['max_bytes'] as num?)?.toInt() ?? attachmentMaxBytes;
    final size = await source.size;
    if (size == 0) throw _artifactError(400);
    if (size > cap) throw _artifactError(413);
    final mime = attachmentMime(filename);
    final allowed = transport?['allowed_mime_types'] as List?;
    if (allowed != null && !allowed.contains(mime)) throw _artifactError(415);
    final name = safeFilename(filename);
    final response = await _port.send(
      'POST',
      _uri('/v1/artifacts/upload'),
      headers: {
        'authorization': 'Bearer $key',
        'content-type': mime,
        'x-artifact-filename': name.codeUnits.any((c) => c > 127)
            ? Uri.encodeComponent(name)
            : name,
      },
      body: source.open(),
      contentLength: size,
      // Headers only arrive after the server received the whole (≤500 MiB)
      // body, so the metadata default would cut legitimate large uploads;
      // bound it by the long budget instead (AUDIT-10: finite, not infinite).
      headersTimeout: readTimeout,
    );
    if (response.statusCode != 201) {
      await response.stream.drain<void>().timeout(readTimeout);
      throw _artifactError(response.statusCode);
    }
    final receipt = Map<String, dynamic>.from(
      jsonDecode(
              await utf8.decoder.bind(response.stream).join().timeout(readTimeout))
          as Map,
    );
    if (!artifactIdPattern.hasMatch(receipt['artifact_id']?.toString() ?? '')) {
      throw const ApiException.local(MessageKey.apiM024);
    }
    final receivedSize = receipt['size_bytes'];
    final receivedHash = receipt['sha256'];
    if ((receivedSize is num && receivedSize != size) ||
        (receivedHash is String &&
            receivedHash.toLowerCase() !=
                (await sha256.bind(source.open()).first).toString())) {
      throw const ApiException.local(MessageKey.apiM025);
    }
    return receipt;
  }

  Future<Uint8List> downloadAttachment(String id) async {
    if (!artifactIdPattern.hasMatch(id)) {
      throw _artifactError(400, download: true);
    }
    final PortResponse response;
    try {
      response = await _open('GET', '/v1/artifacts/download/$id');
    } on ApiException catch (e) {
      throw _artifactError(e.status ?? 500, download: true);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(readTimeout)) {
      if (bytes.length + chunk.length > attachmentMaxBytes) {
        throw _artifactError(413);
      }
      bytes.add(chunk);
    }
    final result = bytes.takeBytes();
    final expected = response.headers['x-artifact-sha256'];
    if (expected != null &&
        sha256.convert(result).toString() != expected.toLowerCase()) {
      throw const ApiException.local(MessageKey.apiM026);
    }
    return result;
  }

  /// Streams a server-side file referenced by `MEDIA:` + absolute path replies
  /// via GET /v1/media/download. 404 means an older gateway without the route —
  /// callers should fall back to copy-path in that case.
  Future<Uint8List> downloadServerFile(String path) async {
    final PortResponse response;
    try {
      response = await _open(
        'GET',
        '/v1/media/download',
        query: {'path': path},
      );
    } on ApiException catch (e) {
      throw _artifactError(e.status ?? 500, download: true);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(readTimeout)) {
      if (bytes.length + chunk.length > attachmentMaxBytes) {
        throw _artifactError(413);
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  /// Contract §2: status can finish as completed even after explicit stop.
  Future<void> stop(String runId) async {
    await _json(
      'POST',
      '/v1/runs/${Uri.encodeComponent(runId)}/stop',
      body: {},
    );
  }

  /// Contract §2: input is steering guidance, accepted:true acknowledges injection.
  Future<void> steer(String runId, String input) async {
    final result = await _json(
      'POST',
      '/v1/runs/${Uri.encodeComponent(runId)}/steer',
      body: {'input': input},
    );
    if (result['accepted'] != true) {
      throw const ApiException.local(MessageKey.apiM027);
    }
  }

  /// Contract §2: DELETE returns 200; subsequent GET is 404 (P0-verified).
  Future<void> deleteSession(String sid) async {
    await _json('DELETE', '/api/sessions/${Uri.encodeComponent(sid)}');
  }

  /// POST /api/sessions: server mints an `api_<ts>_<hex>` id (verified 2026-09-12, HTTP 201).
  Future<Session> createSession() async {
    final json = await _json('POST', '/api/sessions', body: const {});
    final raw = json['session'];
    if (raw is! Map) throw const ApiException.local(MessageKey.apiM028);
    return Session.fromJson(Map<String, dynamic>.from(raw));
  }

  /// Contract §2: rename. Raw JSON object body (verified 2026-09-11, HTTP 200).
  Future<void> renameSession(String sid, String title) async {
    await _json(
      'PATCH',
      '/api/sessions/${Uri.encodeComponent(sid)}',
      body: {'title': title},
    );
  }

  /// Desktop-sidebar flag (PATCH pinned) — durable server-side pin.
  Future<void> setSessionPinned(String sid, bool pinned) async {
    await _json(
      'PATCH',
      '/api/sessions/${Uri.encodeComponent(sid)}',
      body: {'pinned': pinned},
    );
  }

  /// Resolve a pending approval on a live run (POST /v1/runs/{id}/approval).
  /// choice: once | session | always | deny.
  Future<void> resolveApproval(String runId, String choice) async {
    await _json(
      'POST',
      '/v1/runs/${Uri.encodeComponent(runId)}/approval',
      body: {'choice': choice},
    );
  }

  /// Model catalog for the management page (2026-09-11: providers[]/models[]).
  /// R3a ground truth: a models[] element may be a plain String
  /// ("gpt-6-astra", "default") OR a dict (id/slug/is_current) — the old
  /// hard `Map.from(m)` threw on string elements and killed the whole block.
  /// Top-level {"model","provider"} is the GLOBAL current model for the UI.
  Future<({List<Map<String, dynamic>> models, String global})> modelCatalog() async {
    final json = await _json('GET', '/api/model/options');
    final out = <Map<String, dynamic>>[];
    for (final p in (json['providers'] as List? ?? const [])) {
      if (p is! Map) continue;
      final provider = Map<String, dynamic>.from(p);
      for (final m in (provider['models'] as List? ?? const [])) {
        final name = m is Map ? (m['id'] ?? m['slug']) : m;
        if (name == null) continue;
        out.add({
          'provider': provider['slug'],
          'providerName': provider['name'],
          'model': name,
          'current':
              (m is Map && m['is_current'] == true) ||
              provider['is_current'] == true,
        });
      }
    }
    return (models: out, global: textOf(json['model']));
  }

  Future<List<Map<String, dynamic>>> modelOptions() async =>
      (await modelCatalog()).models;

  /// Per-session model lock (2026-09-11: POST returns model_lock accepted).
  Future<void> setSessionModel(String sid, String model) async {
    await _json(
      'POST',
      '/api/sessions/${Uri.encodeComponent(sid)}/model',
      body: {'model': model},
    );
  }

  /// Contract §5: once at startup, refreshed with pull-to-refresh.
  /// R3b: this upstream listing is sorted, enabled-blind (elements are
  /// name/description/category maps); the switch lives on the proxy PATCH.
  Future<List<Skill>> skills() async {
    final json = await _json('GET', '/v1/skills');
    return (json['data'] as List)
        .map((e) => Skill.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// R3b: skill on/off lives in the reverse proxy's PATCH (writes the
  /// config's disabled set; effective from the NEXT turn). Essential
  /// skills answer 400 — ApiException.status carries that to the UI.
  Future<void> setSkillEnabled(String name, bool enabled) async {
    await _json(
      'PATCH',
      '/api/skills/${Uri.encodeComponent(name)}',
      body: {'enabled': enabled},
    );
  }

  /// R3c: the two memory files, read through the proxy (no upstream
  /// endpoint exists). Items: {name, chars, limit, content|null, mtime}.
  Future<List<Map<String, dynamic>>> memories() async {
    final json = await _json('GET', '/api/memories',
        deadline: metadataTimeout);
    return (json['files'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// R3c: atomic PUT (proxy writes tmp + os.replace); "" clears.
  Future<void> saveMemory(String name, String content) async {
    await _json(
      'PUT',
      '/api/memories/${Uri.encodeComponent(name)}',
      body: {'content': content},
    );
  }
}
