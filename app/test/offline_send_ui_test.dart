import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/chat/local_attempt.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/platform/connectivity_hint.dart';
import 'package:hermes_app/platform/store_tx.dart';
import 'package:hermes_app/providers.dart';

import 'support/localized_app.dart';
import 'stuck_busy_recovery_test.dart' show SBRepo;

/// OFFLINE-SEND R3 §5.3/§5.5: the UI face of the delivery evidence — the
/// offline short-circuit card with its retry affordance, the ONE derived
/// presentation state CP and LiveTurnView share, and the retry ordering
/// (single-flight, one child, never for unknown, disabled without locks).
/// Every POST assertion reads the repo ledger, never a phase guess.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  final session = Session(
    id: sid,
    title: 'A',
    count: 0,
    startedAt: 0,
    activity: 0,
    source: 'api_server',
  );

  ChatController make(
    WidgetTester tester, {
    ConnectivityHint Function()? connectivity,
    StoreTxCapability Function()? txCapability,
  }) {
    final binding = tester.binding;
    return ChatController(
      repo,
      store,
      sid,
      serverUrl: url,
      now: binding.clock.now,
      connectivity: connectivity ?? () => ConnectivityHint.unknown,
      txCapability: txCapability ?? () => StoreTxCapability.resolvedAvailable,
    );
  }

  ProviderContainer pageContainer(WidgetTester tester) {
    final binding = tester.binding;
    return ProviderContainer(
      overrides: [
        localStoreProvider.overrideWithValue(store),
        initialSettingsProvider.overrideWithValue(
          const AppSettings(url: url, key: 'fake'),
        ),
        repositoryProvider.overrideWithValue(repo),
        skillsProvider.overrideWith((ref) async => []),
        chatNowProvider.overrideWith((ref) => binding.clock.now),
      ],
    );
  }

  UiLocal key(UiMessage? m) => m! as UiLocal;

  testWidgets(
    'M01: offline hint blocks BEFORE dispatch — zero POSTs, draft kept, '
    'the honest not-sent card with an enabled retry affordance',
    (tester) async {
      final c = make(tester, connectivity: () => ConnectivityHint.offline);
      const raw = '  多行\n原文  '; // verbatim raw draft, edges included
      await store.saveDraft(url, sid, raw);
      await c.send(raw.trim(), draft: raw, rawDraft: raw);
      await tester.pump();

      expect(repo.sends, 0);
      expect(repo.stopCalls, 0);
      expect(c.phase, ChatPhase.idle);
      expect(c.busy, isFalse);
      expect(key(c.error).key, MessageKey.chatSendOffline);
      expect(c.deliveryView, AttemptDeliveryView.notDispatched);
      expect(c.failedCard, isNotNull);
      expect(key(c.failedCard!).key, MessageKey.chatSendOffline);
      // The raw draft survives VERBATIM (edges, newline).
      expect(store.draft(url, sid), raw);
      // A notDispatched journal record exists and is retry-offered.
      final id = c.retryUnsentAttemptId;
      expect(id, isNotNull);
      expect(c.retryUnsentAvailable, isTrue);
      final attempt = store.loadAttempt(url, sid, id!)!;
      expect(attempt.delivery, AttemptDelivery.notDispatched);
      expect(attempt.rawDraft, raw);
      expect(attempt.terminalEvidence!['decision'], 'blockedBeforeDispatch');
      expect(attempt.terminalEvidence!['retriedBy'], isNull);
      c.dispose();
    },
  );

  testWidgets(
    'M14: retry of a notDispatched attempt dispatches EXACTLY ONE child '
    '(double-tap joins the same flight); the parent is consumed forever',
    (tester) async {
      final c = make(tester, connectivity: () => ConnectivityHint.offline);
      await store.saveDraft(url, sid, '重送这句');
      await c.send('重送这句', rawDraft: '重送这句');
      await tester.pump();
      final parent = c.retryUnsentAttemptId!;
      expect(repo.sends, 0);

      // Double tap JOINS the one flight — no second child exists to post.
      final f1 = c.retryUnsent(parent);
      expect(identical(c.retryUnsent(parent), c.retryFlight), isTrue);
      final f2 = c.retryUnsent(parent);
      expect(identical(f1, f2), isTrue);

      // Still offline: the CHILD rides its own honest offline short-circuit
      // (zero POSTs by construction) while CONSUMING the parent exactly
      // once. No live stream is ever subscribed, so the repo ledger stays
      // the authority: sends must remain 0 through every retry shape.
      for (var i = 0; i < 10 && c.retryFlight != null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(await f1, SendOutcome.stale);
      await f2;
      await tester.pump();
      await tester.pump();
      expect(c.phase, ChatPhase.idle);
      expect(repo.sends, 0); // zero POSTs ever — the parent is consumed

      // The parent is consumed: retriedBy names the claim-minted CHILD.
      final parentRec = store.loadAttempt(url, sid, parent)!;
      final childId = parentRec.terminalEvidence!['retriedBy'];
      expect(childId, isA<String>());
      expect(childId, isNot(parent));
      final child = store
          .listAttempts(url, sid)
          .firstWhere((a) => a.attemptId == childId);
      expect(child.origin, 'human');
      expect(child.delivery, AttemptDelivery.notDispatched);
      expect(child.rawDraft, '重送这句');
      // A second retry of the same parent is a NO-OP with zero new POSTs
      // and creates NO second child.
      final before = store.listAttempts(url, sid).length;
      expect(await c.retryUnsent(parent), SendOutcome.stale);
      expect(repo.sends, 0);
      expect(store.listAttempts(url, sid).length, before);
      expect(c.retryUnsentAttemptId, isNotNull); // the CHILD is now offered
      c.dispose();
    },
  );

  testWidgets(
    'red line 1/3: an outcome-UNKNOWN attempt has NO retry affordance — '
    'retryUnsent is a structured no-op, never a POST', (tester) async {
      final c = make(tester);
      const raw = 'unknown shape';
      final id = LocalStore.newAttemptId();
      await store.saveAttempt(
        url,
        sid,
        LocalAttempt(
          attemptId: id,
          server: url,
          sid: sid,
          createdAt: DateTime(2026),
          rawDraft: raw,
          delivery: AttemptDelivery.outcomeUnknown,
          terminalEvidence: const {'dispatchIntent': true},
        ),
      );
      expect(c.failedCard, isNull); // unknown is not the failed-card shape
      expect(c.retryUnsentAttemptId, isNull);
      expect(await c.retryUnsent(id), SendOutcome.stale);
      expect(repo.sends, 0);
      c.dispose();
    },
  );

  testWidgets(
    '§4.5 degradation: without RESOLVED Web Locks the retry stays DISABLED '
    'and retryUnsent refuses to post', (tester) async {
      final c = make(
        tester,
        connectivity: () => ConnectivityHint.offline,
        txCapability: () => StoreTxCapability.unavailable,
      );
      await store.saveDraft(url, sid, 'degraded');
      await c.send('degraded', rawDraft: 'degraded');
      await tester.pump();
      final id = c.retryUnsentAttemptId;
      expect(id, isNotNull); // the card is honest…
      expect(c.retryUnsentAvailable, isFalse); // …the button is disabled
      expect(await c.retryUnsent(id!), SendOutcome.stale);
      expect(repo.sends, 0);
      c.dispose();
    },
  );

  testWidgets(
    'M11/§5.3: the derived presentation — pre-ack send is `dispatching` '
    '(never 發言中), acked work is `activeConfirmed`, idle is silent',
    (tester) async {
      final container = pageContainer(tester);
      addTearDown(container.dispose);
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
      final c = container.read(chatProvider(sid));

      await tester.enterText(find.byType(TextField), '统一状态');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump();
      await tester.pump();
      // Attempt-backed, no ack yet: the ONE presentation says dispatching.
      expect(c.busy, isTrue);
      expect(c.livePresentation, LivePresentation.dispatching);
      // The dispatching face never claims someone is typing (M11 red line).
      expect(find.text('發言中'), findsNothing);

      // A business ack (run.started) confirms server-side work: the SAME
      // getter flips to activeConfirmed (existing 發言中/waiting UX).
      repo.events.add(
        const SseEvent('run.started', '{"run_id":"rP","session_id":"s"}'),
      );
      await tester.pump();
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
      await tester.pump();
      await tester.pump();
      expect(c.busy, isFalse);
      expect(c.livePresentation, LivePresentation.silent);
    },
  );

  testWidgets(
    '§5.3 failed card: a journal-only notDispatched attempt (reload shape) '
    'renders its card + an ENABLED retry button through the real ChatPage',
    (tester) async {
      const raw = '重送的稿件';
      await store.saveAttempt(
        url,
        sid,
        LocalAttempt(
          attemptId: LocalStore.newAttemptId(),
          server: url,
          sid: sid,
          createdAt: DateTime(2026),
          rawDraft: raw,
          delivery: AttemptDelivery.notDispatched,
          terminalEvidence: const {
            'stage': 'prepared',
            'decision': 'failedBeforeDispatch',
          },
        ),
      );
      final container = pageContainer(tester);
      addTearDown(container.dispose);
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

      // chatSendNotDispatched (the failedBeforeDispatch decision wording).
      expect(find.text('訊息未送出，草稿與附件已保留。'), findsOneWidget);
      final button = find.byKey(const ValueKey('chat.retryUnsent'));
      expect(button, findsOneWidget);
      await tester.tap(button);
      for (var i = 0; i < 40 && repo.sends == 0; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(repo.sends, 1); // exactly one child POST from the card
      repo.events
        ..add(
          const SseEvent(
            'run.completed',
            '{"completed":true,"session_id":"s","messages":[]}',
          ),
        )
        ..add(const SseEvent('done', '{}'));
      await repo.events.close();
      final c = container.read(chatProvider(sid));
      for (var i = 0; i < 40 && c.busy; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      await tester.pump();
      await tester.pump();
      expect(button, findsNothing); // consumed: no second child affordance
    },
  );
}
