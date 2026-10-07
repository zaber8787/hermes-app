import 'dart:convert';

import '../l10n/message_key.dart';

typedef Json = Map<String, dynamic>;

String textOf(dynamic value) => value == null
    ? ''
    : value is String
    ? value
    : jsonEncode(value);

class ToolCall {
  const ToolCall(this.id, this.name, this.arguments);
  final String id;
  final String name;
  final String arguments;
  factory ToolCall.fromJson(Json json) {
    final function = (json['function'] as Map?) ?? json;
    return ToolCall(
      textOf(json['id'] ?? json['call_id']),
      textOf(function['name']),
      textOf(function['arguments']),
    );
  }
}

class Message {
  const Message({
    required this.id,
    required this.role,
    this.content = '',
    this.displayKind,
    this.toolCalls = const [],
    this.toolCallId,
    this.toolName,
    this.reasoning = '',
    this.timestamp = 0,
    this.cronProvenance,
    this.steerProvenance,
  });
  final String id;
  final String role;
  final String content;
  final String? displayKind;
  final List<ToolCall> toolCalls;
  final String? toolCallId;
  final String? toolName;
  final String reasoning;
  final double timestamp;

  /// APPWAKE A: the server-verified minimal cron identity, present only on
  /// rows the bridge accepted (display_metadata.hermes_app_cron). Text or
  /// display_kind alone never proves provenance — absence means "not a
  /// candidate", never "an unverified candidate".
  final CronProvenance? cronProvenance;

  /// STEERWEB R6: the server-verified steer batch identity, present ONLY on
  /// rows whose whitelisted steer_provenance the compat projection validated.
  /// Text equality NEVER substitutes for this identity (R4: receipts retire
  /// only against an exact batch id).
  final SteerProvenance? steerProvenance;

  factory Message.fromJson(Json json, {String? fallbackId}) => Message(
    id: textOf(json['id'] ?? fallbackId),
    role: textOf(json['role']),
    content: textOf(json['content']),
    displayKind: json['display_kind'] as String?,
    toolCalls: (json['tool_calls'] as List? ?? [])
        .map((e) => ToolCall.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    toolCallId: json['tool_call_id'] as String?,
    toolName: json['tool_name'] as String?,
    reasoning: textOf(json['reasoning'] ?? json['reasoning_content']),
    timestamp: (json['timestamp'] as num?)?.toDouble() ?? 0,
    cronProvenance: CronProvenance.tryParse(json['cron_provenance']),
    steerProvenance: SteerProvenance.tryParse(json['steer_provenance']),
  );

  bool get isUserTurn => role == 'user' && displayKind == null;
}

/// APPWAKE A minimal provenance contract: the server emits this ONLY for
/// rows it validated as cron-bridge reports, exposing just the verified
/// identity — never raw display_metadata. Client code must treat any
/// malformed/missing block as "no provenance", never partially trust it.
class CronProvenance {
  const CronProvenance({
    required this.schema,
    required this.jobId,
    required this.executionId,
    required this.deliveryKey,
  });
  final int schema;
  final String jobId;
  final String executionId;
  final String deliveryKey;

  static CronProvenance? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final jobId = raw['job_id'];
    final executionId = raw['execution_id'];
    final deliveryKey = raw['delivery_key'];
    if (jobId is! String ||
        jobId.trim().isEmpty ||
        executionId is! String ||
        executionId.trim().isEmpty ||
        deliveryKey is! String ||
        !_hex64.hasMatch(deliveryKey)) {
      return null;
    }
    if (raw['schema'] != 1) return null;
    return CronProvenance(
      schema: 1,
      jobId: jobId.trim(),
      executionId: executionId.trim(),
      deliveryKey: deliveryKey.toLowerCase(),
    );
  }
}

final _hex64 = RegExp(r'^[0-9a-f]{64}$');

/// Contract §3: non-null kinds use a closed rendering whitelist; unknown kinds
/// remain collapsed system events. Storage itself is NOT a closed enum.
/// The VALUE is a catalog key (I18N-PLAN §4.4) — labels resolve at render
/// time, never as a stored translation. The KEY set is the unchanged
/// allowed-kind whitelist.
const systemLabels = <String, MessageKey>{
  'async_delegation_complete': MessageKey.systemM001,
  'auto_continue': MessageKey.systemM002,
  'internal_notification': MessageKey.systemM003,
  'model_switch': MessageKey.systemM004,
  'personality_switch': MessageKey.systemM005,
  'skill_invocation': MessageKey.systemM006,
  'steer': MessageKey.chatSteer,
};

enum EntryKind { user, finalReply, narration, tool, system }

class DisplayEntry {
  const DisplayEntry(
    this.kind,
    this.message, {
    this.call,
    this.result,
    this.label,
  });
  final EntryKind kind;
  final Message message;
  final ToolCall? call;
  final Message? result;

