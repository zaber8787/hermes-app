import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'package:hermes_app/l10n/message_key.dart';

import 'support/localized_app.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/chat/chat_controller.dart'
    show ChatController;
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/providers.dart';

import 'audit_cross_device_sync_test.dart' show FakeSyncRepo;

/// HISTOLD: 「載入較早訊息好像無法使用」.
///
/// The load-older control was disabled for the entire duration of a run: both
/// the button (`onPressed: c.loadingOlder || c.busy ? null : older`) and
/// ChatController.loadOlder (`|| busy`) gated on `busy`, and a long-running
/// turn is precisely when a reader wants the older context — so on a busy
/// session the control looked dead.
///
/// Paging backwards is a read-only GET of rows the live turn cannot touch.
/// Turn state is protected by the `_turnToken` identity check inside
/// loadOlder (a page fetched before a NEW turn was minted is dropped), not by
/// refusing the fetch. Server-side paging is offset-based and was verified
/// against the live gateway (`order=latest&limit=200&offset=N` returns
/// disjoint windows), so nothing upstream needed to change.

const q = '幫我看看這個';

class HPRepo extends FakeSyncRepo {
  /// Rows served for `offset > 0` — the older page under test.
  List<Message>? olderPage;

  @override
  Future<List<Message>> messages(
    String sid, {
    int offset = 0,
    int limit = 200,
  }) {
    if (offset > 0 && olderPage != null) {
      historyReads++;
      return Future.value(olderPage);
    }
    return super.messages(sid, offset: offset, limit: limit);
  }

  @override
  Future<void> stop(String runId) async => stopCalls++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HPRepo repo;
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
    repo = HPRepo();
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
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 12000);
    addTearDown(tester.view.reset);
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

  Future<void> closeAll(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await repo.events.close();
    await tester.pump();
  }

  /// A short latest page keeps the whole timeline flat and laid out, so the
  /// control is always in the tree. `hasOlder` is derived from a page that
  /// fills the window, so the fixture declares the precondition directly.
  void latestPage() {
    repo.history = const [
      Message(id: '1', role: 'user', content: '上一輪的話'),
      Message(id: '2', role: 'assistant', content: '上一輪的回覆'),
    ];
    repo.revCount = 2;
    repo.revLatest = 2;
  }

  void moreHistoryExists() {
    ctrl().hasOlder = true;
    ctrl().notifyListeners();
  }

  Future<void> startRun(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField), q);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
    );
    await tester.pump();
  }

  Finder loadOlderButton() => find.widgetWithText(
    TextButton,
    t(MessageKey.chatM023, locale: AppLocale.zhHant),
  );

  testWidgets('the control stays enabled and loads WHILE a run is streaming', (
    tester,
  ) async {
    latestPage();
    repo.olderPage = const [
      Message(id: '5', role: 'user', content: '更早以前的一句話'),
    ];
    await openPage(tester);
    await startRun(tester);
    moreHistoryExists();
    await tester.pump();
    expect(ctrl().busy, isTrue, reason: 'a run is in flight — the old gate');

    final button = loadOlderButton();
    expect(button, findsOneWidget);
    expect(
      tester.widget<TextButton>(button).onPressed,
      isNotNull,
      reason: 'a running turn must not disable history paging',
    );

    await tester.tap(button);
    await tester.pump();
    await tester.pump();

    expect(
      ctrl().messages.map((m) => m.id),
      contains('5'),
      reason: 'the older page must merge in while the run keeps streaming',
    );
    expect(repo.historyReads, greaterThan(0));
    // An exhausted history (a short page) retires the control.
    expect(ctrl().hasOlder, isFalse);
    await closeAll(tester);
  });

  testWidgets('paging while IDLE still works', (tester) async {
    latestPage();
    repo.olderPage = const [
      Message(id: '5', role: 'user', content: '更早以前的一句話'),
    ];
    await openPage(tester);
    moreHistoryExists();
    final before = repo.historyReads;

    await ctrl().loadOlder();
    await tester.pump();

    expect(ctrl().messages.map((m) => m.id), contains('5'));
    expect(repo.historyReads, greaterThan(before));
    expect(ctrl().loadingOlder, isFalse);
    await closeAll(tester);
  });
}
