import '../../l10n/ui_message.dart';

/// APPROVALPUSH R6: the cross-device approval inbox. One card per exact
/// request, keyed by (server, session, run, request_id); the server epoch
/// rides on the card so a stale generation can never resurrect it. SSE and
/// the GET snapshot are two VIEWS of the same entry — never two cards.
enum ApprovalPhase { pending, resolved }

class ApprovalRequest {
  ApprovalRequest({
    required this.serverUrl,
    required this.sessionId,
    required this.serverEpoch,
    required this.runId,
    required this.requestId,
    required this.createdAt,
    this.summary,
    this.command,
    this.description,
    this.choices = const [],
    this.expiresAt,
    this.deadlineEstimated = true,
  });

  final String serverUrl;
  final String sessionId;

  /// APPROVBUTTON X4 (§7.4): the gateway's epoch is an OPAQUE STRING (real
  /// deployments: hex like `8322a8641e79`). Equality is the ONLY epoch
  /// question — generations are never ordered numerically, and the raw
  /// value rides the exact-answer POST so the SERVER stale check stays
  /// real (an omitted epoch silently falls back to the server's current
  /// generation — that was the contract hole).
  String serverEpoch;
  final String runId;
  final String requestId;
  String? summary;
  String? command;
  String? description;
  List<String> choices;
  double createdAt;
  double? expiresAt;
  bool deadlineEstimated;

  /// The submittable policy tokens this client understands (R6) — the UI
  /// renders a button ONLY for these; the model guard (X2) uses the same
  /// list, so "legal choices" means one thing everywhere.
  static const actionableChoices = {'once', 'session', 'always', 'deny'};

  bool get hasActionableChoice => choices.any(actionableChoices.contains);

  bool busy = false;
  ApprovalPhase phase = ApprovalPhase.pending;
  String? outcome;
  String? choice;
  double? resolvedAt;
  UiMessage? error;

  /// The full identity tuple (R6) — display/debug key; map identity drops
  /// the epoch so a re-stamped event meets its existing card.
  String get key => '$serverUrl|$sessionId|$serverEpoch|$runId|$requestId';

  String get _mapKey => '$serverUrl|$sessionId|$runId|$requestId';

  bool expiredAt(double now) =>
      phase == ApprovalPhase.pending &&
      expiresAt != null &&
      now >= expiresAt!;

  /// Estimate only: the native deadline starts when notify RETURNS, so the
  /// UI must say "about". Null once spent — expiry is a question for the
  /// server, never a local auto-deny.
  int? remainingSeconds(double now) {
    final e = expiresAt;
    if (phase != ApprovalPhase.pending || e == null) return null;
    final r = (e - now).floor();
    return r > 0 ? r : null;
  }

  static Map<String, dynamic>? _asMap(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : null;

  static double? _asDouble(Object? v) => v == null
      ? null
      : (v is num ? v.toDouble() : double.tryParse(v.toString()));

  /// X4: opaque epoch reader — a String rides VERBATIM, anything else is
  /// stringified, absence is '' (never a numeric 0 that fabricates a
  /// generation).
  static String _epoch(Object? v) => switch (v) {
    null => '',
    final String s => s,
    final v => '$v',
  };

  void mergeEvent(Map data, {required double now}) {
    command = data['command']?.toString() ?? command;
    description = data['description']?.toString() ?? description;
    summary = data['summary']?.toString() ?? summary;
    final c = data['choices'];
    if (c is List) {
      final parsed = c.map((e) => e.toString()).toList(growable: false);
      // APPROVBUTTON X2 (§7.2): a replay whose choices carry NOTHING legal
      // (explicit empty list, all-unknown tokens) never erases choices that
      // were already populated — absence is not a policy answer, and the
      // client may not erase the server's own earlier statement.
      if (parsed.any(actionableChoices.contains) || !hasActionableChoice) {
        choices = parsed;
      }
    }
    createdAt = _asDouble(data['created_at']) ?? createdAt;
    expiresAt = _asDouble(data['expires_at']) ?? expiresAt;
    if (data['deadline_estimated'] != null) {
      deadlineEstimated = data['deadline_estimated'] == true;
    }
    // X4: epoch generations are handled by upsertEvent (equality only) —
    // a merge never restamps and never orders epochs.
  }

  static ApprovalRequest fromEvent(
    Map data, {
    required String serverUrl,
    required double now,
    String? epoch,
  }) {
    final created = _asDouble(data['created_at']) ?? now;
    return ApprovalRequest(
      serverUrl: serverUrl,
      sessionId: '${data['session_id'] ?? ''}',
      serverEpoch: epoch ?? _epoch(data['server_epoch']),
      runId: '${data['run_id'] ?? ''}',
      requestId: '${data['request_id']}',
      createdAt: created,
      command: data['command']?.toString(),
      description: data['description']?.toString(),
      summary: data['summary']?.toString(),
      choices: data['choices'] is List
          ? (data['choices'] as List)
                .map((e) => e.toString())
                .toList(growable: false)
          : const [],
      expiresAt: _asDouble(data['expires_at']),
      deadlineEstimated: data['deadline_estimated'] != false,
    );
  }
}

class ApprovalInbox {
  final _entries = <String, ApprovalRequest>{};
  final _unconfirmed = <String>{};

