/// Session-scoped requests. Settled identities remain as replay tombstones and
/// compact receipts; a reconnect cannot resurrect an answered question.
class ClarifyQuestion {
  ClarifyQuestion(Map data)
    : qid = data['qid'] as String,
      question = data['question'] as String,
      choices = (data['choices'] as List?)?.cast<String>() ?? const [],
      multiSelect = data['multi_select'] == true;
  final String qid;
  final String question;
  final List<String> choices;
  final bool multiSelect;
  static bool isOther(String value) =>
      {'other', '其他'}.contains(value.trim().toLowerCase());
  List<String> get options => choices.where((c) =>
      c.trim().toLowerCase() != 'skip' && !isOther(c)).toList();
}

class ClarifyRequest {
  ClarifyRequest(Map data)
    : id = data['clarify_id'] as String,
      sessionId = data['session_id'] as String,
      questions = (data['questions'] as List)
          .map((q) => ClarifyQuestion(q as Map)).toList();
  final String id;
  final String sessionId;
  final List<ClarifyQuestion> questions;
  bool busy = false;
  String? outcome;
  Map<String, String>? answers;
  String? error;
  final invalidQids = <String>{};
  bool get pending => outcome == null;
}

class ClarifyInbox {
  final _entries = <String, ClarifyRequest>{};
  final _resolved = <String, Map>{};
  int revision = 0;
  List<ClarifyRequest> get entries => List.unmodifiable(_entries.values);
  List<ClarifyRequest> get pending => entries.where((e) => e.pending).toList();
  ClarifyRequest? find(String id) => _entries[id];

  void request(Map data) {
    final id = data['clarify_id'];
    if (id is! String || id.isEmpty) return;
    revision++;
    final entry = _entries.putIfAbsent(id, () => ClarifyRequest(data));
    final resolution = _resolved[id];
    if (resolution != null) _apply(entry, resolution);
  }

  void resolve(Map data) {
    final id = data['clarify_id'];
    if (id is! String) return;
    revision++;
    _resolved[id] = Map.of(data);
    final entry = _entries[id];
    if (entry != null) _apply(entry, data);
  }

  void _apply(ClarifyRequest entry, Map data) {
    entry.outcome = data['outcome'] as String;
    if (data['answers'] is Map) {
      entry.answers = Map<String, String>.from(data['answers'] as Map);
    }
    entry.busy = false;
    entry.error = null;
    entry.invalidQids.clear();
  }

  void mergeSnapshot(Map snapshot) {
    // Missing pending rows are settled with an unknown outcome. Only an
    // exact server event may claim answered or timed_out.
    final rows = snapshot['pending'] as List;
    final seen = {for (final row in rows) (row as Map)['clarify_id']};
    for (final row in rows) {
      request(row as Map);
    }
    for (final entry in pending) {
      if (!seen.contains(entry.id)) {
        resolve({
          'clarify_id': entry.id, 'outcome': 'reconciled', 'response': null,
        });
      }
    }
  }
}
