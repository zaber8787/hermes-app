import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/features/sessions/sessions_page.dart';

Session s(String id, {double? at, bool pinned = false}) => Session(
      id: id,
      title: id,
      count: 1,
      startedAt: at ?? 1,
      activity: at ?? 1,
      source: 'test',
      pinned: pinned,
    );

void main() {
  group('sortSessionRows', () {
    test('pinned floats to the top even when older than unpinned rows', () {
      final rows = [
        s('new-unpinned', at: 900),
        s('old-pinned', at: 10, pinned: true),
        s('mid-unpinned', at: 500),
      ];
      sortSessionRows(rows, hidden: (_) => false);
      expect(rows.map((r) => r.id).toList(),
          ['old-pinned', 'new-unpinned', 'mid-unpinned']);
    });

    test('within pinned group activity still decides order', () {
      final rows = [
        s('pinned-old', at: 10, pinned: true),
        s('pinned-new', at: 800, pinned: true),
        s('plain', at: 700),
      ];
      sortSessionRows(rows, hidden: (_) => false);
      expect(rows.map((r) => r.id).toList(),
          ['pinned-new', 'pinned-old', 'plain']);
    });

    test('hidden sinks below active but pinned-hidden still floats top', () {
      final rows = [
        s('active', at: 600),
        s('hidden-new', at: 950),
        s('pinned', at: 20, pinned: true),
      ];
      sortSessionRows(rows, hidden: (row) => row.id == 'hidden-new');
      expect(rows.map((r) => r.id).toList(), ['pinned', 'active', 'hidden-new']);
    });
  });
}
