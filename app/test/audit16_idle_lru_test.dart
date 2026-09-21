import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/localized_app.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/sessions/sessions_page.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/providers.dart';

/// AUDIT-16 regressions: a day of browsing must not mean "one retained
/// controller + foreground history GET per session, forever".
/// Deliberately written against only pre-existing public API so it also
/// COMPILES against the old app: red comes from the behaviour (nothing
/// was ever evicted; every idle controller refetched on resume), never
/// from a missing fixture helper.

const url = 'http://test.invalid';
final cur = Session(
  id: 'cur',
  title: 'CUR',
  count: 1,
  startedAt: 0,
  activity: 0,
  source: 'api_server',
);

class FakeLruRepo extends HermesRepository {
  int activityCalls = 0;
  @override
  Future<SessionActivity> sessionActivity(String sid) async {
    activityCalls++;
    return SessionActivity.quiet(sid);
  }
  FakeLruRepo() : super(url, 'fake');

  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async =>
      {'id': sid, 'message_count': 0}; // R1 sync clock: quiet by default
  final turnEvents = <String, StreamController<SseEvent>>{};
  int messagesCalls = 0;
  static const rows = [
    Message(id: 'm1', role: 'assistant', content: 'hello', timestamp: 1),
  ];
  @override
  Future<void> checkCapabilities() async {}
  @override
  Future<List<Session>> sessions() async => [cur];
  @override
  Future<bool> health() async => true;
  @override
  Future<List<Skill>> skills() async => const [];
  @override
  Future<List<Message>> messages(
    String sid, {
    int offset = 0,
    int limit = 200,
  }) async {
    messagesCalls++;
    return rows;
  }

  @override
  Stream<SseEvent> chat(String sid, String input) =>
      turnEvents.putIfAbsent(sid, () => StreamController<SseEvent>.broadcast())
          .stream;
  @override
  void cancelStream(String sid) {}
  @override
  Future<Json> runStatus(String runId) async => {'status': 'completed'};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeLruRepo repo;
  late ProviderContainer container;

  Future<void> boot() async {
    SharedPreferences.setMockInitialValues({});
    repo = FakeLruRepo();
    container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        localStoreProvider.overrideWithValue(
          LocalStore(await SharedPreferences.getInstance()),
        ),
        initialSettingsProvider.overrideWith(
          (ref) => const AppSettings(url: url, key: 'k'),
        ),
      ],
    );
    addTearDown(container.dispose);
  }

  Map<String, ChatController> visit(int n) => {
    for (var i = 0; i < n; i++) 's$i': container.read(chatProvider('s$i')),
  };

  Future<void> openAndPop(WidgetTester tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedWrap(const SessionsPage(), navigatorKey: navKey),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(); // clock-free: SessionsPage owns a 30s timer
    }
    await tester.tap(find.text('CUR'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // push transition
    await tester.pump();
    navKey.currentState!.pop(); // pop = the eviction trigger's natural point
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    await tester.pump(); // drain open()'s post-pop housekeeping
  }

  testWidgets(
    'AUDIT-16 past sessions are bounded: oldest idles evicted, newest kept',
    (tester) async {
      await boot();
      // "20 sessions already browsed today": controllers exist, idle.
      final orig = visit(20);
      await openAndPop(tester);

      // Bounded + LRU-ordered. (Whether the just-popped session already
      // counts as an idle resident depends on pop-vs-dispose timing, so
      // the assertable facts are: the NEWEST idles survive, NOTHING
      // older than the newest 8 survives, and at most 8 stay.)
      final kept = [
        for (var i = 0; i < 20; i++)
          if (identical(container.read(chatProvider('s$i')), orig['s$i'])) i,
      ];
      expect(
        kept.length,
        lessThanOrEqualTo(8),
        reason: 'idle controllers must be bounded (old code: all 20 kept)',
      );
      for (final i in kept) {
        expect(i, greaterThanOrEqualTo(12), reason: 'eviction must be LRU-ordered, not arbitrary');
      }
      for (var i = 13; i < 20; i++) {
        expect(
          identical(container.read(chatProvider('s$i')), orig['s$i']),
          isTrue,
          reason: 'the newest idles stay resident (LRU, not autoDispose)',
        );
      }
      // An evicted session re-enters as a fully working fresh controller.
      final rebuilt = container.read(chatProvider('s0'));
      await rebuilt.bootstrap();
      expect(rebuilt.messages, hasLength(1));
      rebuilt.dispose(); // R1: bootstrap's sync poll must not outlive the test
    },
  );

  testWidgets(
    'AUDIT-16 a session with a running turn survives the eviction sweep',
    (tester) async {
      await boot();
      final orig = visit(20);
      repo.turnEvents['busy'] = StreamController<SseEvent>.broadcast();
      final busyC = container.read(chatProvider('busy'));
      unawaited(busyC.send('go')); // page-less background turn (v0.12 shape)
      await tester.pump();
      await tester.pump();
      repo.turnEvents['busy']!.add(
        const SseEvent('run.started', '{"run_id":"rb"}'),
      );
      await tester.pump();
      expect(busyC.busy, isTrue);

      await openAndPop(tester);

      expect(busyC.busy, isTrue); // sweep must not have killed the run view
      expect(
        identical(container.read(chatProvider('busy')), busyC),
        isTrue,
        reason: 'running turns are exempt from the LRU (audit 16 rule 1)',
      );
      expect(
        identical(container.read(chatProvider('s0')), orig['s0']),
        isFalse, // still evicts the idles (red driver on old code)
        reason: 'idles are still bounded even while another session runs',
      );

      // End the turn so no send/silence timer outlives the test.
      repo.turnEvents['busy']!
        ..add(const SseEvent('run.completed', '{"messages":[]}'))
        ..add(const SseEvent('done', '{}'));
      await repo.turnEvents['busy']!.close();
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(busyC.busy, isFalse);
    },
  );

  testWidgets(
    'AUDIT-16 resume only fetches for visible pages and active runs',
    (tester) async {
      await boot();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: localizedWrap(ChatPage(session: cur)),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump(); // bootstrap load settles
      }
      visit(6); // six browsed-then-closed sessions: idle, page-less
      await tester.pump();
      final base = repo.messagesCalls, aBase = repo.activityCalls;

      // Route through the state machine Flutter validates (inactive ->
      // hidden -> paused -> hidden -> inactive -> resumed).
      for (final s in const [
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
        await tester.pump();
      }
      await tester.pump();

      // WAVE4: resume now reconciles through ONE activity GET for the
      // visible page only; a quiet revision must cost ZERO history GETs.
      // (Old code fanned out one history GET per retained idle controller.)
      expect(
        repo.activityCalls - aBase,
        1,
        reason: 'exactly one immediate activity GET, page-less controllers '
            'stay silent',
      );
      expect(
        repo.messagesCalls - base,
        0,
        reason: 'a quiet revision must not re-GET history on resume',
      );
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.inactive,
      );
    },
  );
}
