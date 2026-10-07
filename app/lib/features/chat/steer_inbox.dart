/// STEERWEB R2/R4: typed durable steer receipts (the ONLY steer vocabulary
/// the App trusts). States and ids arrive verbatim from the server ledger —
/// nothing here derives an order from timestamps or local guesses.
library;

enum SteerState {
  accepted,
  staged,
  delivered,
  notDelivered,
  outcomeUnknown,
  unknown,
}

SteerState _stateOf(String raw) => switch (raw) {
  'accepted' => SteerState.accepted,
  'staged' => SteerState.staged,
  'delivered' => SteerState.delivered,
  'not_delivered' => SteerState.notDelivered,
  'outcome_unknown' => SteerState.outcomeUnknown,
  _ => SteerState.unknown,
};

class SteerReceipt {
  const SteerReceipt({
    required this.steerId,
    required this.runId,
    required this.sequence,
    required this.state,
    required this.clientRequestId,
    this.batchId,
    this.rowId,
    this.error,
    this.serverEpoch,
  });

  final String steerId;
  final String runId;
  final int sequence;
  final SteerState state;
  final String clientRequestId;
  final String? batchId;
  final String? rowId;
  final String? error;
  final String? serverEpoch;

  /// Terminal for tracking purposes: nothing more will change on the server.
  bool get settled =>
      state == SteerState.delivered || state == SteerState.notDelivered;

  factory SteerReceipt.fromJson(Map<String, dynamic> json) => SteerReceipt(
    steerId: '${json['steer_id'] ?? ''}',
    runId: '${json['run_id'] ?? ''}',
    sequence: (json['sequence'] as num?)?.toInt() ?? 0,
    state: _stateOf('${json['state'] ?? ''}'),
    clientRequestId: '${json['client_request_id'] ?? ''}',
    batchId: json['batch_id'] is String ? json['batch_id'] as String : null,
    rowId: json['row_id'] is String ? json['row_id'] as String : null,
    error: json['error'] is String ? json['error'] as String : null,
    serverEpoch: json['server_epoch'] is String
        ? json['server_epoch'] as String
        : null,
  );
}

class SteerListing {
  const SteerListing({
    required this.accepting,
    required this.acceptingReason,
    required this.revision,
    required this.overflow,
    required this.serverEpoch,
    required this.items,
  });

  /// The SERVER decides whether steers are still accepted (R2) — the client
  /// never infers this from run-status snapshots alone.
  final bool accepting;
  final String acceptingReason;
  final int revision;
  final bool overflow;
  final String? serverEpoch;
  final List<SteerReceipt> items;

  factory SteerListing.fromJson(Map<String, dynamic> json) => SteerListing(
    accepting: json['accepting'] == true,
    acceptingReason: '${json['accepting_reason'] ?? ''}',
    revision: (json['revision'] as num?)?.toInt() ?? 0,
    overflow: json['overflow'] == true,
    serverEpoch: json['server_epoch'] is String
        ? json['server_epoch'] as String
        : null,
    items: ((json['steers'] as List?) ?? const [])
        .map((e) =>
            SteerReceipt.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
  );
}
