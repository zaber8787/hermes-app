/// Audio seam for the voice call (PLAN-VOICEUI §4.1/§4.8). Everything the
/// controller needs from a platform: mic permission, 640-byte capture
/// frames, playback with an explicit flush (barge-in must clear the local
/// buffer the instant it arrives, §3.1), and the drained signal so
/// assistantSpeaking follows the LOCAL buffer, not audio_end (§4.7).
library;

import 'package:flutter/foundation.dart';

import 'call_audio_native.dart'
    if (dart.library.js_interop) 'call_audio_web.dart' as impl;

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

/// Platform pick per §4.8: Android rides the microphone-type foreground
/// service (call_audio_native.dart), Web rides getUserMedia + the two
/// worklets in web/voice_worklets.js (call_audio_web.dart); everything
/// else honestly reports `unsupported` (§4.6 callUnsupported) instead of
/// half-working. Same conditional-import shape as transport.dart:1.
CallAudio newCallAudio() => impl.newCallAudio();

/// Every promise empty, permission honestly `unsupported` (§4.2 row 1:
/// `unsupported` → error(unsupported), no dial attempt).
class CallAudioUnsupported implements CallAudio {
  @override
  Future<MicPermission> ensurePermission() async => MicPermission.unsupported;
  @override
  Future<void> start({required String title, required bool speaker}) async {}
  @override
  Stream<Uint8List> get frames => const Stream<Uint8List>.empty();
  @override
  Stream<CallAudioSignal> get signals => const Stream<CallAudioSignal>.empty();
  @override
  void play(Uint8List pcm) {}
  @override
  void flushPlayback() {}
  @override
  Stream<void> get drained => const Stream<void>.empty();
  @override
  Future<void> setSpeaker(bool on) async {}
  @override
  Future<void> stop() async {}
}
