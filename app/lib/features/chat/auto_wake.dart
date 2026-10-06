import 'dart:async';

import '../../models/message.dart';
import '../settings/local_store.dart';

/// A cron report the server proved it delivered (provenance present) and
/// this client has queued for a possible auto-wake.
class WakeCandidate {
  const WakeCandidate({
    required this.messageId,
    required this.deliveryKey,
    required this.order,
  });
  final String messageId;
  final String deliveryKey;

  /// The numeric message id — the ONLY ordering clue the client trusts
  /// (plan §2): never lexicographic ids, timestamps, or array index.
  final int order;
}

/// APPWAKE A: pure detection + durable queue for foreground auto-wake.
/// Batch A is SHADOW ONLY: it discovers candidates and persists the queue
/// and the scan cursor; it never sends anything. Dispatch integration
/// arrives later — everything here stays free of controller/SSE
/// dependencies so the whole state machine is testable standalone.
class AutoWakeObserver {
  AutoWakeObserver({
    required this.store,
    required this.serverUrl,
    required this.sid,
    required DateTime Function() now,
  }) : _now = now;

  final LocalStore store;
  final String serverUrl;
  final String sid;
  final DateTime Function() _now;

  Map<String, dynamic>? _state; // null = never armed under this scope
  bool _running = false;
  bool _dirty = false;
  bool _persistedOk = false; // queue on disk? dispatch gate prerequisite

  static final _prefix = RegExp(r'^\[Cron report: [^\]]*\]\n');

  bool get armed => _state != null;

  /// Queued (discovered, not yet admitted) report count for the UI hint.
  int get pendingCount => armed
      ? (((_state!['queued']) as List?) ?? const []).length
      : 0;

  Map<String, dynamic>? get state => _state;

  /// The candidate test (plan §3): FIVE conditions or nothing — role=user,
  /// display_kind=internal_notification, SERVER-verified cron provenance,
  /// later than the armed cutoff, not yet consumed/queued. assistant/tool/
  /// system/ordinary user/other internal_notification rows and anything
  /// without provenance are never candidates.
  static WakeCandidate? candidate(Message m, {int? cutoff}) {
    if (m.role != 'user' || m.displayKind != 'internal_notification') {
      return null;
    }
    final provenance = m.cronProvenance;
    if (provenance == null) return null;
    final order = int.tryParse(m.id);
    if (order == null) return null; // non-numeric id: never guess order
    if (cutoff != null && order <= cutoff) return null;
    return WakeCandidate(
      messageId: m.id,
      deliveryKey: provenance.deliveryKey,
      order: order,
    );
  }

  /// Bridge report body minus the fixed "[Cron report: name]" prefix AND
  /// the cron header block (up to the dashed separator), for the
  /// NO_REPLY / HEARTBEAT_OK / empty checks. WHOLE-body equality only — a
  /// report that merely mentions those must never be killed.
  static String reportBody(String content) => content
      .replaceFirst(_prefix, '')
      .replaceFirst(RegExp(r'^(.*?\n)?-{6,}\n', dotAll: true), '')
      .trim();

