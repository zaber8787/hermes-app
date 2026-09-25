import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../api/hermes_repository.dart';
import '../../l10n/message_key.dart';
import '../../l10n/ui_message.dart';
import '../settings/local_store.dart';
import 'attachment.dart';
import 'draft_store.dart';
import 'file_drop.dart';
import 'picker_session.dart';

/// addFiles 的 staging 故障分類：(b) 來源讀取失敗、(c) 其他暫存錯誤。
/// (a) declared-size 超限走既有 ApiException 路徑，不經此類型。
enum _StageFault { unreadable, broken }

class _StageFaultException implements Exception {
  const _StageFaultException(this.fault);
  final _StageFault fault;
}

class AttachmentController extends ChangeNotifier {
  AttachmentController(
    this.repo,
    this.store,
    this.sid, {
    DraftStore? blobs,
    PickerFactory? pickFactory,
    DateTime Function()? clock,
    Timer Function(Duration, void Function())? timer,
    Duration? pickTimeout,
  }) : drafts = store.attachments(repo.baseUrl, sid),
       _blobs = blobs ?? newDraftStore(),
       _newSession = pickFactory ?? createPickerSession,
       _clock = clock ?? DateTime.now,
       _timer = timer ?? Timer.new,
       _pickBudget = pickTimeout ?? defaultPickBudget;

  /// Total wall budget for ONE pick: dialog wait + provider reads + the
  /// whole batch staging share it; it is never reset per file (B3).
  static const defaultPickBudget = Duration(minutes: 5);

  final HermesRepository repo;
  final LocalStore store;
  final String sid;
  List<AttachmentDraft> drafts;
  bool busy = false, _disposed = false;
  final PickerFactory _newSession;
  final DateTime Function() _clock;
  final Timer Function(Duration, void Function()) _timer;
  final Duration _pickBudget;

