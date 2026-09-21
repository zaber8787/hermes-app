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
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/features/chat/message_timeline.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/providers.dart';

/// R4: the approval card, finally actually clicked. Fake approval.request
/// events (real bridge shape: command/choices/run_id/session_id) must render
/// the card, POST the chosen answer to /v1/runs/{run_id}/approval, retire the
/// card on success, stay honest on 404/409, and degrade (display + CLI hint)
/// when no run_id exists at all.

const url = 'http://test.invalid';

class FakeApprovalRepo extends HermesRepository {
  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  FakeApprovalRepo() : super(url, 'fake');
  final events = StreamController<SseEvent>.broadcast();
  final approvals = <List<String>>[];
  Object? approvalError; // when set, the next resolveApproval throws it
  @override
  Stream<SseEvent> chat(String sid, String input) => events.stream;
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
  Future<void> resolveApproval(String runId, String choice) async {
    if (approvalError case final e?) {
      approvalError = null;
      throw e;
    }
    approvals.add([runId, choice]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeApprovalRepo repo;
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
    repo = FakeApprovalRepo();
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

  Future<void> openAndSend(WidgetTester tester, {bool startRun = true}) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedWrap(ChatPage(session: session), locale: AppLocale.zhHant),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byType(TextField), '清一下暫存碟');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump();
    if (startRun) {
      repo.events.add(
        const SseEvent('run.started', '{"session_id":"s","run_id":"r7"}'),
      );
      await tester.pump();
    }
  }

  void approvalEvent({String? runId = 'r7'}) {
    repo.events.add(
      SseEvent(
        'approval.request',
        '{"session_id":"s",${runId == null ? '' : '"run_id":"$runId",'}'
        '"request_id":"q1","command":"rm -rf /tmp/scratch",'
        '"description":"rm 指向目錄","choices":["once","deny"]}',
      ),
    );
  }

  Future<void> finishTurn(WidgetTester tester) async {
    repo.events
      ..add(const SseEvent('run.completed', '{"messages":[]}'))
      ..add(const SseEvent('done', '{}'));
    await repo.events.close();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('approval.request: card shows command + the server choices', (
    tester,
  ) async {
    await openAndSend(tester);
    approvalEvent();
    await tester.pump();
    expect(find.byType(ApprovalCard), findsOneWidget);
    expect(find.text('需要你的核准'), findsOneWidget);
    expect(find.text('rm -rf /tmp/scratch'), findsOneWidget); // 明文命令
    expect(find.text('允許一次'), findsOneWidget);
    expect(find.text('拒絕'), findsOneWidget);
    expect(find.text('本次對話都允許'), findsNothing); // choices 以事件為準
    await finishTurn(tester);
  });

  testWidgets('clicking a choice POSTs it, card retires, turn continues', (
    tester,
  ) async {
    await openAndSend(tester);
    approvalEvent();
    await tester.pump();
    await tester.tap(find.text('拒絕'));
    await tester.pump();
    await tester.pump();
    // mock repo assertion: exactly the contract call POST /v1/runs/r7/approval
    expect(repo.approvals, [
      ['r7', 'deny'],
    ]);
    expect(find.byType(ApprovalCard), findsNothing); // 卡片消失
    expect(find.text('已回覆審核：拒絕'), findsOneWidget); // 老實顯示
    final c = container.read(chatProvider('s'));
    expect(c.busy, isTrue); // 回合續跑
    await finishTurn(tester);
    expect(c.busy, isFalse);
  });

  testWidgets('409 on the answer: honest error, card stays usable', (
    tester,
  ) async {
    await openAndSend(tester);
    approvalEvent();
    await tester.pump();
    repo.approvalError = const ApiException('審核已被處理', 409);
    await tester.tap(find.text('允許一次'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('回覆失敗：審核已被處理 (HTTP 409)'), findsOneWidget);
    expect(find.byType(ApprovalCard), findsOneWidget); // 不消失、不卡死
    // buttons re-armed: the user may retry or settle it elsewhere
    await tester.tap(find.text('拒絕'));
    await tester.pump();
    await tester.pump();
    expect(repo.approvals, [
      ['r7', 'deny'],
    ]);
    expect(find.byType(ApprovalCard), findsNothing);
    await finishTurn(tester);
  });

  testWidgets('no run_id anywhere: display-only + CLI hint', (tester) async {
    await openAndSend(tester, startRun: false); // never saw run.started
    approvalEvent(runId: null);
    await tester.pump();
    expect(find.byType(ApprovalCard), findsOneWidget);
    expect(find.text('rm -rf /tmp/scratch'), findsOneWidget);
    expect(find.text('允許一次'), findsNothing);
    expect(find.textContaining('請改用 CLI 處理'), findsOneWidget);
    await finishTurn(tester);
  });
}
