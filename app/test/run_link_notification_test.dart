import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/features/chat/notification_inbox.dart';
import 'package:hermes_app/features/chat/run_link.dart';

/// STEERWEB R7 (App side): the canonical link and the ledger cursor rules.
/// Dedup is by EXACT EVENT ID — text never dedups anything; a read event is
/// never resurrected by a replayed page; a link carrying a secret does not
/// parse AT ALL.
void main() {
  group('run_link (R7)', () {
    test('parses the canonical server form verbatim', () {
      final link = RunLink.tryParse(
        'https://example.invalid/#/chat'
        '?session=s%2F1&run=run_9&event=abc123&request=req7',
      );
      expect(link, isNotNull);
      expect(link!.sessionId, 's/1'); // percent-decoded VERBATIM
      expect(link.runId, 'run_9');
      expect(link.eventId, 'abc123');
      expect(link.requestId, 'req7');
    });

    test('round-trips through toUrl without secrets', () {
      final url = const RunLink(
        sessionId: 's 1',
        runId: 'r/2',
        eventId: 'e-3',
      ).toUrl();
      expect(url.contains('session=s%201'), isTrue);
      expect(url.contains('run=r%2F2'), isTrue);
      final back = RunLink.tryParse(url)!;
      expect(back.sessionId, 's 1');
      expect(back.runId, 'r/2');
      expect(back.eventId, 'e-3');
      for (final secret in ['key=', 'token=', 'apikey=', 'Bearer']) {
        expect(url.contains(secret), isFalse);
      }
    });

    test('a link carrying a credential NEVER parses', () {
      expect(
        RunLink.tryParse(
          'https://x.test/#/chat?session=s&key=SECRET&run=r',
        ),
        isNull,
      );
      expect(
        RunLink.tryParse('ftp://x.test/#/chat?session=s'),
        isNull,
      );
      expect(RunLink.tryParse('https://x.test/#/other?session=s'), isNull);
      expect(RunLink.tryParse('https://x.test/#/chat?run=r'), isNull);
    });
  });

  group('notification ledger (R7)', () {
    NotificationEvent event(
      String id, {
      int seq = 1,
      bool read = false,
      NotificationKind kind = NotificationKind.completed,
    }) => NotificationEvent(
      eventId: id,
      kind: kind,
      runId: 'r1',
      sessionId: 's',
      sourceId: 'terminal',
      seq: seq,
      createdAt: 1,
      read: read,
    );

    NotificationPage page(List<NotificationEvent> items, int cursor) =>
        NotificationPage(
          items: items,
          serverChannel: 'ntfy',
          nextCursor: cursor,
          overflow: false,
        );

    test('replayed pages dedup by EXACT event id (no second card)', () {
      final ledger = NotificationLedger();
      ledger.merge(page([event('a'), event('b', seq: 2)], 2));
      ledger.merge(page([event('a'), event('b', seq: 2)], 2)); // replay
      expect(ledger.unread.length, 2);
    });

    test('a replayed UNREAD glimpse never resurrects a read event', () {
      final ledger = NotificationLedger();
      ledger.merge(page([event('a')], 1));
      ledger.markRead('a');
      ledger.merge(page([event('a', read: false)], 1)); // old glimpse
      expect(ledger.hasUnread, isFalse);
    });

    test('read wins in merge order: read item after unread lands read', () {
      final ledger = NotificationLedger();
      ledger.merge(page([event('a')], 1));
      ledger.merge(page([event('a', read: true)], 2));
      expect(ledger.hasUnread, isFalse);
    });

    test('cursor moves forward only (server clock never rewinds the UI)', () {
      final ledger = NotificationLedger(cursor: 5);
      ledger.merge(page(const [], 3)); // a late/stale page
      expect(ledger.cursor, 5);
      ledger.merge(page(const [], 9));
      expect(ledger.cursor, 9);
    });

    test('an approval event link locates the exact request', () {
      final e = event(
        'ev1',
        kind: NotificationKind.approvalRequest,
      ); // sourceId 'terminal' — replaced below
      final withReq = NotificationEvent(
        eventId: e.eventId,
        kind: NotificationKind.approvalRequest,
        runId: 'r1',
        sessionId: 's',
        sourceId: 'req-77',
        seq: 1,
        createdAt: 1,
        read: false,
      );
      expect(withReq.link.requestId, 'req-77');
      expect(withReq.link.eventId, 'ev1');
      expect(e.kind, NotificationKind.approvalRequest);
    });
  });
}
