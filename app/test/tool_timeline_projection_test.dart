import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/features/chat/live_turn.dart';
import 'package:hermes_app/features/chat/tool_timeline_projection.dart';
import 'package:hermes_app/models/message.dart';

/// TOOLCARD-DUP pure layer: identity pairing, coverage adjudication, and
/// the shared overlap projection. No widgets, no controllers, no I/O —
/// raw inputs must come out untouched and every non-convergent case must
/// keep BOTH representations.

Message user(String id, {String text = 'q', double ts = 10}) =>
    Message(id: id, role: 'user', content: text, timestamp: ts);

Message assistant(
  String id,
  List<ToolCall> calls, {
  String content = '',
  double ts = 100,
}) => Message(id: id, role: 'assistant', content: content, toolCalls: calls, timestamp: ts);

Message result(String id, String callId, String content, {double ts = 100}) =>
    Message(
      id: id,
      role: 'tool',
      toolCallId: callId,
      toolName: 'tool',
      content: content,
      timestamp: ts,
    );

ToolRef ref({
  String key = 'k',
  String? callId,
  String name = 't',
  String? arguments,
  String? result,
  bool preview = false,
  double ts = 0,
  int turn = 1,
  int order = 0,
}) => ToolRef(
  slotKey: key,
  rowId: '',
  callIndex: 0,
  callId: callId,
  name: name,
  arguments: arguments,
  result: result,
  previewResult: preview,
  timestamp: ts,
  turnIndex: turn,
  order: order,
);

