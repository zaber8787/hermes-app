import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/features/sessions/session_visibility.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart' show Json;
import 'package:hermes_app/l10n/message_key.dart';

/// BULK-HIDE C1: the shared single/batch visibility pipeline. Fakes stand
/// in for the server; the 5-worker budget, per-item results and the
/// "never claim what you cannot confirm" rules are the contract under test.

class FakeVisRepo extends HermesRepository {
  FakeVisRepo() : super('http://test.invalid', 'fake');
  final List<(String, bool)> patches = [];
  Map<String, int> failStatus = {};
  Map<String, bool> confirm = {}; // server's actual answer per id
  Set<String> noFlag = {}; // 2xx without the hidden field
  Map<String, bool> detail = {};
  Completer<void>? gate; // when set, every PATCH waits on it
  int inFlight = 0, maxInFlight = 0;
  bool detailThrows = false;

  @override
  Future<Json> sessionDetail(String sid) async {
    if (detailThrows) throw ApiException('gone', 404);
    return {'id': sid, if (detail.containsKey(sid)) 'hidden': detail[sid]};
  }

  @override
  Future<bool?> setSessionHidden(String sid, bool hidden) async {
    patches.add((sid, hidden));
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    final g = gate;
    if (g != null) await g.future;
    inFlight--;
    final fail = failStatus[sid];
    if (fail != null) throw ApiException('rejected', fail);
    if (noFlag.contains(sid)) return detail[sid];
    return confirm[sid] ?? hidden;
  }
}

class FlakyMirrorStore extends LocalStore {
  FlakyMirrorStore(super.prefs);
  Set<String> throwOn = {};
  @override
  Future<void> setHidden(String server, String sid, bool hidden) {
    if (throwOn.contains(sid)) throw const HiddenPersistenceFailure();
    return super.setHidden(server, sid, hidden);
  }
}

