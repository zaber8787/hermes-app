import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SliverMultiBoxAdaptorParentData;
import '../../l10n/app_strings.dart';
import '../../l10n/localized_text.dart';
import '../../l10n/message_key.dart';
import '../../models/message.dart';
import 'chat_controller.dart' show RemoteHint, RemoteMessageRow;
import 'copy_actions.dart';
import 'live_turn.dart';
import 'message_content.dart';
import 'tool_timeline_projection.dart';
import 'turn_history_match.dart' show foldedTurnTextEquals;
import 'typing_dots.dart';

class MessageTimeline extends StatelessWidget {
  const MessageTimeline({
    super.key,
    required this.messages,
    required this.detailed,
    this.remoteRows = const [],
    this.wakeRowIds = const {},
    this.toolOverrides = const {},
    this.toolExclusions = const {},
    this.slotScope = '',
  });
  final List<Message> messages;
  final bool detailed;

  /// APPWAKE C: rows projected as "auto-read schedule report" system lines.
  /// Projection-only — the durable rows stay plain user anchors.
  final Set<String> wakeRowIds;

  /// WAVE4: not-yet-durable remote user projections — rendered after the
  /// durable rows; never part of `messages` (offsets/fingerprints stay pure).
  /// Raw Message + separate hint (§4.4): the note renders at the UI
  /// boundary, never inside durable content.
  final List<RemoteMessageRow> remoteRows;

  /// TOOLCARD-DUP: one build's shared tool-overlap result. Callers that
  /// render BOTH siblings of the same turn must pass the SAME object's
  /// halves — a tool representation may only disappear when the other
  /// side demonstrably represents the same call and covers its content.
  /// Default-empty keeps every existing call site byte-identical.
  final Map<String, ToolViewPayload> toolOverrides;
  final Set<String> toolExclusions;
  final String slotScope;
  @override
  Widget build(BuildContext context) {
    final hints = {for (final r in remoteRows) r.message.id: r.hint};
    var entries = projectMessages([
      ...messages,
      ...remoteRows.map((r) => r.message),
    ], wakeRowIds: wakeRowIds);
    if (toolExclusions.isNotEmpty) {
      entries = entries
          .where(
            (e) =>
                e.kind != EntryKind.tool ||
                !toolExclusions.contains(toolSlotKeyFor(e, slotScope)),
          )
          .toList();
    }
    final rows = _timelineRows(
      entries,
      hints: hints,
      detailed: detailed,
      toolOverrides: toolOverrides,
      slotScope: slotScope,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final row in rows) row.build(context, null)],
    );
  }
}

/// OPENPERF P1 (定案1): the projection flattened into stable ROWS so the
/// chat page can render it through a lazily-built sliver — one build
/// projects, but only viewport rows ever construct their EntryViews.
/// Grouping, tool-overlap exclusions and the §3.8 slot-key rules are
/// SHARED with the box form above; the sliver must never present a
/// different timeline than the Column does.
class TimelineRow {
  const TimelineRow({
    required this.keyValue,
    required this.build,
    this.isGroup = false,
    this.estimate = 120,
  });

  /// Stable mapping identity for the sliver delegate's child lookup
  /// (null = positional fallback, same rule as a duplicated tool slot).
  final Object? keyValue;
  final bool isGroup;

  /// Cheap height guess (px) used while the row is a placeholder — the
  /// sliver arithmetic (reveal targets, extent estimates) rides on it.
  final double estimate;

  /// Builds the row widget; [outerKey] is the delegate's mapping key
  /// (null in the box form — where tool rows keep their own slot keys).
  final Widget Function(BuildContext context, Key? outerKey) build;
}

/// OPENPERF P1: the page's current reveal target, published to the lazy
/// sliver. During the cold-open jump-to-bottom the delegate must NOT pay
/// full markdown layout for all 200 swept rows — rows far from the target
/// build as cheap estimated-height placeholders; only the window that the
/// refined jumps settle on becomes real.
class TimelineReveal {
  const TimelineReveal({
    required this.pixels,
    required this.viewport,
    required this.revision,
    this.focusIndex,
    this.realFrom,
  });
  final double pixels;
  final double viewport;
  final int revision;

  /// During an anchor restore the target row must be real even when its
  /// placeholder-scale estimate is outside the scroll window — the page
  /// pins its neighbourhood until the measured correction lands.
  final int? focusIndex;

  /// Cold-open bottom follow: every row at or above this index builds real
  /// content while the page streams its tail into existence (chunk by
  /// chunk, bottom up). Null = proximity rules only.
  final int? realFrom;
}

