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
