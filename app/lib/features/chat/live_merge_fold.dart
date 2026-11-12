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
/// (S) LATEATTACH: no name evidence (mismatched names, a nameless durable
///     tool, or a live list SHORTER than the durable tail because this client
///     attached mid-run) — hand back min(durable tools, COMPLETED live rows)
///     live slots from the head instead of standing down. Standing down here
///     is what made "已完成過的幽靈執行紀錄" pile up at the bottom of the
///     initiating client after a mid-run refresh.
/// (c) only if even (S) has nothing to hand back — show BOTH.
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
  // folding the DURABLE side would swallow steps the stream never carried.
  // LATEATTACH: this no longer exits the fold. A client that attached mid-run
  // has a live list that is a suffix of the turn, which is exactly the k > L
  // shape, and standing down there is what painted the ghost pile under the
  // real one. It only disqualifies the durable-hiding paths; the live-side
  // count hand-back (S) below still applies.
  final shorterThanDurable = k > live.tools.length;
  final durableNames = [
    for (final e in tools) e.call?.name ?? e.message.toolName,
  ];
  // (n) a nameless durable tool cannot be checked against the live side —
  // same narrowing as (a): it disqualifies the name paths, not (S).
  final nameless = durableNames.contains(null);
  final liveNames = [for (final t in live.tools) t.name];
  // (S) LATEATTACH: the count hand-back, shared by every case the name
  // evidence cannot take. Frames arrive in order, so the COMPLETED prefix of
  // the live list is the landed prefix; up to min(durable tools in this turn,
  // completed live rows) live slots go back from the head. Durable cards are
  // never hidden here, so what can disappear is bounded by the durable cards
  // already on screen — the worst case is a step that goes invisible for one
  // poll until its own durable row lands, never a lost record.
  var completedLive = 0;
  for (final t in live.tools) {
    if (t.completed) completedLive++;
  }
  final handBack = completedLive < k ? completedLive : k;
  Set<String> countHandBack() =>
      _handBackFirstLive(liveTail, projection, handBack);
  if (shorterThanDurable || nameless) return countHandBack();
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
    return _handBackFirstLive(liveTail, projection, k);
  }
  // (L) LIVE-MERGE: every durable step has a same-name live successor —
  // the live row still legitimately owns the whole tail.
  if (_inOrderSubsequence(durableNames.cast<String>(), liveNames)) {
    return {for (final e in tools) toolSlotKeyFor(e, projection.scope)};
  }
  // (c) no name evidence either way: hand back what is provably landed (S)
  // and show the rest. Durable cards still never hide; a live-only step is
  // never swallowed, because (S) hides no more than `k` rows and only the
  // completed ones.
  return countHandBack();
}

/// RUNORDER path (b) and LATEATTACH path (S) share one shape: live slots
/// `0..m-1` are covered by durable cards already on screen, so they leave the
/// provisional row and everything from `m` on stays at the end of the timeline.
Set<String> _handBackFirstLive(
  List<Message> liveTail,
  ToolOverlapProjection projection,
  int m,
) {
  if (m <= 0) return const {};
  return {
    for (final e in projectMessages(liveTail))
      if (e.kind == EntryKind.tool &&
          e.call != null &&
          e.call!.id.startsWith('live#') &&
          (int.tryParse(e.call!.id.substring(5)) ?? m) < m)
        toolSlotKeyFor(e, projection.scope),
  };
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
