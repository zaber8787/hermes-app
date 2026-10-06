import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/chat/remote_stop.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/providers.dart';

import 'support/localized_app.dart';

/// CROSSDEV-STOP R2 §5.3 / §7 V04, V13, V17 (UI face): the enablement
/// matrix, the chooser, the row action's composer silence, and the /stop
/// command consumption/retention rules. Every fake records a STOP LEDGER
/// (method + exact runId + counts) — chatCalls-only proves nothing here.
const url = 'http://test.invalid';
const sid = 's';

class UIRepo extends HermesRepository {
  UIRepo() : super(url, 'fake');
  final events = StreamController<SseEvent>.broadcast();
  List<Message> history = [];
  int historyReads = 0, activityReads = 0, chatCalls = 0, statusCalls = 0;
  final stopLocal = <String>[];
  final stopRemote = <String>[];
  int epochTicks = 0;
  String epoch = 'e1';
  bool overflow = false;
  List<ActivityRun> active = [], recent = [];
  int? activityFail; // when set: every activity GET throws this status
  int failNext = 0;
  Completer<void>? stopGate; // parks the NEXT remote stop POST
  int? stopFail; // remote POST throws this status
  Json Function(String) status = (_) => {'status': 'running'};

  @override
  Future<SessionActivity> sessionActivity(String s) async {
    activityReads++;
    if (failNext > 0) {
      failNext--;
      throw ApiException('activity down', 503);
    }
    if (activityFail != null) throw ApiException('activity down', activityFail);
    return SessionActivity(
      sessionId: s,
      resolvedSessionId: s,
      serverEpoch: epoch,
      observedAt: 0,
      historyRevision: HistoryRevision(s, history.length, history.length),
      activityRevision: 0,
      activeRuns: active,
      recentTerminal: recent,
      overflow: overflow,
    );
  }

  @override
  Future<List<Message>> messages(
    String s, {
    int offset = 0,
    int limit = 200,
  }) async {
    historyReads++;
    return history;
  }

  @override
  Future<Json> sessionDetail(String s) async => {
    'id': s,
    'message_count': history.length,
  };

  @override
  Stream<SseEvent> chat(String s, String input, {String? wakeBatch}) {
    chatCalls++;
    return events.stream;
  }

  @override
  Future<void> stop(String runId) async => stopLocal.add(runId);

  @override
  Future<void> stopWithDeadline(String runId) async {
    stopRemote.add(runId);
    final g = stopGate;
    if (g != null) {
      stopGate = null;
      await g.future;
    }
    if (stopFail != null) throw ApiException('stop refused', stopFail);
  }

  @override
  Future<Json> runStatus(String runId) async {
    statusCalls++;
    return status(runId);
  }

  @override
  Future<List<Skill>> skills() async => const [];
  @override
  Future<void> checkCapabilities() async {}
  @override
  void cancelStream(String s) {}
}

