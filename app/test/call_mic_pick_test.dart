import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/features/call/call_audio.dart';
import 'package:hermes_app/features/call/call_controller.dart';
import 'package:hermes_app/features/call/call_page.dart';
import 'package:hermes_app/features/call/call_providers.dart';
import 'package:hermes_app/features/call/call_settings.dart';
import 'package:hermes_app/features/call/call_state.dart';
import 'package:hermes_app/features/settings/key_vault.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'package:hermes_app/l10n/app_strings.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';
import 'package:hermes_app/providers.dart';

import 'support/call_fakes.dart';
import 'support/localized_app.dart';

// TASK-MICPICK R5: input enumeration filter, deviceId persistence, the
// vanished-device fallback, and the in-call switch that must NOT touch the
// socket (counter-proof: reconnect count stays 0).

class MapVault implements KeyVault {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

const usb = AudioInputDevice(id: 'usb-1', label: 'USB Interface');
const headset = AudioInputDevice(id: 'hs-2', label: '');

List<MessageKey> systemKeys(CallState s) => [
  for (final c in s.captions)
    if (c.role == CaptionRole.system && c.system is UiLocal)
      (c.system! as UiLocal).key,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('filterAudioInputs (R1)', () {
    test('keeps real audio inputs only, in platform order', () {
      final out = filterAudioInputs([
        (kind: 'audioinput', id: 'default', label: 'Default - Built-in'),
        (kind: 'audioinput', id: 'communications', label: 'Comms'),
        (kind: 'audioinput', id: 'mac-1', label: ' Built-in Mic '),
        (kind: 'audiooutput', id: 'spk-1', label: 'Speakers'),
        (kind: 'videoinput', id: 'cam-1', label: 'FaceTime HD'),
        (kind: 'audioinput', id: '', label: ''), // pre-permission anonymous
        (kind: 'audioinput', id: 'usb-1', label: 'USB Interface'),
        (kind: 'audioinput', id: 'mac-1', label: 'Built-in Mic'), // dup id
      ]);
      expect(out, const [
        AudioInputDevice(id: 'mac-1', label: 'Built-in Mic'),
        AudioInputDevice(id: 'usb-1', label: 'USB Interface'),
      ]);
    });

    test('an all-anonymous (no permission) dump is an empty list', () {
      expect(
        filterAudioInputs([
          (kind: 'audioinput', id: '', label: ''),
          (kind: 'audioinput', id: '', label: ''),
        ]),
        isEmpty,
      );
    });

    test('unlabeled devices are numbered by position', () {
      final en = AppStrings.forLocale(AppLocale.en);
      final zh = AppStrings.forLocale(AppLocale.zhHant);
      expect(micDisplayName(en, usb, 0), 'USB Interface');
      expect(micDisplayName(en, headset, 1), 'Microphone 2');
      expect(micDisplayName(zh, headset, 2), '麥克風 3');
    });
  });

  group('resolveInputDevice (R4)', () {
    test('present id is kept; vanished / empty / null → system default', () {
      expect(resolveInputDevice('usb-1', const [usb, headset]), 'usb-1');
      expect(resolveInputDevice('ghost', const [usb, headset]), isNull);
      expect(resolveInputDevice('usb-1', const []), isNull);
      expect(resolveInputDevice('', const [usb]), isNull);
      expect(resolveInputDevice(null, const [usb]), isNull);
    });
  });

  group('LocalStore voice.mic (R2)', () {
    test('deviceId round-trips through prefs; null/empty clears', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = LocalStore(prefs, vault: MapVault());
      expect(store.voiceMicId(), isNull);
      await store.saveVoiceMicId('usb-1');
      expect(store.voiceMicId(), 'usb-1');
      // a fresh store over the same prefs (next app start) reads it back
      expect(LocalStore(prefs, vault: MapVault()).voiceMicId(), 'usb-1');
      await store.saveVoiceMicId('');
      expect(store.voiceMicId(), isNull);
      await store.saveVoiceMicId('hs-2');
      await store.saveVoiceMicId(null);
      expect(prefs.containsKey('voice.mic'), isFalse);
    });
  });

