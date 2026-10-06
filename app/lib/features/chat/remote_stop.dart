/// CROSSDEV-STOP R1 (plan §3/§4): the immutable remote-stop target and the
/// PURE candidate classifier. No Flutter/widget imports, no clock guessing,
/// no text matching: every decision rides the explicit identity context the
/// controller passes in. Server ids are kept VERBATIM — a blank (empty or
/// whitespace-only) id is invalid, and a non-empty id is never trimmed into
/// another id. Nothing here may hold an API key, ever.
library;

import '../../l10n/message_key.dart';
import '../../l10n/ui_message.dart';
import '../../models/session_activity.dart';

String _short(String id) => id.length > 8 ? id.substring(0, 8) : id;

bool _idOk(String id) => id.trim().isNotEmpty;

/// One exactly-identified server run this page may ask to stop. Immutable:
/// a click must re-verify the SAME tuple (plan §3 rule 4) — conditions that
/// moved never retarget onto another run.
class RemoteStopTarget {
  const RemoteStopTarget({
    required this.connectionGeneration,
    required this.accountGeneration,
    required this.requestedSessionId,
    required this.resolvedSessionId,
    required this.serverEpoch,
    required this.observationId,
    required this.runId,
  });

  /// Bumped whenever the connection identity (server URL / API key) moves.
  final int connectionGeneration;

  /// This controller has no separate account rotation (one repo = one key):
  /// mirrors [connectionGeneration]. Kept as its own field so a future
  /// multi-account notion can rotate independently.
  final int accountGeneration;

  /// The session id this page requested (never inferred from previews).
  final String requestedSessionId;

  /// The server's resolved lineage id, verbatim; empty is invalid.
  final String resolvedSessionId;

  /// Opaque server epoch — kept verbatim, NEVER parsed as an int.
  final String serverEpoch;

  final String? observationId;

  /// The stoppable run's id, verbatim; blank is invalid.
  final String runId;

  /// Every identity part present and non-blank (blank never means
  /// "trim and try again" — it means INVALID).
  bool get isValid =>
      _idOk(requestedSessionId) &&
      _idOk(resolvedSessionId) &&
      _idOk(serverEpoch) &&
      _idOk(runId);

  /// Full-tuple equality: same target or a different world.
  bool sameIdentityAs(RemoteStopTarget other) =>
      connectionGeneration == other.connectionGeneration &&
      accountGeneration == other.accountGeneration &&
      requestedSessionId == other.requestedSessionId &&
      resolvedSessionId == other.resolvedSessionId &&
      serverEpoch == other.serverEpoch &&
      observationId == other.observationId &&
      runId == other.runId;

  /// Derivation with identity overrides (never a silent trim: a passed id is
  /// stored verbatim, `null` keeps the current value).
  RemoteStopTarget withIdentity({
    String? requestedSessionId,
    String? resolvedSessionId,
    String? serverEpoch,
    String? observationId,
    String? runId,
  }) => RemoteStopTarget(
    connectionGeneration: connectionGeneration,
    accountGeneration: accountGeneration,
    requestedSessionId: requestedSessionId ?? this.requestedSessionId,
    resolvedSessionId: resolvedSessionId ?? this.resolvedSessionId,
    serverEpoch: serverEpoch ?? this.serverEpoch,
    observationId: observationId ?? this.observationId,
    runId: runId ?? this.runId,
  );

  /// Log-safe by construction: shortened ids only — no keys, no previews.
  @override
  String toString() =>
      'RemoteStopTarget(gen:$connectionGeneration,'
      ' session:${_short(requestedSessionId)},'
      ' run:${_short(runId)})';
}

/// Why one activeRuns entry is or is not a stoppable remote target.
enum RemoteRunKind {
  stoppable,
  stopping, // show 「正在停止」 and reconcile — NOT a new-POST target
  terminal,
  unknownStatus,
  noRunId,
  locallyRepresented,
  invalidIdentity,
}

/// Remote-stop flight disposition (consumed by R2; defined now so the UI
/// vocabulary is fixed): none = idle, preflighting = post-click evidence
/// check, checking = POST landed, outcome unread, confirming = read-only
/// reconciliation, unconfirmed = bounded check expired, ended = terminal
/// seen, unavailable = 404/scope-hidden (never "killed by us").
enum RemoteStopPhaseState {
  none,
  preflighting,
  checking,
  confirming,
  unconfirmed,
  ended,
  unavailable,
}

