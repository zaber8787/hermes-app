import 'dart:convert';

import '../../models/message.dart';
import 'live_turn.dart';

/// TOOLCARD-DUP: pure render-layer projection that pairs tool
/// representations of the SAME call across the durable history and the
/// live/terminal transcript, then lets ONE of them stand. Red lines:
/// durable rows stay the single source of truth — nothing here mutates
/// `c.messages`, a transcript, `turn.tools`, or any stored field; this
/// module only READS snapshots and emits presentation decisions. Matching
/// is identity/structure ONLY — never time windows, text similarity, or
/// card-title/count heuristics. Anything below the evidence bar stays
/// UNMATCHED and BOTH representations render (a duplicated step is the
/// safe outcome; a swallowed step is not).

/// Slot-key scope separator: keys are `$scope#$rowId#c$i` / `#r` so the
/// same numeric row can never alias across sessions in the maps below.
String toolSlotScope(String sessionId) => sessionId;

/// Stable slot key for a projected tool entry. Basis: session + durable
/// row + call index (or the result row for an orphan result), never a
/// post-filter index or a shared runId.
String toolSlotKeyFor(DisplayEntry e, String scope) {
  final m = e.message;
  final c = e.call;
  if (c == null) return '$scope#${m.id}#r';
  final i = m.toolCalls.indexOf(c);
  return '$scope#${m.id}#c${i >= 0 ? i : 'x${c.id}'}';
}

/// Raw turn boundary (plan §2.1.1): a plain user row splits turns even
/// when the wake projection renders it as a system line; hidden rows are
/// barriers too — nothing may pair across them.
bool toolTurnBoundary(Message m) => m.isUserTurn || m.displayKind == 'hidden';

final _numericRowId = RegExp(r'^\d+$');

/// One tool representation as the UI would show it — a read-only VIEW of
/// durable/transcript/live data, never a new Message.
class ToolRef {
  const ToolRef({
    required this.slotKey,
    required this.rowId,
    required this.callIndex,
    this.callId,
    required this.name,
    this.arguments,
    this.result,
    this.previewResult = false,
    this.timestamp = 0,
    required this.turnIndex,
    required this.order,
    this.liveIndex,
  });

  final String slotKey;
  final String rowId;

  /// Index inside the row's toolCalls; -1 for an orphan result row.
  final int callIndex;

  /// The wire call id when genuinely present (never message/seq data).
  final String? callId;
  final String name;

  /// Argument bytes; null = the source carries no arguments field at all.
  final String? arguments;

  /// Result bytes; null = no result representation (in flight / never
  /// landed). A non-null empty string IS a completed empty result.
  final String? result;

  /// True only for the raw-SSE preview channel (compat forwards the
  /// `preview` field); a full result may byte-prefix-cover a preview.
  final bool previewResult;

  /// The timestamp rendered at this slot — the same (result ?? row)
  /// value the existing EntryView shows; `covers` requires the winner to
  /// preserve it.
  final double timestamp;

  /// Turn index (durable side) or segment index (transcript side).
  final int turnIndex;

  /// Global order within its side.
  final int order;

  /// Set for raw `turn.tools` entries: their index in the live list.
  final int? liveIndex;

  bool get isOrphanResult => callIndex < 0;
}

