import '../../api/sse.dart';
import '../../l10n/message_key.dart';
import '../../l10n/ui_message.dart';
import '../../models/message.dart';

class LiveTool {
  LiveTool(this.name, this.arguments);
  final String name, arguments;
  String result = '';
  bool completed = false;
}

/// Contract §2–3: deltas are provisional. Only completion payloads establish
/// final text. tool.progress (including reasoning) never splits narration.
class LiveTurn {
  String? runId;
  String delta = '';
  String? finalText;
  String reasoning = '';
  bool completed = false;
  final tools = <LiveTool>[];
  List<Message>? transcript;
  final seenSequences = <String>{};

  /// Pending approval card (approval.request SSE); null when nothing awaits.
  Map<String, dynamic>? approval;
  String? approvalChoice;

  /// Descriptor state (§4.3): the failure renders in the CURRENT locale.
  UiMessage? approvalError;
  bool approvalBusy = false;

  /// R4: the bridge's approval.request carries its OWN run_id; a stream that
  /// missed run.started still has a valid POST target. Null = nothing to
  /// answer here (pre-bridge events) — the card degrades to display-only.
  String? get approvalRunId {
    final fromEvent = approval?['run_id']?.toString();
    if (runId != null) return runId;
    return (fromEvent == null || fromEvent.isEmpty) ? null : fromEvent;
  }

  /// Choices the server allows for this request: the event's own `choices`
  /// list wins (server-truth, R4); flag computation is the fallback for
  /// older payloads.
  List<String> get approvalChoices {
    if (approval == null) return const [];
    final fromEvent = approval!['choices'];
    if (fromEvent is List && fromEvent.isNotEmpty) {
      return fromEvent.map((e) => e.toString()).toList();
    }
    final smartDenied = approval!['smart_denied'] == true;
    final allowSession = approval!['allow_session'] != false;
    final allowPermanent = approval!['allow_permanent'] != false;
    if (smartDenied || !allowSession) return const ['once', 'deny'];
    return allowPermanent
        ? const ['once', 'session', 'always', 'deny']
        : const ['once', 'session', 'deny'];
  }

  void apply(SseEvent event, String sid) {
    if (event.type == 'done') return;
    final data = event.json;
    if (data['session_id'] != null && data['session_id'] != sid) {
      throw const AppFormatException(
        UiMessage.local(MessageKey.streamM001),
      );
    }
    final seq = data['seq'];
    if (seq != null && !seenSequences.add('${data['run_id']}:$seq')) return;
    switch (event.type) {
      case 'run.started':
        runId = textOf(data['run_id']);
      case 'assistant.delta':
        delta += textOf(data['delta']);
      case 'tool.started':
        tools.add(LiveTool(textOf(data['tool_name']), textOf(data['args'])));
      case 'tool.progress':
        reasoning += textOf(data['delta'] ?? data['preview']);
      case 'tool.completed':
      case 'tool.failed':
        final name = textOf(data['tool_name']);
        final pending = tools.where((t) => t.name == name && !t.completed);
        if (pending.isNotEmpty) {
          final tool = pending.first;
          tool.completed = true;
          tool.result = textOf(data['preview']);
        }
      case 'assistant.completed':
        finalText = textOf(data['content']);
      case 'approval.request':
        approval = data;
        approvalChoice = null;
        approvalError = null;
      case 'run.completed':
        transcript = (data['messages'] as List? ?? [])
            .asMap()
            .entries
            .map(
              (e) => Message.fromJson(
                Map<String, dynamic>.from(e.value),
                fallbackId: 'live-${e.key}',
              ),
            )
            .toList();
        completed = true;
      case 'error':
        throw const AppFormatException(
          UiMessage.local(MessageKey.streamM002),
        );
    }
  }
}
