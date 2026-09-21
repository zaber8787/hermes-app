import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/features/settings/key_vault.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/features/settings/settings_page.dart';
import 'package:hermes_app/features/sessions/sessions_page.dart';
import 'package:hermes_app/main.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/providers.dart';

/// ENVHYGIENE §7.2 config/app gates. Deliberately written against the PUBLIC
/// behaviour only (no new helper imports) so the SAME file runs red against
/// the old app: old builds had a hardcoded default host, key-only
/// `configured`, and would happily enter SessionsPage with a blank URL.

class FakeVault implements KeyVault {
  String? value;
  @override
  Future<String?> read(String key) async => value;
  @override
  Future<void> write(String key, String value) async => this.value = value;
}

class QuietRepo extends HermesRepository {
  QuietRepo() : super('http://test.invalid', 'k');
  int requests = 0;
  @override
  Future<void> checkCapabilities() async {
    requests++;
  }

  @override
  Future<List<Session>> sessions() async {
    requests++;
    return const [];
  }

  @override
  Future<List<Skill>> skills() async => const [];
  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  @override
  void cancelStream(String sid) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppSettings.configured', () {
    test('key alone is NOT enough — blank or junk URL must not be "configured"',
        () {
      expect(const AppSettings(url: '', key: 'k').configured, isFalse);
      expect(const AppSettings(url: 'not a url', key: 'k').configured, isFalse);
      expect(
        const AppSettings(url: '/relative/only', key: 'k').configured,
        isFalse,
      );
      expect(
        const AppSettings(url: 'http://u:p@host', key: 'k').configured,
        isFalse,
        reason: 'userinfo must never pass the shared validator',
      );
      expect(
        const AppSettings(url: 'http://host:70000', key: 'k').configured,
        isFalse,
        reason: 'port range is part of URL validity',
      );
    });

    test('valid URL + key is configured; trailing slash normalises', () {
      expect(const AppSettings(url: 'http://host:8700', key: 'k').configured,
          isTrue);
      expect(const AppSettings(url: 'https://host:8700/', key: 'k').configured,
          isTrue);
    });

    test('a fresh public build has NO default URL', () {
      // No --dart-define under `flutter test`: the Android default must be
      // empty (old builds shipped a hardcoded operator host here).
      expect(AppSettings.defaultUrl, '');
      expect(const AppSettings().url, '');
      expect(const AppSettings().configured, isFalse);
    });
  });

  group('loadSettings precedence', () {
    test('stored URL wins over the (empty) compile default', () async {
      SharedPreferences.setMockInitialValues({'server.url': 'http://mine:1/'});
      final s = LocalStore(await SharedPreferences.getInstance(), vault: FakeVault());
      final settings = await s.loadSettings();
      expect(settings.url, 'http://mine:1/');
    });

    test('stored BLANK url is a missing value, not a station', () async {
      SharedPreferences.setMockInitialValues({'server.url': '   '});
      final s = LocalStore(await SharedPreferences.getInstance(), vault: FakeVault());
      final settings = await s.loadSettings();
      expect(settings.url, '');
    });

    test('stored INVALID url is preserved verbatim for the user to fix',
        () async {
      SharedPreferences.setMockInitialValues({'server.url': 'http://bad|url'});
      final s = LocalStore(await SharedPreferences.getInstance(), vault: FakeVault());
      final settings = await s.loadSettings();
      expect(settings.url, 'http://bad|url');
      expect(settings.configured, isFalse);
    });

    test('legacy define is empty in public builds — nothing migrates', () async {
      SharedPreferences.setMockInitialValues({
        'server.url': 'http://someone-elses-host:8642',
      });
      final s = LocalStore(await SharedPreferences.getInstance(), vault: FakeVault());
      final settings = await s.loadSettings();
      expect(settings.url, 'http://someone-elses-host:8642',
          reason: 'no port-wide 8642 guessing (§4.1.4)');
    });
  });

  group('startup routing', () {
    Future<void> boot(
      WidgetTester tester, {
      required String url,
      required String key,
      required QuietRepo repo,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      final container = ProviderContainer(
        overrides: [
          localStoreProvider.overrideWithValue(store),
          repositoryProvider.overrideWithValue(repo),
          initialSettingsProvider.overrideWithValue(
            AppSettings(url: url, key: key),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const HermesApp(),
        ),
      );
      await tester.pump();
      addTearDown(repo.close);
    }

    testWidgets('key present + URL blank => SettingsPage, ZERO requests',
        (tester) async {
      final repo = QuietRepo();
      await boot(tester, url: '', key: 'k', repo: repo);
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(find.byType(SessionsPage), findsNothing);
      expect(repo.requests, 0, reason: 'nothing may be fetched pre-config');
    });

    testWidgets('invalid stored URL + key => still SettingsPage, zero calls',
        (tester) async {
      final repo = QuietRepo();
      await boot(tester, url: 'http:/broken', key: 'k', repo: repo);
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(repo.requests, 0);
    });

    testWidgets('valid URL + key => SessionsPage', (tester) async {
      final repo = QuietRepo();
      await boot(tester, url: 'http://srv:8700', key: 'k', repo: repo);
      await tester.pump();
      expect(find.byType(SessionsPage), findsOneWidget);
    });

    testWidgets('blank-URL settings page shows neutral guidance, no Tailscale',
        (tester) async {
      final repo = QuietRepo();
      await boot(tester, url: '', key: 'k', repo: repo);
      expect(find.textContaining('Tailscale'), findsNothing);
      expect(find.textContaining('private network'), findsOneWidget);
    });
  });
}
