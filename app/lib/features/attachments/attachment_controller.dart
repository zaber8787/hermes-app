import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import '../../api/hermes_repository.dart';
import '../../l10n/message_key.dart';
import '../../l10n/ui_message.dart';
import '../settings/local_store.dart';
import 'attachment.dart';
import 'draft_store.dart';
import 'file_drop.dart';

/// addFiles 的 staging 故障分類：(b) 來源讀取失敗、(c) 其他暫存錯誤。
/// (a) declared-size 超限走既有 ApiException 路徑，不經此類型。
enum _StageFault { unreadable, broken }

class _StageFaultException implements Exception {
  const _StageFaultException(this.fault);
  final _StageFault fault;
}

class AttachmentController extends ChangeNotifier {
  AttachmentController(this.repo, this.store, this.sid, {DraftStore? blobs})
    : drafts = store.attachments(repo.baseUrl, sid),
      _blobs = blobs ?? newDraftStore();
  final HermesRepository repo;
  final LocalStore store;
  final String sid;
  List<AttachmentDraft> drafts;
  bool busy = false, _disposed = false;
  // Descriptors, never pretranslated strings (I18N-PLAN §4.3): consumers
  // render these with AppStrings.render / LocalizedText.
  UiMessage? error;
  /// Per-failure-count parts for the batch addFiles summary; the joined
  /// {parts} string is locale-dependent (AppStrings.joinParts), so the
  /// WIDGET renders M005 (batchSucceeded == 0) or M006 (partial success)
  /// from these — error stays null while batchParts is non-empty.
  List<UiMessage> batchParts = const [];
  int batchSucceeded = 0;
  final DraftStore _blobs;
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _save() => store.saveAttachments(repo.baseUrl, sid, drafts);

