import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/approval_inbox.dart';
import 'package:hermes_app/features/chat/approval_inbox_view.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart' show Json;
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/providers.dart';

import 'support/localized_app.dart';
import 'approval_inbox_ui_test.dart' as fixture;

// APPROVBUTTON X4 (report §5, plan §7.4): server_epoch is an OPAQUE STRING
// (real gateway: hex like 8322a8641e79 — the old int parse turned it into
// 0, and the ">0 ? epoch : null" rule then OMITTED it, letting the server
// fall back to its own current epoch — a stale-generation answer sailed
// through the stale check). Fixtures here use the REAL hex shape across
// snapshot / SSE / exact-answer. Epoch decides generation by EQUALITY
// only; a moved generation cleans the stale card (never answerable) and
// the repair loop re-reads the truth.

const hexEpoch = '8322a8641e79';
const hexEpoch2 = 'f00dcafe1234';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('model — opaque hex epoch', () {
    const now = 1000000.0;

    Map<String, dynamic> reqData(String rid, {String epoch = hexEpoch}) => {
      'session_id': 's',
      'run_id': 'r7',
      'request_id': rid,
      'server_epoch': epoch,
      'command': 'rm -rf /tmp/x-$rid',
      'choices': ['once', 'deny'],
      'created_at': now,
      'expires_at': now + 300,
    };

    test('snapshot/SSE hex epoch survives verbatim (never _asInt→0)', () {
      final inbox = ApprovalInbox();
      final a = inbox.upsertEvent(
        serverUrl: 'http://s',
        data: reqData('q1'),
        now: now,
      );
      expect(a!.serverEpoch, hexEpoch);
      inbox.mergeSnapshot(
        serverUrl: 'http://s',
        runId: 'r7',
        snapshot: {
          'schema_version': 1,
          'run_id': 'r7',
          'session_id': 's',
          'server_epoch': hexEpoch,
          'revision': 2,
          'pending': [reqData('q2')],
          'available': true,
          'overflow': false,
        },
        now: now + 1,
      );
      expect(inbox.find(requestId: 'q2')!.serverEpoch, hexEpoch);
    });

    test('key carries the opaque epoch', () {
      final inbox = ApprovalInbox();
      final a = inbox.upsertEvent(
        serverUrl: 'http://s',
        data: reqData('q1'),
        now: now,
      );
      expect(a!.key, 'http://s|s|$hexEpoch|r7|q1');
    });

    test('a moved generation retires the pending card and re-arms repair', () {
      final inbox = ApprovalInbox();
      final old = inbox.upsertEvent(
        serverUrl: 'http://s',
        data: reqData('q1'),
        now: now,
      );
      final moved = inbox.upsertEvent(
        serverUrl: 'http://s',
        data: reqData('q1', epoch: hexEpoch2),
        now: now + 1,
      );
      expect(old!.phase, ApprovalPhase.resolved);
      expect(old.outcome, 'superseded');
      expect(moved!.phase, ApprovalPhase.pending);
      expect(moved.serverEpoch, hexEpoch2);
      // The unknown truth of the new generation must be re-read, not trusted:
      expect(inbox.isUnconfirmed('r7'), isTrue);
      expect(inbox.pendingFor(sessionId: 's').map((e) => e.requestId), ['q1']);
    });

    test('a settled card is never resurrected by a foreign generation', () {
      final inbox = ApprovalInbox();
      final a = inbox.upsertEvent(
        serverUrl: 'http://s',
        data: reqData('q1'),
        now: now,
      );
      inbox.settle(runId: 'r7', requestId: 'q1', outcome: 'answered', now: now);
      final again = inbox.upsertEvent(
        serverUrl: 'http://s',
        data: reqData('q1', epoch: hexEpoch2),
        now: now + 1,
      );
      expect(identical(again, a), isTrue);
      expect(again!.phase, ApprovalPhase.resolved);
      expect(again.serverEpoch, hexEpoch); // foreign generation cannot restamp
    });
  });

  group('wire — hex epoch on snapshot / SSE / exact-answer', () {
    late HexRepo repo;
    late ProviderContainer container;

    Future<void> boot(WidgetTester t) async {
      SharedPreferences.setMockInitialValues({});
      repo = HexRepo();
      container = ProviderContainer(
        overrides: [
          repositoryProvider.overrideWithValue(repo),
          localStoreProvider.overrideWithValue(
            LocalStore(await SharedPreferences.getInstance()),
          ),
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
                title: 't',
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

    testWidgets('X4: hex snapshot epoch rides the exact-answer POST verbatim', (t) async {
      await boot(t);
      repo.pendingRows = [
        {'request_id': 'q1', 'command': 'rm -rf /tmp/x-q1', 'choices': ['once', 'deny']},
      ];
      repo.events.add(
        SseEvent(
          'approval.request',
          '{"session_id":"s","run_id":"r7","request_id":"q1",'
          '"command":"rm -rf /tmp/x-q1","server_epoch":"$hexEpoch",'
          '"choices":["once","deny"]}',
        ),
      );
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey('approval-inbox-q1')), findsOneWidget);
      await t.tap(find.descendant(
        of: find.byKey(const ValueKey('approval-inbox-q1')),
        matching: find.text('Allow once'),
      ));
      await t.pump();
      await t.pump();
      final posts = List.of(repo.posts);
      await end(t);
      expect(
        posts,
        [
          ['r7', 'once', 'q1', hexEpoch],
        ],
        reason: 'the opaque epoch must ride the POST — null here means the '
            'server stale check silently falls back to the CURRENT epoch',
      );
    });

    testWidgets('X4: a generation bump cleans the stale card out of the panel', (t) async {
      await boot(t);
      repo.pendingRows = [
        {'request_id': 'q1', 'command': 'rm -rf /tmp/x-q1', 'choices': ['once', 'deny']},
      ];
      repo.events.add(
        SseEvent(
          'approval.request',
          '{"session_id":"s","run_id":"r7","request_id":"q1",'
          '"command":"rm -rf /tmp/x-q1","server_epoch":"$hexEpoch",'
          '"choices":["once","deny"]}',
        ),
      );
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey('approval-inbox-q1')), findsOneWidget);
      // Gateway restart: the SAME request id arrives under a NEW generation.
      repo.epoch = hexEpoch2;
      repo.pendingRows = [
        {'request_id': 'q1', 'command': 'rm -rf /tmp/x-q1-new', 'choices': ['once', 'deny']},
      ];
      await container.read(chatProvider('s')).reconfirmApprovals(
            container.read(chatProvider('s')).pendingApprovals().first,
          );
      await t.pump();
      await t.pump();
      final c = container.read(chatProvider('s'));
      final unconfirmed = c.approvalUnconfirmedRuns.contains('r7');
      final cards = find.byType(PendingApprovalCard).evaluate().length;
      final answerable = find
          .descendant(
            of: find.byType(PendingApprovalCard),
            matching: find.byType(FilledButton),
          )
          .evaluate()
          .length;
      await end(t);
      expect(cards, 1); // ONE card (the new generation), never two
      expect(answerable, greaterThan(0)); // the re-read truth is answerable
      expect(unconfirmed, isFalse); // the available snapshot confirmed the new gen
    });
  });
}

class HexRepo extends fixture.FakeInboxRepo {
  HexRepo() : super(capability: Map<String, dynamic>.from(fixture.capabilityOn));

  String epoch = hexEpoch;
  List<Map<String, dynamic>>? pendingRows;

  @override
  Future<Json> runApprovals(String runId) async {
    getCalls++;
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    return {
      'schema_version': 1,
      'run_id': runId,
      'session_id': 's',
      'server_epoch': epoch,
      'revision': getCalls,
      'pending': [
        for (final r in (pendingRows ?? const <Map<String, dynamic>>[]))
          {...r, 'created_at': r['created_at'] ?? now, 'expires_at': r['expires_at'] ?? now + 300},
      ],
      'available': true,
      'overflow': false,
    };
  }

  @override
  Future<void> resolveApprovalExact(
    String runId,
    String choice,
    String requestId,
    String? serverEpoch,
  ) async {
    posts.add([runId, choice, requestId, serverEpoch]);
  }
}