  group('CallController input selection', () {
    late FakeConnector connector;
    late FakeCallAudio audio;
    late List<Duration> waits;
    late List<String?> saved;
    late CallController controller;

    CallController make({String? inputDeviceId}) {
      connector = FakeConnector();
      audio = FakeCallAudio()..inputs = const [usb, headset];
      waits = [];
      saved = [];
      return CallController(
        target: const StandaloneCallTarget(),
        url: Uri.parse('ws://test.invalid/'),
        token: 'tk-1',
        connect: connector.call,
        audio: audio,
        delay: (d) {
          waits.add(d);
          return Future.value();
        },
        inputDeviceId: inputDeviceId,
        saveInputDevice: (id) async => saved.add(id),
      );
    }

    Future<void> startConnected() async {
      await controller.start();
      connector.sockets.last.emit(kReadyJson);
      await pumpEventQueue();
    }

    /// The R5 counter-proof: one dial, the socket never closed, no backoff
    /// scheduled, attempt counter untouched.
    void expectNoReconnect() {
      expect(connector.calls, 1, reason: 'reconnect count must stay 0');
      expect(connector.sockets, hasLength(1));
      expect(connector.sockets.single.closeCalledWith, isNull);
      expect(waits, isEmpty);
      expect(controller.state.attempt, 0);
    }

    setUp(() => controller = make());
    tearDown(() async {
      controller.dispose();
      await audio.dispose();
    });

    test('call start opens the saved device when it is present (R2)', () async {
      controller = make(inputDeviceId: 'usb-1');
      await startConnected();
      expect(audio.startDeviceIds, ['usb-1']);
      expect(controller.inputDeviceId, 'usb-1');
      expect(systemKeys(controller.state), isNot(contains(MessageKey.callMicFallback)));
    });

    test('no saved device = system default, no deviceId constraint', () async {
      await startConnected();
      expect(audio.startDeviceIds, [null]);
      expect(controller.inputDeviceId, isNull);
    });

    test('injected nonexistent device falls back to default + hint (R4)', () async {
      controller = make(inputDeviceId: 'ghost-9');
      await startConnected();
      expect(audio.startDeviceIds, [null]);
      expect(controller.inputDeviceId, isNull);
      expect(controller.state.phase, CallPhase.connected);
      expect(systemKeys(controller.state), contains(MessageKey.callMicFallback));
    });

    test('a listed device that fails to open also falls back (R4)', () async {
      controller = make(inputDeviceId: 'usb-1');
      audio.failingInputs = {'usb-1'};
      await startConnected();
      expect(audio.startDeviceIds, ['usb-1', null]);
      expect(controller.inputDeviceId, isNull);
      expect(controller.state.phase, CallPhase.connected);
      expect(systemKeys(controller.state), contains(MessageKey.callMicFallback));
    });

    test('Android-like platform (no enumeration) never crashes (R4)', () async {
      controller = make(inputDeviceId: 'usb-1');
      audio.inputs = const [];
      await startConnected();
      expect(audio.startDeviceIds, [null]);
      expect(await controller.listInputs(), isEmpty);
    });

    test('in-call switch restarts capture only: reconnect count 0 (R3)', () async {
      await startConnected();
      audio.pushFrame(frame(1));
      await pumpEventQueue();

      expect(await controller.switchInput('usb-1'), isTrue);
      await pumpEventQueue();

      expect(audio.switches, ['usb-1']);
      expect(audio.starts, 1, reason: 'no full audio restart either');
      expect(audio.stopped, isFalse);
      expect(controller.inputDeviceId, 'usb-1');
      expect(controller.state.phase, CallPhase.connected);
      expectNoReconnect();
      // the same socket keeps carrying the new device's frames
      audio.pushFrame(frame(2));
      await pumpEventQueue();
      expect(connector.sockets.single.sentFrames, [frame(1), frame(2)]);
      // remembered for next call, and the spoken-style confirmation line
      expect(saved, ['usb-1']);
      expect(systemKeys(controller.state), contains(MessageKey.callMicSwitched));
    });

    test('switch while muted keeps muted and the socket (R3)', () async {
      await startConnected();
      controller.toggleMute();
      expect(await controller.switchInput('hs-2'), isTrue);
      expect(controller.state.phase, CallPhase.muted);
      expectNoReconnect();
    });

    test('failed switch keeps the old device, saves nothing (R3)', () async {
      controller = make(inputDeviceId: 'usb-1');
      await startConnected();
      audio.failingInputs = {'hs-2'};
      expect(await controller.switchInput('hs-2'), isFalse);
      expect(controller.inputDeviceId, 'usb-1');
      expect(audio.liveInput, 'usb-1');
      expect(saved, isEmpty);
      expect(systemKeys(controller.state), isNot(contains(MessageKey.callMicSwitched)));
      expectNoReconnect();
    });

    test('switch before audio is live is refused, not queued', () async {
      await controller.start(); // connecting, no ready yet
      expect(await controller.switchInput('usb-1'), isFalse);
      expect(audio.switches, isEmpty);
    });

    test('unplugged mid-call → system default + hint, call stays up (R4)', () async {
      controller = make(inputDeviceId: 'usb-1');
      await startConnected();
      audio.pushSignal(const InputLost());
      await pumpEventQueue();
      expect(audio.switches, [null]);
      expect(controller.inputDeviceId, isNull);
      expect(systemKeys(controller.state), contains(MessageKey.callMicFallback));
      expect(saved, isEmpty, reason: 're-plugging restores it next call');
      expectNoReconnect();
    });
  });

