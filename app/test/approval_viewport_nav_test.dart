import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/approval_inbox_view.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/providers.dart';

import 'support/localized_app.dart';
import 'approval_inbox_ui_test.dart' as fixture;

// APPROVBUTTON X3 (report §4, plan §7.3): a pending approval must be
// REACHABLE from wherever the reader is. The panel lives in the tail sliver
// (the lazy timeline stays lazy — the fix never eagerly expands the page);
// a pinned CTA appears while the reader is away from it and lands exactly
// on the pending card. Acceptance is hit-testability, not findsOneWidget.

class LongRepo extends fixture.FakeInboxRepo {
  LongRepo() : super(capability: Map<String, dynamic>.from(fixture.capabilityOn));

  List<Message> history = const [];

  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);

  @override
  Future<List<Message>> messages(
    String sid, {
    int offset = 0,
    int limit = 200,
  }) async => offset == 0 ? history : const [];
}

List<Message> history80() => List.generate(
      80,
      (i) => Message(
        id: '$i',
        role: i.isEven ? 'user' : 'assistant',
        content: '段落 **粗體** 與文字內容 ($i)\n\n' * 4,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LongRepo repo;
  late ProviderContainer container;

  void parkMidTimeline(WidgetTester t) {
    final position =
        t.state<ScrollableState>(find.byType(Scrollable).first).position;
    position.jumpTo(position.maxScrollExtent / 2);
  }

  Future<void> boot(WidgetTester t, {required bool park}) async {
    SharedPreferences.setMockInitialValues({});
    repo = LongRepo()..history = history80();
    container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        localStoreProvider.overrideWithValue(LocalStore(await SharedPreferences.getInstance())),
        initialSettingsProvider.overrideWith(
          (ref) => const AppSettings(url: fixture.url, key: 'fake'),
        ),
      ],
    );
    addTearDown(container.dispose);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedWrap(
          ChatPage(
            session: Session(
              id: 's',
              title: 'long',
              count: 80,
              startedAt: 0,
              activity: 0,
              source: 'api_server',
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await t.pump();
    }
    await t.enterText(find.byType(TextField), '清一下暫存碟');
    await t.pump();
    await t.tap(find.byIcon(Icons.arrow_upward));
    await t.pump();
    await t.pump();
    repo.events.add(
      const SseEvent('run.started', '{"session_id":"s","run_id":"r7"}'),
    );
    await t.pump();
    if (park) {
      // The reader walks away from the bottom BEFORE the request arrives —
      // like the report probe ("在 timeline 中段停留，再接完整 SSE").
      parkMidTimeline(t);
      await t.pump();
    }
    repo.pendingRows = [
      {'request_id': 'q1', 'command': 'rm -rf /tmp/scratch-q1', 'choices': ['once', 'deny']},
    ];
    repo.events.add(
      const SseEvent(
        'approval.request',
        '{"session_id":"s","run_id":"r7","request_id":"q1",'
        '"command":"rm -rf /tmp/scratch-q1","description":"d",'
        '"choices":["once","deny"]}',
      ),
    );
    for (var i = 0; i < 4; i++) {
      await t.pump();
    }
  }

  Future<void> end(WidgetTester t) async {
    if (!repo.events.isClosed) {
      repo.events
        ..add(const SseEvent('run.completed', '{"messages":[]}'))
        ..add(const SseEvent('done', '{}'));
      await t.pump();
    }
    await t.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await repo.events.close();
  }

  Finder answerButtons() => find.descendant(
        of: find.byKey(const ValueKey('approval-inbox-q1')),
        matching: find.byType(FilledButton),
        matchRoot: false,
      );

  testWidgets('X3: a mid-timeline reader reaches the pending card through the pinned CTA', (t) async {
    await boot(t, park: true);
    // The MODEL owns the exact-request card even while the lazy tail sliver
    // keeps it unbuilt below a long read — what the reader CAN'T do is
    // reach it: zero hit-testable buttons from mid-timeline.
    expect(container.read(chatProvider('s')).pendingApprovals().length, 1);
    expect(answerButtons().hitTestable(), findsNothing);
    // Mid-page: still zero of the card's own buttons reachable...
    expect(answerButtons().hitTestable(), findsNothing);
    // ...but a PINNED entry owns the way in, and it is tappable.
    final cta = find.byKey(const ValueKey('approval-nav-cta'));
    expect(cta, findsOneWidget);
    expect(cta.hitTestable(), findsOne);
    await t.tap(cta);
    for (var i = 0; i < 10; i++) {
      await t.pump();
    }
    final reachable = answerButtons().hitTestable().evaluate().length;
    await end(t);
    expect(reachable, greaterThan(0),
        reason: 'the CTA must land the reader ON the exact request card');
  });

  testWidgets('X3 control: at the panel the CTA is absent (no yank, no duplicate affordance)', (t) async {
    await boot(t, park: false);
    final cta = find.byKey(const ValueKey('approval-nav-cta'));
    final atBottom = answerButtons().hitTestable().evaluate().length;
    await end(t);
    expect(atBottom, greaterThan(0)); // panel visible right after the send
    expect(cta, findsNothing);
  });
}
