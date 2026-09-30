import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/features/chat/auto_wake.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/models/message.dart';

// APPWAKE A: the durable shadow queue. Detection and persistence only —
// nothing here may ever POST; dispatch integration is a later batch.
DateTime _clock() => DateTime.utc(2026, 9, 27, 12);

DispatchPlan? o2plan(AutoWakeObserver o) =>
    AutoWakeObserver.plan(o.state, now: _clock());

String dk(String seed) => seed.padRight(64, '0').substring(0, 64);

Message report(String id, String body, {String job = 'J', String exec = 'e1'}) =>
    Message(
      id: id,
      role: 'user',
      displayKind: 'internal_notification',
      content: '[Cron report: $job]\n$body',
      cronProvenance:
          CronProvenance(schema: 1, jobId: job, executionId: exec, deliveryKey: dk('$job:$exec')),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  DateTime clock() => DateTime.utc(2026, 9, 27, 12);
  const server = 'http://test.invalid';
  const sid = 's';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    store.setAutoWakeEnabled(server, true);
  });

  AutoWakeObserver make() =>
      AutoWakeObserver(store: store, serverUrl: server, sid: sid, now: clock);

  Future<void> commit(AutoWakeObserver o, List<Message> rows, {bool latest = true}) =>
      o.onHistoryCommit(rows, latestPage: latest);

  List queued(AutoWakeObserver o) =>
      ((o.state?['queued']) as List?) ?? const [];

  test('first arm baselines: existing reports never queue', () async {
    final o = make();
    await commit(o, [
      Message(id: '1', role: 'user', content: 'hello'),
      report('2', 'old report'),
    ]);
    expect(queued(o), isEmpty);
    expect(o.state!['cutoffOrder'], 2);
    // A report AFTER arming counts even with a previously unseen dk.
    await commit(o, [
      Message(id: '1', role: 'user', content: 'hello'),
      report('2', 'old report'),
      report('3', 'fresh', exec: 'e2'),
    ]);
    expect(queued(o).length, 1);
    expect(queued(o).first['dk'], dk('J:e2'));
  });

  test('five-condition gate: nothing else is ever a candidate', () async {
    final o = make();
    await commit(o, [
      Message(id: '1', role: 'assistant', content: 'a'),
      Message(id: '2', role: 'tool', content: 't'),
      Message(id: '3', role: 'system', content: 's'),
      Message(id: '4', role: 'user', content: 'human typed'),
      Message(
        id: '5',
        role: 'user',
        displayKind: 'async_delegation_complete',
        content: 'other kind',
      ),
      Message(id: '6', role: 'user', displayKind: 'internal_notification', content: 'no provenance'),
      Message(
        id: '7',
        role: 'assistant',
        displayKind: 'internal_notification',
        content: 'wrong role',
        cronProvenance: CronProvenance(schema: 1, jobId: 'J', executionId: 'x', deliveryKey: dk('J:x')),
      ),
    ]);
    expect(queued(o), isEmpty);
  });

  test('repeated commits + restart never double-queue', () async {
    final o = make();
    await commit(o, [Message(id: '1', role: 'user', content: 'hi')]);
    await commit(o, [Message(id: '1', role: 'user', content: 'hi'), report('2', 'a')]);
    await commit(o, [Message(id: '1', role: 'user', content: 'hi'), report('2', 'a')]);
    expect(queued(o).length, 1);
    // Restart: a fresh observer over the SAME store keeps queue + cursor.
    final o2 = make();
    await commit(o2, [Message(id: '1', role: 'user', content: 'hi'), report('2', 'a')]);
    expect(queued(o2).length, 1);
    expect(o2.state!['lastSeenOrder'], 2);
  });

  test('non-numeric ids stop auto-processing without touching the queue', () async {
    final o = make();
    await commit(o, [Message(id: '1', role: 'user', content: 'hi')]);
    await commit(o, [report('2', 'a'), Message(id: 'legacy-id', role: 'user', content: 'x')]);
    expect(queued(o).length, 1);
    expect(o.state!['orderUncertain'], true);
    expect(o2plan(o), isNull); // planner refuses while order is untrusted
    // A later trustworthy commit clears the flag and keeps the queue.
    await commit(o, [report('2', 'a'), Message(id: '3', role: 'user', content: 'x')]);
    expect(o.state!['orderUncertain'], false);
    expect(o2plan(o), isNotNull);
  });

  test('gap: cursor never jumps ahead of proven coverage', () async {
    final o = make();
    await commit(o, [Message(id: '1', role: 'user', content: 'hi')]);
    // A page starting at 90 cannot prove rows 2..89 were seen.
    await commit(o, [
      report('90', 'a', exec: 'g90'),
      report('91', 'b', exec: 'g91'),
    ]);
    expect(o.state!['lastSeenOrder'], 1);
    expect(queued(o).length, 2);
    // The old page that closes the gap lets it advance (without queueing twice).
    await commit(o, [
      Message(id: '2', role: 'user', content: 'x'),
      report('90', 'a', exec: 'g90'),
    ], latest: false);
    expect(queued(o).length, 2);
    expect(o.state!['lastSeenOrder'], 1); // old pages never advance
    await commit(o, [
      for (var i = 2; i <= 89; i++) Message(id: '$i', role: 'user', content: 'x'),
      report('90', 'a', exec: 'g90'),
      report('91', 'b', exec: 'g91'),
    ]);
    expect(o.state!['lastSeenOrder'], 91);
  });

  test('NO_REPLY/HEARTBEAT_OK and empty are ignored-consumed; mentions survive', () async {
    final o = make();
    await commit(o, [Message(id: '1', role: 'user', content: 'hi')]);
    await commit(o, [
      report('2', 'NO_REPLY', exec: 'r1'),
      report('3', '   ', exec: 'r2'),
      report('4', 'we discussed NO_REPLY handling', exec: 'r3'),
      report('5', 'HEARTBEAT_OK', exec: 'r4'),
    ]);
    expect(queued(o).map((q) => q['dk']), [dk('J:r3')]);
    expect(o.state!['ignoredKeys'],
        containsAll([dk('J:r1'), dk('J:r2'), dk('J:r4')]));
    // Reconcile must NOT reset ignored verdicts:
    await commit(o, [report('2', 'NO_REPLY', exec: 'r1')]);
    expect(queued(o).map((q) => q['dk']), [dk('J:r3')]);
  });

  test('debounce + batch cap: <=10 per batch, ascending, remainder keeps queue', () async {
    final o = make();
    await commit(o, [Message(id: '1', role: 'user', content: 'hi')]);
    final rows = [
      for (var i = 2; i <= 13; i++) report('$i', 'r$i', exec: 'e$i'),
    ];
    await commit(o, rows);
    expect(queued(o).length, 12);
    final p = AutoWakeObserver.plan(o.state, now: clock());
    expect(p, isNotNull);
    expect(p!.items.length, 10);
    expect(p.items.map((e) => e['order']), p.items.map((e) => e['order']).toList()..sort());
    expect(p.overflow, true);
    expect(p.anchorAfterId, 11); // max report order of the batch
  });

  test('disable clears the queue; re-enable never replays the gap', () async {
    final o = make();
    await commit(o, [Message(id: '1', role: 'user', content: 'hi')]);
    await commit(o, [Message(id: '1', role: 'user', content: 'hi'), report('2', 'a')]);
    expect(queued(o).length, 1);
    store.setAutoWakeEnabled(server, false);
    await commit(o, [report('3', 'during-off', exec: 'off1')]);
    expect(o.armed, false);
    expect(store.wakeState(server, sid), isNull); // boundary stored, queue gone
    store.setAutoWakeEnabled(server, true);
    final o2 = make();
    // Re-arm baselines from THIS commit: the off-window report is inside
    // the fresh cutoff and never replays.
    await commit(o2, [report('3', 'during-off', exec: 'off1')]);
    expect(queued(o2), isEmpty);
    await commit(o2, [
      report('3', 'during-off', exec: 'off1'),
      report('4', 'after', exec: 'on1'),
    ]);
    expect(queued(o2).map((q) => q['dk']), [dk('J:on1')]);
  });

  test('lineage move keeps the delivery_key queue', () async {
    final o = make();
    await commit(o, [Message(id: '1', role: 'user', content: 'hi')]);
    await commit(o, [Message(id: '1', role: 'user', content: 'hi'), report('2', 'a')]);
    await o.moveLineage();
    final disk = store.wakeState(server, sid)!;
    expect((disk['queued'] as List).length, 1);
  });

  test('anchor projection: receipts map their canonical row to a system line', () async {
    final o = make();
    await commit(o, [Message(id: '1', role: 'user', content: 'hi')]);
    final st = o.state!;
    st['batches'] = [
      {
        'batch_id': 'wb1',
        'state': 'accepted',
        'anchor_after_id': 2,
        'canonical_input': AutoWakeContract.canonicalInput,
      },
    ];
    await store.saveWakeState(server, sid, st);
    final rows = [
      report('2', 'a'),
      Message(id: '3', role: 'user', content: AutoWakeContract.canonicalInput),
      Message(id: '4', role: 'assistant', content: 'summary'),
    ];
    expect(o.anchors(rows), {'3'});
    // The projection keeps the user-turn anchor semantics intact:
    final entries = projectMessages(rows, wakeRowIds: {'3'});
    expect(entries.any((e) => e.kind == EntryKind.user), false);
    expect(entries.any((e) => e.kind == EntryKind.system && e.label == MessageKey.systemWakeRead),
        true);
    // The anchor is the FIRST canonical user row AFTER the watermark; a
    // same-text row sitting BEFORE it (e.g. a human who typed the sentence
    // earlier) is not touched, and a later duplicate stays a user bubble
    // (only the first match is claimed — no human row is hidden by mere
    // text; the receipt's watermark is the identity).
    expect(
      o.anchors([Message(id: '1', role: 'user', content: AutoWakeContract.canonicalInput)]),
      isEmpty,
    );
    expect(
      o.anchors([
        Message(id: '3', role: 'user', content: AutoWakeContract.canonicalInput),
        Message(id: '9', role: 'user', content: AutoWakeContract.canonicalInput),
      ]),
      {'3'},
    );
  });
}
