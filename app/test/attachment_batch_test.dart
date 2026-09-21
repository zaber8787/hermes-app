import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/l10n/app_locale.dart';
import 'package:hermes_app/l10n/app_strings.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';
import 'package:hermes_app/models/session_activity.dart';
import 'package:hermes_app/features/attachments/attachment.dart';
import 'package:hermes_app/features/attachments/attachment_controller.dart';
import 'package:hermes_app/features/attachments/draft_store.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/models/message.dart' show Json;

/// 來源讀取失敗的故障注入（不 import dart:io；VM 測試用抽象錯誤即可）。
class SourceGone implements Exception {
  const SourceGone();
}

class StageBroken implements Exception {
  const StageBroken();
}

/// Re-openable fake bytes source with per-fault injection points.
class FakeSource implements AttachmentSource {
  FakeSource.ok(List<int> bytes)
    : _bytes = bytes,
      _sizeError = null,
      _readError = null,
      _declared = null;
  FakeSource.unreadable()
    : _bytes = null,
      _sizeError = const SourceGone(),
      _readError = null,
      _declared = null;
  FakeSource.readFails({int declaredSize = 4})
    : _bytes = null,
      _sizeError = null,
      _readError = const SourceGone(),
      _declared = declaredSize;
  final List<int>? _bytes;
  final Object? _sizeError;
  final Object? _readError;
  final int? _declared;
  int opens = 0;

  @override
  Future<int> get size {
    if (_sizeError != null) return Future<int>.error(_sizeError);
    return Future.value(_declared ?? _bytes!.length);
  }

  @override
  Stream<List<int>> open() {
    opens++;
    final controller = StreamController<List<int>>();
    // 非同步送資料與錯誤：reject 若沒被 await-for 接住就會變成 unhandled。
    Future.microtask(() {
      if (_bytes != null) controller.add(_bytes);
      if (_readError != null) {
        controller.addError(_readError);
      } else {
        controller.close();
      }
    });
    return controller.stream;
  }
}

/// In-memory DraftStore injected via constructor: no path_provider, no disk.
class FakeDraftStore implements DraftStore {
  final staged = <String, List<int>>{};
  final discarded = <String>[];
  Future<void>? stageGate; // Completer hook: block staging inside tests.
  Object? stageError; // for (c) 其他 staging 錯誤

  @override
  Future<String> stage(Stream<List<int>> source, String key) async {
    if (stageGate != null) await stageGate;
    if (stageError != null) throw stageError!;
    final bytes = <int>[];
    await for (final chunk in source) {
      bytes.addAll(chunk);
    }
    final ref = 'fake/$key';
    staged[ref] = bytes;
    return ref;
  }

  @override
  Future<void> discard(String ref) async {
    discarded.add(ref);
    staged.remove(ref);
  }

  @override
  Future<AttachmentSource> open(String ref) async {
    final bytes = staged[ref];
    if (bytes == null) {
      throw const ApiException('附件快取已遺失，請移除後重新選取。');
    }
    return StreamAttachmentSource(() => Stream.value(bytes), bytes.length);
  }
}

/// Upload fake: no HTTP, distinct artifact_id per call, records payloads.
class FakeArtifactRepo extends HermesRepository {
  @override
  Future<SessionActivity> sessionActivity(String sid) async =>
      SessionActivity.quiet(sid);
  FakeArtifactRepo() : super('http://fake.invalid', 'fake');

  @override
  Future<Map<String, dynamic>> sessionDetail(String sid) async =>
      {'id': sid, 'message_count': 0}; // R1 sync clock: quiet by default
  final payloads = <List<int>>[];
  int calls = 0;
  @override
  Future<Json> uploadAttachment(
    AttachmentSource source,
    String filename,
  ) async {
    final bytes = <int>[];
    await for (final chunk in source.open()) {
      bytes.addAll(chunk);
    }
    payloads.add(bytes);
    final id = String.fromCharCode(97 + calls) * 32;
    calls++;
    return {
      'artifact_id': id,
      'filename': filename,
      'size_bytes': bytes.length,
      'expires_at': DateTime.now().millisecondsSinceEpoch / 1000 + 300,
    };
  }
}

