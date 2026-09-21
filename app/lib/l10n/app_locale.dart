/// Pure-Dart language identity (I18N-PLAN §4.1). No Flutter, no network,
/// no Riverpod state here — the widget Locale mapping lives in
/// `app_strings.dart` so this file stays usable from CLI/CI code.
enum AppLocale {
  en('en'),
  zhHant('zh-Hant');

  const AppLocale(this.tag);

  /// Canonical persisted value written to `ui.locale`.
  final String tag;

  /// Strict normalization (I18N-PLAN §1): missing / wrong-typed / unknown →
  /// English. Legacy or externally supplied zh, zh-TW, zh-Hant-TW and
  /// zh-Hant all read as Traditional Chinese. Simplified Chinese is never
  /// produced from a preference value.
  static AppLocale normalize(Object? value) {
    if (value is! String) return AppLocale.en;
    switch (value.trim()) {
      case 'en':
        return AppLocale.en;
      case 'zh':
      case 'zh-TW':
      case 'zh-Hant':
      case 'zh-Hant-TW':
        return AppLocale.zhHant;
      default:
        return AppLocale.en;
    }
  }
}
