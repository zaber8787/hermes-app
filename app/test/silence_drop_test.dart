import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session_activity.dart';

import 'support/localized_app.dart';

// SILENCE-DROP §4: the watchdog must stop calling a merely QUIET stream
// "connection lost". Timing comes from the injected clock seam + fake
// timers — never a real 75s sleep; recovery rounds park on Completers so
// the 1/2/4/8/16/30 ladder is asserted, not waited out.
class FakeRepo extends HermesRepository {
  FakeRepo() : super('http://test.invalid', 'fake');
  StreamController<SseEvent>? _cur;
  List<Message> history = [];
  int sends = 0, reads = 0;
  StreamController<SseEvent> get events => _cur!;
  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async =>
      {'id': sid, 'message_count': 0};
  @override
  Stream<SseEvent> chat(String sid, String input) {
    sends++;
    _cur = StreamController<SseEvent>();
    return _cur!.stream;
  }

  @override
  Future<List<Message>> messages(
    String sid, {
    int offset = 0,
    int limit = 200,
  }) async {
    reads++;
    return history;
  }

  @override
  void cancelStream(String sid) => closeStream();

  void closeStream() {
    final c = _cur;
    if (c != null && !c.isClosed) unawaited(c.close());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  late FakeRepo repo;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    repo = FakeRepo();
  });
  tearDown(() => repo.close());

  ChatController make(WidgetTester tester, List<Completer<void>> waits) {
    final binding = tester.binding; // fake clock: pump(d) moves timers AND now
    return ChatController(
      repo,
      store,
      's',
      now: binding.clock.now,
      wait: (d) {
        final w = Completer<void>();
        waits.add(w);
        return w.future;
      },
    );
  }

  /// Start a turn and let the cross-tab claim + POST settle BEFORE any
  /// timing starts (§4: claim/store completion first, then the clock).
  Future<void> launch(WidgetTester tester, ChatController c) async {
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(repo.sends, 1);
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r","session_id":"s"}'),
    );
    await tester.pump();
    await tester.pump();
    expect(c.phase, ChatPhase.sending);
  }

  /// Release the parked recovery round with a persisted final in history:
  /// read-only reconcile settles; the POST is never touched.
  Future<void> settleByHistory(
    WidgetTester tester,
    ChatController c,
    List<Completer<void>> waits,
  ) async {
    repo.history = const [
      Message(id: '1', role: 'user', content: 'hello'),
      Message(id: '2', role: 'assistant', content: 'persisted final'),
    ];
    waits.last.complete(); // the CURRENTLY PARKED round
    await tester.pump();
    await tester.pump();
    expect(c.phase, ChatPhase.idle);
    repo.closeStream();
  }

  const heartbeat = SseEvent('heartbeat', '{}');

  testWidgets(
    'silence beyond 75s fires the read-only recover exactly once (§4.1)',
    (tester) async {
      final waits = <Completer<void>>[];
      final c = make(tester, waits);
      final sending = c.send('hello');
      await launch(tester, c);

      for (var i = 0; i < 7; i++) {
        await tester.pump(const Duration(seconds: 10));
        expect(c.phase, ChatPhase.sending); // ≤70s: still watching
      }
      await tester.pump(const Duration(seconds: 5)); // t=75.000: no tick fired
      expect(c.phase, ChatPhase.sending);
      await tester.pump(const Duration(seconds: 5)); // t=80 tick: >75s
      expect(c.phase, ChatPhase.recovering);
      expect(c.reconnects, 1);
      expect(repo.sends, 1); // the POST is never replayed
      // B2 update: silence must carry the NEUTRAL checking wording.
      expect((c.error! as UiLocal).key, MessageKey.chatStreamChecking);

      await settleByHistory(tester, c, waits);
      await sending;
      expect(repo.sends, 1);
      c.dispose();
    },
  );

  testWidgets('exactly 75s is NOT past the limit (strict >)', (tester) async {
    final waits = <Completer<void>>[];
    final c = make(tester, waits);
    final sending = c.send('hello');
    await launch(tester, c);

    // Align ticks on 7.5s multiples so one lands EXACTLY at 75.000s.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 7500));
      expect(c.phase, ChatPhase.sending);
    }
    expect(c.reconnects, 0);
    await tester.pump(const Duration(milliseconds: 7500)); // t=82.5 > 75
    expect(c.phase, ChatPhase.recovering);
    expect(c.reconnects, 1);

    await settleByHistory(tester, c, waits);
    await sending;
    c.dispose();
  });

  testWidgets(
    'quiet-but-live stream: neutral ladder, neutral exhaustion, never a '
    'second POST (§4.2)',
    (tester) async {
      final waits = <Completer<void>>[];
      final durations = <int>[];
      final c = ChatController(
        repo,
        store,
        's',
        now: tester.binding.clock.now,
        wait: (d) {
          durations.add(d.inSeconds);
          final w = Completer<void>();
          waits.add(w);
          return w.future;
        },
      );
      final sending = c.send('hello');
      await launch(tester, c);

      await tester.pump(const Duration(seconds: 80)); // tick at 80 > 75
      expect(c.phase, ChatPhase.recovering);
      expect(c.reconnects, 1);
      expect(repo.sends, 1);
      expect((c.error! as UiLocal).key, isNot(MessageKey.chatStateM026));
      expect((c.error! as UiLocal).key, MessageKey.chatStreamChecking);
      expect((c.error! as UiLocal).args['seconds'], 1);

      // Rounds 1..5 reconcile against empty history — never a POST.
      for (var round = 0; round < 5; round++) {
        waits.last.complete();
        await tester.pump();
        await tester.pump();
        expect(c.phase, ChatPhase.recovering);
        expect((c.error! as UiLocal).key, MessageKey.chatStreamChecking);
      }
      // Round 6 fails too: EXHAUSTED but still never "connection lost".
      waits.last.complete();
      await tester.pump();
      await tester.pump();
      expect(durations, [1, 2, 4, 8, 16, 30]);
      expect(c.phase, ChatPhase.uncertain);
      expect((c.error! as UiLocal).key, MessageKey.chatStreamUnconfirmed);
      expect((c.error! as UiLocal).key, isNot(MessageKey.chatStateM027));
      expect(repo.sends, 1);
      expect(c.reconnects, 1);
      c.dispose();
      await sending;
    },
  );

  testWidgets(
    'heartbeats alone keep a 20-minute run alive, silent-but-waiting (§4.3)',
    (tester) async {
      final waits = <Completer<void>>[];
      final c = make(tester, waits);
      final sending = c.send('hello');
      await launch(tester, c);

      for (var minute = 0; minute < 20; minute++) {
        for (var tick = 0; tick < 6; tick++) {
          await tester.pump(const Duration(seconds: 10));
          repo.events.add(heartbeat); // the ONLY traffic for 20 minutes
          await tester.pump();
        }
        expect(c.phase, ChatPhase.sending);
      }
      expect(c.reconnects, 0);
      expect(repo.sends, 1);
      expect(c.streamWaitingNotice, isNotNull); // >30s without OUTPUT
      expect((c.streamWaitingNotice! as UiLocal).args['seconds'], 1200);

      // Business output ends the notice: tool.progress, then assistant.delta.
      repo.events.add(
        const SseEvent('tool.progress', '{"delta":"still working"}'),
      );
      await tester.pump();
      await tester.pump();
      expect(c.streamWaitingNotice, isNull);
      await tester.pump(const Duration(seconds: 45)); // ticks at 1240: notice
      expect(c.streamWaitingNotice, isNotNull);
      repo.events.add(const SseEvent('assistant.delta', '{"delta":"ok"}'));
      await tester.pump();
      await tester.pump();
      expect(c.streamWaitingNotice, isNull);

      repo.events.add(
        const SseEvent('run.completed', '{"completed":true,"messages":[]}'),
      );
      repo.closeStream();
      await tester.pump();
      await tester.pump();
      await sending;
      expect(c.phase, ChatPhase.idle);
      c.dispose();
    },
  );

  testWidgets(
    'two clocks: heartbeats refresh freshness but age the waiting notice '
    '(§4.4)',
    (tester) async {
      final waits = <Completer<void>>[];
      final c = make(tester, waits);
      var notifies = 0;
      c.addListener(() => notifies++);
      final sending = c.send('hello');
      await launch(tester, c);

      await tester.pump(const Duration(seconds: 40)); // notice appears at 40
      expect(c.streamWaitingNotice, isNotNull);
      expect((c.streamWaitingNotice! as UiLocal).args['seconds'], 40);

      // Heartbeat WITHOUT notice-vs-not: a bare heartbeat repaints nothing.
      var before = notifies;
      repo.events.add(heartbeat);
      await tester.pump();
      await tester.pump();
      expect(notifies, before); // no-repaint contract stays intact

      // Heartbeat keeps freshness but NOT the output clock: 10s later the
      // tick only ages the notice; nothing recovers at t=80 (last event 40).
      await tester.pump(const Duration(seconds: 10));
      expect(c.phase, ChatPhase.sending);
      expect(c.reconnects, 0);
      expect((c.streamWaitingNotice! as UiLocal).args['seconds'], 50);

      // A PLAIN event resets BOTH clocks.
      repo.events.add(const SseEvent('assistant.delta', '{"delta":"x"}'));
      await tester.pump();
      await tester.pump();
      expect(c.streamWaitingNotice, isNull);
      before = notifies;
      repo.events.add(heartbeat); // no notice showing: still no repaint
      await tester.pump();
      await tester.pump();
      expect(notifies, before);
      await tester.pump(const Duration(seconds: 45));
      expect(c.phase, ChatPhase.sending); // age on the OUTPUT clock only
      expect((c.streamWaitingNotice! as UiLocal).args['seconds'], 40);

      repo.events.add(
        const SseEvent('run.completed', '{"completed":true,"messages":[]}'),
      );
      repo.closeStream();
      await tester.pump();
      await sending;
      c.dispose();
    },
  );

  testWidgets('unfinished EOF recovers as an OBSERVED interruption (§4.5)', (
    tester,
  ) async {
    final waits = <Completer<void>>[];
    final c = make(tester, waits);
    final sending = c.send('hello');
    await launch(tester, c);

    repo.closeStream(); // EOF before any completion frame
    await tester.pump();
    await tester.pump();
    expect(c.phase, ChatPhase.recovering);
    expect(c.reconnects, 1);
    expect(repo.sends, 1);
    expect((c.error! as UiLocal).key, MessageKey.chatStateM026);
    expect(c.recoveryCause, RecoveryCause.streamEnded);

    await settleByHistory(tester, c, waits);
    await sending;
    c.dispose();
  });

  testWidgets('non-4xx stream error recovers as an interruption (§4.5)', (
    tester,
  ) async {
    final waits = <Completer<void>>[];
    final c = make(tester, waits);
    final sending = c.send('hello');
    await launch(tester, c);

    repo.events.add(const SseEvent('assistant.delta', '{"delta":"x"}'));
    await tester.pump();
    await tester.pump();
    repo.events.addError(const ApiException('upstream exploded', 503));
    await tester.pump();
    await tester.pump();
    expect(c.phase, ChatPhase.recovering);
    expect((c.error! as UiLocal).key, MessageKey.chatStateM026);
    expect(c.recoveryCause, RecoveryCause.streamError);

    await settleByHistory(tester, c, waits);
    await sending;
    c.dispose();
  });

  testWidgets('4xx still settles with rejection — never recovery (§4.5)', (
    tester,
  ) async {
    final waits = <Completer<void>>[];
    final c = make(tester, waits);
    final sending = c.send('hello');
    await launch(tester, c);

    repo.events.addError(const ApiException('rejected', 404));
    await tester.pump();
    await tester.pump();
    expect(c.phase, ChatPhase.idle);
    expect(c.reconnects, 0);
    expect((c.error! as UiLocal).key, MessageKey.chatStateM023);
    await sending;
    c.dispose();
  });

  testWidgets(
    'EOF during a silence backoff upgrades the cause without a second loop '
    '(§4.5)',
    (tester) async {
      final waits = <Completer<void>>[];
      final c = make(tester, waits);
      final sending = c.send('hello');
      await launch(tester, c);

      await tester.pump(const Duration(seconds: 80)); // silence -> recover
      expect(c.phase, ChatPhase.recovering);
      expect(c.recoveryCause, RecoveryCause.silence);
      expect(waits.length, 1);

      repo.closeStream(); // late EOF lands WHILE the loop is single-flight
      await tester.pump();
      await tester.pump();
      expect(c.reconnects, 1); // no second loop, no extra POST
      expect(repo.sends, 1);
      expect(c.recoveryCause, RecoveryCause.streamEnded); // upgraded only

      waits.first.complete(); // round 2 now speaks with the sharper words
      await tester.pump();
      await tester.pump();
      expect((c.error! as UiLocal).key, MessageKey.chatStateM026);
      expect(waits.length, 2);

      await settleByHistory(tester, c, waits);
      await sending;
      c.dispose();
    },
  );

  testWidgets('completing before the limit leaves nothing to recover (§4.6)', (
    tester,
  ) async {
    final waits = <Completer<void>>[];
    final c = make(tester, waits);
    final sending = c.send('hello');
    await launch(tester, c);

    repo.events.add(
      const SseEvent('run.completed', '{"completed":true,"messages":[]}'),
    );
    repo.closeStream();
    await tester.pump();
    await tester.pump();
    expect(c.phase, ChatPhase.idle);

    await tester.pump(const Duration(seconds: 80));
    expect(c.phase, ChatPhase.idle);
    expect(c.reconnects, 0);
    expect(c.streamWaitingNotice, isNull);
    await sending;
    c.dispose();
  });

  testWidgets('a late final during a recovery wait settles the turn (§4.6)', (
    tester,
  ) async {
    final waits = <Completer<void>>[];
    final c = make(tester, waits);
    final sending = c.send('hello');
    await launch(tester, c);

    await tester.pump(const Duration(seconds: 40));
    expect(c.streamWaitingNotice, isNotNull);
    await tester.pump(const Duration(seconds: 40)); // recover
    expect(c.phase, ChatPhase.recovering);
    expect(c.streamWaitingNotice, isNull); // recovering shows checking text

    await settleByHistory(tester, c, waits);
    expect(c.error, isNull);
    expect(c.recoveryCause, isNull);
    await sending;
    c.dispose();
  });

  testWidgets('backgrounded ticks show nothing and arm no recover (§4.6)', (
    tester,
  ) async {
    final waits = <Completer<void>>[];
    final c = make(tester, waits);
    final sending = c.send('hello');
    await launch(tester, c);

    c.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 40));
    expect(c.streamWaitingNotice, isNull); // no notice while hidden
    await tester.pump(const Duration(seconds: 40)); // tick at 80: skipped
    expect(c.phase, ChatPhase.sending);
    expect(c.reconnects, 0);

    repo.events.add(
      const SseEvent('run.completed', '{"completed":true,"messages":[]}'),
    );
    repo.closeStream();
    await tester.pump();
    await tester.pump();
    await sending;
    c.dispose();
  });

  testWidgets('detach, dispose and a new turn never inherit the notice (§4.6)', (
    tester,
  ) async {
    final waits = <Completer<void>>[];
    final c = make(tester, waits);
    final sending = c.send('hello');
    await launch(tester, c);

    await tester.pump(const Duration(seconds: 40));
    expect(c.streamWaitingNotice, isNotNull);

    // Finishing the turn retires notice + cause.
    repo.events.add(
      const SseEvent('run.completed', '{"completed":true,"messages":[]}'),
    );
    repo.closeStream();
    await tester.pump();
    await tester.pump();
    await sending;
    expect(c.phase, ChatPhase.idle);
    expect(c.streamWaitingNotice, isNull);

    // Turn 2 ages from ZERO: exactly 40s of silence means "40", not "80+".
    final sending2 = c.send('again');
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(repo.sends, 2);
    repo.events.add(
      const SseEvent('run.started', '{"run_id":"r2","session_id":"s"}'),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 40));
    expect((c.streamWaitingNotice! as UiLocal).args['seconds'], 40);
    c.dispose(); // dispose clears the notice even mid-sending
    expect(c.streamWaitingNotice, isNull);
    repo.closeStream();
    await sending2;
  });

  testWidgets('detach and dispose clear the notice; stale events no-op (§4.6)', (
    tester,
  ) async {
    final waits = <Completer<void>>[];
    final c = make(tester, waits);
    final sending = c.send('hello');
    await launch(tester, c);

    await tester.pump(const Duration(seconds: 40));
    expect(c.streamWaitingNotice, isNotNull);
    c.detach(); // leaving the page: notice dies with the SSE ownership
    expect(c.streamWaitingNotice, isNull);
    expect(c.recoveryCause, isNull);
    c.dispose();
    expect(c.streamWaitingNotice, isNull);
    repo.closeStream();
    await sending;
  });

  testWidgets('settling retires the waiting clock for the next turn (§4.6)', (
    tester,
  ) async {
    final waits = <Completer<void>>[];
    final c = make(tester, waits);
    final sending = c.send('hello');
    await launch(tester, c);

    await tester.pump(const Duration(seconds: 80)); // recover
    repo.history = const [
      Message(id: '1', role: 'user', content: 'hello'),
      Message(id: '2', role: 'assistant', content: 'persisted final'),
    ];
    waits.first.complete();
    await tester.pump();
    await tester.pump();
    expect(c.phase, ChatPhase.idle);
    expect(c.streamWaitingNotice, isNull);

    // Settlement already cancelled this turn's stream, so an old-token
    // frame CANNOT arrive (physical contract); a fresh pump cannot revive
    // anything either way.
    expect(repo.events.isClosed, isTrue);
    await tester.pump(const Duration(seconds: 90));
    expect(c.phase, ChatPhase.idle);
    expect(c.messages.last.content, 'persisted final');
    expect(c.reconnects, 1); // the silence recover only — never a second
    await sending;
    c.dispose();
  });

  test('silence-drop catalog literals (§4.8)', () {
    for (final s in ['0', '31', '80']) {
      expect(
        t(MessageKey.chatStreamWaiting, args: {'seconds': s}),
        'Waiting for a reply (no output for ${s}s)',
      );
      expect(
        t(MessageKey.chatStreamWaiting,
            locale: AppLocale.zhHant, args: {'seconds': s}),
        '等待回覆（無輸出 $s 秒）',
      );
    }
    expect(
      t(MessageKey.chatStreamChecking, args: {'seconds': 3}),
      'No stream updates received; checking history in 3s. '
      'The message will not be resent.',
    );
    expect(
      t(MessageKey.chatStreamChecking, locale: AppLocale.zhHant, args: {'seconds': 3}),
      '暫未收到串流更新，3 秒後核對歷史；不會重送訊息。',
    );
    expect(
      t(MessageKey.chatStreamUnconfirmed),
      'The result of this turn is still unconfirmed. Use "Re-check" to check again.',
    );
    expect(
      t(MessageKey.chatStreamUnconfirmed, locale: AppLocale.zhHant),
      '尚無法確認這回合的結果。請使用「重新核對」確認。',
    );
    // M026 reworded: it now claims a stream interruption, nothing else.
    expect(
      t(MessageKey.chatStateM026, args: {'seconds': 2}),
      'The reply stream was interrupted; checking history in 2s. '
      'The message will not be resent.',
    );
    expect(
      t(MessageKey.chatStateM026, locale: AppLocale.zhHant, args: {'seconds': 2}),
      '回覆串流中斷，2 秒後核對歷史；不會重送訊息。',
    );
  });
}
