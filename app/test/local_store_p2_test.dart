import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'dart:convert';
import 'package:hermes_app/l10n/app_strings.dart';
import 'package:hermes_app/models/session.dart';

final kT0 = DateTime.utc(2026, 1, 1);
final kKey = '${Uri.encodeComponent('http://s')}.x.pending';

void main() {
  SharedPreferences.setMockInitialValues({});
  Future<LocalStore> store() async =>
      LocalStore(await SharedPreferences.getInstance());

  group('P2 local store', () {
    test('draft survives store recreation (app kill)', () async {
      final a = await store();
      await a.saveDraft('http://s', 'x', '打到一半的長文\n第二行');
      final b = await store();
      expect(b.draft('http://s', 'x'), '打到一半的長文\n第二行');
      await b.saveDraft('http://s', 'x', '');
      expect((await store()).draft('http://s', 'x'), '');
    });

    test('drafts are per-session and per-server', () async {
      final s = await store();
      await s.saveDraft('http://a', 'x', 'A');
      await s.saveDraft('http://b', 'x', 'B');
      await s.saveDraft('http://a', 'y', 'Y');
      expect(s.draft('http://a', 'x'), 'A');
      expect(s.draft('http://b', 'x'), 'B');
      expect(s.draft('http://a', 'y'), 'Y');
    });

    test('hidden set persists and toggles', () async {
      final a = await store();
      await a.setHidden('http://s', 'h1', true);
      await a.setHidden('http://s', 'h2', true);
      await a.setHidden('http://s', 'h2', false);
      final b = await store();
      expect(b.isHidden('http://s', 'h1'), isTrue);
      expect(b.isHidden('http://s', 'h2'), isFalse);
      expect(b.isHidden('http://other', 'h1'), isFalse);
    });

    test('title cache overrides stale server title on reopen', () async {
      final a = await store();
      await a.cacheTitle('http://s', 'x', '新名字');
      final s = Session(
        id: 'x',
        title: '舊名字',
        count: 1,
        startedAt: 0,
        activity: 0,
        source: 'api_server',
      ).withTitle((await store()).cachedTitle('http://s', 'x') ?? '');
      expect(s.title, '新名字');
    });

    test('titles stay raw; the untitled fallback is display-only', () async {
      // Model/storage never inject a translated string (I18N-PLAN §4.4)…
      expect(Session(id: 'x', title: '', count: 0, startedAt: 0, activity: 0, source: 'api_server').withTitle('').title,
          '');
      // …the LIST/HEADER render applies the locale-aware fallback.
      expect(
        displaySessionTitle(AppStrings(AppLocale.en), ''),
        'Untitled conversation',
      );
      expect(
        displaySessionTitle(AppStrings(AppLocale.zhHant), ''),
        '未命名對話',
      );
      // A server title literally equal to the old fallback stays raw:
      expect(displaySessionTitle(AppStrings(AppLocale.en), '未命名對話'),
          '未命名對話');
    });

    test('lost marker round-trips', () async {
      final a = await store();
      expect(a.lostNotice('http://s', 'x'), isNull);
      await a.markLost('http://s', 'x');
      expect((await store()).lostNotice('http://s', 'x'), isNotNull);
      await a.clearLost('http://s', 'x');
      expect((await store()).lostNotice('http://s', 'x'), isNull);
    });
  });

  group('STUCK-BUSY recovery budget (B3)', () {
    test('legacy pending parses with null recovery fields', () async {
      final st = await store();
      st.prefs.remove(kKey);
      st.prefs.setString(
        kKey,
        jsonEncode({
          'run_id': 'r',
          'user_text': '早先的回合',
          'started_at': kT0.toIso8601String(),
        }),
      );
      final p = st.loadPending('http://s', 'x')!;
      expect(p.recoveryDeadline, isNull);
      expect(p.recoveryRetryUsed, isFalse);
      expect(p.hasRecoveryMetadata, isFalse);
    });

    test('beginPendingRecovery initializes once; reload keeps the deadline',
        () async {
      final st = await store();
      st.prefs.remove(kKey);
      await st.savePending('http://s', 'x', userText: 'q', runId: 'r');
      final b1 = await st.beginPendingRecovery('http://s', 'x', now: kT0);
      expect(b1.outcome, PendingRecoveryOutcome.begun);
      expect(b1.record!.recoveryDeadline, kT0.add(const Duration(seconds: 60)));
      final b2 = await st.beginPendingRecovery(
        'http://s',
        'x',
        now: kT0.add(const Duration(seconds: 10)),
      );
      expect(b2.outcome, PendingRecoveryOutcome.alreadyPresent);
      expect(b2.record!.recoveryDeadline, kT0.add(const Duration(seconds: 60)));
    });

    test('begin compare-mismatch never touches another token\u2019s record',
        () async {
      final st = await store();
      st.prefs.remove(kKey);
      final token =
          (await st.claimPending('http://s', 'x', userText: 'q', turnId: '1'))!;
      final bad = await st.beginPendingRecovery(
        'http://s',
        'x',
        token: 'other-tab|9',
        now: kT0,
      );
      expect(bad.outcome, PendingRecoveryOutcome.mismatch);
      expect(st.loadPending('http://s', 'x')!.hasRecoveryMetadata, isFalse);
      final mine = await st.beginPendingRecovery(
        'http://s',
        'x',
        token: token,
        now: kT0,
      );
      expect(mine.outcome, PendingRecoveryOutcome.begun);
    });

    test('consumeRecoveryRetry is single-shot, re-arms exactly 30s once',
        () async {
      final st = await store();
      st.prefs.remove(kKey);
      await st.savePending('http://s', 'x', userText: 'q', runId: 'r');
      await st.beginPendingRecovery('http://s', 'x', now: kT0);
      final at = kT0.add(const Duration(seconds: 40));
      final c1 = await st.consumeRecoveryRetry('http://s', 'x', now: at);
      expect(c1.outcome, RecoveryRetryOutcome.consumed);
      expect(c1.record!.recoveryDeadline, at.add(const Duration(seconds: 30)));
      expect(c1.record!.recoveryStartedAt, kT0);
      expect(c1.record!.recoveryRetryUsed, isTrue);
      final c2 = await st.consumeRecoveryRetry(
        'http://s',
        'x',
        now: at.add(const Duration(seconds: 5)),
      );
      expect(c2.outcome, RecoveryRetryOutcome.alreadyUsed);
      expect(c2.record!.recoveryDeadline, at.add(const Duration(seconds: 30)));
    });

    test('amend / touch / savePending preserve recovery + startedAt', () async {
      final st = await store();
      st.prefs.remove(kKey);
      final token = (await st.claimPending(
        'http://s',
        'x',
        userText: 'q',
        turnId: '1',
        startedAt: kT0,
      ))!;
      await st.beginPendingRecovery('http://s', 'x', token: token, now: kT0);
      await st.amendPendingRun(
        'http://s',
        'x',
        token: token,
        userText: 'q',
        runId: 'r2',
      );
      var p = st.loadPending('http://s', 'x')!;
      expect(p.recoveryDeadline, kT0.add(const Duration(seconds: 60)));
      await st.touchPending('http://s', 'x', token);
      p = st.loadPending('http://s', 'x')!;
      expect(p.recoveryDeadline, kT0.add(const Duration(seconds: 60)));
      await st.savePending('http://s', 'x', runId: 'r3');
      p = st.loadPending('http://s', 'x')!;
      expect(p.recoveryDeadline, kT0.add(const Duration(seconds: 60)));
      final later = kT0.add(const Duration(minutes: 5));
      await st.savePending('http://s', 'x', userText: 'q2', startedAt: later);
      expect(st.loadPending('http://s', 'x')!.startedAt, later);
      expect(st.loadPending('http://s', 'x')!.recoveryDeadline, isNotNull);
    });

    test('a NEW claim resets the old turn\u2019s recovery metadata', () async {
      final st = await store();
      st.prefs.remove(kKey);
      await st.savePending('http://s', 'x', userText: 'q', runId: 'r');
      await st.beginPendingRecovery('http://s', 'x', now: kT0);
      final token = await st.claimPending(
        'http://s',
        'x',
        userText: '新回合',
        turnId: '2',
        historyAfterId: 77,
      );
      expect(token, isNotNull);
      final p = st.loadPending('http://s', 'x')!;
      expect(p.recoveryDeadline, isNull);
      expect(p.recoveryRetryUsed, isFalse);
      expect(p.historyAfterId, 77);
    });

    test('clearPending compare-mismatch reports false and keeps the record',
        () async {
      final st = await store();
      st.prefs.remove(kKey);
      final token =
          (await st.claimPending('http://s', 'x', userText: 'q', turnId: '1'))!;
      expect(await st.clearPending('http://s', 'x', token: 'stale'), isFalse);
      expect(st.loadPending('http://s', 'x'), isNotNull);
      expect(await st.clearPending('http://s', 'x', token: token), isTrue);
      expect(st.loadPending('http://s', 'x'), isNull);
    });
  });
}