/// Mirrors `projectMessages` row eligibility EXACTLY (same visibility
/// filter, same last-wins result map — the render shows the same bytes)
/// but keeps the row/index/turn context projectMessages flattens away.
/// Duplicate call ids are detected as raw-input ambiguity later; this
/// inventory itself must mirror what actually renders.
List<ToolRef> toolRefsFromRows(String scope, List<Message> rows) {
  final visible = rows.where((m) => m.displayKind != 'hidden').toList();
  final results = <String, Message>{
    for (final m in visible)
      if (m.role == 'tool' && m.displayKind == null && m.toolCallId != null)
        m.toolCallId!: m,
  };
  final paired = <String>{
    for (final m in visible)
      if (m.displayKind == null) ...m.toolCalls.map((c) => c.id),
  };
  final refs = <ToolRef>[];
  var turn = 0, order = 0;
  for (final m in rows) {
    if (toolTurnBoundary(m)) {
      turn++;
      continue;
    }
    if (m.displayKind != null || m.role == 'system') continue;
    if (m.role == 'assistant') {
      for (var i = 0; i < m.toolCalls.length; i++) {
        final c = m.toolCalls[i];
        final res = c.id.isEmpty ? null : results[c.id];
        refs.add(
          ToolRef(
            slotKey: '$scope#${m.id}#c$i',
            rowId: m.id,
            callIndex: i,
            callId: c.id.isEmpty ? null : c.id,
            name: c.name,
            arguments: c.arguments,
            result: res?.content,
            timestamp: (res ?? m).timestamp,
            turnIndex: turn,
            order: order++,
          ),
        );
      }
    } else if (m.role == 'tool' && !paired.contains(m.toolCallId)) {
      refs.add(
        ToolRef(
          slotKey: '$scope#${m.id}#r',
          rowId: m.id,
          callIndex: -1,
          callId:
              (m.toolCallId == null || m.toolCallId!.isEmpty) ? null : m.toolCallId,
          name: m.toolName ?? '',
          timestamp: m.timestamp,
          result: m.content,
          turnIndex: turn,
          order: order++,
        ),
      );
    }
  }
  return refs;
}

/// Raw live tools: name/args plus the preview result channel. NO wire call
/// id and no row identity exists on this path (plan §1.5), so these refs
/// can never clear the identity bar; they are listed for completeness and
/// will stay unmatched in v1.
List<ToolRef> toolRefsFromLiveTools(String scope, List<LiveTool> tools) {
  return [
    for (var i = 0; i < tools.length; i++)
      ToolRef(
        slotKey: '$scope#live#$i',
        rowId: '',
        callIndex: i,
        name: tools[i].name,
        arguments: tools[i].arguments,
        result: tools[i].completed ? tools[i].result : null,
        previewResult: tools[i].completed,
        turnIndex: 0,
        order: i,
        liveIndex: i,
      ),
  ];
}

/// JSON-aware argument equality (plan §2.1.5): parsed structural compare
/// (object key order irrelevant; array order/type/value strict); a parse
/// failure on either side falls back to raw string equality. Raw bytes are
/// never rewritten anywhere.
bool toolArgsEqual(String a, String b) {
  if (a == b) return true;
  final ja = _tryJson(a), jb = _tryJson(b);
  if (ja == null || jb == null) return false;
  return _jsonEq(ja, jb);
}

Object? _tryJson(String s) {
  try {
    return jsonDecode(s);
  } on FormatException {
    return null;
  }
}