List<TimelineRow> _timelineRows(
  List<DisplayEntry> entries, {
  required Map<String, RemoteHint> hints,
  required bool detailed,
  required Map<String, ToolViewPayload> toolOverrides,
  required String slotScope,
}) {
  final seenKeys = <String>{};
  // One line of laid-out markdown ≈ 24px plus the bubble/time chrome;
  // deliberately rough — placeholder arithmetic only, real rows
  // self-correct.
  double estimateOf(DisplayEntry e) =>
      e.kind == EntryKind.tool ? 96.0 : 120.0 + e.message.content.length * 0.62;
  TimelineRow view(DisplayEntry e) {
    if (e.kind != EntryKind.tool) {
      final hint = hints[e.message.id] ?? RemoteHint.none;
      return TimelineRow(
        keyValue: 'entry:${e.kind}:${e.message.id}',
        estimate: estimateOf(e),
        build: (context, outerKey) =>
            EntryView(key: outerKey, entry: e, hint: hint),
      );
    }
    final key = toolSlotKeyFor(e, slotScope);
    final unique = seenKeys.add(key);
    final hint = hints[e.message.id] ?? RemoteHint.none;
    final toolOverride = toolOverrides[key];
    return TimelineRow(
      keyValue: unique ? key : null,
      estimate: 96.0,
      build: (context, outerKey) => EntryView(
        // Stable slot key (plan §3.8): expanding step 3 must survive a new
        // step arriving or the winning payload swapping sources. A
        // duplicated key would break the widget tree — fall back to
        // positional identity instead of crashing the page.
        key: unique ? ValueKey(key) : null,
        entry: e,
        hint: hint,
        toolOverride: toolOverride,
      ),
    );
  }

  if (detailed) return entries.map(view).toList();
  final rows = <TimelineRow>[];
  var details = <DisplayEntry>[];
  void flush() {
    if (details.isEmpty) return;
    final frozen = List<DisplayEntry>.of(details);
    details = [];
    rows.add(
      TimelineRow(
        keyValue: 'group:${frozen.first.message.id}',
        isGroup: true,
        estimate: 56.0,
        build: (context, outerKey) => Builder(
          // The title strings resolve at build; Builder keeps the closure
          // honest about needing a live BuildContext.
          builder: (context) {
            final steps = frozen.where((e) => e.kind == EntryKind.tool).length;
            return ExpansionTile(
              key: outerKey,
              title: Text(
                steps > 0
                    ? AppStrings.of(
                        context,
                      ).resolve(MessageKey.timelineM001, count: steps)
                    : AppStrings.of(context).resolve(MessageKey.timelineM002),
              ),
              children: [for (final e in frozen) view(e).build(context, null)],
            );
          },
        ),
      ),
    );
  }

  for (final e in entries) {
    if (e.kind == EntryKind.user || e.kind == EntryKind.finalReply) {
      flush();
      rows.add(view(e));
    } else {
      details.add(e);
    }
  }
  flush();
  return rows;
}

/// OPENPERF P1: the sliver form of [MessageTimeline] for the chat page's
/// scroll view. Identical projection, but rows materialize only near the
/// viewport (ListView.builder / SliverList semantics) instead of one eager
/// Column of every message in the page.
const int _lazyThreshold = 40;

class MessageTimelineSliver extends StatelessWidget {
  const MessageTimelineSliver({
    super.key,
    required this.messages,
    required this.detailed,
    this.remoteRows = const [],
    this.wakeRowIds = const {},
    this.toolOverrides = const {},
    this.toolExclusions = const {},
    this.slotScope = '',
    this.reveal,
  });
  final List<Message> messages;
  final bool detailed;
  final Set<String> wakeRowIds;
  final List<RemoteMessageRow> remoteRows;
  final Map<String, ToolViewPayload> toolOverrides;
  final Set<String> toolExclusions;
  final String slotScope;

  /// OPENPERF P1: the chat page's reveal target — with it the cold-open
  /// jump sweeps placeholders instead of full markdown rows. Null keeps
  /// every row real (probes, LiveTurn embeds, tests).
  final TimelineReveal? reveal;
  TimelineReveal? get _reveal => reveal;

