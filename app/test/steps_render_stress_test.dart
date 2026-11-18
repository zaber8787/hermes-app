// STEPSRENDER D0: render stress matrix for a turn with MANY tool steps.
// Three faces: A = MessageTimelineSliver mounted directly, B = ChatPage with
// a big durable history, C = ChatPage with few durable rows plus N LIVE tool
// steps (the suspect path: the box/sliver gate only counted durable
// messages, so a live run of N steps rode the one eager Column).
// Every cell RECORDS ms / tool-EntryViews / SelectionAreas via debugPrint —
// no timing assertions (plan §2.5); N=100/400 expanded cells are the pins.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_controller.dart'
    show ChatController;
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/chat/message_timeline.dart';
import 'package:hermes_app/features/chat/tool_timeline_projection.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'timeline_virtualization_test.dart' show FakePerfRepo;
import 'toolcard_dup_test.dart' show durableTurn;
import 'support/localized_app.dart';

const q = '幫我整理這份報告的重點';
const url = 'http://test.invalid';
// Post-fix windowed-group cap (plan D2); pinned here as the expected value.
const cap = 40;

Message liveToolsMessage(int n) => Message(
  id: 'live-tools',
  role: 'assistant',
  content: '',
  timestamp: 0,
  toolCalls: [
    for (var i = 1; i <= n; i++) ToolCall('live#$i', 't$i', '{"i":$i}'),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakePerfRepo repo;
  late LocalStore store;
  late ProviderContainer container;
  final session = Session(
    id: 's',
    title: 'A',
    count: 0,
    startedAt: 0,
    activity: 0,
    source: 'api_server',
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repo = FakePerfRepo();
    store = LocalStore(await SharedPreferences.getInstance());
    container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        localStoreProvider.overrideWithValue(store),
        initialSettingsProvider.overrideWithValue(
          const AppSettings(url: url, key: 'fake'),
        ),
        skillsProvider.overrideWith((ref) async => []),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    if (!repo.events.isClosed) unawaited(repo.events.close());
    repo.close();
  });

  ChatController ctrl() => container.read(chatProvider('s'));

  Future<void> openPage(
    WidgetTester tester, {
    Size size = const Size(1400, 12000),
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedWrap(ChatPage(session: session), locale: AppLocale.en),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Future<void> sendUi(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
  }

  // Finite pumps only: a live turn animates typing dots forever, so
  // pumpAndSettle is off the table (toolcard_dup_test precedent).
  Future<void> closeAll(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await repo.events.close();
    await tester.pump();
  }

  Future<void> frames(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  List<EntryView> toolEntries(WidgetTester tester) => tester
      .widgetList<EntryView>(find.byType(EntryView))
      .where((e) => e.entry.kind == EntryKind.tool)
      .toList();

  int nonToolEntries(WidgetTester tester) => tester
      .widgetList<EntryView>(find.byType(EntryView))
      .where((e) => e.entry.kind != EntryKind.tool)
      .length;

  int selAreas(WidgetTester tester) =>
      find.byType(SelectionArea).evaluate().length;

  /// No NON-NULL key may appear twice among the children of any element.
  /// Global collection would false-positive: the same slot key may legally
  /// live in two different subtrees (durable timeline + live transcript).
  void expectNoDuplicateSiblingKeys(WidgetTester tester) {
    for (final el in tester.allElements) {
      final seen = <Key>{};
      el.visitChildren((c) {
        final k = c.widget.key;
        if (k != null && !seen.add(k)) {
          fail('duplicate sibling key $k under ${el.widget.runtimeType}');
        }
      });
    }
  }

  Future<void> sweep200(WidgetTester tester) async {
    final state = tester.state<ScrollableState>(find.byType(Scrollable).first);
    final max = state.position.maxScrollExtent;
    for (var off = 0.0; off <= max; off += 200) {
      state.position.jumpTo(off);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'at offset $off');
    }
  }

  Future<void> cell(
    WidgetTester tester, {
    required String face,
    required bool detailed,
    required int n,
  }) async {
    if (detailed) await store.setDetailed(url, 's', true);
    final sw = Stopwatch()..start();
    if (face == 'A') {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1400, 12000);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        localizedApp(
          SizedBox(
            width: 1400,
            height: 12000,
            child: Material(
              child: CustomScrollView(
                slivers: [
                  MessageTimelineSliver(
                    messages: durableTurn(n),
                    detailed: detailed,
                    reveal: const TimelineReveal(
                      pixels: 0,
                      viewport: 800,
                      revision: 0,
                      realFrom: -20,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    } else if (face == 'B') {
      repo.history = durableTurn(n);
      await openPage(tester);
      for (var i = 0; i < 10; i++) {
        await tester.pump();
      }
    } else {
      repo.history = const [
        Message(id: '1', role: 'user', content: '舊話', timestamp: 1),
        Message(id: '2', role: 'assistant', content: '好', timestamp: 2),
      ];
      await openPage(tester);
      await sendUi(tester, q);
      repo.events.add(
        const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
      );
      await tester.pump();
      // The whole live run lands in ONE batch: N started+completed pairs
      // with no pump between, so the first frame after this sees the full
      // N-step live tail (the incident's worst case, not a gradual build).
      for (var i = 1; i <= n; i++) {
        repo.events.add(
          SseEvent(
            'tool.started',
            '{"tool_name":"t$i","args":{"i":$i},"seq":$i}',
          ),
        );
        repo.events.add(
          SseEvent('tool.completed', '{"tool_name":"t$i","preview":"done"}'),
        );
      }
      sw.start();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(ctrl().live, isNotNull);
      expect(ctrl().live!.tools.length, n);
      expect(ctrl().live!.transcript, isNull);
    }
    sw.stop();
    debugPrint(
      'STEPSRENDER face=$face mode=${detailed ? 'detailed' : 'brief'} '
      'N=$n ms=${sw.elapsedMilliseconds} toolEV=${toolEntries(tester).length} '
      'selArea=${selAreas(tester)}',
    );
    expect(tester.takeException(), isNull);
    if (detailed) {
      await sweep200(tester);
      expectNoDuplicateSiblingKeys(tester);
      await closeAll(tester);
      return;
    }
    // BRIEF: the collapsed group is the only count surface.
    expect(
      find.text(t(MessageKey.timelineM001, count: n)).evaluate().length,
      1,
    );
    final expectedNonTool = face == 'C'
        ? 2 + (ctrl().pendingBubbleText != null ? 1 : 0)
        : 3;
    expect(nonToolEntries(tester), expectedNonTool);
    await tester.tap(find.text(t(MessageKey.timelineM001, count: n)));
    await frames(tester);
    expect(tester.takeException(), isNull);
    final expanded = toolEntries(tester);
    debugPrint(
      'STEPSRENDER-EXPANDED face=$face N=$n toolEV=${expanded.length}',
    );
    expect(expanded.length, n <= cap ? n : cap);
    expect(
      find.byKey(const ValueKey('timeline.window.earlier')),
      n <= cap ? findsNothing : findsOneWidget,
    );
    expectNoDuplicateSiblingKeys(tester);
    await closeAll(tester);
  }

  for (final n in [25, 100, 400]) {
    for (final detailed in [false, true]) {
      final mode = detailed ? 'detailed' : 'brief';
      testWidgets('face A sliver-direct N=$n $mode', (tester) async {
        await cell(tester, face: 'A', detailed: detailed, n: n);
      });
      testWidgets('face B chatpage-durable N=$n $mode', (tester) async {
        await cell(tester, face: 'B', detailed: detailed, n: n);
      });
      testWidgets('face C chatpage-live N=$n $mode', (tester) async {
        await cell(tester, face: 'C', detailed: detailed, n: n);
      });
    }
  }

  group('root cause', () {
    testWidgets(
      'R1: a 400-step LIVE turn keeps mounted tool rows viewport-bounded',
      (tester) async {
        await store.setDetailed(url, 's', true);
        repo.history = const [
          Message(id: '1', role: 'user', content: '舊話', timestamp: 1),
          Message(id: '2', role: 'assistant', content: '好', timestamp: 2),
        ];
        await openPage(tester, size: const Size(1400, 900));
        await sendUi(tester, q);
        repo.events.add(
          const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
        );
        await tester.pump();
        for (var i = 1; i <= 400; i++) {
          repo.events.add(
            SseEvent(
              'tool.started',
              '{"tool_name":"t$i","args":{"i":$i},"seq":$i}',
            ),
          );
        }
        await tester.pump();
        await tester.pump();
        await tester.pump();
        final mounted = toolEntries(tester).length;
        debugPrint('STEPSRENDER-R1 toolEV=$mounted');
        expect(mounted, lessThanOrEqualTo(60));
        await closeAll(tester);
      },
    );

    testWidgets('R2: a recycled group keeps its step slot keys (H2)', (
      tester,
    ) async {
      final msgs = <Message>[
        ...durableTurn(10),
        for (var i = 0; i < 40; i++) ...[
          Message(id: 'fu$i', role: 'user', content: '填充 $i', timestamp: 2.0 + i),
          Message(
            id: 'fa$i',
            role: 'assistant',
            content: '長回答' * 30,
            timestamp: 3.0 + i,
          ),
        ],
      ];
      await tester.pumpWidget(
        localizedApp(
          SizedBox(
            width: 800,
            height: 600,
            child: Material(
              child: CustomScrollView(
                slivers: [MessageTimelineSliver(messages: msgs, detailed: false)],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final title = find.text(t(MessageKey.timelineM001, count: 10));
      expect(title, findsOneWidget);
      await tester.tap(title);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final state = tester.state<ScrollableState>(find.byType(Scrollable).first);
      state.position.jumpTo(state.position.maxScrollExtent);
      await tester.pump();
      await tester.pump();
      expect(
        find.text(t(MessageKey.timelineM001, count: 10)),
        findsNothing,
        reason: 'precondition: the group row was recycled off-viewport',
      );
      state.position.jumpTo(0);
      await tester.pump();
      await tester.pump();
      // A recycled group may come back expanded (hidden-element state) or
      // collapsed — expand only if it came back collapsed.
      if (toolEntries(tester).isEmpty) {
        await tester.tap(find.text(t(MessageKey.timelineM001, count: 10)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }
      final steps = toolEntries(tester);
      expect(
        steps.every((e) => e.key != null),
        isTrue,
        reason: 'H2: re-running the group Builder re-consumed seenKeys '
            'and stripped every step slot key',
      );
      expect(steps.length, 10);
    });

    test('R3: toolSlotKeyFor cost on a 400-call live row (record only)', () {
      for (final n in [25, 100, 400]) {
        final entries = projectMessages([liveToolsMessage(n)])
            .where((e) => e.kind == EntryKind.tool)
            .toList();
        expect(entries.length, n);
        final sw = Stopwatch()..start();
        for (var r = 0; r < 100; r++) {
          for (final e in entries) {
            toolSlotKeyFor(e, 's');
          }
        }
        sw.stop();
        final per = sw.elapsedMicroseconds / 100;
        debugPrint(
          'STEPSRENDER-R3 N=$n µs/pass=${per.toStringAsFixed(1)} '
          'est4passes=${(per * 4).toStringAsFixed(1)}',
        );
      }
    });
  });
}
