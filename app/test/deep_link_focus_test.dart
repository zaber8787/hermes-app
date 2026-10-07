import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/chat/run_link.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/session_activity.dart';

/// 01412FIX F5 (M6): in-session deep-link focus — the named event converges
/// as READ (exactly once), the named approval request is the ONE focused
/// card, the named run is exposed. Unknown ids match NOTHING.
class LinkRepo extends HermesRepository {
  LinkRepo() : super('http://test.invalid', 'fake');
  final List<String> reads = [];

  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);

  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async =>
      {'id': sid, 'message_count': 0};

  @override
  Future<Map<String, dynamic>> notificationRead(String eventId) async {
    reads.add(eventId);
    return {'event_id': eventId, 'read': true};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
  });

  test('applyDeepLink: event read once, approval + run focused', () async {
    final repo = LinkRepo();
    final c = ChatController(repo, store, 's');
    c.applyDeepLink(
      const RunLink(sessionId: 's', runId: 'r9', eventId: 'e7', requestId: 'q3'),
    );
    await pumpEventQueue();
    expect(repo.reads, ['e7']); // read != approve: just the ledger ack
    expect(c.approvalFocus, 'q3');
    expect(c.focusedRunId, 'r9');
    c.applyDeepLink(const RunLink(sessionId: 's', eventId: 'e7'));
    await pumpEventQueue();
    expect(repo.reads.length, 1); // one ack per event, never spam
    c.dispose();
    repo.close();
  });
}
