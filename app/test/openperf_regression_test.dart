import 'dart:async';
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

/// OPENPERF P4 (定案1 防回退): the durable timeline must stay a row list.
/// Baseline f134e52 mounted ALL 200 EntryViews on first build (native
/// ~1886 ms / Chrome ~4863 ms debug — .perf-scratch/render-probe.log).
/// These pins are deliberately relaxed (CI varies); they only catch a
/// regression BACK to eager full-Column mounting: a first build that
/// mounts the whole page, or one that pays full-markdown layout for every
/// swept row during the cold-open jump.
class FakeOpenRepo extends HermesRepository {
  FakeOpenRepo() : super('http://test.invalid', 'fake');

  final events = StreamController<SseEvent>.broadcast();
  List<Message> history = const [];

  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);

  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async => {
    'id': sid,
    'message_count': 0, // P1 harness shape
  };

  @override
  Stream<SseEvent> chat(String sid, String input, {String? wakeBatch}) =>
      events.stream;

  @override
  Future<List<Message>> messages(
    String sid, {
    int offset = 0,
    int limit = 200,
  }) async => offset == 0 ? history : const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeOpenRepo repo;
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
  final heavy = () {
    final text = List.filled(
      12,
      'Paragraph **bold** and a https://example.org/path link.\n\n',
    ).join();
    return List.generate(
      200,
      (i) => Message(
        id: 'm${i.toString().padLeft(3, '0')}',
        role: i.isEven ? 'user' : 'assistant',
        content: '$text($i)',
      ),
    );
  }();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repo = FakeOpenRepo();
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

  testWidgets('200-row first build mounts a viewport-sized window (P4 pin)', (
    tester,
  ) async {
    repo.history = heavy;
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
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    sw.stop();
    // Relaxed from the ~1.9s/4.9s baseline; the ceiling only has to stay
    // clearly below an eager full page.
    expect(sw.elapsedMilliseconds, lessThan(2500));
    // The HARD structural pin: a first build that builds every row fails
    // here even on a machine fast enough to pass the timing gate.
    // Viewport + cacheExtent never needs more than a few dozen rows.
    expect(find.byType(EntryView).evaluate().length, lessThanOrEqualTo(60));
    // …and the landed page is still the real tail, not a stretch of
    // placeholders.
    final built = tester
        .widgetList<EntryView>(find.byType(EntryView))
        .map((e) => e.entry.message.id)
        .toList();
    expect(built, contains('m199'));
  });

  testWidgets('content of swept-but-unrevealed rows stays unbuilt (P4 pin)', (
    tester,
  ) async {
    repo.history = heavy;
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
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    // A placeholder window must not have paid MessageContent layout for
    // the far end of the page either way it is asked about.
    final built = tester
        .widgetList<EntryView>(find.byType(EntryView))
        .map((e) => e.entry.message.id)
        .toList();
    expect(built, isNot(contains('m000')));
    expect(built, isNot(contains('m001')));
  });
}
