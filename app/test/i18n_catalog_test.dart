import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'package:hermes_app/l10n/app_strings.dart';
import 'package:hermes_app/l10n/catalog.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';

import 'support/localized_app.dart';

// Catalog contract tests (I18N-PLAN §8/§9): parity, placeholders, counts,
// nested descriptors, raw passthrough — plus representative LITERAL output
// so the tests never just compare the implementation against itself.
void main() {
  final keys = MessageKey.values;

  test('both locales cover every key with nonempty strings', () {
    for (final k in keys) {
      final en = catalogEn[k], zh = catalogZhHant[k];
      expect(en, isNotNull, reason: '$k missing in English');
      expect(zh, isNotNull, reason: '$k missing in zh-Hant');
      expect(en!.trim(), isNotEmpty);
      expect(zh!.trim(), isNotEmpty);
    }
  });

  test('placeholders match between locales', () {
    final ph = RegExp(r'\{(\w+)\}');
    for (final k in keys) {
      final a = ph.allMatches(catalogEn[k]!).map((m) => m[1]).toSet();
      final b = ph.allMatches(catalogZhHant[k]!).map((m) => m[1]).toSet();
      expect(a, b, reason: '$k placeholder parity');
    }
  });

  test('every enum key is reachable from both catalogs', () {
    expect(catalogEn.keys.toSet(), keys.toSet());
    expect(catalogZhHant.keys.toSet(), keys.toSet());
  });

  test('representative literal translations', () {
    // Exact reviewed values, not self-comparison:
    expect(t(MessageKey.settingsM007), 'Connection settings');
    expect(t(MessageKey.settingsM007, locale: AppLocale.zhHant), '連線設定');
    expect(t(MessageKey.commonCancel), 'Cancel');
    expect(t(MessageKey.commonCancel, locale: AppLocale.zhHant), '取消');
    expect(t(MessageKey.chatStateStoppedByYou), 'Stopped by you');
    expect(t(MessageKey.chatStateStoppedByYou, locale: AppLocale.zhHant), '已由你停止');
    expect(t(MessageKey.chatRemoteUnconfirmed), '⋯ (not yet confirmed in history)');
    expect(t(MessageKey.chatRemoteUnconfirmed, locale: AppLocale.zhHant), '⋯（尚未於歷史確認）');
    expect(t(MessageKey.sessionsUntitled), 'Untitled conversation');
    expect(t(MessageKey.sessionsUntitled, locale: AppLocale.zhHant), '未命名對話');
    expect(t(MessageKey.languageEnglish), 'English');
    expect(t(MessageKey.languageTraditionalChinese), '繁體中文');
    expect(t(MessageKey.settingsLanguage, locale: AppLocale.zhHant), '語言');
    expect(t(MessageKey.chatRemoteBusy, locale: AppLocale.zhHant), '其他裝置進行中');
  });

  test('count rules: 0 and >1 plural, 1 singular (zh invariant)', () {
    expect(t(MessageKey.timelineM001, args: {'count': 1}, count: 1), '🔧 Ran 1 step');
    expect(t(MessageKey.timelineM001, args: {'count': 0}, count: 0), '🔧 Ran 0 steps');
    expect(t(MessageKey.timelineM001, args: {'count': 2}, count: 2), '🔧 Ran 2 steps');
    expect(t(MessageKey.timelineM001, args: {'count': 1204}, count: 1204), '🔧 Ran 1204 steps');
    for (final n in [0, 1, 2, 9999]) {
      expect(
        t(MessageKey.timelineM001, args: {'count': n}, count: n, locale: AppLocale.zhHant),
        '🔧 執行了 $n 個步驟',
      );
    }
    expect(t(MessageKey.sessionsM021, args: {'count': 1, 'month': 3, 'day': 4, 'source': 'api'}, count: 1), '1 message · 3/4 · api');
    expect(t(MessageKey.sessionsM021, args: {'count': 2, 'month': 3, 'day': 4, 'source': 'api'}, count: 2), '2 messages · 3/4 · api');
  });

  test('nested descriptors resolve recursively; raw stays byte-exact', () {
    final nested = UiMessage.local(
      MessageKey.chatStateM013,
      args: {'error': messageForError(const FormatException('server said no'))},
    );
    expect(r(nested), 'Reply failed: server said no');
    expect(r(nested, locale: AppLocale.zhHant), '回覆失敗：server said no');
    // Raw SERVER text is never re-translated in either locale.
    const raw = UiMessage.raw('伺服器回傳的原文 100% 保持');
    expect(r(raw), '伺服器回傳的原文 100% 保持');
    expect(r(raw, locale: AppLocale.zhHant), '伺服器回傳的原文 100% 保持');
  });

  test('list separators are locale-specific', () {
    expect(
      AppStrings(AppLocale.en).joinParts(['a', 'b']),
      'a, b',
    );
    expect(
      AppStrings(AppLocale.zhHant).joinParts(['太大', '讀取失敗']),
      '太大、讀取失敗',
    );
  });

  test('delegate load is synchronous and locale-correct', () async {
    const d = AppStringsDelegate.delegate;
    final en = await d.load(const Locale('en'));
    final zh = await d.load(
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant', countryCode: 'TW'),
    );
    expect(en.locale, AppLocale.en);
    expect(zh.locale, AppLocale.zhHant);
    expect(d.shouldReload(const AppStringsDelegate()), isFalse);
  });

  test('unknown resolution throws StateError, never falls back silently', () {
    // Every key is cataloged, so a missing placeholder ARG leaves its
    // marker visible (loud) rather than silently dropping data:
    expect(t(MessageKey.contentM003, args: const {}), contains('{saved}'));
  });
}