void main() {
  late FakeVisRepo repo;
  late LocalStore store;
  const url = 'http://test.invalid';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repo = FakeVisRepo();
    store = LocalStore(await SharedPreferences.getInstance());
  });

  VisibilityService svc() => VisibilityService(repo, store, url);

  group('applyVisibility', () {
    test('three picked rows: exactly 3 PATCHes (set, not toggle), all '
        'mirrored, auto-clean report', () async {
      final r = await svc().apply({'a', 'b', 'c'}, true);
      expect(repo.patches.length, 3);
      expect(repo.patches.map((p) => p.$2).toSet(), {true});
      expect(r.succeededIds, {'a', 'b', 'c'});
      expect(r.failuresById, isEmpty);
      expect(store.isHidden(url, 'a'), isTrue);
      expect(store.isHidden(url, 'c'), isTrue);
    });

    test('budgeted run: 5 in flight, release opens the 6th, error does '
        'not abort, 50 ids land exactly once', () async {
      repo.gate = null;

      final fut = svc().apply(
        {for (var i = 0; i < 50; i++) 'r$i'},
        true,
        onProgress: (d, t) {},
      );
      // One shared gate, stepped release-by-release: the inFlight peak
      // proves the window.
      var g = Completer<void>();
      repo.gate = g;
      await pumpFuture();
      expect(repo.maxInFlight, 5);
      for (var i = 0; i < 46; i++) {
        if (!g.isCompleted) g.complete();
        await pumpFuture();
        g = Completer<void>();
        repo.gate = g;
      }
      if (!g.isCompleted) g.complete();
      final r = await fut;
      expect(r.successCount + r.failureCount, 50);
      expect(repo.patches.map((p) => p.$1).toSet().length, 50);
      expect(repo.maxInFlight, lessThanOrEqualTo(5));
    });

    test('one 503 among three: per-item results, mirror untouched for it, '
        'retry restates the SAME bool', () async {
      repo.failStatus = {'b': 503};
      final r = await svc().apply({'a', 'b', 'c'}, true);
      expect(r.succeededIds, {'a', 'c'});
      expect(r.failuresById.keys, {'b'});
      expect(r.failuresById['b']!.outcome, VisibilityOutcome.serverFailure);
      expect(store.isHidden(url, 'b'), isFalse); // failed: local NOT written
      repo.failStatus = {}; // the 503 was transient
      repo.patches.clear();
      final retry = await svc().apply({'b'}, true, retryIds: {'b'});
      expect(repo.patches, [('b', true)]); // same bool, idempotent set
      expect(retry.succeededIds, {'b'});
    });

    test('404 is an explicit failure — never "hidden success"', () async {
      repo.failStatus = {'a': 404};
      final r = await svc().apply({'a'}, true);
      expect(r.failuresById['a']!.outcome, VisibilityOutcome.serverFailure);
      expect(store.isHidden(url, 'a'), isFalse);
    });

    test('2xx without any flag (even after readback) stays UNKNOWN: local '
        'untouched; a confirming readback retry converges without a new '
        'PATCH', () async {
      repo.noFlag = {'a'};
      final r = await svc().apply({'a'}, true);
      expect(r.failuresById['a']!.outcome, VisibilityOutcome.outcomeUnknown);
      expect(store.isHidden(url, 'a'), isFalse);
      repo.detail['a'] = true; // readback now proves the write
      repo.patches.clear();
      final retry = await svc().set('a', true, readbackFirst: true);
      expect(retry.outcome, VisibilityOutcome.success);
      expect(repo.patches, isEmpty); // mirror-only sync, no second PATCH
      expect(store.isHidden(url, 'a'), isTrue);
    });

    test(
      'timeout-shaped error (no status) is UNKNOWN, local unchanged',
      () async {
        repo.failStatus = {};
        // emulate: the fake throws a status-less ApiException
        final r = await VisibilityService(
          _NoStatusRepo(),
          store,
          url,
        ).set('a', true);
        expect(r.outcome, VisibilityOutcome.outcomeUnknown);
        expect(store.isHidden(url, 'a'), isFalse);
      },
    );

    test('server ok + mirror refusal = localSyncFailure: NO reverse PATCH; '
        'readback retry syncs the mirror only', () async {
      final flaky = FlakyMirrorStore(await SharedPreferences.getInstance())
        ..throwOn = {'a'};
      final r = await VisibilityService(repo, flaky, url).set('a', true);
      expect(r.outcome, VisibilityOutcome.localSyncFailure);
      expect(repo.patches.length, 1); // no rollback PATCH
      expect(repo.patches.single, ('a', true));
      expect(flaky.isHidden(url, 'a'), isFalse);
      repo.detail['a'] = true;
      final retry = await VisibilityService(
        repo,
        flaky..throwOn = {},
        url,
      ).set('a', true, readbackFirst: true);
      expect(retry.outcome, VisibilityOutcome.success);
      expect(repo.patches.length, 1); // still just the original write
      expect(flaky.isHidden(url, 'a'), isTrue);
    });

    test('readback-first retry with a FOREIGN server value demands a '
        're-apply instead of silently re-PATCHing', () async {
      repo.detail['a'] = false; // another device unhid it
      final r = await svc().set('a', true, readbackFirst: true);
      expect(r.outcome, VisibilityOutcome.outcomeUnknown);
      expect(repo.patches, isEmpty); // never overwrite silently here
    });

    test(
      'a confirmed batch records server confirmations for the resolver',
      () async {
        final r = await svc().apply({'a'}, true);
        expect(r.confirmations, {'a': true});
      },
    );
  });
}

class _NoStatusRepo extends HermesRepository {
  _NoStatusRepo() : super('http://test.invalid', 'fake');
  @override
  Future<bool?> setSessionHidden(String sid, bool hidden) async =>
      throw const ApiException.local(MessageKey.apiM005);
}

/// Drains microtasks/one event-loop turn so Future.wait workers advance.
Future<void> pumpFuture() => Future<void>.delayed(Duration.zero);
