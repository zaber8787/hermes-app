import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/features/attachments/attachment.dart';
import 'package:hermes_app/features/attachments/attachment_controller.dart';
import 'package:hermes_app/features/chat/chat_controller.dart';
import 'package:hermes_app/features/chat/message_content.dart';
import 'package:hermes_app/features/settings/local_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  testWidgets('MessageTime shows clock today, date after midnight or year end', (
    tester,
  ) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 12, 0);
    final otherDay = today.subtract(const Duration(days: 1));
    final otherYear = DateTime(now.year - 1, 1, 1, 8, 5);
    double epoch(DateTime d) => d.millisecondsSinceEpoch / 1000;
    String clock(DateTime d) =>
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              MessageTime(epoch(today)),
              MessageTime(epoch(otherDay)),
              MessageTime(epoch(otherYear)),
            ],
          ),
        ),
      ),
    );
    expect(find.text(clock(today)), findsOneWidget);
    expect(
      find.text('${otherDay.month}/${otherDay.day} ${clock(otherDay)}'),
      findsOneWidget,
    );
    expect(
      find.text('${otherYear.month}/${otherYear.day} ${clock(otherYear)}'),
      findsOneWidget,
    );
  });

  testWidgets(
    'malformed data-URL images degrade to placeholders instead of throwing',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: MessageContent(
                  'MEDIA:data:image/png;base64,aGVsbG8=',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MessageImage), findsOneWidget);
      expect(find.text('圖片無法載入'), findsOneWidget);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: MessageContent('data:image/png;base64,###'),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('圖片資料無效'), findsOneWidget);
    },
  );

  test('unuploaded drafts persist per session across controller rebuilds', () async {
    final dir = await Directory.systemTemp.createTemp('hermes-drafts');
    final a = await File('${dir.path}/a.txt').writeAsString('a');
    final b = await File('${dir.path}/b.txt').writeAsString('b');
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    final repo = HermesRepository('http://127.0.0.1:9', 'k');
    await store.saveAttachments(repo.baseUrl, 's1', [
      AttachmentDraft(localPath: a.path, filename: 'note.txt'),
    ]);
    await store.saveAttachments(repo.baseUrl, 's2', [
      AttachmentDraft(localPath: b.path, filename: 'other.md'),
    ]);
    final first = AttachmentController(repo, store, 's1');
    final second = AttachmentController(repo, store, 's2');
    expect(first.drafts.single.filename, 'note.txt');
    expect(first.drafts.single.uploaded, isFalse);
    expect(second.drafts.single.localPath, b.path);
    expect(second.drafts.single.artifactId, isNull);
    final rebuilt = AttachmentController(repo, store, 's1');
    expect(rebuilt.drafts.single.localPath, a.path);
    expect(rebuilt.drafts.single.artifactId, isNull);
    await first.remove(0);
    expect(await a.exists(), isFalse);
    expect(AttachmentController(repo, store, 's1').drafts, isEmpty);
    expect(AttachmentController(repo, store, 's2').drafts.single.localPath, b.path);
    for (final c in [first, second, rebuilt]) {
      c.dispose();
    }
    repo.close();
    await dir.delete(recursive: true);
  });

  test(
    'keepalive comments reset the silence watchdog before recovery starts',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      var historyReads = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) async {
        if (r.uri.path.endsWith('/messages')) {
          historyReads++;
          r.response.headers.contentType = ContentType.json;
          r.response.write(
            jsonEncode({
              'data': [
                {'id': 'u1', 'role': 'user', 'content': 'hi', 'timestamp': 1},
                {
                  'id': 'a1',
                  'role': 'assistant',
                  'content': 'final',
                  'timestamp': 2,
                },
              ],
            }),
          );
          await r.response.close();
          return;
        }
        await r.drain<void>();
        r.response.bufferOutput = false;
        r.response.headers.contentType = ContentType('text', 'event-stream');
        r.response.write(
          'event: run.started\ndata: {"run_id":"r","session_id":"s"}\n\n',
        );
        await r.response.flush();
        // 75s of darkness leaves only t=80s watchdog checks in range, where
        // the run is silent for >silenceLimit unless keepalives reset it.
        await Future.delayed(const Duration(seconds: 75));
        r.response.write(': keepalive\n\n');
        await r.response.flush();
        await Future.delayed(const Duration(seconds: 13));
        r.response.write(
          'event: run.completed\n'
          'data: {"run_id":"r","session_id":"s","messages":[]}\n\n',
        );
        await r.response.close();
      });
      final repo = HermesRepository('http://127.0.0.1:${server.port}', 'k');
      final c = ChatController(repo, store, 's');
      final phases = <ChatPhase>[];
      c.addListener(() => phases.add(c.phase));
      try {
        await c.send('hi');
        expect(c.phase, ChatPhase.idle);
        expect(c.error, isNull);
        expect(phases.toSet(), {ChatPhase.sending, ChatPhase.idle});
        expect(historyReads, 1);
      } finally {
        c.dispose();
        repo.close();
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
