import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';

/// AUDIT-21 (D2, same-device half): two LocalStore instances over the SAME
/// SharedPreferences mock simulate two same-origin tabs sharing storage.
/// Written against pre-existing public API only, so it compiles against
/// the old app; red comes from behaviour (old code POSTed twice and its
/// settle unconditionally wiped whatever pending record sat in storage).

const url = 'http://test.invalid';

class FakeTabRepo extends HermesRepository {
  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  FakeTabRepo() : super(url, 'fake');

  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async =>
      {'id': sid, 'message_count': 0}; // R1 sync clock: quiet by default
  final events = StreamController<SseEvent>.broadcast();
  int sends = 0, cancels = 0;
  Json Function(String runId) status = (_) => {'status': 'running'};
  @override
  Stream<SseEvent> chat(String sid, String input) {
    sends++;
    return events.stream;
  }

  @override
  void cancelStream(String sid) => cancels++;
  @override
  Future<List<Message>> messages(
    String sid, {
    int offset = 0,
    int limit = 200,
  }) async => const [Message(id: 'h1', role: 'assistant', content: 'done')];
  @override
  Future<Json> runStatus(String runId) async => status(runId);
  @override
  Future<void> checkCapabilities() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  ChatController tab(FakeTabRepo repo, LocalStore store) =>
      ChatController(repo, store, 's', serverUrl: url);

  // Crash simulator: freeze A's tab's clock OUT of the lease — what a
  // crashed (never-heartbeating) tab's record looks like to everyone
  // else. Storage-level on purpose: it keeps this file compilable
  // against the pre-D2 app (no new API in the red run's fixtures).
  Future<void> expireLease() async {
    final key = '${Uri.encodeComponent(url)}.s.pending';
    final rec = Map<String, dynamic>.from(jsonDecode(prefs.getString(key)!) as Map);
    rec['lease_until'] =
        DateTime.now().subtract(const Duration(seconds: 5)).toIso8601String();
    await prefs.setString(key, jsonEncode(rec));
  }

  testWidgets('a second tab must not POST onto a live claim', (tester) async {
    final repoA = FakeTabRepo(), repoB = FakeTabRepo();
    final a = tab(repoA, LocalStore(prefs));
    final b = tab(repoB, LocalStore(prefs));
    addTearDown(() {
      repoA.events.close();
      repoB.events.close();
      a.dispose();
      b.dispose();
    });

    unawaited(a.send('A 的問題'));
    await tester.pump();
    await tester.pump();
    expect(repoA.sends, 1); // A owns the slot and posts once

    unawaited(b.send('B 的問題'));
    await tester.pump();
    await tester.pump();
    expect(
      repoB.sends,
      0,
      reason: 'old code POSTed blindly and started a duplicate run',
    );
    expect(b.error ?? '', contains('另一個分頁'));
    expect(b.busy, isFalse); // rolled back: no ghost bubble, input intact

    // A finishes cleanly: its settle may delete its OWN record.
    repoA.events
      ..add(const SseEvent('run.completed', '{"messages":[]}'))
      ..add(const SseEvent('done', '{}'));
    await repoA.events.close(); // the send loop ends with the stream
    await tester.pump();
    expect(a.busy, isFalse);
    expect(LocalStore(prefs).loadPending(url, 's'), isNull);
  });

  testWidgets('A completing must never wipe B\'s (takeover) pending', (
    tester,
  ) async {
    final repoA = FakeTabRepo(), repoB = FakeTabRepo();
    final a = tab(repoA, LocalStore(prefs));
    final b = tab(repoB, LocalStore(prefs));
    addTearDown(() {
      repoA.events.close();
      repoB.events.close();
      a.dispose();
      b.dispose();
    });

    unawaited(a.send('A 的問題'));
    await tester.pump();
    await tester.pump();
    expect(repoA.sends, 1);

    // A's tab effectively crashes (lease ages out un-heartbeaten)...
    await expireLease();
    // ...so B's claim takes over (崩潰接手) and B legitimately POSTs.
    unawaited(b.send('B 的問題'));
    await tester.pump();
    await tester.pump();
    expect(repoB.sends, 1);
    expect(b.busy, isTrue);

    // The zombie A's run finally lands. Its settle must NOT clear B's
    // record (compare-and-delete: different owner token).
    repoA.events
      ..add(const SseEvent('run.completed', '{"messages":[]}'))
      ..add(const SseEvent('done', '{}'));
    await repoA.events.close();
    await tester.pump();
    expect(a.busy, isFalse);
    final survivor = LocalStore(prefs).loadPending(url, 's');
    expect(
      survivor,
      isNotNull,
      reason: 'old code cleared blindly and destroyed B\'s recovery record',
    );
    expect(survivor!.userText, 'B 的問題');

    // B finishes: its own clear succeeds.
    repoB.events
      ..add(const SseEvent('run.completed', '{"messages":[]}'))
      ..add(const SseEvent('done', '{}'));
    await repoB.events.close();
    await tester.pump();
    expect(LocalStore(prefs).loadPending(url, 's'), isNull);
  });

  testWidgets('pre-D2 records adopt and settle unchanged (migration)', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      '${Uri.encodeComponent(url)}.s.pending': jsonEncode({
        'run_id': 'r9',
        'user_text': '舊紀錄',
        'started_at': DateTime.now().toIso8601String(),
      }),
    });
    prefs = await SharedPreferences.getInstance();
    final repo = FakeTabRepo();
    final c = tab(repo, LocalStore(prefs));
    addTearDown(() {
      repo.events.close();
      c.dispose();
    });

    await c.bootstrap(); // adopts the legacy record read-only
    expect(c.busy, isTrue);

    repo.status = (_) => {'status': 'completed'};
    await tester.pump(const Duration(seconds: 6)); // bootstrap tick sees it
    await tester.pump();
    expect(c.busy, isFalse);
    // Unowned (token null) record: an unowned clear may remove it —
    // exactly the old behaviour, no schema rewrite needed first.
    expect(LocalStore(prefs).loadPending(url, 's'), isNull);
    c.dispose(); // R1: bootstrap's sync poll must not outlive the test
  });
}