  /// How long a settled-elsewhere outcome stays visible before it retires.
  static const resolvedTtlSeconds = 6.0;

  int get count => _entries.length;

  bool isUnconfirmed(String runId) => _unconfirmed.contains(runId);
  void markConfirmed(String runId) => _unconfirmed.remove(runId);
  void markUnconfirmed(String runId) => _unconfirmed.add(runId);
  Set<String> get unconfirmedRuns => Set.unmodifiable(_unconfirmed);

  /// SSE view of a request. Returns the (possibly new-generation) entry, or
  /// null for a legacy event without a request_id (the old card path owns
  /// those). A duplicate never resets identity, timers, or settlement.
  /// X4: [epoch] (when a transport supplies it, e.g. the GET envelope)
  /// overrides the data field. Epoch decides generation by EQUALITY only:
  /// a moved generation retires the live card ('superseded' — it belongs
  /// to a dead generation and must never be answerable again), installs
  /// the new one, and flags the run unconfirmed so the repair loops
  /// re-read the truth. A settled card is never resurrected or restamped.
  ApprovalRequest? upsertEvent({
    required String serverUrl,
    required Map data,
    double? now,
    String? epoch,
  }) {
    final requestId = '${data['request_id'] ?? ''}';
    if (requestId.isEmpty) return null;
    final runId = '${data['run_id'] ?? ''}';
    final sessionId = '${data['session_id'] ?? ''}';
    final mapKey = '$serverUrl|$sessionId|$runId|$requestId';
    final incoming = epoch ?? ApprovalRequest._epoch(data['server_epoch']);
    final t = now ?? _wall();
    final existing = _entries[mapKey];
    if (existing != null) {
      final generationMoved =
          existing.serverEpoch.isNotEmpty &&
          incoming.isNotEmpty &&
          incoming != existing.serverEpoch;
      if (generationMoved) {
        if (existing.phase == ApprovalPhase.pending) {
          _settle(existing, t, outcome: 'superseded');
          final fresh = ApprovalRequest.fromEvent(
            data,
            serverUrl: serverUrl,
            now: t,
            epoch: incoming,
          );
          _entries[mapKey] = fresh;
          markUnconfirmed(fresh.runId);
          _flagUnknownChoices(fresh);
          return fresh;
        }
        return existing; // a foreign generation never touches a settled card
      }
      existing.mergeEvent(data, now: t);
      if (epoch != null &&
          incoming.isNotEmpty &&
          existing.phase == ApprovalPhase.pending) {
        existing.serverEpoch = incoming;
      }
      _flagUnknownChoices(existing);
      return existing;
    }
    final entry = ApprovalRequest.fromEvent(
      data,
      serverUrl: serverUrl,
      now: t,
      epoch: incoming,
    );
    _entries[mapKey] = entry;
    _flagUnknownChoices(entry);
    return entry;
  }

  /// APPROVBUTTON X2 (§7.2): a pending card that owns NO actionable choice
  /// is a STATE-UNKNOWN, not a "no options" card — the run is marked
  /// unconfirmed so the repair loops (status/activity poll → bounded
  /// re-GET) and the card's 「重新核對」 entry own it. A later
  /// available=true snapshot confirms the truth and clears the flag.
  void _flagUnknownChoices(ApprovalRequest e) {
    if (e.phase == ApprovalPhase.pending && !e.hasActionableChoice) {
      markUnconfirmed(e.runId);
    }
  }

