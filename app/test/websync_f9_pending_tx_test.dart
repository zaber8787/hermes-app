/// WEBSYNC F9: the pending-slot transactions must decide from the
/// AUTHORITATIVE storage value re-read INSIDE the critical section —
/// serialization alone is not enough when each tab's shared_preferences
/// instance answers from its own pre-loaded cache.
///
/// Two-tab simulation (contract level): on the VM there is one isolate, so
/// cross-tab staleness is reproduced by handing the second "tab" its own
/// SharedPreferences instance whose cache was built BEFORE the first tab's
/// write (setMockInitialValues re-seeds the backend verbatim and resets the
/// static, so the new instance's cache starts at the snapshot while the
/// shared backend keeps evolving). The web build runs the same bodies under
/// real Web Locks; true dual-browser-context timing is exercised in the
/// .websync-evidence run and its gap is noted there.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/features/settings/local_store.dart';

/// A fresh LocalStore whose cache snapshot is the CURRENT backend — call it
/// BEFORE the other tab writes to freeze this tab's view of the world.
Future<LocalStore> reopenTab() async {
  SharedPreferences? existing;
  try {
    existing = await SharedPreferences.getInstance();
  } on Object {
    existing = null;
  }
  final snapshot = <String, Object>{};
  if (existing != null) {
    for (final k in existing.getKeys()) {
      // Typed legacy accessors; string-first order (the legacy list getter
      // THROWS on a String value, and the scalar getters type-check to null).
      final v = existing.getString(k) ??
          existing.getInt(k) ??
          existing.getDouble(k) ??
          existing.getBool(k) ??
          _stringList(existing, k);
      if (v != null) snapshot[k] = v;
    }
  }
  SharedPreferences.setMockInitialValues(snapshot);
  return LocalStore(await SharedPreferences.getInstance());
}

List<String>? _stringList(SharedPreferences p, String k) {
  try {
    return p.getStringList(k);
  } on Object {
    return null;
  }
}

void main() {
  group('F9 authoritative re-read inside the lock', () {
    test('second tab with a pre-claim cache cannot double-claim', () async {
      SharedPreferences.setMockInitialValues({});
      final a = LocalStore(await SharedPreferences.getInstance());
      final b = await reopenTab(); // B initialized before A ever claimed
      final tokA = await a.claimPending('http://s', 'x',
          userText: 'A says', turnId: 't1');
      final tokB = await b.claimPending('http://s', 'x',
          userText: 'B says', turnId: 't2');
      expect(tokA, isNotNull);
      // The F9 bug: B's stale "empty" cache made this claim succeed too.
      expect(tokB, isNull);
      final rec = a.loadPending('http://s', 'x')!;
      expect(rec.userText, 'A says');
      expect(rec.ownerTurn, 't1');
    });

    test('racing claims from two tabs elect exactly one owner', () async {
      SharedPreferences.setMockInitialValues({});
      final a = LocalStore(await SharedPreferences.getInstance());
      final b = await reopenTab();
      final tokens = await Future.wait([
        a.claimPending('http://s', 'x', userText: 'A', turnId: 'ta'),
        b.claimPending('http://s', 'x', userText: 'B', turnId: 'tb'),
      ]);
      expect(tokens.whereType<String>().length, 1);
    });

    test('stale-cache clear cannot delete a claim that landed after the snapshot',
        () async {
      SharedPreferences.setMockInitialValues({});
      final a = LocalStore(await SharedPreferences.getInstance());
      await a.savePending('http://s', 'x', userText: 'legacy'); // unowned
      final b = await reopenTab(); // B's cache: the UNOWNED record
      final tokA = await a.claimPending('http://s', 'x',
          userText: 'legacy', turnId: 'takeover');
      // B CASes with its stale token (null == null looked true pre-fix) and
      // would wipe A's fresh claim; the re-read must refuse.
      expect(await b.clearPending('http://s', 'x', token: null), isFalse);
      expect(tokA, isNotNull);
      expect(await a.touchPending('http://s', 'x', tokA!), isTrue);
    });

    test('heartbeat is decided from the re-read record, not the cached one',
        () async {
      SharedPreferences.setMockInitialValues({});
      final a = LocalStore(await SharedPreferences.getInstance());
      final tokA = await a.claimPending('http://s', 'x',
          userText: 'A', turnId: 'a1', lease: Duration.zero);
      // A's lease is already dead; B (cache predates everything) takes over.
      final b = await reopenTab();
      final tokB = await b.claimPending('http://s', 'x',
          userText: 'B', turnId: 'b1');
      expect(tokB, isNotNull);
      // A heartbeat-ing with its own token must FAIL from the re-read:
      // its cache still says A owns it, the storage says B does.
      expect(await a.touchPending('http://s', 'x', tokA!), isFalse);
      expect(await b.touchPending('http://s', 'x', tokB!), isTrue);
    });

    test('recovery stamping compares against the re-read token', () async {
      SharedPreferences.setMockInitialValues({});
      final a = LocalStore(await SharedPreferences.getInstance());
      final b = await reopenTab(); // stale view: empty
      final tokA = await a.claimPending('http://s', 'x',
          userText: 'A', turnId: 'a1');
      // B tries to begin recovery with the token it "remembered" (none):
      // storage now has an owner — mismatch, not a blind stamp.
      final r = await b.beginPendingRecovery('http://s', 'x', token: null);
      expect(r.outcome, PendingRecoveryOutcome.mismatch);
      expect((await a.loadPending('http://s', 'x')!).hasRecoveryMetadata,
          isFalse);
      final r2 = await a.beginPendingRecovery('http://s', 'x', token: tokA);
      expect(r2.outcome, PendingRecoveryOutcome.begun);
    });
  });
}
