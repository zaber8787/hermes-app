/// STEERWEB R4: the pure cross-device steer target, classifier and outcome
/// vocabulary. Mirrors remote_stop.dart's identity discipline (plan §6): the
/// SAME generation/sid/epoch/observation/runId tuple, but steerable is NOT
/// stoppable — queued and stopping runs can stop yet must never steer, and
/// waiting_for_approval can steer yet is answered only via the exact
/// approval chain. Nothing here guesses from text or timestamps.
library;

import '../../l10n/message_key.dart';
import '../../l10n/ui_message.dart';
import '../../models/session_activity.dart';
import 'steer_inbox.dart';

String _short(String id) => id.length > 8 ? id.substring(0, 8) : id;

bool _idOk(String id) => id.trim().isNotEmpty;

class RemoteSteerTarget {
  const RemoteSteerTarget({
    required this.connectionGeneration,
    required this.accountGeneration,
    required this.requestedSessionId,
    required this.resolvedSessionId,
    required this.serverEpoch,
    required this.observationId,
    required this.runId,
  });

  final int connectionGeneration;
  final int accountGeneration;
  final String requestedSessionId;
  final String resolvedSessionId;
  final String serverEpoch;
  final String? observationId;
  final String runId;

  bool get isValid =>
      _idOk(requestedSessionId) &&
      _idOk(resolvedSessionId) &&
      _idOk(serverEpoch) &&
      _idOk(runId);

  bool sameIdentityAs(RemoteSteerTarget other) =>
      connectionGeneration == other.connectionGeneration &&
      accountGeneration == other.accountGeneration &&
      requestedSessionId == other.requestedSessionId &&
      resolvedSessionId == other.resolvedSessionId &&
      serverEpoch == other.serverEpoch &&
      observationId == other.observationId &&
      runId == other.runId;

  RemoteSteerTarget withIdentity({
    String? requestedSessionId,
    String? resolvedSessionId,
    String? serverEpoch,
    String? observationId,
    String? runId,
  }) => RemoteSteerTarget(
    connectionGeneration: connectionGeneration,
    accountGeneration: accountGeneration,
    requestedSessionId: requestedSessionId ?? this.requestedSessionId,
    resolvedSessionId: resolvedSessionId ?? this.resolvedSessionId,
    serverEpoch: serverEpoch ?? this.serverEpoch,
    observationId: observationId ?? this.observationId,
    runId: runId ?? this.runId,
  );

  @override
  String toString() =>
      'RemoteSteerTarget(gen:$connectionGeneration,'
      ' session:${_short(requestedSessionId)},'
      ' run:${_short(runId)})';
}

/// Why one activeRuns entry is or is not a steerable remote target (the
/// R2 decision table's client-side mirror; the SERVER's `accepting` stays
/// the final word at submit time).
enum RemoteRunSteerKind {
  steerable, // running
  approvalWait, // waiting_for_approval: durable-queued after approval
  queued, // not ready: never queued-into-the-next-turn here
  stopping,
  terminal,
  unknownStatus,
  noRunId,
  locallyRepresented,
  invalidIdentity,
}

RemoteRunSteerKind classifyRemoteSteer(
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
  if (lastActivitySuccess == null ||
      now.difference(lastActivitySuccess) > syncInterval) {
    return RemoteRunSteerKind.invalidIdentity;
  }
  if (!_idOk(requestedSessionId) ||
      snapshotSessionId != requestedSessionId ||
      !_idOk(resolvedSessionId) ||
      !_idOk(epoch)) {
    return RemoteRunSteerKind.invalidIdentity;
  }
  if (isLocallyRepresented) return RemoteRunSteerKind.locallyRepresented;
  if (entry.isTerminal) return RemoteRunSteerKind.terminal;
  final runId = entry.runId;
  if (runId == null || !_idOk(runId)) return RemoteRunSteerKind.noRunId;
  if (!entry.statusKnown) return RemoteRunSteerKind.unknownStatus;
  if (entry.status == 'running') return RemoteRunSteerKind.steerable;
  if (entry.status == 'waiting_for_approval') {
    return RemoteRunSteerKind.approvalWait;
  }
  if (entry.status == 'queued') return RemoteRunSteerKind.queued;
  if (entry.status == 'stopping') return RemoteRunSteerKind.stopping;
  return RemoteRunSteerKind.unknownStatus;
}

enum RemoteSteerBlock {
  none,
  unsupported,
  noSnapshot,
  stale,
  noSteerableTarget,
}

/// One chooser row: identity = source/status/SHORT id (never a preview as
/// identity); rows that cannot steer stay visible with the honest reason.
class RemoteSteerRow {
  const RemoteSteerRow({
    required this.label,
    required this.kind,
    required this.blockReason,
    this.target,
  });
  final String label;
  final RemoteRunSteerKind kind;
  final MessageKey? blockReason;
  final RemoteSteerTarget? target;
  bool get actionable => target != null;
}

String remoteSteerShortId(String runId) =>
    runId.length <= 6 ? runId : runId.substring(runId.length - 6);

