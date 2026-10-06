import 'dart:async';

import 'package:flutter/material.dart' show CircularProgressIndicator;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_app/api/hermes_repository.dart' show ApiException;
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/chat/live_turn.dart';
import 'package:hermes_app/features/chat/message_timeline.dart';
import 'package:hermes_app/features/chat/typing_dots.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/providers.dart';

import 'support/localized_app.dart';
import 'stuck_busy_recovery_test.dart' show SBRepo;

/// STUCK-BUSY plan B5 "UI/i18n" row: countdown 60→1 without misleading
/// typing dots, uncertain actions gated on the persisted retry allowance,
/// the clear-local-waiting action, and en/zh-TW parity. Widget-driven like
/// the AUDIT-05 UI face.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  late SBRepo repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    repo = SBRepo();
  });
  tearDown(() => repo.close());

  final session = Session(
    id: 's',
    title: 'A',
    count: 1,
    startedAt: 0,
    activity: 0,
    source: 'api_server',
  );

  Future<ProviderContainer> mount(WidgetTester tester, AppLocale locale) async {
    final binding = tester.binding;
    final container = ProviderContainer(overrides: [
      localStoreProvider.overrideWithValue(store),
      initialSettingsProvider.overrideWithValue(
        const AppSettings(url: 'http://test.invalid', key: 'fake'),
      ),
      repositoryProvider.overrideWithValue(repo),
      skillsProvider.overrideWith((ref) async => []),
      chatNowProvider.overrideWith((ref) => binding.clock.now),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedWrap(
          locale: locale,
          ChatPage(session: session),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return container;
  }

  testWidgets('recovering shows the countdown and never typing dots (zh)',
      (tester) async {
    await store.savePending(
      repo.baseUrl,
      's',
      userText: '問題一',
      runId: 'r',
    );
    repo.history = const [Message(id: '1', role: 'user', content: '問題一')];
    final hang = Completer<Map<String, dynamic>>();
    repo.status = (_) => hang.future; // never answers: pure observation
    final container = await mount(tester, AppLocale.zhHant);
    // the page bootstrapped the pending record itself: recovering inside
    // a FRESH 60s window, status GET forever in flight.
    expect(container.read(chatProvider('s')).phase, ChatPhase.recovering);
    expect(find.byType(TypingDots), findsNothing);
    expect(find.textContaining('正在核對上一回合'), findsOneWidget);
    expect(find.textContaining('60 秒'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('60 秒'), findsNothing); // ticking down
    expect(find.textContaining('正在核對上一回合'), findsOneWidget);
    expect(find.byType(TypingDots), findsNothing);
    container.read(chatProvider('s')).dispose();
  });

  testWidgets('uncertain with allowance left offers BOTH actions',
      (tester) async {
    await store.savePending(
      repo.baseUrl,
      's',
      userText: '問題一',
      runId: 'r',
    );
    final now = tester.binding.clock.now();
    await store.beginPendingRecovery(
      repo.baseUrl,
      's',
      now: now.subtract(const Duration(seconds: 61)),
    ); // expired, retry still unused
    final container = await mount(tester, AppLocale.zhHant);
    final cc = container.read(chatProvider('s'));
    // ignore: avoid_print
    print('DBG phase=${cc.phase} err=${cc.error} dl=${store.loadPending(repo.baseUrl, 's')?.recoveryDeadline}');
    expect(find.text('重新核對'), findsOneWidget);
    expect(find.text('清除本機等待紀錄'), findsOneWidget);
    expect(find.byType(TypingDots), findsNothing);
    await tester.tap(find.text('重新核對'));
    await tester.pump();
    expect(
      store.loadPending(repo.baseUrl, 's')!.recoveryRetryUsed,
      isTrue,
    ); // consumed exactly once
    // the re-check armed a real 30s window: end the controller (cancels
    // its timers) before the widget teardown drains the fake clock.
    container.read(chatProvider('s')).dispose();
    await tester.pump();
  });

  testWidgets('spent allowance hides 重新核對; clear lands idle, no POSTs (en)',
      (tester) async {
    await store.savePending(
      repo.baseUrl,
      's',
      userText: '問題一',
      runId: 'r',
    );
    final now = tester.binding.clock.now();
    await store.beginPendingRecovery(
      repo.baseUrl,
      's',
      now: now.subtract(const Duration(seconds: 120)),
    );
    await store.consumeRecoveryRetry(
      repo.baseUrl,
      's',
      now: now.subtract(const Duration(seconds: 59)),
    );
    await mount(tester, AppLocale.en);
    expect(
      find.textContaining('The re-check has been used'),
      findsOneWidget,
    );
    expect(find.text('Re-check'), findsNothing);
    expect(
      find.text('Clear local waiting record'),
      findsOneWidget,
    );
    await tester.tap(find.text('Clear local waiting record'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(store.loadPending(repo.baseUrl, 's'), isNull);
    expect(repo.sends, 0);
    expect(repo.stopCalls, 0);
    // settled idle: no countdown row, no dots
    await tester.pump();
    expect(find.byType(TypingDots), findsNothing);
  });

  testWidgets('another-tab prompt renders via the error row (zh)',
      (tester) async {
    final container = await mount(tester, AppLocale.zhHant);
    final c = container.read(chatProvider('s'));
    c.error = const UiMessage.local(MessageKey.chatStateM021);
    c.notifyListeners();
    await tester.pump();
    expect(find.textContaining('已由其他分頁接手'), findsOneWidget);
    c.error = null;
    c.notifyListeners();
    await tester.pump();
  });

  // ---- OFFLINE-SEND R1 (A5): presentation-state gate ----------------------

  testWidgets('LiveTurnView dots follow showTyping, never the bare turn',
      (tester) async {
    final turn = LiveTurn(); // incomplete: the old code always showed dots
    await tester.pumpWidget(
      localizedWrap(
        locale: AppLocale.zhHant,
        LiveTurnView(turn: turn, detailed: false, showTyping: false),
      ),
    );
    expect(find.byType(TypingDots), findsNothing);
    await tester.pumpWidget(
      localizedWrap(
        locale: AppLocale.zhHant,
        LiveTurnView(turn: turn, detailed: false, showTyping: true),
      ),
    );
    expect(find.byType(TypingDots), findsOneWidget);
  });

  testWidgets('recovering with NULL deadline says nothing (zh, live==null)',
      (tester) async {
    await store.savePending(
      repo.baseUrl,
      's',
      userText: '問題一',
      runId: 'r',
    );
    final hang = Completer<Map<String, dynamic>>();
    repo.status = (_) => hang.future;
    final container = await mount(tester, AppLocale.zhHant);
    final c = container.read(chatProvider('s'));
    expect(c.phase, ChatPhase.recovering);
    // An unknown deadline with no active evidence must not fall back to
    // "發言中" + dots: absence of evidence is never evidence of typing.
    c.debugSetRecoveryBudget(null);
    c.notifyListeners();
    await tester.pump();
    expect(find.text('發言中'), findsNothing);
    expect(find.text('Typing'), findsNothing);
    expect(find.byType(TypingDots), findsNothing);
    c.dispose();
  });

  testWidgets('history throw on first read still shows the local exit (zh)',
      (tester) async {
    // A2 contract: a persisted pending turn publishes LOCAL state before
    // any GET; a failing history read must never hide the waiting row
    // behind a spinner.
    await store.savePending(
      repo.baseUrl,
      's',
      userText: '問題一',
    );
    repo.messagesOverride = () => throw const ApiException('blackout');
    final container = await mount(tester, AppLocale.zhHant);
    await tester.pump();
    final c = container.read(chatProvider('s'));
    expect(c.phase, ChatPhase.recovering);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('正在核對上一回合'), findsOneWidget);
    expect(find.text('問題一'), findsOneWidget); // pending bubble visible
    expect(find.byType(TypingDots), findsNothing);
    expect(repo.sends, 0);
    c.dispose();
    await tester.pump();
  });
}
