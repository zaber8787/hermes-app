/// Android audio for the voice call (PLAN-VOICEUI §4.8 row
/// call_audio_native.dart). Capture AND playback live inside the Kotlin
/// `VoiceCallService` (microphone-type foreground service, §4.4) so the
/// call keeps running with the Activity paused; Dart only speaks the three
/// channels:
///
/// * MethodChannel `hermes/voice-call` — micPermission / requestMic / start
///   / stop / setSpeaker / openAppSettings.
/// * EventChannel `hermes/voice-call/uplink` — Uint8List = one 640-byte
///   capture frame; Map = signal {type: focusLost|hangupRequested|stats|
///   drained, input_latency_ms}.
/// * BasicMessageChannel `hermes/voice-call/downlink` (BinaryCodec) — one
///   message per PCM frame; a ZERO-length message is the flush command, so
///   play/flush ordering rides one guaranteed-ordered channel (§4.1).
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'call_audio.dart';

CallAudio newCallAudio() => defaultTargetPlatform == TargetPlatform.android
    ? CallAudioAndroid()
    : CallAudioUnsupported();

class CallAudioAndroid implements CallAudio {
  static const _method = MethodChannel('hermes/voice-call');
  static const _uplink = EventChannel('hermes/voice-call/uplink');
  static const _downlink = BasicMessageChannel<Object?>(
      'hermes/voice-call/downlink', BinaryCodec());

  final _frames = StreamController<Uint8List>.broadcast();
  final _signals = StreamController<CallAudioSignal>.broadcast();
  final _drained = StreamController<void>.broadcast();
  StreamSubscription<Object?>? _uplinkSub;
  bool _started = false;

  @override
  Future<MicPermission> ensurePermission() async {
    final state = await _method.invokeMethod<String>('micPermission');
    if (state == 'granted') return MicPermission.granted;
    // §4.4: anything but granted goes through the ONE permission request
    // (request code 2404); Kotlin distinguishes denied vs permanentlyDenied
    // via shouldShowRequestPermissionRationale after a prior ask.
    final requested = await _method.invokeMethod<String>('requestMic');
    return switch (requested) {
      'granted' => MicPermission.granted,
      'permanentlyDenied' => MicPermission.permanentlyDenied,
      _ => MicPermission.denied,
    };
  }

  @override
  Future<void> start({required String title, required bool speaker}) async {
    // Subscribe BEFORE the service starts producing, or the first frames
    // fall on the floor (EventChannel buffers only while listened).
    await _uplinkSub?.cancel();
    _uplinkSub = _uplink.receiveBroadcastStream().listen(
          _onUplink,
          // VoiceCallService never sink.errors; swallow rather than let a
          // stray native error kill the frame pump mid-call.
          onError: (Object _) {},
        );
    try {
      await _method
          .invokeMethod('start', {'title': title, 'speaker': speaker});
      _started = true;
    } on Object {
      await _uplinkSub?.cancel();
      _uplinkSub = null;
      rethrow;
    }
  }

  void _onUplink(Object? event) {
    if (event is Uint8List) {
      _frames.add(event);
      return;
    }
    if (event is! Map) return;
    switch (event['type']) {
      case 'focusLost':
        _signals.add(const FocusLost());
      case 'hangupRequested':
        _signals.add(const HangupRequested());
      case 'drained':
        _drained.add(null);
      case 'stats':
        final ms = (event['input_latency_ms'] as num?)?.toDouble();
        _signals.add(CaptureStats(ms));
    }
  }

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  Stream<CallAudioSignal> get signals => _signals.stream;

  @override
  void play(Uint8List pcm) {
    // sublistView: the frame may be a view over a bigger buffer; BinaryCodec
    // must carry exactly these bytes.
    _downlink.send(ByteData.sublistView(pcm));
  }

  @override
  void flushPlayback() {
    // Length-0 message = flush (§4.1). Idempotent by construction (§3.1):
    // Kotlin clears the queue and restarts the AudioTrack each time.
    _downlink.send(ByteData(0));
  }

  @override
  Stream<void> get drained => _drained.stream;

  @override
  Future<void> setSpeaker(bool on) =>
      _method.invokeMethod('setSpeaker', {'on': on});

  @override
  Future<void> stop() async {
    final sub = _uplinkSub;
    _uplinkSub = null;
    final wasStarted = _started;
    _started = false;
    await sub?.cancel();
    if (wasStarted) await _method.invokeMethod('stop');
  }
}
