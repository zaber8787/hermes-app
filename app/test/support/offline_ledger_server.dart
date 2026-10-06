// OFFLINE-SEND R3 §7.1: the B-class manual/e2e fixture server.
//
// A dart:io-only, dependency-free server with a PROCESS-MEMORY ledger: every
// request that mutates (chat POST, upload POST, run-stop POST, CORS OPTIONS)
// and every accepted run is COUNTED, and the only way to reset the counters
// is the test endpoint POST /__test/reset?mode=<mode>. A real browser (or
// the VM harness) can therefore prove "zero mutation POSTs", "exactly one
// chat POST", "reconnect never added a POST" from the SERVER side — never
// from a mock's own counters.
//
// It is deliberately RAW-SOCKET (no HttpServer): modes must control the
// bytes at the byte level — "record the POST then kill the socket with no
// response at all" and "never answer" are exactly what dart:io's HttpServer
// response object CANNOT do (its detachSocket auto-flushes a default 200).
//
// Run:
//   ../toolchain/flutter/bin/dart run test/support/offline_ledger_server.dart \
//       --port 18701 [--mode success]
//
// Modes (boot default, switched at runtime via POST /__test/reset?mode=X):
//   success              — full happy path, permissive CORS headers.
//   accepted-drop        — chat POST: RECORD, then destroy the socket with
//                          NO response bytes (client: dispatch proven,
//                          outcome unknown — never "not dispatched").
//   cors-preflight-deny  — OPTIONS answered 403 (counted); a browser never
//                          reaches the POST, and this ledger proves it.
//   cors-response-deny   — OPTIONS passes (counted), but POST responses
//                          carry NO access-control-allow-origin header.
//   headers-hang         — chat POST: socket accepted, NEVER answered.
//   history-hang         — history GET never completes. Submode:
//                          ?submode=headers  (default: no bytes back)
//                          ?submode=body     (headers now, body never).
//   stop-409/stop-404/stop-410 — run stop replies with that status.
//
// Paths are matched by SUFFIX so both the app's real contract paths
// (/api/sessions/:id/chat/stream, …) and the plan's /v1/... shorthands
// route to the same handlers. One request per connection (connection:
// close) — the price of byte-level honesty; harness browsers reconnect.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class LedgerServer {
  LedgerServer({this.mode = 'success'});

  String mode;
  ServerSocket? _server;
  final _sockets = <_Conn>{};

  // ---- process-memory ledger (reset ONLY via /__test/reset) --------------
  int options = 0; // CORS preflights SEEN
  int chatPosts = 0; // POST .../chat or .../chat/stream
  int uploadPosts = 0; // POST .../artifacts/upload
  int stopPosts = 0; // POST .../runs/:id/stop
  int acceptedRuns = 0; // run.started actually emitted on a chat stream
  List<String> historyUserIds = []; // user-row ids ever SERVED in history
  final _history = <(String, String)>[]; // (role, row id) rows served
  int _rowSeq = 0;

  static const _modes = [
    'success',
    'accepted-drop',
    'cors-preflight-deny',
    'cors-response-deny',
    'headers-hang',
    'history-hang',
    'stop-409',
    'stop-404',
    'stop-410',
  ];

  Future<void> start(int port) async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen((socket) {
      final conn = _Conn(socket, this);
      _sockets.add(conn);
      conn.start();
    });
    // ignore: avoid_print
    print('offline_ledger_server listening on :$port (mode=$mode)');
  }

  Future<void> stop() async {
    for (final c in _sockets.toList()) {
      c.socket.destroy();
    }
    _sockets.clear();
    await _server?.close();
  }

  void reset({String? newMode}) {
    if (newMode != null) mode = newMode;
    options = 0;
    chatPosts = 0;
    uploadPosts = 0;
    stopPosts = 0;
    acceptedRuns = 0;
    historyUserIds = [];
    _history.clear();
    _rowSeq = 0;
    for (final c in _sockets.toList()) {
      c.socket.destroy(); // frees any hang from the PREVIOUS scenario
    }
    _sockets.clear();
  }

  Map<String, Object?> get ledger => {
    'mode': mode,
    'options': options,
    'chatPosts': chatPosts,
    'uploadPosts': uploadPosts,
    'stopPosts': stopPosts,
    'acceptedRuns': acceptedRuns,
    'historyUserIds': historyUserIds,
  };
}

/// One connection: accumulate until a full request head+body, then route.
class _Conn {
  _Conn(this.socket, this.s);
  final Socket socket;
  final LedgerServer s;
  final _buf = BytesBuilder(copy: false);
  String? _method, _target;
  bool _routed = false;
  final _headers = <String, String>{};

  void start() {
    socket.listen(
      _onBytes,
      onError: (Object _) => socket.destroy(),
      onDone: () => s._sockets.remove(this),
      cancelOnError: true,
    );
  }

