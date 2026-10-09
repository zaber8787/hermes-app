import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/platform/notification_surface.dart';

/// 01412FIX F4 (M5): the browser channel's permission/claim/show/read
/// convergence on the APP side. The server ledger decides who alerts; the
/// client claims its turn, shows honestly, reports shown/failed from the
/// SURFACE answer, and converges as read when another device won.

class FakeNotifyRepo extends HermesRepository {
  FakeNotifyRepo(this.hub) : super('http://test.invalid', 'fake');
  final NotifyHub hub;

  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);

  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async =>
      {'id': sid, 'message_count': 0};

  @override
  Future<Map<String, dynamic>?> notificationEventsFeature() async =>
      {'enabled': true, 'system_channel': hub.channel};

  @override
  Future<Map<String, dynamic>> notificationEvents({int after = 0}) async {
    final items = after == 0 ? hub.events : const <Map<String, dynamic>>[];
    return {
      'data': items,
      'server_channel': hub.channel,
      'head_seq': hub.events.length,
      'next_cursor': after + items.length,
      'overflow': false,
    };
  }

  @override
  Future<Map<String, dynamic>> notificationClaim(
    String eventId, {
    required String deviceId,
  }) async {
    hub.claimCalls++;
    final winner = hub.winners.putIfAbsent(eventId, () => deviceId);
    if (winner == deviceId) {
      return {
        'verdict': 'claimed',
        'delivery_id': 'd-$eventId',
        'show_token': 'tok-$eventId',
      };
    }
    return {
      'verdict': 'already_claimed',
      'delivery_id': 'd-$eventId',
      'show_token': null,
    };
  }

  @override
  Future<Map<String, dynamic>> notificationDelivery(
    String eventId, {
    required String deliveryId,
    required String showToken,
    required String outcome,
  }) async {
    hub.reports.add('$eventId:$outcome:$showToken');
    return {'delivery': outcome};
  }

  @override
  Future<Map<String, dynamic>> notificationRead(String eventId) async {
    hub.reads.add(eventId);
    return {'event_id': eventId, 'read': true};
  }
}

class NotifyHub {
  String channel = 'browser';
  List<Map<String, dynamic>> events = [];
  final Map<String, String> winners = {};
  final List<String> reports = [];
  final List<String> reads = [];
  int claimCalls = 0;
}

class FakeSurface implements NotificationSurface {
  FakeSurface({this.grant = true});
  final bool grant;
  final List<String> shown = [];

  @override
  Future<bool> ensurePermission() async => grant;

  @override
  bool show({required String title, required String body}) {
    if (!grant) return false;
    shown.add(body);
    return true;
  }
}

Map<String, dynamic> row(String id, String kind) => {
  'event_id': id,
  'kind': kind,
  'run_id': 'r1',
  'sid': 's',
  'source_id': 'terminal',
  'created_seq': 1,
  'created_at': 1.0,
  'payload': {},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  late NotifyHub hub;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    hub = NotifyHub()
      ..events = [row('e-1', 'completed'), row('e-2', 'approval_request')];
  });

  Future<void> tick(ChatController c) async {
    await c.debugActivitySnapshotRaw();
    await pumpEventQueue();
    await c.debugActivitySnapshotRaw();
    await pumpEventQueue();
  }

  test('granted permission: claim once, show, report shown; show is NOT read',
      () async {
        final repo = FakeNotifyRepo(hub);
        final surface = FakeSurface();
        final c = ChatController(repo, store, 's');
        c.notifySurfaceForTest = surface;
        await tick(c);
        expect(c.browserAlertsGranted, isTrue);
        expect(hub.claimCalls, 2); // one claim per unread event
        expect(surface.shown.length, 2);
        expect(hub.reports, containsAll(['e-1:shown:tok-e-1', 'e-2:shown:tok-e-2']));
        // show != read: the ledger stays unread until the user ACTUALLY reads
        expect(hub.reads, isEmpty);
        expect(c.notifications.hasUnread, isTrue);

        await tick(c); // second poll must not re-claim settled events
        expect(hub.claimCalls, 2);
        c.dispose();
        repo.close();
      });

  test('a device that loses the claim converges locally without showing',
      () async {
        final winnerRepo = FakeNotifyRepo(hub);
        final winnerSurface = FakeSurface();
        final winner = ChatController(winnerRepo, store, 's')
          ..notifySurfaceForTest = winnerSurface;
        await tick(winner);
        expect(winnerSurface.shown.length, 2);

        final loserSurface = FakeSurface();
        final loserRepo = FakeNotifyRepo(hub);
        final loser = ChatController(loserRepo, store, 's')
          ..notifySurfaceForTest = loserSurface;
        await tick(loser);
        expect(loserSurface.shown, isEmpty); // exactly ONE device alerts
        expect(loser.notifications.hasUnread, isFalse); // converged as read
        expect(hub.reports.length, 2); // the loser never re-reports
        winner.dispose();
        loser.dispose();
        winnerRepo.close();
        loserRepo.close();
      });

  test('denied permission: panel-only, zero claims', () async {
    final repo = FakeNotifyRepo(hub);
    final surface = FakeSurface(grant: false);
    final c = ChatController(repo, store, 's')..notifySurfaceForTest = surface;
    await tick(c);
    expect(c.browserAlertsGranted, isFalse);
    expect(hub.claimCalls, 0);
    expect(surface.shown, isEmpty);
    expect(c.notifications.hasUnread, isTrue); // panel still shows the truth
    c.dispose();
    repo.close();
  });

  // NOTIF2 B1: the browser surface runs IN PARALLEL with the server's system
  // channel. An ntfy-configured account still alerts the browser when the
  // browser granted permission (the cross-device claim race keeps the
  // dedup); a denied browser stays panel-only and must never throw.
  test('ntfy channel + granted permission: claim, show, report shown once',
      () async {
        hub.channel = 'ntfy';
        final repo = FakeNotifyRepo(hub);
        final surface = FakeSurface();
        final c = ChatController(repo, store, 's')
          ..notifySurfaceForTest = surface;
        await tick(c);
        expect(c.browserAlertsGranted, isTrue); // permission IS asked
        expect(hub.claimCalls, 2); // the claim path runs beside ntfy
        expect(surface.shown.length, 2);
        expect(
          hub.reports,
          containsAll(['e-1:shown:tok-e-1', 'e-2:shown:tok-e-2']),
        );
        expect(hub.reads, isEmpty); // show is STILL not a server read
        expect(c.notifications.hasUnread, isTrue);

        await tick(c); // settled events are never re-claimed
        expect(hub.claimCalls, 2);
        c.dispose();
        repo.close();
      });

  test('ntfy channel + denied permission: no show, no claim, no throw',
      () async {
        hub.channel = 'ntfy';
        final repo = FakeNotifyRepo(hub);
        final surface = FakeSurface(grant: false);
        final c = ChatController(repo, store, 's')
          ..notifySurfaceForTest = surface;
        await tick(c);
        expect(c.browserAlertsGranted, isFalse);
        expect(hub.claimCalls, 0); // ungranted: nothing is claimed
        expect(surface.shown, isEmpty);
        expect(c.notifications.hasUnread, isTrue); // panel keeps the truth
        c.dispose();
        repo.close();
      });
}
