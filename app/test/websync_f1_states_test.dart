/// WEBSYNC F1: "串流中斷" splits into three honest states once recovery
/// is exhausted — DELIVERED-but-reply-loading (the message demonstrably
/// landed: a runId exists or the text is in history), STREAM UNAVAILABLE
/// (observed transport failure AND the text is positively NOT in history —
/// the only path allowed to offer a resend), and UNCONFIRMED (neutral).
/// The old M027 resend bait may never appear on a landed path.
import 'dart:async';
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
  Stream<SseEvent> chat(String sid, String input, {String? wakeBatch}) {
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
    final binding = tester.binding;
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

  Future<void> pumpClaim(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(repo.sends, 1);
  }

  Future<void> runAllRounds(WidgetTester tester, List<Completer<void>> waits)
      async {
    for (var round = 0; round < 6; round++) {
      waits.last.complete();
      await tester.pump();
      await tester.pump();
    }
  }

  testWidgets(
    'EOF mid-stream with the user row already in history: DELIVERED, never '
    'the resend bait',
    (tester) async {
      final waits = <Completer<void>>[];
      final c = make(tester, waits);
      final sending = c.send('hello');
      await pumpClaim(tester);
      repo.events.add(
        const SseEvent('run.started', '{"run_id":"r","session_id":"s"}'),
      );
      await tester.pump();
      repo.events.add(
        const SseEvent('message', '{"content":"partial"}'),
      );
      await tester.pump();
      repo.history = const [Message(id: '1', role: 'user', content: 'hello')];
      repo.closeStream(); // EOF with no final — stream died, text landed
      await tester.pump();
      await tester.pump();
      expect(c.phase, ChatPhase.recovering);

      await runAllRounds(tester, waits);
      expect(c.phase, ChatPhase.uncertain);
      final key = (c.error! as UiLocal).key;
      expect(key, MessageKey.chatDeliveredReplyLoading);
      expect(key, isNot(MessageKey.chatStateM027)); // the F1 contract
      expect(repo.sends, 1); // never a re-POST on a landed turn
      c.dispose();
      await sending;
    },
  );

  testWidgets(
    'EOF before run.started with empty history: stream unavailable — the '
    'ONLY exhausted path allowed to offer a resend',
    (tester) async {
      final waits = <Completer<void>>[];
      final c = make(tester, waits);
      final sending = c.send('hello');
      await pumpClaim(tester);
      repo.closeStream(); // EOF before any ack: acceptance never confirmed
      await tester.pump();
      await tester.pump();
      expect(c.phase, ChatPhase.recovering);

      await runAllRounds(tester, waits);
      expect(c.phase, ChatPhase.uncertain);
      expect((c.error! as UiLocal).key, MessageKey.chatStreamUnavailable);
      expect(repo.sends, 1);
      c.dispose();
      await sending;
    },
  );

  testWidgets(
    'neutral silence exhaustion without a runId stays unconfirmed (not '
    'delivered, not resend-baited)',
    (tester) async {
      final waits = <Completer<void>>[];
      final c = make(tester, waits);
      final sending = c.send('hello');
      await pumpClaim(tester);
      await tester.pump(const Duration(seconds: 80)); // silence, no runId
      expect(c.phase, ChatPhase.recovering);
      expect(c.recoveryCause, RecoveryCause.silence);

      await runAllRounds(tester, waits);
      expect(c.phase, ChatPhase.uncertain);
      expect((c.error! as UiLocal).key, MessageKey.chatStreamUnconfirmed);
      expect(repo.sends, 1);
      c.dispose();
      await sending;
    },
  );

  testWidgets(
    'a KNOWN run alone is acceptance even while every history read comes '
    'back empty',
    (tester) async {
      final waits = <Completer<void>>[];
      final c = make(tester, waits);
      final sending = c.send('hello');
      await pumpClaim(tester);
      repo.events.add(
        const SseEvent('run.started', '{"run_id":"r","session_id":"s"}'),
      );
      await tester.pump();
      repo.closeStream();
      await tester.pump();
      await tester.pump();
      await runAllRounds(tester, waits);
      expect(c.phase, ChatPhase.uncertain);
      expect(
        (c.error! as UiLocal).key,
        MessageKey.chatDeliveredReplyLoading,
      );
      c.dispose();
      await sending;
    },
  );

  test('F1 catalog literals (bilingual)', () {
    expect(
      t(MessageKey.chatDeliveredReplyLoading),
      'Message delivered — your reply is still loading. '
      'Use "Re-check" to refresh it.',
    );
    expect(
      t(MessageKey.chatDeliveredReplyLoading, locale: AppLocale.zhHant),
      '訊息已送達，回覆載入中。可使用「重新核對」更新。',
    );
    expect(
      t(MessageKey.chatStreamUnavailable),
      'The reply stream is unavailable and this message was not found in '
      'history; it may not have been accepted. You can resend it — re-check '
      'first to avoid sending twice.',
    );
    expect(
      t(MessageKey.chatStreamUnavailable, locale: AppLocale.zhHant),
      '回覆串流不可用，且歷史未見這則訊息，可能未入庫；可重送，'
      '建議先「重新核對」避免重複。',
    );
  });
}
