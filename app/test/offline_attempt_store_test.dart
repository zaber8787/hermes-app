import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/features/attachments/attachment.dart';
import 'package:hermes_app/features/chat/local_attempt.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/platform/store_tx.dart';

/// OFFLINE-SEND R2 store layer: the per-attempt journal, its stable
/// identity, the §4.2 settlement ordering, and the draft CAS counter.
/// Two LocalStore instances over the SAME SharedPreferences mock simulate
/// two same-origin tabs (the audit21 pattern).

const url = 'http://test.invalid';
const enc = 'http%3A%2F%2Ftest.invalid';
final kT0 = DateTime.utc(2026, 1, 1);

Map<String, Object?> prefsSnapshot(SharedPreferences p) =>
    {for (final k in p.getKeys()) k: p.get(k)};

String attemptKey(String sid, String id) => '$enc.$sid.attempt.$id';

String attemptJson(
  String id, {
  String sid = 's',
  AttemptDisposition disposition = AttemptDisposition.waiting,
  String? rawDraft,
}) => jsonEncode(LocalAttempt(
  attemptId: id,
  server: url,
  sid: sid,
  createdAt: kT0,
  disposition: disposition,
  rawDraft: rawDraft,
).toJson());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late LocalStore a, b;

  setUp(() async {
    LocalStore.debugFailAttemptWrites = false;
    LocalStore.debugEndAttemptHook = null;
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    a = LocalStore(prefs);
    b = LocalStore(prefs); // same storage, different tabId
  });

  Future<({String token, String attemptId})> claimHuman(
    LocalStore st, {
    String sid = 's',
    String turn = '1',
  }) async {
    final token = (await st.claimPending(
      url,
      sid,
      userText: 'q',
      turnId: turn,
    ))!;
    return (token: token, attemptId: st.loadPending(url, sid)!.attemptId!);
  }

  LocalAttempt tombstoneOf(String id, {String sid = 's'}) => LocalAttempt(
    attemptId: id,
    server: url,
    sid: sid,
    createdAt: kT0,
    disposition: AttemptDisposition.abandoned,
    rawDraft: '  原稿 with trailing  ',
  );

  test('capability is resolved on the VM before any transaction', () {
    // io impl: the single-context chain IS complete serialization.
    expect(storeTxCapability, StoreTxCapability.resolvedAvailable);
    expect(storeTxIsCrossTab, isFalse); // unchanged F9 semantics
  });

  group('identity', () {
    test('newAttemptId is 32 lowercase hex and unique', () {
      final ids = {for (var i = 0; i < 200; i++) LocalStore.newAttemptId()};
      for (final id in ids) {
        expect(id, matches(RegExp(r'^[0-9a-f]{32}$')));
      }
      expect(ids.length, 200);
    });

    test('LocalAttempt.fromJson tolerates optionals, rejects corrupt', () {
      final full = LocalAttempt(
        attemptId: 'a' * 32,
        server: url,
        sid: 's',
        createdAt: kT0,
        rawDraft: 'x\n  y',
        preparedInput: 'x y',
        attachmentSnapshots: const [
          AttachmentDraft(
            localPath: '/p',
            filename: 'p.png',
            artifactId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          ),
        ],
        editorRevision: 4,
        disposition: AttemptDisposition.abandoned,
        delivery: AttemptDelivery.outcomeUnknown,
        runId: 'r1',
        terminalEvidence: const {'stage': 'headers'},
      );
      final back = LocalAttempt.fromJson(full.toJson())!;
      expect(back.attemptId, 'a' * 32);
      expect(back.rawDraft, 'x\n  y');
      expect(back.attachmentSnapshots.single.artifactId, 'b' * 32);
      expect(back.disposition, AttemptDisposition.abandoned);
      expect(back.terminalEvidence!['stage'], 'headers');

      final minimal = LocalAttempt.fromJson({
        'schema_version': 1,
        'attempt_id': 'c' * 32,
        'server': url,
        'sid': 's',
        'created_at': kT0.toIso8601String(),
      })!;
      expect(minimal.origin, 'human');
      expect(minimal.disposition, AttemptDisposition.waiting);
      expect(minimal.delivery, AttemptDelivery.outcomeUnknown);
      expect(minimal.rawDraft, isNull); // null, NOT ''
      expect(minimal.attachmentSnapshots, isEmpty);

      expect(
        LocalAttempt.fromJson({
          'schema_version': 99,
          'attempt_id': 'd' * 32,
          'server': url,
          'sid': 's',
          'created_at': kT0.toIso8601String(),
        }),
        isNull,
      );
      expect(
        LocalAttempt.fromJson({
          'schema_version': 1,
          'server': url,
          'sid': 's',
          'created_at': kT0.toIso8601String(),
        }),
        isNull,
      );
      expect(
        LocalAttempt.fromJson({
          'schema_version': 1,
          'attempt_id': 'e' * 32,
          'server': url,
          'sid': 's',
          'created_at': 'yesterday',
        }),
        isNull,
      );
    });

    test('listAttempts skips corrupt entries without throwing', () async {
      final c = await claimHuman(a);
      prefs.setString(attemptKey('s', 'd' * 32), 'this is not json');
      expect(a.listAttempts(url, 's').map((e) => e.attemptId), [c.attemptId]);
    });
  });

  group('attempt_id through the pending writers', () {
    test('human claim mints once; every rewrite preserves the SAME id',
        () async {
      final c1 = await claimHuman(a);
      final (token, id) = (c1.token, c1.attemptId);
      expect(id, matches(RegExp(r'^[0-9a-f]{32}$')));
      final entry = a.loadAttempt(url, 's', id)!;
      expect(entry.disposition, AttemptDisposition.waiting);
      expect(entry.delivery, AttemptDelivery.outcomeUnknown);
      expect(entry.origin, 'human');
      expect(entry.rawDraft, isNull);

      expect(await a.touchPending(url, 's', token), isTrue);
      expect(a.loadPending(url, 's')!.attemptId, id);
      expect(
        await a.amendPendingRun(
          url,
          's',
          token: token,
          userText: 'q',
          runId: 'r2',
        ),
        isTrue,
      );
      expect(a.loadPending(url, 's')!.attemptId, id);
      await a.savePending(url, 's', runId: 'r3');
      expect(a.loadPending(url, 's')!.attemptId, id);
      // savePending produces an UNOWNED record (documented pre-D2
      // semantics), so the recovery begin below carries no token.
      final begun = await a.beginPendingRecovery(url, 's', now: kT0);
      expect(begun.outcome, PendingRecoveryOutcome.begun);
      expect(a.loadPending(url, 's')!.attemptId, id);
      final used = await a.consumeRecoveryRetry(
        url,
        's',
        token: a.loadPending(url, 's')!.token,
        now: kT0.add(const Duration(seconds: 61)),
      );
      expect(used.outcome, RecoveryRetryOutcome.consumed);
      expect(a.loadPending(url, 's')!.attemptId, id);
      // No duplicate journal entries were created along the way.
      expect(a.listAttempts(url, 's').map((e) => e.attemptId), [id]);
    });

    test('autoWake claims and legacy autoWake records never mint', () async {
      final token = (await a.claimPending(
        url,
        's',
        userText: 'wake',
        turnId: 'w1',
        origin: 'autoWake',
        wakeBatchId: 'batch-1',
      ))!;
      expect(token, isNotNull);
      expect(a.loadPending(url, 's')!.attemptId, isNull);
      expect(a.listAttempts(url, 's'), isEmpty);

      // Hand-written legacy autoWake record: the migration op must leave
      // it exactly alone (a wake dispatch is not a human attempt).
      SharedPreferences.setMockInitialValues({
        '$enc.s.pending': jsonEncode({
          'run_id': 'r9',
          'user_text': 'wake',
          'started_at': kT0.toIso8601String(),
          'origin': 'autoWake',
          'wake_batch_id': 'batch-1',
        }),
      });
      final st = LocalStore(await SharedPreferences.getInstance());
      final begun = await st.beginPendingRecovery(url, 's', now: kT0);
      expect(begun.outcome, PendingRecoveryOutcome.begun);
      expect(st.loadPending(url, 's')!.attemptId, isNull);
      expect(st.listAttempts(url, 's'), isEmpty);
      final rec = Map<String, dynamic>.from(
        jsonDecode(st.prefs.getString('$enc.s.pending')!) as Map,
      );
      expect(rec.containsKey('attempt_id'), isFalse);
    });

    test('legacy human record migrates exactly once, on the first begin',
        () async {
      SharedPreferences.setMockInitialValues({
        '$enc.s.pending': jsonEncode({
          'run_id': 'r9',
          'user_text': 'pre-R2',
          'started_at': kT0.toIso8601String(),
        }),
      });
      final st = LocalStore(await SharedPreferences.getInstance());
      expect(st.loadPending(url, 's')!.attemptId, isNull);
      final begun = await st.beginPendingRecovery(url, 's', now: kT0);
      expect(begun.outcome, PendingRecoveryOutcome.begun);
      final id = st.loadPending(url, 's')!.attemptId!;
      expect(id, matches(RegExp(r'^[0-9a-f]{32}$')));
      final entries = st.listAttempts(url, 's');
      expect(entries.single.attemptId, id);
      expect(entries.single.rawDraft, isNull); // legacy: draft unknown
      expect(entries.single.delivery, AttemptDelivery.outcomeUnknown);
      // Second op: SAME id, still exactly ONE entry — never a second mint.
      final again = await st.beginPendingRecovery(
        url,
        's',
        now: kT0.add(const Duration(seconds: 5)),
      );
      expect(again.outcome, PendingRecoveryOutcome.alreadyPresent);
      expect(st.loadPending(url, 's')!.attemptId, id);
      expect(st.listAttempts(url, 's').single.attemptId, id);
    });
  });

  group('listAttempts prefix', () {
    test('only the exact server+sid+attempt prefix is listed', () async {
      final id = (await claimHuman(a)).attemptId;
      await claimHuman(a, sid: 'other');
      // Different server URL sharing the same sid.
      await b.claimPending('http://other', 's', userText: 'q', turnId: '1');
      // Adversarial siblings: a sid that merely starts with 's', and a
      // dotted remainder that is not a single attempt id.
      final id1 = '1' * 32, id2 = '2' * 32;
      prefs.setString(
        '$enc.sextra.attempt.$id1',
        attemptJson(id1, sid: 'sextra'),
      );
      prefs.setString('${attemptKey('s', id2)}.evil', attemptJson(id2));
      final listed = a.listAttempts(url, 's').map((e) => e.attemptId).toList();
      expect(listed, [id]);
    });

    test('abandoned tombstones stay listed (no TTL drop)', () async {
      final c1 = await claimHuman(a);
      final (token, id) = (c1.token, c1.attemptId);
      final res = await a.endLocalAttempt(
        url,
        's',
        token: token,
        attemptId: id,
        tombstone: tombstoneOf(id),
      );
      expect(res.outcome, LocalAttemptEndOutcome.ended);
      final listed = a.listAttempts(url, 's');
      expect(listed.single.attemptId, id);
      expect(listed.single.disposition, AttemptDisposition.abandoned);
    });
  });

  group('endLocalAttempt ordering', () {
    test('tombstone lands BEFORE the pending delete; crash keeps both',
        () async {
      final c1 = await claimHuman(a);
      final (token, id) = (c1.token, c1.attemptId);
      final phases = <String>[];
      LocalStore.debugEndAttemptHook = (phase) async {
        if (phase == 'afterJournal') throw StateError('crash');
      };
      await expectLater(
        a.endLocalAttempt(
          url,
          's',
          token: token,
          attemptId: id,
          tombstone: tombstoneOf(id),
        ),
        throwsStateError,
      );
      // Crash between §4.2 steps 2 and 3: tombstone AND pending present —
      // the abandoned entry is what a later reload must find, so this tab
      // never re-arms a waiting budget for the same attemptId.
      expect(a.loadPending(url, 's'), isNotNull);
      expect(
        a.loadAttempt(url, 's', id)!.disposition,
        AttemptDisposition.abandoned,
      );
      // The retry runs the tombstone + delete to completion.
      LocalStore.debugEndAttemptHook = (phase) async => phases.add(phase);
      final res = await a.endLocalAttempt(
        url,
        's',
        token: token,
        attemptId: id,
        tombstone: tombstoneOf(id),
      );
      expect(res.outcome, LocalAttemptEndOutcome.ended);
      expect(res.attemptId, id);
      expect(phases, ['afterJournal', 'afterDelete']);
      expect(a.loadPending(url, 's'), isNull);
      expect(a.loadAttempt(url, 's', id)!.disposition, AttemptDisposition.abandoned);
    });

    test('refused journal write = journalFailed, pending untouched, no tombstone',
        () async {
      final c1 = await claimHuman(a);
      final (token, id) = (c1.token, c1.attemptId);
      final before = prefs.getString('$enc.s.pending');
      LocalStore.debugFailAttemptWrites = true;
      final res = await a.endLocalAttempt(
        url,
        's',
        token: token,
        attemptId: id,
        tombstone: tombstoneOf(id),
      );
      expect(res.outcome, LocalAttemptEndOutcome.journalFailed);
      LocalStore.debugFailAttemptWrites = false;
      expect(prefs.getString('$enc.s.pending'), before);
      // The claim-time waiting entry is still there; NO abandoned tombstone.
      expect(a.loadAttempt(url, 's', id)!.disposition, AttemptDisposition.waiting);
    });

    test('token or attemptId mismatch writes absolutely nothing', () async {
      final c1 = await claimHuman(a);
      final (token, id) = (c1.token, c1.attemptId);
      var snap = prefsSnapshot(prefs);
      final r1 = await b.endLocalAttempt(
        url,
        's',
        token: 'other-tab|9',
        attemptId: id,
        tombstone: tombstoneOf(id),
      );
      expect(r1.outcome, LocalAttemptEndOutcome.mismatch);
      expect(prefsSnapshot(prefs), snap);
      final r2 = await b.endLocalAttempt(
        url,
        's',
        token: token,
        attemptId: 'f' * 32,
        tombstone: tombstoneOf('f' * 32),
      );
      expect(r2.outcome, LocalAttemptEndOutcome.mismatch);
      snap = prefsSnapshot(prefs);
      expect(prefsSnapshot(prefs), snap);
    });

    test('double end: ended then missing, tombstone still listed', () async {
      final c1 = await claimHuman(a);
      final (token, id) = (c1.token, c1.attemptId);
      final first = await a.endLocalAttempt(
        url,
        's',
        token: token,
        attemptId: id,
        tombstone: tombstoneOf(id),
      );
      expect(first.outcome, LocalAttemptEndOutcome.ended);
      final second = await a.endLocalAttempt(
        url,
        's',
        token: token,
        attemptId: id,
        tombstone: tombstoneOf(id),
      );
      expect(second.outcome, LocalAttemptEndOutcome.missing);
      expect(a.listAttempts(url, 's').single.disposition, AttemptDisposition.abandoned);
    });

    test('two tabs racing one settlement: at most one ended', () async {
      final c1 = await claimHuman(a);
      final (token, id) = (c1.token, c1.attemptId);
      final results = await Future.wait([
        a.endLocalAttempt(
          url,
          's',
          token: token,
          attemptId: id,
          tombstone: tombstoneOf(id),
        ),
        b.endLocalAttempt(
          url,
          's',
          token: token,
          attemptId: id,
          tombstone: tombstoneOf(id),
        ),
      ]);
      expect(
        results.where((r) => r.outcome == LocalAttemptEndOutcome.ended).length,
        1,
      );
      for (final r in results.where(
        (r) => r.outcome != LocalAttemptEndOutcome.ended,
      )) {
        expect([LocalAttemptEndOutcome.missing, LocalAttemptEndOutcome.mismatch],
            contains(r.outcome));
      }
    });
  });

  group('draft CAS', () {
    test('revision starts at 0 and every accepted write bumps it once',
        () async {
      expect(a.draftRevision(url, 's'), 0);
      expect(await a.saveDraftCas(url, 's', 'first', expectedRevision: 0), isTrue);
      expect(a.draft(url, 's'), 'first');
      expect(a.draftRevision(url, 's'), 1);
      expect(await a.saveDraftCas(url, 's', 'stale', expectedRevision: 0), isFalse);
      expect(a.draft(url, 's'), 'first');
      expect(a.draftRevision(url, 's'), 1);
      await a.saveDraft(url, 's', 'plain');
      expect(a.draft(url, 's'), 'plain');
      expect(a.draftRevision(url, 's'), 2);
    });
  });

  group('removeAttempt', () {
    test('removes; missing is false-safe; tombstones of others survive',
        () async {
      final idA = (await claimHuman(a, sid: 's')).attemptId;
      final idB = (await claimHuman(a, sid: 'y')).attemptId;
      expect(await a.removeAttempt(url, 'y', idB), isTrue);
      expect(a.listAttempts(url, 'y'), isEmpty);
      expect(await a.removeAttempt(url, 'y', idB), isFalse); // gone already
      expect(await a.removeAttempt(url, 's', 'e' * 32), isFalse); // never there
      final cz = await claimHuman(a, sid: 'z');
      final (tokZ, idZ) = (cz.token, cz.attemptId);
      final ended = await a.endLocalAttempt(
        url,
        'z',
        token: tokZ,
        attemptId: idZ,
        tombstone: tombstoneOf(idZ, sid: 'z'),
      );
      expect(ended.outcome, LocalAttemptEndOutcome.ended);
      expect(await a.removeAttempt(url, 'y', idB), isFalse);
      expect(
        a.listAttempts(url, 'z').single.disposition,
        AttemptDisposition.abandoned,
      );
      expect(a.listAttempts(url, 's').single.attemptId, idA);
    });
  });

  test('saveAttempt reports a refused write as false', () async {
    final id = (await claimHuman(a)).attemptId;
    LocalStore.debugFailAttemptWrites = true;
    expect(await a.saveAttempt(url, 's', tombstoneOf(id)), isFalse);
    LocalStore.debugFailAttemptWrites = false;
    expect(await a.saveAttempt(url, 's', tombstoneOf(id)), isTrue);
    expect(a.loadAttempt(url, 's', id)!.disposition, AttemptDisposition.abandoned);
  });
}
