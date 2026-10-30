/// Voice-call wire protocol (PLAN-VOICEUI §3.1/§3.2/§3.3, §4.7/§4.8).
///
/// Pure Dart: JSON in, typed events out, zero I/O. The same close-code and
/// hello shapes exist on the gateway side (`vg/handshake.py`); the two files
/// must stay in lockstep. Binary frames are raw PCM (640 bytes = 320 int16
/// LE samples, 16 kHz mono, 20 ms) — never JSON, never a header (D1).
library;

import 'dart:convert';

/// Protocol generation both ends must agree on (§3.2: proto != 1 → 4400).
const kCallProto = 1;

/// One downlink/uplink frame: 640 bytes; the LAST frame of an utterance may
/// be shorter and is played as-is (§3.1).
const kFrameBytes = 640;
const kSampleRate = 16000;
const kFrameMs = 20;

/// WS close codes shared with `vg/handshake.py` (§3.3 table).
const closeNormal = 1000;
const closeGoingAway = 1001;
const closeBadHello = 4400;
const closeAuth = 4401;
const closeHelloTimeout = 4408;
const closeBusy = 4409;
const closeStalled = 4410;

/// The hello message the App sends right after the socket opens (§3.2).
/// The App ALWAYS sends the `session_id` key: `null` (standalone target)
/// serialises to `""` = standalone mode; a non-empty string = bound mode
/// (D3 — the config default is never used by this App). `sessionTitle` is
/// display-only and truncated to 120 chars, matching the gateway's rule.
String helloJson({
  required String token,
  String? sessionId,
  String? sessionTitle,
  required String client,
  bool reply = true,
}) => jsonEncode({
  'type': 'hello',
  'proto': kCallProto,
  'token': token,
  'session_id': sessionId ?? '',
  if (sessionTitle != null) 'session_title': _truncate(sessionTitle, 120),
  'reply': reply,
  'client': client,
});

String _truncate(String v, int max) =>
    v.length <= max ? v : v.substring(0, max);

/// One gateway event (§4.7). Unknown `type`s and unparsable JSON decode to
/// [UnknownEvent] and are ignored — a future gateway can add events without
/// breaking this App (§2 rule 3).
sealed class GatewayEvent {
  const GatewayEvent();
}

class ReadyEvent extends GatewayEvent {
  const ReadyEvent({
    required this.proto,
    required this.sampleRate,
    required this.frameMs,
    required this.format,
    required this.channels,
    required this.mode,
    required this.sessionId,
  });
  final int proto;
  final int sampleRate;
  final int frameMs;
  final String format;
  final int channels;

  /// 'bound' | 'standalone' (§3.1 ready field).
  final String mode;
  final String sessionId;
}

class SpeechStartEvent extends GatewayEvent {
  const SpeechStartEvent();
}

class PartialEvent extends GatewayEvent {
  const PartialEvent(this.text);
  final String text;
}

class SpeechEndEvent extends GatewayEvent {
  const SpeechEndEvent();
}

class SegmentFinalEvent extends GatewayEvent {
  const SegmentFinalEvent(this.text);
  final String text;
}

class TurnFinalEvent extends GatewayEvent {
  const TurnFinalEvent(this.turn, this.text);
  final int turn;
  final String text;
}

class RouteEvent extends GatewayEvent {
  const RouteEvent(this.turn, this.route);
  final int turn;

  /// 'front' | 'brain'
  final String route;
}

class BrainQueuedEvent extends GatewayEvent {
  const BrainQueuedEvent(this.turn, this.reason, this.active);
  final int turn;

  /// 'voice_turn_ahead' | 'session_busy' (§3.2 busy gate)
  final String reason;
  final int active;
}

class BrainPendingEvent extends GatewayEvent {
  const BrainPendingEvent(this.turn, this.text);
  final int turn;
  final String text;
}

class BrainResultEvent extends GatewayEvent {
  const BrainResultEvent(this.turn, this.secs);
  final int turn;
  final double secs;
}

class ReplyTextEvent extends GatewayEvent {
  const ReplyTextEvent(this.turn, this.source, this.text);
  final int turn;

  /// 'front' | 'brain'
  final String source;
  final String text;
}

