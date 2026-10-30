import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/features/call/call_audio.dart';
import 'package:hermes_app/features/call/call_controller.dart';
import 'package:hermes_app/features/call/call_protocol.dart';
import 'package:hermes_app/features/call/call_state.dart';
import 'package:hermes_app/models/session.dart';

import 'support/call_fakes.dart';

// PLAN-VOICEUI §6.2 call_controller_test: the §4.2 state machine WITH its
// I/O side effects, driven through the two seams (socket, audio) and an
// injected clock/backoff so no wall time is waited on.

Session session() => const Session(
  id: 's1',
  title: 'Alpha',
  count: 1,
  startedAt: 0,
  activity: 0,
  source: 'api_server',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeConnector connector;
  late FakeCallAudio audio;
  late List<Duration> waits;
  late DateTime clock;
  late CallController controller;
  DateTime clockNow() => clock;

  CallController make({CallTarget? target}) {
    connector = FakeConnector();
    audio = FakeCallAudio();
    waits = [];
    clock = DateTime(2026, 1, 1);
    return CallController(
      target: target ?? const StandaloneCallTarget(),
      url: Uri.parse('ws://test.invalid/'),
      token: 'tk-1',
      connect: connector.call,
      audio: audio,
      delay: (d) {
        waits.add(d);
        return Future.value();
      },
      now: clockNow,
    );
  }

  Future<void> startConnected() async {
    await controller.start();
    connector.sockets.last.emit(kReadyJson);
    await pumpEventQueue();
  }

  tearDown(() async {
    controller.dispose();
    await audio.dispose();
  });

  setUp(() => controller = make());

  test('(1) the first thing sent is hello with token + session_id', () async {
    controller = make(target: SessionCallTarget(session()));
    await controller.start();
    expect(connector.sockets.single.texts, hasLength(1));
    final hello = connector.sockets.single.texts.single;
    expect(hello, contains('"type":"hello"'));
    expect(hello, contains('"token":"tk-1"'));
    expect(hello, contains('"session_id":"s1"'));
    expect(hello, contains('"session_title":"Alpha"'));
  });

  test('(1b) standalone hello sends an empty session_id, never omits it', () async {
    await controller.start();
    expect(connector.sockets.single.texts.single, contains('"session_id":""'));
  });

  test('(2) capture frames before ready are dropped, not buffered', () async {
    await controller.start();
    audio.pushFrame(frame(7));
    await pumpEventQueue();
    expect(connector.sockets.single.sentFrames, isEmpty);
    connector.sockets.last.emit(kReadyJson);
    await pumpEventQueue();
    audio.pushFrame(frame(7));
    await pumpEventQueue();
    expect(connector.sockets.single.sentFrames, hasLength(1));
  });

  test('(3) after ready every frame is forwarded once', () async {
    await startConnected();
    audio.pushFrame(frame(3));
    audio.pushFrame(frame(4));
    await pumpEventQueue();
    expect(connector.sockets.single.sentFrames, hasLength(2));
    expect(connector.sockets.single.sentFrames.first, frame(3));
  });

  test('(4) muted forwards silent 640-byte frames (D8)', () async {
    await startConnected();
    controller.toggleMute();
    expect(controller.state.phase, CallPhase.muted);
    audio.pushFrame(frame(9));
    await pumpEventQueue();
    final sent = connector.sockets.single.sentFrames.single;
    expect(isSilent(sent), isTrue);
  });

  test('(5) a binary frame goes straight to audio.play', () async {
    await startConnected();
    final bytes = frame(11);
    connector.sockets.last.emit(bytes);
    await pumpEventQueue();
    expect(audio.played.single, bytes);
    expect(controller.state.assistantSpeaking, isTrue);
  });

  test('(6) barge_in flushes once; bytes before/after still play', () async {
    await startConnected();
    connector.sockets.last.emit(frame(1));
    await pumpEventQueue();
    expect(controller.state.assistantSpeaking, isTrue);
    connector.sockets.last.emit(eventJson('barge_in', {'was_playing': true}));
    await pumpEventQueue();
    expect(controller.state.assistantSpeaking, isFalse);
    connector.sockets.last.emit(frame(2));
    await pumpEventQueue();
    expect(audio.flushes, 1);
    expect(audio.played, hasLength(2));
    expect(controller.state.assistantSpeaking, isTrue);
    expect(controller.state.bargeAt, isNotNull);
  });

  test('(7) audio_stop then barge_in = two flushes, no throw', () async {
    await startConnected();
    connector.sockets.last.emit(eventJson('audio_stop', {'kind': 'tts'}));
    connector.sockets.last.emit(eventJson('barge_in', {'was_playing': false}));
    await pumpEventQueue();
    expect(audio.flushes, 2);
  });

  test('(8) 1006 reconnects with 0.5s/1s/2s backoff then network error', () async {
    await startConnected();
    connector.autoPeerClose1006 = true;
    await connector.sockets.single.peerClose(1006);
    await pumpEventQueue();
    expect(waits, [
      const Duration(milliseconds: 500),
      const Duration(seconds: 1),
      const Duration(seconds: 2),
    ]);
    expect(controller.state.phase, CallPhase.error);
    expect(controller.state.errorKind, CallErrorKind.network);
  });

  test('(9) wantMuted survives a reconnect', () async {
    await startConnected();
    controller.toggleMute();
    await connector.sockets.last.peerClose(1006);
    await pumpEventQueue();
    expect(controller.state.phase, CallPhase.connecting);
    connector.sockets.last.emit(kReadyJson);
    await pumpEventQueue();
    expect(controller.state.phase, CallPhase.muted);
  });

  test('(10) hangUp sends hangup, closes 1000, stops audio, ends', () async {
    await startConnected();
    final socket = connector.sockets.last;
    await controller.hangUp();
    expect(socket.texts.last, '{"type":"hangup"}');
    expect(socket.closeCalledWith, 1000);
    expect(audio.stopped, isTrue);
    expect(controller.state.phase, CallPhase.ended);
  });

  test('(11) FocusLost mutes with the system caption', () async {
    await startConnected();
    audio.pushSignal(const FocusLost());
    await pumpEventQueue();
    expect(controller.state.phase, CallPhase.muted);
    expect(controller.state.captions.last.role, CaptionRole.system);
  });

  test('(12) HangupRequested ends the call', () async {
    await startConnected();
    audio.pushSignal(const HangupRequested());
    await pumpEventQueue();
    expect(controller.state.phase, CallPhase.ended);
  });

  test('(13) denied permission errors without ever dialing', () async {
    audio.permission = MicPermission.denied;
    await controller.start();
    expect(controller.state.phase, CallPhase.error);
    expect(controller.state.errorKind, CallErrorKind.micDenied);
    expect(connector.calls, 0);
  });

  test('(14) five silent ping intervals reconnect once', () async {
    connector = FakeConnector();
    audio = FakeCallAudio();
    waits = [];
    clock = DateTime(2026, 1, 1);
    controller = CallController(
      target: const StandaloneCallTarget(),
      url: Uri.parse('ws://test.invalid/'),
      token: 'tk-1',
      connect: connector.call,
      audio: audio,
      delay: (d) {
        waits.add(d);
        return Future.value();
      },
      now: clockNow,
      pingInterval: const Duration(milliseconds: 40),
    );
    await controller.start();
    connector.sockets.last.emit(kReadyJson);
    await pumpEventQueue();
    // pongTimeout = 5 pings = 200ms of injected clock with no pong answer;
    // advance the fake clock just ahead of the real 40ms ticks.
    for (var i = 0; i < 8 && controller.state.phase == CallPhase.connected; i++) {
      clock = clock.add(const Duration(milliseconds: 60));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    await pumpEventQueue();
    expect(controller.state.phase, CallPhase.connecting);
    expect(controller.state.attempt, 1);
  });

  test('(15) first attempt open failure = gatewayDown, no retry', () async {
    connector.failNext = true;
    await controller.start();
    expect(controller.state.phase, CallPhase.error);
    expect(controller.state.errorKind, CallErrorKind.gatewayDown);
    expect(connector.calls, 1);
    expect(waits, isEmpty);
  });

  test('(16) 4401 closes to auth error, 4409 to busy, no retry', () async {
    await startConnected();
    await connector.sockets.last.peerClose(closeAuth);
    await pumpEventQueue();
    expect(controller.state.phase, CallPhase.error);
    expect(controller.state.errorKind, CallErrorKind.auth);
    expect(waits, isEmpty);
  });

  test('(17) audio.start rides the first ready with the target title', () async {
    controller = make(target: SessionCallTarget(session()));
    await startConnected();
    expect(audio.startTitle, 'Alpha');
    expect(audio.startSpeaker, isTrue); // D9 default
  });

  test('(18) drained clears assistantSpeaking, not audio_end (tts)', () async {
    await startConnected();
    connector.sockets.last.emit(frame(5));
    connector.sockets.last.emit(eventJson('audio_end', {'kind': 'tts'}));
    await pumpEventQueue();
    expect(controller.state.assistantSpeaking, isTrue);
    audio.drainedCtl.add(null);
    await pumpEventQueue();
    expect(controller.state.assistantSpeaking, isFalse);
  });

  // ---- TASK-VOICEBUG4: the 4409 reconnect storm ---------------------------

  CallController makeFastPing() {
    connector = FakeConnector();
    audio = FakeCallAudio();
    waits = [];
    clock = DateTime(2026, 1, 1);
    return CallController(
      target: const StandaloneCallTarget(),
      url: Uri.parse('ws://test.invalid/'),
      token: 'tk-1',
      connect: connector.call,
      audio: audio,
      delay: (d) {
        waits.add(d);
        return Future.value();
      },
      now: clockNow,
      pingInterval: const Duration(milliseconds: 40),
    );
  }

  test('(19) answered pings keep the call up past the pong timeout', () async {
    // 19:11:01 ready → 19:11:07 redial: the pong timestamp was never
    // refreshed, so every healthy call dropped itself 5 pings after ready.
    controller = makeFastPing();
    await controller.start();
    connector.sockets.last.emit(kReadyJson);
    await pumpEventQueue();
    for (var i = 0; i < 10; i++) {
      clock = clock.add(const Duration(milliseconds: 60)); // 600ms ≫ 200ms
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final pings = connector.sockets.last.texts
          .where((t) => t.contains('"type":"ping"'));
      if (pings.isNotEmpty) {
        final id = RegExp(r'"id":(\d+)').firstMatch(pings.last)!.group(1);
        connector.sockets.last.emit(eventJson('pong', {'id': int.parse(id!)}));
        await pumpEventQueue();
      }
    }
    expect(controller.state.phase, CallPhase.connected);
    expect(connector.calls, 1);
  });

  test('(20) a pong-timeout drop closes the old socket before redialing', () async {
    controller = makeFastPing();
    await controller.start();
    connector.sockets.last.emit(kReadyJson);
    await pumpEventQueue();
    for (var i = 0; i < 8 && controller.state.phase == CallPhase.connected; i++) {
      clock = clock.add(const Duration(milliseconds: 60));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    await pumpEventQueue();
    expect(connector.calls, 2);
    // the first socket is closed by us, not left half-open as a ghost that
    // keeps the gateway seat and turns the redial into a 4409
    expect(connector.sockets.first.closeCalledWith, isNotNull);
    expect(connector.sockets.last.closeCalledWith, isNull);
  });

  test('(21) 4409 stops redialing; a manual retry restarts the mic', () async {
    await startConnected();
    expect(audio.starts, 1);
    await connector.sockets.last.peerClose(1006);
    await pumpEventQueue();
    await connector.sockets.last.peerClose(closeBusy);
    await pumpEventQueue();
    expect(controller.state.phase, CallPhase.error);
    expect(controller.state.errorKind, CallErrorKind.busy);
    expect(connector.calls, 2);
    expect(waits, hasLength(1)); // only the 1006 redial, none after 4409
    expect(audio.stopped, isTrue);
    await controller.retry();
    connector.sockets.last.emit(kReadyJson);
    await pumpEventQueue();
    expect(controller.state.phase, CallPhase.connected);
    expect(audio.starts, 2); // was 1: the redialed call never sent a frame
    expect(audio.stopped, isFalse);
  });

  test('(22) connect → ready → drop loops back off exponentially to 30s', () async {
    await startConnected();
    for (var i = 0; i < 8; i++) {
      await connector.sockets.last.peerClose(closeStalled);
      await pumpEventQueue();
      connector.sockets.last.emit(kReadyJson);
      await pumpEventQueue();
    }
    expect(waits, [
      const Duration(milliseconds: 500),
      const Duration(seconds: 1),
      const Duration(seconds: 2),
      const Duration(seconds: 4),
      const Duration(seconds: 8),
      const Duration(seconds: 16),
      const Duration(seconds: 30),
      const Duration(seconds: 30),
    ]);
    expect(connector.calls, 9);
  });
}
