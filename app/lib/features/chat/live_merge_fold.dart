import '../../models/message.dart';
import '../../models/session_activity.dart';
import 'live_turn.dart';
import 'tool_timeline_projection.dart';

/// LIVE-MERGE: only a continuous, identified live run can own the entire
/// open durable tail. Returns display exclusions; stored history is untouched.
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
    if (user.afterId != null
        ? user.afterId.toString() != anchor.id
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
  return {for (final e in tools) toolSlotKeyFor(e, projection.scope)};
}
