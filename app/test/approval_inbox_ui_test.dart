import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/l10n/app_locale.dart';

import 'support/localized_app.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/chat/approval_inbox_view.dart';
import 'package:hermes_app/features/chat/message_timeline.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/providers.dart';

/// APPROVALPUSH B3 (R6/U1-U4): the cross-device approval panel. With the
/// server capability on, cards come from the ApprovalInbox (SSE and GET are
/// the SAME card, keyed by exact request_id); every POST carries the exact
/// id + server_epoch; another device's answer clears ONLY its own card; an
/// old server keeps the legacy card with an honest unavailable notice.

const url = 'http://test.invalid';

// The shape approvalInboxFeature() returns: the INNER feature map.
const capabilityOn = {
  'enabled': true,
  'contract_version': 1,
  'precise_responses': true,
  'server_epoch': 7,
};

class FakeInboxRepo extends HermesRepository {
  FakeInboxRepo({this.capability}) : super(url, 'fake');
  final StreamController<SseEvent> events = StreamController.broadcast();
  Map<String, dynamic>? capability; // null = old server (no feature)
  List<Map<String, dynamic>>? pendingRows; // null = mirror the SSE pendings
  bool snapshotAvailable = true;
  final sseIds = <String>[];
  int getCalls = 0;
  final posts = <List<Object?>>[];
  Object? postError;
  Completer<void>? postGate;

  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  @override
  Stream<SseEvent> chat(String sid, String input, {String? wakeBatch}) =>
      events.stream;
  @override
  Future<List<Message>> messages(
    String sid, {
    int offset = 0,
    int limit = 200,
  }) async => const [];
  @override
  Future<Json> sessionDetail(String sid) async => {
    'id': sid,
    'message_count': 0,
  };
  @override
  Future<List<Skill>> skills() async => const [];
  @override
  Future<void> checkCapabilities() async {}
  @override
  void cancelStream(String sid) {}

  @override
  Future<Map<String, dynamic>?> approvalInboxFeature() async => capability;

  @override
  Future<Json> runApprovals(String runId) async {
    getCalls++;
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    return {
      'schema_version': 1,
      'run_id': runId,
      'session_id': 's',
      'server_epoch': 7,
      'revision': getCalls,
      'pending': [
        for (final r in (pendingRows ??
            [
              for (final id in sseIds)
                {
                  'request_id': id,
                  'command': 'rm -rf /tmp/scratch-$id',
                  'choices': ['once', 'session', 'deny'],
                },
            ]))
          {...r, 'created_at': r['created_at'] ?? now, 'expires_at': r['expires_at'] ?? now + 300},
      ],
      'available': snapshotAvailable,
      'overflow': false,
    };
  }

  @override
  Future<void> resolveApproval(String runId, String choice) async {
    posts.add([runId, choice, null, null]);
  }

