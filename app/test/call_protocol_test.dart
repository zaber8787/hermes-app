import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/features/call/call_protocol.dart';

// PLAN-VOICEUI §6.2 call_protocol_test: every event JSON parses to its
// subclass with the right fields; unknown/broken input never throws;
// hello always carries the session_id key; readyCompatible gates the
// audio description (§3.1/§3.2).
void main() {
  group('constants (shared with vg/handshake.py)', () {
    test('frame geometry and close codes match PLAN §3.1/§3.3', () {
      expect(kCallProto, 1);
      expect(kFrameBytes, 640);
      expect(kSampleRate, 16000);
      expect(kFrameMs, 20);
      expect(closeNormal, 1000);
      expect(closeGoingAway, 1001);
      expect(closeBadHello, 4400);
      expect(closeAuth, 4401);
      expect(closeHelloTimeout, 4408);
      expect(closeBusy, 4409);
      expect(closeStalled, 4410);
    });
  });

  group('helloJson', () {
    test('sessionId null serialises to empty string (D3: App always sends',
        () {
      // the key; "" = standalone, never the gateway config default)
      final j = jsonDecode(
        helloJson(token: 'tk', client: 'hermes-app/0.14.25 android'),
      ) as Map;
      expect(j['session_id'], '');
      expect(j['type'], 'hello');
      expect(j['proto'], 1);
      expect(j['token'], 'tk');
      expect(j['reply'], true);
      expect(j['client'], 'hermes-app/0.14.25 android');
    });

    test('bound session id and title pass through; reply flag honoured', () {
      final j = jsonDecode(
        helloJson(
          token: 'tk',
          sessionId: 'sid-77',
          sessionTitle: '專案討論',
          client: 'hermes-app',
          reply: false,
        ),
      ) as Map;
      expect(j['session_id'], 'sid-77');
      expect(j['session_title'], '專案討論');
      expect(j['reply'], false);
      expect(j.containsKey('session_title'), isTrue);
    });

    test('no title means no session_title key; title truncates at 120', () {
      final j = jsonDecode(
        helloJson(token: '', sessionTitle: '題' * 200, client: 'c'),
      ) as Map;
      expect(j['session_title'], '題' * 120);
      final j2 = jsonDecode(helloJson(token: '', client: 'c')) as Map;
      expect(j2.containsKey('session_title'), isFalse);
    });
  });

  group('parseGatewayEvent', () {
    test('ready carries proto + audio description + mode + session_id', () {
      final e = parseGatewayEvent(
        '{"type":"ready","pid":123,"tts":"off","proto":1,'
        '"audio":{"format":"s16le","sample_rate":16000,"channels":1,'
        '"frame_ms":20},"session_id":"abc","mode":"bound"}',
      );
      expect(e, isA<ReadyEvent>());
      final r = e as ReadyEvent;
      expect(r.proto, 1);
      expect(r.sampleRate, 16000);
      expect(r.frameMs, 20);
      expect(r.format, 's16le');
      expect(r.channels, 1);
      expect(r.mode, 'bound');
      expect(r.sessionId, 'abc');
    });

    test('speech/partial/segment/turn rows', () {
      expect(parseGatewayEvent('{"type":"speech_start"}'),
          isA<SpeechStartEvent>());
      expect(parseGatewayEvent('{"type":"speech_end"}'), isA<SpeechEndEvent>());
      final p = parseGatewayEvent('{"type":"partial","text":"今天下"}')
          as PartialEvent;
      expect(p.text, '今天下');
      final s = parseGatewayEvent('{"type":"segment_final","text":"半天"}')
          as SegmentFinalEvent;
      expect(s.text, '半天');
      final t = parseGatewayEvent('{"type":"turn_final","turn":4,"text":"今天下雨"}')
          as TurnFinalEvent;
      expect((t.turn, t.text), (4, '今天下雨'));
    });

    test('route / brain rows', () {
      final r = parseGatewayEvent('{"type":"route","turn":2,"route":"brain"}')
          as RouteEvent;
      expect((r.turn, r.route), (2, 'brain'));
      final q = parseGatewayEvent(
        '{"type":"brain_queued","turn":3,"reason":"session_busy","active":1}',
      ) as BrainQueuedEvent;
      expect((q.turn, q.reason, q.active), (3, 'session_busy', 1));
      final p = parseGatewayEvent(
        '{"type":"brain_pending","turn":3,"text":"好，我去處理一下。"}',
      ) as BrainPendingEvent;
      expect((p.turn, p.text), (3, '好，我去處理一下。'));
      final b = parseGatewayEvent('{"type":"brain_result","turn":3,"secs":8.5}')
          as BrainResultEvent;
      expect((b.turn, b.secs), (3, 8.5));
    });

    test('reply_text row', () {
      final e = parseGatewayEvent(
        '{"type":"reply_text","turn":5,"source":"brain","text":"现在是下午三点。"}',
      ) as ReplyTextEvent;
      expect((e.turn, e.source, e.text), (5, 'brain', '现在是下午三点。'));
    });

    test('audio rows: start carries kind/text/ms; end/stop carry kind', () {
      final a = parseGatewayEvent(
        '{"type":"audio_start","kind":"filler","text":"嗯……","ms":420}',
      ) as AudioStartEvent;
      expect((a.kind, a.text, a.ms), ('filler', '嗯……', 420.0));
      expect(
        (parseGatewayEvent('{"type":"audio_end","kind":"tts"}')
                as AudioEndEvent)
            .kind,
        'tts',
      );
      expect(
        (parseGatewayEvent('{"type":"audio_stop","kind":"filler"}')
                as AudioStopEvent)
            .kind,
        'filler',
      );
      final b = parseGatewayEvent('{"type":"barge_in","was_playing":true}')
          as BargeInEvent;
      expect(b.wasPlaying, isTrue);
    });

    test('error row keeps where/kind/detail, absent fields stay null', () {
      final e = parseGatewayEvent(
        '{"type":"error","where":"brain","kind":"queue_timeout",'
        '"detail":"Traceback ..."}',
      ) as GatewayErrorEvent;
      expect((e.where, e.kind, e.detail), ('brain', 'queue_timeout', 'Traceback ...'));
      final f = parseGatewayEvent('{"type":"error","where":"front"}')
          as GatewayErrorEvent;
      expect((f.where, f.kind, f.detail), ('front', null, null));
    });

    test('pong row', () {
      expect((parseGatewayEvent('{"type":"pong","id":9}') as PongEvent).id, 9);
    });

    test('unknown type decodes to UnknownEvent with the type kept', () {
      final e = parseGatewayEvent('{"type":"voiceprint_gate","x":1}')
          as UnknownEvent;
      expect(e.type, 'voiceprint_gate');
    });

    test('broken JSON decodes to UnknownEvent, never throws', () {
      expect(parseGatewayEvent('{not json'), isA<UnknownEvent>());
      expect(parseGatewayEvent('[]'), isA<UnknownEvent>());
      expect(parseGatewayEvent('{"no_type":1}'), isA<UnknownEvent>());
    });
  });

  group('readyCompatible', () {
    ReadyEvent ready({
      int proto = 1,
      int rate = 16000,
      int frameMs = 20,
      String format = 's16le',
      int channels = 1,
    }) => ReadyEvent(
      proto: proto,
      sampleRate: rate,
      frameMs: frameMs,
      format: format,
      channels: channels,
      mode: 'standalone',
      sessionId: '',
    );

    test('exact v1 description is compatible', () {
      expect(readyCompatible(ready()), isTrue);
    });

    test('proto 2, 48k, wrong format or stereo are protocol errors', () {
      expect(readyCompatible(ready(proto: 2)), isFalse);
      expect(readyCompatible(ready(rate: 48000)), isFalse);
      expect(readyCompatible(ready(format: 'f32le')), isFalse);
      expect(readyCompatible(ready(channels: 2)), isFalse);
      expect(readyCompatible(ready(frameMs: 10)), isFalse);
    });
  });
}