  @override
  Widget build(BuildContext context) {
    final hints = {for (final r in remoteRows) r.message.id: r.hint};
    var entries = projectMessages([
      ...messages,
      ...remoteRows.map((r) => r.message),
    ], wakeRowIds: wakeRowIds);
    if (toolExclusions.isNotEmpty) {
      entries = entries
          .where(
            (e) =>
                e.kind != EntryKind.tool ||
                !toolExclusions.contains(toolSlotKeyFor(e, slotScope)),
          )
          .toList();
    }
    final rows = _timelineRows(
      entries,
      hints: hints,
      detailed: detailed,
      toolOverrides: toolOverrides,
      slotScope: slotScope,
    );
    // UNIFORM placeholder height = the rows' average estimate. Uniformity
    // is what makes the sliver's own cold-seek mapping (index × laid-out
    // average) land jumps on the right row; per-row estimates would make
    // the page non-uniform and degrade the seek to a sequential crawl.
    final estimateTotal = rows.fold<double>(
      0,
      (sum, row) => sum + row.estimate,
    );
    final averageExtent = rows.isEmpty ? 120.0 : estimateTotal / rows.length;
    final indexByKey = <Object, int>{
      for (var i = 0; i < rows.length; i++)
        if (rows[i].keyValue != null) rows[i].keyValue!: i,
    };
    return SliverList(
      // Keyed children + the child-index callback keep expansion state and
      // scroll anchoring across rebuilds, exactly where Column's keyed
      // children used to (a new page simply maps to new indices).
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final key = rows[index].keyValue;
          final rowKey = ValueKey(key ?? 'row#$index');
          final reveal = _reveal;
          if (reveal == null || rows.length <= _lazyThreshold) {
            return rows[index].build(context, rowKey);
          }
          return _LazyRow(
            key: rowKey,
            index: index,
            offset: index * averageExtent,
            extent: averageExtent,
            reveal: reveal,
            builder: rows[index].build,
          );
        },
        childCount: rows.length,
        findChildIndexCallback: (key) {
          var inner = key;
          while (inner is ValueKey<Object> && inner.value is Key) {
            inner = inner.value as Key;
          }
          return inner is ValueKey<Object> ? indexByKey[inner.value] : null;
        },
      ),
    );
  }
}

/// OPENPERF P1: placeholder row. Rows far from the viewport (or the reveal
/// jump's landing window) lay out as a uniform-average spacer; the row
/// realises when the viewport comes near. Uniform placeholder geometry
/// keeps the sliver's cold-seek mapping (index × average) self-consistent,
/// so the reveal jump lands on the right row before refining.
class _LazyRow extends StatefulWidget {
  const _LazyRow({
    super.key,
    required this.index,
    required this.offset,
    required this.extent,
    required this.reveal,
    required this.builder,
  });

  final int index;
  final double offset;
  final double extent;
  final TimelineReveal reveal;
  final Widget Function(BuildContext, Key?) builder;

  @override
  State<_LazyRow> createState() => _LazyRowState();
}

class _LazyRowState extends State<_LazyRow> {
  bool _real = false;
  ScrollPosition? _position;

  bool _near() {
    final reveal = widget.reveal;
    final focus = reveal.focusIndex;
    if (focus != null && (widget.index - focus).abs() <= 12) return true;
    final realFrom = reveal.realFrom;
    if (realFrom != null) {
      // Cold-open sweep: ONLY the real tail may materialise. A stray real
      // row in the middle poisons the sliver's laid-out-average mapping
      // and the sweep stalls on it.
      return widget.index >= realFrom;
    }
    final position = _position;
    final viewport = position == null
        ? reveal.viewport
        : position.viewportDimension;
    // Where this row's box is ACTUALLY laid out beats every estimate: the
    // sliver's own index→offset mapping (laid-out average, not our prefix
    // sums) decides which rows it places around the viewport — a row that
    // got laid out anywhere near the reader must go real, or the page
    // lands on a frozen placeholder band while the estimate-scale bottom
    // says it is done.
    final box = context.findRenderObject();
    final data = box is RenderBox ? box.parentData : null;
    if (position != null &&
        box is RenderBox &&
        data is SliverMultiBoxAdaptorParentData &&
        data.layoutOffset != null) {
      final top = data.layoutOffset!;
      return top < position.pixels + viewport * 2 &&
          top + box.size.height > position.pixels - viewport;
    }
    // Never laid out yet: judge in the placeholder estimate scale.
    final pixels = position == null
        ? reveal.pixels
        : position.pixels.clamp(0.0, position.maxScrollExtent);
    final window = viewport * 2;
    return widget.offset < pixels + viewport + window &&
        widget.offset + widget.extent > pixels - window;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (!identical(_position, position)) {
      _position?.removeListener(_onScroll);
      _position = position;
      _position?.addListener(_onScroll);
    }
  }

