import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:hermes_app/features/call/call_audio.dart';
import 'package:hermes_app/features/call/gateway_socket.dart';

/// Shared fakes for the VOICEUI UI rod (PLAN-VOICEUI §6.2): a socket that
/// records sends and lets the test drive receives/closes, and an audio
/// seam with the same control.
class FakeGatewaySocket implements GatewaySocket {
  final _messages = StreamController<Object>();
  final texts = <String>[];
  final sentFrames = <Uint8List>[];
  int? closeCalledWith;
  int? _closeCode;
  bool _closed = false;

  @override
  Stream<Object> get messages => _messages.stream;

  @override
  void sendText(String s) {
    if (_closed) throw StateError('sendText after close');
    texts.add(s);
  }

  @override
  void sendBytes(Uint8List b) {
    if (_closed) throw StateError('sendBytes after close');
    sentFrames.add(b);
  }

  @override
  Future<void> close([int code = 1000, String reason = '']) async {
    closeCalledWith = code;
    _closeCode = code;
    _closed = true;
    if (!_messages.isClosed) await _messages.close();
  }

  @override
  int? get closeCode => _closeCode;

  void emit(Object message) => _messages.add(message);

  /// The peer drops the socket (onDone) with [code] — no local close().
  Future<void> peerClose(int? code) async {
    _closeCode = code;
    _closed = true;
    if (!_messages.isClosed) await _messages.close();
  }

  Future<void> dispose() async {
    if (!_messages.isClosed) await _messages.close();
  }
}

class FakeConnector {
  final sockets = <FakeGatewaySocket>[];
  int calls = 0;
  bool failNext = false;

  /// Sockets created while true die right away with a 1006 (drop rig).
  bool autoPeerClose1006 = false;

  Future<GatewaySocket> call(Uri url) async {
    calls++;
    if (failNext) {
      failNext = false;
      throw const FormatException('connect refused');
    }
    final socket = FakeGatewaySocket();
    sockets.add(socket);
    if (autoPeerClose1006) {
      unawaited(socket.peerClose(1006));
    }
    return socket;
  }
}

class FakeCallAudio implements CallAudio {
  final framesCtl = StreamController<Uint8List>.broadcast();
  final signalsCtl = StreamController<CallAudioSignal>.broadcast();
  final drainedCtl = StreamController<void>.broadcast();
  final played = <Uint8List>[];

  MicPermission permission = MicPermission.granted;
  int flushes = 0;
  bool stopped = false;
  int starts = 0;
  String? startTitle;
  bool? startSpeaker;

  @override
  Future<MicPermission> ensurePermission() async => permission;

  @override
  Future<void> start({required String title, required bool speaker}) async {
    starts++;
    stopped = false;
    startTitle = title;
    startSpeaker = speaker;
  }

  @override
  Stream<Uint8List> get frames => framesCtl.stream;

  @override
  Stream<CallAudioSignal> get signals => signalsCtl.stream;

  @override
  void play(Uint8List pcm) => played.add(pcm);

  @override
  void flushPlayback() => flushes++;

  @override
  Stream<void> get drained => drainedCtl.stream;

  @override
  Future<void> setSpeaker(bool on) async {}

  @override
  Future<void> stop() async => stopped = true;

  void pushFrame(Uint8List frame) => framesCtl.add(frame);
  void pushSignal(CallAudioSignal signal) => signalsCtl.add(signal);

  Future<void> dispose() async {
    await framesCtl.close();
    await signalsCtl.close();
    await drainedCtl.close();
  }
}

/// A compatible `ready` (§3.1 audio block) as one wire line.
const kReadyJson =
    '{"type":"ready","proto":1,"mode":"standalone","session_id":"",'
    '"audio":{"sample_rate":16000,"frame_ms":20,"format":"s16le","channels":1}}';

String eventJson(String type, [Map<String, Object?> fields = const {}]) =>
    jsonEncode({'type': type, ...fields});

Uint8List frame(int fill) => Uint8List.fromList(List.filled(640, fill));

bool isSilent(Uint8List b) => b.length == 640 && b.every((x) => x == 0);
