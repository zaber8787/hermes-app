/// STEERWEB R7: the notification events ledger, App side. The server ledger
/// is the SINGLE source of truth — this module is cursor math + exact-id
/// bookkeeping ONLY. Dedup is by EVENT ID, never by text; reads are per
/// account; a replayed GET must never re-offer a notification.
library;

import 'run_link.dart';

enum NotificationKind {
  approvalRequest,
  completed,
  failed,
  cancelled,
  interrupted,
  steerReady,
  unknown,
}

NotificationKind _kindOf(String raw) => switch (raw) {
  'approval_request' => NotificationKind.approvalRequest,
  'completed' => NotificationKind.completed,
  'failed' => NotificationKind.failed,
  'cancelled' => NotificationKind.cancelled,
  'interrupted' => NotificationKind.interrupted,
  'steer_ready' => NotificationKind.steerReady,
  _ => NotificationKind.unknown,
};

class NotificationEvent {
  const NotificationEvent({
    required this.eventId,
    required this.kind,
    required this.runId,
    required this.sessionId,
    required this.sourceId,
    required this.seq,
    required this.createdAt,
    required this.read,
  });

  final String eventId;
  final NotificationKind kind;
  final String runId;
  final String sessionId;
  final String sourceId;
  final int seq;
  final double createdAt;
  final bool read;

  /// The deep link the click (ntfy or panel) navigates — EXACTLY this
  /// event's identity, built from ids only, never containing a secret.
  RunLink get link => RunLink(
    sessionId: sessionId,
    runId: runId.isEmpty ? null : runId,
    eventId: eventId,
    requestId: kind == NotificationKind.approvalRequest ? sourceId : null,
  );

  factory NotificationEvent.fromJson(Map<String, dynamic> json) =>
      NotificationEvent(
        eventId: '${json['event_id'] ?? ''}',
        kind: _kindOf('${json['kind'] ?? ''}'),
        runId: '${json['run_id'] ?? ''}',
        sessionId: '${json['sid'] ?? json['session_id'] ?? ''}',
        sourceId: '${json['source_id'] ?? ''}',
        seq: (json['created_seq'] as num?)?.toInt() ?? 0,
        createdAt: (json['created_at'] as num?)?.toDouble() ?? 0,
        read: json['read_at'] != null,
      );
}

class NotificationPage {
  const NotificationPage({
    required this.items,
    required this.serverChannel,
    required this.nextCursor,
    required this.overflow,
  });
  final List<NotificationEvent> items;
  final String serverChannel; // 'ntfy' | 'browser'
  final int nextCursor;
  final bool overflow;

  factory NotificationPage.fromJson(Map<String, dynamic> json) =>
      NotificationPage(
        items: ((json['data'] as List?) ?? const [])
            .map((e) => NotificationEvent.fromJson(
                Map<String, dynamic>.from(e as Map)))
            .toList(),
        serverChannel: '${json['server_channel'] ?? ''}',
        nextCursor: (json['head_seq'] as num?)?.toInt() ?? 0,
        overflow: json['overflow'] == true,
      );
}

/// Pure cursor ledger: merge by EVENT ID (a replayed page adds nothing);
/// unread view is the honest UI list.
class NotificationLedger {
  NotificationLedger({this.cursor = 0});

  int cursor;
  final Map<String, NotificationEvent> _byId = {};

  bool get hasUnread => _byId.values.any((e) => !e.read);

  List<NotificationEvent> get unread {
    final out = _byId.values.where((e) => !e.read).toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    return List.unmodifiable(out);
  }

  int merge(NotificationPage page) {
    for (final e in page.items) {
      if (e.eventId.trim().isEmpty) continue;
      final prev = _byId[e.eventId];
      // exact-id dedup: a replay never resurrects a read event, and a read
      // answer always wins over an older unread glimpse.
      _byId[e.eventId] = prev != null && prev.read && !e.read ? prev : e;
    }
    if (page.nextCursor > cursor) cursor = page.nextCursor;
    return cursor;
  }

  void markRead(String eventId) {
    final e = _byId[eventId];
    if (e != null) _byId[eventId] = _copyRead(e);
  }

  static NotificationEvent _copyRead(NotificationEvent e) => NotificationEvent(
    eventId: e.eventId,
    kind: e.kind,
    runId: e.runId,
    sessionId: e.sessionId,
    sourceId: e.sourceId,
    seq: e.seq,
    createdAt: e.createdAt,
    read: true,
  );
}
