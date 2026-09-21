import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:hermes_app/l10n/app_locale.dart';
import 'package:hermes_app/l10n/app_strings.dart';
import 'package:hermes_app/l10n/locale_provider.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';

/// Shared fixture: MaterialApp with app + framework delegates and an
/// EXPLICIT locale (default English — tests must never rely on the host
/// machine language). Caller ProviderScope overrides are preserved; the
/// locale provider default is aligned with the visible [locale].
Widget localizedApp(
  Widget home, {
  AppLocale locale = AppLocale.en,
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: [
      initialLocaleProvider.overrideWithValue(locale),
      ...overrides,
    ],
    child: MaterialApp(
      locale: AppStrings.localeFor(locale),
      supportedLocales: AppStrings.supportedLocales,
      localizationsDelegates: const [
        AppStringsDelegate.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: home,
    ),
  );
}

/// Wraps a page in a MaterialApp that registers the app + framework
/// delegates and an EXPLICIT locale, INSIDE an already-provided provider
/// scope (pairs with UncontrolledProviderScope in controller tests).
Widget localizedWrap(
  Widget home, {
  AppLocale locale = AppLocale.en,
  GlobalKey<NavigatorState>? navigatorKey,
}) {
  return MaterialApp(
    navigatorKey: navigatorKey,
    locale: AppStrings.localeFor(locale),
    supportedLocales: AppStrings.supportedLocales,
    localizationsDelegates: const [
      AppStringsDelegate.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: home,
  );
}

/// MaterialApp-with-delegates drop-in for `MaterialApp(home: ...)` call
/// sites in migrated widget tests.
Widget localizedHome({required Widget home, AppLocale locale = AppLocale.en}) =>
    localizedWrap(home, locale: locale);

/// Convenience for direct resolver assertions.
String t(MessageKey key, {AppLocale locale = AppLocale.en, Map<String, Object?> args = const {}, int? count}) =>
    AppStrings.forLocale(locale).resolve(key, args: args, count: count);

/// Convenience: render a descriptor.
String r(UiMessage m, {AppLocale locale = AppLocale.en}) =>
    AppStrings.forLocale(locale).render(m);
