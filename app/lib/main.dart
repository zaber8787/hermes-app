import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'features/settings/local_store.dart';
import 'features/settings/notification_locale.dart';
import 'features/settings/settings_page.dart';
import 'features/sessions/sessions_page.dart';
import 'l10n/app_strings.dart';
import 'l10n/message_key.dart';
import 'l10n/ui_message.dart';
import 'providers.dart';
import 'diagnostics/diagnostics.dart';
import 'platform/stream_keepalive.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Diagnostics.initialize();
  StreamKeepalive.initialize();
  final store = LocalStore(await SharedPreferences.getInstance());
  // Language loads FIRST and outside the credential try/catch: a vault
  // failure must never discard an existing saved language (I18N-PLAN §4.2).
  final locale = store.loadLocale();
  // Initial notification-language mirror lands in the serialized queue
  // BEFORE any stream can start (I18N-PLAN §6.5); failures are non-fatal.
  unawaited(syncNotificationLocale(locale));
  var settings = const AppSettings();
  UiMessage? initialError;
  try {
    settings = await store.loadSettings();
  } catch (_) {
    initialError = const UiMessage.local(MessageKey.startupM001);
  }
  runApp(
    ProviderScope(
      overrides: [
        localStoreProvider.overrideWithValue(store),
        initialSettingsProvider.overrideWithValue(settings),
        initialLocaleProvider.overrideWithValue(locale),
      ],
      child: HermesApp(initialError: initialError),
    ),
  );
}

class HermesApp extends ConsumerWidget {
  const HermesApp({super.key, this.initialError});
  final UiMessage? initialError;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    // Watched ONCE here; no ValueKey(locale), no ProviderScope recreation,
    // no route replacement — a language change re-renders localized
    // subtrees in place, keeping drafts/scroll/focus (I18N-PLAN §4.2/§4.5).
    final locale = ref.watch(localeProvider).locale;
    // Native notification mirror (I18N-PLAN §6.2): dispatched from the live
    // tree on every committed change; never blocks or reverts the switch.
    ref.listen(localeProvider, (previous, next) {
      if (previous?.locale != next.locale) {
        unawaited(
          syncNotificationLocale(next.locale).then((ok) {
            if (!ok) {
              ref.read(localeProvider.notifier).reportMirrorFailure(next.locale);
            }
          }),
        );
      }
    });
    return MaterialApp(
      title: 'Hermes',
      debugShowCheckedModeBanner: false,
      locale: AppStrings.localeFor(locale),
      supportedLocales: AppStrings.supportedLocales,
      localizationsDelegates: const [
        AppStringsDelegate.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff72e0be),
          brightness: Brightness.dark,
          surface: const Color(0xff10171d),
        ),
        scaffoldBackgroundColor: const Color(0xff10171d),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xff10171d)),
        cardTheme: CardThemeData(
          elevation: 0,
          color: const Color(0xff19232b),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
      ),
      home: settings.configured
          ? const SessionsPage()
          : SettingsPage(initialError: initialError),
    );
  }
}