  /// GET view of a run. available=true is the server's truth: pending rows
  /// upsert, vanished pendings reconcile away. available=false (unknown /
  /// queue error / overflow) NEVER claims "empty" — nothing is removed and
  /// the run is flagged unconfirmed until a good snapshot lands.
  void mergeSnapshot({
    required String serverUrl,
    required String runId,
    required Map snapshot,
    double? now,
  }) {
    final t = now ?? _wall();
    final epoch = ApprovalRequest._epoch(snapshot['server_epoch']);
    final available = snapshot['available'] != false;
    final rows = (snapshot['pending'] is List ? snapshot['pending'] as List : const [])
        .map(ApprovalRequest._asMap)
        .whereType<Map<String, dynamic>>()
        .toList();
    final snapSession = '${snapshot['session_id'] ?? ''}';
    final seen = <String>{};
    for (final row in rows) {
      final rid = '${row['request_id'] ?? ''}';
      if (rid.isEmpty) continue;
      seen.add(rid);
      upsertEvent(
        serverUrl: serverUrl,
        data: {
          ...row,
          'run_id': row['run_id'] ?? runId,
          'session_id': row['session_id'] ?? snapSession,
        },
        now: t,
        epoch: ApprovalRequest._epoch(row['server_epoch'] ?? snapshot['server_epoch']),
      );
    }
    if (!available) {
      markUnconfirmed(runId);
      return;
    }
    // APPROVBUTTON X2: only rows that all carry an actionable choice
    // CONFIRM the run. An available-but-illegal row stays UNCONFIRMED so
    // the bounded repair loop keeps trying — the client still may not
    // invent the server's policy (§7.2).
    final allLegal = rows.every(
      (row) =>
          row['choices'] is List &&
          (row['choices'] as List).any(
            (c) => ApprovalRequest.actionableChoices.contains('$c'),
          ),
    );
    if (rows.isEmpty || allLegal) {
      markConfirmed(runId);
    } else {
      markUnconfirmed(runId);
    }
    for (final e in _entries.values) {
      if (e.serverUrl != serverUrl || e.runId != runId) continue;
      if (e.phase != ApprovalPhase.pending) continue;
      if (!seen.contains(e.requestId)) {
        _settle(e, t, outcome: 'reconciled');
      }
    }
  }

  /// Exact-id settlement (R2): ONLY the named request leaves pending.
  ApprovalRequest? settle({
    required String runId,
    required String requestId,
    required String outcome,
    String? choice,
    double? now,
  }) {
    final e = find(runId: runId, requestId: requestId);
    if (e == null || e.phase != ApprovalPhase.pending) return e;
    e.choice = choice ?? e.choice;
    _settle(e, now ?? _wall(), outcome: outcome);
    return e;
  }

  /// A terminal run ends its whole inbox bucket (fail-closed, R9).
  int settleRun({
    required String serverUrl,
    required String runId,
    required String outcome,
    double? now,
  }) {
    var n = 0;
    final t = now ?? _wall();
    for (final e in _entries.values) {
      if (e.serverUrl == serverUrl &&
          e.runId == runId &&
          e.phase == ApprovalPhase.pending) {
        _settle(e, t, outcome: outcome);
        n++;
      }
    }
    return n;
  }

  ApprovalRequest? find({String? serverUrl, String? runId, String? requestId}) {
    for (final e in _entries.values) {
      if (serverUrl != null && e.serverUrl != serverUrl) continue;
      if (runId != null && e.runId != runId) continue;
      if (requestId != null && e.requestId != requestId) continue;
      return e;
    }
    return null;
  }

  List<ApprovalRequest> pendingFor({
    String? serverUrl,
    String? sessionId,
    String? runId,
  }) {
    final out = _entries.values.where((e) {
      if (e.phase != ApprovalPhase.pending) return false;
      if (serverUrl != null && e.serverUrl != serverUrl) return false;
      if (sessionId != null && e.sessionId != sessionId) return false;
      if (runId != null && e.runId != runId) return false;
      return true;
    }).toList();
    out.sort((a, b) => a.createdAt != b.createdAt
        ? a.createdAt.compareTo(b.createdAt)
        : a.requestId.compareTo(b.requestId));
    return out;
  }

  bool hasPendingForRun(String runId) =>
      _entries.values.any((e) =>
          e.phase == ApprovalPhase.pending && e.runId == runId);

  /// Whether an entry still owns a slot right now: pending, or a brief
  /// "handled elsewhere" receipt before it retires.
  static bool isVisible(ApprovalRequest e, double now) =>
      e.phase == ApprovalPhase.pending ||
      (e.outcome == 'answered_elsewhere' &&
          e.resolvedAt != null &&
          now - e.resolvedAt! < resolvedTtlSeconds);

  /// What the panel renders NOW (entries are dropped once unshowable).
  List<ApprovalRequest> visible(double now) {
    final out = <ApprovalRequest>[];
    final stale = <ApprovalRequest>[];
    for (final e in _entries.values.toList()) {
      if (isVisible(e, now)) {
        out.add(e);
      } else if (e.phase == ApprovalPhase.resolved &&
          e.resolvedAt != null &&
          now - e.resolvedAt! >= resolvedTtlSeconds) {
        stale.add(e);
      }
    }
    for (final e in stale) {
      _entries.remove(e._mapKey);
    }
    out.sort((a, b) => a.createdAt != b.createdAt
        ? a.createdAt.compareTo(b.createdAt)
        : a.requestId.compareTo(b.requestId));
    return out;
  }

  void _settle(ApprovalRequest e, double now, {required String outcome}) {
    e.phase = ApprovalPhase.resolved;
    e.outcome = outcome;
    e.resolvedAt = now;
    e.busy = false;
  }

  static double _wall() => DateTime.now().millisecondsSinceEpoch / 1000.0;
}
