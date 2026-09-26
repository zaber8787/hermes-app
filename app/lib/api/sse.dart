import 'dart:async';
import 'dart:convert';

class SseEvent {
  const SseEvent(this.type, this.data, {this.id});
  final String type, data;
  final String? id;
  Map<String, dynamic> get json {
    final decoded = jsonDecode(data);
    if (decoded is! Map) {
      throw const FormatException('SSE payload is not an object');
    }
    return Map<String, dynamic>.from(decoded);
  }
}

/// Contract §2 SSE. UTF-8 and line boundaries can split at ANY byte.
/// Supports CR/LF/CRLF, comments, multiline data, optional id and a trailing frame.
Stream<SseEvent> parseSse(Stream<List<int>> bytes) async* {
  var event = 'message';
  String? id;
  final data = <String>[];
  var first = true;
  await for (var line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (first) {
      line = line.replaceFirst(RegExp('^\uFEFF'), '');
      first = false;
    }
    if (line.isEmpty) {
      if (data.isNotEmpty) yield SseEvent(event, data.join('\n'), id: id);
      event = 'message';
      data.clear();
      continue;
    }
    if (line.startsWith(':')) {
      // `: keepalive` is how the gateway marks a live-but-idle POST SSE
      // stream: api_server.py's chat-stream handler writes it whenever its
      // event queue times out an empty 10s wait — the cadence is the
      // SERVER's current choice (gateway/platforms/api_server.py, POST
      // keepalive constant), not a parser contract, and older comments
      // claiming a fixed 30s cadence were wrong. Surface just this comment
      // as a heartbeat event so the UI can tell "alive and thinking" from
      // a wedged socket; other SSE comments stay silent per spec.
      if (line.substring(1).trim() == 'keepalive' &&
          event == 'message' &&
          data.isEmpty) {
        yield const SseEvent('heartbeat', '{}');
      }
      continue;
    }
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        event = value;
      case 'data':
        data.add(value);
      case 'id':
        if (!value.contains('\u0000')) id = value;
    }
  }
  if (data.isNotEmpty) yield SseEvent(event, data.join('\n'), id: id);
}
