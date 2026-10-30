/// Call state types (PLAN-VOICEUI §4.2/§4.8). Immutable value objects only:
/// no I/O, no singletons — the reducer in `call_reducer.dart` is the only
/// thing that transitions them in this layer.
library;

import 'package:flutter/foundation.dart';

import '../../l10n/ui_message.dart';
import '../../models/session.dart';

/// Exactly the six phases from the task spec (§4.2); a reconnect is
/// `connecting` with `attempt > 0`, never a seventh state.
enum CallPhase { idle, connecting, connected, muted, ended, error }

/// §4.6 — one MessageKey per kind, both catalogs.
enum CallErrorKind {
  micDenied,
  micPermanentlyDenied,
  unsupported,
  gatewayDown,
  auth,
  busy,
  network,
  protocol,
}

/// Main-brain indicator row state (§4.3 item 2).
enum BrainIndicator { none, pending, queued }

enum CaptionRole { user, assistant, system }

/// One caption-stream line (§4.3 item 3). System lines carry a localisable
/// [system] message; `text` keeps the raw text for user/assistant lines.
@immutable
class CaptionLine {
  const CaptionLine({
    required this.role,
    this.text = '',
    this.finalized = true,
    this.turn,
    this.source,
    this.system,
  });
  final CaptionRole role;
  final String text;
  final bool finalized;
  final int? turn;

  /// 'front' | 'brain' for assistant lines (§4.7 reply_text).
  final String? source;
  final UiMessage? system;
}

/// What the call is attached to (§4.8). [sessionId] follows the hello
/// semantics of §3.2/D3: a non-empty string = bound; `''` = standalone (the
/// App always sends the key); it is never null for App-created targets.
sealed class CallTarget {
  const CallTarget();
  String? get sessionId;
}

class SessionCallTarget extends CallTarget {
  const SessionCallTarget(this.session);
  final Session session;
  @override
  String? get sessionId => session.id;
}

class StandaloneCallTarget extends CallTarget {
  const StandaloneCallTarget();
  @override
  String? get sessionId => '';
}

/// The complete immutable snapshot a `CallController` exposes (§4.8 field
/// list). `copyWith` keeps every field optional-by-absence.
@immutable
class CallState {
  const CallState({
    required this.target,
    this.phase = CallPhase.idle,
    this.attempt = 0,
    this.errorKind,
    this.wantMuted = false,
    this.captions = const [],
    this.committedSegments = const [],
    this.liveUser = '',
    this.userSpeaking = false,
    this.assistantSpeaking = false,
    this.brain = BrainIndicator.none,
    this.brainSince,
    this.queuedReason,
    this.fillerHint,
    this.bargeAt,
    this.speakerOn = true,
    this.rttMs,
    this.lastPongAt,
  });

  static const maxCaptions = 50;

  final CallTarget target;
  final CallPhase phase;

  /// Reconnect counter: 0 = first connect attempt (§4.2/D16).
  final int attempt;
  final CallErrorKind? errorKind;

  /// User intent, not socket truth — a mute survives a reconnect (§4.2).
  final bool wantMuted;
  final List<CaptionLine> captions;

  /// `segment_final` texts committed during the CURRENT turn (§4.7 partial
  /// row): liveUser = committed segments + in-flight partial text.
  final List<String> committedSegments;
  final String liveUser;
  final bool userSpeaking;

  /// Local playback buffer non-empty (§4.7 binary row) — NOT `audio_end`.
  final bool assistantSpeaking;
  final BrainIndicator brain;
  final DateTime? brainSince;
  final String? queuedReason;
  final String? fillerHint;
  final DateTime? bargeAt;
  final bool speakerOn;
  final int? rttMs;
  final DateTime? lastPongAt;

  bool get bound => (target.sessionId ?? '').isNotEmpty;

  /// Nullable fields use a presence sentinel so an explicit `null` CLEARS
  /// (fillerHint, brainSince, ... must be clearable); absence keeps.
  CallState copyWith({
    CallTarget? target,
    CallPhase? phase,
    int? attempt,
    Object? errorKind = _keep,
    bool? wantMuted,
    List<CaptionLine>? captions,
    List<String>? committedSegments,
    String? liveUser,
    bool? userSpeaking,
    bool? assistantSpeaking,
    BrainIndicator? brain,
    Object? brainSince = _keep,
    Object? queuedReason = _keep,
    Object? fillerHint = _keep,
    Object? bargeAt = _keep,
    bool? speakerOn,
    Object? rttMs = _keep,
    Object? lastPongAt = _keep,
  }) => CallState(
    target: target ?? this.target,
    phase: phase ?? this.phase,
    attempt: attempt ?? this.attempt,
    errorKind: errorKind == _keep
        ? this.errorKind
        : errorKind as CallErrorKind?,
    wantMuted: wantMuted ?? this.wantMuted,
    captions: captions ?? this.captions,
    committedSegments: committedSegments ?? this.committedSegments,
    liveUser: liveUser ?? this.liveUser,
    userSpeaking: userSpeaking ?? this.userSpeaking,
    assistantSpeaking: assistantSpeaking ?? this.assistantSpeaking,
    brain: brain ?? this.brain,
    brainSince: brainSince == _keep
        ? this.brainSince
        : brainSince as DateTime?,
    queuedReason: queuedReason == _keep
        ? this.queuedReason
        : queuedReason as String?,
    fillerHint: fillerHint == _keep ? this.fillerHint : fillerHint as String?,
    bargeAt: bargeAt == _keep ? this.bargeAt : bargeAt as DateTime?,
    speakerOn: speakerOn ?? this.speakerOn,
    rttMs: rttMs == _keep ? this.rttMs : rttMs as int?,
    lastPongAt: lastPongAt == _keep
        ? this.lastPongAt
        : lastPongAt as DateTime?,
  );
}

const _keep = Object();
