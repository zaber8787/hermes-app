// TASK-WEBUX2-01 Ticket B: an unreachable station, a relayed gateway 504 and
// a rejected key must land as three identifiable outcomes (err-unreachable /
// err-upstream / err-token + a bounded 1s/2s/4s retry on the token-submit
// path), and a fresh profile must re-enter the token with zero mouse: the
// key field is focused on arrival and Enter saves.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/transport.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/features/settings/key_vault.dart';
import 'package:hermes_app/features/settings/settings_page.dart';
import 'package:hermes_app/providers.dart';

import 'support/localized_app.dart';

const url = 'http://test.invalid';

class MapVault implements KeyVault {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

/// Idle repo for provider wiring only; the tested instance is injected via
/// SettingsPage.repositoryFactory.
class _NullRepo extends HermesRepository {
  _NullRepo() : super(url, 'fake');
  @override
  Future<Map<String, dynamic>?> autoWakeFeature() async => null;
}

/// Mode-driven port for the connection test. 'timeout' throws PortTimeout,
/// 'gw504' answers 504, 'auth401' answers 401; capabilities calls are counted.
class _ModePort implements HttpPort {
  _ModePort(this.mode);
  final String mode;
  int capabilitiesCalls = 0;

  @override
  Future<PortResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Stream<List<int>>? body,
    int? contentLength,
    Future<void>? abortTrigger,
    Duration? headersTimeout,
    DispatchObservation? observation,
  }) async {
    if (uri.path == '/v1/capabilities') {
      capabilitiesCalls++;
      if (mode == 'timeout') throw const PortTimeout();
      if (mode == 'gw504') return _resp(504, {'error': 'gateway timeout'});
      if (mode == 'auth401') return _resp(401, {'error': 'bad key'});
      return _resp(200, {
        'auth': {'required': true},
        'features': {'session_chat_streaming': true},
      });
    }
    return _resp(200, {'ok': true});
  }

  static PortResponse _resp(int status, Map<String, Object> body) =>
      PortResponse(
        status,
        {'content-type': 'application/json'},
        Stream.value(utf8.encode(jsonEncode(body))),
      );

  @override
  void close() {}
}

Future<ProviderContainer> _boot(
  WidgetTester tester,
  _ModePort port, {
  AppSettings initial = const AppSettings(url: url, key: 'fake'),
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final store = LocalStore(await SharedPreferences.getInstance(),
      vault: MapVault());
  final container = ProviderContainer(
    overrides: [
      repositoryProvider.overrideWithValue(_NullRepo()),
      localStoreProvider.overrideWithValue(store),
      initialSettingsProvider.overrideWith((ref) => initial),
    ],
  );
  addTearDown(container.dispose);
  // The page is a lazy ListView: at the default 800x600 test surface the key
  // field never builds. A tall surface makes every child real at once.
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: localizedWrap(
        SettingsPage(repositoryFactory: (u, k) =>
            HermesRepository(u, k, port: port)),
      ),
    ),
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
  return container;
}

Future<void> _runConnectionTest(WidgetTester tester) async {
  final button = find.text('Test connection');
  await tester.scrollUntilVisible(
      button, 300, scrollable: find.byType(Scrollable).first);
  await tester.tap(button);
  await tester.pump();
  // Bounded ladder: first attempt + 3 retries at 1s/2s/4s. pumpAndSettle is
  // forbidden here: it would spin on the retry timers themselves.
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 2));
  await tester.pump(const Duration(seconds: 4));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('webux2 B: headers timeout names err-unreachable and retries',
      (tester) async {
    final port = _ModePort('timeout');
    await _boot(tester, port);
    await _runConnectionTest(tester);
    expect(find.byKey(const ValueKey('err-unreachable')), findsOneWidget);
    expect(find.byKey(const ValueKey('retry-button')), findsOneWidget);
    // First attempt + the ticket-fixed ladder of three retries.
    expect(port.capabilitiesCalls, 4);
  });

  testWidgets('webux2 B: relayed 504 names err-upstream and retries',
      (tester) async {
    final port = _ModePort('gw504');
    await _boot(tester, port);
    await _runConnectionTest(tester);
    expect(find.byKey(const ValueKey('err-upstream')), findsOneWidget);
    expect(find.byKey(const ValueKey('retry-button')), findsOneWidget);
    expect(port.capabilitiesCalls, 4);
  });

  testWidgets('webux2 B: a rejected key names err-token and never retries',
      (tester) async {
    final port = _ModePort('auth401');
    await _boot(tester, port);
    await _runConnectionTest(tester);
    expect(find.byKey(const ValueKey('err-token')), findsOneWidget);
    expect(find.text('Key rejected'), findsOneWidget);
    expect(find.byKey(const ValueKey('retry-button')), findsNothing);
    expect(port.capabilitiesCalls, 1);
  });

  testWidgets('webux2 B: Enter in the key field saves the token',
      (tester) async {
    final port = _ModePort('ok');
    final container = await _boot(
      tester,
      port,
      // Fresh profile: the settings page opens blank.
      initial: const AppSettings(),
    );
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), url);
    await tester.pump();
    await tester.enterText(fields.at(1), 'tok-webux2');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(container.read(settingsProvider).key, 'tok-webux2');
  });

  testWidgets('webux2 B: a blank token focuses the key field on arrival',
      (tester) async {
    await _boot(tester, _ModePort('ok'), initial: const AppSettings());
    final editable = find.byType(EditableText);
    expect(editable, findsNWidgets(2));
    final keyField = tester.widget<EditableText>(editable.at(1));
    expect(keyField.focusNode.hasFocus, isTrue);
  });
}
