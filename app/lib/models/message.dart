import 'dart:convert';

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
  );

  bool get isUserTurn => role == 'user' && displayKind == null;
}

/// Contract §3: non-null kinds use a closed rendering whitelist; unknown kinds
/// remain collapsed system events. Storage itself is NOT a closed enum.
const systemLabels = {
  'async_delegation_complete': '委派完成',
  'auto_continue': '自動續行',
  'internal_notification': '內部通知',
  'model_switch': '模型切換',
  'personality_switch': '風格切換',
  'skill_invocation': 'Skill 呼叫',
  'steer': '插話',
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
  final String? label;
}

/// Contract §3–4. A turn's final is its LAST contentful, tool-free assistant.
/// A tool-calling assistant may contribute BOTH narration and tool cards.
List<DisplayEntry> projectMessages(List<Message> messages) {
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
      entries.add(
        DisplayEntry(
          EntryKind.system,
          m,
          label: systemLabels[m.displayKind] ?? '系統事件',
        ),
      );
    } else if (m.role == 'user') {
      entries.add(DisplayEntry(EntryKind.user, m));
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
