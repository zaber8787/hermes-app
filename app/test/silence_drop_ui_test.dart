import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/providers.dart';

import 'support/localized_app.dart';

// SILENCE-DROP §4.8 (UI face): the waiting notice and the neutral silence
// check render in secondary tones (never error red) and switch locale
// live without touching the stream or the POST count.
class FakeUiRepo extends HermesRepository {
  FakeUiRepo() : super('http://test.invalid', 'fake');
  StreamController<SseEvent>? _cur;
  List<Message> history = [];
  int sends = 0, reads = 0;
  Json Function(String runId) status = (_) => {'status': 'running'};
  StreamController<SseEvent> get events => _cur!;
  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async =>
      {'id': sid, 'message_count': 0};
  @override
  Stream<SseEvent> chat(String sid, String input) {
    sends++;
    _cur = StreamController<SseEvent>();
    return _cur!.stream;
  }

  @override
  Future<List<Message>> messages(
    String sid, {
    int offset = 0,
    int limit = 200,
  }) async {
    reads++;
    return history;
  }

  @override
  Future<Json> runStatus(String runId) async => status(runId);

  @override
  void cancelStream(String sid) {
    final c = _cur;
    if (c != null && !c.isClosed) unawaited(c.close());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  late FakeUiRepo repo;
  late ProviderContainer container;
  const url = 'http://test.invalid';
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
    store = LocalStore(await SharedPreferences.getInstance());
    repo = FakeUiRepo();
  });
  tearDown(() {
    container.dispose();
    repo.close();
  });

  Future<void> mount(WidgetTester tester, AppLocale locale) async {
    final binding = tester.binding;
    container = ProviderContainer(overrides: [
      localStoreProvider.overrideWithValue(store),
      initialSettingsProvider.overrideWithValue(
        const AppSettings(url: url, key: 'fake'),
      ),
      repositoryProvider.overrideWithValue(repo),
      skillsProvider.overrideWith((ref) async => []),
      chatNowProvider.overrideWith((ref) => binding.clock.now),
    ]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedWrap(locale: locale, ChatPage(session: session)),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> sendHi(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField), 'hi');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(repo.sends, 1);
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r","session_id":"s"}'),
    );
    await tester.pump();
    await tester.pump();
  }

  Color? textColor(WidgetTester tester, Finder finder) =>
      tester.widget<Text>(finder).style?.color;
  ColorScheme scheme(WidgetTester tester, Finder finder) =>
      Theme.of(tester.element(finder)).colorScheme;

  testWidgets(
    'waiting + silence-check ride secondary tones, never error red (en)',
    (tester) async {
      await mount(tester, AppLocale.en);
      await sendHi(tester);

      await tester.pump(const Duration(seconds: 40));
      final waiting = find.text('Waiting for a reply (no output for 40s)');
      expect(waiting, findsOneWidget);
      expect(textColor(tester, waiting), isNot(scheme(tester, waiting).error));

      await tester.pump(const Duration(seconds: 45)); // tick at 80 recovers
      final check = find.textContaining('No stream updates received');
      expect(check, findsOneWidget);
      expect(textColor(tester, check), scheme(tester, check).tertiary);
      expect(textColor(tester, check), isNot(scheme(tester, check).error));
      expect(repo.sends, 1); // observing history is read-only

      // The parked round finds the persisted final and settles.

      repo.history = const [
        Message(id: '1', role: 'user', content: 'hi'),
        Message(id: '2', role: 'assistant', content: 'ok'),
      ];
      await tester.pump(const Duration(seconds: 20));
      await tester.pump();
      await tester.pump();
      expect(repo.sends, 1);
      expect(find.textContaining('No stream updates received'), findsNothing);
      expect(find.textContaining('Waiting for a reply'), findsNothing);
    },
  );

  testWidgets('the same descriptors switch zh-Hant live, streams untouched', (
    tester,
  ) async {
    await mount(tester, AppLocale.en);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedWrap(locale: AppLocale.zhHant, ChatPage(session: session)),
      ),
    );
    await tester.pump();
    await tester.pump();

    await sendHi(tester);
    await tester.pump(const Duration(seconds: 40));
    expect(
      find.text('等待回覆（無輸出 40 秒）'),
      findsOneWidget,
    ); // zh rendering
    await tester.pump(const Duration(seconds: 45));
    expect(
      find.textContaining('暫未收到串流更新'),
      findsOneWidget,
    ); // descriptor, not pre-rendered text
    expect(repo.sends, 1);
    repo.history = const [
      Message(id: '1', role: 'user', content: 'hi'),
      Message(id: '2', role: 'assistant', content: 'ok'),
    ];
    await tester.pump(const Duration(seconds: 20));
    await tester.pump();
    await tester.pump();
    expect(repo.sends, 1);
  });

  testWidgets('an OBSERVED stream interruption keeps the error red', (
    tester,
  ) async {
    await mount(tester, AppLocale.en);
    await sendHi(tester);

    repo.events.addError(const ApiException('gone', 502));
    await tester.pump();
    await tester.pump();
    final fail = find.textContaining('The reply stream was interrupted');
    expect(fail, findsOneWidget);
    expect(textColor(tester, fail), scheme(tester, fail).error);
    expect(repo.sends, 1);

    repo.history = const [
      Message(id: '1', role: 'user', content: 'hi'),
      Message(id: '2', role: 'assistant', content:'ok'),
    ];
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump();
  });
}
