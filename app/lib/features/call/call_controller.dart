/// The call's only I/O member (PLAN-VOICEUI §4.8): it owns the socket, the
/// timers and the audio seam, and funnels every text message through the
/// pure reducer. Everything the page sees is [state]; every wire byte goes
/// through [connect]/[audio]. All clocks and waits are injectable so the
/// §4.2 timers (5s ready, 1s ping, 5/10s backoffs) are testable without
/// wall time.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../diagnostics/diagnostics.dart';
import '../../l10n/message_key.dart';
import '../../l10n/ui_message.dart';
import 'call_audio.dart';
import 'call_protocol.dart';
import 'call_reducer.dart';
import 'call_state.dart';
import 'gateway_socket.dart';

/// §5.3: the fixed bridge+proxy share of the uplink estimate, in ms.
const kUplinkFixedMs = 5;

class CallController extends ChangeNotifier {
  CallController({
    required this.target,
    required this.url,
    required this.token,
    required this.connect,
    required this.audio,
    this.delay = Future.delayed,
    this.now = DateTime.now,
    this.clientTag = 'hermes-app',
    Duration pingInterval = const Duration(seconds: 1),
  }) : _pingInterval = pingInterval,
       _state = CallState(target: target),
       _pongTimeout = pingInterval * 5;

  final CallTarget target;
  final Uri url;
  final String token;
  final GatewayConnector connect;
  final CallAudio audio;

  /// Injectable clock/wait seams (test determinism; the app uses real ones).
  final Future<void> Function(Duration) delay;
  final DateTime Function() now;
  final String clientTag;
  final Duration _pingInterval;
  final Duration _pongTimeout;

  CallState get state => _state;
  CallState _state;

  bool _disposed = false;
  bool _started = false;
  bool _everConnected = false;
  bool _audioStarted = false;
  bool _closing = false;

  GatewaySocket? _socket;
  StreamSubscription<Object>? _msgSub;
  StreamSubscription<Object>? _signalsSub;
  StreamSubscription<Uint8List>? _framesSub;
  StreamSubscription<void>? _drainedSub;
  Timer? _readyTimer;
  Timer? _pingTimer;
  Timer? _statsTimer;

  int _pingId = 0;
  int _pingOutstandingId = -1;
  DateTime? _pingSentAt;
  DateTime? _lastPongAt;
  DateTime? _turnFinalAt;
  bool _awaitingFirstAudio = false;

  // §5.3 stats accumulators (machine data only, never captions/secrets).
  final List<int> _rttWindow = [];
  double? _inputLatencyMs;
  int _framesSent = 0;
  int _framesDropped = 0;

  String? get _sessionTitle =>
      target is SessionCallTarget ? (target as SessionCallTarget).session.title : null;

  String get _audioTitle => _sessionTitle ?? '';

