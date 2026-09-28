import 'dart:async';


import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/auto_wake.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/chat/viewers.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session_activity.dart';

// APPWAKE C: the dispatch pipeline — gates, admit/POST/ack order, and the
// ledger-verdict (409/410) read-only paths. The ledger fake enforces what
// the real one does: ONE consumption per delivery_key, CAS release.
class Ledger {
  final consumed = <String>{};
  final batches = <String, Map<String, dynamic>>{};
  final keysOf = <String, List<String>>{};
  int n = 0;
}

class WakeRepo extends HermesRepository {
  WakeRepo(this.ledger) : super('http://test.invalid', 'fake');
  final Ledger ledger;
  List<Message> history = [Message(id: '1', role: 'user', content: 'hi')];
  Map<String, dynamic>? cap = {
    'features': {
      'auto_wake': {
        'enabled': true,
        'canonical_input': AutoWakeContract.canonicalInput,
        'batch_max': 10,
      },
    },
  };
  Map<String, dynamic>? admitOverride;
  Map<String, dynamic>? Function(List<String>)? admitHook;
  int? gateReject;
  bool receiptThrows = false;
  int admits = 0, capFetches = 0;
  final posts = <(String input, String? batch)>[];
  final acks = <(String, String)>[];
  int get wakePosts => posts.where((p) => p.$2 != null).length;
  StreamController<SseEvent>? _cur;
  StreamController<SseEvent> get events => _cur!;

  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async =>
      {'id': sid, 'message_count': 0};
  @override
  Future<List<Message>> messages(String sid, {int offset = 0, int limit = 200}) async => history;

  @override
  Future<Map<String, dynamic>> autoWakeCapability() async {
    capFetches++;
    return cap ?? {'features': <String, dynamic>{}};
  }

  @override
  Future<Map<String, dynamic>> wakeAdmit(
    String sid,
    List<String> keys,
  ) async {
    admits++;
    if (admitOverride case final over?) return over;
    if (admitHook?.call(keys) case final blocked?) return blocked;
    final fresh = keys.where((k) => !ledger.consumed.contains(k)).toList();
    if (fresh.isEmpty) return {'status': 'empty'};
    ledger.consumed.addAll(fresh);
    final id = 'wb_${++ledger.n}';
    ledger.batches[id] = {'state': 'reserved'};
    ledger.keysOf[id] = fresh;
    return {
      'status': 'admitted',
      'batch_id': id,
      'anchor_after_id': 5,
      'canonical_input': AutoWakeContract.canonicalInput,
    };
  }

  @override
  Future<Map<String, dynamic>> wakeReceipt(String sid, String id) async {
    if (receiptThrows) throw ApiException('unreadable', 503);
    return {'state': ledger.batches[id]?['state'] ?? 'terminal'};
  }

  @override
  Future<void> wakeAck(String sid, String id, String state, {String? runId}) async {
    acks.add((id, state));
    if (ledger.batches[id] case final b?) b['state'] = state;
  }

  @override
  Future<Map<String, dynamic>> wakeRelease(String sid, String id) async {
    if (ledger.batches[id]?['state'] != 'reserved') {
      return {'status': 'conflict'};
    }
    ledger.consumed.removeAll(ledger.keysOf[id] ?? const []);
    ledger.batches[id]!['state'] = 'released';
    return {'status': 'ok'};
  }

  @override
  Stream<SseEvent> chat(String sid, String input, {String? wakeBatch}) async* {
    posts.add((input, wakeBatch));
    if (gateReject case final status?) {
      // Mirror what the REAL gate CAS answers with: the batch is already
      // past 'reserved' when a 409/410 rides back.
      final batchUnderTest = ledger.batches[wakeBatch];
      if (batchUnderTest != null) {
        batchUnderTest['state'] = status == 409 ? 'dispatching' : 'released';
        if (status == 410) {
          ledger.consumed.removeAll(ledger.keysOf[wakeBatch] ?? const []);
        }
      }
      throw ApiException('ledger verdict', status);
    }
    _cur = StreamController<SseEvent>();
    yield* _cur!.stream;
  }

