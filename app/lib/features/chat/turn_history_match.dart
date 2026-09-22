import '../../models/message.dart';

/// STUCK-BUSY plan B1/B2: ONE shared matcher for "which history row is the
/// pending turn's user row, and did that turn end with a final". Ghost
/// claiming, bootstrap anchoring, live reconcile and pendingDelivered all
/// call into here so the four paths can no longer disagree. Raw text, sent
/// payloads, history and fingerprints are NEVER rewritten by this module —
/// text is only ever COMPARED in folded form.

/// Claim-comparison fold: trim, collapse all whitespace (incl. newlines),
/// drop the platform's attachment-tag decoration. Moved verbatim out of
/// ChatController (v0.13.17 semantics — nothing here changes what a fold IS).
String foldTurnText(String s) =>
    // i18n-exempt: history-matching regex (cross-device protocol) — see
    // I18N-PLAN §5; the decoration tag is protocol data, not UI text.
    s.replaceAll(RegExp(r'\[附件: [^\]]*\]'), '').replaceAll(
      RegExp(r'\s+'),
      ' ',
    ).trim();

/// Shared comparison rule (B1): raw exact first, then trim/fold equality.
/// When either side folds to empty (attachment-tag-only or whitespace),
/// ONLY the raw exact form may match — the fold must never pair two
/// different "empty-looking" turns together.
bool foldedTurnTextEquals(String a, String b) {
  if (a == b) return true;
  final fa = foldTurnText(a), fb = foldTurnText(b);
  if (fa.isEmpty || fb.isEmpty) return false;
  return fa == fb;
}

/// What the last ordinary row after the anchor looks like (B1): `tool` is
/// an assistant row still holding tool calls or a raw tool result row —
/// the incident's "terminal history ends on a tool row" shape.
enum TurnTailKind { none, user, assistant, tool }

/// Pure inspection of a loaded history page against one pending turn.
/// NEVER mutates rows; the final definition stays the existing one:
/// the LAST ordinary (displayKind == null) row of the turn must be an
/// assistant with no tool calls and non-empty content — "some assistant
/// appeared once" and "a tool row counts as final" are both still NO.
class PendingHistoryInspection {
  const PendingHistoryInspection({
    required this.anchorIndex,
    required this.ambiguous,
    required this.hasRowsAfterAnchor,
    required this.hasFinal,
    required this.tailKind,
  });

  /// Index of the unique qualifying user anchor, -1 when none/ambiguous.
  final int anchorIndex;

  /// Several candidate rows qualify and neither the pending's time floor
  /// nor its row watermark (historyAfterId / excludeIds) identifies one —
  /// picking either could settle on the wrong turn (B1: never任选).
  final bool ambiguous;

  /// Raw (displayKind included) rows between the anchor and the next user
  /// row — "something landed", not "the turn is final".
  final bool hasRowsAfterAnchor;
  final bool hasFinal;
  final TurnTailKind tailKind;

  bool get anchorFound => anchorIndex >= 0;
}

