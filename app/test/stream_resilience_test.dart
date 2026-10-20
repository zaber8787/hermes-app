import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'audit05_poll_owner_test.dart' show FakePollRepo;

class ResilienceRepo extends FakePollRepo {
  int activityCalls = 0;
  @override
  Future<SessionActivity> sessionActivity(String sid) async {
    activityCalls++;
    return SessionActivity(
      sessionId: sid,
      resolvedSessionId: sid,
      serverEpoch: '1',
      observedAt: 0,
      historyRevision: HistoryRevision(sid, history.length, history.length),
      activityRevision: activityCalls,
      activeRuns: const [],
      recentTerminal: const [],
      overflow: false,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final failure in ['eof', 'error', 'empty']) {
    testWidgets('$failure falls back once, merges and settles on resume', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      final repo = ResilienceRepo();
      final c = ChatController(repo, store, 's', webStreamRecovery: true);
      final sending = c.send('hi');
      await tester.pump();
      if (failure != 'empty') {
        repo.events.add(
          const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
        );
        await tester.pump();
      }
      if (failure == 'error') repo.events.addError(StateError('stream lost'));
      unawaited(repo.events.close());
      await tester.pump();
      expect(c.streamPolling, isTrue);
      expect(repo.sends, 1);
      expect(c.streamQuietNotice, isNotNull);
      if (failure != 'empty') {
        final before = repo.statusCalls;
        repo.history = const [
          Message(id: 'u1', role: 'user', content: 'hi', timestamp: 1),
        ];
        await tester.pump(const Duration(seconds: 6));
        expect(repo.statusCalls, greaterThan(before));
        expect(repo.messagesCalls, greaterThan(0));
        expect(c.messages.any((m) => m.content == 'hi'), isTrue);
        expect(repo.activityCalls, greaterThan(1));
        c.didChangeAppLifecycleState(AppLifecycleState.hidden);
        c.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await tester.pump();
        expect(c.streamPolling, isTrue);
        expect(repo.sends, 1);
        repo.history = const [
          Message(id: 'u1', role: 'user', content: 'hi', timestamp: 1),
          Message(id: 'a1', role: 'assistant', content: 'done', timestamp: 2),
        ];
        c.didChangeAppLifecycleState(AppLifecycleState.hidden);
        repo.status = (_) => {'status': 'completed'};
        c.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await tester.pump();
        expect(c.phase, ChatPhase.idle);
        expect(c.streamPolling, isFalse);
        expect(c.messages.any((m) => m.content == 'done'), isTrue);
        final stopped = repo.statusCalls;
        await tester.pump(const Duration(seconds: 12));
        expect(repo.statusCalls, stopped);
      }
      expect(repo.sends, 1);
      c.dispose();
      repo.close();
      await sending;
    });
  }

  testWidgets('native EOF retains bounded recovery', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    final repo = ResilienceRepo();
    final c = ChatController(repo, store, 's', webStreamRecovery: false);
    final sending = c.send('hi');
    await tester.pump();
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r1","session_id":"s"}'),
    );
    await tester.pump();
    unawaited(repo.events.close());
    await tester.pump();
    expect(c.streamPolling, isFalse);
    expect(repo.sends, 1);
    c.dispose();
    await tester.pump(const Duration(seconds: 31));
    await sending;
    repo.close();
  });
}
