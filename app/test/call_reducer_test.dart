import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/features/call/call_protocol.dart';
import 'package:hermes_app/features/call/call_reducer.dart';
import 'package:hermes_app/features/call/call_state.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';
import 'package:hermes_app/models/session.dart';

// PLAN-VOICEUI §6.2 call_reducer_test: one case per §4.7 row (event in,
// state fields asserted), the caption-assembly sequence, the brain
// indicator chain, the 50-line ring, and the §4.2 close branches.
final t0 = DateTime(2026, 10, 30, 12, 0, 0);
DateTime later(int secs) => t0.add(Duration(seconds: secs));

const standalone = StandaloneCallTarget();
final bound = SessionCallTarget(
  Session(
    id: 'sid-1',
    title: '專案討論',
    count: 3,
    startedAt: 0,
    activity: 0,
    source: 'api_server',
  ),
);

CallState connected({
  CallTarget target = standalone,
  int attempt = 0,
  bool wantMuted = false,
  List<CaptionLine> captions = const [],
}) => CallState(
  target: target,
  phase: CallPhase.connected,
  attempt: attempt,
  wantMuted: wantMuted,
  captions: captions,
);

/// Last system line's MessageKey, or null if the tail is not a system line.
MessageKey? lastSystemKey(CallState s) {
  if (s.captions.isEmpty) return null;
  final sys = s.captions.last.system;
  return sys is UiLocal ? sys.key : null;
}