/// [pendingText] is the persisted user_text; `knownText: false` marks a
/// legacy record WITHOUT the field — it can never anchor and must not be
/// treated as an explicit empty string (AUDIT-12).
/// [timeFloor] is the bootstrap floor (seconds-epoch, startedAt − grace):
/// rows WITH a server timestamp below it are older turns; timestamp 0
/// (no server time) is never dropped by the floor.
/// [excludeIds] is the live `_beforeSend` watermark; [historyAfterId] is
/// the persisted max numeric history id at send time (B3) — both are
/// row-identity watermarks, never content attribution proofs.
PendingHistoryInspection inspectPendingHistory({
  required List<Message> rows,
  String? pendingText,
  bool knownText = true,
  double? timeFloor,
  Set<String> excludeIds = const {},
  int? historyAfterId,
}) {
  if (!knownText) {
    return const PendingHistoryInspection(
      anchorIndex: -1,
      ambiguous: false,
      hasRowsAfterAnchor: false,
      hasFinal: false,
      tailKind: TurnTailKind.none,
    );
  }
  final text = pendingText ?? '';
  final candidates = <int>[];
  for (var i = 0; i < rows.length; i++) {
    final m = rows[i];
    if (!m.isUserTurn || excludeIds.contains(m.id)) continue;
    if (historyAfterId != null) {
      final numeric = int.tryParse(m.id);
      if (numeric != null && numeric <= historyAfterId) continue;
    }
    if (!foldedTurnTextEquals(m.content, text)) continue;
    if (timeFloor != null && m.timestamp > 0 && m.timestamp < timeFloor) {
      continue;
    }
    candidates.add(i);
  }
  if (candidates.isEmpty) {
    return const PendingHistoryInspection(
      anchorIndex: -1,
      ambiguous: false,
      hasRowsAfterAnchor: false,
      hasFinal: false,
      tailKind: TurnTailKind.none,
    );
  }
  if (candidates.length > 1) {
    // Repeated identical text: the watermarks above already had their
    // chance. Ambiguous — no arbitrary pick of an older (or newer) turn.
    return const PendingHistoryInspection(
      anchorIndex: -1,
      ambiguous: true,
      hasRowsAfterAnchor: false,
      hasFinal: false,
      tailKind: TurnTailKind.none,
    );
  }
  final anchor = candidates.single;
  final turnRows = rows.skip(anchor + 1).takeWhile((m) => !m.isUserTurn).toList();
  final ordinary = turnRows.where((m) => m.displayKind == null).toList();
  final tail = ordinary.isEmpty ? null : ordinary.last;
  final hasFinal =
      tail != null &&
      tail.role == 'assistant' &&
      tail.toolCalls.isEmpty &&
      tail.content.isNotEmpty;
  final tailKind = switch (tail) {
    null => TurnTailKind.none,
    _ when tail.role == 'tool' || tail.toolCalls.isNotEmpty => TurnTailKind.tool,
    _ when tail.role == 'assistant' => TurnTailKind.assistant,
    _ when tail.role == 'user' => TurnTailKind.user,
    _ => TurnTailKind.none,
  };
  return PendingHistoryInspection(
    anchorIndex: anchor,
    ambiguous: false,
    hasRowsAfterAnchor: turnRows.isNotEmpty,
    hasFinal: hasFinal,
    tailKind: tailKind,
  );
}

/// B2: the terminal-evidence verdict every read-only recovery path shares.
enum RecoveryVerdict {
  /// Positive evidence the run is still working (status or an active-run
  /// snapshot). A tool-tail or an expired timer may NEVER override this.
  running,

  /// The turn ended and we know it: explicit status/recentTerminal match,
  /// or quiet confirmation plus a real final in history.
  normalTerminal,

  /// Confirmed quiet, unique anchor, no final in the turn: the terminal
  /// signal was lost (e.g. review_input_budget_exhausted tails on a tool
  /// row). Settle with the notice — keep rows, never fabricate a final.
  incompleteTerminal,

  /// Anything else — including run 404 alone, stale/unsupported/failed
  /// activity, unknown statuses, ambiguous anchors. Keep observing within
  /// the budget; never derive "idle" from a missing answer.
  unknown,
}

/// Pure evidence-priority evaluator (B2 §1–5 order):
/// 1. explicit terminal status for our runId outranks everything;
/// 2. positive-active status or an active snapshot says `running`;
/// 3. recentTerminal identity match settles without an anchor;
/// 4. CONFIRMED quiet + unique anchor decides final vs no-final;
/// 5. otherwise unknown.
RecoveryVerdict evaluateRecoveryEvidence({
  String? status,
  bool runGone = false,
  bool activeConfirmed = false,
  bool quietConfirmed = false,
  bool terminalMatch = false,
  PendingHistoryInspection? history,
}) {
  if (status != null) {
    switch (status) {
      case 'completed':
        final h = history;
        if (h != null && h.anchorFound && !h.hasFinal) {
          return RecoveryVerdict.incompleteTerminal;
        }
        return RecoveryVerdict.normalTerminal;
      case 'cancelled':
      case 'failed':
        // Settled by the server (or the user's own stop record, applied at
        // the settle site) — provenance decides the banner, not history.
        return RecoveryVerdict.normalTerminal;
      case 'queued':
      case 'running':
      case 'waiting_for_approval':
      case 'stopping':
        return RecoveryVerdict.running;
      default:
        return RecoveryVerdict.unknown;
    }
  }
  if (terminalMatch) return RecoveryVerdict.normalTerminal;
  if (activeConfirmed) return RecoveryVerdict.running;
  final h = history;
  if (quietConfirmed && h != null && h.anchorFound && !h.ambiguous) {
    return h.hasFinal
        ? RecoveryVerdict.normalTerminal
        : RecoveryVerdict.incompleteTerminal;
  }
  return RecoveryVerdict.unknown;
}
