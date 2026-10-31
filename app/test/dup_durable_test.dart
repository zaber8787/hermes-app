import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/l10n/app_locale.dart';

import 'support/localized_app.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/chat/tool_timeline_projection.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/providers.dart';

import 'audit_cross_device_sync_test.dart' show FakeSyncRepo;

/// DUPDURABLE: a core compression rebuild re-appends old rows (tool_calls
/// included) under NEW row ids — the same wire call id then sits on 2-3
/// durable rows, and the per-row projection rendered every copy, piled at
/// the bottom (rebuild rows carry the largest row ids).

const q = '幫我整理這份報告的重點';

/// One real turn (user + assistant call C1 + result) followed by [copies]
/// rebuild batches that replay the same assistant call + result rows under
/// fresh row ids — the shape measured in state.db.
List<Message> rebuiltHistory(int copies, {double ts = 1000}) {
  final rows = <Message>[
    Message(id: '1', role: 'user', content: q, timestamp: ts),
  ];
  var id = 2;
  for (var k = 0; k <= copies; k++) {
    rows.add(
      Message(
        id: '${id++}',
        role: 'assistant',
        timestamp: ts,
        toolCalls: const [ToolCall('C1', 'terminal', '{"cmd":"ls"}')],
      ),
    );
    rows.add(
      Message(
        id: '${id++}',
        role: 'tool',
        toolCallId: 'C1',
        toolName: 'terminal',
        content: 'ok',
        timestamp: ts,
      ),
    );
  }
  return rows;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('dedupDurableToolCalls (pure)', () {
    test('no duplicates → no exclusions, no overrides', () {
      final rows = [
        const Message(id: '1', role: 'user', content: q),
        const Message(
          id: '2',
          role: 'assistant',
          toolCalls: [
            ToolCall('C1', 'a', '{}'),
            ToolCall('C2', 'b', '{}'),
          ],
        ),
        const Message(id: '3', role: 'tool', toolCallId: 'C1', content: 'x'),
        const Message(id: '4', role: 'tool', toolCallId: 'C2', content: 'y'),
      ];
      final d = dedupDurableToolCalls('s', rows);
      expect(d.excluded, isEmpty);
      expect(d.overrides, isEmpty);
    });

    test('same id three times → first-seen slot stays, later two excluded', () {
      final d = dedupDurableToolCalls('s', rebuiltHistory(2));
      expect(d.excluded, {'s#4#c0', 's#6#c0'});
      expect(d.overrides, isEmpty, reason: 'identical copies upgrade nothing');
    });

    test('a later copy with fuller arguments upgrades the first slot', () {
      final rows = [
        const Message(id: '1', role: 'user', content: q),
        const Message(
          id: '2',
          role: 'assistant',
          toolCalls: [ToolCall('C1', 'terminal', '')],
        ),
        const Message(
          id: '9',
          role: 'assistant',
          toolCalls: [ToolCall('C1', 'terminal', '{"cmd":"ls"}')],
        ),
      ];
      final d = dedupDurableToolCalls('s', rows);
      expect(d.excluded, {'s#9#c0'});
      expect(d.overrides.keys, ['s#2#c0']);
      expect(d.overrides['s#2#c0']!.arguments, '{"cmd":"ls"}');
    });

    test('duplicated orphan results (no assistant call) collapse too', () {
      final rows = [
        const Message(id: '1', role: 'user', content: q),
        const Message(id: '2', role: 'tool', toolCallId: 'R1', content: ''),
        const Message(id: '7', role: 'tool', toolCallId: 'R1', content: 'out'),
      ];
      final d = dedupDurableToolCalls('s', rows);
      expect(d.excluded, {'s#7#r'});
      expect(d.overrides['s#2#r']!.result, 'out');
    });

    test('text-only duplicates and id-less calls are never collapsed', () {
      final rows = [
        const Message(id: '1', role: 'user', content: q),
        const Message(id: '2', role: 'assistant', content: 'same'),
        const Message(id: '3', role: 'user', content: q),
        const Message(id: '4', role: 'assistant', content: 'same'),
        const Message(
          id: '5',
          role: 'assistant',
          toolCalls: [ToolCall('', 'a', '{}'), ToolCall('', 'a', '{}')],
        ),
      ];
      final d = dedupDurableToolCalls('s', rows);
      expect(d.excluded, isEmpty);
    });
  });

  group('chat page', () {
    late FakeSyncRepo repo;
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
      repo = FakeSyncRepo();
      store = LocalStore(await SharedPreferences.getInstance());
      container = ProviderContainer(
        overrides: [
          repositoryProvider.overrideWithValue(repo),
          localStoreProvider.overrideWithValue(store),
          initialSettingsProvider.overrideWith(
            (ref) => const AppSettings(url: 'http://test.invalid', key: 'k'),
          ),
        ],
      );
      addTearDown(container.dispose);
    });

    Future<void> openPage(WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1400, 12000);
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

    Future<void> closeAll(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await repo.events.close();
      await tester.pump();
    }

    testWidgets(
      'DUPDURABLE: durable history with the same call id three times renders ONE tool row',
      (tester) async {
        await store.setDetailed('http://test.invalid', 's', true);
        repo.history = rebuiltHistory(2);
        await openPage(tester);
        expect(
          find.text('terminal').evaluate().length,
          1,
          reason: 'compression-rebuild copies of C1 rendered more than once',
        );
        await closeAll(tester);
      },
    );

    testWidgets(
      'DUPDURABLE: duplicated plain text rows are left alone (out of scope)',
      (tester) async {
        await store.setDetailed('http://test.invalid', 's', true);
        repo.history = const [
          Message(id: '1', role: 'user', content: q),
          Message(id: '2', role: 'assistant', content: '重複的回覆'),
          Message(id: '3', role: 'user', content: q),
          Message(id: '4', role: 'assistant', content: '重複的回覆'),
        ];
        await openPage(tester);
        expect(find.text('重複的回覆').evaluate().length, 2);
        await closeAll(tester);
      },
    );
  });
}