  void _onBytes(List<int> bytes) {
    _buf.add(bytes);
    var all = _buf.takeBytes();
    _buf.clear();
    _buf.add(all);
    if (_method == null) {
      final end = _headerEnd(all);
      if (end < 0) return; // headers incomplete
      final text = utf8.decode(all.sublist(0, end), allowMalformed: true);
      final lines = text.split(RegExp(r'\r?\n'));
      final parts = lines.first.split(' ');
      if (parts.length < 2) {
        socket.destroy();
        return;
      }
      _method = parts[0].toUpperCase();
      _target = parts[1];
      for (final line in lines.skip(1)) {
        final colon = line.indexOf(':');
        if (colon <= 0) continue;
        _headers[line.substring(0, colon).trim().toLowerCase()] = line
            .substring(colon + 1)
            .trim();
      }
      all = all.sublist(end + 4);
      _buf.clear();
      _buf.add(all);
    }
    if (!_bodyComplete()) return; // headers in, body still streaming
    if (_routed) return; // one request per connection (connection: close)
    _routed = true; // NOTE: routed sockets STAY in _sockets — reset must
    // still be able to destroy a hang; a closed socket's destroy is a no-op.
    _route();
  }

  bool _bodyComplete() {
    final bytes = _buf.takeBytes();
    if (_headers['transfer-encoding']?.toLowerCase().contains('chunked') ==
        true) {
      var off = 0;
      while (true) {
        final nl = _indexOf(bytes, _crlf, off);

        if (nl < 0) return false;
        final size = int.tryParse(
          utf8.decode(bytes.sublist(off, nl)).trim(),
          radix: 16,
        );
        if (size == null) return false;
        if (size == 0) return true; // terminating chunk (trailer ignored)
        if (bytes.length < nl + 2 + size + 2) return false;
        off = nl + 2 + size + 2;
      }
    }
    return bytes.length >= (int.tryParse(_headers['content-length'] ?? '0') ?? 0);
  }

  static const _crlf = [13, 10];
  static const _headEnd = [13, 10, 13, 10];