void main() {
  group('§4.7 rows', () {
    test('ready → connected, attempt reset; wantMuted → muted', () {
      final s = reduceEvent(
        CallState(target: standalone, phase: CallPhase.connecting),
        const ReadyEvent(
          proto: 1,
          sampleRate: 16000,
          frameMs: 20,
          format: 's16le',
          channels: 1,
          mode: 'standalone',
          sessionId: '',
        ),
        t0,
      );
      expect(s.phase, CallPhase.connected);

      final m = reduceEvent(
        CallState(
          target: standalone,
          phase: CallPhase.connecting,
          wantMuted: true,
        ),
        const ReadyEvent(
          proto: 1,
          sampleRate: 16000,
          frameMs: 20,
          format: 's16le',
          channels: 1,
          mode: 'standalone',
          sessionId: '',
        ),
        t0,
      );
      expect(m.phase, CallPhase.muted);
    });

    test('ready with attempt > 0 adds the reconnected system line', () {
      final s = reduceEvent(
        CallState(
          target: standalone,
          phase: CallPhase.connecting,
          attempt: 2,
        ),
        const ReadyEvent(
          proto: 1,
          sampleRate: 16000,
          frameMs: 20,
          format: 's16le',
          channels: 1,
          mode: 'standalone',
          sessionId: '',
        ),
        t0,
      );
      expect(s.attempt, 0);
      expect(lastSystemKey(s), MessageKey.callReconnected);
    });

    test('speech_start / speech_end drive userSpeaking', () {
      expect(
        reduceEvent(connected(), const SpeechStartEvent(), t0).userSpeaking,
        isTrue,
      );
      final s = connected();
      expect(
        reduceEvent(
          reduceEvent(s, const SpeechStartEvent(), t0),
          const SpeechEndEvent(),
          t0,
        ).userSpeaking,
        isFalse,
      );
    });

    test('partial/segment_final assemble liveUser from committed + text', () {
      var s = connected();
      s = reduceEvent(s, const PartialEvent('今天下'), t0);
      expect(s.liveUser, '今天下');
      // segment_final finalises the WHOLE segment (§4.7: committedSegments
      // += text; liveUser = committedSegments), replacing the partial.
      s = reduceEvent(s, const SegmentFinalEvent('今天下午'), t0);
      expect(s.committedSegments, ['今天下午']);
      expect(s.liveUser, '今天下午');
      s = reduceEvent(s, const PartialEvent('開會'), t0);
      expect(s.liveUser, '今天下午開會');
      // turn_final commits the final text and clears the live buffers.
      s = reduceEvent(s, const TurnFinalEvent(7, '今天下午開會。'), t0);
      expect(s.liveUser, '');
      expect(s.committedSegments, isEmpty);
      final user = s.captions.where((c) => c.role == CaptionRole.user);
      expect(user.map((c) => c.text), ['今天下午開會。']);
      expect(user.single.finalized, isTrue);
      expect(user.single.turn, 7);
      // exactly one live line during the turn, finalised in place:
      var live = connected();
      live = reduceEvent(live, const PartialEvent('ab'), t0);
      live = reduceEvent(live, const PartialEvent('abc'), t0);
      expect(
        live.captions.where((c) => c.role == CaptionRole.user).length,
        1,
      );
      expect(live.captions.last.text, 'abc');
      expect(live.captions.last.finalized, isFalse);
    });

    test('turn_final with no live line still finalises a line', () {
      final s = reduceEvent(connected(), const TurnFinalEvent(2, '裸 turn'), t0);
      expect(s.captions.last.role, CaptionRole.user);
      expect(s.captions.last.finalized, isTrue);
      expect(s.captions.last.text, '裸 turn');
    });

    test('route brain → pending with brainSince; route front untouched', () {
      final s = reduceEvent(connected(), const RouteEvent(1, 'brain'), t0);
      expect(s.brain, BrainIndicator.pending);
      expect(s.brainSince, t0);
      expect(
        reduceEvent(connected(), const RouteEvent(1, 'front'), t0).brain,
        BrainIndicator.none,
      );
    });

    test('brain_queued → brain_pending → brain_result indicator chain', () {
      var s = connected(target: bound);
      s = reduceEvent(
        s,
        const BrainQueuedEvent(4, 'session_busy', 2),
        t0,
      );
      expect(s.brain, BrainIndicator.queued);
      expect(s.queuedReason, 'session_busy');
      s = reduceEvent(s, BrainPendingEvent(4, '好，我去處理。'), later(5));
      expect(s.brain, BrainIndicator.pending);
      expect(s.brainSince, later(5)); // re-counts (§4.7 brain_pending row)
      expect(s.queuedReason, isNull);
      s = reduceEvent(s, const BrainResultEvent(4, 12.5), later(20));
      expect(s.brain, BrainIndicator.none);
      expect(lastSystemKey(s), MessageKey.callBrainWritten);
    });

    test('brain_result in standalone adds no caption', () {
      final s = reduceEvent(
        connected(),
        const BrainResultEvent(1, 3.0),
        t0,
      );
      expect(s.captions, isEmpty);
    });

    test('reply_text adds an assistant line with source', () {
      final s = reduceEvent(
        connected(),
        const ReplyTextEvent(3, 'brain', '下午三點有會議。'),
        t0,
      );
      expect(s.captions.single.role, CaptionRole.assistant);
      expect(s.captions.single.source, 'brain');
      expect(s.captions.single.text, '下午三點有會議。');
    });

    test('audio_start filler sets fillerHint; tts does not touch captions', () {
      final f = reduceEvent(
        connected(),
        const AudioStartEvent('filler', '好，我去處理一下。', 900),
        t0,
      );
      expect(f.fillerHint, '好，我去處理一下。');
      final t = reduceEvent(
        connected(),
        const AudioStartEvent('tts', '', 1200),
        t0,
      );
      expect(t.fillerHint, isNull);
      expect(t.captions, isEmpty);
    });

    test('audio_end(filler) clears hint; audio_end(tts) does not', () {
      final withHint = reduceEvent(
        connected(),
        const AudioStartEvent('filler', '嗯', 300),
        t0,
      );
      expect(
        reduceEvent(withHint, const AudioEndEvent('filler'), t0).fillerHint,
        isNull,
      );
      expect(
        reduceEvent(withHint, const AudioEndEvent('tts'), t0).fillerHint,
        '嗯',
      );
    });

    test('audio_stop clears hint and assistantSpeaking (idempotent)', () {
      var s = connected();
      s = reduceEvent(
        s,
        const AudioStartEvent('filler', '嗯', 100),
        t0,
      );
      s = s.copyWith(assistantSpeaking: true);
      s = reduceEvent(s, const AudioStopEvent('filler'), t0);
      expect(s.assistantSpeaking, isFalse);
      expect(s.fillerHint, isNull);
      final again = reduceEvent(s, const AudioStopEvent('tts'), t0);
      expect(again.assistantSpeaking, isFalse); // flush is idempotent (§3.1)
    });

    test('barge_in equals audio_stop plus bargeAt', () {
      final s = reduceEvent(
        connected(
          captions: const [
            CaptionLine(role: CaptionRole.assistant, text: '長故事……'),
          ],
        ).copyWith(assistantSpeaking: true, fillerHint: '嗯'),
        const BargeInEvent(true),
        t0,
      );
      expect(s.assistantSpeaking, isFalse);
      expect(s.fillerHint, isNull);
      expect(s.bargeAt, t0);
    });

    test('local_mute and unknown events are ignored', () {
      final s = connected();
      expect(
        reduceEvent(s, const UnknownEvent('local_mute'), t0).captions,
        isEmpty,
      );
      expect(identical(reduceEvent(s, const UnknownEvent('x'), t0), s), isTrue);
    });

    test('error rows: tts / front / front-timeout / brain / queue_timeout', () {
      final tts = reduceEvent(
        connected(),
        const GatewayErrorEvent('tts', 'boom', 'detail'),
        t0,
      );
      expect(lastSystemKey(tts), MessageKey.callErrTts);
      final front = reduceEvent(
        connected(),
        const GatewayErrorEvent('front', null, null),
        t0,
      );
      expect(lastSystemKey(front), MessageKey.callErrFront);
      final frontTo = reduceEvent(
        connected(),
        const GatewayErrorEvent('front', 'timeout', null),
        t0,
      );
      expect(lastSystemKey(frontTo), MessageKey.callErrFrontTimeout);
      var brain = reduceEvent(
        connected().copyWith(brain: BrainIndicator.pending),
        const GatewayErrorEvent('brain', 'http_500', 'x'),
        t0,
      );
      expect(lastSystemKey(brain), MessageKey.callErrBrain);
      expect(brain.brain, BrainIndicator.none);
      brain = reduceEvent(
        connected().copyWith(brain: BrainIndicator.queued),
        const GatewayErrorEvent('brain', 'queue_timeout', null),
        t0,
      );
      expect(lastSystemKey(brain), MessageKey.callErrBrainQueueTimeout);
      expect(brain.brain, BrainIndicator.none);
    });

    test('pong stamps lastPongAt', () {
      final s = reduceEvent(connected(), const PongEvent(3), later(4));
      expect(s.lastPongAt, later(4));
    });
  });

  group('caption ring (D21)', () {
    test('more than 50 lines drops the oldest', () {
      var s = connected();
      for (var i = 0; i < 60; i++) {
        s = reduceEvent(s, ReplyTextEvent(i, 'front', '行 $i'), t0);
      }
      expect(s.captions.length, CallState.maxCaptions);
      expect(s.captions.first.text, '行 10');
      expect(s.captions.last.text, '行 59');
    });
  });

  group('§4.2 close branches', () {
    test('4401 → error(auth), 4409 → error(busy), 4400 → error(protocol)', () {
      expect(
        reduceClose(connected(), closeAuth, everConnected: true).errorKind,
        CallErrorKind.auth,
      );
      expect(
        reduceClose(connected(), closeBusy, everConnected: true).phase,
        CallPhase.error,
      );
      final p = reduceClose(connected(), closeBadHello, everConnected: true);
      expect((p.phase, p.errorKind), (CallPhase.error, CallErrorKind.protocol));
    });

    test('1001 → ended with gateway-closed system line', () {
      final s = reduceClose(connected(), closeGoingAway, everConnected: true);
      expect(s.phase, CallPhase.ended);
      expect(lastSystemKey(s), MessageKey.callGatewayClosed);
    });

    test('1000 → ended, no caption', () {
      final s = reduceClose(connected(), closeNormal, everConnected: true);
      expect(s.phase, CallPhase.ended);
      expect(s.captions, isEmpty);
    });

    test('4408 / 4410 → connecting with attempt+1', () {
      for (final code in [closeHelloTimeout, closeStalled]) {
        final s = reduceClose(
          CallState(target: standalone, phase: CallPhase.connecting),
          code,
          everConnected: code == closeStalled,
        );
        expect((s.phase, s.attempt), (CallPhase.connecting, 1),
            reason: 'code $code');
      }
    });

    test('1006 after a healthy connection → attempt+1, wantMuted kept', () {
      final s = reduceClose(
        connected(wantMuted: true),
        1006,
        everConnected: true,
      );
      expect((s.phase, s.attempt, s.wantMuted), (CallPhase.connecting, 1, true));
    });

    test('first-connection socket failure → error(gatewayDown), no retry', () {
      final s = reduceClose(
        CallState(target: standalone, phase: CallPhase.connecting),
        null,
        everConnected: false,
      );
      expect(
        (s.phase, s.errorKind),
        (CallPhase.error, CallErrorKind.gatewayDown),
      );
    });

    test('attempt 3 dropping again → error(network)', () {
      final s = reduceClose(
        CallState(
          target: standalone,
          phase: CallPhase.connecting,
          attempt: 3,
        ),
        1006,
        everConnected: true,
      );
      expect(
        (s.phase, s.errorKind),
        (CallPhase.error, CallErrorKind.network),
      );
    });
  });
}