/// Outcome of `refreshActivityForStopCheck()` (plan §4 bullet 3): the
/// click-path must tell "THIS refresh failed" apart from "the old snapshot
/// is still sitting there" — a pre-click flight's answer is never laundered
/// into this click's success.
enum ActivityRefreshResult {
  /// A request issued AFTER the call completed and its snapshot was applied.
  refreshed,

  /// A request issued after the call failed (typed [error] preserved).
  failed,

  /// The controller/session/connection moved before any post-call request
  /// could answer: this click has no evidence either way.
  staleContext,

  disposed,
}

class ActivityRefreshOutcome {
  const ActivityRefreshOutcome(this.result, {this.error});
  final ActivityRefreshResult result;
  final Object? error;
  bool get ok => result == ActivityRefreshResult.refreshed;

  @override
  String toString() => 'ActivityRefreshOutcome(${result.name})';
}

/// Why there is currently NO stoppable remote target — the honest UI
/// reason (plan §3: null runId / unknown status / stale / unsupported never
/// fake a stop affordance; null id points the user back to the originating
/// device, it is never guaranteed to be stoppable there either).
enum RemoteStopBlock {
  none,
  noSnapshot,
  unsupported,
  unknownState,
  stale,
  noStoppableTarget,
}

/// Pure §3 candidate rules for one activeRuns entry. NO time-window or text
/// guessing lives here: freshness arrives as the explicit clock pair
/// ([now], [lastActivitySuccess]) against [syncInterval], and the session
/// identity arrives as explicit strings. A snapshot whose evidence expired
/// or whose session/lineage/epoch identity is missing or mismatched proves
/// NOTHING: [RemoteRunKind.invalidIdentity].
RemoteRunKind classifyRemoteRun(
  ActivityRun entry, {
  required DateTime now,
  required DateTime? lastActivitySuccess,
  required Duration syncInterval,
  required String requestedSessionId,
  required String snapshotSessionId,
  required String resolvedSessionId,
  required String epoch,
  required bool isLocallyRepresented,
}) {
  // Rule 1: expired evidence authenticates nothing, whatever it shows.
  if (lastActivitySuccess == null ||
      now.difference(lastActivitySuccess) > syncInterval) {
    return RemoteRunKind.invalidIdentity;
  }
  // Rule 2: the snapshot must speak THIS session's identity — never a
  // preview/text/title guess. Empty resolved/epoch = incomplete identity.
  if (!_idOk(requestedSessionId) ||
      snapshotSessionId != requestedSessionId ||
      !_idOk(resolvedSessionId) ||
      !_idOk(epoch)) {
    return RemoteRunKind.invalidIdentity;
  }
  // Rule 3: this page's own run is settled locally, never remotely.
  if (isLocallyRepresented) return RemoteRunKind.locallyRepresented;
  if (entry.isTerminal) return RemoteRunKind.terminal;
  final runId = entry.runId;
  if (runId == null || !_idOk(runId)) return RemoteRunKind.noRunId;
  if (!entry.statusKnown) return RemoteRunKind.unknownStatus;
  if (entry.status == 'stopping') return RemoteRunKind.stopping;
  if (ActivityRun.isLiveStatus(entry.status)) return RemoteRunKind.stoppable;
  return RemoteRunKind.unknownStatus;
}

// ---- CROSSDEV-STOP R2 (plan §5.2/§5.3): outcome + chooser surfaces ---------
// Pure additions; every R1 type and rule above is untouched.

/// What one remote-stop flight ended with. Nothing here is a local
/// disposition: NO outcome may ever feed localWaitingEnded/restoreDraft or
/// write a StopRecord (§5.2) — [message] is the honest UI wording only.
enum RemoteStopKind {
  /// POST landed (200); the read-only observer reconciles the outcome.
  requested,

  /// POST answered 409 run_not_active: NOT a red error and NOT a confirmed
  /// stop — reconcile, never claim (§5.2 row 2).
  checkingConflict,

  /// Terminal proven for THIS target (status-confirmed or recentTerminal).
  ended,

  /// POST or status answered 404 — or the target vanished with NO terminal
  /// evidence: this target is unavailable (scope hiding shares the 404, so
  /// nothing may be claimed about why, and nothing may fake an end).
  /// Wording key: chatStopRemoteUnavailable (§5.2 row 3).
  alreadyGone,

  /// Evidence moved (epoch/resolved/session/connection) or the target
  /// disappeared: NO POST happened and NO retargeting follows (§5.1).
  targetChanged,

