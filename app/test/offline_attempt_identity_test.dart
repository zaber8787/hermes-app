import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/chat/local_attempt.dart';
import 'package:hermes_app/features/chat/message_timeline.dart'
    show EntryView;
import 'package:hermes_app/features/chat/turn_history_match.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/platform/connectivity_hint.dart';
import 'package:hermes_app/platform/store_tx.dart';
import 'package:hermes_app/providers.dart';

import 'audit_cross_device_sync_test.dart' show FakeSyncRepo;
import 'stuck_busy_recovery_test.dart' show SBRepo;
import 'support/localized_app.dart';

/// OFFLINE-SEND R3 §5.4/§7 M14+M18: identity over inference. A same-text
/// history row is a CANDIDATE, never proof — attribution requires durable
/// row identity above BOTH watermarks, a server timestamp, and an
/// unchanged server epoch. Ambiguity is reported, never resolved by
/// guessing; durable rows are never deleted by a text match.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const q = '同一句話的兩條真實記錄';
  const t = 1759000000.0; // any real server timestamp

  group('matcher unit — strict candidacy only for attempt-backed records', () {
    test('M18 timestamp-0 rows: legacy may anchor, an attempt-backed hard '
        'attribution may NOT', () {
      final rows = [
        const Message(id: '9', role: 'user', content: q), // timestamp 0
      ];
      expect(
        inspectPendingHistory(rows: rows, pendingText: q).anchorFound,
        isTrue, // the legacy default stays byte-identical
      );
      final strict = inspectPendingHistory(
        rows: rows,
        pendingText: q,
        attemptBacked: true,
        requireServerTime: true,
      );
      expect(strict.anchorIndex, -1);
      expect(strict.ambiguous, isFalse); // no candidacy at all, not a tie
    });

    test('M18 epoch moved: the stale numeric watermark stops excluding — '
        'repeated same text surfaces as ambiguous, never a silent pick', () {
      final rows = [
        const Message(id: '76', role: 'user', content: q, timestamp: t),
        const Message(id: '78', role: 'user', content: q, timestamp: t),
      ];
      // Same epoch: row 76 is below the send-time max -> unique anchor 78.
      final settled = inspectPendingHistory(
        rows: rows,
        pendingText: q,
        historyAfterId: 77,
        attemptBacked: true,
        requireServerTime: true,
      );
      expect(settled.anchorIndex, 1);
      expect(settled.ambiguous, isFalse);
      // Epoch moved: 77 separates nothing anymore -> BOTH are candidates.
      final moved = inspectPendingHistory(
        rows: rows,
        pendingText: q,
        historyAfterId: 77,
        attemptBacked: true,
        requireServerTime: true,
        epochMoved: true,
      );
      expect(moved.anchorIndex, -1);
      expect(moved.ambiguous, isTrue);
      // ...and an ambiguous anchor can NEVER be upgraded into a verdict:
      expect(
        evaluateRecoveryEvidence(quietConfirmed: true, history: moved),
        RecoveryVerdict.unknown,
      );
    });

    test('fold is candidate filtering only: attachments/tags never settle '
        'a turn on text alone', () {
      // The fold says "same words" — that is ALL it is ever allowed to say
      // for an attempt-backed record (§5.4): no rows, no delivered bits.
      expect(
        foldedTurnTextEquals('$q [附件: a.png]', q),
        isTrue, // candidate-level agreement...
      );
      final insp = inspectPendingHistory(
        rows: [
          const Message(id: '5', role: 'assistant', content: '回覆'),
          const Message(id: '6', role: 'user', content: '$q [附件: b.png]',
              timestamp: t),
        ],
        pendingText: q,
        attemptBacked: true,
        requireServerTime: true,
      );
      // Different attachments = different turns: the fold may list a
      // candidate but durable identity (afterId/runId — absent here) is
      // the only claim; this inspection alone settles NOTHING (no final
      // row exists AFTER the candidate — nothing to attribute).
      expect(insp.hasFinal, isFalse);
      expect(
        evaluateRecoveryEvidence(quietConfirmed: true, history: insp),
        isNot(RecoveryVerdict.normalTerminal),
      );
    });
  });

  group('CP face — two durable rows, one honest bubble', () {
    late FakeSyncRepo repo;
    late LocalStore store;
    late ProviderContainer container;
    final session = Session(
      id: 's',
      title: 'A',
      count: 0,
      startedAt: 0,
      activity: 0,
      source: 'api_server',
    );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      repo = FakeSyncRepo();
      store = LocalStore(await SharedPreferences.getInstance());
      container = ProviderContainer(
        overrides: [
          repositoryProvider.overrideWithValue(repo),
          localStoreProvider.overrideWithValue(store),
          initialSettingsProvider.overrideWith(
            (ref) => const AppSettings(url: 'http://test.invalid', key: 'k'),
          ),
        ],
      );
      addTearDown(container.dispose);
    });

    ChatController ctrl() => container.read(chatProvider('s'));

    Future<void> openPage(WidgetTester tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: localizedWrap(
            ChatPage(session: session),
            locale: AppLocale.zhHant,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
    }

    Future<void> sendUi(WidgetTester tester) async {
      await tester.enterText(find.byType(TextField), q);
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump();
    }

    List<String> userIds(WidgetTester tester) =>
        tester
            .widgetList<EntryView>(find.byType(EntryView))
            .where((e) => e.entry.kind == EntryKind.user)
            .map((e) => e.entry.message.id)
            .toList();

    Future<void> closeAll(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await repo.events.close();
      await tester.pump();
    }

    testWidgets('M18: TWO durable same-text rows both render — no text '
        'match may delete or silence either real row', (tester) async {
      repo.history = [
        const Message(id: '1', role: 'user', content: '舊話'),
      ];
      repo.revCount = 1;
      repo.revLatest = 1;
      await openPage(tester);
      await sendUi(tester);
      // The server shows TWO new same-text rows above the send watermark:
      repo.post([
        const Message(id: '2', role: 'user', content: q, timestamp: t),
        const Message(id: '3', role: 'user', content: q, timestamp: t),
      ]);
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(userIds(tester), ['1', '2', '3', 'pending'],
          reason: 'two candidates = we cannot know: both rows AND the '
              'honest pending bubble stand — deleting either is the lie');
      expect(ctrl().busy, isTrue);
      await closeAll(tester);
    });

    testWidgets('M18 contrast: the UNIQUE row above the watermark retires '
        'the bubble exactly once and never respawns', (tester) async {
      repo.history = [
        const Message(id: '1', role: 'user', content: '舊話'),
      ];
      repo.revCount = 1;
      repo.revLatest = 1;
      await openPage(tester);
      await sendUi(tester);
      repo.post([const Message(id: '2', role: 'user', content: q,
          timestamp: t)]);
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(userIds(tester), ['1', '2']); // unique identity -> delivered
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 6));
        expect(userIds(tester), ['1', '2']); // settled claims never respawn
      }
      await closeAll(tester);
    });
  });

  group('M14 — an old attempt never mutates the newer child', () {
    late LocalStore store;
    late SBRepo repo;
    const url = 'http://test.invalid';
    const sid = 's';

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      store = LocalStore(await SharedPreferences.getInstance());
      repo = SBRepo();
    });
    tearDown(() => repo.close());

    testWidgets('a late business frame confirms ONLY the attempt it '
        'belongs to: A stays untouched while B runs', (tester) async {
      var hint = ConnectivityHint.offline;
      final c = ChatController(
        repo,
        store,
        sid,
        serverUrl: url,
        now: tester.binding.clock.now,
        connectivity: () => hint,
        txCapability: () => StoreTxCapability.resolvedAvailable,
      );
      await store.saveDraft(url, sid, q);
      await c.send(q, rawDraft: q); // A: blocked offline, journal record
      await tester.pump();
      final a = c.retryUnsentAttemptId!;
      final aBefore = store.loadAttempt(url, sid, a)!;

      // B = the retry, now online: dispatches through the normal gate.
      hint = ConnectivityHint.unknown;
      final flight = c.retryUnsent(a);
      for (var i = 0; i < 20 && repo.sends == 0; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(repo.sends, 1); // exactly B's child POST
      repo.events.add(
        const SseEvent('run.started', '{"run_id":"rB","session_id":"s"}'),
      );
      await tester.pump();
      await tester.pump();

      // A's journal is EXACTLY what it was, plus the retriedBy stamp B's
      // claim wrote BEFORE dispatch — no frame rewrites an old attempt.
      final aAfter = store.loadAttempt(url, sid, a)!;
      expect(aAfter.delivery, aBefore.delivery); // still notDispatched
      expect(aAfter.terminalEvidence!['decision'], 'blockedBeforeDispatch');
      expect(aAfter.terminalEvidence!['retriedBy'], isA<String>());
      expect(aAfter.rawDraft, q); // draft preserved for A's own history
      expect(aAfter.attemptId, isNot(c.turnAttemptId)); // B owns the turn
      expect(c.turnIsAttemptBacked, isTrue);
      expect(c.livePresentation, LivePresentation.activeConfirmed);

      repo.events
        ..add(
          const SseEvent(
            'run.completed',
            '{"completed":true,"session_id":"s","messages":[]}',
          ),
        )
        ..add(const SseEvent('done', '{}'));
      await repo.events.close();
      for (var i = 0; i < 20 && c.retryFlight != null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      await flight;
      await tester.pump();
      expect(repo.sends, 1); // A never gained a POST, ever
      expect(store.loadAttempt(url, sid, a)!.delivery,
          AttemptDelivery.notDispatched);
      c.dispose();
    });
  });
}
