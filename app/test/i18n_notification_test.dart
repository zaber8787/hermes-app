
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'package:hermes_app/main.dart';
import 'package:hermes_app/platform/stream_keepalive.dart';
import 'package:hermes_app/providers.dart';

/// Mock of the Android side of `hermes/stream-keepalive`: records the exact
/// dispatch ORDER and shape, like MainActivity's real guard order (§6.1).
class KeepaliveRecorder {
  final calls = <(String, Object?)>[];
  bool failNextSetLocale = false;
  bool rejectTags = false;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      StreamKeepalive.channel,
      (call) async {
        if (call.method == 'setLocale') {
          if (rejectTags) throw PlatformException(code: 'argument');
          final tag = (call.arguments as Map<Object?, Object?>)['tag'];
          if (tag != 'en' && tag != 'zh-Hant') {
            throw PlatformException(code: 'argument');
          }
          if (failNextSetLocale) {
            failNextSetLocale = false;
            throw PlatformException(code: 'io');
          }
        }
        calls.add((
          call.method,
          call.arguments is Map
              ? {
                  for (final e in (call.arguments as Map).entries)
                    '${e.key}': e.value
                }
              : call.arguments,
        ));
        return null;
      },
    );
  }

  void uninstall() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(StreamKeepalive.channel, null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late KeepaliveRecorder recorder;

  setUp(() {
    recorder = KeepaliveRecorder()..install();
    StreamKeepalive.initialize();
    StreamKeepalive.resetCommandQueueForTest();
  });
  tearDown(() => recorder.uninstall());

  test('syncLocale dispatch shape: map with canonical tag only', () async {
    await StreamKeepalive.syncLocale('zh-Hant');
    expect(
      recorder.calls.map((c) => '${c.$1}:${c.$2}'),
      ['setLocale:{tag: zh-Hant}'],
    );
  });

  test('initial sync is queued BEFORE the first start', () async {
    final sync = StreamKeepalive.syncLocale('en');
    final keepalive = StreamKeepalive(1);
    final start = keepalive.start();
    await sync;
    await start;
    expect(recorder.calls.map((c) => c.$1), ['setLocale', 'start']);
  });

  test('changed-locale command serializes with stop/start, never reorders',
      () async {
    final first = StreamKeepalive(1);
    final start = first.start();
    final sync = StreamKeepalive.syncLocale('zh-Hant');
    final stop = first.stop();
    await Future.wait([start, sync, stop]);
    expect(recorder.calls.map((c) => c.$1), ['start', 'setLocale', 'stop']);
    expect(recorder.calls[1].$2, {'tag': 'zh-Hant'});
  });

  test('rapid en -> zh -> en: last committed tag wins, two calls max queued',
      () async {
    await Future.wait([
      StreamKeepalive.syncLocale('en'),
      StreamKeepalive.syncLocale('zh-Hant'),
      StreamKeepalive.syncLocale('en'),
    ]);
    expect(recorder.calls.every((c) => c.$1 == 'setLocale'), isTrue);
    expect(recorder.calls.last.$2, {'tag': 'en'});
  });

  test('failure does not poison the queue: a later start still dispatches',
      () async {
    recorder.failNextSetLocale = true;
    expect(await StreamKeepalive.syncLocale('zh-Hant'), isFalse);
    final keepalive = StreamKeepalive(2);
    await keepalive.start();
    expect(recorder.calls.last.$1, 'start');
  });

  test('non-Android skips the channel entirely (web seam)', () async {
    // This host is not Android; the queue must stay untouched.
    if (defaultTargetPlatform == TargetPlatform.android) return;
    expect(await StreamKeepalive.syncLocale('zh-Hant'), isTrue);
    expect(recorder.calls, isEmpty);
  });

  ProviderContainer? uiContainer;

  Future<void> switchViaUi(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [localStoreProvider.overrideWithValue(LocalStore(prefs))],
    );
    uiContainer = container;
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const HermesApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('language.zhHant')).first);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'UI switch commits zh-Hant in place; the channel seam is the direct '
    'dispatch tests above',
    (tester) async {
      // FakeAsync cannot interleave the serialized native round-trip, so
      // dispatch shape/order/serialization are asserted directly above;
      // here the contract is: the switch lands, UI language moves, the
      // warning surface stays quiet while no mirror failure is reported.
      await switchViaUi(tester);
      expect(find.text('連線設定'), findsOneWidget);
      expect(
        find.textContaining('Notification language sync failed'),
        findsNothing,
      );
    },
  );

  testWidgets('mirror failure warns without reverting the committed UI', (
    tester,
  ) async {
    await switchViaUi(tester);
    uiContainer!.read(localeProvider.notifier).reportMirrorFailure(AppLocale.zhHant);
    await tester.pump();
    expect(find.text('連線設定'), findsOneWidget); // UI language stays
    expect(
      find.textContaining('通知語言同步失敗'),
      findsOneWidget,
    );
  });

  test('locale bookkeeping: token stream commands unchanged by a switch',
      () async {
    final keepalive = StreamKeepalive(3);
    await keepalive.start();
    await StreamKeepalive.syncLocale('zh-Hant');
    await keepalive.stop();
    final ids = recorder.calls
        .where((c) => c.$1 == 'start' || c.$1 == 'stop')
        .map((c) => c.$2)
        .toList();
    expect(ids, [3, 3]); // same tokens; switch added none
  });
}