  // ---- pick lifetime token machinery (IOS-PICKER-PLAN B3) ----
  // Every await back into pick() rechecks: current token, not disposed,
  // absolute deadline not passed. A superseded/aborted operation can never
  // commit a draft, write prefs, or unlock a newer pick.
  int _pickToken = 0;
  PickerSession? _session;
  Completer<PickerOutcome?>? _pickWait;
  Timer? _pickTimer;
  void Function()? _stageCancel;

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
    if (_disposed) return;
    _disposed = true;
    _pickToken++; // every late continuation of any pick is now inert
    _pickTimer?.cancel();
    _pickTimer = null;
    final cancel = _stageCancel;
    _stageCancel = null;
    cancel?.call();
    final session = _session;
    _session = null;
    session?.abort();
    final wait = _pickWait;
    _pickWait = null;
    if (wait != null && !wait.isCompleted) wait.complete(null);
    super.dispose();
  }

  bool _expiredAt(DateTime deadline) => !_clock().isBefore(deadline);

  Future<void> _save() => store.saveAttachments(repo.baseUrl, sid, drafts);

  /// One pick, one busy window, one ABSOLUTE deadline covering the dialog
  /// wait AND the whole batch staging (IOS-PICKER-PLAN B3). The timer only
  /// models the environment waking up: on every wake the absolute clock
  /// decides; focus merely wakes the check and can never cancel.
  Future<void> pick() async {
    if (_disposed || busy) return;
    final token = ++_pickToken;
    busy = true;
    error = null;
    batchParts = const [];
    batchSucceeded = 0;
    notifyListeners();
    final deadline = _clock().add(_pickBudget);
    final wait = Completer<PickerOutcome?>(); // null = aborted/timed out
    _pickWait = wait;
    PickerSession? session;
    void expire() {
      // Idempotent wake-time expiry: release the parked cancellable read;
      // the session abort and unlock happen once in pick()'s finally.
      if (token != _pickToken || _disposed) return;
      _stageCancel?.call();
      if (!wait.isCompleted) wait.complete(null);
    }

    void tick() {
      if (token != _pickToken || _disposed) return;
      if (_expiredAt(deadline)) {
        expire();
      } else {
        _pickTimer = _timer(deadline.difference(_clock()), tick);
      }
    }

    try {
      session = _session = _newSession();
      // Focus/visibility wake-ups only re-check the deadline (B3.7):
      // they never cancel, and before the deadline they never even expire.
      session.onFocusHint = () {
        if (token == _pickToken && _expiredAt(deadline)) expire();
      };
      _pickTimer = _timer(_pickBudget, tick);
      unawaited(
        session.outcome.then<void>(
          (outcome) => _deliverWait(wait, token, deadline, outcome),
          onError: (Object e) {
            if (token != _pickToken || _disposed || wait.isCompleted) return;
            wait.complete(
              PickerFailed(
                e is UiCarriesMessage
                    ? messageForError(e)
                    : const UiMessage.local(MessageKey.attachmentPickerFailed),
              ),
            );
          },
        ),
      );
      final outcome = await wait.future;
      if (token != _pickToken || _disposed) return; // superseded or disposed
      if (outcome == null) {
        error = const UiMessage.local(MessageKey.attachmentPickerTimeout);
        return;
      }
      switch (outcome) {
        case PickerPicked(:final items):
          for (final item in items) {
            if (token != _pickToken || _disposed) return;
            if (_expiredAt(deadline)) {
              error = const UiMessage.local(MessageKey.attachmentPickerTimeout);
              return;
            }
            await _stagePicked(item, token, deadline);
            if (token != _pickToken || _disposed) return;
            // A commit whose write crossed the deadline still settles —
            // that file stays and NOTHING after it starts (B3 tail).
            if (_expiredAt(deadline)) {
              error = const UiMessage.local(MessageKey.attachmentPickerTimeout);
              return;
            }
          }
        case PickerCancelled():
          break; // explicit cancel: silent (IOS-PICKER-PLAN B4)
        case PickerEmptyUnexpected():
          error = const UiMessage.local(MessageKey.attachmentPickerEmpty);
        case PickerFailed(:final message):
          error = message;
      }
    } catch (e) {
      if (token == _pickToken && !_disposed) {
        error = e is UiCarriesMessage
            ? messageForError(e)
            : const UiMessage.local(MessageKey.attachmentBatchM001);
      }
    } finally {
      // An older operation NEVER unlocks a newer pick (B3.6).
      if (token == _pickToken && !_disposed) {
        _pickTimer?.cancel();
        _pickTimer = null;
        if (!wait.isCompleted) wait.complete(null);
        if (_pickWait == wait) _pickWait = null;
        session?.abort(); // idempotent terminal/late cleanup
        _session = null;
        busy = false;
        notifyListeners();
      }
    }
  }

  /// A result that reaches pick() AFTER its deadline was already due is
  /// judged as a timeout first — it is never staged (B3.7).
  void _deliverWait(
    Completer<PickerOutcome?> wait,
    int token,
    DateTime deadline,
    PickerOutcome outcome,
  ) {
    if (token != _pickToken || _disposed || wait.isCompleted) return;
    if (_expiredAt(deadline)) {
      wait.complete(null); // judged timeout; the result is dropped (B3.7)
      return;
    }
    wait.complete(outcome);
  }

  /// Picked-file staging: AUDIT-01 semantics (sized while spooling, drained
  /// once, never re-enters pickSource) plus the B3 lifetime guards: the
  /// upstream read is cancellable through [_stageCancel], and no commit
  /// happens unless token, disposal and deadline all still hold.
  Future<void> _stagePicked(
    PickedAttachment item,
    int token,
    DateTime deadline,
  ) async {
    final known = item.knownSize;
    if (known != null && known > attachmentMaxBytes) {
      throw const ApiException.local(MessageKey.attachmentTooLarge);
    }
    final raw = item.openStream();
    final bridge = StreamController<List<int>>();
    final sub = raw.listen(
      (chunk) {
        if (!bridge.isClosed) bridge.add(chunk);
      },
      onError: (Object e, StackTrace st) {
        if (!bridge.isClosed) bridge.addError(e, st);
      },
      onDone: () {
        if (!bridge.isClosed) bridge.close();
      },
      cancelOnError: true,
    );
    _stageCancel = () {
      unawaited(sub.cancel());
      if (!bridge.isClosed) bridge.close();
    };
    try {
      var seen = 0;
      final counted = bridge.stream.map((chunk) {
        seen += chunk.length;
        if (seen > attachmentMaxBytes) {
          throw const ApiException.local(MessageKey.attachmentTooLarge);
        }
        return chunk;
      });
      final ref = await _blobs.stage(_readGuarded(counted), _newKey());
      // Late-result gate (B3.4): invalid after token/disposal/deadline —
      // the ref is discarded and NEVER surfaces as a draft or prefs write.
      if (token != _pickToken || _disposed || _expiredAt(deadline)) {
        await _blobs.discard(ref);
        return;
      }
      // Atomic commit zone (B3 tail): once started, the prefs write
      // settles; the file is kept and the loop stops at the next check.
      drafts = [
        ...drafts,
        AttachmentDraft(localPath: ref, filename: safeFilename(item.name)),
      ];
      await _save();
    } finally {
      _stageCancel = null;
      unawaited(sub.cancel());
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
        if (broken > 0) UiMessage.count(MessageKey.attachmentBatchM004, broken),
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
