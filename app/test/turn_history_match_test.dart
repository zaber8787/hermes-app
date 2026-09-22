import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/features/chat/turn_history_match.dart';
import 'package:hermes_app/models/message.dart';

/// STUCK-BUSY plan B1: the shared folded-anchor helper. These tests were
/// written BEFORE the helper existed (red), then the fold semantics were
/// moved out of chat_controller unchanged (green).
void main() {
  group('foldTurnText (moved semantics, untouched)', () {
    test('trim + collapse whitespace + drop attachment tags', () {
      expect(foldTurnText('  hello   world \n'), 'hello world');
      // i18n-exempt: cross-device history-matching fixtures, not UI text.
      expect(foldTurnText('a [附件: x.png] b'), 'a b');
      expect(foldTurnText('\n\n部署 完成\n[附件: log.txt]'), '部署 完成');
      expect(foldTurnText('[附件: only]'), '');
      expect(foldTurnText('   '), '');
    });

    test('foldedTurnTextEquals: exact first, folded second', () {
      expect(foldedTurnTextEquals('same', 'same'), isTrue);
      // i18n-exempt: matching-rule fixtures (protocol), not UI text.
      expect(foldedTurnTextEquals('a\n\tb  c', 'a [附件: f] b c'), isTrue);
      // Raw-different but trim-equal still matches (exact rule includes trim).
      expect(foldedTurnTextEquals(' hi ', 'hi'), isTrue);
    });

    test('folded-empty rows may only match raw-exact (no empty-collapse)', () {
      // i18n-exempt: matching-rule fixtures (protocol), not UI text.
      expect(foldedTurnTextEquals('', '[附件: x]'), isFalse);
      expect(foldedTurnTextEquals('  ', '[附件: x]'), isFalse);
      expect(foldedTurnTextEquals('', ''), isTrue);
      expect(foldedTurnTextEquals('[附件: x]', '[附件: x]'), isTrue);
    });
  });

  group('inspectPendingHistory', () {
    const user = Message(id: '1', role: 'user', content: '問題一');
    const asstFinal = Message(id: '2', role: 'assistant', content: '答復');
    const asstTools = Message(
      id: '2',
      role: 'assistant',
      content: '',
      toolCalls: [ToolCall('t1', 'shell', '{}')],
    );
    const toolRow = Message(
      id: '3',
      role: 'tool',
      content: 'result',
      toolCallId: 't1',
    );

    test('final after anchor: hasFinal true, tail assistant', () {
      final r = inspectPendingHistory(
        rows: const [user, asstFinal],
        pendingText: '問題一',
      );
      expect(r.anchorFound, isTrue);
      expect(r.hasFinal, isTrue);
      expect(r.tailKind, TurnTailKind.assistant);
      expect(r.hasRowsAfterAnchor, isTrue);
    });

    test('tool-tail (the incident shape) is NOT final', () {
      final r = inspectPendingHistory(
        rows: const [user, asstTools, toolRow],
        pendingText: '問題一',
      );
      expect(r.anchorFound, isTrue);
      expect(r.hasFinal, isFalse);
      expect(r.tailKind, TurnTailKind.tool);
      expect(r.hasRowsAfterAnchor, isTrue);
    });

    test('user-only turn: no rows after anchor, no final', () {
      final r = inspectPendingHistory(rows: const [user], pendingText: '問題一');
      expect(r.anchorFound, isTrue);
      expect(r.hasFinal, isFalse);
      expect(r.hasRowsAfterAnchor, isFalse);
      expect(r.tailKind, TurnTailKind.none);
    });

    test('folded Discord text anchors the same as raw', () {
      final r = inspectPendingHistory(
        // i18n-exempt: cross-device persistence fixture (Discord reformat).
        rows: const [
          Message(id: '1', role: 'user', content: '部署 完成\n[附件: log.txt]'),
          Message(id: '2', role: 'assistant', content: 'done'),
        ],
        pendingText: '部署 完成 [附件: log.txt]',
      );
      expect(r.anchorFound, isTrue);
      expect(r.hasFinal, isTrue);
    });

    test('turn ends at the NEXT user row, even without a final', () {
      final r = inspectPendingHistory(
        rows: const [
          user,
          asstTools,
          Message(id: '4', role: 'user', content: '下一個問題'),
          Message(id: '5', role: 'assistant', content: '另一輪的final'),
        ],
        pendingText: '問題一',
      );
      expect(r.hasFinal, isFalse);
      expect(r.tailKind, TurnTailKind.tool);
    });

    test('legacy unknown text can never anchor', () {
      final r = inspectPendingHistory(
        rows: const [user, asstFinal],
        pendingText: null,
        knownText: false,
      );
      expect(r.anchorFound, isFalse);
      expect(r.ambiguous, isFalse);
      expect(r.hasFinal, isFalse);
    });

    test('genuinely empty pending text anchors an empty user row only raw-exact',
        () {
      // i18n-exempt: anchor-rule fixture (protocol), not UI text.
      const emptyUser = Message(id: '9', role: 'user', content: '');
      final r = inspectPendingHistory(
        rows: const [emptyUser, asstFinal],
        pendingText: '',
      );
      expect(r.anchorFound, isTrue);
      final s = inspectPendingHistory(
        // i18n-exempt: anchor-rule fixture (protocol), not UI text.
        rows: const [Message(id: '9', role: 'user', content: '   '), asstFinal],
        pendingText: '',
      );
      expect(s.anchorFound, isFalse);
    });

    test('time floor drops older duplicates (stale same-text)', () {
      final r = inspectPendingHistory(
        rows: const [
          Message(id: '1', role: 'user', content: '問題一', timestamp: 100),
          Message(id: '2', role: 'assistant', content: '舊答復'),
          Message(id: '3', role: 'user', content: '問題一', timestamp: 300),
        ],
        pendingText: '問題一',
        timeFloor: 295,
      );
      expect(r.anchorIndex, 2);
      expect(r.ambiguous, isFalse);
    });

    test('zero-timestamp (no server time) rows are never dropped by floor', () {
      final r = inspectPendingHistory(
        rows: const [Message(id: '1', role: 'user', content: '問題一')],
        pendingText: '問題一',
        timeFloor: 1000,
      );
      expect(r.anchorFound, isTrue);
    });

    test('multiple qualifying candidates are ambiguous, never picked', () {
      final r = inspectPendingHistory(
        rows: const [
          Message(id: '1', role: 'user', content: '問題一', timestamp: 300),
          Message(id: '2', role: 'user', content: '問題一', timestamp: 301),
        ],
        pendingText: '問題一',
        timeFloor: 295,
      );
      expect(r.anchorFound, isFalse);
      expect(r.ambiguous, isTrue);
    });

    test('excluded ids (before-send watermark) leave the newer row unique', () {
      final r = inspectPendingHistory(
        rows: const [
          Message(id: '1', role: 'user', content: '問題一'),
          Message(id: '2', role: 'user', content: '問題一'),
        ],
        pendingText: '問題一',
        excludeIds: const {'1'},
      );
      expect(r.anchorIndex, 1);
    });

    test('historyAfterId watermark drops older numeric rows', () {
      final r = inspectPendingHistory(
        rows: const [
          Message(id: '5', role: 'user', content: '問題一'),
          Message(id: '9', role: 'user', content: '問題一'),
        ],
        pendingText: '問題一',
        historyAfterId: 5,
      );
      expect(r.anchorIndex, 1);
    });

    test('displayKind rows are filtered before the final/tail check', () {
      final r = inspectPendingHistory(
        rows: const [
          user,
          Message(id: '7', role: 'system', content: '', displayKind: 'auto_continue'),
          asstTools,
        ],
        pendingText: '問題一',
      );
      expect(r.hasFinal, isFalse);
      expect(r.tailKind, TurnTailKind.tool);
    });
  });

  group('evaluateRecoveryEvidence (B2 priorities)', () {
    test('explicit terminal statuses settle; completed+no-final is incomplete',
        () {
      final toolTail = inspectPendingHistory(
        rows: const [
          Message(id: '1', role: 'user', content: 'q'),
          Message(
            id: '2',
            role: 'assistant',
            content: '',
            toolCalls: [ToolCall('t', 'x', '{}')],
          ),
        ],
        pendingText: 'q',
      );
      const finalHist = Message(id: '1', role: 'user', content: 'q');
      final withFinal = inspectPendingHistory(
        rows: const [
          finalHist,
          Message(id: '2', role: 'assistant', content: 'ok'),
        ],
        pendingText: 'q',
      );
      for (final s in ['completed', 'cancelled', 'failed']) {
        expect(
          evaluateRecoveryEvidence(
            status: s,
            history: withFinal,
            quietConfirmed: true,
          ),
          RecoveryVerdict.normalTerminal,
          reason: s,
        );
      }
      expect(
        evaluateRecoveryEvidence(status: 'completed', history: toolTail),
        RecoveryVerdict.incompleteTerminal,
      );
      // cancelled never masquerades as "ended without a final": provenance
      // (stop record) decides at the settle site, the verdict stays normal.
      expect(
        evaluateRecoveryEvidence(status: 'cancelled', history: toolTail),
        RecoveryVerdict.normalTerminal,
      );
    });

    test('positive-active statuses can never be called terminal', () {
      for (final s in ['queued', 'running', 'waiting_for_approval', 'stopping']) {
        expect(
          evaluateRecoveryEvidence(status: s, quietConfirmed: true),
          RecoveryVerdict.running,
          reason: s,
        );
      }
      // A snapshot proving an active run outranks tool-tail history.
      expect(
        evaluateRecoveryEvidence(activeConfirmed: true, quietConfirmed: false),
        RecoveryVerdict.running,
      );
    });

    test('unknown statuses and missing evidence are unknown', () {
      expect(evaluateRecoveryEvidence(status: 'exploded'), RecoveryVerdict.unknown);
      expect(evaluateRecoveryEvidence(runGone: true), RecoveryVerdict.unknown);
      expect(
        evaluateRecoveryEvidence(runGone: true, quietConfirmed: false),
        RecoveryVerdict.unknown,
      );
      // runGone + quiet but NO anchor: still unknown, never incomplete.
      expect(
        evaluateRecoveryEvidence(
          runGone: true,
          quietConfirmed: true,
          history: inspectPendingHistory(rows: const [], pendingText: 'q'),
        ),
        RecoveryVerdict.unknown,
      );
    });

    test('quiet + unique anchor + no final is incompleteTerminal', () {
      final toolTail = inspectPendingHistory(
        rows: const [
          Message(id: '1', role: 'user', content: 'q'),
          Message(
            id: '2',
            role: 'assistant',
            content: '',
            toolCalls: [ToolCall('t', 'x', '{}')],
          ),
          Message(id: '3', role: 'tool', content: 'r', toolCallId: 't'),
        ],
        pendingText: 'q',
      );
      expect(
        evaluateRecoveryEvidence(
          runGone: true,
          quietConfirmed: true,
          history: toolTail,
        ),
        RecoveryVerdict.incompleteTerminal,
      );
      // User-only history under quiet: incomplete too.
      expect(
        evaluateRecoveryEvidence(
          quietConfirmed: true,
          history: inspectPendingHistory(
            rows: const [Message(id: '1', role: 'user', content: 'q')],
            pendingText: 'q',
          ),
        ),
        RecoveryVerdict.incompleteTerminal,
      );
      // Quiet + final present: settle normally.
      expect(
        evaluateRecoveryEvidence(
          quietConfirmed: true,
          history: inspectPendingHistory(
            rows: const [
              Message(id: '1', role: 'user', content: 'q'),
              Message(id: '2', role: 'assistant', content: 'ok'),
            ],
            pendingText: 'q',
          ),
        ),
        RecoveryVerdict.normalTerminal,
      );
      // Ambiguous anchor is never incomplete.
      expect(
        evaluateRecoveryEvidence(
          quietConfirmed: true,
          history: inspectPendingHistory(
            rows: const [
              Message(id: '1', role: 'user', content: 'q', timestamp: 10),
              Message(id: '2', role: 'user', content: 'q', timestamp: 11),
            ],
            pendingText: 'q',
            timeFloor: 5,
          ),
        ),
        RecoveryVerdict.unknown,
      );
    });

    test('recentTerminal identity match settles without an anchor', () {
      expect(
        evaluateRecoveryEvidence(
          terminalMatch: true,
          history: inspectPendingHistory(
            rows: const [Message(id: '1', role: 'assistant', content: 'x')],
            pendingText: 'q',
          ),
        ),
        RecoveryVerdict.normalTerminal,
      );
    });
  });
}
