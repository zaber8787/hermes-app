import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'package:hermes_app/l10n/app_strings.dart';
import 'package:hermes_app/models/session.dart';

void main() {
  SharedPreferences.setMockInitialValues({});
  Future<LocalStore> store() async =>
      LocalStore(await SharedPreferences.getInstance());

  group('P2 local store', () {
    test('draft survives store recreation (app kill)', () async {
      final a = await store();
      await a.saveDraft('http://s', 'x', '打到一半的長文\n第二行');
      final b = await store();
      expect(b.draft('http://s', 'x'), '打到一半的長文\n第二行');
      await b.saveDraft('http://s', 'x', '');
      expect((await store()).draft('http://s', 'x'), '');
    });

    test('drafts are per-session and per-server', () async {
      final s = await store();
      await s.saveDraft('http://a', 'x', 'A');
      await s.saveDraft('http://b', 'x', 'B');
      await s.saveDraft('http://a', 'y', 'Y');
      expect(s.draft('http://a', 'x'), 'A');
      expect(s.draft('http://b', 'x'), 'B');
      expect(s.draft('http://a', 'y'), 'Y');
    });

    test('hidden set persists and toggles', () async {
      final a = await store();
      await a.setHidden('http://s', 'h1', true);
      await a.setHidden('http://s', 'h2', true);
      await a.setHidden('http://s', 'h2', false);
      final b = await store();
      expect(b.isHidden('http://s', 'h1'), isTrue);
      expect(b.isHidden('http://s', 'h2'), isFalse);
      expect(b.isHidden('http://other', 'h1'), isFalse);
    });

    test('title cache overrides stale server title on reopen', () async {
      final a = await store();
      await a.cacheTitle('http://s', 'x', '新名字');
      final s = Session(
        id: 'x',
        title: '舊名字',
        count: 1,
        startedAt: 0,
        activity: 0,
        source: 'api_server',
      ).withTitle((await store()).cachedTitle('http://s', 'x') ?? '');
      expect(s.title, '新名字');
    });

    test('titles stay raw; the untitled fallback is display-only', () async {
      // Model/storage never inject a translated string (I18N-PLAN §4.4)…
      expect(Session(id: 'x', title: '', count: 0, startedAt: 0, activity: 0, source: 'api_server').withTitle('').title,
          '');
      // …the LIST/HEADER render applies the locale-aware fallback.
      expect(
        displaySessionTitle(AppStrings(AppLocale.en), ''),
        'Untitled conversation',
      );
      expect(
        displaySessionTitle(AppStrings(AppLocale.zhHant), ''),
        '未命名對話',
      );
      // A server title literally equal to the old fallback stays raw:
      expect(displaySessionTitle(AppStrings(AppLocale.en), '未命名對話'),
          '未命名對話');
    });

    test('lost marker round-trips', () async {
      final a = await store();
      expect(a.lostNotice('http://s', 'x'), isNull);
      await a.markLost('http://s', 'x');
      expect((await store()).lostNotice('http://s', 'x'), isNotNull);
      await a.clearLost('http://s', 'x');
      expect((await store()).lostNotice('http://s', 'x'), isNull);
    });
  });
}
