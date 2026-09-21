import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'app_locale.dart';
import 'catalog.dart';
import 'message_key.dart';
import 'ui_message.dart';

/// Immutable resolver over the handwritten catalogs (I18N-PLAN §4.1/§4.5).
/// One instance per locale; instances are created once by the delegate and
/// reused — no per-frame parsing, no mutable global translator.
class AppStrings {
  const AppStrings(this.locale);

  final AppLocale locale;

  static AppStrings of(BuildContext context) =>
      Localizations.of<AppStrings>(context, AppStrings)!;

  static AppStrings forLocale(AppLocale locale) => AppStrings(locale);

  /// The ONLY supported locales: English and Traditional Chinese (zh-Hant).
  /// A Simplified Chinese locale is intentionally absent so nothing can
  /// silently fall back to it.
  static const supportedLocales = [
    Locale('en'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant', countryCode: 'TW'),
  ];

  static Locale localeFor(AppLocale locale) => switch (locale) {
    AppLocale.en => const Locale('en'),
    AppLocale.zhHant => const Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hant',
      countryCode: 'TW',
    ),
  };

  Map<MessageKey, String> get _table => switch (locale) {
    AppLocale.en => catalogEn,
    AppLocale.zhHant => catalogZhHant,
  };

  /// Count variants: English swaps the plural branch for count != 1;
  /// Traditional Chinese keeps the invariant template (plan §4.3).
  String resolve(MessageKey key, {Map<String, Object?> args = const {}, int? count}) {
    var use = key;
    if (count != null && count != 1 && locale == AppLocale.en) {
      use = _pluralOf(key) ?? key;
    }
    final found = _table[use] ?? _table[key];
    if (found == null) {
      throw StateError('missing catalog entry for $use (${locale.name})');
    }
    var out = found;
    if (count != null && !args.containsKey('count')) {
      out = out.replaceAll('{count}', '$count');
    }
    for (final entry in args.entries) {
      out = out.replaceAll('{${entry.key}}', renderValue(entry.value));
    }
    return out;
  }

  /// Render a descriptor (nested locals resolve recursively; raw stays
  /// byte-for-byte).
  String render(UiMessage message) => switch (message) {
    UiRaw(:final text) => text,
    UiLocal(:final key, :final args, :final count) =>
      resolve(key, args: args, count: count),
  };

  String renderValue(Object? value) => switch (value) {
    null => '',
    String s => s,
    int n => n.toString(),
    UiMessage m => render(m),
    _ => '$value',
  };

  /// Locale-specific list separator for assembled parts (plan §4.3).
  String joinParts(List<String> parts) =>
      locale == AppLocale.zhHant ? parts.join('、') : parts.join(', ');

  static MessageKey? _pluralOf(MessageKey key) {
    const map = {
      MessageKey.attachmentBatchM002: MessageKey.attachmentBatchM002Plural,
      MessageKey.attachmentBatchM003: MessageKey.attachmentBatchM003Plural,
      MessageKey.attachmentBatchM004: MessageKey.attachmentBatchM004Plural,
      MessageKey.attachmentBatchM006: MessageKey.attachmentBatchM006Plural,
      MessageKey.commandsM017: MessageKey.commandsM017Plural,
      MessageKey.commandsM023: MessageKey.commandsM023Plural,
      MessageKey.timelineM001: MessageKey.timelineM001Plural,
      MessageKey.timelineM010: MessageKey.timelineM010Plural,
      MessageKey.sessionsM019: MessageKey.sessionsM019Plural,
      MessageKey.sessionsM021: MessageKey.sessionsM021Plural,
      MessageKey.managementM012: MessageKey.managementM012Plural,
    };
    return map[key];
  }
}

class AppStringsDelegate extends LocalizationsDelegate<AppStrings> {
  const AppStringsDelegate();

  static const AppStringsDelegate delegate = AppStringsDelegate();

  @override
  bool isSupported(Locale locale) => AppStrings.supportedLocales
      .any((l) => l.languageCode == locale.languageCode);

  @override
  Future<AppStrings> load(Locale locale) =>
      SynchronousFuture<AppStrings>(
        AppStrings(
          locale.languageCode == 'zh' ? AppLocale.zhHant : AppLocale.en,
        ),
      );

  @override
  bool shouldReload(AppStringsDelegate old) => false;
}
