import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/models/message.dart';

/// TASK-RENDERPARITY: the same two-turn exchange as the messages page serves
/// it for an api_server session, for a Discord session the app injected into
/// before the compat projection (core's internal_notification row with the
/// thread's sender prefix), and after it (compat's injected_rows unit:
/// display_kind null, the typed text, a crosssource_provenance block).
List<Map<String, dynamic>> exchange({
  required String Function(String text) userContent,
  String? userKind,
  Map<String, dynamic>? provenance,
}) {
  final rows = <Map<String, dynamic>>[];
  var id = 100;
  for (final text in ['test from app', 'second']) {
    rows.add({
      'id': id++,
      'role': 'user',
      'content': userContent(text),
      'display_kind': userKind,
      'crosssource_provenance': ?provenance,
    });
    final call = 'call_$id';
    rows.add({
      'id': id++,
      'role': 'assistant',
      'content': '',
      'display_kind': null,
      'tool_calls': [
        {
          'id': call,
          'type': 'function',
          'function': {'name': 'terminal', 'arguments': '{}'},
        },
      ],
    });
    rows.add({
      'id': id++,
      'role': 'tool',
      'content': '{"output": "Sun"}',
      'tool_call_id': call,
      'tool_name': 'terminal',
      'display_kind': null,
    });
    rows.add({
      'id': id++,
      'role': 'assistant',
      'content': 'reply to $text: https://example.org',
      'display_kind': null,
    });
  }
  return rows;
}

List<(EntryKind, String)> shape(List<Map<String, dynamic>> rows) =>
    projectMessages(rows.map(Message.fromJson).toList())
        .map((e) => (e.kind, e.kind == EntryKind.tool ? '' : e.message.content))
        .toList();

void main() {
  final api = exchange(userContent: (t) => t);
  final injectedRaw = exchange(
    userContent: (t) => '[zaber] $t',
    userKind: 'internal_notification',
  );
  final injectedProjected = exchange(
    userContent: (t) => t,
    provenance: {
      'schema': 1,
      'admission_id': 'a1',
      'display_kind': 'internal_notification',
    },
  );

  test('api_server exchange: user bubbles and one HERMES final per turn', () {
    expect(shape(api).map((s) => s.$1), [
      EntryKind.user,
      EntryKind.tool,
      EntryKind.finalReply,
      EntryKind.user,
      EntryKind.tool,
      EntryKind.finalReply,
    ]);
  });

  test('red: core row shape renders an internal notice and narration', () {
    final entries = projectMessages(injectedRaw.map(Message.fromJson).toList());
    expect(shape(injectedRaw), isNot(shape(api)));
    final notices = entries.where((e) => e.kind == EntryKind.system).toList();
    expect(notices, hasLength(2));
    expect(
      DisplayEntry.labelKeyFor(notices.first.message),
      MessageKey.systemM003,
    );
    // No user-turn boundary, so the first reply is run narration.
    expect(
      entries
          .where((e) => e.kind == EntryKind.narration)
          .map((e) => e.message.content),
      ['reply to test from app: https://example.org'],
    );
  });

  test('green: compat-projected rows render exactly like api_server', () {
    expect(shape(injectedProjected), shape(api));
    final entries = projectMessages(
      injectedProjected.map(Message.fromJson).toList(),
    );
    expect(entries.where((e) => e.kind == EntryKind.system), isEmpty);
    expect(entries.where((e) => e.kind == EntryKind.narration), isEmpty);
    expect(
      injectedProjected.map(Message.fromJson).where((m) => m.isUserTurn).length,
      2,
    );
  });
}
