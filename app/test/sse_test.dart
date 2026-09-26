import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/live_turn.dart';

void main() {
  test(
    'UTF8 byte chunks, BOM, CRLF, comments, multiline data and frame IDs',
    () async {
      final bytes = utf8.encode(
        '\uFEFF:heartbeat\r\nid: 7\r\nevent: assistant.delta\r\ndata: {"delta":\r\ndata: "你好"}\r\n\r\n',
      );
      final events = await parseSse(
        Stream.fromIterable(bytes.map((b) => [b])),
      ).toList();
      expect(events.length, 1);
      expect(events.single.type, 'assistant.delta');
      expect(events.single.id, '7');
      expect(events.single.json['delta'], '你好');
    },
  );
  test(
    'multiple events per chunk and trailing frame; empty/comments ignored',
    () async {
      final events = await parseSse(
        Stream.value(
          utf8.encode(': ping\n\nevent: done\ndata: {}\n\ndata: {"x":1}'),
        ),
      ).toList();
      expect(events.map((e) => e.type), ['done', 'message']);
      expect(events.last.json['x'], 1);
    },
  );
  test(
    'keepalive comments survive byte/CRLF splits and stay liveness-only',
    () async {
      // SILENCE-DROP §4.7: the SAME bytes the gateway sends for an idle-but-
      // live stream, under every transport split the parser must tolerate.
      final bytes = utf8.encode(
        ': keepalive\n\n: keepalive\r\n\r\nevent: heartbeat\r\ndata: {}\r\n\r\n',
      );
      final events = await parseSse(
        Stream.fromIterable(bytes.map((b) => [b])), // one byte at a time
      ).toList();
      // Two `: keepalive` comments + one typed heartbeat event; the typed
      // frame parses through the GENERAL path too, so all three are liveness.
      expect(events.map((e) => e.type).toList(), [
        'heartbeat',
        'heartbeat',
        'heartbeat',
      ]);
    },
  );
  test(
    'a plain comment yields no event and never corrupts a data frame',
    () async {
      // Ordinary comments are NOT liveness (§2): no event at all.
      final silent = await parseSse(
        Stream.value(
          utf8.encode(
            ': this is not a keepalive\n\nevent: x\ndata: {"v":1}\n\n',
          ),
        ),
      ).toList();
      expect(silent.map((e) => e.type).toList(), ['x']);
      // A comment sitting BETWEEN the data lines of one frame changes
      // nothing: the data still joins to exactly the same payload.
      final mid = await parseSse(
        Stream.value(
          utf8.encode(
            'event: assistant.delta\ndata: {"delta":\n: keepalive\ndata: "ab"}\n\n',
          ),
        ),
      ).toList();
      expect(mid.single.type, 'assistant.delta');
      expect(mid.single.json['delta'], 'ab');
    },
  );
  test('keepalive-only stream produces heartbeats, nothing else', () async {
    final events = await parseSse(
      Stream.value(utf8.encode(': keepalive\n\n: keepalive\n\n')),
    ).toList();
    expect(events.length, 2);
    expect(events.every((e) => e.type == 'heartbeat'), isTrue);
  });
  test(
    'progress reasoning does not split delta; completed payload corrects it',
    () {
      final turn = LiveTurn();
      void event(String name, Map<String, dynamic> data) =>
          turn.apply(SseEvent(name, jsonEncode(data)), 's');
      event('run.started', {'run_id': 'r', 'session_id': 's', 'seq': 1});
      event('assistant.delta', {
        'delta': 'provisional narration',
        'run_id': 'r',
        'seq': 2,
      });
      event('assistant.delta', {
        'delta': 'provisional narration',
        'run_id': 'r',
        'seq': 2,
      });
      event('tool.progress', {'tool_name': '_thinking', 'delta': 'thoughts'});
      expect(turn.delta, 'provisional narration');
      expect(turn.tools, isEmpty);
      event('assistant.completed', {'content': 'final answer'});
      expect(turn.finalText, 'final answer');
      event('run.completed', {
        'messages': [
          {'role': 'assistant', 'content': 'final answer'},
        ],
      });
      expect(turn.completed, isTrue);
      expect(turn.transcript!.single.content, 'final answer');
      expect(turn.runId, 'r');
    },
  );
  test('tool start/result are paired without counting progress as a step', () {
    final turn = LiveTurn();
    turn.apply(
      const SseEvent(
        'tool.started',
        '{"tool_name":"terminal","args":{"command":"pwd"}}',
      ),
      's',
    );
    turn.apply(
      const SseEvent(
        'tool.progress',
        '{"tool_name":"terminal","delta":"working"}',
      ),
      's',
    );
    turn.apply(
      const SseEvent(
        'tool.completed',
        '{"tool_name":"terminal","preview":"/tmp"}',
      ),
      's',
    );
    expect(turn.tools.length, 1);
    expect(turn.tools.single.completed, isTrue);
    expect(turn.tools.single.result, '/tmp');
  });
  test('different session frames are rejected', () {
    expect(
      () => LiveTurn().apply(
        const SseEvent('run.started', '{"session_id":"other"}'),
        's',
      ),
      throwsFormatException,
    );
  });
}
