import 'package:flutter/material.dart';
import '../../models/message.dart';
import 'copy_actions.dart';
import 'live_turn.dart';
import 'message_content.dart';
import 'typing_dots.dart';

class MessageTimeline extends StatelessWidget {
  const MessageTimeline({
    super.key,
    required this.messages,
    required this.detailed,
    this.remoteRows = const [],
  });
  final List<Message> messages;
  final bool detailed;

  /// WAVE4: not-yet-durable remote user projections — rendered after the
  /// durable rows; never part of `messages` (offsets/fingerprints stay pure).
  final List<Message> remoteRows;
  @override
  Widget build(BuildContext context) {
    final entries = projectMessages([...messages, ...remoteRows]);
    if (detailed) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: entries.map((e) => EntryView(entry: e)).toList(),
      );
    }
    final widgets = <Widget>[];
    final details = <DisplayEntry>[];
    void flush() {
      if (details.isEmpty) return;
      final frozen = List<DisplayEntry>.of(details);
      final steps = frozen.where((e) => e.kind == EntryKind.tool).length;
      widgets.add(
        ExpansionTile(
          title: Text(steps > 0 ? '🔧 執行了 $steps 個步驟' : '執行資訊與系統事件'),
          children: frozen.map((e) => EntryView(entry: e)).toList(),
        ),
      );
      details.clear();
    }

    for (final e in entries) {
      if (e.kind == EntryKind.user || e.kind == EntryKind.finalReply) {
        flush();
        widgets.add(EntryView(entry: e));
      } else {
        details.add(e);
      }
    }
    flush();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: widgets,
    );
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
            child: Text(expanded ? '收合' : '展開完整內容'),
          ),
      ],
    );
  }
}

class EntryView extends StatelessWidget {
  const EntryView({super.key, required this.entry});
  final DisplayEntry entry;
  @override
  Widget build(BuildContext context) {
    final e = entry;
    final colors = Theme.of(context).colorScheme;
    final m = e.message;
    switch (e.kind) {
      case EntryKind.tool:
        return Card(
          child: ExpansionTile(
            leading: const Icon(Icons.terminal, size: 18),
            title: Text(e.call?.name ?? m.toolName ?? '工具'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.result == null ? '等待結果' : '工具結果'),
                MessageTime((e.result ?? m).timestamp),
              ],
            ),
            childrenPadding: const EdgeInsets.all(16),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (e.call != null)
                ExpansionTile(
                  title: const Text('參數'),
                  children: [FoldedText(e.call!.arguments)],
                ),
              if (e.result != null) FoldedText(e.result!.content),
            ],
          ),
        );
      case EntryKind.system:
        return Card(
          color: colors.surfaceContainerHighest,
          child: ExpansionTile(
            leading: const Icon(Icons.info_outline, size: 18),
            title: Text(e.label ?? '系統事件'),
            childrenPadding: const EdgeInsets.all(16),
            subtitle: MessageTime(m.timestamp),
            children: [FoldedText(m.content)],
          ),
        );
      case EntryKind.user:
        return Align(
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
                narration ? '執行旁白' : 'HERMES',
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
                  title: const Text('思考過程'),
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
    this.onResolve,
  });
  final LiveTurn turn;
  final bool detailed;
  final Future<void> Function(String choice)? onResolve;
  @override
  Widget build(BuildContext context) {
    if (turn.transcript != null && turn.transcript!.isNotEmpty) {
      return MessageTimeline(messages: turn.transcript!, detailed: detailed);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (turn.approval != null)
          ApprovalCard(turn: turn, onResolve: onResolve)
        else if (turn.approvalChoice != null && !turn.completed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              '已回覆審核：${approvalChoiceLabels[turn.approvalChoice] ?? turn.approvalChoice}',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (turn.tools.isNotEmpty)
          ExpansionTile(
            initiallyExpanded: detailed,
            title: Text('🔧 執行了 ${turn.tools.length} 個步驟'),
            children: turn.tools
                .map(
                  (tool) => ExpansionTile(
                    leading: Icon(
                      tool.completed
                          ? Icons.check_circle_outline
                          : Icons.hourglass_top,
                      size: 18,
                    ),
                    title: Text(tool.name),
                    children: [
                      ExpansionTile(
                        title: const Text('參數'),
                        children: [FoldedText(tool.arguments)],
                      ),
                      if (tool.result.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: FoldedText(tool.result),
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
                  turn.finalText == null ? '串流中 · 內容尚未確認' : 'HERMES',
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
            title: const Text('思考過程'),
            children: [FoldedText(turn.reasoning)],
          ),
        if (!turn.completed && turn.approval == null)
          const Padding(
            padding: EdgeInsets.all(12),
            child: TypingDots(),
          ),
      ],
    );
  }
}

const approvalChoiceLabels = {
  'once': '允許一次',
  'session': '本次對話都允許',
  'always': '一律允許',
  'deny': '拒絕',
};

/// Danger-command approval card: redacted target, why it was flagged, and the
/// choice buttons the server's flags allow (smart-DENY narrows to once/deny).
/// R4: without any run_id (pre-bridge event) it degrades to a display-only
/// notice — answering belongs to the CLI there, never a fake-local accept.
class ApprovalCard extends StatelessWidget {
  const ApprovalCard({super.key, required this.turn, this.onResolve});
  final LiveTurn turn;
  final Future<void> Function(String choice)? onResolve;

  static const _labels = approvalChoiceLabels;

  @override
  Widget build(BuildContext context) {
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
                    '需要你的核准',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: colors.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(data['description']?.toString() ?? '這個動作被標記為敏感操作',
                style: TextStyle(color: colors.onErrorContainer)),
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
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
            if (turn.approvalError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(turn.approvalError!,
                    style: TextStyle(color: colors.error, fontSize: 12)),
              ),
            const SizedBox(height: 12),
            if (turn.approvalRunId == null)
              Text(
                '此審核事件缺少 run_id，無法在此回覆；請改用 CLI 處理。',
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
                      child: Text(_labels[c] ?? c),
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
                child: Text('已回覆：${_labels[choice] ?? choice}',
                    style: TextStyle(
                        fontSize: 12, color: colors.onErrorContainer)),
              ),
          ],
        ),
      ),
    );
  }
}
