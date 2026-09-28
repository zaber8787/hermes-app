import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/auto_wake.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/features/settings/settings_page.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/providers.dart';

import 'support/localized_app.dart';

// APPWAKE D: the surfaces — settings toggle (off default, capability-gated),
// session opt-out, and the chat-page hints.
class WakeUiRepo extends HermesRepository {
  WakeUiRepo({this.offer = true}) : super('http://test.invalid', 'fake');
  bool offer;
  List<Message> history = [];
  final _events = <String, StreamController<SseEvent>>{};
  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async =>
      {'id': sid, 'message_count': 0};
  @override
  Future<List<Message>> messages(String sid, {int offset = 0, int limit = 200}) async =>
      history;
  @override
  Future<Map<String, dynamic>> autoWakeCapability() async => {
    'features': {
      if (offer)
        'auto_wake': {
          'enabled': true,
          'canonical_input': AutoWakeContract.canonicalInput,
          'batch_max': 10,
        },
    },
  };
  @override
  Future<Map<String, dynamic>?> autoWakeFeature() async =>
      offer ? {'enabled': true} : null;
  @override
  Stream<SseEvent> chat(String sid, String input, {String? wakeBatch}) {
    final c = _events.putIfAbsent(sid, StreamController<SseEvent>.new);
    return c.stream;
  }

  @override
  void cancelStream(String sid) {
    final c = _events.remove(sid);
    if (c != null && !c.isClosed) unawaited(c.close());
  }

  void closeAll() {
    for (final c in _events.values) {
      if (!c.isClosed) unawaited(c.close());
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const url = 'http://test.invalid';
  late LocalStore store;
  late WakeUiRepo repo;
  late List<Override> overrides;

  Future<void> boot({bool offer = true}) async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    repo = WakeUiRepo(offer: offer);
    overrides = [
      localStoreProvider.overrideWithValue(store),
      initialSettingsProvider.overrideWithValue(
        const AppSettings(url: url, key: 'fake'),
      ),
      repositoryProvider.overrideWithValue(repo),
      skillsProvider.overrideWith((ref) async => []),
    ];
  }

  tearDown(() {
    repo.closeAll();
    repo.close();
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 2200);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      localizedApp(const SettingsPage(), overrides: overrides),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
  }

  Future<void> openChat(WidgetTester tester) async {
    await tester.pumpWidget(
      localizedApp(
        ChatPage(
          session: Session(
            id: 's',
            title: 'A',
            count: 1,
            startedAt: 0,
            activity: 0,
            source: 'api_server',
          ),
        ),
        overrides: overrides,
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  test('auto-wake ships OFF: no stored preference means disabled', () async {
    await boot();
    expect(store.autoWakeEnabled(url), isFalse);
    expect(store.autoWakeSessionOff(url, 's'), isFalse);
  });

  testWidgets('settings toggle: default off; enabling persists', (tester) async {
    await boot();
    await pumpSettings(tester);
    final sw = find.byType(SwitchListTile);
    expect(sw, findsOneWidget);
    expect(tester.widget<SwitchListTile>(sw).value, isFalse);
    await tester.tap(find.byKey(const ValueKey('settings.autoWake.switch')));
    await tester.pump();
    expect(store.autoWakeEnabled(url), isTrue);
    expect(tester.widget<SwitchListTile>(sw).value, isTrue);
  });

  testWidgets('pure server: toggle is OFF, inert, and says why', (tester) async {
    await boot(offer: false);
    await pumpSettings(tester);
    final sw = find.byType(SwitchListTile);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(sw).onChanged, isNull);
    expect(tester.widget<SwitchListTile>(sw).value, isFalse);
    expect(
      find.byKey(const ValueKey('settings.autoWake.unavailable')),
      findsOneWidget,
    );
  });

  testWidgets('session menu offers the opt-out only when offered', (
    tester,
  ) async {
    await boot();
    store.setAutoWakeEnabled(url, true);
    await openChat(tester);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('Pause auto-read in this session'), findsOneWidget);
    await tester.tap(find.text('Pause auto-read in this session'));
    await tester.pumpAndSettle();
    expect(store.autoWakeSessionOff(url, 's'), isTrue);
  });

  testWidgets('pure server session menu stays silent', (tester) async {
    await boot(offer: false);
    store.setAutoWakeEnabled(url, true);
    await openChat(tester);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.textContaining('auto-read'), findsNothing);
  });

  testWidgets('queued reports surface the waiting hint', (tester) async {
    await boot();
    store.setAutoWakeEnabled(url, true);
    await store.saveWakeState(url, 's', {
      'armedAt': '2026-09-27T12:00:00.000Z',
      'cutoffOrder': 1,
      'lastSeenOrder': 1,
      'orderUncertain': false,
      'queued': [
        {'id': '2', 'dk': 'a' * 64, 'order': 2},
        {'id': '3', 'dk': 'b' * 64, 'order': 3},
      ],
      'ignoredKeys': <String>[],
      'batches': <Map<String, dynamic>>[],
    });
    await openChat(tester);
    // The 1s debounce may already be trying; the menu/admit is honest
    // either way — this test only reads the HINT.
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('chat.wakeHint')), findsOneWidget);
    expect(find.textContaining('Schedule reports waiting: 2'), findsOneWidget);
  });

  testWidgets('session opt-out hides the hint', (tester) async {
    await boot();
    store.setAutoWakeEnabled(url, true);
    store.setAutoWakeSessionOff(url, 's', true);
    await store.saveWakeState(url, 's', {
      'armedAt': '2026-09-27T12:00:00.000Z',
      'cutoffOrder': 1,
      'lastSeenOrder': 1,
      'orderUncertain': false,
      'queued': [
        {'id': '2', 'dk': 'a' * 64, 'order': 2},
      ],
      'ignoredKeys': <String>[],
      'batches': <Map<String, dynamic>>[],
    });
    await openChat(tester);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('chat.wakeHint')), findsNothing);
  });
}