  group('CallSettingsDialog mic picker (R1/R2/R4)', () {
    Future<LocalStore> pumpDialog(
      WidgetTester tester,
      FakeCallAudio probe, {
      Map<String, Object> prefs = const {},
    }) async {
      SharedPreferences.setMockInitialValues(prefs);
      final store = LocalStore(
        await SharedPreferences.getInstance(),
        vault: MapVault(),
      );
      await tester.pumpWidget(localizedHome(
        home: Scaffold(
          body: CallSettingsDialog(
            store: store,
            serverUrl: 'http://127.0.0.1:8700',
            audioFactory: () => probe,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return store;
    }

    testWidgets('no permission → "visible after granting", picker disabled',
        (tester) async {
      final probe = FakeCallAudio()
        ..permission = MicPermission.denied
        ..inputs = const [usb];
      await pumpDialog(tester, probe);
      expect(find.text(t(MessageKey.callMicNeedsPermission)), findsOneWidget);
      expect(find.text('USB Interface'), findsNothing);
      expect(probe.stopped, isTrue, reason: 'probe never keeps the mic');
      await probe.dispose();
    });

    testWidgets('granted → devices listed, unlabeled one numbered; pick saves',
        (tester) async {
      final probe = FakeCallAudio()..inputs = const [usb, headset];
      final store = await pumpDialog(tester, probe);
      expect(probe.stopped, isTrue);
      await tester.tap(find.byKey(const ValueKey('call.settings.mic')));
      await tester.pumpAndSettle();
      expect(find.text('USB Interface'), findsWidgets);
      expect(find.text(t(MessageKey.callMicNumbered, args: {'n': 2})),
          findsWidgets);
      await tester.tap(find.text('USB Interface').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('call.settings.save')));
      await tester.pumpAndSettle();
      expect(store.voiceMicId(), 'usb-1');
      await probe.dispose();
    });

    testWidgets('saved device gone → shows default + hint, no crash, kept',
        (tester) async {
      final probe = FakeCallAudio()..inputs = const [usb];
      final store =
          await pumpDialog(tester, probe, prefs: {'voice.mic': 'ghost-9'});
      expect(tester.takeException(), isNull);
      expect(find.text(t(MessageKey.callMicDefault)), findsOneWidget);
      expect(find.text(t(MessageKey.callMicFallback)), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('call.settings.save')));
      await tester.pumpAndSettle();
      expect(store.voiceMicId(), 'ghost-9', reason: 'untouched unless picked');
      await probe.dispose();
    });

    testWidgets('platform with no list → only the default item',
        (tester) async {
      final probe = FakeCallAudio();
      await pumpDialog(tester, probe);
      await tester.tap(find.byKey(const ValueKey('call.settings.mic')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('call.settings.mic.default')),
          findsWidgets);
      expect(tester.takeException(), isNull);
      await probe.dispose();
    });
  });

  group('CallPage quick switch (R3)', () {
    Future<(CallController, FakeConnector, FakeCallAudio)> boot(
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(
        await SharedPreferences.getInstance(),
        vault: MapVault(),
      );
      final connector = FakeConnector();
      final audio = FakeCallAudio()..inputs = const [usb, headset];
      final controller = CallController(
        target: const StandaloneCallTarget(),
        url: Uri.parse('ws://test.invalid/'),
        token: 'tk',
        connect: connector.call,
        audio: audio,
        delay: (d) => Future.value(),
      );
      final container = ProviderContainer(
        overrides: [
          localStoreProvider.overrideWithValue(store),
          initialSettingsProvider.overrideWithValue(
            const AppSettings(url: 'http://test.invalid', key: 'k'),
          ),
          gatewayConnectorProvider.overrideWithValue(connector.call),
          callAudioFactoryProvider.overrideWithValue(() => audio),
        ],
      );
      container.read(activeCallProvider.notifier).set(controller);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: localizedWrap(const CallPage()),
      ));
      await controller.start();
      connector.sockets.last.emit(kReadyJson);
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        container.dispose();
        await audio.dispose();
      });
      return (controller, connector, audio);
    }

    testWidgets('mic button lists inputs; tap switches without redial',
        (tester) async {
      final (controller, connector, audio) = await boot(tester);
      await tester.tap(find.byKey(const ValueKey('call.micPick')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('call.micPicker.default')), findsOneWidget);
      expect(find.text('USB Interface'), findsOneWidget);
      expect(find.text(t(MessageKey.callMicNumbered, args: {'n': 2})),
          findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('call.micPicker.usb-1')));
      await tester.pumpAndSettle();
      expect(audio.switches, ['usb-1']);
      expect(controller.inputDeviceId, 'usb-1');
      expect(connector.calls, 1, reason: 'reconnect count must stay 0');
      expect(connector.sockets.single.closeCalledWith, isNull);
      expect(find.text(t(MessageKey.callMicSwitched)), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose(); // ping timers must be gone before the body ends
    });

    testWidgets('failed switch → toast, old device stays', (tester) async {
      final (controller, connector, audio) = await boot(tester);
      audio.failingInputs = {'hs-2'};
      await tester.tap(find.byKey(const ValueKey('call.micPick')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('call.micPicker.hs-2')));
      await tester.pump();
      await tester.pump();
      expect(find.text(t(MessageKey.callMicSwitchFailed)), findsOneWidget);
      expect(controller.inputDeviceId, isNull);
      expect(connector.calls, 1);
      await tester.pumpWidget(const SizedBox());
      controller.dispose(); // ping timers must be gone before the body ends
    });
  });
}