  /// The successful LATEST-page commit is the only scan entry (plan §2:
  /// committed messages are the truth — stale GETs, old pages and repeat
  /// reconciles never produce a wake). The caller identity-guards the
  /// commit before calling this. [latestPage]=false (an older-page merge)
  /// never re-arms and never advances the cursor.
  Future<void> onHistoryCommit(
    List<Message> messages, {
    bool latestPage = true,
  }) async {
    if (_running) {
      _dirty = true; // exactly one follow-up re-scan after the pass
      return;
    }
    _running = true;
    try {
      var rows = messages;
      var latest = latestPage;
      while (true) {
        _dirty = false;
        await _scan(rows, latestPage: latest);
        if (!_dirty) break;
        rows = const [];
        latest = false; // the re-scan re-reads from the store, not "latest"
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _scan(List<Message> messages, {required bool latestPage}) async {
    if (!store.autoWakeEnabled(serverUrl) ||
        store.autoWakeSessionOff(serverUrl, sid)) {
      // OFF (or session-excluded): never keep a stale queue — re-enabling
      // starts a FRESH cutoff later (plan §2 rule 5). An already-accepted
      // run's recovery is independent and continues.
      if (_state != null) {
        _state = null;
        _persistedOk = false;
        await store.clearWakeState(serverUrl, sid);
      }
      return;
    }
    final disk = store.wakeState(serverUrl, sid);
    if (disk == null && _state == null && latestPage) {
      // First arm: the cutoff is the SUCCESSFULLY fetched server cutoff —
      // pre-existing reports never replay; later arrivals still count.
      _state = _freshArmed(messages);
      _persistedOk = await _persist();
      return;
    }
    if (disk == null && _state == null) {
      return; // old-page merge before any arm: nothing to observe yet
    }
    if (disk != null) {
      _state = disk; // restart / other tab: queue + cursor survive as-is
    }
    final st = _state!;

    // Ordering gate (plan §2): a commit mixing numeric and non-numeric ids
    // gives no trustworthy order — auto-dispatch is blocked (plan() refuses
    // to fire) and the cursor never jumps; queueing stays safe because it
    // dedups by delivery_key, not by position.
    final hasNumeric = messages.any((m) => int.tryParse(m.id) != null);
    final hasForeign = messages.any((m) => int.tryParse(m.id) == null);
    final uncertain = hasNumeric && hasForeign;
    st['orderUncertain'] = uncertain;

    var lastSeen = (st['lastSeenOrder'] as num?)?.toInt() ?? 0;
    final ignored = _keySet(st, 'ignoredKeys');
    final queued = List<Map<String, dynamic>>.from(
      ((st['queued']) as List?)
              ?.map((e) => Map<String, dynamic>.from(e as Map)) ??
          const [],
    );
    final queuedKeys = {for (final q in queued) q['dk'] as String};
    final cutoff = (st['cutoffOrder'] as num?)?.toInt();
    // A commit whose oldest numeric row leaves a gap under the cursor
    // cannot prove coverage — do NOT advance past the hole; re-query later.
    final oldest = messages
        .map((m) => int.tryParse(m.id))
        .whereType<int>()
        .fold<int?>(null, (lo, n) => lo == null || n < lo ? n : lo);
    final coversCursor =
        !latestPage || uncertain || oldest == null || oldest <= lastSeen + 1;
    for (final m in messages) {
      final order = int.tryParse(m.id);
      if (latestPage && coversCursor && order != null && order > lastSeen) {
        lastSeen = order;
      }
      final found = candidate(m, cutoff: cutoff);
      if (found == null) continue;
      final dk = found.deliveryKey;
      if (ignored.contains(dk) || queuedKeys.contains(dk)) {
        continue; // delivery_key dedup, stable across pagination/restart
      }
      final body = reportBody(m.content);
      final stripped = body
          .replaceAll(RegExp(r'\n*請讀取新到的排程報告並簡短回覆。\s*$'), '')
          .replaceAll(RegExp(r'\n*To stop or manage this job, send me a new '
              r'message \(e\.g\. "stop reminder [^"]+"\)\.?\s*$'), '')
          .trim();
      if (stripped.isEmpty || stripped == 'NO_REPLY' ||
          stripped == 'HEARTBEAT_OK') {
        ignored.add(dk); // ignored-CONSUMED: never re-evaluated
        continue;
      }
      queuedKeys.add(dk);
      queued.add({'id': found.messageId, 'dk': dk, 'order': found.order});
    }
    queued.sort(
      (a, b) => (a['order'] as num).compareTo(b['order'] as num),
    ); // ascending numeric order
    st['queued'] = queued;
    st['lastSeenOrder'] = lastSeen;
    st['ignoredKeys'] = ignored.toList()..sort();
    await _persist();
  }

  Set<String> _keySet(Map<String, dynamic> st, String field) => {
    for (final k in ((st[field]) as List?)?.cast<String>() ??
        const <String>[])
      k,
  };

  Map<String, dynamic> _freshArmed(List<Message> messages) {
    var cutoff = 0;
    for (final m in messages) {
      final n = int.tryParse(m.id);
      if (n != null && n > cutoff) cutoff = n;
    }
    return {
      'armedAt': _now().toIso8601String(),
      'cutoffOrder': cutoff,
      'lastSeenOrder': cutoff,
      'orderUncertain': false,
      'queued': <Map<String, dynamic>>[],
      'ignoredKeys': <String>[],
    };
  }

  /// Persist BEFORE any dispatch attempt (plan §2 rule 2): the queue is
  /// only dispatch-eligible once the write PROVED it survived. A refused
  /// write keeps the in-memory view but shuts the dispatch gate until a
  /// later commit succeeds again — never pretend the queue persisted.
  bool get queuePersisted => _persistedOk;

  Future<bool> _persist() async {
    final st = _state;
    if (st == null) return false;
    try {
      _persistedOk = await store.saveWakeState(serverUrl, sid, st);
    } on Object {
      _persistedOk = false;
    }
    return _persistedOk;
  }

  /// Compression / resolved-session move: delivery_key-keyed queue state
  /// rides along unchanged (row ids change with the copy — the plan
  /// forbids treating a new session id as "every report is new").
  Future<void> moveLineage() => _persist();

  /// Disable boundary: clear the unsent queue NOW so re-enabling builds a
  /// fresh cutoff and never replays the disabled window.
  Future<void> disarm() async {
    _state = null;
    _persistedOk = false;
    await store.clearWakeState(serverUrl, sid);
  }

  // ---- admitted batches (APPWAKE C): the client-side mirror of the
  // server ledger. The ledger decides consumption; these rows carry the
  // receipt (batch id + anchor) so display projection and turn recovery
  // survive restarts. State: dispatched -> accepted -> terminal/uncertain.

  /// Admit succeeded: fix the fingerprint + batch id BEFORE any POST,
  /// drop the queued entries, persist, and only THEN may dispatch start.
  Future<bool> recordBatch({
    required String batchId,
    required int anchorAfterId,
    required List<Map<String, dynamic>> items,
  }) async {
    final st = _state;
    if (st == null) return false;
    final batches = List<Map<String, dynamic>>.from(
      ((st['batches']) as List?)
              ?.map((e) => Map<String, dynamic>.from(e as Map)) ??
          const [],
    );
    if (batches.any((b) => b['batch_id'] == batchId)) return true;
    batches.add({
      'batch_id': batchId,
      'anchor_after_id': anchorAfterId,
      'canonical_input': AutoWakeContract.canonicalInput,
      'delivery_keys': [for (final i in items) i['dk']],
      'items': items,
      'state': 'dispatched',
      'at': _now().toIso8601String(),
    });
    final used = {for (final i in items) i['dk']};
    st['queued'] = [
      for (final q in ((st['queued']) as List?) ?? const [])
        if (!used.contains((q as Map)['dk'])) q,
    ];
    st['batches'] = batches;
    return _persist();
  }

  /// A PROVEN release (server freed the rows): drop the mirror row and
  /// hand the items back to the queue — the next admit may re-claim them.
  Future<void> abandonBatch(String batchId) async {
    final st = _state;
    if (st == null) return;
    final batches = ((st['batches']) as List?) ?? const [];
    Map<String, dynamic>? dropped;
    final kept = <Map<String, dynamic>>[];
    for (final b in batches) {
      final m = Map<String, dynamic>.from(b as Map);
      if (m['batch_id'] == batchId) {
        dropped = m;
      } else {
        kept.add(m);
      }
    }
    st['batches'] = kept;
    final back = ((dropped?['items']) as List?) ?? const [];
    final queued = List<Map<String, dynamic>>.from(
      ((st['queued']) as List?)
              ?.map((e) => Map<String, dynamic>.from(e as Map)) ??
          const [],
    );
    final have = {for (final q in queued) q['dk']};
    for (final i in back) {
      final m = Map<String, dynamic>.from(i as Map);
      if (!have.contains(m['dk'])) queued.add(m);
    }
    queued.sort(
      (a, b) => (a['order'] as num).compareTo(b['order'] as num),
    );
    st['queued'] = queued;
    await _persist();
  }

  Map<String, dynamic>? batch(String batchId) {
    final st = _state;
    if (st == null) return null;
    for (final b in ((st['batches']) as List?) ?? const []) {
      if ((b as Map)['batch_id'] == batchId) return Map<String, dynamic>.from(b);
    }
    return null;
  }

  /// One-way state advance (dispatched → accepted → terminal), persisted.
  Future<void> advanceBatch(String batchId, String state, {String? runId}) async {
    final st = _state;
    if (st == null) return;
    const rank = {'dispatched': 0, 'accepted': 1, 'terminal': 2};
    var touched = false;
    final batches = [
      for (final b in ((st['batches']) as List?) ?? const [])
        () {
          final m = Map<String, dynamic>.from(b as Map);
          if (m['batch_id'] == batchId &&
              (rank[m['state']] ?? 0) < (rank[state] ?? 0)) {
            m['state'] = state;
            if (runId != null) m['run_id'] = runId;
            touched = true;
          }
          return m;
        }(),
    ];
    if (!touched) return;
    st['batches'] = batches;
    await _persist();
  }

  /// A dispatch that never proved ANYTHING about the ledger (connection
  /// died before a verdict): honest "uncertain" — no anchor projection,
  /// no replay; the receipt GET (server truth) decides later.
  Future<void> markUncertain(String batchId) =>
      _setState(batchId, 'uncertain');

  Future<void> _setState(String batchId, String state) async {
    final st = _state;
    if (st == null) return;
    st['batches'] = [
      for (final b in ((st['batches']) as List?) ?? const [])
        if ((b as Map)['batch_id'] == batchId)
          {...b, 'state': state}
        else
          b,
    ];
    await _persist();
  }

  /// Batch plan (plan §5): after [debounce] of quiet, merge the CURRENT
  /// candidates into ONE request — at most [batchMax] in ascending numeric
  /// order; the remainder keeps its queue. Pure: never consumes anything;
  /// the server admission ledger is the only consumption record. A batch
  /// fingerprint, once fixed at admit time, is never edited afterwards.
  static DispatchPlan? plan(
    Map<String, dynamic>? state, {
    required DateTime now,
    Duration debounce = const Duration(seconds: 1),
    int batchMax = 10,
  }) {
    if (state == null) return null;
    if (state['orderUncertain'] == true) return null;
    final queued = ((state['queued']) as List?) ?? const [];
    if (queued.isEmpty) return null;
    final batch = List<Map<String, dynamic>>.from(queued)
      ..sort((a, b) => (a['order'] as num).compareTo(b['order'] as num));
    return DispatchPlan(
      batch.take(batchMax).toList(),
      overflow: batch.length > batchMax,
    );
  }

  /// The durable blob, for callers that render from it (UI hints).
  static Map<String, dynamic>? decoded(LocalStore store, String server, String sid) =>
      store.wakeState(server, sid);

  /// APPWAKE C: rows the UI projects as "auto-read schedule report"
  /// system lines. Identity = the server receipt (batch anchor watermark +
  /// the FIXED canonical sentence), never a content prefix on any human
  /// message. A batch whose run never anchored contributes nothing — an
  /// uncertain wake keeps its honest raw row, never a fake system line.
  Set<String> anchors(List<Message> rows) {
    final st = _state;
    if (st == null) return const {};
    final out = <String>{};
    for (final b in ((st['batches']) as List?) ?? const []) {
      final batch = b as Map;
      final anchor = (batch['anchor_after_id'] as num?)?.toInt();
      final batchState = batch['state'];
      final canonical = batch['canonical_input'];
      if (anchor == null ||
          canonical != AutoWakeContract.canonicalInput ||
          !const {'accepted', 'terminal'}.contains(batchState)) {
        continue;
      }
      for (final m in rows) {
        final id = int.tryParse(m.id);
        if (id != null && id > anchor && m.isUserTurn && m.content == canonical) {
          out.add(m.id);
          break; // the FIRST such row after the watermark is the anchor
        }
      }
    }
    return out;
  }
}

/// What [AutoWakeObserver.plan] hands to the (future) dispatch lane.
class DispatchPlan {
  const DispatchPlan(this.items, {this.overflow = false});
  final List<Map<String, dynamic>> items;
  final bool overflow;

  List<String> get deliveryKeys => [for (final i in items) i['dk'] as String];

  /// The wake user row lands AFTER every report of its batch; this is the
  /// watermark the receipt's anchor search starts from (max report order).
  int get anchorAfterId =>
      (items.fold<num?>(null, (hi, i) {
        final o = i['order'] as num;
        return hi == null || o > hi ? o : hi;
      })?.toInt()) ??
      0;
}

/// The fixed wake sentence (server-owned; identical for every locale,
/// device and install — it must NOT vary with UI language or clocks).
class AutoWakeContract {
  // i18n-exempt: cross-device protocol literal (server-owned wake sentence,
  // matched byte-exactly by the admission ledger) — I18N-PLAN §5 class.
  static const canonicalInput = '請讀取新到的排程報告並簡短回覆。';
}

