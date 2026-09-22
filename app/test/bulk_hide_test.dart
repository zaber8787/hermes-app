import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/l10n/app_locale.dart';

import 'support/localized_app.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/sessions/session_selection.dart';
import 'package:hermes_app/features/sessions/sessions_page.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart' show Json;
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/providers.dart';

/// BULK-HIDE (plan C1): selection-mode regressions on the REAL SessionsPage
/// (provider, ListView, gestures). Selection is id-keyed; only a COMPLETE
/// list refresh may drop a row, and never a filter, reorder or refetch.

const url = 'http://test.invalid';

class FakeBulkRepo extends HermesRepository {
  FakeBulkRepo() : super(url, 'fake');
  List<Session> rows = [];
  int patchPinned = 0, renames = 0, deletes = 0;

  // hidden PATCH rig: bodies recorded; per-id failure/gate configurable.
  final List<(String, bool)> hiddenPatches = [];
  Map<String, int> hiddenFailStatus = {}; // id -> HTTP status to throw
  bool echoHidden = true; // 2xx WITHOUT the flag = outcome-unknown rig
  Map<String, bool> detailHidden = {};
  Completer<void>? gate;

  @override
  Future<List<Session>> sessions() async => List.of(rows);
  @override
  Future<bool> health() async => true;
  @override
  Future<List<Skill>> skills() async => const [];
  @override
  Future<Json> sessionDetail(String sid) async => {
    'id': sid,
    if (detailHidden.containsKey(sid)) 'hidden': detailHidden[sid],
  };
  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  @override
  Future<void> checkCapabilities() async {}
  @override
  Future<void> setSessionPinned(String sid, bool pinned) async => patchPinned++;
  @override
  Future<bool?> setSessionHidden(String sid, bool hidden) async {
    hiddenPatches.add((sid, hidden));
    await gate?.future;
    final fail = hiddenFailStatus[sid];
    if (fail != null) throw ApiException('hidden rejected', fail);
    if (!echoHidden) {
      return detailHidden[sid]; // no flag in PATCH body: readback decides
    }
    return hidden;
  }

  @override
  Future<void> renameSession(String sid, String title) async => renames++;
  @override
  Future<void> deleteSession(String sid) async {
    deletes++;
    rows = rows.where((s) => s.id != sid).toList();
  }

  @override
  Stream<SseEvent> chat(String sid, String input) =>
      throw StateError('selection mode must never send');
  @override
  void cancelStream(String sid) {}
}

