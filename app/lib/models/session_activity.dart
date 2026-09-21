/// GET /api/sessions/{sid}/activity contract (WAVE4 plan §3.1/§3.3).
/// Strict parse: unknown schema version or malformed shape must throw, an
/// empty-but-valid payload means the gateway CONFIRMED zero active runs.
class ActivityUser {
  const ActivityUser({this.text, this.truncated = false, this.afterId});
  final String? text;
  final bool truncated;
  final int? afterId;

  static ActivityUser? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final text = raw['text'];
    return ActivityUser(
      text: text is String ? text : null,
      truncated: raw['truncated'] == true,
      afterId: (raw['after_id'] as num?)?.toInt(),
    );
  }
}

class ActivityRun {
  ActivityRun({
    required this.observationId,
    required this.runId,
    required this.status,
    required this.startedAt,
    required this.source,
    this.user,
    this.endedAt,
    this.reason,
  });
  final String observationId;
  final String? runId; // null = synthetic sync-chat observation
  final String status;
  final double startedAt;
  final String source;
  final ActivityUser? user;
  final double? endedAt;
  final String? reason;

  static const terminalStatuses = {'completed', 'failed', 'cancelled', 'interrupted'};
  static const liveStatuses = {'queued', 'running', 'waiting_for_approval', 'stopping'};

  bool get isTerminal => terminalStatuses.contains(status);
  bool get statusKnown => terminalStatuses.contains(status) || liveStatuses.contains(status);

  static ActivityRun fromJson(Map<String, dynamic> json) {
    final observationId = json['observation_id'];
    final status = json['status'];
    if (observationId is! String || observationId.isEmpty || status is! String) {
      throw const FormatException('activity run row malformed');
    }
    final startedAt = json['started_at'];
    return ActivityRun(
      observationId: observationId,
      runId: json['run_id'] is String ? json['run_id'] as String : null,
      status: status,
      startedAt: startedAt is num ? startedAt.toDouble() : 0,
      source: json['source'] is String ? json['source'] as String : 'run_status',
      user: ActivityUser.fromJson(json['user']),
      endedAt: json['ended_at'] is num ? (json['ended_at'] as num).toDouble() : null,
      reason: json['reason'] is String ? json['reason'] as String : null,
    );
  }
}

class HistoryRevision {
  const HistoryRevision(this.sessionId, this.count, this.latestId);
  final String sessionId;
  final int count;
  final int latestId;

  bool sameAs(HistoryRevision other) =>
      other.sessionId == sessionId && other.count == count && other.latestId == latestId;

  static HistoryRevision fromJson(Object? raw) {
    if (raw is! Map || raw['count'] is! num || raw['latest_id'] is! num) {
      throw const FormatException('activity history_revision malformed');
    }
    return HistoryRevision(
      raw['session_id'] is String ? raw['session_id'] as String : '',
      (raw['count'] as num).toInt(),
      (raw['latest_id'] as num).toInt(),
    );
  }
}

class SessionActivity {
  SessionActivity({
    required this.sessionId,
    required this.resolvedSessionId,
    required this.serverEpoch,
    required this.observedAt,
    required this.historyRevision,
    required this.activityRevision,
    required this.activeRuns,
    required this.recentTerminal,
    required this.overflow,
  });
  final String sessionId;
  final String resolvedSessionId;
  final String serverEpoch;
  final double observedAt;
  final HistoryRevision historyRevision;
  final int activityRevision;
  final List<ActivityRun> activeRuns;
  final List<ActivityRun> recentTerminal;
  final bool overflow;

  /// A confirmed-quiet snapshot (zero active runs) — the default fakes use.
  factory SessionActivity.quiet(String sid) => SessionActivity(
        sessionId: sid,
        resolvedSessionId: sid,
        serverEpoch: 'test-epoch',
        observedAt: 0,
        historyRevision: HistoryRevision(sid, 0, 0),
        activityRevision: 0,
        activeRuns: const [],
        recentTerminal: const [],
        overflow: false,
      );

  static SessionActivity fromJson(Map<String, dynamic> json) {
    if (json['object'] != 'hermes.session.activity' || json['schema_version'] != 1) {
      throw const FormatException('activity contract version unsupported');
    }
    final active = json['active_runs'];
    if (active is! List) throw const FormatException('activity active_runs malformed');
    return SessionActivity(
      sessionId: json['session_id'] is String ? json['session_id'] as String : '',
      resolvedSessionId:
          json['resolved_session_id'] is String ? json['resolved_session_id'] as String : '',
      serverEpoch: json['server_epoch'] is String ? json['server_epoch'] as String : '',
      observedAt: json['observed_at'] is num ? (json['observed_at'] as num).toDouble() : 0,
      historyRevision: HistoryRevision.fromJson(json['history_revision']),
      activityRevision: (json['activity_revision'] as num?)?.toInt() ?? 0,
      activeRuns: active
          .map((e) => ActivityRun.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      recentTerminal: (json['recent_terminal'] is List ? json['recent_terminal'] as List : const [])
          .map((e) => ActivityRun.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      overflow: json['overflow'] == true,
    );
  }
}

enum ActivityFreshness {
  /// No snapshot has ever succeeded this process (cold start) — state unknown.
  unknown,

  /// The server answered 404 for the endpoint: legacy gateway, no live view.
  unsupported,

  /// Latest snapshot succeeded and the periodic observation is running.
  fresh,

  /// A past snapshot exists but recent requests failed: last view may be old.
  stale,
}

/// Remote runs this page may show (everything except OUR OWN run id).
List<ActivityRun> remoteActive(List<ActivityRun> active, String? localRunId) => active
    .where((r) => !(localRunId != null && r.runId != null && r.runId == localRunId))
    .toList();
