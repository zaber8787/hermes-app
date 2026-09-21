import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/features/settings/management_page.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/providers.dart';

/// R3 management UI behaviour (widget side; HTTP-side parsing lives in
/// audit_wave3_admin_test.dart where TestWidgetsFlutterBinding stays off).

void main() {
  group('management page', () {
    late FakeAdminRepo repo;
    late ProviderContainer container;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      repo = FakeAdminRepo();
      container = ProviderContainer(
        overrides: [
          repositoryProvider.overrideWithValue(repo),
          localStoreProvider.overrideWithValue(
            LocalStore(await SharedPreferences.getInstance()),
          ),
          initialSettingsProvider.overrideWith(
            (ref) => const AppSettings(url: 'http://test.invalid', key: 'k'),
          ),
        ],
      );
      addTearDown(container.dispose);
    });

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ManagementPage()),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('skills: switches real, essential locked, lag note', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('開關在下個回合生效。'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(find.byType(Switch), findsNWidgets(2)); // alpha + beta
      // Toggle beta OFF -> PATCH recorded + provider invalidated -> repaint.
      final betaSwitch = find.byType(Switch).last;
      await tester.tap(betaSwitch);
      await tester.pump();
      await tester.pump();
      expect(repo.patches, [
        ['beta', false],
      ]);
    });

    testWidgets('skills: server 400 (essential) locks the row', (tester) async {
      repo.reject400 = true;
      await open(tester);
      await tester.tap(find.byType(Switch).first); // alpha
      await tester.pump();
      await tester.pump();
      expect(find.text('切換失敗：切換被拒 (HTTP 400)'), findsOneWidget);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ManagementPage()),
        ),
      );
      await tester.pump();
      expect(find.byIcon(Icons.lock_outline), findsNWidgets(2));
    });

    testWidgets('memory rows show chars/limit and mtime; model shows global', (
      tester,
    ) async {
      await open(tester);
      expect(find.textContaining('5/2200 字元'), findsOneWidget);
      expect(
        find.textContaining('0/1375 字元 · 最後修改 （尚無檔案）'),
        findsOneWidget,
      );
      expect(find.textContaining('memory 在對話中的生效方式'), findsOneWidget);
      expect(find.textContaining('全域目前：gpt-6-astra'), findsOneWidget);
    });

    testWidgets('memory editor: save PUTs content and pops', (tester) async {
      await open(tester);
      await tester.tap(find.text('MEMORY.md'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), '新的記憶');
      await tester.tap(find.text('儲存'));
      await tester.pumpAndSettle();
      expect(repo.saved, [['MEMORY.md', '新的記憶']]);
    });
  });
}

class FakeAdminRepo extends HermesRepository {
  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  FakeAdminRepo() : super('http://test.invalid', 'fake');
  final patches = <List<Object>>[];
  final saved = <List<String>>[];
  bool reject400 = false;
  final _enabled = {'alpha': true, 'beta': true};

  @override
  Future<void> checkCapabilities() async {}

  @override
  Future<List<Skill>> skills() async => [
    Skill('alpha', '甲技能', 'tools', enabled: _enabled['alpha']!),
    Skill('hermes-agent', '核心', ''),
    Skill('beta', '乙技能', 'misc', enabled: _enabled['beta']!),
  ];

  @override
  Future<void> setSkillEnabled(String name, bool enabled) async {
    if (reject400) throw const ApiException('切換被拒', 400);
    patches.add([name, enabled]);
    _enabled[name] = enabled;
  }

  @override
  Future<({List<Map<String, dynamic>> models, String global})> modelCatalog()
      async => (
        models: const [
          {'model': 'gpt-6-astra', 'provider': 'nous', 'providerName': 'Nous',
           'current': true},
        ],
        global: 'gpt-6-astra',
      );

  @override
  Future<List<Map<String, dynamic>>> memories() async => [
    {'name': 'MEMORY.md', 'chars': 5, 'limit': 2200, 'content': '嘿嘅嗚唔',
     'mtime': 1758000000.0},
    {'name': 'USER.md', 'chars': 0, 'limit': 1375, 'content': null,
     'mtime': null},
  ];

  @override
  Future<void> saveMemory(String name, String content) async =>
      saved.add([name, content]);
}
