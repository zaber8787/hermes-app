/// Browser audio for the voice call (PLAN-VOICEUI §4.1/§4.8 row
/// call_audio_web.dart). getUserMedia runs with the browser's own AEC/AGC/
/// NS on (§4.1 point 3); the AudioContext stays at the device default rate
/// (Firefox rejects MediaStream sources into a differently-sampled
/// context), and web/voice_worklets.js does the 16k resampling both ways.
/// Frames are worklet-event-driven, never a Dart timer, so background-tab
/// timer throttling cannot starve the uplink (§4.4).
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'call_audio.dart';

CallAudio newCallAudio() => CallAudioWeb();

class CallAudioWeb implements CallAudio {
  web.AudioContext? _ctx;
  web.MediaStream? _stream;
  web.AudioWorkletNode? _capture;
  web.AudioWorkletNode? _playback;

  final _frames = StreamController<Uint8List>.broadcast();
  final _signals = StreamController<CallAudioSignal>.broadcast();
  final _drained = StreamController<void>.broadcast();

  // pagehide (§4.4): tell the controller to hang up synchronously so the
  // gateway sees a clean close before the tab dies. The JS function object
  // must be identical for add/removeEventListener, hence the cached one.
  late final JSFunction _onPagehide =
      ((web.Event _) => _signals.add(const HangupRequested())).toJS;
  bool _pagehideArmed = false;

  @override
  Future<MicPermission> ensurePermission() async {
    // getUserMedia only exists in a secure context (§0.2 point 3); an
    // http:// deployment honestly cannot call.
    if (!web.window.isSecureContext) return MicPermission.unsupported;
    if (_stream != null) return MicPermission.granted;
    try {
      _stream = await _openStream();
      return MicPermission.granted;
    } on Object catch (e) {
      final name = _errorName(e);
      if (name == 'NotAllowedError' || name == 'SecurityError') {
        return MicPermission.denied;
      }
      if (name == 'NotFoundError' || name == 'OverconstrainedError') {
        return MicPermission.unsupported;
      }
      rethrow;
    }
  }

  /// The rejected getUserMedia promise carries a JS DOMException; reading
  /// its `name` must survive a pure-Dart throw (no interop `is` check —
  /// that is the exact platform-consistency trap the lint warns about).
  static String _errorName(Object e) {
    try {
      final js = e as JSAny;
      if (js.isA<web.DOMException>()) return (js as web.DOMException).name;
    } on Object {
      // ignore: avoid_catches_without_on_clauses
    }
    return '';
  }

  /// §4.1: echoCancellation + noiseSuppression + autoGainControl, mono.
  /// No sampleRate constraint — the capture worklet downsamples (§4.1
  /// point 3, Firefox rule).
  Future<web.MediaStream> _openStream() {
    final track = web.MediaTrackConstraints(
      echoCancellation: true.toJS,
      autoGainControl: true.toJS,
      noiseSuppression: true.toJS,
      channelCount: 1.toJS,
    );
    final constraints = web.MediaStreamConstraints(audio: track);
    return web.window.navigator.mediaDevices.getUserMedia(constraints).toDart;
  }

  String _moduleUrl() => Uri.base.resolve('voice_worklets.js').toString();

  @override
  Future<void> start({required String title, required bool speaker}) async {
    final existing = _ctx;
    if (existing != null) {
      // Reconnect keeps the same graph; just make sure audio is running.
      if (existing.state == 'suspended') await existing.resume().toDart;
      return;
    }
    final ctx = web.AudioContext();
    _ctx = ctx;
    try {
      await ctx.audioWorklet.addModule(_moduleUrl()).toDart;
      final stream = _stream ?? await _openStream();
      _stream = stream;
      final source = ctx.createMediaStreamSource(stream);
      final capture = web.AudioWorkletNode(ctx, 'vg-capture');
      capture.port.onmessage = ((web.MessageEvent e) {
        final data = e.data;
        if (data.isA<JSArrayBuffer>()) {
          // Transferred Int16Array buffer (worklet zero-copies it out).
          _frames.add((data as JSArrayBuffer).toDart.asUint8List());
        }
      }).toJS;
      source.connect(capture);
      final playback = web.AudioWorkletNode(ctx, 'vg-playback');
      playback.port.onmessage = ((web.MessageEvent e) {
        final map = e.data.dartify();
        if (map is Map && map['type'] == 'drained') _drained.add(null);
      }).toJS;
      playback.connect(ctx.destination);
      _capture = capture;
      _playback = playback;
      if (ctx.state == 'suspended') await ctx.resume().toDart;
      if (!_pagehideArmed) {
        _pagehideArmed = true;
        web.window.addEventListener('pagehide', _onPagehide);
      }
    } on Object {
      await _teardown();
      rethrow;
    }
  }

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  Stream<CallAudioSignal> get signals => _signals.stream;

  @override
  void play(Uint8List pcm) {
    final node = _playback;
    if (node == null) return;
    final i16 = Int16List(pcm.lengthInBytes ~/ 2);
    for (var i = 0; i < i16.length; i++) {
      i16[i] = pcm[2 * i] | (pcm[2 * i + 1] << 8); // s16 little-endian
    }
    node.port.postMessage(
        <String, Object?>{'type': 'pcm', 'data': i16.toJS}.jsify()!);
  }

  @override
  void flushPlayback() {
    final node = _playback;
    if (node == null) return;
    node.port.postMessage(
        <String, Object?>{'type': 'flush'}.jsify()!); // idempotent (§3.1)
  }

  @override
  Stream<void> get drained => _drained.stream;

  @override
  Future<void> setSpeaker(bool on) async {} // the browser owns the route

  @override
  Future<void> stop() => _teardown();

  Future<void> _teardown() async {
    if (_pagehideArmed) {
      _pagehideArmed = false;
      web.window.removeEventListener('pagehide', _onPagehide);
    }
    _capture?.disconnect();
    _playback?.disconnect();
    _capture = null;
    _playback = null;
    final stream = _stream;
    _stream = null;
    stream?.getTracks().toDart.forEach((t) => t.stop());
    final ctx = _ctx;
    _ctx = null;
    if (ctx != null) await ctx.close().toDart;
  }
}
