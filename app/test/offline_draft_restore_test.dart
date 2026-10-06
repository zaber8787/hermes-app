import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/localized_app.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/api/sse.dart';
import 'package:hermes_app/features/attachments/attachment.dart';
import 'package:hermes_app/features/attachments/attachment_controller.dart';
import 'package:hermes_app/features/attachments/draft_store.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/chat/local_attempt.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/models/message.dart';
import 'package:hermes_app/models/session.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/providers.dart';

/// R2 §4.3 draft discipline: the restore action is the ONLY way an attempt
/// snapshot enters the editor, it runs EXACTLY ONCE, current text always
/// wins over it, and no composer write (keystroke, dispose, clear) may
/// overwrite a newer revision.
class FakeRestoreRepo extends HermesRepository {
  FakeRestoreRepo() : super('http://test.invalid', 'fake');
  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async =>
      {'id': sid, 'message_count': 0};
  final events = StreamController<SseEvent>();
  List<Message> history = [];
  int sends = 0;
  int stopCalls = 0;
  @override
  Future<void> stop(String runId) async {
    stopCalls++;
  }

  @override
  Stream<SseEvent> chat(String sid, String input, {String? wakeBatch}) {
    sends++;
    return events.stream;
  }

  @override
  void cancelStream(String sid) => unawaited(events.close());

  @override
  Future<Json> runStatus(String runId) async => {'status': 'running'};

  @override
  Future<List<Message>> messages(
    String sid, {
    int offset = 0,
    int limit = 200,
  }) async => history;
}

class FakeBlobs implements DraftStore {
  final discarded = <String>[];
  @override
  Future<String> stage(Stream<List<int>> source, String key) async => key;
  @override
  Future<void> discard(String ref) async {
    discarded.add(ref);
  }

  @override
  Future<AttachmentSource> open(String ref) async =>
      StreamAttachmentSource(() => Stream.value(const []));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const url = 'http://test.invalid';
  late SharedPreferences prefs;
  late LocalStore store;
  late FakeRestoreRepo repo;
  late ProviderContainer container;
  FakeBlobs? blobs;

  final sessionA = Session(
    id: 's',
    title: 'A',
    count: 1,
    startedAt: 0,
    activity: 0,
    source: 'api_server',
  );

