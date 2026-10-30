/// Pure event → state transitions (PLAN-VOICEUI §4.7 "state change" column
/// and the §4.2 close branches). NO I/O here: playback flushes, ping
/// timers and socket work belong to the controller (call7b). rttMs is set
/// by the controller when a pong answers a known ping (§4.7 pong row);
/// this reducer only stamps lastPongAt.
library;

import '../../l10n/message_key.dart';
import '../../l10n/ui_message.dart';
import 'call_protocol.dart';
import 'call_state.dart';

/// Apply one gateway event. `now` is injected so tests are deterministic.
CallState reduceEvent(CallState s, GatewayEvent e, DateTime now) => switch (e) {
  // ready: connecting → connected/muted, attempt back to 0; a reconnect
  // (attempt > 0) adds the "reconnected" system line (§4.7/§4.2).
  ReadyEvent() => s.copyWith(
    phase: s.wantMuted ? CallPhase.muted : CallPhase.connected,
    attempt: 0,
    errorKind: null,
    captions: s.attempt > 0
        ? _add(
            s.captions,
            const CaptionLine(
              role: CaptionRole.system,
              system: UiMessage.local(MessageKey.callReconnected),
            ),
          )
        : s.captions,
  ),
  SpeechStartEvent() => s.copyWith(userSpeaking: true),
  PartialEvent(:final text) => s.copyWith(
    liveUser: '${s.committedSegments.join()}$text',
    captions: _upsertLiveUser(s.captions, s.committedSegments, text),
  ),
  SpeechEndEvent() => s.copyWith(userSpeaking: false),
  SegmentFinalEvent(:final text) => () {
    final committed = [...s.committedSegments, text];
    return s.copyWith(
      committedSegments: committed,
      liveUser: committed.join(),
      captions: _upsertLiveUser(s.captions, committed, ''),
    );
  }(),
  TurnFinalEvent(:final turn, :final text) => s.copyWith(
    committedSegments: const [],
    liveUser: '',
    captions: _finalizeUser(s.captions, turn, text),
  ),
  RouteEvent(:final route) => route == 'brain'
      ? s.copyWith(brain: BrainIndicator.pending, brainSince: now)
      : s,
  BrainQueuedEvent(:final reason) => s.copyWith(
    brain: BrainIndicator.queued,
    queuedReason: reason,
  ),
  BrainPendingEvent() => s.copyWith(
    brain: BrainIndicator.pending,
    brainSince: now,
    queuedReason: null,
  ),
  BrainResultEvent() => s.copyWith(
    brain: BrainIndicator.none,
    brainSince: null,
    queuedReason: null,
    captions: s.bound
        ? _add(
            s.captions,
            const CaptionLine(
              role: CaptionRole.system,
              system: UiMessage.local(MessageKey.callBrainWritten),
            ),
          )
        : s.captions,
  ),
  ReplyTextEvent(:final turn, :final source, :final text) => s.copyWith(
    captions: _add(
      s.captions,
      CaptionLine(
        role: CaptionRole.assistant,
        text: text,
        turn: turn,
        source: source,
      ),
    ),
  ),
  AudioStartEvent(:final kind, :final text) => kind == 'filler'
      ? s.copyWith(fillerHint: text)
      : s,
  AudioEndEvent(:final kind) => kind == 'filler'
      ? s.copyWith(fillerHint: null)
      : s, // tts end ≠ drained: assistantSpeaking waits for onDrained (§4.7)
  AudioStopEvent() => s.copyWith(assistantSpeaking: false, fillerHint: null),
  BargeInEvent() => s.copyWith(assistantSpeaking: false, fillerHint: null, bargeAt: now),
  GatewayErrorEvent(:final where, :final kind) => switch (where) {
    'tts' => s.copyWith(
      captions: _add(
        s.captions,
        const CaptionLine(
          role: CaptionRole.system,
          system: UiMessage.local(MessageKey.callErrTts),
        ),
      ),
    ),
    'front' => s.copyWith(
      captions: _add(
        s.captions,
        CaptionLine(
          role: CaptionRole.system,
          system: UiMessage.local(
            kind == 'timeout'
                ? MessageKey.callErrFrontTimeout
                : MessageKey.callErrFront,
          ),
        ),
      ),
    ),
    'brain' => s.copyWith(
      brain: BrainIndicator.none,
      brainSince: null,
      captions: _add(
        s.captions,
        CaptionLine(
          role: CaptionRole.system,
          system: UiMessage.local(
            kind == 'queue_timeout'
                ? MessageKey.callErrBrainQueueTimeout
                : MessageKey.callErrBrain,
          ),
        ),
      ),
    ),
    _ => s, // unknown `where`: diagnostics only, silent (§4.7)
  },
  PongEvent() => s.copyWith(lastPongAt: now),
  UnknownEvent() => s, // §2 rule 3: the future may add events; ignore them.
};