  static int _indexOf(List<int> hay, List<int> needle, int from) {
    outer:
    for (var i = from; i + needle.length <= hay.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (hay[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  static int _headerEnd(List<int> b) => _indexOf(b, _headEnd, 0);

  Future<void> _route() async {
    final method = _method!, path = _target!.split('?').first;
    final query = _target!.contains('?')
        ? Uri.splitQueryString(_target!.split('?').last)
        : const <String, String>{};
    final ledgerPath = path == '/__test/ledger' || path == '/__test/reset';
    if (!ledgerPath) {
      switch (method) {
        case 'OPTIONS':
          s.options++;
          if (s.mode == 'cors-preflight-deny') {
            _respond(403, '', cors: true); // counted, and NOT allowed
            return;
          }
          _respond(204, '', cors: true);
          return;
        case 'POST'
            when path.endsWith('/chat/stream') || path.endsWith('/chat'):
          await _dispatchChat();
          return;
        case 'POST' when path.endsWith('/artifacts/upload'):
          s.uploadPosts++;
          _respond(201, jsonEncode({'artifact_id': 'artifact-000000'}));
          return;
        case 'POST' when path.contains('/runs/') && path.endsWith('/stop'):
          s.stopPosts++;
          final status = switch (s.mode) {
            'stop-409' => 409,
            'stop-404' => 404,
            'stop-410' => 410,
            _ => 200,
          };
          _respond(status, '{"run":{"status":"${status == 200 ? 'stopping' : 'unchanged'}"}}');
          return;
      }
    } else if (method == 'POST' && path == '/__test/reset') {
      final m = query['mode'];
      if (m != null && !LedgerServer._modes.contains(m)) {
        _respond(400, '{"error":"unknown mode"}');
        return;
      }
      s.reset(newMode: m);
      _respondLedger(jsonEncode(s.ledger));
      return;
    } else if (method == 'GET' && path == '/__test/ledger') {
      _respondLedger(jsonEncode(s.ledger));
      return;
    }

    switch ((method, path)) {
      case ('GET', _) when path.endsWith('/v1/capabilities'):
        _respond(200, jsonEncode({
          'auth': {'required': true, 'scheme': 'bearer'},
          'features': {'session_chat_streaming': true},
        }));
      case ('GET', '/health'):
        _respond(200, '{"ok":true}');
      case ('GET', _)
          when path.endsWith('/v1/sessions') || path.endsWith('/api/sessions'):
        _respond(200, jsonEncode({
          'data': [
            {'id': 'ledger-sid', 'message_count': s._history.length, 'started_at': 1},
          ],
        }));
      case ('GET', _) when path.endsWith('/messages'):
        if (s.mode == 'history-hang') {
          if ((query['submode'] ?? 'headers') == 'body') {
            // headers NOW, body NEVER: a drain-side black hole.
            _writeHead(200, contentType: 'application/json');
            await socket.flush();
            return; // socket stays open, unanswered forever
          }
          return; // no bytes at all, ever
        }
        _respond(200, jsonEncode({'data': _historyRows()}));
      case ('GET', _) when path.endsWith('/activity'):
        _respond(200, jsonEncode({
          'object': 'hermes.session.activity',
          'schema_version': 1,
          'session_id': 'ledger-sid',
          'resolved_session_id': 'ledger-sid',
          'server_epoch': 'ledger-epoch',
          'observed_at': DateTime.now().millisecondsSinceEpoch / 1000,
          'history_revision': {
            'session_id': 'ledger-sid',
            'count': s._history.length,
            'latest_id': s._rowSeq,
          },
          'activity_revision': 0,
          'active_runs': const [],
          'recent_terminal': const [],
          'overflow': false,
        }));
      case ('GET', _) when path.contains('/runs/'):
        _respond(200, '{"run":{"status":"completed"}}');
      default:
        _respond(404, '');
    }
  }

  Future<void> _dispatchChat() async {
    s.chatPosts++; // RECORDED FIRST — even accepted-drop proves the POST
    if (s.mode == 'headers-hang') return; // socket accepted, never answered
    if (s.mode == 'accepted-drop') {
      socket.destroy(); // NO status line, NO headers — connection gone
      return;
    }
    // success (+ all stop-* modes behave like success for chat):
    final runId = 'run-${s.acceptedRuns + 1}';
    final uid = 'u${s._rowSeq + 1}';
    s.acceptedRuns++;
    s._history.addAll([('user', uid), ('assistant', 'a${s._rowSeq + 1}')]);
    s._rowSeq++;
    s.historyUserIds = [
      for (final (role, id) in s._history)
        if (role == 'user') id,
    ];
    _writeHead(200, contentType: 'text/event-stream');
    socket.add(
      utf8.encode(
        'event: run.started\ndata: {"run_id":"$runId","session_id":"ledger-sid"}\n\n',
      ),
    );
    await socket.flush();
    // A short visible beat, then terminal — deterministic and cheap.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    socket.add(
      utf8.encode(
        'event: run.completed\ndata: {"run_id":"$runId","status":"completed",'
        '"messages":[]}\n\n',
      ),
    );
    await _end();
  }

  List<Map<String, Object?>> _historyRows() => [
    for (final (role, id) in s._history)
      {
        'id': id,
        'role': role,
        'content': role == 'user' ? 'ledger turn' : 'ledger reply',
        'timestamp': 1,
      },
  ];

  void _writeHead(int status, {String contentType = 'application/json'}) {
    final b = StringBuffer('HTTP/1.1 $status ${status == 204 ? 'No Content' : 'OK'}\r\n');
    if (s.mode != 'cors-response-deny') {
      // cors-response-deny: OPTIONS passes but POST responses carry NO
      // access-control-allow-origin — that is the whole point.
      b.write('access-control-allow-origin: *\r\n');
      b.write('access-control-allow-headers: authorization,content-type,'
          'x-artifact-filename\r\n');
      b.write('access-control-allow-methods: GET,POST,PATCH,DELETE,OPTIONS\r\n');
    }
    b.write('content-type: $contentType\r\nconnection: close\r\n\r\n');
    socket.add(utf8.encode(b.toString()));
  }

  /// The harness's OWN endpoints stay browser-readable in EVERY mode —
  /// the ledger is the measuring instrument, never a test subject.
  void _respondLedger(String body) {
    final b = StringBuffer(
      'HTTP/1.1 200 OK\r\n'
      'access-control-allow-origin: *\r\n'
      'access-control-allow-headers: authorization,content-type\r\n'
      'access-control-allow-methods: GET,POST,PATCH,DELETE,OPTIONS\r\n'
      'content-length: ${body.length}\r\nconnection: close\r\n\r\n',
    );
    socket.add(utf8.encode(b.toString()));
    if (body.isNotEmpty) socket.add(utf8.encode(body));
    unawaited(_end());
  }

  void _respond(int status, String body, {bool cors = false}) {
    if (cors) {
      final deny = s.mode == 'cors-response-deny';
      final b = StringBuffer('HTTP/1.1 $status OK\r\n');
      if (!deny) {
        b.write('access-control-allow-origin: *\r\n'
            'access-control-allow-headers: authorization,content-type\r\n'
            'access-control-allow-methods: GET,POST,PATCH,DELETE,OPTIONS\r\n');
      }
      b.write('content-length: ${body.length}\r\nconnection: close\r\n\r\n');
      socket.add(utf8.encode(b.toString()));
      if (body.isNotEmpty) socket.add(utf8.encode(body));
      unawaited(_end());
      return;
    }
    _writeHead(status);
    // SSE callers never go through _respond; JSON bodies get a length.
    socket.add(utf8.encode(body));
    unawaited(_end());
  }

  Future<void> _end() async {
    try {
      await socket.flush();
      await socket.close();
    } catch (_) {}
    socket.destroy();
  }
}

Future<void> main(List<String> args) async {
  var port = 18701;
  var mode = 'success';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--port' && i + 1 < args.length) {
      port = int.parse(args[++i]);
    } else if (args[i] == '--mode' && i + 1 < args.length) {
      mode = args[++i];
    }
  }
  final server = LedgerServer(mode: mode);
  await server.start(port);
  ProcessSignal.sigint.watch().listen((_) async {
    await server.stop();
    exit(0);
  });
}