  String inputText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).last).controller!.text;

  Widget app() => UncontrolledProviderScope(
    container: container,
    child: localizedWrap(ChatPage(session: sessionA)),
  );

  Future<void> drain(WidgetTester tester, [int frames = 30]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump();
    }
  }

  Future<void> typeAndSend(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await drain(tester);
  }

  Future<void> leavePage(WidgetTester tester) async {
    await tester.pumpWidget(const Placeholder());
    await tester.pump();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = LocalStore(prefs);
    repo = FakeRestoreRepo();
    blobs = null;
    container = ProviderContainer(
      overrides: [
        localStoreProvider.overrideWithValue(store),
        initialSettingsProvider.overrideWithValue(
          const AppSettings(url: url, key: 'fake'),
        ),
        repositoryProvider.overrideWithValue(repo),
        skillsProvider.overrideWith((ref) async => []),
      ],
    );
  });
  tearDown(() {
    LocalStore.debugEndAttemptHook = null;
    container.dispose();
    repo.close();
  });

  testWidgets('local stop restores the VERBATIM draft exactly once', (
    tester,
  ) async {
    // i18n-exempt: verbatim draft bytes (leading/trailing spaces, emoji,
    // newline) — a preservation fixture, not UI text.
    const raw = ' 復原草稿😀 verbatim \n第二行 ';
    await tester.pumpWidget(app());
    await tester.pump();
    await typeAndSend(tester, raw);
    expect(repo.sends, 1); // one chat attempt opened; it was never accepted
    expect(store.loadPending(url, 's'), isNotNull);
    final attemptId = store.loadPending(url, 's')!.attemptId!;

    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    await drain(tester);
    expect(inputText(tester), raw); // seeded back, byte-for-byte
    expect(store.draft(url, 's'), raw);
    expect(store.loadPending(url, 's'), isNull);
    final entry = store.loadAttempt(url, 's', attemptId)!;
    expect(entry.disposition, AttemptDisposition.abandoned);
    expect(entry.rawDraft, raw);
    expect(entry.draftRestoredRevision, isNotNull); // consumed ONCE
    expect(find.byKey(const ValueKey('chat.restoreDraft')), findsNothing);
    expect(repo.stopCalls, 0); // the local END itself posts nothing

    await leavePage(tester);
    await tester.pumpWidget(app());
    await tester.pump();
    await drain(tester);
    expect(inputText(tester), raw); // slot carries it; no second restore offer
    expect(find.byKey(const ValueKey('chat.restoreDraft')), findsNothing);
    await leavePage(tester);
  });

  testWidgets('typing while a held local stop lands: current text wins', (
    tester,
  ) async {
    const a = 'A 未送草稿';
    final hold = Completer<void>();
    LocalStore.debugEndAttemptHook = (phase) async {
      if (phase == 'afterJournal' && !hold.isCompleted) {
        await hold.future; // stop in flight while the user types B (M17)
      }
    };
    await tester.pumpWidget(app());
    await tester.pump();
    await typeAndSend(tester, a);
    expect(store.loadPending(url, 's'), isNotNull);

    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    await drain(tester, 10); // the local end is parked inside the journal tx
    await tester.enterText(find.byType(TextField), 'B 新輸入');
    await tester.pump();

    hold.complete();
    await drain(tester);

    expect(inputText(tester), 'B 新輸入'); // B never touched
    expect(find.byKey(const ValueKey('chat.restoreDraft')), findsOneWidget);
    final pending = store.loadPending(url, 's');
    expect(pending, isNull); // the tombstone landed before the hold
    final entries = store.listAttempts(url, 's');
    final tomb = entries
        .where((e) => e.disposition == AttemptDisposition.abandoned)
        .single;
    expect(tomb.rawDraft, a); // A preserved in the journal
    expect(tomb.draftRestoredRevision, isNull); // restore NOT force-applied

    // The restore action stays available but never overwrites B.
    await tester.tap(find.text(t(MessageKey.chatRestoreDraft)));
    await drain(tester);
    expect(inputText(tester), 'B 新輸入');
    expect(
      find.text(t(MessageKey.chatDraftRestoreConflict)),
      findsOneWidget,
    );
    expect(
      store.loadAttempt(url, 's', tomb.attemptId)!.draftRestoredRevision,
      isNull,
    );
    await tester.pump(const Duration(milliseconds: 450)); // debounce settles B
    expect(store.draft(url, 's'), 'B 新輸入');
    await leavePage(tester);
  });

  testWidgets('attachments survive a local end; blobs are never discarded', (
    tester,
  ) async {
    blobs = FakeBlobs();
    final seeded = AttachmentDraft(
      localPath: 'blob-1',
      filename: 'note.txt',
      artifactId: 'a' * 32,
      expiresAt:
          DateTime.now().millisecondsSinceEpoch / 1000 + 300, // receipt fresh
    );
    await store.saveAttachments(url, 's', [seeded]);
    container = ProviderContainer(
      overrides: [
        localStoreProvider.overrideWithValue(store),
        initialSettingsProvider.overrideWithValue(
          const AppSettings(url: url, key: 'fake'),
        ),
        repositoryProvider.overrideWithValue(repo),
        skillsProvider.overrideWith((ref) async => []),
        attachmentsProvider.overrideWith(
          (ref, sid) => AttachmentController(
            ref.watch(repositoryProvider),
            ref.watch(localStoreProvider),
            sid,
            blobs: blobs,
          ),
        ),
      ],
    );
    await tester.pumpWidget(app());
    await tester.pump();
    await typeAndSend(tester, '带附件的稿');
    expect(repo.sends, 1);

    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    await drain(tester);

    final ac = container.read(attachmentsProvider('s'));
    expect(ac.drafts, hasLength(1)); // composer entry kept
    expect(ac.drafts.single.localPath, 'blob-1');
    expect(blobs!.discarded, isEmpty); // a local end consumed NO blob
    expect(store.attachments(url, 's').single.localPath, 'blob-1');
    expect(inputText(tester), '带附件的稿');
    await leavePage(tester);
  });

  testWidgets('M16: attempt-backed same-text draft kept, legacy ghost cleared', (
    tester,
  ) async {
    // i18n-exempt: same-text ghost fixtures, not UI text.
    const same = '同一句重送';
    await store.claimPending(url, 's', userText: same, turnId: 't1');
    final attemptId = store.loadPending(url, 's')!.attemptId!;
    final seeded = store.loadAttempt(url, 's', attemptId)!;
    await store.saveAttempt(
      url,
      's',
      LocalAttempt(
        attemptId: seeded.attemptId,
        server: seeded.server,
        sid: seeded.sid,
        createdAt: seeded.createdAt,
        origin: 'human',
        rawDraft: same, // attempt-backed draft equal to the last delivered
        attachmentSnapshots: seeded.attachmentSnapshots,
        editorRevision: seeded.editorRevision,
      ),
    );
    await store.saveDraft(url, 's', same);
    repo.history = const [Message(id: '1', role: 'user', content: same)];

    await tester.pumpWidget(app());
    await tester.pump();
    await drain(tester);
    await tester.pump(const Duration(milliseconds: 30));
    await drain(tester);

    expect(inputText(tester), same); // identity decides, not the bytes
    expect(store.draft(url, 's'), same);
    expect(find.byKey(const ValueKey('chat.restoreDraft')), findsNothing);
    await leavePage(tester);
  });

  testWidgets('legacy delivered same-text draft is still a ghost', (
    tester,
  ) async {
    const same = '同一句重送';
    await store.saveDraft(url, 's', same);
    repo.history = const [Message(id: '1', role: 'user', content: same)];

    await tester.pumpWidget(app());
    await tester.pump();
    await drain(tester);

    expect(inputText(tester), isEmpty); // pre-R2 shape keeps the old rule
    await leavePage(tester);
  });

  test('clearForAttempt removes ONLY the consumed, unreferenced drafts', () async {
    final fake = FakeBlobs();
    const a = AttachmentDraft(localPath: 'blob-A', filename: 'a.txt');
    const b = AttachmentDraft(localPath: 'blob-B', filename: 'b.txt');
    await store.saveAttachments(repo.baseUrl, 's', [a, b]);
    final c = AttachmentController(repo, store, 's', blobs: fake);
    await c.clearForAttempt([a]);
    expect(c.drafts.map((d) => d.localPath), ['blob-B']);
    expect(fake.discarded, ['blob-A']);
    expect(store.attachments(repo.baseUrl, 's').single.localPath, 'blob-B');
    c.dispose();
  });

  test('a blob still referenced by an abandoned journal is never discarded', () async {
    final fake = FakeBlobs();
    const a = AttachmentDraft(localPath: 'blob-A', filename: 'a.txt');
    await store.saveAttachments(repo.baseUrl, 's', [a]);
    await store.saveAttempt(
      repo.baseUrl,
      's',
      LocalAttempt(
        attemptId: 'f' * 32,
        server: repo.baseUrl,
        sid: 's',
        createdAt: DateTime.utc(2026, 1, 1),
        origin: 'human',
        rawDraft: ' abandoned 稿 ',
        attachmentSnapshots: const [a],
        disposition: AttemptDisposition.abandoned,
      ),
    );
    final c = AttachmentController(repo, store, 's', blobs: fake);
    await c.clearForAttempt([a]); // composer cleared by the outcome rule
    expect(c.drafts, isEmpty);
    expect(fake.discarded, isEmpty); // evidence still points at the blob
    c.dispose();
  });

  test('mergeForRestore merges by blob identity, never overwriting receipts', () async {
    final fake = FakeBlobs();
    final olderB = AttachmentDraft(
      localPath: 'blob-B',
      filename: 'b.txt',
      artifactId: 'b' * 32,
      expiresAt: 1, // stale snapshot copy
    );
    final newerB = AttachmentDraft(
      localPath: 'blob-B',
      filename: 'b.txt',
      artifactId: 'c' * 32, // user re-uploaded while away
      expiresAt:
          DateTime.now().millisecondsSinceEpoch / 1000 + 300,
    );
    const a = AttachmentDraft(localPath: 'blob-A', filename: 'a.txt');
    await store.saveAttachments(repo.baseUrl, 's', [newerB]);
    final c = AttachmentController(repo, store, 's', blobs: fake);
    await c.mergeForRestore([a, olderB]);
    expect(c.drafts.map((d) => d.localPath), ['blob-B', 'blob-A']);
    expect(c.drafts.first.artifactId, 'c' * 32); // newer receipt stands
    expect(store.attachments(repo.baseUrl, 's'), hasLength(2));
    c.dispose();
  });
}