  @override
  void didUpdateWidget(_LazyRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_real && _near()) _real = true;
  }

  @override
  void dispose() {
    _position?.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    if (mounted && !_real && _near()) setState(() => _real = true);
  }

  @override
  Widget build(BuildContext context) {
    // Children created by a jump (or first layout) never receive a scroll
    // notification of their own — decide at build time as well.
    if (!_real && _near()) _real = true;
    if (_real) return widget.builder(context, widget.key);
    return SizedBox(height: widget.extent);
  }
}

class FoldedText extends StatefulWidget {
  const FoldedText(this.text, {super.key, this.limit = 2000});
  final String text;
  final int limit;
  @override
  State<FoldedText> createState() => _FoldedTextState();
}

class _FoldedTextState extends State<FoldedText> {
  bool expanded = false;
  @override
  Widget build(BuildContext context) {
    final long = widget.text.length > widget.limit;
    final strings = AppStrings.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          style: const TextStyle(fontFamily: 'monospace'),
          !long || expanded
              ? widget.text
              : '${widget.text.substring(0, widget.limit)}…',
        ),
        if (long)
          TextButton(
            onPressed: () => setState(() => expanded = !expanded),
            child: Text(
              strings.resolve(
                expanded ? MessageKey.timelineM003 : MessageKey.timelineM004,
              ),
            ),
          ),
      ],
    );
  }
}

class EntryView extends StatelessWidget {
  const EntryView({
    super.key,
    required this.entry,
    this.hint = RemoteHint.none,
    this.toolOverride,
  });
  final DisplayEntry entry;

  /// Remote-projection note rendered separately from raw content (§4.4).
  final RemoteHint hint;

  /// TOOLCARD-DUP: temporary view payload for a tool slot whose paired
  /// other-side representation strictly covers the stored one. Durable
  /// identity/key/timestamp stay — this only changes what the slot shows
  /// while the paired live/transcript copy is excluded elsewhere.
  final ToolViewPayload? toolOverride;
  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final e = entry;
    final colors = Theme.of(context).colorScheme;
    final m = e.message;
    switch (e.kind) {
      case EntryKind.tool:
        final p =
            toolOverride ??
            ToolViewPayload(
              name: e.call?.name ?? m.toolName ?? '',
              arguments: e.call?.arguments,
              result: e.result?.content,
              timestamp: (e.result ?? m).timestamp,
            );
        return Card(
          child: ExpansionTile(
            leading: const Icon(Icons.terminal, size: 18),
            title: Text(
              p.name.isNotEmpty
                  ? p.name
                  : strings.resolve(MessageKey.timelineM005),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  strings.resolve(
                    p.result == null
                        ? MessageKey.timelineM006
                        : MessageKey.timelineM007,
                  ),
                ),
                MessageTime(p.timestamp),
              ],
            ),
            childrenPadding: const EdgeInsets.all(16),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (p.arguments != null)
                ExpansionTile(
                  title: Text(strings.resolve(MessageKey.timelineArguments)),
                  children: [FoldedText(p.arguments!)],
                ),
              if (p.result != null) FoldedText(p.result!),
            ],
          ),
        );
      case EntryKind.system:
        return Card(
          color: colors.surfaceContainerHighest,
          child: ExpansionTile(
            leading: const Icon(Icons.info_outline, size: 18),
            title: Text(strings.resolve(DisplayEntry.labelKeyFor(m, e.label))),
            childrenPadding: const EdgeInsets.all(16),
            subtitle: MessageTime(m.timestamp),
            children: [FoldedText(m.content)],
          ),
        );
      case EntryKind.user:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 600),
                margin: const EdgeInsets.only(top: 20, bottom: 12, left: 36),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MessageContent(m.content),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        CopyMenuButton(text: m.content),
                        MessageTime(m.timestamp),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (hint != RemoteHint.none)
              Padding(
                // Localized note OUTSIDE the raw bubble: content bytes stay
                // what the server observed (plan §4.4).
                padding: const EdgeInsets.only(right: 4, bottom: 8),
                child: Text(
                  strings.resolve(
                    hint == RemoteHint.unconfirmed
                        ? MessageKey.chatRemoteUnconfirmed
                        : MessageKey.chatRemoteTruncated,
                  ),
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        );
      case EntryKind.finalReply:
      case EntryKind.narration:
        final narration = e.kind == EntryKind.narration;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                narration ? strings.resolve(MessageKey.timelineM008) : 'HERMES',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.2,
                  color: narration ? colors.onSurfaceVariant : colors.primary,
                ),
              ),
              const SizedBox(height: 8),
              if (m.content.isNotEmpty)
                if (narration)
                  SelectableText(
                    m.content,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      color: colors.onSurfaceVariant,
                    ),
                  )
                else
                  MessageContent(m.content),
              Row(
                children: [
                  if (!narration && m.content.isNotEmpty)
                    CopyMenuButton(text: m.content),
                  MessageTime(m.timestamp),
                ],
              ),
              if (m.reasoning.isNotEmpty)
                ExpansionTile(
                  title: Text(strings.resolve(MessageKey.timelineReasoning)),
                  children: [FoldedText(m.reasoning)],
                ),
            ],
          ),
        );
    }
  }
}

