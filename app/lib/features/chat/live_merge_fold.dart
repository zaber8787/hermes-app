import '../../models/message.dart';
import '../../models/session_activity.dart';
import 'live_turn.dart';
import 'tool_timeline_projection.dart';

/// LIVE-MERGE: only a continuous, identified live run can own the entire
/// open durable tail. Returns display exclusions; stored history is untouched.
///
/// RUNORDER: ownership is proven by the gates below (:20-53 at the shape
/// this was written against); INSIDE that window the fold now hands the
/// FIRST k live rows (k = durable tools past the anchor) back to the
/// durable cards, so durable tools keep their slots and narration and
/// execution stay interleaved instead of "thinking first, tools last".
/// This allocates display authority inside a PROVEN window — it is not
/// identity matching, and the projection layer's identity/structure-only
/// contract (tool_timeline_projection.dart:6-15) stays untouched.
/// Exit conditions, checked in order:
/// (a) k > live.tools.length — the live stream missed steps it never
///     carried, so dropping ANY durable card would SWALLOW a step: stand
///     down (a duplicated step is the safe outcome; a swallowed one is
///     not — the trade-off tool_timeline_projection.dart:12-15 already
///     makes).
/// (n) a durable tool without any name — nothing to compare, stand down.
/// (b) the first k names match the durable order pairwise — exclude the
///     first k LIVE slots (the new RUNORDER path).
/// (L) the durable names are an ordered subsequence of the live names —
///     the LIVE-MERGE whole-tail fold is still justified (a live row owns
///     every durable card; timeline_dup's [skill_view, terminal] case).
/// (c) anything else — an INTENTIONAL change from folding anyway: stand
///     down and show both, rather than hide steps over a mismatch.
Set<String> liveMergeFoldExclusions({
  required LiveTurn? live,
  required List<ActivityRun> activeRuns,
  required List<Message> durableTail,
  required ToolOverlapProjection projection,
  required List<Message> liveTail,

  /// TIMELINEDUP: the durable user row this device's own send landed as
  /// (ChatController.ownTurnAnchor). Ownership evidence for the window
  /// before the observation poll lists the run; never a text guess here.
  Message? ownAnchor,
}) {
  if (live == null ||
      live.completed ||
      live.runId == null ||
      (live.transcript != null && live.transcript!.isNotEmpty) ||
      liveTail.isEmpty ||
      liveTail.every((m) => m.toolCalls.isEmpty) ||
      projection.liveToolsExcluded.isNotEmpty ||
      activeRuns.length > 1 ||
      (activeRuns.isEmpty && ownAnchor == null) ||
      (activeRuns.isNotEmpty &&
          (activeRuns.single.runId != live.runId ||
              activeRuns.single.isTerminal))) {
    return const {};
  }
  final anchorIndex = durableTail.lastIndexWhere(toolTurnBoundary);
  if (anchorIndex < 0) return const {};
  final anchor = durableTail[anchorIndex];
  if (!anchor.isUserTurn) return const {};
  if (activeRuns.isEmpty) {
    if (ownAnchor!.id != anchor.id) return const {};
  } else {
    final user = activeRuns.single.user;
    if (user == null) return const {};
    // GHOSTRUN: compat's after_id is the session's last row id read BEFORE
    // the run's user row lands — a watermark, never the user row itself.
    // The anchor must be the ONE user turn past it; equality never held
    // once the run was listed, so the live row re-rendered the whole tail.
    final after = user.afterId;
    if (after != null
        ? !_ownsPastWatermark(durableTail, anchor, after)
        : user.text != anchor.content) {
      return const {};
    }
  }
  final entries = projectMessages(durableTail.sublist(anchorIndex));
  final tools = entries.where((e) => e.kind == EntryKind.tool).toList();
  if (tools.isEmpty) return const {};
  final lastTool = entries.lastIndexWhere((e) => e.kind == EntryKind.tool);
  if (entries.skip(lastTool + 1).any((e) => e.kind == EntryKind.finalReply)) {
    return const {};
  }
  final k = tools.length;
  // (a) R12: the live list is SHORTER than the durable tail it would own —
  // folding would swallow the steps it never carried.
  if (k > live.tools.length) return const {};
  final durableNames = [
    for (final e in tools) e.call?.name ?? e.message.toolName,
  ];
  // (n) a nameless durable tool cannot be checked against the live side.
  if (durableNames.contains(null)) return const {};
  final liveNames = [for (final t in live.tools) t.name];
  var prefix = true;
  for (var i = 0; i < k; i++) {
    if (durableNames[i] != liveNames[i]) {
      prefix = false;
      break;
    }
  }
  // (b) RUNORDER: the live head IS the durable tail — hand those k slots
  // back so the durable cards keep their interleaved positions and only
  // the not-yet-durable live rows (k..) render at the end.
  if (prefix) {
    return {
      for (final e in projectMessages(liveTail))
        if (e.kind == EntryKind.tool &&
            e.call != null &&
            e.call!.id.startsWith('live#') &&
            (int.tryParse(e.call!.id.substring(5)) ?? k) < k)
          toolSlotKeyFor(e, projection.scope),
    };
  }
  // (L) LIVE-MERGE: every durable step has a same-name live successor —
  // the live row still legitimately owns the whole tail.
  if (_inOrderSubsequence(durableNames.cast<String>(), liveNames)) {
    return {for (final e in tools) toolSlotKeyFor(e, projection.scope)};
  }
  // (c) no evidence either way: show BOTH (intentional change, see header).
  return const {};
}

/// [sub] appears in [seq] in order (not necessarily contiguously).
bool _inOrderSubsequence(List<String> sub, List<String> seq) {
  var j = 0;
  for (final s in seq) {
    if (j < sub.length && s == sub[j]) j++;
  }
  return j == sub.length;
}

bool _ownsPastWatermark(List<Message> rows, Message anchor, int after) {
  final id = int.tryParse(anchor.id);
  if (id == null || id <= after) return false;
  for (final m in rows) {
    if (!m.isUserTurn || identical(m, anchor)) continue;
    final n = int.tryParse(m.id);
    if (n != null && n > after) return false;
  }
  return true;
}