Session row(String id, {bool pinned = false, double? at, bool? hidden}) =>
    Session(
      id: id,
      title: id,
      count: 1,
      startedAt: at ?? 100,
      activity: at ?? 100,
      source: 'api',
      pinned: pinned,
      hidden: hidden,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeBulkRepo repo;
  late LocalStore store;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    repo = FakeBulkRepo();
    container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        localStoreProvider.overrideWithValue(store),
        initialSettingsProvider.overrideWith(
          (ref) => const AppSettings(url: url, key: 'k'),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<void> boot(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedWrap(const SessionsPage(), locale: AppLocale.zhHant),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(); // providers resolve in microtasks
    }
  }

  Future<void> enterSelect(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.checklist));
    await tester.pump();
  }

  bool isChecked(WidgetTester tester, String id) => tester
      .widget<Checkbox>(
        find.descendant(
          of: find.byKey(ValueKey('$url|$id')),
          matching: find.byType(Checkbox),
        ),
      )
      .value!;

  int selectedCount(WidgetTester tester) {
    final label = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .firstWhere((t) => t.startsWith('已選 '));
    return int.parse(label.substring(3, label.indexOf(' 筆')));
  }

  Future<void> scrollToCard(WidgetTester tester, String id) async {
    if (find.byKey(ValueKey('$url|$id')).evaluate().isEmpty) {
      await tester.dragUntilVisible(
        find.byKey(ValueKey('$url|$id')),
        find.byType(ListView).first,
        const Offset(0, -60),
      );
      await tester.pump();
    } else {
      final r = tester.getRect(find.byKey(ValueKey('$url|$id')));
      if (r.bottom > 600 || r.top < 0) {
        await tester.dragUntilVisible(
          find.byKey(ValueKey('$url|$id')),
          find.byType(ListView).first,
          const Offset(0, -60),
        );
        await tester.pump();
      }
    }
  }

  Future<void> pullRefresh(WidgetTester tester) async {
    // back to the true top first (scrollToCard may have scrolled down);
    // drag ON A CARD — the taller toolbar puts the ListView centre over
    // the search field, whose own gesture arena eats a centre drag.
    await tester.pumpAndSettle(); // retract the previous indicator
    final st = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(ListView).first,
        matching: find.byType(Scrollable),
      ).first,
    );
    st.position.jumpTo(0);
    await tester.pump();
    await tester.fling(
      find.byType(Card).first,
      const Offset(0, 280),
      1200,
    );
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }
    await tester.pump(const Duration(seconds: 1));
  }

  group('SessionSelection (pure model)', () {
    test('enter/toggle/union/clear semantics', () {
      final sel = SessionSelection()..enter(['a']);
      expect(sel.selecting, isTrue);
      expect(sel.selectedIds, {'a'});
      sel.toggle('b');
      sel.toggle('a'); // tap on a checked row UNCHECKS it
      expect(sel.selectedIds, {'b'});
      sel.selectAll(['c', 'b']); // union, never replace
      expect(sel.selectedIds, {'b', 'c'});
      sel.clearIds();
      expect(sel.selectedIds, isEmpty);
      expect(sel.selecting, isTrue); // clear does not exit
      sel.exit();
      expect(sel.selecting, isFalse);
    });

    test('retainExisting drops only vanished ids and reports them', () {
      final sel = SessionSelection()..enter(['a', 'b', 'c']);
      final removed = sel.retainExisting(['c', 'd']);
      expect(removed, {'a', 'b'});
      expect(sel.selectedIds, {'c'});
      expect(sel.outsideCount(['c']), 0);
      expect(sel.outsideCount(['c', 'd']), 0);
      sel.enter(['z']);
      expect(sel.outsideCount(['c']), 1);
    });
  });

  group('Phase 1 — selection mode on the real page', () {
    testWidgets('visible Select button enters; tap toggles without opening; '
        'cancel exits and clears', (tester) async {
      repo.rows = [row('a'), row('b')];
      await boot(tester);
      expect(find.byIcon(Icons.checklist), findsOneWidget);
      await enterSelect(tester);
      expect(find.byType(Checkbox), findsNWidgets(2));
      await tester.tap(find.byKey(const ValueKey('$url|a')));
      await tester.pump();
      expect(isChecked(tester, 'a'), isTrue);
      expect(find.text('已選 1 筆'), findsOneWidget);
      expect(find.byType(ChatPage), findsNothing); // no navigation, no markRead
      await tester.tap(find.byKey(const ValueKey('$url|a')));
      await tester.pump();
      expect(isChecked(tester, 'a'), isFalse);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(find.byType(Checkbox), findsNothing);
      await enterSelect(tester);
      expect(find.text('已選 0 筆'), findsOneWidget); // cleared, not kept
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
    });

    testWidgets('long-press enters selection with the row picked; the menu '
        'button keeps the single-item sheet', (tester) async {
      repo.rows = [row('a'), row('b')];
      await boot(tester);
      await tester.longPress(find.byKey(const ValueKey('$url|b')));
      await tester.pump();
      expect(find.byType(Checkbox), findsNWidgets(2));
      expect(isChecked(tester, 'b'), isTrue);
      expect(find.byType(ChatPage), findsNothing);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      // The trailing more_vert is a REAL button now.
      await tester.tap(find.byKey(const ValueKey('menu-a')));
      await tester.pumpAndSettle();
      expect(find.text('重新命名'), findsOneWidget); // the sheet is open
      Navigator.of(tester.element(find.byType(SessionsPage))).pop();
      await tester.pumpAndSettle();
    });

    testWidgets('select-all covers the whole filtered set across lazy rows, '
        'and filters never clear the selection (M-outside note)', (
      tester,
    ) async {
      repo.rows = [for (var i = 0; i < 600; i++) row('r$i')];
      await boot(tester);
      await enterSelect(tester);
      await tester.tap(find.byKey(const ValueKey('select-current')));
      await tester.pump();
      expect(
        find.text('已選 600 筆'),
        findsOneWidget,
        reason: 'the fetched list, not just mounted widgets (B4)',
      );
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pump();
      expect(find.text('已選 600 筆'), findsOneWidget); // filters keep ids
      expect(find.text('其中 600 筆不在目前列表'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'r1');
      await tester.pump();
      expect(find.text('已選 600 筆'), findsOneWidget);
      expect(find.text('其中 489 筆不在目前列表'), findsOneWidget);
      // UNION: another select-all under the narrowed filter adds nothing.
      await tester.tap(find.byKey(const ValueKey('select-current')));
      await tester.pump();
      expect(find.text('已選 600 筆'), findsOneWidget);
    });

    testWidgets('refresh: reorder/refetch keeps ids selected; a vanished id '
        'leaves the selection with a notice', (tester) async {
      repo.rows = [row('a'), row('b'), row('c')];
      await boot(tester);
      await enterSelect(tester);
      await scrollToCard(tester, 'a');
      await tester.tap(find.byKey(const ValueKey('$url|a')));
      await tester.pumpAndSettle();
      await scrollToCard(tester, 'b');
      await tester.tap(find.byKey(const ValueKey('$url|b')));
      await tester.pumpAndSettle();
      expect(selectedCount(tester), 2);
      // Same ids, brand-new objects, reordered — the selection must stand.
      repo.rows = [row('c'), row('b'), row('a')];
      await pullRefresh(tester);
      expect(selectedCount(tester), 2);
      await scrollToCard(tester, 'a');
      expect(isChecked(tester, 'a'), isTrue);
      expect(isChecked(tester, 'b'), isTrue);
      // A truly vanished id leaves the selection and is REPORTED.
      repo.rows = [row('a'), row('c')];
      await pullRefresh(tester);
      expect(selectedCount(tester), 1);
      expect(isChecked(tester, 'a'), isTrue);
      expect(find.textContaining('1 筆對話已不存在'), findsOneWidget);
    });

    testWidgets('Escape and Back exit the selection; Back never pops the '
        'list page', (tester) async {
      repo.rows = [row('a')];
      await boot(tester);
      await enterSelect(tester);
      expect(find.byType(Checkbox), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(Checkbox), findsNothing);
      await enterSelect(tester);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('HERMES'), findsOneWidget); // page still here
      expect(find.byType(Checkbox), findsNothing); // selection exited
    });
  });

  group('Phase 2 — the page writes through the shared pipeline', () {
    testWidgets('single hide from the row menu dual-writes (server PATCH '
        '+ local mirror), not local-only anymore', (tester) async {
      repo.rows = [row('a'), row('b')];
      await boot(tester);
      await tester.tap(find.byKey(const ValueKey('menu-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('隱藏此對話'));
      await tester.pump();
      await tester.pump();
      expect(repo.hiddenPatches, [('a', true)]);
      expect(store.isHidden(url, 'a'), isTrue);
      expect(repo.deletes, 0); // a hide is never a delete
    });

    testWidgets('DELETE cleanup is pure-local: no hidden PATCH for a '
        'deleted id', (tester) async {
      repo.rows = [row('a'), row('b')];
      await store.setHidden(url, 'a', true);
      await boot(tester);
      await tester.tap(find.byType(Switch)); // 顯示已隱藏
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('menu-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('刪除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('刪除').last); // confirm dialog
      await tester.pumpAndSettle();
      await tester.pump();
      expect(repo.deletes, 1);
      expect(repo.hiddenPatches, isEmpty); // B2: never PATCH a deleted id
      expect(store.isHidden(url, 'a'), isFalse); // mirror forgotten
    });
  });

  group('Phase 3 — the bulk toolbar', () {
    Future<void> pick(WidgetTester tester, String id) async {
      // taller Phase-3 header: scroll lazy rows on screen first
      await tester.ensureVisible(find.byKey(ValueKey('$url|$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('$url|$id')));
      await tester.pump();
    }

    testWidgets('select 3, hide: exactly 3 set-PATCHes, rows leave at '
        'batch end, auto-exit, no DELETE', (tester) async {
      repo.rows = [row('a'), row('b'), row('c')];
      await boot(tester);
      await enterSelect(tester);
      await pick(tester, 'a');
      await pick(tester, 'b');
      await pick(tester, 'c');
      await tester.tap(find.byKey(const ValueKey('hide-selected')));
      await tester.pump();
      await tester.pump();
      expect(repo.hiddenPatches.length, 3);
      expect(repo.hiddenPatches.map((p) => p.$2).toSet(), {true});
      expect(repo.deletes, 0);
      expect(find.byType(Checkbox), findsNothing); // auto exit
      // default view: hidden rows gone…
      expect(find.byKey(ValueKey('$url|a')), findsNothing);
      // …but visible with the switch on, and counted.
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(find.byKey(ValueKey('$url|b')), findsOneWidget);
      expect(find.text('顯示已隱藏（3）'), findsOneWidget);
    });

    testWidgets('one 503 among three: summary, failed row stays selected, '
        'retry PATCHes ONLY it, then exits', (tester) async {
      repo.rows = [row('a'), row('b'), row('c')];
      repo.hiddenFailStatus = {'b': 503};
      await boot(tester);
      await enterSelect(tester);
      await pick(tester, 'a');
      await pick(tester, 'b');
      await pick(tester, 'c');
      await tester.tap(find.byKey(const ValueKey('hide-selected')));
      await tester.pump();
      await tester.pump();
      expect(find.text('已完成 2 筆，1 筆未完成'), findsOneWidget);
      expect(isChecked(tester, 'b'), isTrue); // selection = failed only
      expect(selectedCount(tester), 1);
      expect(find.text('b'), findsWidgets); // persistent summary lists it
      repo.hiddenFailStatus = {};
      repo.hiddenPatches.clear();
      await tester.tap(find.byKey(const ValueKey('retry-unfinished')));
      await tester.pump();
      await tester.pump();
      expect(repo.hiddenPatches, [('b', true)]);
      expect(find.byType(Checkbox), findsNothing);
    });

    testWidgets('unhide batch touches hidden=false only; pins survive '
        'untouched (incl. pinned-hidden)', (tester) async {
      repo.rows = [row('a'), row('b'), row('p', pinned: true)];
      await store.setHidden(url, 'a', true);
      await store.setHidden(url, 'b', true);
      await store.setHidden(url, 'p', true);
      await boot(tester);
      await tester.tap(find.byType(Switch)); // 顯示已隱藏
      await tester.pump();
      await enterSelect(tester);
      await tester.tap(find.byKey(const ValueKey('select-current')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('unhide-selected')));
      await tester.pump();
      await tester.pump();
      expect(repo.hiddenPatches.length, 3);
      expect(repo.hiddenPatches.map((p) => p.$2).toSet(), {false});
      expect(repo.patchPinned, 0); // B4: a hide batch never rewrites pins
      expect(store.isHidden(url, 'p'), isFalse);
      expect(find.text('已完成 3 筆，0 筆未完成'), findsOneWidget);
    });

    testWidgets('already-at-target rows are NO-OPs: counted, not PATCHed', (
      tester,
    ) async {
      repo.rows = [row('a', hidden: true)];
      await store.setHidden(url, 'a', true);
      await store.ensureHiddenMigration(url); // marker set…
      await store.resolveLegacyHidden(url, ['a']); // …and this id retired
      await boot(tester);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      await enterSelect(tester);
      await pick(tester, 'a');
      await tester.tap(find.byKey(const ValueKey('hide-selected')));
      await tester.pump();
      await tester.pump();
      expect(repo.hiddenPatches, isEmpty); // B4 no-op: no needless PATCH
      expect(find.text('已完成 1 筆，0 筆未完成'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing); // auto-exit
    });

    testWidgets('applying freezes order and controls; progress updates', (
      tester,
    ) async {
      repo.rows = [row('a'), row('b')];
      final gate = Completer<void>();
      repo.gate = gate;
      await boot(tester);
      await enterSelect(tester);
      await pick(tester, 'a');
      await pick(tester, 'b');
      await tester.tap(find.byKey(const ValueKey('hide-selected')));
      await tester.pump();
      expect(find.text('處理中：0/2'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(
                of: find.byKey(ValueKey('$url|a')),
                matching: find.byType(Checkbox),
              ),
            )
            .onChanged,
        isNull,
      );
      expect(find.byKey(ValueKey('$url|b')), findsOneWidget); // frozen
      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(find.byType(Checkbox), findsNothing); // done
    });

    testWidgets('legacy banner persists until synced; its select-then-'
        'hide pipeline retires it', (tester) async {
      // old build left hidden ids LOCAL-only; new boots must freeze them
      // as pending, never silently upload or erase them.
      SharedPreferences.setMockInitialValues({
        'hidden.$url': ['l1'],
      });
      store = LocalStore(await SharedPreferences.getInstance());
      repo.rows = [row('l1'), row('k1')];
      await boot(tester);
      expect(find.text('有 1 筆舊隱藏設定尚未同步'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('select-legacy')));
      await tester.pump();
      expect(find.text('已選 1 筆'), findsOneWidget); // showHidden on, l1 picked
      await tester.tap(find.byKey(const ValueKey('hide-selected')));
      await tester.pump();
      await tester.pump();
      expect(repo.hiddenPatches, [('l1', true)]);
      expect(find.text('有 1 筆舊隱藏設定尚未同步'), findsNothing);
    });

    testWidgets('English summary renders through the same typed catalog', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      store = LocalStore(await SharedPreferences.getInstance());
      repo.rows = [row('a')];
      repo.hiddenFailStatus = {'a': 503};
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: localizedWrap(const SessionsPage(), locale: AppLocale.en),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      await tester.tap(find.byIcon(Icons.checklist));
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('$url|a')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hide-selected')));
      await tester.pump();
      await tester.pump();
      expect(find.text('0 completed; 1 not completed'), findsOneWidget);
    });
  });
}