  @override
  void cancelStream(String sid) {
    final c = _cur;
    if (c != null && !c.isClosed) unawaited(c.close());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const server = 'http://test.invalid';
  const sid = 's';
  String dk(String seed) => seed.padRight(64, '0').substring(0, 64);

  late LocalStore store;
  late Ledger ledger;
  late WakeRepo repo;
  var allowAdmit = false;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    store.setAutoWakeEnabled(server, true);
    ledger = Ledger();
    repo = WakeRepo(ledger);
    allowAdmit = false;
    ChatViewers.reset();
    ChatViewers.acquire(sid);
  });
  tearDown(() {
    repo.close();
    ChatViewers.reset();
  });

  Future<ChatController> boot(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final c = ChatController(
      repo,
      store,
      sid,
      now: tester.binding.clock.now,
    );
    await c.bootstrap(); // arms the observer; the seeded queue survives
    return c;
  }

  Future<void> seedQueue(LocalStore store, List<(String, int)> reports) async {
    // admit stays refused until the test releases it: NO dispatch may
    // happen before the explicit pump-then-drain window.
    store.setAutoWakeEnabled(server, true);
    allowAdmit = false;
    repo.admitHook = (_) => allowAdmit ? null : {'status': 'busy', 'retry_after_s': 1};
    await store.saveWakeState(server, sid, {
      'armedAt': '2026-09-27T12:00:00.000Z',
      'cutoffOrder': 1,
      'lastSeenOrder': 1,
      'orderUncertain': false,
      'queued': [
        for (final (id, order) in reports)
          {'id': id, 'dk': dk('dk$id'), 'order': order},
      ],
      'ignoredKeys': <String>[],
      'batches': <Map<String, dynamic>>[],
    });
  }

  /// Move the fake clock and flush every await hop of the dispatch chain.
  Future<void> drain(WidgetTester t, [Duration d = Duration.zero]) async {
    await t.pump();
    await t.pump(d);
    for (var i = 0; i < 25; i++) {
      await t.pump();
    }
  }

  /// Pump in small steps so every 1s debounce hop lands deterministically.
  Future<void> drainOpen(WidgetTester t, Duration total) async {
    var left = total;
    while (left > Duration.zero) {
      final step = left > const Duration(milliseconds: 700)
          ? const Duration(milliseconds: 700)
          : left;
      left -= step;
      await drain(t, step);
    }
  }

  testWidgets('idle dispatch: admit -> batch persisted -> wake POST -> acks', (
    tester,
  ) async {
    await seedQueue(store, [('2', 2)]);
    final c = await boot(tester);
    allowAdmit = true;
    await drainOpen(tester, const Duration(seconds: 2));
    expect(repo.wakePosts, 1);
    expect(repo.posts.single.$1, AutoWakeContract.canonicalInput);
    expect(c.pendingInput, isNull); // NO fake human bubble
    expect(ledger.consumed, {dk('dk2')});
    // The batch is in the durable mirror BEFORE the POST could happen.
    final batch = store.wakeState(server, sid)!['batches']!
        .cast<Map>()
        .single;
    expect(batch['state'], 'dispatched');
    // run.started -> accepted ack; completion -> terminal ack + settle.
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r","session_id":"s"}'),
    );
    await drain(tester);
    expect(repo.acks.contains((batch['batch_id'], 'accepted')), isTrue);
    repo.events.add(
      const SseEvent('run.completed', '{"completed":true,"messages":[]}'),
    );
    await repo.events.close();
    await drain(tester);
    expect(c.phase, ChatPhase.idle);
    expect(repo.acks.contains((batch['batch_id'], 'terminal')), isTrue);
    expect(
      store.wakeState(server, sid)!['batches']!
          .cast<Map>()
          .single['state'],
      'terminal',
    );
    c.dispose();
  });

  testWidgets('typing pauses dispatch; putting the editor down resumes', (
    tester,
  ) async {
    await seedQueue(store, [('2', 2)]);
    final c = await boot(tester);
    allowAdmit = true;
    c.noteInputActive(true);
    await drainOpen(tester, const Duration(seconds: 5));
    expect(repo.wakePosts, 0);
    c.noteInputActive(false);
    await drainOpen(tester, const Duration(seconds: 2));
    expect(repo.wakePosts, 1);
    c.dispose();
  });

  testWidgets('a manual turn wins; the wake runs after it settles', (
    tester,
  ) async {
    await seedQueue(store, [('2', 2)]);
    final c = await boot(tester);
    allowAdmit = true;
    c.send('human now');
    await drainOpen(tester, const Duration(seconds: 3));
    expect(repo.posts.map((p) => p.$2).whereType<String>(), isEmpty); // no wake yet
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"m","session_id":"s"}'),
    );
    await drain(tester);
    repo.events.add(
      const SseEvent('run.completed', '{"completed":true,"messages":[]}'),
    );
    await repo.events.close();
    await drain(tester);
    expect(c.phase, ChatPhase.idle);
    await drainOpen(tester, const Duration(seconds: 2));
    expect(repo.wakePosts, 1); // exactly one, AFTER the manual settle
    c.dispose();
  });

  testWidgets('no capability -> never admit, never POST (pure server)', (
    tester,
  ) async {
    repo.cap = null;
    await seedQueue(store, [('2', 2)]);
    final c = await boot(tester);
    allowAdmit = true;
    await drainOpen(tester, const Duration(seconds: 5));
    expect(repo.admits, 0);
    expect(repo.wakePosts, 0);
    c.dispose();
  });

  testWidgets('hidden app never auto-sends; resume re-checks', (tester) async {
    await seedQueue(store, [('2', 2)]);
    final c = await boot(tester);
    allowAdmit = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await drainOpen(tester, const Duration(seconds: 5));
    expect(repo.wakePosts, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await drainOpen(tester, const Duration(seconds: 2));
    expect(repo.wakePosts, 1);
    c.dispose();
  });

  testWidgets('no viewer on screen -> silent', (tester) async {
    await seedQueue(store, [('2', 2)]);
    final c = await boot(tester);
    allowAdmit = true;
    ChatViewers.release(sid);
    await drainOpen(tester, const Duration(seconds: 5));
    expect(repo.wakePosts, 0);
    c.dispose();
  });

  testWidgets('quota: honest hint + server retry_after backoff', (tester) async {
    repo.admitOverride = {'status': 'quota_exceeded', 'retry_after_s': 60};
    await seedQueue(store, [('2', 2)]);
    final c = await boot(tester);
    allowAdmit = true;
    await drainOpen(tester, const Duration(seconds: 2));
    expect(repo.admits, 1);
    expect(c.wakeQuotaHit, isTrue);
    expect(repo.wakePosts, 0);
    await drainOpen(tester, const Duration(seconds: 30));
    expect(repo.admits, 1); // not before the server's retry_after_s
    await drainOpen(tester, const Duration(seconds: 35));
    expect(repo.admits, 2);
    c.dispose();
  });

  testWidgets('busy verdict retries after retry_after_s, queue intact', (
    tester,
  ) async {
    repo.admitOverride = {'status': 'busy', 'retry_after_s': 5};
    await seedQueue(store, [('2', 2)]);
    final c = await boot(tester);
    allowAdmit = true;
    await drainOpen(tester, const Duration(seconds: 2));
    expect(repo.admits, 1);
    expect(store.wakeState(server, sid)!['queued'], hasLength(1)); // intact
    await drainOpen(tester, const Duration(seconds: 6));
    expect(repo.admits, 2);
    c.dispose();
  });

  testWidgets('POST 409 + unreadable receipt + no anchor -> uncertain, no replay', (
    tester,
  ) async {
    repo.gateReject = 409;
    repo.receiptThrows = true;
    await seedQueue(store, [('2', 2)]);
    final c = await boot(tester);
    allowAdmit = true;
    await drainOpen(tester, const Duration(seconds: 2));
    expect(repo.wakePosts, 1);
    await drainOpen(tester, const Duration(seconds: 30));
    expect(repo.wakePosts, 1); // NEVER re-POST an uncertain batch
    final batch = store.wakeState(server, sid)!['batches']!
        .cast<Map>()
        .single;
    expect(batch['state'], 'uncertain');
    expect(c.phase, ChatPhase.idle);
    c.dispose();
  });

  testWidgets('POST 409 + receipt dispatching -> accepted, observed read-only', (
    tester,
  ) async {
    repo.gateReject = 409;
    await seedQueue(store, [('2', 2)]);
    final c = await boot(tester);
    allowAdmit = true;
    await drainOpen(tester, const Duration(seconds: 2));
    expect(repo.wakePosts, 1);
    final batch = store.wakeState(server, sid)!['batches']!
        .cast<Map>()
        .single;
    expect(batch['state'], 'accepted'); // ledger says a run is in flight
    expect(c.phase, ChatPhase.idle);
    await drainOpen(tester, const Duration(seconds: 10));
    expect(repo.wakePosts, 1); // still exactly one POST
    c.dispose();
  });

  testWidgets('POST 410 released -> rows return to the queue and may be re-claimed', (
    tester,
  ) async {
    repo.gateReject = 410;
    await seedQueue(store, [('2', 2)]);
    final c = await boot(tester);
    c.noteInputActive(true); // hold the gate open: attempts happen on demand
    allowAdmit = true;
    await drainOpen(tester, const Duration(seconds: 2));
    expect(repo.wakePosts, 0);
    final st = store.wakeState(server, sid)!;
    expect(st['batches'], isEmpty); // proven release: mirror row gone
    expect(st['queued'], hasLength(1)); // rows back, unconsumed
    expect(ledger.consumed, isEmpty); // server freed them too
    // Freed rows are RE-CLAIMABLE: let go of the editor and the idle gate
    // admits ONE fresh batch for them (never a replay of the dead id).
    c.noteInputActive(false);
    await drainOpen(tester, const Duration(seconds: 8));
    c.noteInputActive(true);
    final attempted = repo.wakePosts;
    expect(attempted, greaterThan(0));
    await drainOpen(tester, const Duration(seconds: 60));
    expect(repo.wakePosts, attempted); // the hold freezes every retry
    expect(ledger.n, attempted); // each attempt = a NEW batch, never a replay
    expect(ledger.batches['wb_1']!['state'], 'released');
    c.dispose();
  });

  testWidgets('two clients, one ledger: exactly one wake POST total', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final repoB = WakeRepo(ledger); // same fake server state
    await seedQueue(store, [('2', 2), ('3', 3)]);
    final a = ChatController(repo, store, sid, now: tester.binding.clock.now);
    final b = ChatController(repoB, store, sid, now: tester.binding.clock.now);
    await a.bootstrap();
    await b.bootstrap();
    await drainOpen(tester, const Duration(seconds: 2));
    await drainOpen(tester, const Duration(seconds: 2));
    expect(repo.wakePosts + repoB.wakePosts, 1);
    // One batch consumed BOTH queued reports (merged, ascending).
    expect(ledger.consumed, {dk('dk2'), dk('dk3')});
    a.dispose();
    b.dispose();
  });

  testWidgets('overflow: >10 queued -> one capped batch, remainder waits', (
    tester,
  ) async {
    await seedQueue(
      store,
      [for (var i = 2; i <= 13; i++) ('$i', i)],
    );
    final c = await boot(tester);
    allowAdmit = true;
    await drainOpen(tester, const Duration(seconds: 2));
    expect(repo.wakePosts, 1);
    expect(ledger.consumed, hasLength(10)); // batch_max honoured
    expect(store.wakeState(server, sid)!['queued'], hasLength(2));
    c.dispose();
  });

  testWidgets('wake turn never clears a draft and never shows a bubble', (
    tester,
  ) async {
    await store.saveDraft(server, sid, 'user draft text');
    await seedQueue(store, [('2', 2)]);
    final c = await boot(tester);
    allowAdmit = true;
    await drainOpen(tester, const Duration(seconds: 2));
    expect(repo.wakePosts, 1);
    expect(store.draft(server, sid), 'user draft text'); // untouched
    expect(c.pendingBubbleText, isNull); // no fake human row
    c.dispose();
  });
}