ActivityRun rrow({
  String obs = 'o1',
  String? runId = 'rremote',
  String status = 'running',
}) => ActivityRun(
  observationId: obs,
  runId: runId,
  status: status,
  startedAt: 1,
  source: runId == null ? 'session_sync' : 'runs_api',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late UIRepo repo;
  late LocalStore store;
  late ProviderContainer container;
  final session = Session(
    id: sid,
    title: 'A',
    count: 0,
    startedAt: 0,
    activity: 0,
    source: 'api_server',
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    repo = UIRepo();
  });
  tearDown(() => repo.close());

  Future<void> open(WidgetTester tester, {AppLocale locale = AppLocale.en}) async {
    container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        localStoreProvider.overrideWithValue(store),
        initialSettingsProvider.overrideWithValue(
          const AppSettings(url: url, key: 'k'),
        ),
        skillsProvider.overrideWith((ref) async => const []),
        // The page's clock rides the widget-test clock: freshness ages
        // deterministically with pump() (stuck_busy_ui_test pattern).
        chatNowProvider.overrideWith((ref) => tester.binding.clock.now),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedWrap(ChatPage(session: session), locale: locale),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  /// The remote rows' TypingDots animate forever — pumpAndSettle can never
  /// settle while they show, so sheet open/close rides finite pumps instead.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  String inputText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).last).controller!.text;

  Finder affordanceButton() => find.descendant(
    of: find.byKey(const ValueKey('chat.remoteStopAffordance')),
    matching: find.byType(TextButton),
  );

  // ---- enablement matrix ----------------------------------------------------

  testWidgets('single fresh remote row: affordance ENABLED; tap POSTs stop '
      'to that exact runId only — zero chat, zero local busy', (tester) async {
    repo.active = [rrow()];
    await open(tester);
    final c = container.read(chatProvider(sid));
    expect(c.busy, isFalse);
    expect(find.byKey(const ValueKey('chat.remoteStopAffordance')),
        findsOneWidget);
    expect(tester.widget<TextButton>(affordanceButton()).onPressed, isNotNull);
    await tester.tap(affordanceButton());
    await tester.pump();
    await tester.pump();
    expect(repo.stopRemote, ['rremote']);
    expect(repo.stopLocal, isEmpty);
    expect(repo.chatCalls, 0);
    expect(c.busy, isFalse, reason: 'a remote action must never set busy');
    expect(c.phase, ChatPhase.idle);
    expect(find.byKey(const ValueKey('chat.remoteStopFeedback')),
        findsOneWidget);
    expect(find.text(t(MessageKey.chatStopRemoteRequested)), findsOneWidget);
    await leave(tester);
  });

  testWidgets('aged-out evidence: affordance DISABLED with the readable '
      'refresh reason (RefreshRequired)', (tester) async {
    repo.active = [rrow()];
    await open(tester);
    final c = container.read(chatProvider(sid));
    expect(c.canRequestRemoteStop, isTrue);
    repo.activityFail = 503; // every later observation fails
    await tester.pump(const Duration(seconds: 7)); // tick + 6s freshness gone
    expect(c.canRequestRemoteStop, isFalse);
    expect(c.remoteBlockReason, RemoteStopBlock.stale);
    await tester.pump();
    expect(tester.widget<TextButton>(affordanceButton()).onPressed, isNull);
    // The reason shows READABLY on the affordance and on each disabled row
    // action — readable text, never tooltip-only (V17).
    expect(find.text(t(MessageKey.chatStopRemoteRefreshRequired)),
        findsWidgets);
    expect(repo.stopRemote, isEmpty);
    await leave(tester);
  });

  testWidgets('null-runId row: disabled ACTION with the readable no-run-id '
      'reason — never tooltip-only (V02/V17)', (tester) async {
    repo.active = [rrow(runId: null)];
    await open(tester);
    expect(find.byKey(const ValueKey('chat.remoteStopDisabled')),
        findsOneWidget);
    expect(find.text(t(MessageKey.chatStopRemoteNoRunId)), findsWidgets);
    expect(repo.stopRemote, isEmpty);
    await leave(tester);
  });

  testWidgets('stopping row shows 核對中 purely from fresh activity and is not '
      'a POST target (V10/V17, zh)', (tester) async {
    repo.active = [rrow(status: 'stopping')];
    await open(tester, locale: AppLocale.zhHant);
    await tester.pump(const Duration(seconds: 6));
    expect(
      find.text(t(MessageKey.chatStopRemoteChecking,
          locale: AppLocale.zhHant)),
      findsWidgets,
    );
    final c = container.read(chatProvider(sid));
    expect(c.remoteStopCandidates, isEmpty);
    expect(c.remoteStopPhaseState, RemoteStopPhaseState.none);
    expect(repo.stopRemote, isEmpty, reason: 'reload = zero auto POSTs');
    await leave(tester);
  });

  // ---- chooser --------------------------------------------------------------

  testWidgets('two stoppable rows: chooser lists them; cancel = ZERO side '
      'effects; selecting POSTs the named row only', (tester) async {
    repo.active = [
      rrow(obs: 'oa', runId: 'rra'),
      rrow(obs: 'ob', runId: 'rrb'),
    ];
    await open(tester);
    expect(tester.widget<TextButton>(affordanceButton()).onPressed, isNotNull);
    await tester.tap(affordanceButton());
    await settle(tester);
    expect(find.text(t(MessageKey.chatStopRemoteChoose)), findsOneWidget);
    expect(
      find.byKey(const ValueKey('chat.stopChooser.rra')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('chat.stopChooser.rrb')),
      findsOneWidget,
    );
    await tester.tap(find.text(t(MessageKey.commonCancel)));
    await settle(tester);
    expect(repo.stopRemote, isEmpty, reason: 'cancel has zero side effects');

    await tester.tap(affordanceButton());
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('chat.stopChooser.rrb')));
    await settle(tester);
    expect(repo.stopRemote, ['rrb'], reason: 'ONLY the named row is POSTed');
    expect(repo.chatCalls, 0);
    await leave(tester);
  });

  testWidgets('overflow: the chooser still opens, with the visible '
      'may-not-be-everything note', (tester) async {
    repo.active = [rrow(runId: 'rra')];
    repo.overflow = true;
    await open(tester);
    await tester.tap(affordanceButton());
    await settle(tester);
    expect(
      find.byKey(const ValueKey('chat.stopChooserOverflow')),
      findsOneWidget,
    );
    expect(find.text(t(MessageKey.chatM016)), findsWidgets);
    await tester.tap(find.text(t(MessageKey.commonCancel)));
    await settle(tester);
    expect(repo.stopRemote, isEmpty);
    await leave(tester);
  });

  testWidgets('null-runId entry appears in the chooser DISABLED with its '
      'reason and is never selectable (V04)', (tester) async {
    repo.active = [rrow(obs: 'oa', runId: 'rra'), rrow(obs: 'ob', runId: null)];
    await open(tester);
    await tester.tap(affordanceButton());
    await settle(tester);
    expect(find.byKey(const ValueKey('chat.stopChooser.rra')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat.stopChooser.blocked')),
        findsOneWidget);
    // The same readable reason also stands on the page row itself — text in
    // two places beats a tooltip in zero of them (V17).
    expect(find.text(t(MessageKey.chatStopRemoteNoRunId)), findsWidgets);
    await leave(tester);
  });

  // ---- row action vs composer ----------------------------------------------

  testWidgets('the ROW stop action never touches the composer or the draft '
      '(V13)', (tester) async {
    repo.active = [rrow()];
    await open(tester);
    await tester.enterText(find.byType(TextField).last, '打字中');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chat.remoteStop.rremote')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // draft debounce
    expect(inputText(tester), '打字中'); // composer untouched
    expect(store.draft(url, sid), '打字中'); // draft slot kept verbatim
    expect(repo.stopRemote, ['rremote']);
    await leave(tester);
  });

  // ---- /stop command consumption & retention (V13) --------------------------

  testWidgets('/stop with an accepted outcome consumes the COMMAND (never a '
      'draft); no restore affordance appears', (tester) async {
    repo.active = [rrow()];
    await open(tester);
    await tester.enterText(find.byType(TextField).last, '/stop');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump();
    expect(inputText(tester), isEmpty, reason: 'command consumed');
    expect(repo.stopRemote, ['rremote']);
    expect(repo.chatCalls, 0);
    expect(find.byKey(const ValueKey('chat.restoreDraft')), findsNothing);
    await leave(tester);
  });

  testWidgets('/stop with 409 also consumes the command and shows the '
      'non-error checking wording (V07/V17, zh)', (tester) async {
    repo.active = [rrow()];
    repo.stopFail = 409;
    await open(tester, locale: AppLocale.zhHant);
    await tester.enterText(find.byType(TextField).last, '/stop');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump();
    expect(inputText(tester), isEmpty, reason: '409 checking consumes the '
        'command without claiming anything (§5.3)');
    expect(
      find.text(t(MessageKey.chatStopRemoteChecking,
          locale: AppLocale.zhHant)),
      findsWidgets,
    );
    expect(find.text(t(MessageKey.chatStopRemoteEnded,
        locale: AppLocale.zhHant)), findsNothing);
    await leave(tester);
  });

  testWidgets('/stop with a FAILED preflight RETAINS the command', (
    tester,
  ) async {
    repo.active = [rrow()];
    await open(tester);
    final c = container.read(chatProvider(sid));
    expect(c.canRequestRemoteStop, isTrue);
    repo.activityFail = 503; // the click's NEW preflight cannot succeed
    await tester.pump(const Duration(seconds: 7));
    await tester.enterText(find.byType(TextField).last, '/stop');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump();
    expect(inputText(tester), '/stop',
        reason: 'no evidence → the typed command stays, nothing POSTed');
    expect(repo.stopRemote, isEmpty);
    await leave(tester);
  });

  testWidgets('input TYPED DURING the awaited /stop survives untouched', (
    tester,
  ) async {
    repo.active = [rrow()];
    await open(tester);
    final gate = Completer<void>();
    repo.stopGate = gate;
    await tester.enterText(find.byType(TextField).last, '/stop');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    expect(repo.stopRemote, ['rremote']); // parked inside the POST
    await tester.enterText(find.byType(TextField).last, '新的輸入');
    await tester.pump();
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(inputText(tester), '新的輸入',
        reason: 'the accepted /stop may clear ONLY its own command text');
    await leave(tester);
  });

  testWidgets('connection move during an awaited POST: targetChanged RETAINS '
      'the command, readable feedback, no draft restore (V11/V13)', (
    tester,
  ) async {
    repo.active = [rrow()];
    await open(tester);
    final c = container.read(chatProvider(sid));
    final gate = Completer<void>();
    repo.stopGate = gate;
    await tester.enterText(find.byType(TextField).last, '/stop');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    expect(repo.stopRemote, ['rremote']); // POST parked mid-flight
    c.debugBumpConnectionGeneration(); // settings moved underneath
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(inputText(tester), '/stop', reason: 'targetChanged never consumes');
    expect(
      find.text(t(MessageKey.chatStopRemoteTargetChanged)),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('chat.restoreDraft')), findsNothing);
    expect(c.remoteStopPhaseState, RemoteStopPhaseState.none);
    await leave(tester);
  });
}