  // ---- lifecycle ----------------------------------------------------------

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _subscribeAudio();
    final permission = await audio.ensurePermission();
    if (_disposed) return;
    switch (permission) {
      case MicPermission.granted:
        await _connectOnce();
      case MicPermission.denied:
        _enterError(CallErrorKind.micDenied);
      case MicPermission.permanentlyDenied:
        _enterError(CallErrorKind.micPermanentlyDenied);
      case MicPermission.unsupported:
        _enterError(CallErrorKind.unsupported);
    }
  }

  /// error → connecting(attempt 0) (§4.2 last rows). A mic-denied error
  /// re-runs the permission step (M3 acceptance 6); everything else just
  /// re-dials.
  Future<void> retry() async {
    if (_disposed || _state.phase != CallPhase.error) return;
    final kind = _state.errorKind;
    _set(_state.copyWith(
      phase: CallPhase.connecting,
      attempt: 0,
      errorKind: null,
    ));
    if (kind == CallErrorKind.micDenied || kind == CallErrorKind.unsupported) {
      _started = false;
      await start();
    } else {
      await _connectOnce();
    }
  }

  void toggleMute() {
    if (_state.phase == CallPhase.connected) {
      _set(_state.copyWith(phase: CallPhase.muted, wantMuted: true));
    } else if (_state.phase == CallPhase.muted) {
      _set(_state.copyWith(phase: CallPhase.connected, wantMuted: false));
    }
  }

  Future<void> setSpeaker(bool on) async {
    if (_state.speakerOn == on) return;
    _set(_state.copyWith(speakerOn: on));
    await audio.setSpeaker(on);
  }

  /// §4.2 hangup row: hangup text, close(1000), stop the audio, ended.
  Future<void> hangUp() async {
    if (_disposed || _state.phase == CallPhase.ended) return;
    _closing = true;
    _stopTimers();
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        socket.sendText('{"type":"hangup"}');
      } catch (_) {
        // a dead socket hanging up is exactly a hangup having happened
      }
    }
    _set(_state.copyWith(phase: CallPhase.ended, errorKind: null));
    if (socket != null) {
      try {
        await socket.close(closeNormal);
      } catch (_) {}
    }
    await _stopAudio();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stopTimers();
    unawaited(_msgSub?.cancel());
    unawaited(_signalsSub?.cancel());
    unawaited(_framesSub?.cancel());
    unawaited(_drainedSub?.cancel());
    final live =
        _state.phase != CallPhase.ended && _state.phase != CallPhase.error;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      if (live) {
        try {
          socket.sendText('{"type":"hangup"}');
        } catch (_) {}
      }
      unawaited(socket.close().catchError((Object _) {}));
    }
    if (live) unawaited(_stopAudio());
    super.dispose();
  }

  // ---- connect ------------------------------------------------------------

  Future<void> _connectOnce() async {
    if (_disposed) return;
    if (_state.phase != CallPhase.connecting) {
      _set(_state.copyWith(phase: CallPhase.connecting, errorKind: null));
    }
    GatewaySocket socket;
    try {
      socket = await connect(url);
    } catch (_) {
      _record('call.connect-failed');
      _handleClose(null);
      return;
    }
    if (_disposed || _state.phase == CallPhase.ended || _state.phase == CallPhase.error) {
      unawaited(socket.close().catchError((Object _) {}));
      return;
    }
    _socket = socket;
    try {
      socket.sendText(helloJson(
        token: token,
        sessionId: target.sessionId,
        sessionTitle: _sessionTitle,
        client: clientTag,
      ));
    } catch (_) {
      // the peer already gone by the time hello raced it: the onDone below
      // routes through reduceClose exactly like a live close would
      _record('call.hello-raced-close');
    }
    _readyTimer?.cancel();
    _readyTimer = Timer(const Duration(seconds: 5), _onReadyTimeout);
    _msgSub?.cancel();
    _msgSub = socket.messages.listen(
      _onMessage,
      onDone: () => _handleClose(socket.closeCode),
      onError: (Object _) => _handleClose(socket.closeCode),
    );
  }

  void _onReadyTimeout() {
    // §4.2: a missing ready is the 4408 branch — always a retry, unlike a
    // refused FIRST open (that one is gatewayDown inside _connectOnce).
    if (_disposed || _state.phase != CallPhase.connecting) return;
    _handleClose(closeHelloTimeout);
  }

  void _onMessage(Object message) {
    if (_disposed) return;
    if (message is String) {
      _onText(message);
    } else if (message is Uint8List) {
      _onBinary(message);
    }
  }

  void _onText(String raw) {
    final event = parseGatewayEvent(raw);
    if (event is ReadyEvent) {
      unawaited(_onReady(event));
      return;
    }
    var next = reduceEvent(_state, event, now());
    if (event is PongEvent && event.id == _pingOutstandingId) {
      final sent = _pingSentAt;
      if (sent != null) {
        final rtt = now().difference(sent).inMilliseconds;
        next = next.copyWith(rttMs: rtt);
        _rttWindow.add(rtt);
        if (_rttWindow.length > 20) {
          _rttWindow.removeRange(0, _rttWindow.length - 20); // newest wins
        }
      }
      _pingOutstandingId = -1;
    }
    if (event is TurnFinalEvent) {
      _turnFinalAt = now();
      _awaitingFirstAudio = true;
    }
    if (event is GatewayErrorEvent) {
      // detail goes to diagnostics only (§4.7 footnote: may carry reprs)
      _record('call.gateway-error', event: event.where);
    }
    _set(next);
    if (event is AudioStopEvent || event is BargeInEvent) {
      final t0 = now();
      audio.flushPlayback();
      if (event is BargeInEvent) {
        debugPrint(
          'call: flush ${now().difference(t0).inMilliseconds}ms since barge_in',
        );
      }
    }
  }

  void _onBinary(Uint8List bytes) {
    if (!_everConnected) return; // §4.2: nothing plays before ready
    if (_awaitingFirstAudio && _turnFinalAt != null) {
      _awaitingFirstAudio = false;
      debugPrint(
        'call: first_audio ${now().difference(_turnFinalAt!).inMilliseconds}ms since turn_final',
      );
    }
    audio.play(bytes);
    if (!_state.assistantSpeaking) {
      _set(_state.copyWith(assistantSpeaking: true));
    }
  }

  Future<void> _onReady(ReadyEvent event) async {
    if (_disposed) return;
    _readyTimer?.cancel();
    if (!readyCompatible(event)) {
      _record('call.ready-incompatible', event: 'proto ${event.proto}');
      _finishWithError(CallErrorKind.protocol);
      return;
    }
    _everConnected = true;
    _lastPongAt = now();
    _set(reduceEvent(_state, event, now()));
    if (!_audioStarted) {
      _audioStarted = true;
      await audio
          .start(title: _audioTitle, speaker: _state.speakerOn)
          .catchError((Object e) {
            _record('call.audio-start-failed');
            _enterError(CallErrorKind.unsupported);
          });
    }
    _startPing();
  }

  void _startPing() {
    _pingTimer?.cancel();
    _statsTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      if (_disposed) return;
      final phase = _state.phase;
      if (phase != CallPhase.connected && phase != CallPhase.muted) return;
      _pingId++;
      _pingOutstandingId = _pingId;
      _pingSentAt = now();
      _socket?.sendText('{"type":"ping","id":$_pingId}');
      final last = _lastPongAt;
      if (last != null && now().difference(last) >= _pongTimeout) {
        // §4.7/§4.2: 5s of silence is a drop — reconnect, mic stays live
        _record('call.pong-timeout');
        _handleClose(null);
      }
    });
    _statsTimer = Timer.periodic(const Duration(seconds: 5), (_) => _sendStats());
  }

  void _sendStats() {
    final phase = _state.phase;
    if (_disposed || (_state.phase != CallPhase.connected && phase != CallPhase.muted)) return;
    final rtts = List<int>.of(_rttWindow)..sort();
    final p50 = rtts.isEmpty ? null : rtts[rtts.length ~/ 2];
    final max = rtts.isEmpty ? null : rtts.last;
    final uplink = (_inputLatencyMs == null || p50 == null)
        ? null
        : kFrameMs + _inputLatencyMs! + p50 / 2 + kUplinkFixedMs;
    _socket?.sendText(jsonEncode({
      'type': 'stats',
      'rtt_ms_p50': p50,
      'rtt_ms_max': max,
      'input_latency_ms': _inputLatencyMs,
      'frames_sent': _framesSent,
      'frames_dropped': _framesDropped,
      'uplink_est_ms': uplink?.round(),
      'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
    }));
  }

  // ---- close / reconnect (§4.2) -------------------------------------------

  void _handleClose(int? code) {
    if (_disposed || _closing) return;
    final phase = _state.phase;
    if (phase == CallPhase.ended || phase == CallPhase.error) return;
    _stopTimers();
    _record('call.closed', event: code == null ? 'open-failed' : '$code');
    final next = reduceClose(_state, code, everConnected: _everConnected);
    if (next.phase == CallPhase.connecting) {
      // §4.2 drop row: flush what was queued, keep the mic, drop frames
      // until the next ready; wantMuted survives (it lives in state).
      audio.flushPlayback();
      _set(next);
      final attempt = next.attempt;
      final wait = Duration(milliseconds: 500 * (1 << (attempt - 1)));
      unawaited(
        delay(wait).then((_) {
          if (_disposed) return;
          if (_state.phase == CallPhase.connecting) unawaited(_connectOnce());
        }),
      );
    } else if (next.phase == CallPhase.ended) {
      _set(next);
      unawaited(_stopAudio());
    } else {
      _set(next);
      unawaited(_stopAudio());
      final socket = _socket;
      _socket = null;
      if (socket != null) {
        unawaited(socket.close().catchError((Object _) {}));
      }
    }
  }

  void _finishWithError(CallErrorKind kind) {
    _stopTimers();
    _set(_state.copyWith(phase: CallPhase.error, errorKind: kind));
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      unawaited(socket.close().catchError((Object _) {}));
    }
    unawaited(_stopAudio());
  }

  void _enterError(CallErrorKind kind) {
    _record('call.permission-error');
    _stopTimers();
    _set(_state.copyWith(phase: CallPhase.error, errorKind: kind));
  }

  // ---- audio plumbing ------------------------------------------------------

  void _subscribeAudio() {
    _signalsSub ??= audio.signals.listen((signal) {
      if (_disposed) return;
      switch (signal) {
        case FocusLost():
          // D20: auto-mute with a system caption (§4.2 focus row)
          if (_state.phase == CallPhase.connected ||
              _state.phase == CallPhase.muted) {
            _set(_state.copyWith(
              phase: CallPhase.muted,
              wantMuted: true,
              captions: _appendSystem(
                _state.captions,
                MessageKey.callFocusMuted,
              ),
            ));
          }
        case HangupRequested():
          unawaited(hangUp()); // notification action / web pagehide (§4.4)
        case CaptureStats(:final inputLatencyMs):
          _inputLatencyMs = inputLatencyMs;
      }
    });
    _drainedSub ??= audio.drained.listen((_) {
      if (_disposed) return;
      if (_state.assistantSpeaking) {
        _set(_state.copyWith(assistantSpeaking: false));
      }
    });
    _framesSub ??= audio.frames.listen((frame) {
      if (_disposed) return;
      switch (_state.phase) {
        case CallPhase.connected:
          _socket?.sendBytes(frame);
          _framesSent++;
        case CallPhase.muted:
          // D8: muted keeps the timeline honest with silent frames
          _socket?.sendBytes(Uint8List(kFrameBytes));
          _framesSent++;
        default:
          _framesDropped++; // connecting/ended: pre-ready or drop-window
      }
    });
  }

  Future<void> _stopAudio() async {
    try {
      await audio.stop();
    } catch (_) {
      _record('call.audio-stop-failed');
    }
  }

  List<CaptionLine> _appendSystem(List<CaptionLine> caps, MessageKey key) {
    final out = [...caps, CaptionLine(role: CaptionRole.system, system: UiMessage.local(key))];
    return out.length > CallState.maxCaptions
        ? out.sublist(out.length - CallState.maxCaptions)
        : out;
  }

  void _stopTimers() {
    _readyTimer?.cancel();
    _pingTimer?.cancel();
    _statsTimer?.cancel();
  }

  void _set(CallState next) {
    _state = next;
    if (!_disposed) notifyListeners();
  }

  void _record(String kind, {String? event}) {
    unawaited(Diagnostics.current?.record(kind, event: event) ?? Future.value());
  }
}
