import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/localized_app.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/chat/viewers.dart';
import 'package:hermes_app/features/sessions/sessions_page.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/providers.dart';

/// AUDIT-21 (D1) regressions. Red on old code because of the target
/// behaviour (fixtures compile identically):
///   * old open() awaited markRead BEFORE navigating, so a second tap
///     landing inside that await pushed a SECOND route for the same sid
///     (test 2: two ChatPages after one gated markRead).
///   * old dispose detached unconditionally, so the first pop of two
///     routes cut the SSE the other route was still watching (test 3).

const url = 'http://test.invalid';
final sessionS = Session(
  id: 's',
  title: 'S',
  count: 1,
  startedAt: 0,
  activity: 0,
  source: 'api_server',
);

class FakeNavRepo extends HermesRepository {
  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  FakeNavRepo() : super(url, 'fake');

  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async =>
      {'id': sid, 'message_count': 0}; // R1 sync clock: quiet by default
  final events = StreamController<SseEvent>.broadcast();
  int sends = 0, cancels = 0;
  @override
  Future<void> checkCapabilities() async {}
  @override
  Future<List<Session>> sessions() async => [sessionS];
  @override
  Future<bool> health() async => true;
  // SessionsPage watches skillsProvider; without this the base class
  // would hit the stubbed HttpClient and riverpod's retry timer would
  // outlive the test.
  @override
  Future<List<Skill>> skills() async => const [];
  @override
  Future<Json> runStatus(String runId) async => {'status': 'completed'};
  @override
  Future<List<Message>> messages(
    String sid, {
    int offset = 0,
    int limit = 200,
  }) async => const [];
  @override
  Stream<SseEvent> chat(String sid, String input) {
    sends++;
    return events.stream;
  }

  // Deliberately does NOT close the stream: the turn must stay alive
  // across the first pop so the detach decision is observable.
  @override
  void cancelStream(String sid) => cancels++;
}

class GatedStore extends LocalStore {
  GatedStore(super.prefs);
  Completer<void>? gate;
  int markReads = 0;
  @override
  Future<void> markRead(String server, String sid, String fingerprint) {
    markReads++;
    final g = gate;
    if (g == null) return super.markRead(server, sid, fingerprint);
    return g.future.then((_) => super.markRead(server, sid, fingerprint));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  late FakeNavRepo repo;
  late ProviderContainer container;

  Future<void> boot(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    store = GatedStore(await SharedPreferences.getInstance());
    repo = FakeNavRepo();
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
    addTearDown(repo.events.close);
  }

  setUp(() => ChatViewers.reset());

  test('viewer ledger: acquire/release 1->0 and the opening claim', () {
    expect(ChatViewers.count('a'), 0);
    // Never-tracked page: release still answers "you are the last one"
    // so pages mounted outside open() keep the old pop-detaches semantics.
    expect(ChatViewers.release('a'), isTrue);
    ChatViewers.acquire('a');
    ChatViewers.acquire('a');
    expect(ChatViewers.release('a'), isFalse); // one viewer remains
    expect(ChatViewers.release('a'), isTrue); // 1 -> 0: detach now
    expect(ChatViewers.claimOpening('b'), isTrue);
    expect(ChatViewers.claimOpening('b'), isFalse); // claim is sync + once
    ChatViewers.releaseOpening('b');
    expect(ChatViewers.claimOpening('b'), isTrue);
  });

  testWidgets(
    'AUDIT-21 fast double tap must not stack two routes for one sid',
    (tester) async {
      await boot(tester);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: localizedWrap(const SessionsPage()),
        ),
      );
      // Only clock-free pumps here: SessionsPage runs a 30s periodic
      // health timer that would keep a clock-advancing settle alive
      // forever under fake async.
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }

      final gate = Completer<void>();
      (store as GatedStore).gate = gate; // hold open() inside markRead's await
      await tester.tap(find.text('S'));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('S')); // second tap inside the await window
      await tester.pump();
      await tester.pump();

      gate.complete();
      (store as GatedStore).gate = null;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300)); // push transition
      await tester.pump();

      expect(
        find.byType(ChatPage),
        findsOneWidget,
        reason: 'second tap must focus/ignore, never stack a second route',
      );
      expect(
        (store as GatedStore).markReads,
        1,
        reason: 'the deduped tap must not run the open() body at all',
      );
    },
  );

  testWidgets(
    'AUDIT-21 two routes for one sid: first pop must NOT detach',
    (tester) async {
      await boot(tester);
      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: localizedWrap(
            navigatorKey: navKey,
            Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => ChatPage(session: sessionS),
                    ),
                  ),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go')); // route 1
      await tester.pumpAndSettle();
      // route 2 for the SAME sid, pushed under the open page (the shape
      // old code could produce via stacked double-open / future entry
      // points; registry semantics must survive it).
      navKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => ChatPage(session: sessionS)),
      );
      await tester.pumpAndSettle();

      final chat = container.read(chatProvider('s'));
      unawaited(chat.send('hello')); // send() only returns at turn end
      await tester.pump();
      await tester.pump();
      repo.events.add(
        const SseEvent('run.started', '{"run_id":"r1"}'),
      ); // give the turn a runId
      await tester.pump();
      expect(chat.busy, isTrue);

      navKey.currentState!.pop(); // pop route 2, route 1 keeps watching
      // Bounded pumps only: the typing indicator's repeat ticker (and the
      // 10s silence timer inside the running send) would keep a
      // clock-advancing pumpAndSettle alive forever while the turn lives.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(chat.detached, isFalse, reason: 'a page is still watching');
      expect(
        repo.cancels,
        0,
        reason: 'the SSE of a watched page must survive',
      );

      navKey.currentState!.pop(); // last viewer leaves: detach NOW
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(
        repo.cancels,
        greaterThan(0),
        reason: 'only the 1->0 pop may cut the stream',
      );
      // The detached immediate poll checks r1 (completed) and settles,
      // retiring the watch timer before the test ends.
      await tester.pump();
      await tester.pump();
      expect(chat.busy, isFalse);
    },
  );
}