  /// APPWAKE C: a projection-only override for rows rendered as system
  /// events WITHOUT a display kind (wake rows stay role=user, displayKind
  /// null so the user-turn anchor boundary is untouched).
  final MessageKey? label;

  /// Catalog key for collapsed system-event chips (I18N-PLAN §4.4): derived
  /// from the raw display kind at render time, never a stored translation.
  static MessageKey labelKeyFor(Message m, [MessageKey? override]) =>
      override ?? systemLabels[m.displayKind] ?? MessageKey.systemGeneric;
}

/// Contract §3–4. A turn's final is its LAST contentful, tool-free assistant.
/// A tool-calling assistant may contribute BOTH narration and tool cards.
/// APPWAKE C: [wakeRowIds] renders those rows as system events at the UI
/// projection ONLY — the turn/final computation keeps seeing them as the
/// plain user anchors they are, and storage is never rewritten.
List<DisplayEntry> projectMessages(
  List<Message> messages, {
  Set<String> wakeRowIds = const {},
}) {
  final visible = messages.where((m) => m.displayKind != 'hidden').toList();
  final finals = <String>{};
  Message? candidate;
  for (final m in visible) {
    if (m.isUserTurn) {
      if (candidate != null) finals.add(candidate.id);
      candidate = null;
    }
    if (m.displayKind == null &&
        m.role == 'assistant' &&
        m.content.isNotEmpty &&
        m.toolCalls.isEmpty) {
      candidate = m;
    }
  }
  if (candidate != null) finals.add(candidate.id);
  final results = <String, Message>{
    for (final m in visible)
      if (m.role == 'tool' && m.displayKind == null && m.toolCallId != null)
        m.toolCallId!: m,
  };
  final paired = <String>{};
  for (final m in visible) {
    if (m.displayKind == null) paired.addAll(m.toolCalls.map((c) => c.id));
  }
  final entries = <DisplayEntry>[];
  for (final m in visible) {
    if (m.displayKind != null || m.role == 'system') {
      entries.add(DisplayEntry(EntryKind.system, m));
    } else if (m.role == 'user') {
      entries.add(
        wakeRowIds.contains(m.id)
            ? DisplayEntry(
                EntryKind.system,
                m,
                label: MessageKey.systemWakeRead,
              )
            : DisplayEntry(EntryKind.user, m),
      );
    } else if (m.role == 'assistant') {
      if (m.content.isNotEmpty || m.reasoning.isNotEmpty) {
        entries.add(
          DisplayEntry(
            finals.contains(m.id) ? EntryKind.finalReply : EntryKind.narration,
            m,
          ),
        );
      }
      for (final call in m.toolCalls) {
        entries.add(
          DisplayEntry(EntryKind.tool, m, call: call, result: results[call.id]),
        );
      }
    } else if (m.role == 'tool' && !paired.contains(m.toolCallId)) {
      entries.add(DisplayEntry(EntryKind.tool, m, result: m));
    }
  }
  return entries;
}

/// Contract §2: pages are chronological inside each latest/oldest page.
/// IDs, not body text, identify messages; overlapping pages replace stale rows.
List<Message> mergeMessages(Iterable<Message> old, Iterable<Message> incoming) {
  final map = {for (final m in old) m.id: m};
  for (final m in incoming) {
    map[m.id] = m;
  }
  return map.values.toList()..sort((a, b) {
    final ai = int.tryParse(a.id), bi = int.tryParse(b.id);
    if (ai != null && bi != null) return ai.compareTo(bi);
    final byTime = a.timestamp.compareTo(b.timestamp);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  });
}

/// STEERWEB R6 typed steer provenance: schema-1, server-minted identity only
/// (run/batch/exact items). Malformed or partial blocks parse to ABSENT —
/// never to a partially trusted value.
class SteerProvenance {
  const SteerProvenance({
    required this.runId,
    required this.batchId,
    required this.items,
  });
  final String runId;
  final String batchId;
  final List<SteerProvenanceItem> items;

  static SteerProvenance? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    if (raw['schema'] != 1) return null;
    final batchId = raw['batch_id'];
    if (batchId is! String || batchId.trim().isEmpty) return null;
    final runId = raw['run_id'];
    final list = raw['items'];
    if (list is! List || list.isEmpty) return null;
    final items = <SteerProvenanceItem>[];
    for (final e in list) {
      if (e is! Map) return null;
      final steerId = e['steer_id'];
      final input = e['input'];
      final sequence = e['sequence'];
      if (steerId is! String || steerId.trim().isEmpty) return null;
      if (input is! String) return null;
      if (sequence is! int) return null;
      items.add(
        SteerProvenanceItem(steerId: steerId, sequence: sequence, input: input),
      );
    }
    return SteerProvenance(
      runId: runId is String ? runId : '',
      batchId: batchId,
      items: List.unmodifiable(items),
    );
  }
}

class SteerProvenanceItem {
  const SteerProvenanceItem({
    required this.steerId,
    required this.sequence,
    required this.input,
  });
  final String steerId;
  final int sequence;
  final String input;
}
