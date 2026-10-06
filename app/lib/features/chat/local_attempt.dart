import '../attachments/attachment.dart';

/// OFFLINE-SEND R2 §4.1: the minimal durable identity + draft-preservation
/// record of ONE local send attempt. Pure data: persistence lives in LocalStore's
/// per-attemptId journal keys (never one shared JSON list). The model
/// tolerates its own past: every optional field may be absent on disk,
/// and R2 conservatively defaults delivery to [AttemptDelivery.outcomeUnknown]
/// — nothing here may claim "not dispatched" without structured
/// before-dispatch evidence (that classification arrives in R3).
enum AttemptDisposition {
  /// The local waiting window is still in play.
  waiting,

  /// Locally ended (§4.2 tombstone). NOT a server terminal statement:
  /// the delivery outcome stays exactly as unknown as it was.
  abandoned,

  /// Resolved by real evidence (R3 territory; R2 never writes it).
  settled,
}

enum AttemptDelivery {
  /// Dispatch may or may not have happened — R2's only honest default.
  outcomeUnknown,

  /// Proven never dispatched (R3: requires structured before-dispatch
  /// evidence; absence of a runId is NEVER this value).
  notDispatched,

  acknowledged,
  rejected,
}

class LocalAttempt {
  /// Wire schema version. NOTE (API deviation, see report): Dart forbids a
  /// static member and an instance member sharing a name, so the contract's
  /// `final int schemaVersion` field is carried by this static const alone —
  /// `toJson()` writes it, `fromJson()` rejects anything else, and every
  /// persisted entry therefore has exactly this version.
  static const schemaVersion = 1;

  const LocalAttempt({
    required this.attemptId,
    required this.server,
    required this.sid,
    required this.createdAt,
    this.origin = 'human',
    this.rawDraft,
    this.preparedInput,
    this.attachmentSnapshots = const [],
    this.editorRevision = 0,
    this.disposition = AttemptDisposition.waiting,
    this.delivery = AttemptDelivery.outcomeUnknown,
    this.runId,
    this.historyAfterId,
    this.serverEpoch,
    this.recoveryStartedAt,
    this.recoveryDeadline,
    this.retryUsed = false,
    this.draftRestoredRevision,
    this.terminalEvidence,
  });

  /// Opaque 128-bit hex id (LocalStore.newAttemptId), independent of the
  /// ownerTab|turnId lease identity: a takeover or reload never changes it.
  final String attemptId;
  final String server;
  final String sid;
  final DateTime createdAt;
  final String origin;

  /// The draft VERBATIM (leading/trailing spaces, newlines, unicode).
  /// `null` = a migrated legacy record whose draft is genuinely unknown —
  /// never `''`, which would mean "the user typed nothing".
  final String? rawDraft;
  final String? preparedInput;
  final List<AttachmentDraft> attachmentSnapshots;
  final int editorRevision;
  final AttemptDisposition disposition;
  final AttemptDelivery delivery;
  final String? runId;
  final int? historyAfterId;
  final int? serverEpoch;
  final DateTime? recoveryStartedAt, recoveryDeadline;
  final bool retryUsed;
  final int? draftRestoredRevision;
  final Map<String, dynamic>? terminalEvidence;

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'attempt_id': attemptId,
    'server': server,
    'sid': sid,
    'created_at': createdAt.toIso8601String(),
    'origin': origin,
    'raw_draft': ?rawDraft,
    'prepared_input': ?preparedInput,
    'attachment_snapshots': [for (final a in attachmentSnapshots) a.toJson()],
    'editor_revision': editorRevision,
    'disposition': disposition.name,
    'delivery': delivery.name,
    'run_id': ?runId,
    'history_after_id': ?historyAfterId,
    'server_epoch': ?serverEpoch,
    'recovery_started_at': ?recoveryStartedAt?.toIso8601String(),
    'recovery_deadline': ?recoveryDeadline?.toIso8601String(),
    if (retryUsed) 'retry_used': true,
    'draft_restored_revision': ?draftRestoredRevision,
    'terminal_evidence': ?terminalEvidence,
  };

  /// Lenient by contract: unknown schema version or a malformed REQUIRED
  /// field yields null ("no such attempt"); missing optionals parse with
  /// their defaults; malformed attachment snapshots are skipped one by
  /// one. Never throws.
  static LocalAttempt? fromJson(Map<String, dynamic> json) {
    try {
      if (json['schema_version'] != schemaVersion) return null;
      final attemptId = json['attempt_id'];
      final server = json['server'];
      final sid = json['sid'];
      final createdAt = DateTime.tryParse(
        json['created_at'] is String ? json['created_at'] as String : '',
      );
      if (attemptId is! String || attemptId.isEmpty) return null;
      if (server is! String || sid is! String || createdAt == null) {
        return null;
      }
      final snapshots = <AttachmentDraft>[];
      final rawSnaps = json['attachment_snapshots'];
      if (rawSnaps is List) {
        for (final e in rawSnaps) {
          try {
            if (e is Map) {
              snapshots.add(
                AttachmentDraft.fromJson(Map<String, dynamic>.from(e)),
              );
            }
          } on Object {
            // One corrupt snapshot entry must not erase the whole journal
            // entry's identity — skip it, keep the attempt.
          }
        }
      }
      DateTime? when(String key) => DateTime.tryParse(
        json[key] is String ? json[key] as String : '',
      );
      int? num_(String key) => (json[key] as num?)?.toInt();
      return LocalAttempt(
        attemptId: attemptId,
        server: server,
        sid: sid,
        createdAt: createdAt,
        origin: json['origin'] is String ? json['origin'] as String : 'human',
        rawDraft: json['raw_draft'] is String ? json['raw_draft'] as String : null,
        preparedInput: json['prepared_input'] is String
            ? json['prepared_input'] as String
            : null,
        attachmentSnapshots: snapshots,
        editorRevision: num_('editor_revision') ?? 0,
        disposition: AttemptDisposition.values.firstWhere(
          (d) => d.name == json['disposition'],
          orElse: () => AttemptDisposition.waiting,
        ),
        delivery: AttemptDelivery.values.firstWhere(
          (d) => d.name == json['delivery'],
          orElse: () => AttemptDelivery.outcomeUnknown,
        ),
        runId: json['run_id'] is String ? json['run_id'] as String : null,
        historyAfterId: num_('history_after_id'),
        serverEpoch: num_('server_epoch'),
        recoveryStartedAt: when('recovery_started_at'),
        recoveryDeadline: when('recovery_deadline'),
        retryUsed: json['retry_used'] == true,
        draftRestoredRevision: num_('draft_restored_revision'),
        terminalEvidence: json['terminal_evidence'] is Map
            ? Map<String, dynamic>.from(json['terminal_evidence'] as Map)
            : null,
      );
    } on Object {
      return null; // malformed optional or foreign shape: read as none
    }
  }
}