class AudioStartEvent extends GatewayEvent {
  const AudioStartEvent(this.kind, this.text, this.ms);
  final String kind;
  final String text;
  final double ms;
}

class AudioEndEvent extends GatewayEvent {
  const AudioEndEvent(this.kind);
  final String kind;
}

class AudioStopEvent extends GatewayEvent {
  const AudioStopEvent(this.kind);
  final String kind;
}

class BargeInEvent extends GatewayEvent {
  const BargeInEvent(this.wasPlaying);
  final bool wasPlaying;
}

class GatewayErrorEvent extends GatewayEvent {
  const GatewayErrorEvent(this.where, this.kind, this.detail);

  /// 'tts' | 'front' | 'brain' | ...
  final String where;
  final String? kind;

  /// Diagnostics ONLY — never shown in captions (may carry Python reprs,
  /// §4.7 footnote).
  final String? detail;
}

class PongEvent extends GatewayEvent {
  const PongEvent(this.id);
  final int id;
}

class UnknownEvent extends GatewayEvent {
  const UnknownEvent(this.type);
  final String type;
}

int _int(Object? v) => (v as num?)?.toInt() ?? 0;
double _double(Object? v) => (v as num?)?.toDouble() ?? 0;
String _str(Object? v) => v is String ? v : '';

/// Parse one text message from the gateway. Bad JSON and unknown types both
/// land in [UnknownEvent] (§4.7): the call never breaks on a malformed line.
GatewayEvent parseGatewayEvent(String raw) {
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const UnknownEvent('');
  }
  if (decoded is! Map || decoded['type'] is! String) {
    return const UnknownEvent('');
  }
  final type = decoded['type'] as String;
  switch (type) {
    case 'ready':
      final audio = decoded['audio'];
      final a = audio is Map ? audio : const {};
      return ReadyEvent(
        proto: _int(decoded['proto']),
        sampleRate: _int(a['sample_rate']),
        frameMs: _int(a['frame_ms']),
        format: _str(a['format']),
        channels: _int(a['channels']),
        mode: _str(decoded['mode']),
        sessionId: _str(decoded['session_id']),
      );
    case 'speech_start':
      return const SpeechStartEvent();
    case 'partial':
      return PartialEvent(_str(decoded['text']));
    case 'speech_end':
      return const SpeechEndEvent();
    case 'segment_final':
      return SegmentFinalEvent(_str(decoded['text']));
    case 'turn_final':
      return TurnFinalEvent(_int(decoded['turn']), _str(decoded['text']));
    case 'route':
      return RouteEvent(_int(decoded['turn']), _str(decoded['route']));
    case 'brain_queued':
      return BrainQueuedEvent(
        _int(decoded['turn']),
        _str(decoded['reason']),
        _int(decoded['active']),
      );
    case 'brain_pending':
      return BrainPendingEvent(_int(decoded['turn']), _str(decoded['text']));
    case 'brain_result':
      return BrainResultEvent(_int(decoded['turn']), _double(decoded['secs']));
    case 'reply_text':
      return ReplyTextEvent(
        _int(decoded['turn']),
        _str(decoded['source']),
        _str(decoded['text']),
      );
    case 'audio_start':
      return AudioStartEvent(
        _str(decoded['kind']),
        _str(decoded['text']),
        _double(decoded['ms']),
      );
    case 'audio_end':
      return AudioEndEvent(_str(decoded['kind']));
    case 'audio_stop':
      return AudioStopEvent(_str(decoded['kind']));
    case 'barge_in':
      return BargeInEvent(decoded['was_playing'] == true);
    case 'error':
      return GatewayErrorEvent(
        _str(decoded['where']),
        decoded['kind'] is String ? decoded['kind'] as String : null,
        decoded['detail'] is String ? decoded['detail'] as String : null,
      );
    case 'pong':
      return PongEvent(_int(decoded['id']));
    default:
      return UnknownEvent(type);
  }
}

/// A `ready` is usable only when the generation AND the audio description
/// match what this client can actually play (§3.1: otherwise protocol error
/// → error(protocol), never a best-effort start).
bool readyCompatible(ReadyEvent e) =>
    e.proto == kCallProto &&
    e.format == 's16le' &&
    e.sampleRate == kSampleRate &&
    e.channels == 1 &&
    e.frameMs == kFrameMs;
