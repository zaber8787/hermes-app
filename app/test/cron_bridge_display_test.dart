import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/models/message.dart';

// P5 cron bridge: the App must already render committed cron reports as
// system events without any UI change (timeline-only contract).
Message cronRow(String id, double ts) => Message.fromJson({
  'id': id,
  'role': 'user',
  'content': '[Cron report: Daily]\nscheduled finding',
  'display_kind': 'internal_notification',
  'timestamp': ts,
});

void main() {
  test('internal_notification parses to a catalogued collapsed system kind', () {
    final m = cronRow('901', 1700.0);
    expect(m.isUserTurn, isFalse);
    expect(DisplayEntry.labelKeyFor(m), MessageKey.systemM003);
  });

  test('cron row renders as a system entry and never steals the turn final', () {
    final entries = projectMessages([
      Message.fromJson({'id': '900', 'role': 'user', 'content': 'hello'}),
      Message.fromJson({'id': '901', 'role': 'assistant', 'content': 'hi'}),
      cronRow('902', 1701.0),
      Message.fromJson({'id': '903', 'role': 'assistant', 'content': 'later'}),
    ]);
    final report = entries.singleWhere((e) => e.message.id == '902');
    expect(report.kind, EntryKind.system);
    // The report is not a user turn: it must not split the alternation. The
    // last contentful assistant stays the one final (901 demotes to
    // narration; 902 cannot "become" a turn boundary).
    expect(
      entries
          .where((e) => e.kind == EntryKind.finalReply)
          .map((e) => e.message.id),
      ['903'],
    );
    expect(
      entries
          .where((e) => e.kind == EntryKind.narration)
          .map((e) => e.message.id),
      ['901'],
    );
  });

  test('consecutive user-role reports merge without inventing fake busy turns', () {
    final entries = projectMessages([
      cronRow('902', 1701.0),
      cronRow('903', 1702.0),
    ]);
    expect(
      entries.map((e) => e.kind),
      [EntryKind.system, EntryKind.system],
    );
  });
}