class LiveTurnView extends StatelessWidget {
  const LiveTurnView({
    super.key,
    required this.turn,
    required this.detailed,
    required this.showTyping,
    this.onResolve,
    this.transcriptUserAnchor,
    this.representedUserIds = const {},
    this.identityOnlyExclusion = false,
    this.toolProjection,
  });
  final LiveTurn turn;
  final bool detailed;

  /// OFFLINE-SEND R1 (A5): the caller's derived presentation state. Dots
  /// may only render for a genuinely-typing turn (sending, or recovery
  /// with fresh active evidence) — an uncertain/un-evidenced wait must
  /// never animate "typing" just because a LiveTurn object exists.
  final bool showTyping;
  final Future<void> Function(String choice)? onResolve;

  /// GHOST-DUP B4: presentation-only transcript boundary. A completed
  /// run.completed transcript may re-carry the CURRENT turn's user row;
  /// when the pending bubble or a durable history row already renders it,
  /// the transcript copy is dropped. Stored rows (user, assistant and
  /// tool alike) are never removed or reordered; per TOOLCARD-DUP the
  /// only transcript TOOL rows that stop rendering are ones a durable
  /// slot in this same build provably represents — presentation
  /// convergence, never a stored-row edit.
  final String? transcriptUserAnchor;
  final Set<String> representedUserIds;

  /// OFFLINE-SEND R3 §5.4: for an ATTEMPT-BACKED turn a transcript user row
  /// is dropped ONLY when its confirmed durable id is already rendered (or
  /// it was supplied by the run event itself). The same-text
  /// [transcriptUserAnchor] sweep is legacy-only: an identity-less preview
  /// stays visible as an unconfirmed summary — it must never erase (or be
  /// erased by) a row that may belong to a DIFFERENT attempt with the same
  /// text.
  final bool identityOnlyExclusion;

  /// TOOLCARD-DUP: the SAME build's shared overlap result the durable
  /// timeline received. Transcript tool rows and raw live tools that a
  /// durable slot already represents (identity + coverage proven) drop out
  /// HERE only — the stored rows and the live list are never touched.
  final ToolOverlapProjection? toolProjection;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    if (turn.transcript != null && turn.transcript!.isNotEmpty) {
      final anchor = transcriptUserAnchor?.trim();
      final rows = turn.transcript!.where((m) {
        if (!m.isUserTurn) return true;
        if (representedUserIds.contains(m.id)) return false;
        if (identityOnlyExclusion) return true;
        return !(anchor != null &&
            anchor.isNotEmpty &&
            foldedTurnTextEquals(m.content, anchor));
      }).toList();
      // The non-empty-transcript branch NEVER falls through to turn.tools,
      // even when every transcript tool entry is excluded below (a
      // re-materialized raw list would resurrect the second card).
      return MessageTimeline(
        messages: rows,
        detailed: detailed,
        toolExclusions: toolProjection?.transcriptExcluded ?? const {},
        slotScope: toolProjection?.scope ?? '',
      );
    }
    final excludedLive = toolProjection?.liveToolsExcluded ?? const <int>{};
    final shownTools = [
      for (var i = 0; i < turn.tools.length; i++)
        if (!excludedLive.contains(i)) i,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (turn.approval != null)
          ApprovalCard(turn: turn, onResolve: onResolve)
        else if (turn.approvalChoice != null && !turn.completed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              // Server-origin unknown choices stay RAW; known kinds map to
              // catalog keys.
              strings.resolve(
                MessageKey.timelineM009,
                args: {
                  'choice': _approvalChoiceLabel(strings, turn.approvalChoice!),
                },
              ),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (shownTools.isNotEmpty)
          ExpansionTile(
            initiallyExpanded: detailed,
            title: Text(
              strings.resolve(
                MessageKey.timelineM010,
                count: shownTools.length,
              ),
            ),
            children: shownTools
                .map(
                  (i) => ExpansionTile(
                    // Unmatched live steps key off the turn instance +
                    // ORIGINAL index (plan §3.8): a filtered view must
                    // never shift one step's expansion state onto another.
                    key: ValueKey('live:${identityHashCode(turn)}#$i'),
                    leading: Icon(
                      turn.tools[i].completed
                          ? Icons.check_circle_outline
                          : Icons.hourglass_top,
                      size: 18,
                    ),
                    title: Text(turn.tools[i].name),
                    children: [
                      ExpansionTile(
                        title: Text(
                          strings.resolve(MessageKey.timelineArguments),
                        ),
                        children: [FoldedText(turn.tools[i].arguments)],
                      ),
                      if (turn.tools[i].result.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: FoldedText(turn.tools[i].result),
                        ),
                    ],
                  ),
                )
                .toList(),
          ),
        if (turn.delta.isNotEmpty || turn.finalText != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  turn.finalText == null
                      ? strings.resolve(MessageKey.timelineM011)
                      : 'HERMES',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 8),
                MessageContent(turn.finalText ?? turn.delta),
              ],
            ),
          ),
        if (detailed && turn.reasoning.isNotEmpty)
          ExpansionTile(
            title: Text(strings.resolve(MessageKey.timelineReasoning)),
            children: [FoldedText(turn.reasoning)],
          ),
        if (!turn.completed && turn.approval == null && showTyping)
          const Padding(padding: EdgeInsets.all(12), child: TypingDots()),
      ],
    );
  }
}

