import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/session_activity.dart';

class _NotificationRepo extends HermesRepository {
  _NotificationRepo() : super('http://test.invalid', 'fake');
  int probes = 0;
  bool failFirst = true;
  int watchAttempts = 0;

  @override
  Future<Map<String, dynamic>> notificationWatch(
    String runId, {
    bool on = true,
  }) async {
    watchAttempts++;
    if (watchAttempts == 1) throw StateError('watch unavailable');
    return {'watching': true};
  }

  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);

  @override
  Future<Map<String, dynamic>?> notificationEventsFeature() async {
    probes++;
    if (failFirst && probes == 1) throw StateError('temporary outage');
    return {'enabled': true, 'system_channel': 'ntfy'};
  }

  @override
  Future<Map<String, dynamic>> notificationEvents({int after = 0}) async => {
    'data': [],
    'server_channel': 'ntfy',
    'head_seq': 0,
    'next_cursor': after,
    'overflow': false,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'temporary capability failure retries after backoff and enables inbox',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      final repo = _NotificationRepo();
      var now = DateTime.utc(2026);
      final c = ChatController(repo, store, 's', now: () => now);
      await c.refreshActivity();
      await pumpEventQueue();
      expect(repo.probes, 1);
      expect(c.notificationEventsEnabled, isFalse);
      await c.refreshActivity();
      await pumpEventQueue();
      expect(repo.probes, 1, reason: 'do not poll on every activity tick');
      now = now.add(const Duration(minutes: 1));
      await c.refreshActivity();
      await pumpEventQueue();
      expect(repo.probes, 2);
      expect(c.notificationEventsEnabled, isTrue);
      c.dispose();
      repo.close();
    },
  );

  test('explicit watch failure is reported and can be retried', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    final repo = _NotificationRepo();
    final c = ChatController(repo, store, 's');
    expect(await c.watchSteerReady('r1'), isFalse);
    expect(await c.watchSteerReady('r1'), isTrue);
    expect(repo.watchAttempts, 2);
    c.dispose();
    repo.close();
  });
}
