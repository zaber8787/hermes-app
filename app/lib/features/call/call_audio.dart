/// Audio seam for the voice call (PLAN-VOICEUI §4.1/§4.8). Everything the
/// controller needs from a platform: mic permission, 640-byte capture
/// frames, playback with an explicit flush (barge-in must clear the local
/// buffer the instant it arrives, §3.1), and the drained signal so
/// assistantSpeaking follows the LOCAL buffer, not audio_end (§4.7).
library;

import 'package:flutter/foundation.dart';

enum MicPermission { granted, denied, permanentlyDenied, unsupported }

/// Out-of-band signals from the platform audio layer (§4.8).
sealed class CallAudioSignal {
  const CallAudioSignal();
}

/// Android audio focus lost (incoming call) → auto-mute, D20.
class FocusLost extends CallAudioSignal {
  const FocusLost();
}

/// Notification "hang up" action, or Web pagehide (§4.4).
class HangupRequested extends CallAudioSignal {
  const HangupRequested();
}

/// Per-second capture stats for the §5.3 stats line; inputLatencyMs null
/// when the platform cannot report it (never fake a number).
class CaptureStats extends CallAudioSignal {
  const CaptureStats(this.inputLatencyMs);
  final double? inputLatencyMs;
}

abstract class CallAudio {
  /// Checked before the socket is even opened; denied paths map straight
  /// to CallErrorKind (§4.2 first row).
  Future<MicPermission> ensurePermission();

  /// Starts capture (and the Android foreground service). [title] feeds
  /// the notification; [speaker] the initial route (D9: speaker on).
  Future<void> start({required String title, required bool speaker});

  /// 640-byte 16 kHz mono s16le frames, 20 ms apart (§3.1).
  Stream<Uint8List> get frames;
  Stream<CallAudioSignal> get signals;

  /// One downlink frame into the playback buffer; [flushPlayback] clears
  /// it immediately and must be idempotent (§3.1 stop row).
  void play(Uint8List pcm);
  void flushPlayback();

  /// Fires when the local buffer has gone non-empty → empty (§4.7
  /// audio_end row: UI speech indicator drains with this, not audio_end).
  Stream<void> get drained;

  Future<void> setSpeaker(bool on);
  Future<void> stop();
}

bool get callSupported =>
    kIsWeb || defaultTargetPlatform == TargetPlatform.android;

// TODO(call7b): newCallAudio() — conditional factory per §4.8:
// CallAudioAndroid (MethodChannel 'hermes/voice-call' + uplink
// EventChannel + downlink BasicMessageChannel, Kotlin VoiceCallService
// next rod), CallAudioWeb (package:web + voice_worklets.js worklets,
// web rod), CallAudioUnsupported elsewhere (ensurePermission →
// unsupported).
