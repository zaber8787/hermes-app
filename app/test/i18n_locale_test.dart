import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hermes_app/features/settings/key_vault.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'package:hermes_app/main.dart';
import 'package:hermes_app/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Black-box Phase-1 locale contract (I18N-PLAN §9): uses ONLY pre-existing
// public APIs so it is a runnable failing assertion against the OLD
// behavior (red), not a compile failure on new symbols.
void main() {
  group('blackbox contract', () {
  testWidgets('fixed English on a Chinese system locale', (tester) async {
    tester.platformDispatcher.localesTestValue = [const Locale('zh', 'TW')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localStoreProvider.overrideWithValue(LocalStore(prefs)),
        ],
        child: const HermesApp(),
      ),
    );
    await tester.pumpAndSettle();
    // The product decision: English wins even on zh-TW, including on a
    // first run without any saved preference.
    expect(find.text('Connection settings'), findsOneWidget);
    expect(find.text('Connect your Hermes'), findsOneWidget);
  });

  testWidgets('settings exposes a language control before connection', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localStoreProvider.overrideWithValue(LocalStore(prefs)),
        ],
        child: const HermesApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings.language')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('language.en')),
      findsWidgets,
      reason: 'English autonym option',
    );
    expect(
      find.byKey(const ValueKey('language.zhHant')),
      findsWidgets,
      reason: '繁體中文 autonym option',
    );
  });

  testWidgets('language switch is live and works with empty settings', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localStoreProvider.overrideWithValue(LocalStore(prefs)),
        ],
        child: const HermesApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Connection settings'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('language.zhHant')).first);
    await tester.pumpAndSettle();
    // Same route, same page instance — text changes in place.
    expect(find.text('連線設定'), findsOneWidget);
    expect(find.text('Connection settings'), findsNothing);
  });
  });
  group('typed state', typedCases);
}


// ---- Typed-state persistence / live-switch cases (Phase 1 skeleton) ----

class _RecordingStore extends LocalStore {
  _RecordingStore(super.prefs);
  List<String?> saved = [];
  int writesInFlight = 0, maxInFlight = 0;
  bool okToSave = true;
  @override
  Future<bool> saveLocale(AppLocale value) async {
    writesInFlight++;
    if (writesInFlight > maxInFlight) maxInFlight = writesInFlight;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (!okToSave) return false;
      saved.add(value.tag);
      final ok = await super.saveLocale(value);
      return ok;
    } finally {
      writesInFlight--;
    }
  }
}

class _ThrowingVault implements KeyVault {
  int reads = 0;
  @override
  Future<String?> read(String key) async {
    reads++;
    throw Exception('vault unavailable');
  }

  @override
  Future<void> write(String key, String value) async {}
}

void typedCases() {
  test('normalize: aliases and rejections', () {
    expect(AppLocale.normalize('zh-Hant'), AppLocale.zhHant);
    expect(AppLocale.normalize('zh'), AppLocale.zhHant);
    expect(AppLocale.normalize('zh-TW'), AppLocale.zhHant);
    expect(AppLocale.normalize('zh-Hant-TW'), AppLocale.zhHant);
    expect(AppLocale.normalize('en'), AppLocale.en);
    // Wrong type / garbage / Simplified Chinese all normalize to English.
    expect(AppLocale.normalize(null), AppLocale.en);
    expect(AppLocale.normalize(7), AppLocale.en);
    expect(AppLocale.normalize('zh-Hans'), AppLocale.en);
    expect(AppLocale.normalize('de-DE'), AppLocale.en);
  });

  testWidgets('saved zh-Hant starts Traditional; legacy zh alias too', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'ui.locale': 'zh-Hant'});
    final prefs = await SharedPreferences.getInstance();
    final store = LocalStore(prefs);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localStoreProvider.overrideWithValue(store),
          // Mirrors main(): the locale loads BEFORE runApp and feeds the
          // root through initialLocaleProvider.
          initialLocaleProvider.overrideWithValue(store.loadLocale()),
        ],
        child: const HermesApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('連線設定'), findsOneWidget);
  });

  testWidgets('a successful switch persists the canonical tag exactly', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = _RecordingStore(prefs);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [localStoreProvider.overrideWithValue(store)],
        child: const HermesApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('language.zhHant')).first);
    await tester.pumpAndSettle();
    expect(prefs.getString('ui.locale'), 'zh-Hant');
    expect(store.saved, ['zh-Hant']);
    expect(find.text('連線設定'), findsOneWidget);
  });

  testWidgets('failed preference write keeps the old language', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = _RecordingStore(prefs)..okToSave = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [localStoreProvider.overrideWithValue(store)],
        child: const HermesApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('language.zhHant')).first);
    await tester.pumpAndSettle();
    // Old language stays committed and the failure is surfaced.
    expect(find.text('Connection settings'), findsOneWidget);
    expect(
      find.textContaining('language preference could not be saved'),
      findsOneWidget,
    );
    expect(prefs.containsKey('ui.locale'), isFalse);
  });

  testWidgets('language saving never touches the credential vault', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final vault = _ThrowingVault();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localStoreProvider.overrideWithValue(LocalStore(prefs, vault: vault)),
        ],
        child: const HermesApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('language.zhHant')).first);
    await tester.pumpAndSettle();
    expect(find.text('連線設定'), findsOneWidget);
    expect(vault.reads, 0);
  });

  test('same-value selection is a no-op; rapid switches serialize', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = _RecordingStore(prefs);
    final container = ProviderContainer(
      overrides: [localStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(localeProvider.notifier);
    expect(await notifier.select(AppLocale.en), isTrue); // same value
    expect(store.saved, isEmpty);
    // Rapid en→zh→en→zh WITHOUT awaiting between choices: last wins,
    // writes serialize (never two concurrent saves).
    final futures = [
      notifier.select(AppLocale.zhHant),
      notifier.select(AppLocale.en),
      notifier.select(AppLocale.zhHant),
    ];
    await Future.wait(futures);
    expect(container.read(localeProvider).locale, AppLocale.zhHant);
    expect(store.saved, ['zh-Hant', 'en', 'zh-Hant']);
    expect(store.maxInFlight, 1);
    expect(prefs.getString('ui.locale'), 'zh-Hant');
  });

  test('an existing language survives a credential vault read failure', () async {
    SharedPreferences.setMockInitialValues({'ui.locale': 'zh-Hant'});
    final prefs = await SharedPreferences.getInstance();
    final store = LocalStore(prefs, vault: _ThrowingVault());
    // main.dart's contract: loadLocale() runs OUTSIDE the settings
    // try/catch; loading settings throws yet the language is still read.
    expect(() => store.loadLocale(), returnsNormally);
    expect(store.loadLocale(), AppLocale.zhHant);
    await expectLater(store.loadSettings(), throwsA(anything));
  });
}
