import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/features/call/call_controller.dart';
import 'package:hermes_app/features/call/call_entry.dart';
import 'package:hermes_app/features/call/call_page.dart';
import 'package:hermes_app/features/call/call_providers.dart';
import 'package:hermes_app/features/call/call_state.dart';
import 'package:hermes_app/features/settings/key_vault.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/providers.dart';

import 'support/call_fakes.dart';
import 'support/localized_app.dart';

// PLAN-VOICEUI §6.2 call_page_test: the page is a pure projection of
// CallController.state — so the rig is one real controller over the fake
// socket/audio, exactly what openCall builds in production.

class MapVault implements KeyVault {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

Session alpha() => const Session(
  id: 's1',
  title: 'Alpha',
  count: 1,
  startedAt: 0,
  activity: 0,
  source: 'api_server',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late CallController controller;
  late FakeConnector connector;
  late FakeCallAudio audio;

  Future<CallController> boot(
    WidgetTester tester, {
    CallTarget? target,
    List<Override> extraOverrides = const [],
  }) async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(
      await SharedPreferences.getInstance(),
      vault: MapVault(),
    );
    final fakeConnector = FakeConnector();
    connector = fakeConnector;
    final fakeAudio = FakeCallAudio();
    audio = fakeAudio;
    final own = CallController(
      target: target ?? SessionCallTarget(alpha()),
      url: Uri.parse('ws://test.invalid/'),
      token: 'tk',
      connect: fakeConnector.call,
      audio: fakeAudio,
      // FakeAsync cannot advance a real Future.delayed backoff; pumpEventQueue
      // then wedges forever on the reconnect path (hang in case (2)). Same
      // immediate-resolve injection call_controller_test.dart uses.
      delay: (d) => Future.value(),
    );
    controller = own;
    final ownContainer = ProviderContainer(
      overrides: [
        localStoreProvider.overrideWithValue(store),
        initialSettingsProvider.overrideWithValue(
          const AppSettings(url: 'http://test.invalid', key: 'k'),
        ),
        gatewayConnectorProvider.overrideWithValue(fakeConnector.call),
        callAudioFactoryProvider.overrideWithValue(() => fakeAudio),
        ...extraOverrides,
      ],
    );
    container = ownContainer;
    ownContainer.read(activeCallProvider.notifier).set(own);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: ownContainer,
        child: localizedWrap(const CallPage()),
      ),
    );
    await own.start();
    await tester.pump();
    addTearDown(() async {
      own.dispose();
      ownContainer.dispose();
      await fakeAudio.dispose();
    });
    return own;
  }

  Future<void> connect(WidgetTester tester) async {
    connector.sockets.last.emit(kReadyJson);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
  }

  /// Unmounts AND releases the controller — flutter_test's pending-timer
  /// invariant runs before tearDown, so the 5s ready timer must be gone
  /// by the time the test body returns.
  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  }

  testWidgets('(1) bound title, and the standalone label', (tester) async {
    await boot(tester);
    expect(find.byKey(const ValueKey('call.title')), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    await teardown(tester);

    await boot(tester, target: const StandaloneCallTarget());
    expect(find.text(t(MessageKey.callStandalone)), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('(2) every phase renders its status line', (tester) async {
    await boot(tester);
    expect(
      find.text(t(MessageKey.callStatusConnecting)),
      findsOneWidget,
    ); // connecting (attempt 0)
    await connect(tester);
    expect(find.text(t(MessageKey.callStatusConnected)), findsOneWidget);
    controller.toggleMute();
    await tester.pump();
    expect(find.text(t(MessageKey.callStatusMuted)), findsOneWidget);
    controller.toggleMute();
    await tester.pump();
    await connector.sockets.last.peerClose(1006);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
    expect(
      find.text(t(MessageKey.callStatusReconnecting, args: {'n': 1})),
      findsOneWidget,
    );
    await controller.hangUp();
    await tester.pump();
    expect(find.text(t(MessageKey.callStatusEnded)), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('(3) brain indicator: pending bar, then queued wording', (tester) async {
    await boot(tester);
    expect(find.byKey(const ValueKey('call.brainBar')), findsNothing);
    await connect(tester);
    connector.sockets.last.emit(eventJson('route', {'turn': 1, 'route': 'brain'}));
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
    expect(find.byKey(const ValueKey('call.brainBar')), findsOneWidget);
    connector.sockets.last.emit(
      eventJson('brain_queued', {
        'turn': 1,
        'reason': 'voice_turn_ahead',
        'active': 1,
      }),
    );
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
    expect(find.text(t(MessageKey.callBrainQueuedVoice)), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('(4) filler audio_start shows its text under the bar', (tester) async {
    await boot(tester);
    await connect(tester);
    connector.sockets.last.emit(
      eventJson('audio_start', {'kind': 'filler', 'text': 'Hmm, one moment.', 'ms': 30}),
    );
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
    expect(find.byKey(const ValueKey('call.fillerHint')), findsOneWidget);
    expect(find.text('Hmm, one moment.'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('(5) mute button zeroes the uplink and swaps its icon', (tester) async {
    await boot(tester);
    await connect(tester);
    expect(find.byIcon(Icons.mic), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('call.mute')));
    await tester.pump();
    expect(find.byIcon(Icons.mic_off), findsOneWidget);
    audio.pushFrame(frame(42));
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
    expect(isSilent(connector.sockets.last.sentFrames.last), isTrue);
    await teardown(tester);
  });

  testWidgets('(6) hang up lands on ended with a close button', (tester) async {
    await boot(tester);
    await connect(tester);
    await tester.tap(find.byKey(const ValueKey('call.hangup')));
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
    expect(controller.state.phase, CallPhase.ended);
    expect(find.byKey(const ValueKey('call.close')), findsOneWidget);
    expect(find.byKey(const ValueKey('call.hangup')), findsNothing);
    await teardown(tester);
  });

  testWidgets('(6b) close clears the single-call registry', (tester) async {
    await boot(tester);
    await connect(tester);
    await tester.tap(find.byKey(const ValueKey('call.hangup')));
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('call.close')));
    await tester.pumpAndSettle();
    expect(container.read(activeCallProvider), isNull);
    await teardown(tester);
  });

  testWidgets('(7) gatewayDown shows its copy and a retry button', (tester) async {
    await boot(tester);
    // no ready sent: the FIRST socket dying before ever connecting is the
    // gatewayDown branch (§4.2, everConnected = false, attempt 0):
    await connector.sockets.last.peerClose(1006);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
    expect(
      find.text(t(MessageKey.callGatewayDown)),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('call.retry')), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('(8) unsupported platforms render no call button', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.pumpWidget(
      localizedApp(const CallButton(target: StandaloneCallTarget())),
    );
    expect(find.byType(IconButton), findsNothing);
    expect(find.byIcon(Icons.call_outlined), findsNothing);
    // invariant check runs before tearDown — reset in-body, addTearDown is too late
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('(9) orb + captions exist and caption lines paint', (tester) async {
    await boot(tester);
    await connect(tester);
    expect(find.byKey(const ValueKey('call.orb')), findsOneWidget);
    expect(find.byKey(const ValueKey('call.captions')), findsOneWidget);
    connector.sockets.last.emit(eventJson('reply_text', {'turn': 1, 'source': 'front', 'text': 'Hello.'}));
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
    expect(find.text('Hello.'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('(10) error phase swaps the control bar', (tester) async {
    await boot(tester);
    await connect(tester);
    await connector.sockets.last.peerClose(4401);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
    expect(find.byKey(const ValueKey('call.hangup')), findsNothing);
    expect(find.byKey(const ValueKey('call.mute')), findsNothing);
    expect(find.byKey(const ValueKey('call.retry')), findsOneWidget);
    expect(find.byKey(const ValueKey('call.close')), findsOneWidget);
    await teardown(tester);
  });
}
