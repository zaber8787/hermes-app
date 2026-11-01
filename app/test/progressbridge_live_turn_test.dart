import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/live_turn.dart';

// TASK-PROGRESSBRIDGE: a Discord-session send now streams the turn live from
// the compat bridge. These are the bridge's raw frames (captured from
// tests/test_crosssource.py's green test, plus one keepalive) fed through the
// real SSE parser into LiveTurn, unchanged client code: the delta grows, the
// tool row appears then completes, and the turn ends completed (not queued).
const sid = '20260910_151843_94d2209a';
const run = 'run_23d8e7a804c54c7d83f7c882cf217a52';
const mid = 'msg_442c3d6c31fe4c40900c21c6b4f5bdb4';

String frame(String event, int seq, Map<String, dynamic> body) =>
    'event: $event\ndata: ${jsonEncode({'session_id': sid, 'run_id': run, 'seq': seq, 'ts': 1793507165.1, ...body})}\n\n';

final raw = [
  frame('run.started', 1, {
    'user_message': {'role': 'user', 'content': '從 app 發的'},
    'runtime': {},
  }),
  frame('message.started', 2, {
    'message': {'id': mid, 'role': 'assistant'},
  }),
  frame('assistant.delta', 3, {'message_id': mid, 'delta': '好'}),
  ': keepalive\n\n',
  frame('tool.started', 4, {
    'message_id': mid,
    'tool_name': 'terminal',
    'preview': 'ls',
    'args': {'command': 'ls'},
  }),
  frame('tool.completed', 5, {
    'message_id': mid,
    'tool_name': 'terminal',
    'preview': null,
    'args': {'command': 'ls'},
  }),
  frame('assistant.delta', 6, {'message_id': mid, 'delta': '了'}),
  frame('assistant.completed', 7, {'message_id': mid, 'content': '好了'}),
  frame('run.completed', 8, {
    'message_id': mid,
    'messages': [],
    'usage': {},
    'runtime': {},
  }),
  frame('done', 9, {}),
].join();

void main() {
  test('bridge progress frames render live through unchanged LiveTurn', () async {
    final events = await parseSse(Stream.value(utf8.encode(raw))).toList();
    expect(events.map((e) => e.type).toList(), [
      'run.started',
      'message.started',
      'assistant.delta',
      'heartbeat',
      'tool.started',
      'tool.completed',
      'assistant.delta',
      'assistant.completed',
      'run.completed',
      'done',
    ]);
    final turn = LiveTurn();
    final seen = <String>[];
    for (final event in events) {
      // The controller skips heartbeats before apply.
      if (event.type == 'heartbeat') continue;
      turn.apply(event, sid);
      seen.add(
        '${event.type}|${turn.delta}|${turn.tools.length}|${turn.tools.isNotEmpty && turn.tools.first.completed}|${turn.completed}',
      );
    }
    expect(seen, [
      'run.started||0|false|false',
      'message.started||0|false|false',
      'assistant.delta|好|0|false|false',
      'tool.started|好|1|false|false',
      'tool.completed|好|1|true|false',
      'assistant.delta|好了|1|true|false',
      'assistant.completed|好了|1|true|false',
      'run.completed|好了|1|true|true',
      'done|好了|1|true|true',
    ]);
    expect(turn.runId, run);
    expect(turn.tools.single.name, 'terminal');
    expect(turn.finalText, '好了');
    expect(turn.terminalStatus, 'completed');
    expect(turn.queued, isFalse);
  });
}