  Future<void> pick() async {
    if (busy) return;
    busy = true;
    error = null;
    batchParts = const [];
    batchSucceeded = 0;
    notifyListeners();
    try {
      final selected = await FilePicker.pickFiles();
      for (final picked in selected) {
        await _stage(picked.readAsByteStream(), picked.name);
      }
    } catch (e) {
      error = e is UiCarriesMessage
          ? messageForError(e)
          : const UiMessage.local(MessageKey.attachmentBatchM001);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Media-sheet result (gallery asset): stage and attach under its title.
  /// `source` must be fresh for staging — the web file stream is one-shot.
  Future<void> pickSource(AttachmentSource source, String name) async {
    if (busy) return;
    busy = true;
    error = null;
    batchParts = const [];
    batchSucceeded = 0;
    notifyListeners();
    try {
      await _stageOnly(source, name);
    } catch (e) {
      error = e is UiCarriesMessage
          ? messageForError(e)
          : const UiMessage.local(MessageKey.attachmentBatchM001);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// 一次拖入多個檔案：共用一個 busy 週期，逐個入車（500MB 上限由 staging
  /// 層把守，WebDraftStore/IO staging 都會拒超大檔）。失敗只計數分類、
  /// 不記 bytes/路徑/exception 原文；成功檔保留，失敗檔不入 drafts。
  Future<void> addFiles(List<DroppedFile> files) async {
    if (busy) return;
    busy = true;
    error = null;
    batchParts = const [];
    batchSucceeded = 0;
    notifyListeners();
    var oversize = 0, unreadable = 0, broken = 0, failed = 0;
    for (final f in files) {
      try {
        await _stageOnly(f.source, f.name);
      } on ApiException {
        // (a) declared-size 超限：_stageOnly 先驗 source.size 的既有路徑。
        failed++;
        oversize++;
      } on _StageFaultException catch (e) {
        failed++;
        if (e.fault == _StageFault.unreadable) {
          unreadable++;
        } else {
          broken++;
        }
      } catch (_) {
        failed++;
        broken++;
      }
    }
    if (failed > 0) {
      // The {parts} join is locale-dependent (AppStrings.joinParts), so the
      // descriptors + counts are exposed and the widget renders M005/M006.
      batchParts = [
        if (oversize > 0)
          UiMessage.count(MessageKey.attachmentBatchM002, oversize),
        if (unreadable > 0)
          UiMessage.count(MessageKey.attachmentBatchM003, unreadable),
        if (broken > 0)
          UiMessage.count(MessageKey.attachmentBatchM004, broken),
      ];
      batchSucceeded = files.length - failed;
    }
    busy = false;
    notifyListeners();
  }

  Future<void> _stageOnly(AttachmentSource source, String name) async {
    final int known;
    try {
      known = await source.size; // web File 帶 size，超大檔直接拒
    } on ApiException {
      rethrow;
    } catch (_) {
      // (b) 連來源大小都取不到：讀取失敗。
      throw const _StageFaultException(_StageFault.unreadable);
    }
    if (known > attachmentMaxBytes) {
      throw const ApiException.local(MessageKey.attachmentTooLarge);
    }
    final Stream<List<int>> bytes;
    try {
      bytes = _readGuarded(source.open());
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const _StageFaultException(_StageFault.unreadable);
    }
    final String ref;
    try {
      ref = await _blobs.stage(bytes, _newKey());
    } on ApiException {
      rethrow;
    } on _StageFaultException {
      rethrow; // 串流深處已分類過的來源讀取失敗。
    } catch (_) {
      // (c) 存入暫存／其他 staging 錯誤。
      throw const _StageFaultException(_StageFault.broken);
    }
    drafts = [
      ...drafts,
      AttachmentDraft(localPath: ref, filename: safeFilename(name)),
    ];
    await _save();
  }

  /// 把來源串流自身的讀取錯誤翻譯成分類用的讀取失敗；資料通過 store 寫入
  /// 階段後才出的錯才是 (c)。
  static Stream<List<int>> _readGuarded(Stream<List<int>> source) =>
      source.transform(
        StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleError: (error, stackTrace, sink) => sink.addError(
            error is ApiException
                ? error // (a) 蓄意的 size/協定錯誤保留原分類。
                : const _StageFaultException(_StageFault.unreadable),
          ),
        ),
      );

  /// File-picker path (AUDIT-01): runs INSIDE pick()'s busy window — it must
  /// not re-enter the guarded public pickSource (that made the whole flow a
  /// silent no-op). The picker stream is single-subscription, so it is sized
  /// while spooling (no size-then-open double consumption) and drained once.
  Future<void> _stage(Stream<List<int>> raw, String name) async {
    var seen = 0;
    final counted = raw.map((chunk) {
      seen += chunk.length;
      if (seen > attachmentMaxBytes) {
        throw const ApiException.local(MessageKey.attachmentTooLarge);
      }
      return chunk;
    });
    final ref = await _blobs.stage(_readGuarded(counted), _newKey());
    drafts = [
      ...drafts,
      AttachmentDraft(localPath: ref, filename: safeFilename(name)),
    ];
    await _save();
  }

  String _newKey() =>
      '${DateTime.now().microsecondsSinceEpoch}-${drafts.length}';

  Future<void> remove(int index) async {
    if (busy) return;
    final old = drafts[index];
    drafts = [...drafts]..removeAt(index);
    await _save();
    await _blobs.discard(old.localPath);
    notifyListeners();
  }

  Future<String> prepare(String text) async {
    if (busy) throw const ApiException.local(MessageKey.attachmentBatchM007);
    busy = true;
    error = null;
    batchParts = const [];
    batchSucceeded = 0;
    notifyListeners();
    try {
      for (var i = 0; i < drafts.length; i++) {
        if (drafts[i].uploaded && !drafts[i].expired) continue;
        final draft = drafts[i];
        final source = await _blobs.open(draft.localPath);
        final receipt = await repo.uploadAttachment(source, draft.filename);
        drafts[i] = draft.withReceipt(receipt);
        await _save(); // Save each receipt before issuing the chat POST.
      }
      if (drafts.any((a) => a.expired)) {
        throw const ApiException.local(MessageKey.attachmentBatchM008);
      }
      return composeAttachmentInput(text, drafts);
    } catch (e) {
      error = e is UiCarriesMessage || e is FormatException
          ? messageForError(e)
          : const UiMessage.local(MessageKey.attachmentBatchM009);
      rethrow;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> clear() async {
    final old = drafts;
    drafts = [];
    await _save();
    for (final draft in old) {
      await _blobs.discard(draft.localPath);
    }
    notifyListeners();
  }
}