/// §4.2 close/transport branches. `everConnected` separates "the socket
/// never opened on the FIRST attempt" (gatewayDown, no retry — D16) from a
/// drop after a working connection.
CallState reduceClose(
  CallState s,
  int? code, {
  required bool everConnected,
}) {
  switch (code) {
    case closeBadHello:
      return s.copyWith(
        phase: CallPhase.error,
        errorKind: CallErrorKind.protocol,
      );
    case closeAuth:
      return s.copyWith(phase: CallPhase.error, errorKind: CallErrorKind.auth);
    case closeBusy:
      return s.copyWith(phase: CallPhase.error, errorKind: CallErrorKind.busy);
    case closeGoingAway:
      return s.copyWith(
        phase: CallPhase.ended,
        errorKind: null,
        captions: _add(
          s.captions,
          const CaptionLine(
            role: CaptionRole.system,
            system: UiMessage.local(MessageKey.callGatewayClosed),
          ),
        ),
      );
    case closeHelloTimeout:
    case closeStalled:
      return _retry(s);
    case closeNormal:
      return s.copyWith(phase: CallPhase.ended, errorKind: null);
    default:
      // 1006 / null (socket open failure): reconnect while a healthy
      // connection or a retry attempt is in play; the very first open
      // failure means the gateway is simply not running (§4.2).
      if (everConnected || s.attempt > 0) return _retry(s);
      return s.copyWith(
        phase: CallPhase.error,
        errorKind: CallErrorKind.gatewayDown,
      );
  }
}

/// One retry step (§4.2/D16): attempt+1, and attempting a 4th try is the
/// network error instead.
CallState _retry(CallState s) {
  final next = s.attempt + 1;
  if (next >= 4) {
    return s.copyWith(
      phase: CallPhase.error,
      errorKind: CallErrorKind.network,
      attempt: s.attempt,
    );
  }
  return s.copyWith(
    phase: CallPhase.connecting,
    attempt: next,
    errorKind: null,
  );
}

/// Append with the 50-line ring (§4.3 item 3 / D21): oldest lines drop.
List<CaptionLine> _add(List<CaptionLine> caps, CaptionLine line) {
  final out = [...caps, line];
  return out.length > CallState.maxCaptions
      ? out.sublist(out.length - CallState.maxCaptions)
      : out;
}

/// Keep ONE unfinalized user line at the tail, live text = committed +
/// partial (§4.7 partial/segment rows).
List<CaptionLine> _upsertLiveUser(
  List<CaptionLine> caps,
  List<String> committed,
  String partial,
) {
  final text = [...committed, partial].join();
  if (caps.isNotEmpty &&
      caps.last.role == CaptionRole.user &&
      !caps.last.finalized) {
    final out = [...caps];
    out[out.length - 1] = CaptionLine(
      role: CaptionRole.user,
      text: text,
      finalized: false,
      turn: caps.last.turn,
    );
    return out;
  }
  return _add(caps, CaptionLine(role: CaptionRole.user, text: text, finalized: false));
}

/// turn_final: the live line becomes the finalized line with the FINAL
/// text; a turn_final with no live line adds one (§4.7 turn_final row).
List<CaptionLine> _finalizeUser(
  List<CaptionLine> caps,
  int turn,
  String text,
) {
  if (caps.isNotEmpty &&
      caps.last.role == CaptionRole.user &&
      !caps.last.finalized) {
    final out = [...caps];
    out[out.length - 1] = CaptionLine(
      role: CaptionRole.user,
      text: text,
      finalized: true,
      turn: turn,
    );
    return out;
  }
  return _add(
    caps,
    CaptionLine(role: CaptionRole.user, text: text, finalized: true, turn: turn),
  );
}