  /// The new preflight request itself failed: no evidence, so no POST (§5.1).
  preflightFailed,

  /// Bounded reconciliation expired or the request result is unknown
  /// (timeout/network/parse): never an auto-rePOST (§5.2).
  unconfirmed,

  /// An honest failure (401/403/other HTTP): visible ≠ stoppable (§7 V16).
  failed,
}

class RemoteStopOutcome {
  const RemoteStopOutcome(this.kind, {this.message, this.error});
  final RemoteStopKind kind;

  /// Catalog-backed wording for the UI (never a raw server string).
  final UiMessage? message;
  final Object? error;

  /// True when the target is being tracked toward an answer (§5.3: 409
  /// checking CONSUMES a /stop command without claiming anything).
  bool get requestedOrChecking =>
      kind == RemoteStopKind.requested ||
      kind == RemoteStopKind.checkingConflict;

  @override
  String toString() => 'RemoteStopOutcome(${kind.name})';
}

/// Catalog wording for the non-failure outcomes (§5.3: a plain failure
/// rides the existing generic stop-failure key with the error arg, which the
/// controller composes itself — that kind is absent here on purpose).
UiMessage remoteStopMessage(RemoteStopKind kind) => UiMessage.local(switch (
  kind) {
  RemoteStopKind.requested => MessageKey.chatStopRemoteRequested,
  RemoteStopKind.checkingConflict => MessageKey.chatStopRemoteChecking,
  RemoteStopKind.ended => MessageKey.chatStopRemoteEnded,
  RemoteStopKind.alreadyGone => MessageKey.chatStopRemoteUnavailable,
  RemoteStopKind.targetChanged => MessageKey.chatStopRemoteTargetChanged,
  RemoteStopKind.preflightFailed => MessageKey.chatStopRemoteRefreshRequired,
  RemoteStopKind.unconfirmed => MessageKey.chatStopRemoteUnconfirmed,
  RemoteStopKind.failed => MessageKey.chatStateM032,
});

/// One chooser row (plan §5.1): identity is the row's source/status/SHORT id
/// — NEVER a preview as identity. Rows that cannot be stopped stay VISIBLE
/// with a readable reason and no target; cancel has zero side effects.
class RemoteStopRow {
  const RemoteStopRow({
    required this.label,
    required this.kind,
    required this.blockReason,
    this.target,
  });
  final String label;
  final RemoteRunKind kind;

  /// null = actionable (kind == stoppable). Disabled rows carry the reason
  /// key verbatim (chatStopRemoteNoRunId for the null/empty-id entries).
  final MessageKey? blockReason;
  final RemoteStopTarget? target;

  bool get actionable => target != null;
}

/// Short display id: the LAST 6 characters (a leading/trailing space is part
/// of the id and never trimmed away first).
String remoteStopShortId(String runId) =>
    runId.length <= 6 ? runId : runId.substring(runId.length - 6);

/// Pure chooser-row derivation: candidates provide the targets, everything
/// else in [entries] gets the honest block wording.
List<RemoteStopRow> buildRemoteStopRows({
  required List<ActivityRun> entries,
  required List<RemoteStopTarget> candidates,
  required DateTime now,
  required DateTime? lastActivitySuccess,
  required Duration syncInterval,
  required String requestedSessionId,
  required String snapshotSessionId,
  required String resolvedSessionId,
  required String epoch,
  required bool Function(ActivityRun) isLocallyRepresented,
}) {
  final targetFor = {for (final t in candidates) t.runId: t};
  return [
    for (final e in entries)
      () {
        final kind = classifyRemoteRun(
          e,
          now: now,
          lastActivitySuccess: lastActivitySuccess,
          syncInterval: syncInterval,
          requestedSessionId: requestedSessionId,
          snapshotSessionId: snapshotSessionId,
          resolvedSessionId: resolvedSessionId,
          epoch: epoch,
          isLocallyRepresented: isLocallyRepresented(e),
        );
        final runId = e.runId;
        final label =
            '${e.source}: '
            '${e.status} · …${remoteStopShortId(runId ?? e.observationId)}';
        final target = kind == RemoteRunKind.stoppable
            ? targetFor[runId]
            : null;
        return RemoteStopRow(
          label: label,
          kind: kind,
          target: target,
          blockReason: switch (kind) {
            RemoteRunKind.stoppable => null,
            RemoteRunKind.noRunId => MessageKey.chatStopRemoteNoRunId,
            _ => MessageKey.chatStopRemoteRefreshRequired,
          },
        );
      }(),
  ];
}