List<RemoteSteerRow> buildRemoteSteerRows({
  required List<ActivityRun> entries,
  required List<RemoteSteerTarget> candidates,
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
        final kind = classifyRemoteSteer(
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
            '${e.status} · …${remoteSteerShortId(runId ?? e.observationId)}';
        final actionable =
            kind == RemoteRunSteerKind.steerable ||
            kind == RemoteRunSteerKind.approvalWait;
        return RemoteSteerRow(
          label: label,
          kind: kind,
          target: actionable ? targetFor[runId] : null,
          blockReason: actionable
              ? null
              : kind == RemoteRunSteerKind.noRunId
              ? MessageKey.chatStopRemoteNoRunId
              : kind == RemoteRunSteerKind.terminal
              ? MessageKey.steerNotDelivered
              : MessageKey.steerUnavailable,
        );
      }(),
  ];
}

/// One steer flight's outcome. An accepted receipt is durable admission —
/// NEVER "the model read it". Unknown network results keep the SAME
/// client_request_id for an idempotent retry; nothing may be re-sent as an
/// ordinary chat prompt (R10 offline-send red line).
enum RemoteSteerKind {
  accepted,
  duplicate,
  conflict,
  notReady,
  closed,
  staleTarget,
  queueFull,
  expired,
  unconfirmed,
  offline,
  failed,
}

class RemoteSteerOutcome {
  const RemoteSteerOutcome(this.kind, {this.receipt, this.message, this.error});
  final RemoteSteerKind kind;
  final SteerReceipt? receipt;
  final UiMessage? message;
  final Object? error;

  /// The durable ledger holds it; track receipts until settled.
  bool get tracked =>
      kind == RemoteSteerKind.accepted || kind == RemoteSteerKind.duplicate;

  @override
  String toString() => 'RemoteSteerOutcome(${kind.name})';
}

UiMessage remoteSteerMessage(RemoteSteerKind kind) =>
    UiMessage.local(switch (kind) {
      RemoteSteerKind.accepted => MessageKey.steerAccepted,
      RemoteSteerKind.duplicate => MessageKey.steerAccepted,
      RemoteSteerKind.conflict => MessageKey.steerConflict,
      RemoteSteerKind.notReady => MessageKey.steerUnavailable,
      RemoteSteerKind.closed => MessageKey.steerNotDelivered,
      RemoteSteerKind.staleTarget => MessageKey.steerUnavailable,
      RemoteSteerKind.queueFull => MessageKey.steerQueueFull,
      RemoteSteerKind.expired => MessageKey.steerExpired,
      RemoteSteerKind.unconfirmed => MessageKey.steerOutcomeUnknown,
      RemoteSteerKind.offline => MessageKey.steerOffline,
      RemoteSteerKind.failed => MessageKey.apiM027,
    });

/// Error-code mapping for the R2 REST surface (exact server codes only).
RemoteSteerKind steerKindForError(String code) => switch (code) {
  'steer_identity_conflict' => RemoteSteerKind.conflict,
  'run_not_ready' => RemoteSteerKind.notReady,
  'run_closed' => RemoteSteerKind.closed,
  'steer_stale_target' => RemoteSteerKind.staleTarget,
  'steer_epoch_stale' => RemoteSteerKind.staleTarget,
  'steer_queue_full' => RemoteSteerKind.queueFull,
  'steer_expired' => RemoteSteerKind.expired,
  _ => RemoteSteerKind.failed,
};

/// One receipt card row (R4): receipts never enter the ordinary message rows.
class SteerReceiptRow {
  const SteerReceiptRow({
    required this.receipt,
    required this.message,
    required this.retryable,
  });
  final SteerReceipt receipt;
  final UiMessage message;
  final bool retryable;
}

UiMessage steerStateMessage(SteerReceipt r) => switch (r.state) {
  SteerState.accepted => UiMessage.local(
    MessageKey.steerAccepted,
    args: {'sequence': r.sequence},
  ),
  SteerState.staged => UiMessage.local(
    MessageKey.steerStaged,
    args: {'sequence': r.sequence},
  ),
  SteerState.delivered => UiMessage.local(
    MessageKey.steerDelivered,
    args: {'sequence': r.sequence},
  ),
  SteerState.notDelivered => UiMessage.local(MessageKey.steerNotDelivered),
  SteerState.outcomeUnknown => UiMessage.local(MessageKey.steerOutcomeUnknown),
  SteerState.unknown => UiMessage.local(MessageKey.steerCheckReceipt),
};

/// Key-only view of the state wording (the panel resolves args itself).
MessageKey steerStateKey(SteerReceipt r) => switch (r.state) {
  SteerState.accepted => MessageKey.steerAccepted,
  SteerState.staged => MessageKey.steerStaged,
  SteerState.delivered => MessageKey.steerDelivered,
  SteerState.notDelivered => MessageKey.steerNotDelivered,
  SteerState.outcomeUnknown => MessageKey.steerOutcomeUnknown,
  SteerState.unknown => MessageKey.steerCheckReceipt,
};