void main() {
  late LocalStore store;
  late FakeArtifactRepo repo;
  late FakeDraftStore blobs;
  late AttachmentController controller;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    repo = FakeArtifactRepo();
    blobs = FakeDraftStore();
    controller = AttachmentController(repo, store, 's', blobs: blobs);
  });
  tearDown(() {
    controller.dispose();
    repo.close();
  });

  Future<List<int>> bytesOf(String ref) async {
    final source = await blobs.open(ref);
    final out = <int>[];
    await for (final chunk in source.open()) {
      out.addAll(chunk);
    }
    return out;
  }

  test('batch of three keeps successes in order when the middle read fails',
      () async {
    await controller.addFiles([
      (name: 'a.txt', source: FakeSource.ok(utf8.encode('AAA'))),
      (name: 'b.png', source: FakeSource.readFails()),
      (name: 'c.txt', source: FakeSource.ok(utf8.encode('CCC'))),
    ]);

    expect(controller.drafts.map((d) => d.filename), ['a.txt', 'c.txt']);
    // 失敗檔無 metadata 殘留（prefs 與 blob store 都只有兩檔）。
    expect(store.attachments(repo.baseUrl, 's').map((d) => d.filename),
        ['a.txt', 'c.txt']);
    expect(blobs.staged.length, 2);
    expect(blobs.discarded, isEmpty);
    expect(controller.busy, isFalse);
    expect(controller.error, isNull);
    expect(controller.batchSucceeded, 2);
    final part = controller.batchParts.single as UiLocal;
    expect(part.key, MessageKey.attachmentBatchM003);
    expect(part.count, 1);
    final en = AppStrings.forLocale(AppLocale.en);
    final zh = AppStrings.forLocale(AppLocale.zhHant);
    expect(en.render(part), '1 file could not be read');
    expect(zh.render(part), '1 個檔案讀取失敗');
    expect(
      zh.resolve(
        MessageKey.attachmentBatchM006,
        args: {'parts': zh.joinParts([zh.render(part)]), 'count': 2},
        count: 2,
      ),
      '1 個檔案讀取失敗，成功 2 個。',
    );

    // 順序與內容 round-trip：staged refs 仍對應各自的來源。
    expect(await bytesOf(controller.drafts[0].localPath), utf8.encode('AAA'));
    expect(await bytesOf(controller.drafts[1].localPath), utf8.encode('CCC'));
  });

  test('two same-named files with different bytes stay two distinct drafts',
      () async {
    await controller.addFiles([
      (name: 'same.png', source: FakeSource.ok([1, 2, 3])),
      (name: 'same.png', source: FakeSource.ok([4, 5, 6, 7])),
    ]);

    expect(controller.drafts, hasLength(2));
    expect(controller.drafts[0].localPath, isNot(controller.drafts[1].localPath));
    expect(await bytesOf(controller.drafts[0].localPath), [1, 2, 3]);
    expect(await bytesOf(controller.drafts[1].localPath), [4, 5, 6, 7]);
    expect(controller.error, isNull);

    final prompt = await controller.prepare('看這兩個');
    expect(
      prompt,
      '看這兩個\n[附件: ${'a' * 32} same.png]\n[附件: ${'b' * 32} same.png]',
    );
    // 上傳各自讀到正確的來源 bytes（未按檔名去重/覆寫）。
    expect(repo.payloads, [
      [1, 2, 3],
      [4, 5, 6, 7],
    ]);
    final lines = composeAttachmentInput('', controller.drafts).split('\n');
    expect(lines, hasLength(2));
    expect(lines.where((l) => l.endsWith('same.png]')), hasLength(2));

    // 重建的 controller 從 metadata 還原兩份不同 localPath。
    final reopened = AttachmentController(repo, store, 's', blobs: blobs);
    expect(reopened.drafts.map((d) => d.localPath).toSet(), hasLength(2));
    expect(await bytesOf(reopened.drafts[0].localPath), [1, 2, 3]);
    expect(await bytesOf(reopened.drafts[1].localPath), [4, 5, 6, 7]);
    reopened.dispose();
  });

  test('a reject inside the batch never escapes as an unhandled async error',
      () async {
    final unhandled = <Object>[];
    await runZonedGuarded(() async {
      await controller.addFiles([
        (name: 'ok.txt', source: FakeSource.ok(utf8.encode('ok'))),
        (name: 'late.txt', source: FakeSource.readFails(declaredSize: 9)),
      ]);
    }, (e, _) => unhandled.add(e));

    expect(unhandled, isEmpty);
    expect(controller.drafts.map((d) => d.filename), ['ok.txt']);
    expect(controller.error, isNull);
    expect((controller.batchParts.single as UiLocal).key,
        MessageKey.attachmentBatchM003);
    expect(controller.busy, isFalse);
  });

  test('staging write failures classify separately from read failures',
      () async {
    blobs.stageError = const StageBroken();
    await controller.addFiles([
      (name: 'x.txt', source: FakeSource.ok(utf8.encode('x'))),
    ]);
    expect(controller.drafts, isEmpty);
    expect(store.attachments(repo.baseUrl, 's'), isEmpty);
    expect(controller.error, isNull);
    final broken = controller.batchParts.single as UiLocal;
    expect(broken.key, MessageKey.attachmentBatchM004);
    expect(broken.count, 1);
    expect(
      AppStrings.forLocale(AppLocale.zhHant).render(broken),
      '1 個檔案附加失敗',
    );

    blobs.stageError = null;
    await controller.addFiles([
      (name: 'y.txt', source: FakeSource.unreadable()),
    ]);
    expect((controller.batchParts.single as UiLocal).key,
        MessageKey.attachmentBatchM003);
  });
}