void main() {
  const scope = 's';

  group('slot keys', () {
    test('call entry keys by row + call index', () {
      final m = assistant('8', [
        const ToolCall('C1', 'a', '{}'),
        const ToolCall('C2', 'b', '{}'),
      ]);
      final entries = projectMessages([m]);
      expect(toolSlotKeyFor(entries[0], scope), 's#8#c0');
      expect(toolSlotKeyFor(entries[1], scope), 's#8#c1');
    });

    test('orphan result keys by its own row', () {
      final entries = projectMessages([
        result('9', 'C1', 'out'),
      ]);
      expect(toolSlotKeyFor(entries.single, scope), 's#9#r');
    });
  });

  group('coversToolDetails', () {
    test('equal content covers both ways', () {
      final a = ref(result: 'out', arguments: '{"x":1}', ts: 5);
      final b = ref(result: 'out', arguments: '{"x":1}', ts: 5);
      expect(coversToolDetails(a, b), isTrue);
      expect(coversToolDetails(b, a), isTrue);
    });

    test('JSON object key order is irrelevant, array order is strict', () {
      expect(
        toolArgsEqual('{"a":1,"b":2}', '{"b":2,"a":1}'),
        isTrue,
        reason: 'object key order carries no meaning',
      );
      expect(toolArgsEqual('[1,2]', '[2,1]'), isFalse);
      expect(toolArgsEqual('{"a":[1,{"b":1}]}', '{"a":[1,{"b":2}]}'), isFalse);
    });

    test('unparseable args compare as raw bytes', () {
      expect(toolArgsEqual('raw-a', 'raw-a'), isTrue);
      expect(toolArgsEqual('raw-a', 'raw-b'), isFalse);
      expect(toolArgsEqual('{"a": 1}', '{ "a" : 1 }'), isTrue);
    });

    test('a full result may byte-prefix-cover a PREVIEW, never a result', () {
      final full = ref(result: 'full output text');
      final preview = ref(result: 'full out', preview: true);
      final normal = ref(result: 'full out');
      expect(coversToolDetails(full, preview), isTrue);
      expect(coversToolDetails(full, normal), isFalse);
      expect(
        coversToolDetails(normal, full),
        isFalse,
        reason: 'a longer/shorter normal result is content evidence, '
            'not an automatic containment',
      );
    });

    test('an existing result proves completion even when empty', () {
      final hasEmpty = ref(result: '');
      final none = ref();
      expect(coversToolDetails(hasEmpty, none), isTrue);
      expect(coversToolDetails(none, hasEmpty), isFalse);
    });

    test('missing timestamp borrows the matched slot time; conflicting '
        'timestamps cover nothing', () {
      final timed = ref(result: 'r', ts: 7);
      final timeless = ref(result: 'r', ts: 0);
      final other = ref(result: 'r', ts: 8);
      expect(coversToolDetails(timeless, timed), isTrue);
      expect(coversToolDetails(timed, timeless), isTrue);
      expect(coversToolDetails(timed, other), isFalse);
    });

    test('args the other side lacks block coverage; {} is a real value', () {
      final withArgs = ref(arguments: '{}');
      final noArgs = ref(arguments: null);
      final emptyArgs = ref(arguments: '');
      expect(coversToolDetails(noArgs, withArgs), isFalse);
      expect(coversToolDetails(emptyArgs, withArgs), isFalse);
      expect(coversToolDetails(withArgs, emptyArgs), isTrue);
      expect(coversToolDetails(withArgs, ref(arguments: '{}')), isTrue);
      expect(coversToolDetails(ref(arguments: '{}'), withArgs), isTrue);
    });

    test('name contradiction never covers', () {
      expect(
        coversToolDetails(ref(name: 'a'), ref(name: 'b')),
        isFalse,
      );
    });
  });

  group('identity — call id (first priority)', () {
    test('unique real call ids pair across sides', () {
      final durable = [ref(key: 'd1', callId: 'C1')];
      final other = [ref(key: 'o1', callId: 'C1')];
      final m = matchToolIdentity(durable: durable, other: other);
      expect(m.single.basis, 'call-id');
    });

    test('same call id with different names does not pair', () {
      final m = matchToolIdentity(
        durable: [ref(key: 'd1', callId: 'C1', name: 'read')],
        other: [ref(key: 'o1', callId: 'C1', name: 'write')],
      );
      expect(m, isEmpty);
    });

    test('duplicate ids prove nothing — no first/last wins', () {
      final m = matchToolIdentity(
        durable: [
          ref(key: 'd1', callId: 'C1', order: 0),
          ref(key: 'd2', callId: 'C1', order: 1),
        ],
        other: [ref(key: 'o1', callId: 'C1')],
      );
      expect(m, isEmpty);
    });

    test('ids repeated across turns never pair', () {
      final m = matchToolIdentity(
        durable: [
          ref(key: 'd1', callId: 'C1', turn: 1),
          ref(key: 'd2', callId: 'C1', turn: 2),
        ],
        other: [ref(key: 'o1', callId: 'C1', turn: 1)],
      );
      expect(m, isEmpty);
    });

    test('a segment straddling two durable turns gives up its matches', () {
      final m = matchToolIdentity(
        durable: [
          ref(key: 'd1', callId: 'C1', turn: 1),
          ref(key: 'd2', callId: 'C2', turn: 2),
        ],
        other: [
          ref(key: 'o1', callId: 'C1', turn: 1),
          ref(key: 'o2', callId: 'C2', turn: 1),
        ],
      );
      expect(m, isEmpty);
    });

    test('call/result orphans pair through the real tool_call_id', () {
      final m = matchToolIdentity(
        durable: [ref(key: 'd1', callId: 'C1', result: 'out')],
        other: [ref(key: 'o1', callId: 'C1', result: 'out')],
      );
      expect(m.single.basis, 'call-id');
    });
  });

  group('identity — row id + call index (second priority)', () {
    List<ToolRef> from(Message row) => toolRefsFromRows(scope, [row]);

    test('same numeric row and index with consistent args pairs', () {
      final durable = from(
        assistant('8', [const ToolCall('C1', 't', '{"p":1}')]),
      );
      final other = from(
        assistant('8', [const ToolCall('C1', 't', '{"p":1}')]),
      );
      final m = matchToolIdentity(durable: durable, other: other);
      expect(m, hasLength(1));
    });

    test('synthetic row ids (live-N, remote:, pending) are not identity', () {
      final durable = from(
        assistant('8', [const ToolCall('', 't', '{"p":1}')]),
      );
      final other = from(
        assistant('live-0', [const ToolCall('', 't', '{"p":1}')]),
      );
      expect(matchToolIdentity(durable: durable, other: other), isEmpty);
    });

    test('different non-empty call ids are counter-evidence even on the '
        'same row+index', () {
      final durable = from(
        assistant('8', [const ToolCall('C1', 't', '{}')]),
      );
      final other = from(
        assistant('8', [const ToolCall('C2', 't', '{}')]),
      );
      expect(matchToolIdentity(durable: durable, other: other), isEmpty);
    });

    test('multi-call rows never pair row-wide', () {
      final durable = from(
        assistant('8', [
          const ToolCall('', 'a', '{}'),
          const ToolCall('', 'b', '{}'),
        ]),
      );
      final other = from(
        assistant('8', [
          const ToolCall('', 'b', '{}'),
          const ToolCall('', 'a', '{}'),
        ]),
      );
      // Index 0↔0 (a/b) and 1↔1 (b/a) both contradict on name; NO pairing.
      expect(matchToolIdentity(durable: durable, other: other), isEmpty);
    });
  });

  group('identity — closed-interval fallback', () {
    // Positive: both sides show the SAME real user row id, so the turn is
    // pinned; the unidentified interval is complete and one-to-one.
    final durablePinned = toolRefsFromRows(scope, [
      user('7'),
      assistant('8', [
        const ToolCall('', 'a', '{"p":1}'),
        const ToolCall('', 'b', '{"p":2}'),
      ]),
    ]);

    test('pinned complete aligned interval pairs (user-row anchor)', () {
      final other = toolRefsFromRows(scope, [
        user('7'),
        assistant('live-0', [
          const ToolCall('', 'a', '{"p":1}'),
          const ToolCall('', 'b', '{"p":2}'),
        ]),
      ]);
      final m = matchToolIdentity(
        durable: durablePinned,
        other: other,
        durableUserTurns: {'7': 1},
        otherSegmentUserRows: {1: '7'},
      );
      expect(m, hasLength(2));
      expect(m.every((x) => x.basis == 'closed-interval'), isTrue);
    });

    test('a missing segment breaks interval completeness', () {
      final other = toolRefsFromRows(scope, [
        user('7'),
        assistant('live-0', [const ToolCall('', 'b', '{"p":2}')]),
      ]);
      final m = matchToolIdentity(
        durable: durablePinned,
        other: other,
        durableUserTurns: {'7': 1},
        otherSegmentUserRows: {1: '7'},
      );
      expect(m, isEmpty);
    });

    test('swapped order inside the interval never pairs', () {
      final other = toolRefsFromRows(scope, [
        user('7'),
        assistant('live-0', [
          const ToolCall('', 'b', '{"p":2}'),
          const ToolCall('', 'a', '{"p":1}'),
        ]),
      ]);
      final m = matchToolIdentity(
        durable: durablePinned,
        other: other,
        durableUserTurns: {'7': 1},
        otherSegmentUserRows: {1: '7'},
      );
      expect(m, isEmpty);
    });

    test('repeated same-signature calls cannot be picked by ordinal', () {
      final durable = toolRefsFromRows(scope, [
        user('7'),
        assistant('8', [
          const ToolCall('', 'a', '{}'),
          const ToolCall('', 'a', '{}'),
        ]),
      ]);
      final other = toolRefsFromRows(scope, [
        user('7'),
        assistant('live-0', [
          const ToolCall('', 'a', '{}'),
          const ToolCall('', 'a', '{}'),
        ]),
      ]);
      final m = matchToolIdentity(
        durable: durable,
        other: other,
        durableUserTurns: {'7': 1},
        otherSegmentUserRows: {1: '7'},
      );
      expect(m, isEmpty);
    });

    test('no positive pin → no interval pairing even for identical lists', () {
      final other = toolRefsFromRows(scope, [
        user('99'), // different user row: turn correspondence unproven
        assistant('live-0', [
          const ToolCall('', 'a', '{"p":1}'),
          const ToolCall('', 'b', '{"p":2}'),
        ]),
      ]);
      final m = matchToolIdentity(
        durable: durablePinned,
        other: other,
        durableUserTurns: {'7': 1},
        otherSegmentUserRows: {1: '99'},
      );
      expect(m, isEmpty);
    });

    test('call-id anchor pins the interval for the id-less middle', () {
      final durable = toolRefsFromRows(scope, [
        user('7'),
        assistant('8', [
          const ToolCall('CA', 'a', '{}'),
          const ToolCall('', 'b', '{"p":2}'),
        ]),
      ]);
      final other = toolRefsFromRows(scope, [
        assistant('live-0', [
          const ToolCall('CA', 'a', '{}'),
          const ToolCall('', 'b', '{"p":2}'),
        ]),
      ]);
      final m = matchToolIdentity(durable: durable, other: other);
      expect(m.where((x) => x.basis == 'call-id'), hasLength(1));
      expect(m.where((x) => x.basis == 'closed-interval'), hasLength(1));
    });

    test('hidden rows are barriers', () {
      final durable = toolRefsFromRows(scope, [
        user('7'),
        const Message(
          id: '7h',
          role: 'user',
          content: 'hidden',
          displayKind: 'hidden',
        ),
        assistant('8', [const ToolCall('', 'a', '{}')]),
      ]);
      // The hidden row shifts the barrier turn by one: pairing must key
      // off the SAME pinned turn, not off a shifted guess.
      final other = toolRefsFromRows(scope, [
        user('7'),
        assistant('live-0', [const ToolCall('', 'a', '{}')]),
      ]);
      final pinnedAcrossBarrier = matchToolIdentity(
        durable: durable,
        other: other,
        durableUserTurns: {'7': 1},
        otherSegmentUserRows: {1: '7'},
      );
      expect(pinnedAcrossBarrier, isEmpty);
    });
  });

  group('projectToolOverlap', () {
    final durable4 = [
      user('1'),
      assistant('2', [
        for (var i = 1; i <= 4; i++)
          ToolCall('C$i', 't$i', '{"i":$i}'),
      ]),
      for (var i = 1; i <= 4; i++) result('r$i', 'C$i', 'out$i'),
    ];

    transcript4({bool results = true, String assistantId = 'live-0'}) => [
      assistant(
        assistantId,
        [
          for (var i = 1; i <= 4; i++)
            ToolCall('C$i', 't$i', '{"i":$i}'),
        ],
      ),
      if (results)
        for (var i = 1; i <= 4; i++) result('tr$i', 'C$i', 'out$i'),
    ];

    test('T1 equal completeness: one set of exclusions, no overrides', () {
      final live = LiveTurn()..transcript = transcript4();
      final p = projectToolOverlap(
        sessionId: scope,
        history: durable4,
        live: live,
      );
      expect(p.matches, hasLength(4));
      expect(p.transcriptExcluded, hasLength(4));
      expect(p.durableOverrides, isEmpty);
    });

    test('durable strictly fuller (transcript lacks results) still '
        'converges to durable', () {
      final live = LiveTurn()
        ..transcript = transcript4(results: false);
      final p = projectToolOverlap(
        sessionId: scope,
        history: durable4,
        live: live,
      );
      expect(p.transcriptExcluded, hasLength(4));
      expect(p.durableOverrides, isEmpty);
    });

    test('T2 transcript strictly fuller: durable slot carries the payload', () {
      final thin = [
        user('1'),
        assistant('2', [
          for (var i = 1; i <= 4; i++)
            ToolCall('C$i', 't$i', '{"i":$i}'),
        ], ts: 100),
      ];
      final live = LiveTurn()..transcript = transcript4();
      final p = projectToolOverlap(sessionId: scope, history: thin, live: live);
      expect(p.durableOverrides, hasLength(4));
      expect(p.transcriptExcluded, hasLength(4));
      for (var i = 1; i <= 4; i++) {
        final ov = p.durableOverrides['s#2#c${i - 1}']!;
        expect(ov.result, 'out$i');
        expect(ov.timestamp, 100, reason: 'durable slot time is preserved');
      }
    });

    test('T3 contradicting content stays doubled', () {
      final other = [
        assistant('live-0', [
          for (var i = 1; i <= 4; i++)
            ToolCall('C$i', 't$i', '{"i":99}'),
        ]),
        for (var i = 1; i <= 4; i++) result('tr$i', 'C$i', 'different$i'),
      ];
      final live = LiveTurn()..transcript = other;
      final p = projectToolOverlap(
        sessionId: scope,
        history: durable4,
        live: live,
      );
      expect(p.transcriptExcluded, isEmpty);
      expect(p.durableOverrides, isEmpty);
      expect(p.matches, hasLength(4), reason: 'identity IS proven; content '
          'simply does not cover — both stay');
    });

    test('T4 partial durable: only the provable two converge', () {
      final thin = [
        user('1'),
        assistant('2', [
          for (var i = 1; i <= 2; i++)
            ToolCall('C$i', 't$i', '{"i":$i}'),
        ]),
        for (var i = 1; i <= 2; i++) result('r$i', 'C$i', 'out$i'),
      ];
      final live = LiveTurn()..transcript = transcript4();
      final p = projectToolOverlap(sessionId: scope, history: thin, live: live);
      expect(p.matches, hasLength(2));
      expect(p.transcriptExcluded, hasLength(2));
    });

    test('T4 raw SSE without any identity keeps 2+4', () {
      final thin = [
        user('1'),
        assistant('2', [
          for (var i = 1; i <= 2; i++)
            ToolCall('C$i', 't$i', '{"i":$i}'),
        ]),
        for (var i = 1; i <= 2; i++) result('r$i', 'C$i', 'out$i'),
      ];
      final live = LiveTurn();
      for (var i = 1; i <= 4; i++) {
        live.tools.add(LiveTool('t$i', '{"i":$i}'));
      }
      final p = projectToolOverlap(sessionId: scope, history: thin, live: live);
      expect(p.matches, isEmpty);
      expect(p.liveToolsExcluded, isEmpty);
      expect(p.transcriptExcluded, isEmpty);
    });

    test('T6 terminal transcript with all tools covered yields exclusions, '
        'never a fall-through flag', () {
      final live = LiveTurn()..transcript = transcript4();
      final p = projectToolOverlap(
        sessionId: scope,
        history: durable4,
        live: live,
      );
      expect(p.transcriptExcluded, hasLength(4));
    });

    test('empty transcript → empty projection', () {
      final live = LiveTurn()..transcript = [];
      final p = projectToolOverlap(
        sessionId: scope,
        history: durable4,
        live: live,
      );
      expect(p.matches, isEmpty);
    });

    test('raw inputs are never mutated', () {
      final history = durable4.map((m) => m).toList();
      final snapshot = [
        for (final m in history)
          [m.id, m.role, m.content, m.toolCallId, m.toolCalls.length],
      ];
      final live = LiveTurn()..transcript = transcript4();
      projectToolOverlap(sessionId: scope, history: history, live: live);
      for (var i = 0; i < history.length; i++) {
        final m = history[i];
        expect(
          [m.id, m.role, m.content, m.toolCallId, m.toolCalls.length],
          snapshot[i],
        );
      }
    });

    test('narration/system rows never participate (T8 core)', () {
      final mixed = [
        user('1'),
        assistant('2', [const ToolCall('C1', 't1', '{}')], content: 'note'),
        result('r1', 'C1', 'out'),
      ];
      final live = LiveTurn()
        ..transcript = [
          assistant('live-0', [const ToolCall('C1', 't1', '{}')], content: 'note'),
          result('tr1', 'C1', 'out'),
        ];
      final p = projectToolOverlap(
        sessionId: scope,
        history: mixed,
        live: live,
      );
      expect(p.matches, hasLength(1));
      final entries = projectMessages(mixed);
      expect(
        entries.where((e) => e.kind != EntryKind.tool),
        hasLength(2),
        reason: 'narration + user stay exactly as projected',
      );
    });
  });
}
