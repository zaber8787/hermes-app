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

  /// What the page may show above the composer.
  ///
  /// A settled form leaves NO row once the user acted on it: the record of
  /// what was asked and answered lives in the turn itself (the clarify tool
  /// call), while a receipt parked above the composer reads as an unanswered
  /// backlog and just accumulates — zaber's「問完會留下一堆問問題的紀錄」.
  /// Replay safety is untouched: `_resolved` still remembers every settled
  /// id, so a reconnect cannot resurrect a question nobody is looking at.
  ///
  /// A form that ended with NO user action (`timed_out` / `undelivered`) is a
  /// different case — nobody saw it end — so the NEWEST such form keeps one
  /// receipt. Older ones never pile.
  List<ClarifyRequest> get visible {
    final shown = pending.toList();
    ClarifyRequest? attention;
    for (final entry in entries) {
      if (entry.pending) continue;
      final outcome = entry.outcome;
      if (outcome == 'timed_out' || outcome == 'undelivered') attention = entry;
    }
    if (attention != null) shown.add(attention);
    return shown;
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