bool _jsonEq(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !_jsonEq(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_jsonEq(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// Canonical form used ONLY for interval signatures (never for bytes).
String _signatureOf(ToolRef r) {
  final args = r.arguments;
  var argPart = '';
  if (args != null && args.isNotEmpty) {
    final j = _tryJson(args);
    argPart = j == null ? args : jsonEncode(_canonical(j));
  }
  return '${r.name}($argPart)';
}

Object? _canonical(Object? v) {
  if (v is Map) {
    final keys = v.keys.map((k) => k.toString()).toList()..sort();
    return {for (final k in keys) k: _canonical(v[k])};
  }
  if (v is List) return v.map(_canonical).toList();
  return v;
}

bool _known(String? s) => s != null && s.isNotEmpty;

/// `covers(A, B)` (plan §2.2): every expandable fact B shows, A also
/// shows, with no contradiction. A result row's mere existence proves
/// completion (even empty content); a preview may be covered only by a
/// byte-prefix of the SAME call's full result — never by substring,
/// length, or fuzz. Contradicting timestamps mean neither side covers.
bool coversToolDetails(ToolRef a, ToolRef b) {
  if (b.name.isNotEmpty && a.name != b.name) return false;
  if (_known(b.arguments)) {
    if (!_known(a.arguments)) return false;
    if (!toolArgsEqual(a.arguments!, b.arguments!)) return false;
  }
  final br = b.result;
  if (br != null) {
    final ar = a.result;
    if (ar == null) return false;
    if (ar != br && !(b.previewResult && ar.startsWith(br))) return false;
  }
  // A side WITHOUT a timestamp carries no time evidence: the matched
  // durable slot's time is used as view metadata instead (plan §2.2), so
  // absence never blocks coverage. Two present-but-different times DO.
  if (b.timestamp > 0 && a.timestamp > 0 && a.timestamp != b.timestamp) {
    return false;
  }
  return true;
}

/// A confirmed same-call pairing proven inside one build.
class ToolMatch {
  const ToolMatch(this.durable, this.other, this.basis);
  final ToolRef durable;
  final ToolRef other;
  final String basis; // 'call-id' | 'row-index' | 'closed-interval'
}

/// Identity pairing per plan §2.1 priority: real unique call ids first,
/// then trusted same numeric row id + call index, then ONLY closed,
/// anchor-pinned intervals. Anything short of that stays unmatched.
List<ToolMatch> matchToolIdentity({
  required List<ToolRef> durable,
  required List<ToolRef> other,
  /// numeric durable USER row id -> its turn index (positive boundary
  /// evidence for pinning a transcript segment to one durable turn).
  Map<String, int> durableUserTurns = const {},
  /// transcript segment index -> the numeric user row id that starts it.
  Map<int, String> otherSegmentUserRows = const {},
}) {
  final matches = <ToolMatch>[];
  final usedD = <String>{}, usedO = <String>{};

  // Ambiguity first: a call id used more than once on either side proves
  // NOTHING (no first/last wins).
  final dById = <String, ToolRef>{};
  final dIdAmbiguous = <String>{};
  for (final r in durable) {
    final id = r.callId;
    if (id == null) continue;
    if (dById.containsKey(id) || dIdAmbiguous.contains(id)) {
      dIdAmbiguous.add(id);
      dById.remove(id);
    } else {
      dById[id] = r;
    }
  }
  final oById = <String, ToolRef>{};
  final oIdAmbiguous = <String>{};
  for (final r in other) {
    final id = r.callId;
    if (id == null || dIdAmbiguous.contains(id)) continue;
    if (oById.containsKey(id) || oIdAmbiguous.contains(id)) {
      oIdAmbiguous.add(id);
      oById.remove(id);
    } else {
      oById[id] = r;
    }
  }

  // Pass 1 — call id equality, names agreeing where both have values.
  for (final o in oById.values) {
    final d = dById[o.callId];
    if (d == null) continue;
    if (d.name.isNotEmpty && o.name.isNotEmpty && d.name != o.name) continue;
    matches.add(ToolMatch(d, o, 'call-id'));
    usedD.add(d.slotKey);
    usedO.add(o.slotKey);
  }

  // A transcript segment whose hits straddle multiple durable turns is
  // contradictory — the whole segment gives up its call-id matches.
  final segTurns = <int, Set<int>>{};
  for (final m in matches) {
    (segTurns[m.other.turnIndex] ??= {}).add(m.durable.turnIndex);
  }
  final conflicted = segTurns.entries.where((e) => e.value.length > 1).map((e) => e.key).toSet();
  if (conflicted.isNotEmpty) {
    matches.removeWhere((m) => conflicted.contains(m.other.turnIndex));
    usedD
      ..clear()
      ..addAll(matches.map((m) => m.durable.slotKey));
    usedO
      ..clear()
      ..addAll(matches.map((m) => m.other.slotKey));
  }

  // Pass 2 — trusted same server row id + call index (synthetic ids such
  // as `live-N`, `pending`, or `remote:` can never anchor this).
  final dByRow = <String, ToolRef>{};
  final dRowAmbiguous = <String>{};
  for (final r in durable) {
    if (!_numericRowId.hasMatch(r.rowId)) continue;
    final k = '${r.rowId}#${r.callIndex}';
    if (dByRow.containsKey(k)) {
      dRowAmbiguous.add(k);
      dByRow.remove(k);
    } else {
      dByRow[k] = r;
    }
  }
  for (final o in other) {
    if (usedO.contains(o.slotKey)) continue;
    if (!_numericRowId.hasMatch(o.rowId)) continue;
    final k = '${o.rowId}#${o.callIndex}';
    if (dRowAmbiguous.contains(k)) continue;
    final d = dByRow[k];
    if (d == null || usedD.contains(d.slotKey)) continue;
    if (d.name.isNotEmpty && o.name.isNotEmpty && d.name != o.name) continue;
    if (_known(d.arguments) && _known(o.arguments) &&
        !toolArgsEqual(d.arguments!, o.arguments!)) {
      continue;
    }
    // A present-but-different call id is counter-evidence; no fallback may
    // step around it.
    if (d.callId != null && o.callId != null && d.callId != o.callId) continue;
    matches.add(ToolMatch(d, o, 'row-index'));
    usedD.add(d.slotKey);
    usedO.add(o.slotKey);
  }

  // Pass 3 — closed-interval fallback. Only for a segment whose turn is
  // ALREADY pinned by positive identity evidence: a shared real user row
  // id, or its own unique call/row-id hits. Two segments claiming one
  // turn cancel each other.
  final segPin = <int, int>{};
  for (final m in matches) {
    final p = segPin.putIfAbsent(m.other.turnIndex, () => m.durable.turnIndex);
    if (p != m.durable.turnIndex) segPin[m.other.turnIndex] = -1; // conflict
  }
  otherSegmentUserRows.forEach((seg, rowId) {
    final t = durableUserTurns[rowId];
    if (t == null) return;
    final p = segPin.putIfAbsent(seg, () => t);
    if (p != t) segPin[seg] = -1;
  });
  final turnOwners = <int, List<int>>{};
  segPin.forEach((seg, turn) {
    if (turn <= 0 && turn != 0) return;
    (turnOwners[turn] ??= []).add(seg);
  });
  final pinned = Map.of(segPin)..removeWhere((seg, turn) {
    if (turn < 0) return true;
    return (turnOwners[turn]?.length ?? 0) > 1;
  });

  final matchOfO = {for (final m in matches) m.other.slotKey: m};
  final matchOfD = {for (final m in matches) m.durable.slotKey: m};

  for (final entry in pinned.entries) {
    final seg = entry.key, turn = entry.value;
    final oa = other.where((r) => r.turnIndex == seg).toList()
      ..sort((x, y) => x.order.compareTo(y.order));
    final da = durable.where((r) => r.turnIndex == turn).toList()
      ..sort((x, y) => x.order.compareTo(y.order));
    if (oa.every((r) => matchOfO.containsKey(r.slotKey))) continue;
    // A turn member matched to a DIFFERENT segment breaks interval trust.
    if (da.any((r) {
      final m = matchOfD[r.slotKey];
      return m != null && m.other.turnIndex != seg;
    })) {
      continue;
    }
    _alignGaps(da, oa, matchOfD, matchOfO, usedD, usedO, matches);
  }
  return matches;
}

/// Walk two ordered lists with confirmed anchors as checkpoints; each
/// anchor-to-anchor residue must be a complete, one-to-one, order-aligned
/// name+arguments run with unique signatures. Anything less leaves both
/// sides fully rendered.
void _alignGaps(
  List<ToolRef> da,
  List<ToolRef> oa,
  Map<String, ToolMatch> matchOfD,
  Map<String, ToolMatch> matchOfO,
  Set<String> usedD,
  Set<String> usedO,
  List<ToolMatch> matches,
) {
  var i = 0, j = 0;
  while (i < da.length || j < oa.length) {
    final d = i < da.length ? da[i] : null;
    final o = j < oa.length ? oa[j] : null;
    final dPaired = d != null && matchOfD.containsKey(d.slotKey);
    final oPaired = o != null && matchOfO.containsKey(o.slotKey);
    if (dPaired && oPaired) {
      if (matchOfD[d.slotKey]!.other.slotKey == o.slotKey) {
        i++;
        j++;
        continue;
      }
      return; // anchors out of order — no ordinal guessing
    }
    if (dPaired || oPaired) return; // anchor misalignment — give up
    final dRun = <ToolRef>[];
    while (i < da.length && !matchOfD.containsKey(da[i].slotKey)) {
      dRun.add(da[i++]);
    }
    final oRun = <ToolRef>[];
    while (j < oa.length && !matchOfO.containsKey(oa[j].slotKey)) {
      oRun.add(oa[j++]);
    }
    if (dRun.length != oRun.length) continue; // missing segment: no pair
    if (dRun.isEmpty) continue;
    final sigs = dRun.map(_signatureOf).toList();
    if (sigs.toSet().length != sigs.length) continue; // repeated signature
    if (oRun.map(_signatureOf).toSet().length != oRun.length) continue;
    var ok = true;
    for (var k = 0; k < dRun.length; k++) {
      final d = dRun[k], o = oRun[k];
      if (d.name != o.name || d.name.isEmpty) {
        ok = false;
        break;
      }
      if (_known(d.arguments) != _known(o.arguments) ||
          (_known(d.arguments) && !toolArgsEqual(d.arguments!, o.arguments!))) {
        ok = false;
        break;
      }
      if (d.callId != null && o.callId != null && d.callId != o.callId) {
        ok = false;
        break;
      }
    }
    if (!ok) continue;
    for (var k = 0; k < dRun.length; k++) {
      final d = dRun[k], o = oRun[k];
      matches.add(ToolMatch(d, o, 'closed-interval'));
      usedD.add(d.slotKey);
      usedO.add(o.slotKey);
      matchOfD[d.slotKey] = matches.last;
      matchOfO[o.slotKey] = matches.last;
    }
  }
}

/// The presentation decision for one paired tool slot.
class ToolViewPayload {
  const ToolViewPayload({
    required this.name,
    this.arguments,
    this.result,
    required this.timestamp,
  });
  final String name;
  final String? arguments;
  final String? result;
  final double timestamp;
}

/// One build's shared overlap result. The durable side never disappears:
/// it either stands alone, or keeps its slot (identity/key/timestamp) with
/// a temporarily more detailed payload. Only the paired LIVE/TRANSCRIPT
/// representation is excluded — both sides can never drop out together.
class ToolOverlapProjection {
  const ToolOverlapProjection({
    required this.scope,
    this.durableOverrides = const {},
    this.transcriptExcluded = const {},
    this.liveToolsExcluded = const {},
    this.matches = const [],
  });
  factory ToolOverlapProjection.empty(String sessionId) =>
      ToolOverlapProjection(scope: toolSlotScope(sessionId));

  final String scope;
  final Map<String, ToolViewPayload> durableOverrides;
  final Set<String> transcriptExcluded;
  final Set<int> liveToolsExcluded;
  final List<ToolMatch> matches;
}

/// Compute BOTH sides from one snapshot; the same result object goes to
/// both views so neither can independently drop the same tool.
ToolOverlapProjection projectToolOverlap({
  required String sessionId,
  required List<Message> history,
  LiveTurn? live,
}) {
  final scope = toolSlotScope(sessionId);
  if (live == null) return ToolOverlapProjection.empty(sessionId);
  final transcript = live.transcript;
  final useTranscript = transcript != null && transcript.isNotEmpty;
  if (!useTranscript && live.tools.isEmpty) {
    return ToolOverlapProjection.empty(sessionId);
  }
  final durable = toolRefsFromRows(scope, history);
  if (durable.isEmpty) return ToolOverlapProjection.empty(sessionId);

  final List<ToolRef> other;
  final Map<int, String> segmentUserRows;
  final Map<String, int> userTurns;
  if (useTranscript) {
    other = toolRefsFromRows(scope, transcript);
    segmentUserRows = _segmentUserRows(transcript);
    if (other.isEmpty) return ToolOverlapProjection.empty(sessionId);
  } else {
    other = toolRefsFromLiveTools(scope, live.tools);
    segmentUserRows = const {};
  }
  userTurns = _durableUserTurns(history);

  final matches = matchToolIdentity(
    durable: durable,
    other: other,
    durableUserTurns: userTurns,
    otherSegmentUserRows: segmentUserRows,
  );

  final overrides = <String, ToolViewPayload>{};
  final transcriptExcluded = <String>{};
  final liveToolsExcluded = <int>{};
  for (final m in matches) {
    if (coversToolDetails(m.durable, m.other)) {
      // Durable stands (equal or fuller): stable position, result, time.
      if (m.other.liveIndex != null) {
        liveToolsExcluded.add(m.other.liveIndex!);
      } else {
        transcriptExcluded.add(m.other.slotKey);
      }
    } else if (coversToolDetails(m.other, m.durable)) {
      // The other representation is strictly fuller: it borrows the
      // durable slot (identity/key/timestamp) — nothing else changes.
      overrides[m.durable.slotKey] = ToolViewPayload(
        name: m.other.name.isNotEmpty ? m.other.name : m.durable.name,
        arguments: m.durable.isOrphanResult
            ? ((m.other.arguments != null && m.other.arguments!.isNotEmpty)
                ? m.other.arguments
                : null)
            : ((m.other.arguments != null && m.other.arguments!.isNotEmpty)
                ? m.other.arguments
                : (m.durable.arguments ?? '')),
        result: m.other.result,
        timestamp: m.durable.timestamp > 0
            ? m.durable.timestamp
            : m.other.timestamp,
      );
      if (m.other.liveIndex != null) {
        liveToolsExcluded.add(m.other.liveIndex!);
      } else {
        transcriptExcluded.add(m.other.slotKey);
      }
    }
    // Neither covers the other → BOTH stay. Identity unknown → never
    // compared. Either way no exclusion, no override.
  }
  return ToolOverlapProjection(
    scope: scope,
    durableOverrides: overrides,
    transcriptExcluded: transcriptExcluded,
    liveToolsExcluded: liveToolsExcluded,
    matches: matches,
  );
}

Map<String, int> _durableUserTurns(List<Message> rows) {
  final out = <String, int>{};
  final ambiguous = <String>{};
  var turn = 0;
  for (final m in rows) {
    if (!toolTurnBoundary(m)) continue;
    turn++;
    if (!m.isUserTurn || !_numericRowId.hasMatch(m.id)) continue;
    if (out.containsKey(m.id) || ambiguous.contains(m.id)) {
      ambiguous.add(m.id);
      out.remove(m.id);
    } else {
      out[m.id] = turn;
    }
  }
  return out;
}

Map<int, String> _segmentUserRows(List<Message> rows) {
  final out = <int, String>{};
  final ambiguous = <int>{};
  var turn = 0;
  for (final m in rows) {
    if (!toolTurnBoundary(m)) continue;
    turn++;
    if (!m.isUserTurn || !_numericRowId.hasMatch(m.id)) continue;
    if (out.containsKey(turn) || ambiguous.contains(turn)) {
      ambiguous.add(turn);
      out.remove(turn);
    } else {
      out[turn] = m.id;
    }
  }
  return out;
}
