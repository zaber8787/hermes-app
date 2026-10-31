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

/// The live capture track ended on its own (device unplugged, TASK-MICPICK
/// R4) — never fired by our own stop()/switchInput().
class InputLost extends CallAudioSignal {
  const InputLost();
}

/// One system audio input (TASK-MICPICK R1). [label] may be empty (the
/// platform hid it); the UI then numbers it "Microphone N". A null id
/// anywhere in this seam means "system default" (no deviceId constraint).
@immutable
class AudioInputDevice {
  const AudioInputDevice({required this.id, required this.label});
  final String id;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is AudioInputDevice && other.id == id && other.label == label;

  @override
  int get hashCode => Object.hash(id, label);
}

/// Pseudo-entries Chrome adds next to the real devices; our own "system
/// default" item already stands for them, listing them would duplicate it.
const _pseudoInputIds = {'default', 'communications'};

/// R1 filter over a raw enumerateDevices() dump: audio inputs only, minus
/// the pseudo-entries, minus anonymous rows (an empty deviceId is what a
/// browser hands out before mic permission — unusable as a constraint),
/// de-duplicated by id in platform order.
List<AudioInputDevice> filterAudioInputs(
  Iterable<({String kind, String id, String label})> raw,
) {
  final seen = <String>{};
  return [
    for (final d in raw)
      if (d.kind == 'audioinput' &&
          d.id.isNotEmpty &&
          !_pseudoInputIds.contains(d.id) &&
          seen.add(d.id))
        AudioInputDevice(id: d.id, label: d.label.trim()),
  ];
}

/// R4: the device id a call should actually open. A saved id that is no
/// longer present (unplugged, other machine's id) falls back to the system
/// default (null) instead of failing the call.
String? resolveInputDevice(String? saved, List<AudioInputDevice> available) {
  if (saved == null || saved.isEmpty) return null;
  return available.any((d) => d.id == saved) ? saved : null;
}

abstract class CallAudio {
  /// Checked before the socket is even opened; denied paths map straight
  /// to CallErrorKind (§4.2 first row).
  Future<MicPermission> ensurePermission();

  /// Starts capture (and the Android foreground service). [title] feeds
  /// the notification; [speaker] the initial route (D9: speaker on);
  /// [deviceId] the input to open, null = system default (MICPICK R2).
  Future<void> start({
    required String title,
    required bool speaker,
    String? deviceId,
  });

  /// System audio inputs, empty when the platform cannot enumerate them
  /// (Android today: only the system default is offered, R4). Callers run
  /// [ensurePermission] first — before it a browser only returns
  /// anonymous rows, which [filterAudioInputs] drops.
  Future<List<AudioInputDevice>> listInputs();

  /// MICPICK R3: swap ONLY the capture source of a running call (old
  /// stream stopped after the new one is live). Throws and leaves the
  /// current input untouched when the new device cannot be opened.
  Future<void> switchInput(String? deviceId);

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
  Future<void> start({
    required String title,
    required bool speaker,
    String? deviceId,
  }) async {}
  @override
  Future<List<AudioInputDevice>> listInputs() async => const [];
  @override
  Future<void> switchInput(String? deviceId) async =>
      throw UnsupportedError('no capture on this platform');
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
