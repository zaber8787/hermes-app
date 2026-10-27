import 'package:flutter/material.dart';
import 'clarify_inbox.dart';

class ClarifyInboxView extends StatelessWidget {
  const ClarifyInboxView({super.key, required this.requests, required this.onAnswer});
  final List<ClarifyRequest> requests;
  final Future<void> Function(String id, Map<String, String> answers) onAnswer;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [for (final r in requests)
      _ClarifyCard(key: ValueKey('clarify-${r.id}'), request: r, onAnswer: onAnswer)],
  );
}

class _ClarifyCard extends StatefulWidget {
  const _ClarifyCard({super.key, required this.request, required this.onAnswer});
  final ClarifyRequest request;
  final Future<void> Function(String, Map<String, String>) onAnswer;
  @override
  State<_ClarifyCard> createState() => _ClarifyCardState();
}

class _ClarifyCardState extends State<_ClarifyCard> {
  final _texts = <String, TextEditingController>{};
  final _selected = <String, Set<String>>{};
  final _other = <String>{};
  TextEditingController _text(ClarifyQuestion q) =>
      _texts.putIfAbsent(q.qid, () => TextEditingController());
  String _answer(ClarifyQuestion q) {
    if (q.choices.isEmpty || _other.contains(q.qid)) {
      final value = _text(q).text;
      if (value.trim().isEmpty) return '';
      return q.choices.isEmpty || value == 'skip' ? value : 'other:$value';
    }
    return q.options.where((_selected[q.qid] ?? {}).contains).join(',');
  }
  @override
  void dispose() {
    for (final text in _texts.values) { text.dispose(); }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    if (!r.pending) {
      final status = switch (r.outcome) {
        'timed_out' => '已逾時',
        'cancelled' => '已取消',
        'answered' => '已答：${r.answers?.values.join('；') ?? ''}',
        _ => '已處理',
      };
      return Padding(padding: const EdgeInsets.all(12),
        child: Text('${r.questions.map((q) => q.question).join('；')} · $status', maxLines: 1, overflow: TextOverflow.ellipsis));
    }
    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
      margin: const EdgeInsets.all(12),
      child: Padding(padding: const EdgeInsets.all(16), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final q in r.questions) _question(context, r, q),
          FilledButton(
            onPressed: r.busy || r.questions.any((q) => _answer(q).isEmpty)
                ? null : () => widget.onAnswer(r.id,
                    {for (final q in r.questions) q.qid: _answer(q)}),
            child: const Text('送出')),
          if (r.busy) const Text('傳送中…'),
          if (r.error != null) Text(r.error!),
        ],
      )),
    );
  }

  Widget _question(BuildContext context, ClarifyRequest r, ClarifyQuestion q) {
    final selected = _selected.putIfAbsent(q.qid, () => <String>{});
    final textMode = q.choices.isEmpty || _other.contains(q.qid);
    final invalid = r.invalidQids.contains(q.qid);
    return Padding(
      key: ValueKey('question-${q.qid}'),
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(q.question, style: TextStyle(fontWeight: FontWeight.bold,
          color: invalid ? Theme.of(context).colorScheme.error : null)),
        if (!textMode) ...[
          for (final choice in q.options)
            if (q.multiSelect)
              CheckboxListTile(title: Text(choice), value: selected.contains(choice),
                onChanged: r.busy ? null : (value) => setState(() {
                  if (value == true) { selected.add(choice); } else { selected.remove(choice); }
                }))
            else
              ChoiceChip(label: Text(choice), selected: selected.contains(choice),
                onSelected: r.busy ? null : (_) => setState(() {
                  selected..clear()..add(choice);
                })),
          TextButton(onPressed: r.busy ? null : () => setState(() => _other.add(q.qid)),
            child: const Text('其他')),
        ],
        if (textMode) TextField(controller: _text(q), enabled: !r.busy,
          decoration: const InputDecoration(labelText: '輸入回答'),
          onChanged: (_) => setState(() {})),
        if (_other.contains(q.qid)) TextButton(
          onPressed: r.busy ? null : () => setState(() => _other.remove(q.qid)),
          child: const Text('返回選項')),
        if (invalid) Text('請選擇有效選項或填寫其他回答',
          key: ValueKey('clarify-error-${q.qid}'),
          style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ]),
    );
  }

}
