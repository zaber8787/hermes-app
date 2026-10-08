import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session_activity.dart';

/// OPENPERF P2 (定案3): opening a chat must NOT serialise activity →
/// history, must NOT spinner-refetch on a warm re-entry, and the pending
/// recovery path must NOT read the same 200-row page twice. Each pin was
/// measured red against f134e52 (see .openperf-evidence/).
class OpenPerfRepo extends HermesRepository {
  OpenPerfRepo() : super('http://test.invalid', 'fake');

  final events = StreamController<SseEvent>.broadcast();
  List<Message> history = const [
    Message(id: '1', role: 'user', content: '甲'),
    Message(id: '2', role: 'assistant', content: '乙'),
  ];
  int messagesGets = 0;
  int activities = 0;
  int runStatuses = 0;
  Completer<SessionActivity>? activityGate;

  @override
  Future<SessionActivity> sessionActivity(String sid) {
    activities++;
    final gate = activityGate;
    if (gate == null) return Future.value(SessionActivity.quiet(sid));
    return gate.future;
  }

  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async => {
    'id': sid,
    'message_count': history.length,
  };

  @override
  Future<List<Message>> messages(
    String sid, {
    int offset = 0,
    int limit = 200,
  }) {
    messagesGets++;
    return Future.value(history);
  }

  @override
  Future<Map<String, dynamic>> runStatus(String runId) async {
    runStatuses++;
    return {'status': 'completed'};
  }

  @override
  Stream<SseEvent> chat(String sid, String input, {String? wakeBatch}) =>
      events.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late OpenPerfRepo repo;
  late LocalStore store;
  const sid = 's';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    repo = OpenPerfRepo();
  });

  ChatController make(WidgetTester tester) =>
      ChatController(repo, store, sid, now: tester.binding.clock.now);

  testWidgets('cold open reads history WITHOUT waiting for activity (P2)', (
    tester,
  ) async {
    final gate = Completer<SessionActivity>();
    repo.activityGate = gate;
    final c = make(tester);
    unawaited(c.bootstrap());
    await tester.pump();
    await tester.pump();
    // The history GET rides in parallel with the pending activity GET —
    // the 2s activity timeout must never gate the page's rows.
    expect(repo.messagesGets, 1);
    gate.complete(SessionActivity.quiet(sid));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(c.messages.map((m) => m.id), ['1', '2']);
    c.dispose();
  });

  testWidgets('warm re-entry keeps rows, shows no spinner, refetches no page', (
    tester,
  ) async {
    final c = make(tester);
    await c.bootstrap();
    expect(c.messages.length, 2);
    expect(repo.messagesGets, 1);

    c.bootstrap();
    await tester.pump();
    // Cached history stays on screen: no loading phase, no re-GET of the
    // latest page. (Revision drift — if any — rides the activity tick.)
    expect(c.loading, isFalse);
    expect(c.messages.length, 2);
    expect(repo.messagesGets, 1);
    c.dispose();
  });

  testWidgets('pending recovery settles the page with ONE latest-page GET', (
    tester,
  ) async {
    await store.savePending(
      'http://test.invalid',
      sid,
      userText: '甲',
      runId: 'r1',
    );
    final c = make(tester);
    await c.bootstrap();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    // runStatus(completed) and the best-effort history load must share
    // the one page flight (the 141 ms double GET in the log).
    expect(repo.messagesGets, 1);
    c.dispose();
  });
}
