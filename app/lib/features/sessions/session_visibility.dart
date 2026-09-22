import 'dart:async';

import '../../api/hermes_repository.dart';
import '../../l10n/message_key.dart';
import '../../l10n/ui_message.dart';
import '../settings/local_store.dart';

/// BULK-HIDE B2: the ONE visibility pipeline. Single hide is N=1 of the
/// same code the batch workers call — no second flow, no optimistic UI.
/// Success means the SERVER confirmed the desired value AND the local
/// mirror persisted; anything else keeps its own honest state.

enum VisibilityOutcome {
  success,
  serverFailure,
  outcomeUnknown,
  localSyncFailure,
}

class VisibilityResult {
  const VisibilityResult(
    this.id,
    this.desiredHidden,
    this.outcome, {
    this.detail,
  });
  final String id;
  final bool desiredHidden;
  final VisibilityOutcome outcome;

  /// Typed cause for the persistent failure summary (never a raw string).
  final UiMessage? detail;
}

class VisibilityBatchReport {
  const VisibilityBatchReport({
    required this.succeededIds,
    required this.failuresById,
    required this.confirmations,
  });
  final Set<String> succeededIds;
  final Map<String, VisibilityResult> failuresById;

  /// Server-CONFIRMED values per touched id (B3 resolver source #1:
  /// they outrank any older GET result).
  final Map<String, bool> confirmations;

  int get successCount => succeededIds.length;
  int get failureCount => failuresById.length;
}

class VisibilityService {
  VisibilityService(this.repo, this.store, this.server);
  final HermesRepository repo;
  final LocalStore store;
  final String server;

  /// Plan-fixed worker budget: five concurrent PATCHes sharing one cursor.
  static const concurrency = 5;

  Future<VisibilityResult> set(
    String id,
    bool desiredHidden, {
    bool readbackFirst = false,
  }) async {
    if (readbackFirst) {
      // localSyncFailure retry: look at the server BEFORE touching the
      // mirror again; never a blind reverse PATCH.
      try {
        final now = _flag((await repo.sessionDetail(id))['hidden']);
        if (now == desiredHidden) return await _mirror(id, desiredHidden);
        if (now != null) {
          // Another device moved it since: do not silently overwrite —
          // the user's explicit retry (plain set) restates the target.
          return VisibilityResult(
            id,
            desiredHidden,
            VisibilityOutcome.outcomeUnknown,
            detail: const UiMessage.local(MessageKey.sessionsVisibilityUnknown),
          );
        }
      } on ApiException {
        // detail unreadable — fall through to the plain set below.
      }
    }
    final bool? confirmed;
    try {
      confirmed = await repo.setSessionHidden(id, desiredHidden);
    } on ApiException catch (e) {
      if (e.status != null) {
        // Explicit HTTP rejection (400/401/403/404/429/5xx): the local
        // mirror keeps its old value; retry can restate the same bool.
        return VisibilityResult(
          id,
          desiredHidden,
          VisibilityOutcome.serverFailure,
          detail: messageForError(e),
        );
      }
      // Timeout / connection / unparseable: the server may or may not
      // have written — nothing local changes, selection stays.
      return VisibilityResult(
        id,
        desiredHidden,
        VisibilityOutcome.outcomeUnknown,
        detail: messageForError(e),
      );
    } catch (e) {
      return VisibilityResult(
        id,
        desiredHidden,
        VisibilityOutcome.outcomeUnknown,
        detail: messageForError(e),
      );
    }
    if (confirmed == null || confirmed != desiredHidden) {
      return VisibilityResult(
        id,
        desiredHidden,
        VisibilityOutcome.outcomeUnknown,
        detail: const UiMessage.local(MessageKey.sessionsVisibilityUnavailable),
      );
    }
    return _mirror(id, desiredHidden);
  }

  Future<VisibilityResult> _mirror(String id, bool desiredHidden) async {
    try {
      await store.setHidden(server, id, desiredHidden);
    } on HiddenPersistenceFailure {
      return VisibilityResult(
        id,
        desiredHidden,
        VisibilityOutcome.localSyncFailure,
        detail: const UiMessage.local(MessageKey.sessionsLocalSyncFailed),
      );
    }
    // The explicit operation retires any legacy "not yet synced" marker.
    try {
      await store.resolveLegacyHidden(server, [id]);
    } on Object {
      // legacy bookkeeping failure never invalidates a confirmed write
    }
    return VisibilityResult(id, desiredHidden, VisibilityOutcome.success);
  }

  /// Set-deduped, snapshot-stable batch: five workers share a cursor and
  /// each fully finishes one id before taking the next. A failing item
  /// never aborts the workers, and nothing starts twice.
  Future<VisibilityBatchReport> apply(
    Iterable<String> ids,
    bool desiredHidden, {
    void Function(int done, int total)? onProgress,
    Set<String> retryIds = const {},
  }) async {
    final queue = ids.toSet().toList();
    final total = queue.length;
    final succeeded = <String>{};
    final failures = <String, VisibilityResult>{};
    final confirmations = <String, bool>{};
    var cursor = 0, done = 0;
    Future<void> worker() async {
      while (true) {
        final i = cursor++;
        if (i >= queue.length) return;
        final id = queue[i];
        final r = await set(
          id,
          desiredHidden,
          readbackFirst: retryIds.contains(id),
        );
        switch (r.outcome) {
          case VisibilityOutcome.success:
            succeeded.add(id);
            confirmations[id] = desiredHidden;
          case VisibilityOutcome.localSyncFailure:
            // Server IS at the target value: the confirmation stands,
            // the row keeps failing until the mirror catches up.
            confirmations[id] = desiredHidden;
            failures[id] = r;
          case VisibilityOutcome.serverFailure:
          case VisibilityOutcome.outcomeUnknown:
            failures[id] = r;
        }
        onProgress?.call(++done, total);
      }
    }

    await Future.wait([
      for (var k = 0; k < concurrency.clamp(1, total == 0 ? 1 : total); k++)
        worker(),
    ]);
    return VisibilityBatchReport(
      succeededIds: succeeded,
      failuresById: failures,
      confirmations: confirmations,
    );
  }

  static bool? _flag(Object? raw) =>
      raw == null ? null : (raw == true || raw == 1);
}
