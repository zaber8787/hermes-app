import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/localized_app.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/chat/message_timeline.dart';
import 'package:hermes_app/features/chat/typing_dots.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/providers.dart';

/// R2 regressions: every busy shape must LOOK busy. Old code drew the
/// pending bubble + "發言中" row only under `pendingInput != null && live
/// != null`, so bootstrap-recovering (live == null) rendered nothing at
/// all — the exact complaint. Red on old = recovering shows no dots.

const url = 'http://test.invalid';

class FakeR2Repo extends HermesRepository {
  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  FakeR2Repo() : super(url, 'fake');

  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async =>
      {'id': sid, 'message_count': 0}; // R1 sync clock: quiet by default
  final events = StreamController<SseEvent>.broadcast();
  List<Message> history = [];
  Json Function(String runId) status = (_) => {'status': 'running'};
  int sends = 0;
  String? stopped;
  @override
  Future<void> stop(String runId) async => stopped = runId;
  @override
  Stream<SseEvent> chat(String sid, String input) {
    sends++;
    return events.stream;
  }

  @override
  Future<List<Message>> messages(
    String sid, {
    int offset = 0,
    int limit = 200,
  }) async => history;
  @override
  Future<Json> runStatus(String runId) async => status(runId);
  @override
  Future<List<Skill>> skills() async => const [];
  @override
  Future<void> checkCapabilities() async {}
  @override
  void cancelStream(String sid) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeR2Repo repo;
  late LocalStore store;
  late ProviderContainer container;
  final session = Session(
    id: 's',
    title: 'A',
    count: 1,
    startedAt: 0,
    activity: 0,
    source: 'api_server',
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repo = FakeR2Repo();
    store = LocalStore(await SharedPreferences.getInstance());
    container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        localStoreProvider.overrideWithValue(store),
        initialSettingsProvider.overrideWith(
          (ref) => const AppSettings(url: url, key: 'k'),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<void> openPage(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedWrap(ChatPage(session: session)),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('idle: no typing row', (tester) async {
    await openPage(tester);
    expect(find.byType(TypingDots), findsNothing);
  });

  testWidgets(
    'bootstrap recovering (busy, live==null): row + pending bubble',
    (tester) async {
      await store.savePending(url, 's', userText: '測試輸入內容', runId: 'r9');
      await openPage(tester); // bootstrap adopts -> phase recovering
      final c = container.read(chatProvider('s'));
      expect(c.busy, isTrue);
      expect(c.live, isNull);
      expect(
        find.byType(TypingDots),
        findsOneWidget,
        reason: 'recovering used to render NOTHING (R2 complaint)',
      );
      expect(find.text('測試輸入內容'), findsOneWidget); // pending bubble

      // Settle the adopted run so no bootstrap timer outlives the test.
      repo.history = const [
        Message(id: '1', role: 'user', content: '測試輸入內容'),
        Message(id: '2', role: 'assistant', content: '結案'),
      ];
      repo.status = (_) => {'status': 'completed'};
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(c.busy, isFalse);
      expect(find.byType(TypingDots), findsNothing);
    },
  );

  testWidgets(
    'sending: bubble + row; once history carries the row: no duplication',
    (tester) async {
      await openPage(tester);
      await tester.enterText(find.byType(TextField), '獨白');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump();
      await tester.pump();
      final c = container.read(chatProvider('s'));
      expect(c.busy, isTrue);
      // The live branch narrates through LiveTurnView (its own dots) —
      // no extra "發言中" row, no doubled dots (that was the old
      // double-narration this task calls out).
      expect(find.byType(TypingDots), findsOneWidget);
      expect(find.text('發言中'), findsNothing);
      // Bubble stands in for the not-yet-persisted row.
      expect(
        find.descendant(
          of: find.byType(MessageTimeline),
          matching: find.text('獨白'),
        ),
        findsNothing,
      );
      expect(find.text('獨白'), findsOneWidget);

      // Server persisted the row: the bubble must retire (no duplicate).
      repo.history = const [Message(id: '1', role: 'user', content: '獨白')];
      await c.reconcileForeground();
      await tester.pump();
      expect(c.pendingDelivered, isTrue);
      expect(find.text('獨白'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(MessageTimeline),
          matching: find.text('獨白'),
        ),
        findsOneWidget, // exactly ONE user row, and it is the timeline's
      );

      // End the turn cleanly.
      repo.events
        ..add(const SseEvent('run.completed', '{"messages":[]}'))
        ..add(const SseEvent('done', '{}'));
      await repo.events.close();
      await tester.pump();
      await tester.pump();
      expect(c.busy, isFalse);
    },
  );

  testWidgets(
    'stopping drain (busy, live==null, no pending text): row without bubble',
    (tester) async {
      await store.savePending(url, 's', userText: '長活', runId: 'r9');
      repo.history = const [
        Message(id: '1', role: 'user', content: '長活'),
      ]; // bootstrap anchors the adopted row: bubble never shows
      await openPage(tester); // bootstrap adopts -> recovering
      final c = container.read(chatProvider('s'));
      expect(c.busy, isTrue);
      await c.stop(); // accepted; the stopping watch owns the turn now
      await tester.pump();
      await tester.pump();
      expect(c.busy, isTrue, reason: 'running status: stop still draining');
      expect(c.live, isNull);
      expect(c.pendingInput, isNull);
      expect(c.pendingBubbleText, isNull);
      expect(
        find.byType(TypingDots),
        findsOneWidget,
        reason: 'the stopping-drain shape must still look busy',
      );
      expect(find.text('長活'), findsOneWidget); // the history row only

      // Terminal: settle so no scheduler outlives the test.
      repo.status = (_) => {'status': 'completed'};
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(c.busy, isFalse);
      expect(find.byType(TypingDots), findsNothing);
    },
  );
}