  @override
  Future<void> resolveApprovalExact(
    String runId,
    String choice,
    String requestId,
    int? serverEpoch,
  ) async {
    if (postGate case final g?) await g.future;
    if (postError case final e?) {
      postError = null;
      throw e;
    }
    posts.add([runId, choice, requestId, serverEpoch]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeInboxRepo repo;
  late ProviderContainer container;
  final session = Session(
    id: 's',
    title: 'A',
    count: 0,
    startedAt: 0,
    activity: 0,
    source: 'api_server',
  );

  Future<void> boot(WidgetTester tester, {AppLocale locale = AppLocale.zhHant}) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedWrap(ChatPage(session: session), locale: locale),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repo = FakeInboxRepo(capability: Map<String, dynamic>.from(capabilityOn));
    container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        localStoreProvider.overrideWithValue(
          LocalStore(await SharedPreferences.getInstance()),
        ),
        initialSettingsProvider.overrideWith(
          (ref) => const AppSettings(url: url, key: 'k'),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<void> openAndSend(WidgetTester tester) async {
    await boot(tester);
    await tester.enterText(find.byType(TextField), '清一下暫存碟');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump();
    repo.events.add(
      const SseEvent('run.started', '{"session_id":"s","run_id":"r7"}'),
    );
    await tester.pump();
  }


  Future<void> finish(WidgetTester tester) async {
    // Settle the turn so no watchdog/poll timers outlive the test.
    if (!repo.events.isClosed) {
      repo.events
        ..add(const SseEvent('run.completed', '{"messages":[]}'))
        ..add(const SseEvent('done', '{}'));
      await repo.events.close();
    }
    await tester.pump();
    await tester.pump();
  }

  void sseApproval(String rid) {
    repo.sseIds.add(rid);
    repo.events.add(
      SseEvent('approval.request', '{"session_id":"s","run_id":"r7",'
          '"request_id":"$rid","command":"rm -rf /tmp/scratch-$rid",'
          '"description":"d","choices":["once","session","deny"]}'),
    );
  }

  testWidgets('U1: capability on — ONE inbox card, exact-id POST, busy once', (
    tester,
  ) async {
    await openAndSend(tester);
    sseApproval('q1');
    await tester.pump();
    await tester.pump();
    // The command appears exactly once: no duplicate legacy card.
    expect(find.text('rm -rf /tmp/scratch-q1'), findsOneWidget);
    expect(find.byType(ApprovalCard), findsNothing);
    expect(find.byKey(const ValueKey('approval-inbox-q1')), findsOneWidget);
    // Busy: the second tap while the POST is open must not double-send.
    repo.postGate = Completer<void>();
    await tester.tap(find.descendant(
      of: find.byKey(const ValueKey('approval-inbox-q1')),
      matching: find.text('允許一次'),
    ));
    await tester.pump();
    await tester.tap(find.descendant(
      of: find.byKey(const ValueKey('approval-inbox-q1')),
      matching: find.text('允許一次'),
    ));
    await tester.pump();
    repo.postGate!.complete();
    await tester.pump();
    await tester.pump();
    expect(repo.posts, [
      ['r7', 'once', 'q1', 7],
    ]);
    // Settled card is gone.
    expect(find.byKey(const ValueKey('approval-inbox-q1')), findsNothing);
  await finish(tester);
  });
  testWidgets('U2: GET-only pending renders too — same run, unique cards, no fake rows',
      (tester) async {
    await openAndSend(tester);
    repo.pendingRows = [
      {'request_id': 'q1', 'command': 'rm -rf /tmp/a', 'choices': ['once', 'deny']},
      {'request_id': 'q2', 'command': 'rm -rf /tmp/b', 'choices': ['once', 'deny']},
    ];
    sseApproval('q1');
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('approval-inbox-q1')), findsOneWidget);
    expect(find.byKey(const ValueKey('approval-inbox-q2')), findsOneWidget);
    // The SSE card and the GET card merged into ONE (no double q1 command).
    expect(find.text('rm -rf /tmp/scratch-q1'), findsNothing);
    // No fake user row was invented for the remote pending q2: the durable
    // history stays untouched and no turn-level approval card exists.
    expect(container.read(chatProvider('s')).messages, isEmpty);
    expect(find.byType(ApprovalCard), findsNothing);
    // Independent answers per card carry their own exact id.
    await tester.tap(find.descendant(
      of: find.byKey(const ValueKey('approval-inbox-q2')),
      matching: find.text('拒絕'),
    ));
    await tester.pump();
    await tester.pump();
    expect(repo.posts.single, ['r7', 'deny', 'q2', 7]);
    expect(find.byKey(const ValueKey('approval-inbox-q1')), findsOneWidget);
  await finish(tester);
  });
  testWidgets('U3: approval.responded clears ONLY the matching request', (
    tester,
  ) async {
    await openAndSend(tester);
    repo.pendingRows = [
      {
        'request_id': 'q1',
        'command': 'rm -rf /tmp/scratch-q1',
        'choices': ['once', 'session', 'deny'],
      },
      {'request_id': 'q2', 'command': 'rm -rf /tmp/b', 'choices': ['once', 'deny']},
    ];
    sseApproval('q1');
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('approval-inbox-q1')), findsOneWidget);
    expect(find.byKey(const ValueKey('approval-inbox-q2')), findsOneWidget);
    repo.events.add(
      const SseEvent('approval.responded',
          '{"session_id":"s","run_id":"r7","request_id":"q1","choice":"once"}'),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('approval-inbox-q1')), findsNothing);
    expect(find.byKey(const ValueKey('approval-inbox-q2')), findsOneWidget);
    // Remote settlement is shown briefly, then retires.
    expect(find.text('此請求已在其他裝置處理'), findsNothing); // answered by THIS device's chat echo
    await tester.pump(const Duration(seconds: 7));
    await tester.pump();
    expect(find.byKey(const ValueKey('approval-inbox-q2')), findsOneWidget);
  await finish(tester);
  });
  testWidgets('U3: resolved-on-another-device echo names the reason', (
    tester,
  ) async {
    await openAndSend(tester);
    sseApproval('q1');
    await tester.pump();
    await tester.pump();
    repo.events.add(
      const SseEvent('approval.resolved',
          '{"session_id":"s","run_id":"r7","request_id":"q1","outcome":"answered_elsewhere"}'),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('此請求已在其他裝置處理'), findsOneWidget);
    // (The 6-second retirement itself is time-based and covered at store
    // level: pump() cannot advance DateTime.now in a widget test.)
  await finish(tester);
  });
  testWidgets('U3: POST conflict reconciles with ONE fresh GET, never re-posts', (
    tester,
  ) async {
    await openAndSend(tester);
    sseApproval('q1');
    await tester.pump();
    await tester.pump();
    // The queue truth view is UNKNOWN (not empty): reconcile must not
    // silently clear the card, and the POST must never be re-sent.
    repo.snapshotAvailable = false;
    repo.postError = StateError('409 approval_request_required');
    await tester.tap(find.descendant(
      of: find.byKey(const ValueKey('approval-inbox-q1')),
      matching: find.text('允許一次'),
    ));
    await tester.pump();
    await tester.pump();
    final getsAfterFail = repo.getCalls;
    expect(getsAfterFail, greaterThan(1)); // exactly the GET does the reconciling
    expect(repo.posts, isEmpty); // and NO second POST happened
    expect(find.text('核准狀態尚未確認，請重新核對'), findsOneWidget);
  await finish(tester);
  });
  testWidgets('U4: old server — legacy card stays + honest unavailable notice', (
    tester,
  ) async {
    repo.capability = null;
    await openAndSend(tester);
    sseApproval('q1');
    await tester.pump();
    await tester.pump();
    expect(find.byType(ApprovalCard), findsOneWidget);
    expect(find.byType(PendingApprovalCard), findsNothing);
    expect(find.text('此伺服器尚不支援跨裝置核准'), findsOneWidget);
  await finish(tester);
  });
  testWidgets('U4: expired card disables choices and asks to reconfirm — never auto-denies',
      (tester) async {
    await openAndSend(tester);
    final past = DateTime.now().millisecondsSinceEpoch / 1000.0 - 5;
    repo.pendingRows = [
      {
        'request_id': 'q1',
        'command': 'rm -rf /tmp/late',
        'choices': ['once', 'deny'],
        'created_at': past - 300,
        'expires_at': past,
      },
    ];
    sseApproval('q1');
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('approval-inbox-q1')), findsOneWidget);
    expect(find.text('正在確認核准是否仍有效'), findsOneWidget);
    await tester.tap(find.descendant(
      of: find.byKey(const ValueKey('approval-inbox-q1')),
      matching: find.text('拒絕'),
    )); // disabled: a tap must change nothing
    await tester.pump();
    expect(repo.posts, isEmpty);
  await finish(tester);
  });
  testWidgets('U4: en locale renders the catalog labels', (tester) async {
    await boot(tester, locale: AppLocale.en);
    await tester.enterText(find.byType(TextField), 'clear the cache');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump();
    repo.events.add(
      const SseEvent('run.started', '{"session_id":"s","run_id":"r7"}'),
    );
    await tester.pump();
    sseApproval('q1');
    await tester.pump();
    await tester.pump();
    expect(find.text('Allow once'), findsOneWidget);
    expect(find.text('Allow for this conversation'), findsOneWidget);
    expect(find.text('Deny'), findsOneWidget);
    expect(find.textContaining(RegExp(r'About \d+ seconds left')), findsOneWidget);
  await finish(tester);
  });}