/// Approval choices: catalog keys for the closed wire vocabulary (§5 —
/// the wire tokens `once/session/always/deny` themselves never change).
/// Unknown server-origin choices stay RAW.
const approvalChoiceKeys = <String, MessageKey>{
  'once': MessageKey.approvalOnce,
  'session': MessageKey.approvalSession,
  'always': MessageKey.approvalAlways,
  'deny': MessageKey.approvalDeny,
};

String _approvalChoiceLabel(AppStrings strings, String choice) =>
    approvalChoiceKeys[choice] == null
    ? choice
    : strings.resolve(approvalChoiceKeys[choice]!);

/// Danger-command approval card: redacted target, why it was flagged, and the
/// choice buttons the server's flags allow (smart-DENY narrows to once/deny).
/// R4: without any run_id (pre-bridge event) it degrades to a display-only
/// notice — answering belongs to the CLI there, never a fake-local accept.
class ApprovalCard extends StatelessWidget {
  const ApprovalCard({super.key, required this.turn, this.onResolve});
  final LiveTurn turn;
  final Future<void> Function(String choice)? onResolve;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final data = turn.approval!;
    final colors = Theme.of(context).colorScheme;
    final busy = turn.approvalBusy;
    final choice = turn.approvalChoice;
    return Card(
      color: colors.errorContainer,
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: colors.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    strings.resolve(MessageKey.timelineM012),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: colors.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Server description stays raw bytes; only the fallback is local.
            Text(
              data['description']?.toString() ??
                  strings.resolve(MessageKey.timelineM013),
              style: TextStyle(color: colors.onErrorContainer),
            ),
            if (data['command']?.toString().isNotEmpty == true) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  data['command'].toString(),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
            if (turn.approvalError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: LocalizedText(
                  turn.approvalError!,
                  style: TextStyle(color: colors.error, fontSize: 12),
                ),
              ),
            const SizedBox(height: 12),
            if (turn.approvalRunId == null)
              Text(
                strings.resolve(MessageKey.timelineM014),
                style: TextStyle(fontSize: 12, color: colors.onErrorContainer),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in turn.approvalChoices)
                    FilledButton.tonal(
                      onPressed: busy || choice != null
                          ? null
                          : () => onResolve?.call(c),
                      style: c == 'deny'
                          ? FilledButton.styleFrom(
                              backgroundColor: colors.errorContainer,
                              foregroundColor: colors.onErrorContainer,
                              side: BorderSide(color: colors.error),
                            )
                          : null,
                      child: Text(_approvalChoiceLabel(strings, c)),
                    ),
                ],
              ),
            if (busy)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (choice != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  strings.resolve(
                    MessageKey.timelineM015,
                    args: {'choice': _approvalChoiceLabel(strings, choice)},
                  ),
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onErrorContainer,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
