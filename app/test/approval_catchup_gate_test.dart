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
import 'package:hermes_app/models/message.dart' show Json;
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/providers.dart';

import 'support/localized_app.dart';
import 'approval_inbox_ui_test.dart' as fixture;

// APPROVBUTTON X2 (report §3, plan §7.2): "a pending exists" may NOT be the
// only catch-up gate. When the card is unconfirmed or its choices are
// illegal (empty / all-unknown) — or a snapshot once failed — the status
// poll must REPAIR read-only (re-fetch and merge), with a bounded retry and
// a visible 「重新核對」 entry. The client never guesses policy choices, and
// an empty-list replay never wipes populated choices.
//
// Red baseline: the report probe ab_page_probe_test measured snapshot
// GET before=1/after=1 with choices still [] across status ticks.

class GateRepo extends fixture.FakeInboxRepo {
  GateRepo() : super(capability: Map<String, dynamic>.from(fixture.capabilityOn));

  /// Next N snapshot GETs fail (then recover) — the transient outage §3.
  int failNextGets = 0;

  /// What GET /runs/{id} reports for the live turn.
  Map<String, dynamic> Function(String runId)? status;

  int statusCalls = 0;

  @override
  Future<Json> runStatus(String runId) async {
    statusCalls++;
    return status?.call(runId) ?? super.runStatus(runId);
  }

  @override
  Future<Json> runApprovals(String runId) async {
    if (failNextGets > 0) {
      failNextGets--;
      throw StateError('synthetic snapshot outage');
    }
    return super.runApprovals(runId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GateRepo repo;
  late ProviderContainer container;

  Future<void> boot(WidgetTester t) async {
    SharedPreferences.setMockInitialValues({});
    repo = GateRepo();
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
              title: 'test',
              count: 0,
              startedAt: 0,
              activity: 0,
              source: 'api_server',
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
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

  void sseApproval(String rid, {List<String>? choices}) {
    repo.sseIds.add(rid);
    final suffix = choices == null
        ? ''
        : ',"choices":[${choices.map((c) => '"$c"').join(',')}]';
    repo.events.add(
      SseEvent(
        'approval.request',
        '{"session_id":"s","run_id":"r7","request_id":"$rid",'
        '"command":"rm -rf /tmp/scratch-$rid","description":"d"$suffix}',
      ),
    );
  }

  int buttons() =>
      find.descendant(
        of: find.byType(PendingApprovalCard),
        matching: find.byType(FilledButton),
      ).evaluate().length -
      find.byKey(const ValueKey('approval-recheck-q1')).evaluate().length;

  // One status-poll tick (watchInterval is 5s).
  Future<void> statusTick(WidgetTester t) async {
    await t.pump(const Duration(seconds: 6));
    for (var i = 0; i < 4; i++) {
      await t.pump();
    }
  }

  testWidgets('X2: a transient snapshot outage is repaired READ-ONLY by the status poll', (t) async {
    await boot(t);
    repo.failNextGets = 1; // the SSE-triggered GET misses
    repo.status = (_) => {
      'status': 'waiting_for_approval',
      'approval': {'command': 'rm -rf /tmp/scratch-q1'},
    };
    sseApproval('q1');
    await t.pump();
    await t.pump();
    expect(repo.getCalls, 0); // the only GET failed
    final cards = find.byType(PendingApprovalCard);
    expect(cards, findsOneWidget);
    expect(find.text('Approval status is unconfirmed. Check again'), findsOneWidget);
    // The status poll sees waiting_for_approval + the card exists: the OLD
    // gate (hasPendingForRun) stopped here. It must re-fetch instead.
    // (detach → the poll owner takes over, exactly like the report probe.)
    container.read(chatProvider('s')).detach();
    final getsBefore = repo.getCalls;
    await statusTick(t);
    final repaired = repo.getCalls > getsBefore;
    final posts = List.of(repo.posts);
    final stillUnconfirmed =
        container.read(chatProvider('s')).approvalUnconfirmedRuns.contains('r7');
    await end(t);
    expect(repaired, isTrue,
        reason: 'waiting status + unconfirmed card must earn a re-GET, not silence');
    expect(posts, isEmpty); // repair is read-only — never a client-side answer
    expect(stillUnconfirmed, isFalse);
  });

  testWidgets('X2: an empty-choices replay must NOT wipe populated choices', (t) async {
    await boot(t);
    repo.pendingRows = [
      {'request_id': 'q1', 'command': 'rm -rf /tmp/scratch-q1', 'choices': ['once', 'deny']},
    ];
    sseApproval('q1', choices: ['once', 'deny']);
    await t.pump();
    await t.pump();
    expect(find.byType(PendingApprovalCard), findsOneWidget);
    expect(buttons(), 2);
    // A malformed replay: the SAME request with an explicit empty list.
    repo.events.add(
      const SseEvent(
        'approval.request',
        '{"session_id":"s","run_id":"r7","request_id":"q1","choices":[]}',
      ),
    );
    await t.pump();
    await t.pump();
    final seen = buttons();
    final cards = find.byType(PendingApprovalCard).evaluate().length;
    await end(t);
    expect(cards, 1);
    expect(seen, 2,
        reason: 'an empty List replay may never erase legal choices');
  });

  testWidgets('X2: legal choices carried by status poll merge into the card (read-only)', (t) async {
    await boot(t);
    // The snapshot view is UNKNOWN (available=false): the card stays unknown.
    repo.snapshotAvailable = false;
    repo.pendingRows = [];
    repo.status = (_) => {
      'status': 'waiting_for_approval',
      'approval': {
        'request_id': 'q1',
        'choices': ['once', 'deny'],
      },
    };
    sseApproval('q1'); // sparse event: NO choices at all
    await t.pump();
    await t.pump();
    expect(find.byType(PendingApprovalCard), findsOneWidget);
    expect(buttons(), 0); // nothing legal yet — no client-side guessing
    container.read(chatProvider('s')).detach(); // poll mode takes over
    await statusTick(t);
    final seen = buttons();
    final posts = List.of(repo.posts);
    await end(t);
    expect(seen, greaterThan(0),
        reason: 'the status payload IS a read-only view of the same card — merge it');
    expect(posts, isEmpty);
  });

  testWidgets('X2: an unconfirmed card exposes a working 「重新核對」 entry', (t) async {
    await boot(t);
    repo.snapshotAvailable = false;
    sseApproval('q1');
    await t.pump();
    await t.pump();
    expect(find.byType(PendingApprovalCard), findsOneWidget);
    final recheck = find.byKey(const ValueKey('approval-recheck-q1'));
    expect(recheck, findsOneWidget);
    expect(recheck.hitTestable(), findsOne);
    final before = repo.getCalls;
    await t.tap(recheck);
    await t.pump();
    await t.pump();
    final after = repo.getCalls;
    await end(t);
    expect(after, greaterThan(before));
  });

  testWidgets('X2 guard: an unknown-choices pending shows state-unknown, never invented buttons', (t) async {
    await boot(t);
    repo.snapshotAvailable = false;
    repo.status = null; // status keeps answering (default busy-run path)
    repo.pendingRows = [
      {'request_id': 'q1', 'command': 'rm -rf /tmp/scratch-q1', 'choices': ['MAYBE', '']},
    ];
    sseApproval('q1', choices: ['MAYBE']);
    await t.pump();
    await t.pump();
    expect(find.byType(PendingApprovalCard), findsOneWidget);
    final seen = buttons();
    await end(t);
    expect(seen, 0, reason: 'unknown tokens get NO submittable button (R6)');
  });
}
