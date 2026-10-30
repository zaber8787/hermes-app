import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/call/call_controller.dart';
import 'package:hermes_app/features/call/call_entry.dart';
import 'package:hermes_app/features/call/call_page.dart';
import 'package:hermes_app/features/call/call_providers.dart';
import 'package:hermes_app/features/call/call_state.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/sessions/sessions_page.dart';
import 'package:hermes_app/features/settings/key_vault.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/models/message.dart' show Message;
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/providers.dart';

import 'support/call_fakes.dart';
import 'support/localized_app.dart';

// PLAN-VOICEUI §6.2 call_entry_test: the buttons, the picker, the single
// call rule, and the one-popup invariant on ChatPage.

class MapVault implements KeyVault {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class CallEntryRepo extends HermesRepository {
  CallEntryRepo() : super('http://test.invalid', 'fake');
  List<Session> rows = [];
  @override
  Future<List<Session>> sessions() async => List.of(rows);
  @override
  Future<bool> health() async => true;
  @override
  Future<List<Skill>> skills() async => const [];
  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async => {
    'id': sid,
    'message_count': 0,
  };
  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  @override
  Future<void> checkCapabilities() async {}
  @override
  Future<List<Message>> messages(
    String sid, {
    int offset = 0,
    int limit = 200,
  }) async => const [];
  @override
  Stream<SseEvent> chat(String sid, String input, {String? wakeBatch}) =>
      throw StateError('calls must not send chat streams');
  @override
  void cancelStream(String sid) {}
}

Session row(String id, String title) => Session(
  id: id,
  title: title,
  count: 1,
  startedAt: 100,
  activity: 100,
  source: 'api',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const url = 'http://test.invalid';

  late CallEntryRepo repo;
  late MapVault vault;
  late ProviderContainer container;
  late FakeConnector connector;
  late List<FakeCallAudio> madeAudio;

  Future<void> boot(WidgetTester tester, Widget page) async {
    SharedPreferences.setMockInitialValues({});
    repo = CallEntryRepo()..rows = [row('a', 'Alpha'), row('b', 'Beta')];
    vault = MapVault();
    final store = LocalStore(
      await SharedPreferences.getInstance(),
      vault: vault,
    );
    connector = FakeConnector();
    madeAudio = [];
    container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        localStoreProvider.overrideWithValue(store),
        initialSettingsProvider.overrideWithValue(
          const AppSettings(url: url, key: 'k'),
        ),
        skillsProvider.overrideWith((ref) async => []),
        gatewayConnectorProvider.overrideWithValue(connector.call),
        callAudioFactoryProvider.overrideWithValue(() {
          final a = FakeCallAudio();
          madeAudio.add(a);
          return a;
        }),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedWrap(page),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    addTearDown(() async {
      container.read(activeCallProvider)?.dispose();
      for (final a in madeAudio) {
        await a.dispose();
      }
      container.dispose();
      repo.close();
    });
  }

  testWidgets('(1) chat AppBar carries the call button and pushes /call', (tester) async {
    await boot(
      tester,
      ChatPage(session: row('a', 'Alpha')),
    );
    expect(find.byIcon(Icons.call_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.call_outlined));
    await tester.pump();
    await tester.pump();
    expect(find.byType(CallPage), findsOneWidget);
    final context = tester.element(find.byType(CallPage));
    expect(ModalRoute.of(context)!.settings.name, callRouteName);
    expect(connector.calls, 1);
    container.read(activeCallProvider)?.dispose(); // invariant check precedes tearDown
  });

  testWidgets('(2) sessions picker: standalone first, sessions below', (tester) async {
    await boot(tester, const SessionsPage());
    expect(find.byKey(const ValueKey('sessions.call')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sessions.call')));
    await tester.pumpAndSettle();
    final tiles = tester.widgetList<ListTile>(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(ListTile),
      ),
    ).toList();
    expect(tiles.first.key, const ValueKey('call.pick.standalone'));
    expect(find.text(t(MessageKey.callStandalone)), findsOneWidget);
    // SessionsPage list rows sit behind the sheet and repeat the name —
    // scope to the picker itself.
    expect(find.descendant(of: find.byType(BottomSheet), matching: find.text('Alpha')), findsOneWidget);
    expect(find.byKey(const ValueKey('call.settings.picker')), findsOneWidget);
  });

  testWidgets('(3) row sheet carries the call row', (tester) async {
    await boot(tester, const SessionsPage());
    await tester.tap(find.byKey(const ValueKey('menu-a')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sessions.row.call')), findsOneWidget);
  });

  testWidgets('(4) a running call is reopened, never re-dialed', (tester) async {
    await boot(tester, const SessionsPage());
    final audio = FakeCallAudio();
    madeAudio.add(audio);
    final first = CallController(
      target: const StandaloneCallTarget(),
      url: Uri.parse('ws://test.invalid/'),
      token: 'tk',
      connect: connector.call,
      audio: audio,
    );
    container.read(activeCallProvider.notifier).set(first);
    await tester.tap(find.byKey(const ValueKey('sessions.call')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('call.pick.standalone')));
    await tester.pump();
    await tester.pump();
    expect(find.byType(CallPage), findsOneWidget);
    expect(connector.calls, 0); // the existing controller owns the wire
    // invariant check precedes tearDown — dispose in-body or the ready timer pends
    container.read(activeCallProvider)?.dispose();
  });

  testWidgets('(5) ChatPage keeps exactly one String popup menu', (tester) async {
    await boot(tester, ChatPage(session: row('a', 'Alpha')));
    expect(find.byType(PopupMenuButton<String>), findsOneWidget);
  });

  testWidgets('(6) an ended call is disposed and replaced, not reopened', (tester) async {
    await boot(tester, const SessionsPage());
    final audio = FakeCallAudio();
    madeAudio.add(audio);
    final stale = CallController(
      target: const StandaloneCallTarget(),
      url: Uri.parse('ws://test.invalid/'),
      token: 'tk',
      connect: connector.call,
      audio: audio,
    );
    container.read(activeCallProvider.notifier).set(stale);
    await stale.hangUp(); // ended already (e.g. back-popped earlier)
    await tester.tap(find.byKey(const ValueKey('sessions.call')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('call.pick.standalone')));
    await tester.pump();
    await tester.pump();
    expect(connector.calls, 1);
    expect(find.byType(CallPage), findsOneWidget);
    expect(container.read(activeCallProvider)?.state.phase, isNot(CallPhase.ended));
    container.read(activeCallProvider)?.dispose(); // invariant check precedes tearDown
  });
}
