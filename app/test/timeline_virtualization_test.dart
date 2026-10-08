import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/l10n/app_locale.dart';

import 'support/localized_app.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/chat/message_timeline.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/providers.dart';

/// OPENPERF P1 (定案1): the durable timeline must be built row-by-row
/// (viewport virtualization), never as one eager Column. Timing baseline
/// from .perf-scratch/render-probe.log at f134e52 (200 rows, debug):
/// native ~1886 ms / Chrome ~4863 ms, 200 EntryViews mounted. Thresholds
/// here are deliberately relaxed (CI machines vary); they only have to
/// catch a regression BACK to eager full-Column mounting.
class FakePerfRepo extends HermesRepository {
  FakePerfRepo() : super('http://test.invalid', 'fake');

  final events = StreamController<SseEvent>.broadcast();
  List<Message> history = const [];
  List<Message> olderHistory = const [];

  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);

  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async => {
    'id': sid,
    'message_count': 0,
  };

  @override
  Stream<SseEvent> chat(String sid, String input, {String? wakeBatch}) =>
      events.stream;

  @override
  Future<List<Message>> messages(
    String sid, {
    int offset = 0,
    int limit = 200,
  }) async => offset == 0 ? history : olderHistory;
}

List<Message> heavyHistory(int n) {
  final text = List.filled(
    12,
    'Paragraph **bold** and a https://example.org/path link.\n\n',
  ).join();
  return List.generate(
    n,
    (i) => Message(
      id: 'm$i',
      role: i.isEven ? 'user' : 'assistant',
      content: '$text($i)',
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakePerfRepo repo;
  late ProviderContainer container;
  const url = 'http://test.invalid';
  final sessionA = Session(
    id: 's',
    title: 'A',
    count: 200,
    startedAt: 0,
    activity: 0,
    source: 'api_server',
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repo = FakePerfRepo();
    container = ProviderContainer(
      overrides: [
        localStoreProvider.overrideWithValue(
          LocalStore(await SharedPreferences.getInstance()),
        ),
        initialSettingsProvider.overrideWithValue(
          const AppSettings(url: url, key: 'fake'),
        ),
        repositoryProvider.overrideWithValue(repo),
        skillsProvider.overrideWith((ref) async => []),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    if (!repo.events.isClosed) unawaited(repo.events.close());
    repo.close();
  });

  testWidgets('200-message first build stays viewport-sized (P1 pin)', (
    tester,
  ) async {
    repo.history = heavyHistory(200);
    final sw = Stopwatch()..start();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedWrap(
          ChatPage(session: sessionA),
          locale: AppLocale.zhHant,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    sw.stop();
    final mounted = find
        .byType(EntryView, skipOffstage: false)
        .evaluate()
        .length;
    // Baseline: 200/200 mounted, ~1.9 s. A virtualized first build must land
    // far below both — relaxed caps that only a full-Column regression trips.
    expect(mounted, lessThan(40), reason: 'timeline must not mount every row');
    expect(
      sw.elapsedMilliseconds,
      lessThan(1200),
      reason:
          'first pump of 200 rows must stay far under the ~1.9 s eager baseline',
    );
  });

  testWidgets('load-older keeps the rows under the reader anchored', (
    tester,
  ) async {
    repo.history = List.generate(
      200,
      (i) => Message(
        id: 'm$i',
        role: i.isEven ? 'user' : 'assistant',
        content: '較新的訊息 $i',
        timestamp: 2000.0 + i,
      ),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedWrap(
          ChatPage(session: sessionA),
          locale: AppLocale.zhHant,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    repo.olderHistory = List.generate(
      50,
      (i) => Message(
        id: 'o$i',
        role: i.isEven ? 'user' : 'assistant',
        content: '更舊的訊息 $i',
        timestamp: 1000.0 + i,
      ),
    );
    // Park at the TOP: the auto-load gate fires loadOlder at offset < 80
    // (the same older() anchor path the in-list button takes).
    // The composer's TextField carries its own Scrollable — target the
    // timeline view by its stable page key.
    final timelineScroll = find
        .descendant(
          of: find.byKey(const ValueKey('chat.timelineScroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    final pos = tester.state<ScrollableState>(timelineScroll).position;
    pos.jumpTo(0);
    await tester.pump();
    // Sample the anchor row in the SAME frame the top is established —
    // the auto-fired loadOlder only begins after this frame settles.
    final rowBefore = tester.getTopLeft(find.text('較新的訊息 0'));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    // The prepended page must not yank the viewport: the row the reader was
    // looking at keeps its screen position (older rows land ABOVE it).
    final rowAfter = tester.getTopLeft(find.text('較新的訊息 0'));
    expect((rowAfter - rowBefore).dy.abs(), lessThan(2.0));
    expect(find.text('較新的訊息 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
