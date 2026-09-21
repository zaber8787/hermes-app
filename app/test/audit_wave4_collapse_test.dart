import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/features/settings/management_page.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/providers.dart';

/// WAVE4 §3.7: Skills/Model collapse — per-server persistence, header-only
/// summaries, provider reuse (no extra list GETs), Offstage state survival,
/// serialized persistence and revert-on-failure. Memory/USER never folds.

const url = 'http://test.invalid';

class FakeCollapseRepo extends HermesRepository {
  FakeCollapseRepo() : super(url, 'fake');
  int skillsCalls = 0, modelCalls = 0;
  bool reject400 = false;
  @override
  Future<void> checkCapabilities() async {}
  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  @override
  Future<List<Skill>> skills() async {
    skillsCalls++;
    return [
      Skill('alpha', '甲技能', 'tools', enabled: true),
      Skill('hermes-agent', '核心', '', enabled: true),
      Skill('beta', '乙技能', 'misc', enabled: false),
    ];
  }

  @override
  Future<({List<Map<String, dynamic>> models, String global})> modelCatalog()
  async {
    modelCalls++;
    return (
      models: const [
        {'model': 'gpt-6-astra', 'provider': 'nous', 'providerName': 'Nous',
         'current': true},
      ],
      global: 'gpt-6-astra',
    );
  }

  @override
  Future<void> setSkillEnabled(String name, bool enabled) async {
    if (reject400) throw const ApiException('切換被拒', 400);
  }

  @override
  Future<List<Map<String, dynamic>>> memories() async => const [];
}

class _ThrowingStore extends LocalStore {
  _ThrowingStore(super.prefs);
  @override
  Future<void> setManagementSectionCollapsed(
    String server,
    String section,
    bool value,
  ) async {
    throw Exception('disk on fire');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeCollapseRepo repo;
  late ProviderContainer container;
  late SharedPreferences prefs;

  ProviderContainer build() => ProviderContainer(
    overrides: [
      repositoryProvider.overrideWithValue(repo),
      localStoreProvider.overrideWithValue(LocalStore(prefs)),
      initialSettingsProvider.overrideWith(
        (ref) => const AppSettings(url: url, key: 'k'),
      ),
    ],
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    repo = FakeCollapseRepo();
    container = build();
    addTearDown(container.dispose);
  });

  Future<void> open(WidgetTester tester, [ProviderContainer? c]) async {
    tester.view.physicalSize = const Size(1600, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c ?? container,
        child: const MaterialApp(home: ManagementPage()),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Finder header(String title) => find
      .ancestor(of: find.text(title), matching: find.byType(InkWell))
      .first;

  test('LocalStore: defaults false; persists under the exact §3.7 key', () async {
    SharedPreferences.setMockInitialValues({});
    final p = await SharedPreferences.getInstance();
    final s = LocalStore(p);
    expect(s.managementSectionCollapsed(url, 'skills'), isFalse);
    await s.setManagementSectionCollapsed(url, 'model', true);
    expect(
      p.getBool('${Uri.encodeComponent(url)}.management.model.collapsed'),
      isTrue,
    );
    expect(s.managementSectionCollapsed(url, 'model'), isTrue);
    expect(
      s.managementSectionCollapsed('https://other', 'model'),
      isFalse,
      reason: 'per-server, never shared',
    );
  });

  testWidgets('collapsed Skills shows header+summary only, body offstage', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(header('Skills'));
    await tester.pump();
    expect(find.text('已啟用 2 / 共 3'), findsOneWidget);
    expect(find.byType(Switch), findsNothing); // offstage: finders skip it
    expect(find.text('開關在下個回合生效。'), findsNothing);
    // Model section stays open; Memory never folds (no toggle there).
    expect(find.text('全域目前：gpt-6-astra'), findsOneWidget);
    expect(find.text('Skills'), findsOneWidget);
  });

  testWidgets('collapse costs ZERO extra provider requests', (tester) async {
    await open(tester);
    expect(repo.skillsCalls, 1);
    await tester.tap(header('Skills'));
    await tester.pump();
    await tester.tap(header('Skills'));
    await tester.pump();
    expect(find.byType(Switch), findsNWidgets(2));
    expect(repo.skillsCalls, 1, reason: 'same Riverpod result, no refetch');
    expect(repo.modelCalls, 1);
  });

  testWidgets('Offstage preserves block state (_lockedByServer survives)', (
    tester,
  ) async {
    repo.reject400 = true;
    await open(tester);
    await tester.tap(find.byType(Switch).first); // alpha -> server 400
    await tester.pump();
    await tester.pump();
    // hermes-agent (local mirror) + alpha (server-confirmed 400 lock).
    expect(find.byIcon(Icons.lock_outline), findsNWidgets(2));
    await tester.tap(header('Skills')); // collapse
    await tester.pump();
    expect(find.byIcon(Icons.lock_outline), findsNothing); // body offstage
    await tester.tap(header('Skills')); // expand
    await tester.pump();
    expect(
      find.byIcon(Icons.lock_outline),
      findsNWidgets(2),
      reason: '_lockedByServer survived the fold — the block never rebuilt',
    );
  });

  testWidgets('keyboard Enter toggles; collapse persists across a new page', (
    tester,
  ) async {
    await open(tester);
    Focus.of(tester.element(header('Skills'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('已啟用 2 / 共 3'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.byType(Switch), findsNWidgets(2));

    await tester.tap(header('Model')); // fold Model
    await tester.pump();
    expect(find.byIcon(Icons.radio_button_checked), findsNothing);
    expect(find.text('全域目前：gpt-6-astra'), findsOneWidget); // summary now

    // Fresh page over the same prefs: Model still folded, Skills open.
    final fresh = build();
    addTearDown(fresh.dispose);
    await open(tester, fresh);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    expect(find.byIcon(Icons.expand_less), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_checked), findsNothing);
  });

  testWidgets('rapid taps serialize: the LAST choice lands on disk', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(header('Skills'));
    await tester.tap(header('Skills'));
    await tester.tap(header('Skills'));
    await tester.pump();
    await tester.pump();
    expect(
      prefs.getBool('${Uri.encodeComponent(url)}.management.skills.collapsed'),
      isTrue,
    );
  });

  testWidgets('persist failure reverts the visible value and warns', (
    tester,
  ) async {
    final c = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        localStoreProvider.overrideWithValue(_ThrowingStore(prefs)),
        initialSettingsProvider.overrideWith(
          (ref) => const AppSettings(url: url, key: 'k'),
        ),
      ],
    );
    addTearDown(c.dispose);
    await open(tester, c);
    await tester.tap(header('Skills'));
    await tester.pump();
    await tester.pump();
    expect(find.text('儲存失敗，摺疊狀態已還原'), findsOneWidget);
    expect(find.byType(Switch), findsNWidgets(2), reason: 'back to expanded');
  });

  testWidgets('Memory section has no fold affordance', (tester) async {
    await open(tester);
    expect(
      find
          .ancestor(
            of: find.text('Memory / USER'),
            matching: find.byType(InkWell),
          )
          .evaluate(),
      isEmpty,
      reason: 'Memory/USER never folds',
    );
  });
}
