import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import '../../diagnostics/diagnostics.dart';
import '../../api/hermes_repository.dart';
import '../../api/transport.dart' show DispatchObservation, TransportStage;
import '../../l10n/app_strings.dart';
import '../../l10n/message_key.dart';
import '../../l10n/ui_message.dart';
import '../../models/message.dart';
import '../../models/session_activity.dart';
import '../../platform/connectivity_hint.dart';
import '../../platform/notification_surface.dart';
import '../../platform/store_tx.dart';
import '../settings/local_store.dart';
import 'dart:math' as math;
import 'auto_wake.dart';
import 'approval_inbox.dart';
import 'live_turn.dart';
import 'local_attempt.dart';
import 'remote_stop.dart';
import 'notification_inbox.dart';
import 'remote_steer.dart';
import 'run_link.dart';
import 'steer_inbox.dart';
import 'turn_history_match.dart';
import 'viewers.dart';

enum ChatPhase { idle, sending, recovering, uncertain }

/// SILENCE-DROP §3.1: WHY recovery started decides its wording. Only the
/// live POST stream may claim an observed failure (streamEnded/streamError);
/// neutral callers (silence/recheck) must never say "connection lost" —
/// the client observed silence, not a drop.
enum RecoveryCause { silence, streamEnded, streamError, recheck }

/// Provenance of the stop-notice banner (I18N-PLAN §4.4). The stored JSON
/// stop record keeps its exact schema; this enum replaces the old
/// "does it start with '{'" display heuristic, and [stopNoticeMessage] is a
/// descriptor resolved at render time — never a stored translation.
enum StopNotice {
  none,

  /// A persisted record adopted at construction (before this session's
  /// actions): the page shows the generic "you asked to stop" banner.
  previousStopRecord,

  /// Stop POST issued, server confirmation outstanding.
  requested,

  /// Terminal reached and the stop was the user's own hand.
  accepted,

  /// The run ended by itself (server-side cancel).
  serverEnded,

  /// A connection drop may have left the previous turn unfinished.
  lost,

  /// The gateway forgot the run; history was reconciled instead.
  notFound,

  /// The stop request itself failed; the error rides as a nested arg.
  failed,
}

/// Projection row for a remote observation (I18N-PLAN §4.4): the raw
/// observed Message plus a SEPARATE hint kind. The localized note never
/// enters durable Message content, so fold, fingerprint, copied payload,
/// draft and POST bytes stay locale-independent.
enum RemoteHint { none, unconfirmed, truncated }

class RemoteMessageRow {
  const RemoteMessageRow(this.message, [this.hint = RemoteHint.none]);
  final Message message;
  final RemoteHint hint;
}

/// OFFLINE-SEND R2 §4.2/§4.3: WHY a turn settled. serverTerminal and
/// rejected keep the exact pre-R2 settlement behavior (M025 cleanup wording
/// included); localAbandonment is the LOCAL end — same scheduler/stream/
/// lease teardown, but the pending record is cleared only through the
/// journal-first endLocalAttempt ordering, no stop record is written, no
/// history row is touched, and no auto-wake ack/schedule may fire.
enum SettlementReason { serverTerminal, rejected, localAbandonment }

/// The per-attempt outcome of the most recent human send (R2 §4.3): the
/// composer must decide attachment clearing / draft restore from THIS
/// attempt's outcome, never from the shared `error` slot (A6).
enum SendOutcome { accepted, rejected, localSettled, lostOwnership, stale }

/// OFFLINE-SEND R3 §5.3: the ONE derived presentation state for the current
/// page's attempt. Sourced ONLY from structured evidence (journal
/// delivery/terminalEvidence plus this session's in-memory mirror) — never
/// from exception strings, never from navigator.onLine at render time.
/// CP/LiveTurnView must consume this and nothing else.
enum AttemptDeliveryView {
  /// Structured before-dispatch evidence proves the underlying call never
  /// ran: the honest "not sent" card; the ONLY state with a retry affordance.
  notDispatched,

  /// THIS live send persisted dispatchIntent and has no ack yet — the
  /// neutral "Sending message…" row (never "typing").
  dispatching,

  /// Dispatch was intended/invoked (or the record is legacy/incomplete)
  /// without stronger evidence: re-check / end waiting / restore only.
  outcomeUnknown,

  /// Contract SSE business ack or a run identity for THIS attempt.
  acknowledged,

  /// The server answered this human chat POST with a contract 4xx.
  rejected,
}

/// OFFLINE-SEND R3 §5.3: the ONE busy-state presentation CP and
/// LiveTurnView share — derived in the controller ONLY (both widgets read
/// this and nothing else, so they can no longer disagree). Wording/animation
/// rules: `dispatching` says「正在送出訊息…」with no typing dots (never
/// 發言中); `activeConfirmed` keeps the existing 發言中/waiting UI;
/// `countdown` shows the persisted recovery countdown, no dots; `silent`
/// (uncertain / evidence-less) shows and animates nothing.
enum LivePresentation { dispatching, countdown, activeConfirmed, silent }

/// OFFLINE-SEND R2 §4.3: what `stop()` did.
enum StopResultKind {
  /// A run exists and the server stop request landed (200/409) or the run
  /// was already gone (404 — [StopResult.serverDisposition] `alreadyGone`,
  /// M031 wording; never "killed by this request").
  serverStopRequested,

  /// No run: this page's human attempt ended locally through the journal-
  /// first tombstone (§4.2). Zero POSTs. restoreDraft carries the snapshot.
  localWaitingEnded,

  /// Nothing to stop (M029) — no run and no local attempt record.
  noTurn,

  /// A write / compare / stop-request failed. The user's input is untouched.
  failure,

  /// CROSSDEV-STOP R2 §5.1: the local paths found no target and MORE THAN
  /// ONE activity row (or overflow) exists: the UI must open a chooser —
  /// NOTHING has been picked and NOTHING has been sent (cancel = zero side
  /// effects). The exact 1-observable-row case never lands here; it runs
  /// [stopRemote] inline and reports [StopResultKind.remoteResult].
  remoteChoice,

  /// CROSSDEV-STOP R2 §5.1/§5.3: a remote flight ran for the unique target;
  /// [StopResult.remote] carries its typed outcome. It NEVER pairs with
  /// restoreDraft/localWaitingEnded and NEVER writes a StopRecord.
  remoteResult,
}

class StopResult {
  const StopResult(
    this.kind, {
    this.attemptId,
    this.restoreDraft,
    this.restoreRevision,
    this.serverDisposition,
    this.cleanup,
    this.message,
    this.remote,
  });
  final StopResultKind kind;

  /// True ONLY for a request that landed (server) or a local end whose
  /// tombstone persisted. Disposed/stale continuations never report success.
  /// CROSSDEV-STOP R2 §5.3: an accepted remote outcome (200-requested or
  /// 409-checking, incl. a terminal confirmed while checking) is "landed"
  /// for COMMAND-consumption purposes and nothing else — it never restores
  /// or clears a draft (restoreDraft stays null by construction).
  bool get success =>
      kind == StopResultKind.serverStopRequested ||
      kind == StopResultKind.localWaitingEnded ||
      (kind == StopResultKind.remoteResult &&
          remote != null &&
          (remote!.requestedOrChecking ||
              remote!.kind == RemoteStopKind.ended ||
              remote!.kind == RemoteStopKind.alreadyGone));

  final String? attemptId;

  /// The preserved raw draft from the abandoned journal snapshot (§4.2
  /// step 2) — verbatim, never trimmed.
  final String? restoreDraft;

  /// The editor revision the snapshot was taken at (restore CAS key).
  final int? restoreRevision;

  /// 'requested' | 'alreadyGone' (server kinds only).
  final String? serverDisposition;

  /// 'done' | 'pending' — 'pending' means the tombstone persisted but the
  /// shared pending delete did not (evidence preserved, cleanup retryable).
  final String? cleanup;

  /// CROSSDEV-STOP R2 §5.2: the typed remote disposition, set for
  /// [StopResultKind.remoteResult] ONLY. Never a local settle in disguise.
  final RemoteStopOutcome? remote;

  final UiMessage? message;
}

class ChatController extends ChangeNotifier with WidgetsBindingObserver {
  ChatController(
    this.repo,
    this.store,
    this.sid, {
    Future<void> Function(Duration)? wait,
    String? serverUrl,
    this.watchInterval = const Duration(seconds: 5),
    this.leaseInterval = const Duration(seconds: 15),
    DateTime Function()? now,
    ConnectivityHint Function()? connectivity,
    StoreTxCapability Function()? txCapability,
  }) : wait = wait ?? ((duration) => Future<void>.delayed(duration)),
       serverUrl = serverUrl ?? repo.baseUrl,
       _now = now ?? DateTime.now,
       _connectivity = connectivity ?? currentConnectivityHint,
       _txCapability = txCapability ?? (() => storeTxCapability),
       detailed = store.detailed(serverUrl ?? repo.baseUrl, sid) {
    // A persisted stop record from BEFORE this session shows the generic
    // provenance banner; its JSON schema and contents are data, untouched.
    if (store.stopRecord(serverUrl ?? repo.baseUrl, sid) != null) {
      stopNoticeKind = StopNotice.previousStopRecord;
    }
    WidgetsBinding.instance.addObserver(this);
    // AUDIT-16: join the alive ledger the idle-LRU eviction pass reads.
    ChatViewers.register(sid, this);
    backgrounded =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.hidden;
  }
  final Future<void> Function(Duration) wait;

  /// STUCK-BUSY B3: one injectable clock for every recovery deadline
  /// (deterministic tests never wait real 60s).
  final DateTime Function() _now;
  DateTime _clock() => _now();

  /// R3 §5.2: injectable connectivity HINT seam (default: the platform
  /// function). A hint may only gate whether THIS send is invoked at all —
  /// it is never read at render time and never negates a past dispatch.
  final ConnectivityHint Function() _connectivity;

  /// R3 §5.3: Web-Locks capability seam. Without resolved locks the retry
  /// affordance is DISABLED and the page shows `chatCrossTabSafetyReduced`
  /// (already rendered by CP) — never a pretend-safe cross-tab retry.
  final StoreTxCapability Function() _txCapability;
  final HermesRepository repo;
  final LocalStore store;
  final String sid, serverUrl;

  /// AUDIT-21 (D2): lease heartbeat cadence — well inside the store's
  /// pendingLease so a live owner never loses its claim to a takeover.
  final Duration leaseInterval;

  /// Server emits `: keepalive` frames on idle chat streams, so silence longer
  /// than this means the socket is wedged rather than the run being slow.
  static const silenceLimit = Duration(seconds: 75);

  /// SILENCE-DROP §3.1: a purely UX choice (independent of the server
  /// keepalive cadence). Once a live send shows no BUSINESS output for this
  /// long, a neutral "waiting" notice appears — heartbeats keep the run alive
  /// but never count as output, so a long tool/think reads as "waiting", not
  /// an error. Never gates recovery; 75s still does.
  static const noOutputNoticeLimit = Duration(seconds: 30);

  List<Message> messages = [];
  bool detailed, loading = false, loadingOlder = false, hasOlder = true;
  bool _disposed = false;
  bool backgrounded = false;

  // ---- two-layer identity (AUDIT-11/12) -----------------------------------
  // `_turnToken` is the immutable TURN identity: minted when a send is
  // accepted or when bootstrap adopts a persisted pending record, retired
  // exactly once by the settlement gate (or dispose). A late continuation
  // from an old turn fails `identical(_turnToken, mine)` and must no-op —
  // it can never write pending, messages, streams, timers or busy.
  // `_recoveryEpoch` stays the OBSERVER revision: mode switches (detach,
  // recover, foreground) invalidate in-flight observation work within the
  // SAME turn without pretending a new turn began.
  int _recoveryEpoch = 0;
  Object? _turnToken;
  Object? _settledTurn; // the turn the settlement gate is/was closing
  Future<bool>? _settleGate;
  Future<void>? _recovery;
  Future<void>? _foregroundCheck;
  Future<bool>? _reconcileFlight; // single-flight GET across ALL observers

  // ---- APPWAKE: shadow detection + durable queue (dispatch lands later) --
  // The observer is pure state + persistence: it never touches turns, and
  // the controller only feeds it SUCCESSFUL history commits.
  AutoWakeObserver? _wake;

  /// APPWAKE: message ids this client recognizes as its OWN server-
  /// confirmed auto-wake anchors — the timeline renders them as system
  /// lines. Durable rows are untouched (user anchor preserved).
  Set<String> get wakeRowIds => _wake?.anchors(messages) ?? const {};

  /// chat_page's live editor signal (focus / IME composition / text).
  /// Auto-dispatch is stricter than manual send: ANY editing pauses it;
  /// putting the editor down hands the queue its debounced chance.
  void noteInputActive(bool active) {
    if (_inputActive == active) return;
    _inputActive = active;
    if (!active &&
        !busy &&
        ((_wake?.state?['queued']) as List?)?.isNotEmpty == true) {
      _wakeSchedule();
    }
  }

  bool _inputActive = false;
  bool get inputActive => _inputActive;

  /// Pending (discovered, not yet admitted) report count for the UI hint.
  int get wakePendingCount => _wake?.pendingCount ?? 0;

  AutoWakeObserver _wakeObserver() => _wake ??= AutoWakeObserver(
    store: store,
    serverUrl: serverUrl,
    sid: sid,
    now: _clock,
  );

  // ---- APPWAKE C dispatch state (plan §4/§5) ------------------------------
  Json? _wakeCap; // null = not fetched / fetch failed; {} = no auto-wake
  Timer? _wakeDebounce;
  bool _wakeDispatching = false,
      _wakeQuotaHit = false,
      _wakePostHappened = false;
  String? _wakeBatchInFlight; // ledger batch of the CURRENT auto-wake turn

  /// Every trigger goes through the SAME debounce (1s = plan §5's merge
  /// window; busy/quota use a longer one): repeated triggers never stack.
  /// Consecutive no-progress failures (transport death, verdict release,
  /// never-started POST): stretch the retry gap geometrically to a minute.
  /// A healthy admit resets it — a dead-end ledger path can never churn.
  int _wakeFailStreak = 0;
  bool get _wakeSettingsOn =>
      store.autoWakeEnabled(serverUrl) &&
      !store.autoWakeSessionOff(serverUrl, sid);

  void _wakeSchedule([int seconds = 1]) {
    if (_disposed || !_wakeSettingsOn) return; // OFF = no timers, no traffic
    _wakeDebounce?.cancel();
    const ladder = [2, 5, 15, 30, 60];
    final floor = _wakeFailStreak == 0
        ? 1
        : ladder[_wakeFailStreak > ladder.length
              ? ladder.length - 1
              : _wakeFailStreak - 1];
    _wakeDebounce = Timer(
      Duration(seconds: seconds > floor ? seconds : floor),
      () {
        if (!_disposed) unawaited(_wakeDispatch());
      },
    );
  }

  Future<Json?> _wakeCapOnce() async {
    final cached = _wakeCap;
    if (cached != null) return cached;
    try {
      final feats = (await repo.autoWakeCapability())['features'];
      final wake = feats is Map ? feats['auto_wake'] : null;
      // {} = confirmed ABSENT (pure server): cached, never refetched.
      _wakeCap = wake is Map ? Map<String, dynamic>.from(wake) : const {};
    } on Object {
      // Transient failure: NOT cached — the next trigger re-asks.
    }
    return _wakeCap;
  }

  void _wakeRunStarted(String? runId) {
    final batchId = _wakeBatchInFlight;
    if (batchId == null || runId == null) return;
    unawaited(() async {
      try {
        await repo.wakeAck(sid, batchId, 'accepted', runId: runId);
      } on Object {
        // receipt lag is harmless: the batch is a server-side run now
      }
      await _wake?.advanceBatch(batchId, 'accepted');
    }());
  }

  Future<void> _wakeTerminalAck(String batchId) async {
    try {
      await repo.wakeAck(sid, batchId, 'terminal');
    } on Object {
      // the terminal may never reach the ledger; the receipt GET decides
    }
    await _wake?.advanceBatch(batchId, 'terminal');
    notifyListeners(); // the "auto-read" projection may appear now
  }

  /// 409/410 from the dispatch POST: the LEDGER already knows this batch.
  /// Read-only recovery ONLY — history reconcile + receipt GET, NEVER a
  /// second POST of the same sentence (plan §4, ghost-dup red line).
  Future<void> _wakeGateVerdict(
    String batchId,
    int status,
    Object? token,
  ) async {
    String? read;
    try {
      final r = await repo.wakeReceipt(sid, batchId);
      final s = r['state'];
      read = s is String ? s : null;
    } on Object {
      // receipt unreadable: fall back to committed-history proof below
    }
    if (_disposed || !identical(_turnToken, token)) return;
    // A committed canonical row AFTER the batch watermark proves acceptance
    // with server data — no guessing from the local clock.
    var anchored = false;
    final anchor = (_wake?.batch(batchId)?['anchor_after_id'] as num?)?.toInt();
    if (anchor != null) {
      for (final m in messages) {
        final n = int.tryParse(m.id);
        if (n != null &&
            n > anchor &&
            m.isUserTurn &&
            m.content == AutoWakeContract.canonicalInput) {
          anchored = true;
          break;
        }
      }
    }
    final wake = _wake;
    if (status == 410) {
      _wakeFailStreak++; // released rows may re-claim, but never churn
      if (read == 'released' && wake != null) {
        await wake.abandonBatch(batchId); // rows return to the queue
      } else {
        await wake?.advanceBatch(batchId, 'terminal');
      }
    } else if (anchored || read == 'dispatching' || read == 'accepted') {
      await wake?.advanceBatch(batchId, 'accepted');
      unawaited(reconcileForeground()); // the run is real: observe it read-only
    } else {
      if (wake != null) await wake.markUncertain(batchId);
      // NO anchor, NO running run: honest dead-end. No auto re-send — the
      // reports stay unconsumed server-side and the queue keeps them for a
      // later admitted batch (never a duplicate of THIS batch).
    }
    if (identical(_wakeBatchInFlight, batchId)) _wakeBatchInFlight = null;
    await _settleTurn(token); // the never-proven turn retires through the gate
    if (!_disposed) _wakeSchedule();
  }

  Future<void> _wakeDispatch() async {
    if (_disposed || _wakeDispatching) return;
    if (!store.autoWakeEnabled(serverUrl) ||
        store.autoWakeSessionOff(serverUrl, sid)) {
      return;
    }
    if (sendBlocked || _bootstrapping || busy || _detached || _inputActive) {
      return; // gated — event triggers (settle/resume/attach/typing) reschedule
    }
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
        ChatViewers.count(sid) == 0) {
      return; // hidden page / no viewer: never auto-send (plan §4)
    }
    final wake = _wakeObserver();
    if (!wake.queuePersisted) return; // queue must be PROVEN on disk
    final cap = await _wakeCapOnce();
    if (_disposed || cap == null || cap['enabled'] != true) return;
    if (cap['canonical_input'] != AutoWakeContract.canonicalInput) return;
    // A different server sentence = a different contract version: stay
    // silent rather than fire a sentence the ledger can't match.
    final plan = AutoWakeObserver.plan(wake.state, now: _clock());
    if (plan == null) return;
    _wakeDispatching = true;
    _wakePostHappened = false;
    String? batchId;
    var turnStarted = false, backoffScheduled = false;
    try {
      Json admitted;
      try {
        admitted = await repo.wakeAdmit(sid, plan.deliveryKeys);
      } on Object {
        _wakeSchedule(5); // transport/5xx: queue intact, ask again later
        return;
      }
      if (_disposed) return;
      final status = admitted['status'];
      if (status == 'quota_exceeded' || status == 'busy') {
        _wakeQuotaHit = status == 'quota_exceeded';
        notifyListeners(); // UI hint may show the quota state now
        final retry = (admitted['retry_after_s'] as num?)?.toInt();
        backoffScheduled = true;
        _wakeSchedule(status == 'busy' ? (retry ?? 5) : (retry ?? 60));
        return;
      }
      if (status != 'admitted') return; // empty/error: nothing to do

      batchId = admitted['batch_id'] as String?;
      if (batchId == null) return;
      _wakeQuotaHit = false;
      final anchor =
          (admitted['anchor_after_id'] as num?)?.toInt() ?? plan.anchorAfterId;
      // PERSIST the receipt + queue shrink BEFORE the POST: a crash now
      // leaves an admitted batch the ledger already counts — never a
      // silently-lost queue that re-fires double later.
      if (!await wake.recordBatch(
        batchId: batchId,
        anchorAfterId: anchor,
        items: plan.items,
      )) {
        try {
          await repo.wakeRelease(sid, batchId);
        } on Object {
          await wake.markUncertain(batchId);
        }
        return; // never dispatch a queue the disk refused to hold
      }
      if (_disposed) return;
      // GATE RE-CHECK at the POST edge: the user typed, sent, hid or left
      // during the admits/awaits — manual input ALWAYS wins (plan §4).
      if (sendBlocked ||
          busy ||
          _detached ||
          _inputActive ||
          ChatViewers.count(sid) == 0 ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        var freed = false;
        try {
          freed = (await repo.wakeRelease(sid, batchId))['status'] == 'ok';
        } on Object {
          freed = false;
        }
        if (freed) {
          await wake.abandonBatch(batchId); // rows return to the queue
        } else {
          await wake.markUncertain(batchId); // ledger decides; never re-fire
        }
        _wakeFailStreak++;
        backoffScheduled = true;
        _wakeSchedule(5);
        return;
      }
      _wakeFailStreak = 0; // the ledger proved this batch is real
      _wakeBatchInFlight = batchId; // set BEFORE the await: a crash now lands
      // on a bootstrap-adoptable wake turn, never an orphan ledger row
      await send(
        AutoWakeContract.canonicalInput,
        wakeBatch: batchId,
        suppressPending: true,
      );
      turnStarted = busy || _wakePostHappened; // POST reached the server?
    } finally {
      _wakeDispatching = false;
      if (batchId != null && !turnStarted) {
        if (identical(_wakeBatchInFlight, batchId)) _wakeBatchInFlight = null;
        // The POST never reached the server: hand the reservation back.
        // A CONFLICT here means a racing ledger state already moved the
        // batch — that's the ledger deciding; the rows stay consumed and
        // a re-admit of the same keys is deduped. NEVER re-POST blindly.
        var freed = false;
        try {
          freed = (await repo.wakeRelease(sid, batchId))['status'] == 'ok';
        } on Object {
          freed = false;
        }
        if (freed) {
          await wake.abandonBatch(batchId);
        } else if (wake.batch(batchId)?['state'] == 'dispatched') {
          await wake.markUncertain(batchId);
        }
        _wakeFailStreak++;
      }
      if (!_disposed &&
          !backoffScheduled &&
          ((wake.state?['queued']) as List?)?.isNotEmpty == true) {
        _wakeSchedule(); // overflow beyond the cap: next batch, debounced
      }
    }
  }

  /// Whether the last dispatch attempt hit the hourly quota (UI hint).
  bool get wakeQuotaHit => _wakeQuotaHit;

  /// The server offers auto-wake (fetched lazily; false until known).
  bool get wakeFeatureOffered => _wakeCap?['enabled'] == true;

  /// AUDIT-09: no send may enter before bootstrap has decided whether a
  /// persisted pending turn owns this session.
  bool _bootstrapping = false;

  /// WAVE4: what a visible page may SHOW as "in progress" — our own turn,
  /// or a remote run the activity snapshot has confirmed.
  bool get displayBusy => busy || remoteBusy;

  /// Remote (not this page's) runs the latest snapshot proves active.
  List<ActivityRun> get remoteActiveRuns => observedActivity == null
      ? const []
      : remoteActive(observedActivity!.activeRuns, activeRunId);
  bool get remoteBusy => remoteActiveRuns.isNotEmpty;

  // ---- CROSSDEV-STOP R1: remote stop evidence (plan §3) -------------------
  // Completely INDEPENDENT of activeRunId / canStop / canEndLocalWaiting /
  // sendBlocked — those keep their exact local meanings. Candidates exist
  // only while the snapshot itself is trustworthy RIGHT NOW (age recomputed
  // at every read), never from previews, text or time-window guesses.

  /// Age-checked freshness recomputed at READ time. The `fresh` enum alone
  /// never expires on its own, so STOP decisions never trust it bare. (No
  /// other consumer changes: the send gate keeps reading `activityFreshness`
  /// exactly as before — this getter can only be STRICTER.)
  bool get activityEvidenceFreshNow {
    if (_disposed || activityFreshness != ActivityFreshness.fresh) return false;
    final seen = lastActivitySuccess;
    if (seen == null || observedActivity == null) return false;
    return _clock().difference(seen) <= syncInterval;
  }

  RemoteRunKind _classifySnapshotRun(
    SessionActivity snap,
    ActivityRun r,
    DateTime now,
  ) => classifyRemoteRun(
    r,
    now: now,
    lastActivitySuccess: lastActivitySuccess,
    syncInterval: syncInterval,
    requestedSessionId: sid,
    snapshotSessionId: snap.sessionId,
    resolvedSessionId: snap.resolvedSessionId,
    epoch: snap.serverEpoch,
    isLocallyRepresented: isLocallyRepresentedRun(r),
  );

  /// Stoppable remote runs of the LAST snapshot, while freshness passes NOW.
  /// `stopping` entries are NOT targets (§3.3: 「正在停止」 reconciles, it
  /// never re-POSTs) — see [remoteStoppingRunIds]. Overflow does not
  /// invalidate the individually valid rows — [remoteCandidatesOverflowed]
  /// tells the UI it may not generalize from them (§5.1).
  List<RemoteStopTarget> get remoteStopCandidates {
    final snap = observedActivity;
    if (snap == null || !activityEvidenceFreshNow) return const [];
    final now = _clock();
    final gen = connectionGeneration;
    return [
      for (final r in snap.activeRuns)
        if (_classifySnapshotRun(snap, r, now) == RemoteRunKind.stoppable)
          RemoteStopTarget(
            connectionGeneration: gen,
            accountGeneration: gen, // one repo = one key: no separate rotation
            requestedSessionId: sid,
            resolvedSessionId: snap.resolvedSessionId,
            serverEpoch: snap.serverEpoch, // opaque — kept verbatim
            observationId: r.observationId,
            runId: r.runId!,
          ),
    ];
  }

  /// Any stoppable candidate exists RIGHT NOW.
  bool get canRequestRemoteStop => remoteStopCandidates.isNotEmpty;

  /// CROSSDEV-STOP R2: the CURRENT candidate for one run id (row-action
  /// wiring): a stale/changed row yields null, never a stale target.
  RemoteStopTarget? remoteTargetForRun(String runId) {
    for (final t in remoteStopCandidates) {
      if (t.runId == runId) return t;
    }
    return null;
  }

  /// Run ids of remote entries already `stopping`: display/核对 only — the
  /// reconciliation ride-along, never a new POST (§3.3).
  List<String> get remoteStoppingRunIds {
    final snap = observedActivity;
    if (snap == null || !activityEvidenceFreshNow) return const [];
    final now = _clock();
    return [
      for (final r in snap.activeRuns)
        if (_classifySnapshotRun(snap, r, now) == RemoteRunKind.stopping)
          r.runId!,
    ];
  }

  /// The fresh snapshot says MORE runs may exist beyond the listed rows:
  /// individually valid rows stay individually actionable, but the page may
  /// never conclude "this is everything" (and may not auto-pick one).
  bool get remoteCandidatesOverflowed =>
      activityEvidenceFreshNow && (observedActivity?.overflow ?? false);

  /// The honest reason there is no target right now (typed for the UI).
  RemoteStopBlock get remoteBlockReason {
    if (_disposed) return RemoteStopBlock.unknownState;
    if (canRequestRemoteStop) return RemoteStopBlock.none;
    if (activityFreshness == ActivityFreshness.unsupported) {
      return RemoteStopBlock.unsupported;
    }
    if (activityFreshness == ActivityFreshness.unknown) {
      return RemoteStopBlock.unknownState;
    }
    final snap = observedActivity;
    if (snap == null || lastActivitySuccess == null) {
      return RemoteStopBlock.noSnapshot;
    }
    if (!activityEvidenceFreshNow) return RemoteStopBlock.stale;
    return RemoteStopBlock.noStoppableTarget;
  }

  /// Connection rotation identity (URL / API key) every target carries.
  int get connectionGeneration => _currentConnectionGeneration();

  // ---- CROSSDEV-STOP R2: scoped remote stop (plan §5.1/§5.2) --------------
  // Memory-only observer: NO persistence, NO pending/attempt/StopRecord, NO
  // wake ack/schedule, NEVER _settleCore/_settleTurn/_settleStoppedRun. The
  // flights are single-flight keyed by the FULL target identity and totally
  // independent of _stopFlight/_turnToken/_owns — a remote action never
  // touches busy, phase, pending or the local turn machinery.

  /// Hard total bound of one reconciliation, counted from the observer start
  /// on [_clock()]; never extended (§5.2).
  static const remoteStopWindow = Duration(seconds: 60);

  /// Bumped by every new observer and by [cancelRemoteStopObserver]: late
  /// continuations compare it and drop on the floor (abortable observer).
  int _remoteStopGen = 0;
  RemoteStopPhaseState _remoteStopPhase = RemoteStopPhaseState.none;
  RemoteStopPhaseState get remoteStopPhaseState =>
      _disposed ? RemoteStopPhaseState.none : _remoteStopPhase;
  UiMessage? _remoteStopFeedback;

  /// Typed UI wording for the latest remote-stop development (never red:
  /// 409/unavailable/unconfirmed are reconciliation states, not faults —
  /// chat_page renders this in the secondary tone).
  UiMessage? get remoteStopFeedback => _remoteStopFeedback;

  /// True while a remote flight/observer owns affordances (repeat-send ban:
  /// the UI must not offer a second POST while this one is in flight).
  bool get remoteStopInFlight =>
      _remoteStopPhase == RemoteStopPhaseState.preflighting ||
      _remoteStopPhase == RemoteStopPhaseState.checking ||
      _remoteStopPhase == RemoteStopPhaseState.confirming;

  RemoteStopTarget? _remoteStopObserved;
  Timer? _remoteStopTimer; // read-only runStatus poll (watchInterval cadence)
  DateTime? _remoteStopStartedAt;
  bool _remoteStopTickBusy = false;
  final _remoteStopFlights = <String, Future<RemoteStopOutcome>>{};

  /// Chooser rows for the CURRENT snapshot (§5.1): every active row shows,
  /// candidates carry their target, everything else shows a readable block
  /// reason. Preview text never identifies a row.
  List<RemoteStopRow> get remoteStopChooserRows {
    final snap = observedActivity;
    if (snap == null) return const [];
    return buildRemoteStopRows(
      entries: snap.activeRuns,
      candidates: remoteStopCandidates,
      now: _clock(),
      lastActivitySuccess: lastActivitySuccess,
      syncInterval: syncInterval,
      requestedSessionId: sid,
      snapshotSessionId: snap.sessionId,
      resolvedSessionId: snap.resolvedSessionId,
      epoch: snap.serverEpoch,
      isLocallyRepresented: isLocallyRepresentedRun,
    );
  }

  /// The honest DISABLED reason for the remote affordance while rows are on
  /// screen but nothing is stoppable right now: stale/unknown/unsupported
  /// evidence asks for a refresh; a null/blank-id row says the server
  /// provided no run id; an all-stopping session is already reconciling.
  MessageKey? get remoteDisabledReason {
    if (_disposed || canRequestRemoteStop) return null;
    if (!remoteBusy && !remoteCandidatesOverflowed) return null;
    switch (remoteBlockReason) {
      case RemoteStopBlock.none:
        return null;
      case RemoteStopBlock.noStoppableTarget:
        final snap = observedActivity;
        if (snap != null &&
            snap.activeRuns.any(
              (r) => r.runId == null || r.runId!.trim().isEmpty,
            )) {
          return MessageKey.chatStopRemoteNoRunId;
        }
        if (snap != null && remoteStoppingRunIds.isNotEmpty) {
          return MessageKey.chatStopRemoteChecking;
        }
        return MessageKey.chatStopRemoteRefreshRequired;
      case RemoteStopBlock.noSnapshot:
      case RemoteStopBlock.unsupported:
      case RemoteStopBlock.unknownState:
      case RemoteStopBlock.stale:
        return MessageKey.chatStopRemoteRefreshRequired;
    }
  }

  void _setRemoteStop(
    RemoteStopPhaseState phase, {
    UiMessage? feedback,
    bool clearFeedback = false,
  }) {
    if (_disposed) return;
    _remoteStopPhase = phase;
    if (clearFeedback) {
      _remoteStopFeedback = null;
    } else if (feedback != null) {
      _remoteStopFeedback = feedback;
    }
    notifyListeners();
  }

  /// ABORT the read-only observer (UI may end its waiting any time): the
  /// generation bump rejects every late completion; zero other side effects.
  void cancelRemoteStopObserver() {
    if (_disposed) return;
    _remoteStopGen++;
    _remoteStopTimer?.cancel();
    _remoteStopTimer = null;
    _remoteStopObserved = null;
    _remoteStopStartedAt = null;
    _setRemoteStop(RemoteStopPhaseState.none, clearFeedback: true);
  }

  /// Single-flight keyed by the FULL target identity (§5.1): identical
  /// repeat taps JOIN the same future — never a second POST.
  Future<RemoteStopOutcome> stopRemote(RemoteStopTarget target) {
    if (_disposed) {
      return Future.value(const RemoteStopOutcome(RemoteStopKind.failed));
    }
    if (!target.isValid) {
      // Incomplete identity is never targeted and never POSTed (V02).
      final msg = const UiMessage.local(MessageKey.chatStopRemoteNoRunId);
      _setRemoteStop(RemoteStopPhaseState.none, feedback: msg);
      return Future.value(
        RemoteStopOutcome(RemoteStopKind.failed, message: msg),
      );
    }
    final key = [
      target.connectionGeneration,
      target.accountGeneration,
      target.requestedSessionId,
      target.resolvedSessionId,
      target.serverEpoch,
      target.observationId,
      target.runId,
    ].join('|');
    final inflight = _remoteStopFlights[key];
    if (inflight != null) return inflight;
    final flight = _stopRemoteCore(target);
    _remoteStopFlights[key] = flight;
    unawaited(
      flight.whenComplete(() {
        if (identical(_remoteStopFlights[key], flight)) {
          _remoteStopFlights.remove(key);
        }
      }),
    );
    return flight;
  }

  Future<RemoteStopOutcome> _stopRemoteCore(RemoteStopTarget target) async {
    if (_disposed) return const RemoteStopOutcome(RemoteStopKind.failed);
    // Connection world moved before this flight even started: the target
    // belongs to another scope — no evidence, no POST, no retarget.
    if (connectionGeneration != target.connectionGeneration) {
      return _remoteOutcome(RemoteStopKind.targetChanged);
    }
    _setRemoteStop(RemoteStopPhaseState.preflighting);
    // (a) evidence gathered AFTER this click only — a pre-click flight's
    // answer is never laundered into this attempt (§4 bullet 3).
    final refresh = await refreshActivityForStopCheck();
    if (_disposed) return const RemoteStopOutcome(RemoteStopKind.failed);
    if (!refresh.ok) {
      // A NEW request failed: typed preflight failure, NO POST (§5.1).
      final out = RemoteStopOutcome(
        RemoteStopKind.preflightFailed,
        message: remoteStopMessage(RemoteStopKind.preflightFailed),
        error: refresh.error,
      );
      _setRemoteStop(RemoteStopPhaseState.none, feedback: out.message);
      return out;
    }
    if (connectionGeneration != target.connectionGeneration) {
      return _remoteOutcome(RemoteStopKind.targetChanged);
    }
    // (b) the SAME tuple must STILL classify stoppable — anything that moved
    // ends the attempt; never silently aim at another run (§3 rule 4).
    final sameTuple = remoteStopCandidates.any((t) => t.sameIdentityAs(target));
    if (!sameTuple) {
      final classified = await _remoteTargetMoved(target);
      return classified;
    }
    // (c) evidence valid → POST immediately; NO unrelated await sits between
    // the re-check and the POST (§5.1). Bounded by repo.metadataTimeout.
    _setRemoteStop(RemoteStopPhaseState.checking, clearFeedback: true);
    late final RemoteStopOutcome outcome;
    try {
      await repo.stopWithDeadline(target.runId);
      outcome = const RemoteStopOutcome(RemoteStopKind.requested);
    } on ApiException catch (e) {
      if (e.status == 409) {
        // run_not_active is NOT a red error and NOT a confirmed stop:
        // reconcile only (§5.2 row 2).
        outcome = const RemoteStopOutcome(RemoteStopKind.checkingConflict);
      } else if (e.status == 404) {
        outcome = const RemoteStopOutcome(RemoteStopKind.alreadyGone);
      } else {
        // 401/403 and every other HTTP answer: an honest failure — visible
        // id ≠ stoppable (§7 V16). Generic stop-failure key, error arg kept.
        outcome = RemoteStopOutcome(
          RemoteStopKind.failed,
          message: UiMessage.local(
            MessageKey.chatStateM032,
            args: {'error': messageForError(e)},
          ),
          error: e,
        );
      }
    } on Object {
      // Timeout / network / parse: the request result is UNKNOWN — never an
      // automatic re-POST; read-only reconciliation decides (§5.2).
      outcome = const RemoteStopOutcome(RemoteStopKind.unconfirmed);
    }
    final wording = outcome.kind == RemoteStopKind.failed
        ? outcome.message
        : remoteStopMessage(outcome.kind);
    if (_disposed) {
      // This controller no longer exists to track the answer: the request
      // result is UNKNOWN to it — never a reported success (§5.1).
      return const RemoteStopOutcome(
        RemoteStopKind.unconfirmed,
        message: UiMessage.local(MessageKey.chatStopRemoteUnconfirmed),
      );
    }
    if (connectionGeneration != target.connectionGeneration) {
      // The POST may have happened, but THIS world no longer owns the
      // target: no observer, no writes onto another scope (§7 V11).
      return _remoteOutcome(RemoteStopKind.targetChanged);
    }
    switch (outcome.kind) {
      case RemoteStopKind.requested:
      case RemoteStopKind.checkingConflict:
        _startRemoteObserver(
          target,
          phase: RemoteStopPhaseState.checking,
          feedback: wording,
        );
      case RemoteStopKind.unconfirmed:
        // Read-only reconciliation only — the POST itself is never re-sent.
        _startRemoteObserver(
          target,
          phase: RemoteStopPhaseState.confirming,
          feedback: wording,
        );
      case RemoteStopKind.alreadyGone:
        _endRemoteObserver(
          RemoteStopPhaseState.unavailable,
          RemoteStopKind.alreadyGone,
          refreshHistory: true,
        );
        return RemoteStopOutcome(
          outcome.kind,
          message: wording,
          error: outcome.error,
        );
      case RemoteStopKind.failed:
        _setRemoteStop(RemoteStopPhaseState.none, feedback: wording);
        return RemoteStopOutcome(
          outcome.kind,
          message: wording,
          error: outcome.error,
        );
      case RemoteStopKind.ended:
      case RemoteStopKind.targetChanged:
      case RemoteStopKind.preflightFailed:
        return RemoteStopOutcome(
          outcome.kind,
          message: wording,
          error: outcome.error,
        );
    }
    return RemoteStopOutcome(outcome.kind, message: wording);
  }

  /// Classifies the (b) failure: the target moved. Terminal evidence in
  /// recentTerminal ENDS tracking honestly; a same-run `stopping` row just
  /// reconciles; anything else is targetChanged / an unavailable vanish —
  /// never a retarget onto whichever row looks similar (§5.1).
  Future<RemoteStopOutcome> _remoteTargetMoved(RemoteStopTarget target) async {
    final snap = observedActivity;
    if (snap != null &&
        (snap.sessionId != target.requestedSessionId ||
            snap.resolvedSessionId != target.resolvedSessionId ||
            snap.serverEpoch != target.serverEpoch)) {
      return _remoteOutcome(RemoteStopKind.targetChanged);
    }
    ActivityRun? row;
    for (final r in snap?.activeRuns ?? const <ActivityRun>[]) {
      if (r.runId == target.runId) row = r;
    }
    if (row == null) {
      for (final r in snap?.recentTerminal ?? const <ActivityRun>[]) {
        if (r.runId == target.runId && r.isTerminal) {
          // The target proved itself finished: alreadyGone/ended, ZERO POSTs
          // (V05) — history best-effort only.
          _endRemoteObserver(
            RemoteStopPhaseState.ended,
            RemoteStopKind.ended,
            refreshHistory: true,
          );
          return const RemoteStopOutcome(
            RemoteStopKind.ended,
            message: UiMessage.local(MessageKey.chatStopRemoteEnded),
          );
        }
      }
      // Gone with no terminal evidence: honest unavailability + refresh —
      // the page may NEVER pretend it ended (§5.1).
      _endRemoteObserver(
        RemoteStopPhaseState.unavailable,
        RemoteStopKind.alreadyGone,
        refreshHistory: true,
      );
      return const RemoteStopOutcome(
        RemoteStopKind.alreadyGone,
        message: UiMessage.local(MessageKey.chatStopRemoteUnavailable),
      );
    }
    if (row.isTerminal) {
      _endRemoteObserver(
        RemoteStopPhaseState.ended,
        RemoteStopKind.ended,
        refreshHistory: true,
      );
      return const RemoteStopOutcome(
        RemoteStopKind.ended,
        message: UiMessage.local(MessageKey.chatStopRemoteEnded),
      );
    }
    if (row.status == 'stopping') {
      // Already stopping server-side: reconcile, do NOT re-POST (§3 rule 3) —
      // the exact 409 UX without needing a 409.
      _startRemoteObserver(
        target,
        phase: RemoteStopPhaseState.checking,
        feedback: const UiMessage.local(MessageKey.chatStopRemoteChecking),
      );
      return const RemoteStopOutcome(
        RemoteStopKind.checkingConflict,
        message: UiMessage.local(MessageKey.chatStopRemoteChecking),
      );
    }
    return _remoteOutcome(RemoteStopKind.targetChanged);
  }

  RemoteStopOutcome _remoteOutcome(RemoteStopKind kind) {
    final msg = remoteStopMessage(kind);
    _setRemoteStop(RemoteStopPhaseState.none, feedback: msg);
    return RemoteStopOutcome(kind, message: msg);
  }

  void _startRemoteObserver(
    RemoteStopTarget target, {
    required RemoteStopPhaseState phase,
    UiMessage? feedback,
  }) {
    _remoteStopGen++;
    _remoteStopTimer?.cancel();
    _remoteStopObserved = target;
    _remoteStopStartedAt = _clock();
    _setRemoteStop(phase, feedback: feedback);
    // §5.2 cadence: ONE immediate reconcile, then every watchInterval (5s by
    // default — the existing injectable seam), total cap remoteStopWindow.
    _remoteStopTimer = Timer.periodic(
      watchInterval,
      (_) => unawaited(_remoteStopTick()),
    );
    unawaited(_remoteStopTick());
  }

  void _endRemoteObserver(
    RemoteStopPhaseState phase,
    RemoteStopKind kind, {
    bool refreshHistory = false,
  }) {
    _remoteStopGen++;
    _remoteStopTimer?.cancel();
    _remoteStopTimer = null;
    _remoteStopObserved = null;
    _remoteStopStartedAt = null;
    _setRemoteStop(phase, feedback: remoteStopMessage(kind));
    if (refreshHistory) unawaited(_remoteRefreshHistory());
    unawaited(refreshActivity());
  }

  Future<void> _remoteStopTick() async {
    if (_disposed || _remoteStopTickBusy) return;
    final target = _remoteStopObserved;
    final start = _remoteStopStartedAt;
    final gen = _remoteStopGen;
    if (target == null || start == null) return;
    bool alive() =>
        !_disposed &&
        gen == _remoteStopGen &&
        connectionGeneration == target.connectionGeneration;
    _remoteStopTickBusy = true;
    try {
      // The total deadline NEVER extends — checked before AND after the GET.
      if (_clock().difference(start) >= remoteStopWindow) {
        _endRemoteObserver(
          RemoteStopPhaseState.unconfirmed,
          RemoteStopKind.unconfirmed,
        );
        return;
      }
      Json status;
      try {
        status = await repo.runStatus(target.runId); // bounded 20s in repo
      } on ApiException catch (e) {
        if (!alive()) return; // late answer after abort: dropped
        if (e.status == 404) {
          // 404 may hide a scope mismatch: honest unavailability, other runs
          // untouched, nothing claimed (§5.2 row 3, V06).
          _endRemoteObserver(
            RemoteStopPhaseState.unavailable,
            RemoteStopKind.alreadyGone,
            refreshHistory: true,
          );
          return;
        }
        if (_clock().difference(start) >= remoteStopWindow) {
          _endRemoteObserver(
            RemoteStopPhaseState.unconfirmed,
            RemoteStopKind.unconfirmed,
          );
        }
        return; // bounded retry on the next tick — never a re-POST
      } on Object {
        if (!alive()) return;
        if (_clock().difference(start) >= remoteStopWindow) {
          _endRemoteObserver(
            RemoteStopPhaseState.unconfirmed,
            RemoteStopKind.unconfirmed,
          );
        }
        return;
      }
      if (!alive()) return; // generation moved: this answer owns nothing
      if (_clock().difference(start) >= remoteStopWindow) {
        _endRemoteObserver(
          RemoteStopPhaseState.unconfirmed,
          RemoteStopKind.unconfirmed,
        );
        return;
      }
      final state = status['status'];
      if (state is String && ActivityRun.isTerminalStatus(state)) {
        // Terminal for THIS target: stop the observer, history best-effort —
        // a history failure never overturns the known terminal (§5.2).
        _endRemoteObserver(
          RemoteStopPhaseState.ended,
          RemoteStopKind.ended,
          refreshHistory: true,
        );
        return;
      }
      // queued/running/waiting/stopping: keep the activity's true display and
      // keep bounded checking — never claim the stop landed (§5.2 row 5).
      _remoteStopPhase = RemoteStopPhaseState.checking;
      notifyListeners();
    } finally {
      if (!_disposed) _remoteStopTickBusy = false;
    }
  }

  /// READ-ONLY history refresh for the observer (display only). Never a
  /// settle: busy, pending, streams, timers, wake and drafts stay untouched,
  /// and a live local turn is never overwritten.
  Future<void> _remoteRefreshHistory() async {
    final gen = _remoteStopGen;
    List<Message> page;
    try {
      page = await repo.messages(sid);
    } catch (_) {
      return; // history is best-effort both ways
    }
    if (_disposed || gen != _remoteStopGen || busy) return;
    messages = page;
    notifyListeners();
  }

  /// An unknown/possibly-stale snapshot is never "idle" (plan §3.4): the send
  /// stays locked while a run we cannot rule out may exist. A legacy gateway
  /// (404 -> unsupported) keeps the pre-WAVE4 semantics: send allowed.
  // A controller that never had a page attached (unit-test scaffolding,
  // eviction ghosts) has nothing to observe — only visible pages lock sends
  // on an unconfirmed state.
  bool _everAttached = false;

  bool get activityBlocksSend => switch (activityFreshness) {
    ActivityFreshness.fresh || ActivityFreshness.unsupported => false,
    ActivityFreshness.unknown => _everAttached,
    ActivityFreshness.stale => observedActivity?.activeRuns.isNotEmpty ?? false,
  };

  bool get sendBlocked =>
      busy || _bootstrapping || remoteBusy || activityBlocksSend;

  /// This tab's two-layer owner token for the pending record (''), or the
  /// observed token after read-only adoption; null = nothing to compare
  /// (unowned record / never claimed) — compare-clear handles those too.
  String? _pendingToken;
  Timer? _leaseTimer;
  int _turnSeq = 0;

  bool _owns(Object? token) => !_disposed && identical(_turnToken, token);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(Diagnostics.current?.record('lifecycle.${state.name}'));
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      backgrounded = true;
      // WAVE4: a hidden app pays for ZERO activity GETs; the resume below
      // fires one immediate tick. In-flight snapshots are retired by epoch.
      _activityTimer?.cancel();
      _activityTimer = null;
      _activityEpoch++;
      notifyListeners();
    } else if (state == AppLifecycleState.resumed && backgrounded) {
      backgrounded = false;
      // AUDIT-16 lineage: only a page ON SCREEN pays — resume fires ONE
      // immediate activity GET for visible sessions, never a per-retained-
      // controller fan-out; the periodic timer restarts exactly once.
      if (!_detached && ChatViewers.count(sid) > 0) {
        _activityTimer ??= Timer.periodic(
          syncInterval,
          (_) => unawaited(_activityTick()),
        );
        unawaited(_activityTick());
      }
      if (phase == ChatPhase.recovering &&
          (_bootDeadline ?? _budgetDeadline) != null) {
        _armCountdownTicker(); // hidden pages skip repaints; re-arm on return
      }
      unawaited(reconcileForeground());
      // APPWAKE: resume is a dispatch trigger (plan §4) — but only for an
      // IDLE session; a busy one gets its chance at the settle instead.
      if (!busy && !_bootstrapping) _wakeSchedule();
      notifyListeners();
    }
  }

  Future<void> reconcileForeground() {
    return _foregroundCheck ??= _onForeground().whenComplete(
      () => _foregroundCheck = null,
    );
  }

  Future<void> _onForeground() async {
    final token = _turnToken;
    unawaited(Diagnostics.current?.record('history.foreground'));
    try {
      if (busy) {
        // AUDIT-11: exactly ONE scheduler per mode — RESUME the current
        // owner; never stack a second observer on top of it.
        if (_bootstrapWaiting) {
          unawaited(_bootstrapTick()); // single-flight via _bootTick
          return;
        }
        if (_stopping && live == null) {
          unawaited(_stopTick()); // single-flight via _stopBusyTick
          return;
        }
        if (live == null) {
          // Bootstrap-observation uncertain (timer expired): a resume is a
          // display refresh, NOT an automatic budget re-check — the 30s
          // allowance is spent only by a human tap (R1 §3.3.7). One
          // general activity GET rides the normal revision check.
          if (_detached || _watchTimer != null) {
            unawaited(_pollRun(fresh: true));
          } else if (phase == ChatPhase.uncertain) {
            unawaited(_activityTick());
          }
          return;
        }
        if (_detached || _watchTimer != null) {
          unawaited(_pollRun(fresh: true)); // single-flight via _pollTickBusy
          return;
        }
        // A live-SSE turn: ONE immediate read-only check; restart the
        // recover backoff only when the SSE is no longer the terminal source.
        final epoch = ++_recoveryEpoch; // abandons any sleeping recover
        _recovery = null;
        if (await _reconcile(epoch: epoch)) return;
        if (!_disposed &&
            epoch == _recoveryEpoch &&
            identical(_turnToken, token) &&
            phase != ChatPhase.sending) {
          unawaited(recover());
        }
      } else {
        // AUDIT-16: an idle session with no page on screen stays SILENT on
        // resume. Every retained controller still observes the lifecycle,
        // and without this guard a resume fanned out one history GET per
        // session ever visited — the slow-relapsing-lists complaint.
        if (ChatViewers.count(sid) == 0) return;
        if (activityFreshness == ActivityFreshness.unsupported) {
          await load(); // legacy gateway: only manual refresh semantics
        } else {
          // The revision inside the snapshot decides any history GET.
          await _activityTick();
        }
      }
    } catch (_) {
      if (_owns(token)) {
        error = const UiMessage.local(MessageKey.chatStateM001);
        if (busy) unawaited(recover());
      }
    }
    notifyListeners();
  }

  int _offset = 0;

  /// Locale-independent descriptor state (I18N-PLAN §4.3): UI resolves it
  /// with the CURRENT locale; overlays resolve at build, never pre-rendered.
  UiMessage? error;

  /// STUCK-BUSY B2: the un-settled-turn notice lives NEXT to (not inside)
  /// `error` so a cleanup failure never masks "this turn never got a
  /// final" — both can be visible at once.
  UiMessage? recoveryNotice;
  StopNotice stopNoticeKind = StopNotice.none;
  UiMessage? stopNoticeMessage;
  ChatPhase phase = ChatPhase.idle;
  LiveTurn? live;
  String? pendingInput;

  /// True once a history refresh shows the server persisted the pending turn
  /// — the pending bubble must then hide or the message renders twice.
  bool get pendingDelivered {
    final p = pendingInput;
    if (p == null) return false;
    // Same shared comparison as every other pending anchor (B1): a
    // cross-platform reformatted row must hide the bubble, not double it.
    if (!_turnAttemptBacked) {
      return messages.any(
        (m) =>
            !_beforeSend.contains(m.id) &&
            m.isUserTurn &&
            foldedTurnTextEquals(m.content, p),
      );
    }
    // R3 §5.4: for an attempt-backed send text stays a CANDIDATE filter.
    // Only a row that survives BOTH watermarks (not seen before the send;
    // numeric id above the send-time max — dropped once the server epoch
    // moved) and is the UNIQUE survivor may retire the bubble. Two
    // same-text candidates = "we cannot know" = the bubble stays (doubling
    // is honest; deleting the wrong row's bubble is not).
    final attempt = _evidenceAttempt;
    final moved = _sendEpochMoved || _attemptEpochMoved(attempt);
    final mark = _turnSendWatermark ?? attempt?.historyAfterId;
    var hits = 0;
    for (final m in messages) {
      if (!m.isUserTurn || _beforeSend.contains(m.id)) continue;
      final numeric = int.tryParse(m.id);
      if (!moved && mark != null && numeric != null && numeric <= mark) {
        continue;
      }
      if (!foldedTurnTextEquals(m.content, p)) continue;
      hits++;
    }
    return hits == 1;
  }

  bool stopBusy = false, steerBusy = false;
  bool get busy => phase != ChatPhase.idle;

  /// R2: the single pending-bubble rule for EVERY busy shape — the live
  /// send's text until history carries it, or the bootstrap-adopted text
  /// that has not anchored into history yet. Null = nothing pending
  /// (bubble must never render twice next to the timeline row).
  String? get pendingBubbleText {
    if (!busy) return null;
    final p = pendingInput;
    // R3 §5.4: an attempt-backed run's OWN completed transcript (event
    // stream = this attempt's identity, never a text match) already renders
    // the user row — the bubble stands down even before history lands.
    final tr = live?.transcript;
    if (p != null &&
        _turnAttemptBacked &&
        tr != null &&
        tr.any((m) => m.isUserTurn)) {
      return null;
    }
    if (p != null && !pendingDelivered) return p;
    if (live == null && !_wakeAdopted) {
      // APPWAKE: an adopted auto-wake turn shows NO human bubble — the
      // system-line projection owns it once anchored; before that, silence.
      final b = _bootUserText;
      if (b != null && !_bootstrapInspection().anchorFound) return b;
    }
    return null;
  }

  bool _wakeAdopted = false; // bootstrap adopted a persisted auto-wake turn

  /// Left-the-page mode: our SSE is cut on purpose so the server counts this
  /// run as having no viewer (that arms its ntfy push and the run keeps
  /// executing); a poll timer replaces the stream until a terminal status.
  final Duration watchInterval;
  bool _detached = false;
  bool _pollCapped = false;
  bool _pollTickBusy = false; // single-flight guard for _pollRun (AUDIT-11)
  bool _pollFreshQueued = false; // a fresh snapshot was asked for mid-GET
  int _pollFails = 0;
  DateTime? _budgetDeadline;
  bool _budgetBegun = false, _budgetRetryUsed = false;

  /// Last POSITIVE evidence the run is alive (an active status or a fresh
  /// active-run snapshot). The budget timer never expires a confirmed
  /// working run (B3: 已確認 active 的 run 顯示「仍在執行」) — only the
  /// evidence-free (unknown) stretch counts toward the deadline.
  DateTime? _lastActiveSeen;
  Timer? _watchTimer;
  Timer? _deadlineTimer;
  bool get detached => _detached;

  // ---- WAVE4 activity observation (replaces R1 message_count polling) -----
  // A visible page GETs /api/sessions/{sid}/activity every syncInterval: the
  // durable history revision PLUS the session's live runs — other devices'
  // turns, sync-API turns, runs older than this page. A revision move is the
  // ONLY history trigger; a quiet tick is that one GET and nothing else.
  // Failures NEVER fabricate idle: they mark stale and keep the last-known
  // state gating the send.
  static const syncInterval = Duration(seconds: 6);
  Timer? _activityTimer;
  Future<void>? _activityFlight; // single-flight across ticks/attach/refresh
  int _activityEpoch = 0; // pause / detach / rollback retires in-flight
  SessionActivity? observedActivity;
  DateTime? lastActivitySuccess;
  ActivityFreshness activityFreshness = ActivityFreshness.unknown;
  HistoryRevision? _appliedHistoryRevision, _pendingHistoryRev;
  final _remoteRows = <String, RemoteMessageRow>{}; // epoch+obs key -> row
  final _claimedRows = <String, String>{}; // observation_id -> durable row id

  // ---- CROSSDEV-STOP R1: request ordering + connection generation --------
  // Every activity request takes a monotonic sequence number at START and
  // captures the turn token, activity epoch and connection generation. The
  // validity of its result is RE-computed after every await (never a bool
  // frozen before the GET), and a response may only land if no strictly
  // newer response has already been applied. A late older answer can never
  // overwrite a newer epoch/snapshot (plan §4 bullet 1).
  int _activitySeq = 0;
  int _lastAppliedActivitySeq = 0;
  int _failedActivitySeq = 0; // the newest request that FAILED (typed error)
  Object? _activityFailure;
  // A URL / API-key move re-scopes every observed run identity: in practice
  // providers mint a NEW repo+controller, but the generation counter fences
  // any in-controller change too (and [debugBumpConnectionGeneration] proves
  // an in-flight old-generation response dies).
  int _connectionGeneration = 0;
  String _connectionIdentity = '';

  /// Lazily advances [_connectionGeneration] when the settings URL/key this
  /// controller reads from actually differ from the last observation.
  int _currentConnectionGeneration() {
    final now = '${repo.baseUrl}|${repo.key}';
    if (now != _connectionIdentity) {
      _connectionIdentity = now;
      _connectionGeneration++;
    }
    return _connectionGeneration;
  }

  // ---- GHOST-DUP B3: presentation-only local run ownership ----------------
  // The runId THIS controller's own turn was named by run.started. Excluded
  // from previews through recentTerminal (activeRunId goes null once live
  // completes) and cleared at every new send / epoch reset — never a
  // growing set of past runs, never inferred from text or source.
  String? _localOwnedRunId;
  // Unknown-identity preview arbitration window (plan B3): when a snapshot
  // run has NO runId yet, and a local pending preview exists for a turn
  // started no later than the observation (5s clock slop) with a history
  // watermark the observation cannot pre-date, the duplicate preview is
  // HELD while the pending bubble shows — no claim written, no durable
  // touch, released the moment any identity appears.
  DateTime? _turnSendAt;
  int? _turnSendWatermark;

  /// R3 §5.4: the server epoch observed when THIS turn dispatched. Once the
  /// epoch moves, the old numeric watermarks prove nothing about row
  /// identity — hard attribution with them is forbidden.
  String? _turnServerEpoch;

  bool get _sendEpochMoved {
    final seen = _turnServerEpoch;
    if (seen == null) return false;
    final now = observedActivity?.serverEpoch;
    return now != null && now != seen;
  }

  /// §5.4 for attempt-backed records: an attempt written under a known
  /// epoch whose CURRENT activity epoch differs (reload case — the numeric
  /// historyAfterId inside can no longer separate turns).
  bool _attemptEpochMoved(LocalAttempt? a) {
    final held = a?.serverEpoch;
    if (held == null) return false;
    final now = observedActivity?.serverEpoch;
    final nowNum = now == null ? null : int.tryParse(now);
    return nowNum != null && nowNum != held;
  }

  bool isLocallyRepresentedRun(ActivityRun r) {
    final id = r.runId;
    return id != null &&
        (id == activeRunId || id == _localOwnedRunId || id == _bootRunId);
  }

  bool _previewTextOverlapsPending(ActivityRun r) {
    if (r.runId != null) return false; // identity exists: exclusion decides
    final p = pendingBubbleText;
    if (p == null) return false; // no local preview to overlap
    final sent = _turnSendAt ?? _bootStartedAt;
    if (sent == null) return false;
    final started = DateTime.fromMillisecondsSinceEpoch(
      (r.startedAt * 1000).round(),
    );
    if (started.isBefore(sent.subtract(const Duration(seconds: 5)))) {
      return false; // older than this send: a genuinely different turn
    }
    final uid = r.user!.afterId;
    final mark = _turnSendWatermark ?? _bootHistoryAfterId;
    if (uid != null && mark != null && uid < mark) {
      return false; // anchors BEFORE this send: not ours to hide
    }
    final text = r.user!.text?.trim() ?? '';
    if (text.isEmpty) return false; // no text: cannot prove the overlap
    return foldedTurnTextEquals(text, p);
  }

  /// Public entry for /status's retry button and every internal caller.
  Future<void> refreshActivity() => _activityTick();

  /// CROSSDEV-STOP R1 §4 bullet 3: wait for ANY already-in-flight activity
  /// request to finish, then issue a NEW request (its seq is above every
  /// prior one). Evidence from a flight that started BEFORE this call is
  /// never laundered into this call's success — only a request started at
  /// or after it may decide the outcome, and a failure is reported as
  /// typed [ActivityRefreshOutcome] instead of letting the previous
  /// snapshot masquerade as a fresh one.
  Future<ActivityRefreshOutcome> refreshActivityForStopCheck() async {
    if (_disposed) {
      return const ActivityRefreshOutcome(ActivityRefreshResult.disposed);
    }
    final since = _activitySeq;
    final inflight = _activityFlight;
    if (inflight != null) {
      try {
        await inflight;
      } catch (_) {}
    }
    if (_disposed) {
      return const ActivityRefreshOutcome(ActivityRefreshResult.disposed);
    }
    if (_lastAppliedActivitySeq <= since && _failedActivitySeq <= since) {
      await _activityTick(); // the new request: seq strictly above `since`
      if (_disposed) {
        return const ActivityRefreshOutcome(ActivityRefreshResult.disposed);
      }
    }
    if (_lastAppliedActivitySeq > since) {
      return const ActivityRefreshOutcome(ActivityRefreshResult.refreshed);
    }
    if (_failedActivitySeq > since) {
      return ActivityRefreshOutcome(
        ActivityRefreshResult.failed,
        error: _activityFailure,
      );
    }
    return const ActivityRefreshOutcome(ActivityRefreshResult.staleContext);
  }

  Future<void> _activityTick() => _disposed
      ? Future.value()
      : _activityFlight ??= _activitySnapshot().whenComplete(
          () => _activityFlight = null,
        );

  Future<void> _activitySnapshot() async {
    final token = _turnToken;
    final epoch = _activityEpoch;
    final gen = _currentConnectionGeneration();
    final seq = ++_activitySeq;
    // CROSSDEV-STOP R1 §4: the OLD code froze `fresh` BEFORE the await and
    // re-read that constant after it — every state move that happened while
    // the GET was in flight was invisible, and a late response still landed.
    // The full context is now RE-computed at each decision point (after
    // every await), and ordering rejects anything the clock already passed.
    // A snapshot fetched while NO turn existed yet is session evidence, not
    // turn evidence: the adoption mint that follows must not silently drop
    // it (existing bootstrap contract), so only a REPLACED turn retires it.
    bool mine() =>
        !_disposed &&
        (token == null || identical(_turnToken, token)) &&
        epoch == _activityEpoch &&
        gen == _currentConnectionGeneration() &&
        seq > _lastAppliedActivitySeq;
    try {
      final snap = await repo.sessionActivity(sid);
      if (!mine()) return; // late / retired / superseded: never overwrite
      _lastAppliedActivitySeq = seq;
      _activityFailure = null;
      _applyActivity(snap, token);
      unawaited(_steerPoll());
      unawaited(_probeNotifyCap());
      unawaited(_notificationPoll());
    } on ApiException catch (e) {
      if (!mine()) return;
      _failedActivitySeq = seq;
      _activityFailure = e;
      if (e.status == 404) {
        // Legacy gateway: no live view here. "Unsupported" — NOT idle, and
        // sends stay allowed exactly like pre-WAVE4 pages.
        observedActivity = null;
        activityFreshness = ActivityFreshness.unsupported;
      } else {
        // 401/403/503/timeout: last-known view ages into stale; whatever it
        // proved keeps locking the send. A COLD failure stays unknown.
        // Never invent an empty active_runs.
        activityFreshness = observedActivity == null
            ? ActivityFreshness.unknown
            : ActivityFreshness.stale;
      }
      notifyListeners();
    } catch (e) {
      if (!mine()) return;
      _failedActivitySeq = seq;
      _activityFailure = e;
      activityFreshness = observedActivity == null
          ? ActivityFreshness
                .unknown // cold fail: still unconfirmed
          : ActivityFreshness.stale;
      notifyListeners();
    }
  }

  void _applyActivity(SessionActivity snap, Object? token) {
    final prev = observedActivity;
    if (prev != null && prev.serverEpoch != snap.serverEpoch) {
      // Gateway restarted: revisions/observations are incomparable now.
      _appliedHistoryRevision = null;
      _claimedRows.clear();
      _localOwnedRunId = null; // GHOST-DUP B3: the ownership table is per-epoch
    }
    if (prev != null &&
        snap.resolvedSessionId.isNotEmpty &&
        prev.resolvedSessionId.isNotEmpty &&
        prev.resolvedSessionId != snap.resolvedSessionId) {
      // Compaction/rollback rewrote the lineage: ids before/after may mean
      // different rows. The pending-revision pass below reloads the latest
      // page; the claim ledger (obs -> durable id) starts over.
      _appliedHistoryRevision = null;
      _claimedRows.clear();
      _localOwnedRunId = null;
      error = const UiMessage.local(MessageKey.chatStateM002);
      // APPWAKE A: lineage moved — the delivery_key-keyed queue rides
      // along; this only re-persists it under the continuing session.
      unawaited(_wakeObserver().moveLineage());
    }
    final remoteGone =
        prev != null &&
        remoteActive(prev.activeRuns, activeRunId).any(
          (r) =>
              !snap.activeRuns.any((x) => x.observationId == r.observationId),
        );
    observedActivity = snap;
    // R1 §4: the success stamp rides the INJECTED clock so STOP freshness
    // is testable (default `_now` stays DateTime.now — production unchanged).
    lastActivitySuccess = _clock();
    activityFreshness = ActivityFreshness.fresh;
    _rebuildRemoteRows();
    final rev = snap.historyRevision;
    if (_appliedHistoryRevision == null ||
        !rev.sameAs(_appliedHistoryRevision!) ||
        remoteGone) {
      _pendingHistoryRev = rev; // committed only when the GET succeeds
      if (!loading && !_bootstrapping) {
        unawaited(
          _latest(token).catchError((_) {
            // Silent: _pendingHistoryRev stays uncommitted, so the NEXT
            // tick re-schedules this exact fetch. The poll/reconcile
            // owners surface their own history errors elsewhere (AUDIT-05).
          }),
        );
      }
    }
    notifyListeners();
  }

  /// Ordered pairing between remote observations and durable rows: candidate
  /// rows are user rows newer than the observation's after_id that no
  /// observation has claimed yet; a match removes the temp row, a miss keeps
  /// the temp bubble until history confirms it (plan §3.3.2).
  void _rebuildRemoteRows() {
    final snap = observedActivity;
    _remoteRows.clear();
    if (snap == null) return;
    final waiting = <ActivityRun>[
      for (final r in snap.activeRuns)
        if (!isLocallyRepresentedRun(r) && r.user != null) r,
      for (final r in snap.recentTerminal)
        if (!isLocallyRepresentedRun(r) &&
            r.user != null &&
            !snap.activeRuns.any((a) => a.observationId == r.observationId))
          r,
    ]..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    if (waiting.isEmpty) return;
    final claimed = _claimedRows.values.toSet();
    // (GHOST-DUP B2) the ledger is IDEMPOTENT: an observation retired once
    // stays retired for the whole epoch/lineage — a rebuild must never
    // re-pair it (respawn its preview or re-take another row). Ledger
    // clearing happens only at the epoch/lineage resets in _applyActivity.
    final unclaimed = [
      for (final m in messages)
        if (m.isUserTurn &&
            !claimed.contains(m.id) &&
            !_beforeSend.contains(m.id) &&
            int.tryParse(m.id) != null)
          m,
    ]..sort((a, b) => int.parse(a.id).compareTo(int.parse(b.id)));
    for (final r in waiting) {
      if (_claimedRows.containsKey(r.observationId)) continue; // B2 skip
      final uid = r.user!.afterId;
      final text = r.user!.text?.trim();
      final folded = text == null ? '' : foldTurnText(text);
      Message? match;
      for (final m in unclaimed) {
        if (uid != null && int.parse(m.id) <= uid) continue;
        if (folded.isEmpty) {
          match = m; // no observed text: positional claim (original rule)
          break;
        }
        // Exact first, then whitespace/platform-decoration-insensitive:
        // cross-platform runs (Discord/API) persist text that is reformatted
        // versus the live observation preview — exact matching strands a
        // ghost row forever. Same rule as every other pending comparison
        // (turn_history_match — STUCK-BUSY B1).
        if (foldedTurnTextEquals(m.content, text!)) {
          match = m;
          break;
        }
      }
      if (match == null && uid != null) {
        // History-first positional fallback: a durable row AFTER the
        // observation point proves the observed turn is already persisted
        // (history appends in order), even if its text was rewritten.
        for (final m in unclaimed) {
          if (int.parse(m.id) > uid) {
            match = m;
            break;
          }
        }
      }
      if (match == null && r.isTerminal) {
        // A finished run's user row is durable by definition; if it is not
        // inside the loaded window, stranding "尚未於歷史確認" below the
        // timeline forever is worse than not showing the preview.
        continue;
      }
      if (match != null) {
        unclaimed.remove(match);
        _claimedRows[r.observationId] = match.id;
        continue;
      }
      // GHOST-DUP B3: identity-unknown overlap — while the local pending
      // bubble shows this exact text for THIS send, the duplicate preview
      // waits. No claim is written; durable rows are untouched; a revealed
      // runId (same or different) ends the hold on the very next rebuild.
      // (A durable match above ALWAYS wins: claims never wait.)
      // R3 §5.4: for an ATTEMPT-BACKED send the text hold is off — the
      // preview could just as well belong to a different attempt with the
      // same text, and hiding it on text alone is forbidden. It renders
      // instead as an UNCONFIRMED summary below.
      final overlaps = _previewTextOverlapsPending(r);
      if (overlaps && !_turnAttemptBacked) continue;
      final raw = text ?? '';
      final hint = r.isTerminal || (overlaps && _turnAttemptBacked)
          ? RemoteHint.unconfirmed
          : (r.user!.truncated ? RemoteHint.truncated : RemoteHint.none);
      _remoteRows['remote:${snap.serverEpoch}:${r.observationId}'] =
          RemoteMessageRow(
            Message(
              id: 'remote:${snap.serverEpoch}:${r.observationId}',
              role: 'user',
              content: raw,
            ),
            hint,
          );
    }
  }

  /// Remote user rows shown under the timeline (never part of `messages`, so
  /// loadOlder offsets and pendingDelivered fingerprints never see them).
  /// Raw Message + separate hint (I18N-PLAN §4.4): the localized note is
  /// rendered at the UI boundary, never stored in the row's content.
  List<RemoteMessageRow> get remoteRows => _remoteRows.values.toList();

  /// GHOST-DUP (B1/B3): the ONE synchronous projection-refresh seam — no
  /// HTTP, no timers, no state beyond the derived remote rows. Identity
  /// updates and durable-history commits call this so the UI never renders
  /// a stale preview alongside a row that already represents it.
  void _refreshUserProjections() => _rebuildRemoteRows();

  /// Pure presentation formatter (I18N-PLAN §4.4): accepts AppStrings so
  /// both the chat banner and /status render the SAME label; raw status and
  /// run-ID shortening stay literal data.
  static String formatRemoteRunLabel(AppStrings strings, ActivityRun r) =>
      strings.render(remoteRunDescriptor(r));

  /// Descriptor twin of [formatRemoteRunLabel] for dialog/SnackBar
  /// composition — raw status rides as an explicit raw arg.
  static UiMessage remoteRunDescriptor(ActivityRun r) {
    final short = r.runId == null
        ? null
        : 'run ${r.runId!.length > 8 ? r.runId!.substring(0, 8) : r.runId}';
    final who = r.runId == null
        ? const UiMessage.local(MessageKey.chatStateM003)
        : UiMessage.raw(short!);
    final what = !r.statusKnown
        ? UiMessage.local(MessageKey.chatStateM004, args: {'status': r.status})
        : switch (r.status) {
            'queued' => const UiMessage.local(MessageKey.chatStateM005),
            'running' => const UiMessage.local(MessageKey.chatStateM006),
            'waiting_for_approval' => const UiMessage.local(
              MessageKey.chatStateM007,
            ),
            'stopping' => const UiMessage.local(MessageKey.chatStateM008),
            _ => UiMessage.raw(r.status),
          };
    return UiMessage.local(
      MessageKey.chatStateRunLabel,
      args: {'who': who, 'what': what},
    );
  }

  // ---- reload recovery (bootstrap) ----------------------------------------
  // A fresh controller after F5 has no live turn; the persisted pending
  // record tells it which turn is still outstanding. Recovery is read-only:
  // runStatus by runId when known, otherwise bounded history observation.
  /// STUCK-BUSY B3: the OLD 30-minute fresh window and the 1440/15-poll
  /// counters are GONE. One persisted budget: 60s initial observation,
  /// then at most ONE 30s re-check — reloads adopt the persisted
  /// deadline instead of minting a new window.
  static const recoveryInitialWindow = Duration(seconds: 60);
  static const recoveryRetryWindow = Duration(seconds: 30);
  String? _bootRunId, _bootUserText;
  DateTime? _bootStartedAt, _bootDeadline;
  int? _bootHistoryAfterId;
  bool _bootActive = false, _bootKnownText = true, _bootRetryUsed = false;
  int _bootFails = 0;
  bool _bootTick = false;
  bool get _bootstrapWaiting =>
      _bootActive && live == null && pendingInput == null;

  /// AUDIT-21 (D2): a turn whose cross-tab claim is still in flight has
  /// not reached the SSE yet while already `sendBlocked`. If the last
  /// viewer leaves inside that window, detach defers to the mint point —
  /// the socket is cut the moment it exists, never earlier and never not.
  bool _pendingStart = false, _detachArmed = false;

  void detach() {
    if (_disposed) return;
    // WAVE4: page gone — the activity poll stops with it (no background GET
    // debt); in-flight snapshots retire via the epoch bump.
    _activityTimer?.cancel();
    _activityTimer = null;
    _activityEpoch++;
    // CROSSDEV-STOP §5.2: a hidden page pays ZERO GETs — the remote
    // observer's poll pauses (memory-only state survives; the deadline
    // clock keeps running; attach resumes, and a reload shows 「核對中」
    // purely from fresh activity — never a re-POST).
    _remoteStopTimer?.cancel();
    _remoteStopTimer = null;
    if (_pendingStart) {
      _detachArmed = true;
      return;
    }
    if (!busy || _detached) return;
    if (_bootstrapWaiting || (_stopping && live == null)) {
      // A reload-recovery (or stopping) poll has no SSE to cut and never arms
      // a viewer: keep the read-only scheduler running across page pop instead
      // of handing it to _pollRun (live/pendingInput are null here).
      return;
    }
    _detached = true;
    _silenceWatch?.cancel();
    // SILENCE-DROP §3.1.6: the page leaves the SSE as the outcome owner; the
    // waiting notice and turn cause die with this ownership mode (the poll
    // UX must not inherit either).
    _waitingSeconds = null;
    _turnRecoveryCause = null;
    _recoveryEpoch++; // abandon any in-flight recover() loop
    _recovery = null;
    repo.cancelStream(sid);
    _watchTimer?.cancel();
    _watchTimer = Timer.periodic(watchInterval, (_) => unawaited(_pollRun()));
    unawaited(_pollRun());
    notifyListeners();
  }

  /// Re-entering the page: stop polling and take one status snapshot; if the
  /// run already ended the snapshot reconciles history immediately.
  void attach() {
    if (_disposed) return;
    _everAttached = true;
    // WAVE4: page visible — observe the session's live activity NOW (first
    // snapshot immediately, then every syncInterval). bootstrap() awaits the
    // same in-flight tick, so entering never double-GETs.
    _activityTimer ??= Timer.periodic(
      syncInterval,
      (_) => unawaited(_activityTick()),
    );
    unawaited(_activityTick());
    // CROSSDEV-STOP §5.2: resume a paused observer poll for the visible page
    // (read-only runStatus only; the first tick enforces the total deadline).
    if (_remoteStopObserved != null &&
        _remoteStopTimer == null &&
        (_remoteStopPhase == RemoteStopPhaseState.checking ||
            _remoteStopPhase == RemoteStopPhaseState.confirming)) {
      _remoteStopTimer = Timer.periodic(
        watchInterval,
        (_) => unawaited(_remoteStopTick()),
      );
      unawaited(_remoteStopTick());
    }
    if (!_detached) return;
    _detached = false;
    _watchTimer?.cancel();
    _watchTimer = null;
    if (busy) {
      unawaited(_pollRun(fresh: true));
    } else {
      // APPWAKE: the page is on screen again — an idle queued batch gets
      // its debounced chance (gates re-checked inside the dispatch).
      _wakeSchedule();
    }
  }

  /// AUDIT-05: the detached/poll mode has exactly ONE owner. Every non-terminal
  /// exit of `_pollRun` (including attach()'s single snapshot) must either
  /// re-arm the timer or land in uncertain with a REAL retry action — never
  /// return into a busy phase with an empty schedule.
  void _ensurePollTimer([Object? token]) {
    if (_disposed || !busy || live == null || _watchTimer != null) return;
    if (!identical(_turnToken, token ?? _turnToken)) return; // not my turn
    _watchTimer = Timer.periodic(watchInterval, (_) => unawaited(_pollRun()));
  }

  Future<void> _pollRun({bool fresh = false}) async {
    if (_disposed) return;
    if (_pollTickBusy) {
      // AUDIT-11: another GET owns the verdict for this turn — never overlap
      // in-flight status/history reads; keep the schedule alive.
      _ensurePollTimer();
      // A FRESH snapshot request (attach/foreground/retry) must NOT be
      // swallowed by the busy guard: its answer is the in-flight GET's
      // possibly-STALE verdict (e.g. 'running' before a waiting_for_approval
      // surfaced). Queue it to run the moment that GET lands.
      if (fresh) _pollFreshQueued = true;
      return;
    }
    final turn = live;
    final token = _turnToken;
    final runId = turn?.runId;
    _pollTickBusy = true;
    try {
      await _pollRunBody(turn, token, runId);
    } finally {
      if (!_disposed) _pollTickBusy = false;
      final again = _pollFreshQueued && busy && _owns(token) && !_pollCapped;
      _pollFreshQueued = false;
      // ONE-SHOT follow-up (never fresh=true: propagating the flag re-arms
      // the queue on every overlapping request and, with a synchronous fake
      // repo, becomes a zero-delay recursion — the 8.4GB suite OOM). Caps
      // and ownership decide the stop, same as the timer path.
      if (!_disposed && again) unawaited(_pollRun());
    }
  }

  Future<void> _pollRunBody(
    LiveTurn? turn,
    Object? token,
    String? runId,
  ) async {
    if (_disposed) return;
    if (runId == null) {
      // SSE was cut before run.started surfaced: reconcile history instead. If
      // the server persisted our user message the run is alive and its final
      // will land later — keep polling (long runs included); only give up when
      // the turn never appeared at all.
      if (busy) {
        // STUCK-BUSY B3: the 1440/15 counters are gone — the SAME
        // persisted recovery budget decides when this observation ends.
        if (await _budgetGate(token)) return; // expired → uncertain (stops)
        var settled = false;
        // AUDIT-05①: a failed history read is a transient miss, not a throw
        // into the void — an escaping error here would strand attach()'s
        // single snapshot with busy and an empty schedule.
        try {
          settled = await _reconcile(epoch: _recoveryEpoch);
        } catch (_) {}
        if (settled) return;
        if (!_owns(token)) return; // the turn was settled/replaced mid-GET
        if (await _budgetGate(token)) return; // expiry during the GETs
        _ensurePollTimer(
          token,
        ); // AUDIT-05①: keep the schedule, don't strand busy
      }
      return;
    }
    late final Json status;
    try {
      status = await repo.runStatus(runId);
    } on ApiException catch (e) {
      if (!_owns(token)) return; // stale response: the new turn owns everything
      if (e.status == 404) {
        if (_isStoppedRun(runId)) {
          _watchTimer?.cancel();
          _watchTimer = null;
          _setStop(
            StopNotice.accepted,
            const UiMessage.local(MessageKey.chatStateStoppedByYou),
          );
          await _finish(soft: true, token: token); // AUDIT-05③
          return;
        }
        // The gateway forgot this run — fall back to a history reconciliation
        // pass; a CONFIRMED-quiet no-final turn settles with the incomplete
        // notice (B2), anything weaker lands in uncertain with a REAL
        // retry action instead of polling a dead id forever.
        _watchTimer?.cancel();
        _watchTimer = null;
        if (await _budgetGate(token)) return; // expiry mid-404: uncertain
        var settled = false;
        // AUDIT-05①: same discipline here — a failing history read lands in
        // uncertain (with its 「重新核對」action), never an uncaught throw.
        try {
          settled = await _reconcile(epoch: _recoveryEpoch);
        } catch (_) {}
        if (settled || !_owns(token)) return;
        if (!busy) return;
        final quiet = await _quietRound(token, _recoveryEpoch, () async {
          try {
            await _reconcile(epoch: _recoveryEpoch);
          } catch (_) {}
        });
        if (!_owns(token)) return;
        if (await _budgetGate(token)) return;
        final pendingTurn = store.loadPending(serverUrl, sid);
        final verdict = evaluateRecoveryEvidence(
          runGone: true,
          quietConfirmed: quiet,
          activeConfirmed:
              activityFreshness == ActivityFreshness.fresh &&
              (observedActivity?.activeRuns.any((r) => !r.isTerminal) ?? false),
          history: inspectPendingHistory(
            rows: messages,
            pendingText: pendingInput,
            excludeIds: _beforeSend,
            historyAfterId: pendingTurn?.historyAfterId,
          ),
        );
        if (verdict == RecoveryVerdict.incompleteTerminal) {
          await _settleTurn(
            token,
            errorMessage: const UiMessage.local(MessageKey.chatTurnIncomplete),
          );
          return;
        }
        phase = ChatPhase.uncertain;
        error = const UiMessage.local(MessageKey.chatRecoveryUncertain);
        notifyListeners();
      } else {
        _ensurePollTimer(token); // AUDIT-05: transient HTTP keeps polling
      }
      return;
    } catch (_) {
      if (!_owns(token)) return;
      // Transient transport error: retry on the next tick; after ~1 minute of
      // misses stop hammering AND land in uncertain so 「重新核對」 (a REAL
      // action) shows — a bare error line under busy is a dead end (AUDIT-05②).
      if (++_pollFails > 12) {
        _watchTimer?.cancel();
        _watchTimer = null;
        _pollCapped = true;
        phase = ChatPhase.uncertain;
        error = const UiMessage.local(MessageKey.chatStateM011);
        notifyListeners();
      } else {
        _ensurePollTimer(token);
      }
      return;
    }
    if (!_owns(token) || !identical(live, turn)) return;
    _pollFails = 0;
    final state = status['status'];
    if (state == 'completed' || state == 'cancelled') {
      _watchTimer?.cancel();
      _watchTimer = null;
      if (state == 'cancelled') {
        _setStop(
          _stopRequestedFor(runId)
              ? StopNotice.accepted
              : StopNotice.serverEnded,
          UiMessage.local(
            _stopRequestedFor(runId)
                ? MessageKey.chatStateStoppedByYou
                : MessageKey.chatStateM012,
          ),
        );
      }
      await _finish(soft: true, token: token); // AUDIT-05③
      return;
    }
    if (state == 'failed') {
      _watchTimer?.cancel();
      _watchTimer = null;
      await _finish(soft: true, token: token); // AUDIT-05③
      return;
    }
    if (state == 'waiting_for_approval') {
      _lastActiveSeen = _clock();
      final a = status['approval'];
      if (a is Map && turn != null && turn.approval == null) {
        if (approvalInboxSupported) {
          // The inbox owns the cards; bootstrap once per idle gap.
          if (!approvalInbox.hasPendingForRun(runId)) {
            unawaited(_refreshApprovals(runId));
          }
        } else {
          turn.approval = Map<String, dynamic>.from(a);
          turn.approvalChoice = null;
          notifyListeners();
        }
      }
      _ensurePollTimer(
        token,
      ); // AUDIT-05①: the card waits WITH a live scheduler
      return; // the card lets the user answer from here
    }
    // Still running: make sure SOMETHING keeps polling — attach() may have
    // cleared the timer mid-request, and there is no SSE re-subscribe route.
    _ensurePollTimer(token);
  }

  bool approvalBusy = false;

  // ---- APPROVALPUSH B3: cross-device approval inbox (spec R6) -------------
  // Cards are keyed by exact request and live OUTSIDE the turn; the turn
  // only keeps its legacy card when the server lacks the capability.
  final ApprovalInbox approvalInbox = ApprovalInbox();
  Map<String, dynamic>? _approvalCap;
  bool _approvalCapAsked = false;
  bool _approvalsFetching = false;

  bool get approvalInboxSupported => _approvalCap?['enabled'] == true;

  /// An OLD server was confirmed (or asked) and we are still showing the
  /// legacy card — say so honestly instead of pretending the new flow runs.
  bool get approvalLegacyNotice =>
      live?.approval != null && _approvalCapAsked && !approvalInboxSupported;

  List<ApprovalRequest> pendingApprovals() {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    return approvalInbox.visible(now);
  }

  Set<String> get approvalUnconfirmedRuns => approvalInbox.unconfirmedRuns;

  Future<void> _probeApprovalCap() async {
    if (_approvalCap != null) return; // supported = cached (epoch-stable)
    _approvalCapAsked = true;
    final feature = await repo.approvalInboxFeature(); // never throws
    if (feature != null && feature['enabled'] == true) _approvalCap = feature;
    // Absent/transient: not cached — the next approval touch re-asks.
  }

  Future<void> _refreshApprovals(String runId) async {
    if (_approvalsFetching) return;
    _approvalsFetching = true;
    try {
      await _probeApprovalCap();
      if (!approvalInboxSupported || _disposed) return;
      final snapshot = await repo.runApprovals(runId);
      if (_disposed) return;
      approvalInbox.mergeSnapshot(
        serverUrl: serverUrl,
        runId: runId,
        snapshot: snapshot,
      );
    } on Object {
      if (!_disposed) approvalInbox.markUnconfirmed(runId);
    } finally {
      _approvalsFetching = false;
      if (!_disposed) notifyListeners();
    }
  }

  static bool _approvalTerminalEvent(String type) => switch (type) {
    'run.completed' ||
    'run.failed' ||
    'run.cancelled' ||
    'run.interrupted' => true,
    _ => false,
  };

  Future<void> _routeApprovalInbox(dynamic event, LiveTurn turn) async {
    await _probeApprovalCap();
    if (!approvalInboxSupported || _disposed) return;
    Map data;
    try {
      data = event.json as Map;
    } on Object {
      data = const {};
    }
    final runId = '${data['run_id'] ?? turn.runId ?? ''}';
    switch (event.type as String) {
      case 'approval.request':
        final entry = approvalInbox.upsertEvent(
          serverUrl: serverUrl,
          data: data,
        );
        // One card per request: with the panel on, the turn must not also
        // render the same request's legacy card.
        if (entry != null && runId == turn.runId) turn.approval = null;
        unawaited(_refreshApprovals(runId)); // cross-device siblings
      case 'approval.responded':
        approvalInbox.settle(
          runId: runId,
          requestId: '${data['request_id'] ?? ''}',
          outcome: 'answered',
          choice: data['choice']?.toString(),
        );
      case 'approval.resolved':
        approvalInbox.settle(
          runId: runId,
          requestId: '${data['request_id'] ?? ''}',
          outcome: '${data['outcome'] ?? 'resolved'}',
        );
      default:
        if (runId.isNotEmpty) {
          approvalInbox.settleRun(
            serverUrl: serverUrl,
            runId: runId,
            outcome: 'run_terminal',
          );
        }
    }
    if (!_disposed) notifyListeners();
  }

  /// Exact-answer path (R6): ONE POST per request, shared per-request busy,
  /// conflicts reconcile through a fresh GET — never a blind re-post.
  Future<void> resolveApprovalExact(ApprovalRequest req, String choice) async {
    if (req.busy || req.phase != ApprovalPhase.pending) return;
    if (req.expiredAt(DateTime.now().millisecondsSinceEpoch / 1000.0)) return;
    req.busy = true;
    req.error = null;
    notifyListeners();
    try {
      await repo.resolveApprovalExact(
        req.runId,
        choice,
        req.requestId,
        req.serverEpoch > 0 ? req.serverEpoch : null,
      );
      if (_disposed) return;
      approvalInbox.settle(
        runId: req.runId,
        requestId: req.requestId,
        outcome: 'answered',
        choice: choice,
      );
      final turn = live;
      if (turn != null && turn.runId == req.runId && turn.approval == null) {
        turn.approvalChoice = choice; // existing answered-note, no fake rows
      }
      notifyListeners();
    } on Object {
      req.busy = false;
      req.error = UiMessage.local(MessageKey.approvalUnavailable);
      unawaited(_refreshApprovals(req.runId));
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> reconfirmApprovals(ApprovalRequest req) =>
      _refreshApprovals(req.runId);

  bool get canControl => live?.runId != null && !live!.completed && busy;

  // ---- stopping a turn the user can see but the SSE may not know ----------
  // runId order for a stop target: live turn → bootstrap-known runId →
  // persisted pending record. `canControl` stays SSE-only (steer needs a live
  // socket); stopping only needs a runId and a read-only settle path.
  bool _stopping = false, _stopBusyTick = false;
  String? _stopRunId;
  int _stopFails = 0;
  int reconnects = 0;

  // ---- OFFLINE-SEND R2 §4.2/§4.3: local settlement state -------------------
  /// Outcome of the most recent human send attempt (composer decisions).
  SendOutcome? sendOutcome;

  // ---- OFFLINE-SEND R3 §5.1/§5.3: delivery-evidence state ------------------
  /// Storage refusal notice for evidence/journal writes that were refused
  /// mid-flight. The in-memory positive evidence STAYS valid next to it
  /// (§5.2.7) — a storage error never revokes what was observed.
  UiMessage? storageNotice;

  /// The attempt this page's CURRENT/most recent human send is about
  /// (claim-minted, or minted locally by the offline short-circuit). The
  /// derived getters prefer its journal entry; after a reload it is read
  /// back through the pending record's attemptId.
  String? _turnAttemptId;

  /// In-memory mirror of the last evidence this session wrote/read for
  /// [_turnAttemptId] — kept even when the matching journal write was
  /// refused (positive evidence survives storage failure, §5.2.7).
  LocalAttempt? _attemptMirror;

  /// Which attempt [_attemptMirror] belongs to (mirror is attempt-scoped).
  String? _mirrorAttemptId;

  /// Serializes every journal merge so merges land in evidence order inside
  /// the same session lock; decision points `await` it before settling.
  Future<void> _evidenceQueue = Future.value();

  /// Business ack already recorded for this turn — merge once, not per frame.
  bool _journalAckRecorded = false;

  /// Live-dispatch view only while THIS send owns the attempt.
  bool _dispatchInFlight = false;

  /// R3 §5.3: derived presentation state for the current attempt (journal +
  /// this session's mirror only — see [AttemptDeliveryView]).
  AttemptDeliveryView? get deliveryView {
    final a = _evidenceAttempt;
    if (a == null) return null;
    switch (a.delivery) {
      case AttemptDelivery.acknowledged:
        return AttemptDeliveryView.acknowledged;
      case AttemptDelivery.rejected:
        return AttemptDeliveryView.rejected;
      case AttemptDelivery.notDispatched:
        return AttemptDeliveryView.notDispatched;
      case AttemptDelivery.outcomeUnknown:
        // dispatchIntent persisted by THIS live send → neutral "sending".
        // A reload only ever sees the conservative unknown (§5.2.8: intent
        // alone is never stronger than unknown — and never weaker).
        if (_dispatchInFlight &&
            _mirrorAttemptId == a.attemptId &&
            a.terminalEvidence?['dispatchIntent'] == true) {
          return AttemptDeliveryView.dispatching;
        }
        return AttemptDeliveryView.outcomeUnknown;
    }
  }

  /// The failed card source (§5.3 first row): set only while structured
  /// before-dispatch evidence stands for the current attempt. Wording
  /// follows the recorded DECISION, never a live connectivity read.
  UiMessage? get failedCard {
    final a = _evidenceAttempt;
    if (a == null || a.delivery != AttemptDelivery.notDispatched) return null;
    return UiMessage.local(
      a.terminalEvidence?['decision'] == 'blockedBeforeDispatch'
          ? MessageKey.chatSendOffline
          : MessageKey.chatSendNotDispatched,
    );
  }

  /// Journal-first view of the attempt the getters describe: the live/last
  /// send's attempt (mirrored in-memory), else the pending record's.
  LocalAttempt? get _evidenceAttempt {
    final id = _turnAttemptId ?? store.loadPending(serverUrl, sid)?.attemptId;
    if (id == null) return _latestJournalAttempt();
    if (_mirrorAttemptId == id && _attemptMirror != null) return _attemptMirror;
    return store.loadAttempt(serverUrl, sid, id);
  }

  /// R3 §5.3: the failed-card source after a reload — the newest UNSETTLED
  /// human attempt that holds real evidence (snapshot or structured). A
  /// migration stub (neither) never surfaces as anyone's card.
  LocalAttempt? _latestJournalAttempt() {
    final all = [
      for (final a in store.listAttempts(serverUrl, sid))
        if (a.origin == 'human' &&
            a.disposition != AttemptDisposition.settled &&
            (a.rawDraft != null || a.terminalEvidence != null))
          a,
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return all.isEmpty ? null : all.last;
  }

  /// R3 §5.4: an attempt is BACKED when its record holds a real snapshot or
  /// structured evidence. Migration stubs (attemptId-only, minted by
  /// `savePending`/`beginPendingRecovery`) are NOT backed: they keep the
  /// legacy byte-identical text paths everywhere.
  bool get _turnAttemptBacked {
    final a = _evidenceAttempt;
    return a != null && (a.rawDraft != null || a.terminalEvidence != null);
  }

  /// CP/LiveTurnView read this to pick identity-only transcript exclusion
  /// (§5.4): backed turns never drop transcript rows on text equality.
  bool get turnIsAttemptBacked => !_disposed && _turnAttemptBacked;

  /// The one attempt record behind the current/last turn's evidence.
  String? get turnAttemptId =>
      _turnAttemptId ?? store.loadPending(serverUrl, sid)?.attemptId;

  /// §5.3: the ONE derived busy-state presentation. Both widgets consume
  /// this — never their own guesses.
  LivePresentation get livePresentation {
    if (_disposed || !busy) return LivePresentation.silent;
    switch (phase) {
      case ChatPhase.sending:
        if (!_turnAttemptBacked) return LivePresentation.activeConfirmed;
        // Acked (business frame/runId) = the server took this attempt;
        // before that it is honestly "sending", never "typing".
        if (_journalAckRecorded || live?.runId != null) {
          return LivePresentation.activeConfirmed;
        }
        return LivePresentation.dispatching;
      case ChatPhase.recovering:
        if (recoveryActiveConfirmed) return LivePresentation.activeConfirmed;
        return recoverySecondsRemaining != null
            ? LivePresentation.countdown
            : LivePresentation.silent;
      case ChatPhase.uncertain:
        return LivePresentation.silent;
      case ChatPhase.idle:
        return LivePresentation.silent;
    }
  }

  /// §5.3/§6: the neutral delivery note for an attempt-backed attempt whose
  /// outcome is STILL unknown while the page sits uncertain. Legacy shapes
  /// (and every attempt with positive ack) stay worded by `error` alone.
  UiMessage? get deliveryNotice {
    if (_disposed || phase != ChatPhase.uncertain) return null;
    final a = _evidenceAttempt;
    if (a == null || !_turnAttemptBacked) return null;
    if (a.delivery != AttemptDelivery.outcomeUnknown) return null;
    return const UiMessage.local(MessageKey.chatDeliveryUnknown);
  }

  // ---- R3 §5.3: safe retry of a NOT-DISPATCHED attempt ---------------------

  /// Single-flight guard: concurrent taps join the ONE retry future.
  Future<SendOutcome>? _retryFlight;

  @visibleForTesting
  Future<SendOutcome>? get retryFlight => _retryFlight;

  /// The notDispatched card's attempt id (retry affordance target), set only
  /// while structured never-dispatched evidence stands unretried.
  String? get retryUnsentAttemptId {
    if (_disposed) return null;
    final a = _evidenceAttempt;
    if (a == null || a.origin != 'human') return null;
    if (a.delivery != AttemptDelivery.notDispatched) return null;
    if (a.terminalEvidence?['retriedBy'] != null) return null;
    return a.attemptId;
  }

  /// Retry needs (a) the idle page, (b) real never-dispatched evidence and
  /// (c) RESOLVED Web-Locks capability — without locks the button renders
  /// disabled next to `chatCrossTabSafetyReduced` (§4.5/§5.3).
  bool get retryUnsentAvailable {
    if (_disposed || busy) return false;
    if (retryUnsentAttemptId == null) return false;
    return _txCapability() == StoreTxCapability.resolvedAvailable;
  }

  /// §5.3: the ONLY retry POST in the whole feature, and only for
  /// notDispatched. Re-checks the old attempt, stamps `retriedBy` BEFORE
  /// the child dispatches (a crash / second view can never mint a second
  /// child that posts), then re-sends the preserved rawDraft through the
  /// NORMAL send gate (fresh attempt id, normal prepare — the old
  /// preparedInput's artifacts are never replayed). Unknown attempts have
  /// NO retry path, by construction.
  Future<SendOutcome> retryUnsent(String attemptId) {
    final flight = _retryFlight;
    if (flight != null) return flight;
    final started = _retryUnsentNow(attemptId);
    _retryFlight = started;
    unawaited(
      started.whenComplete(() {
        if (identical(_retryFlight, started)) _retryFlight = null;
      }),
    );
    return started;
  }

  Future<SendOutcome> _retryUnsentNow(String attemptId) async {
    if (!retryUnsentAvailable) return SendOutcome.stale;
    final old = store.loadAttempt(serverUrl, sid, attemptId);
    if (old == null ||
        old.attemptId != attemptId ||
        old.origin != 'human' ||
        old.delivery != AttemptDelivery.notDispatched ||
        old.terminalEvidence?['retriedBy'] != null) {
      return SendOutcome.stale; // not the retry shape: no POST, no state change
    }
    final raw = old.rawDraft;
    if (raw == null || raw.trim().isEmpty) {
      // A notDispatched record without its preserved draft cannot be
      // re-sent honestly — leave the card exactly as it is.
      return SendOutcome.stale;
    }
    sendOutcome = null;
    await send(raw, draft: raw, rawDraft: raw, retryOf: attemptId);
    return sendOutcome ?? SendOutcome.stale;
  }

  /// CAS the retry marker into the PARENT attempt before the child may
  /// dispatch. True only when the stamp holds (or already names THIS
  /// child); false means another view already retried (or the write was
  /// refused) and the child must never dispatch.
  Future<bool> _stampRetriedBy(
    String parentAttemptId,
    String childAttemptId, {
    String? replacing,
  }) async {
    final parent = store.loadAttempt(serverUrl, sid, parentAttemptId);
    if (parent == null) return false;
    final stamp = parent.terminalEvidence?['retriedBy'];
    if (stamp == childAttemptId) return true;
    if (stamp != null && stamp != replacing)
      return false; // another view's child
    final next = Map<String, dynamic>.from(parent.terminalEvidence ?? const {})
      ..['retriedBy'] = childAttemptId;
    return store.saveAttempt(
      serverUrl,
      sid,
      LocalAttempt(
        attemptId: parent.attemptId,
        server: parent.server,
        sid: parent.sid,
        createdAt: parent.createdAt,
        origin: parent.origin,
        rawDraft: parent.rawDraft,
        preparedInput: parent.preparedInput,
        attachmentSnapshots: parent.attachmentSnapshots,
        editorRevision: parent.editorRevision,
        disposition: parent.disposition,
        delivery: parent.delivery,
        runId: parent.runId,
        historyAfterId: parent.historyAfterId,
        serverEpoch: parent.serverEpoch,
        recoveryStartedAt: parent.recoveryStartedAt,
        recoveryDeadline: parent.recoveryDeadline,
        retryUsed: parent.retryUsed,
        draftRestoredRevision: parent.draftRestoredRevision,
        terminalEvidence: next,
      ),
    );
  }

  /// Flushes every queued journal merge (test/decision-point seam).
  @visibleForTesting
  Future<void> waitEvidenceWrites() => _evidenceQueue;

  /// Double-tap join: every concurrent stop() shares the ONE in-flight
  /// future (the old `stopBusy → return true` double-tap lie is retired).
  Future<StopResult>? _stopFlight;

  /// Stop asked while this turn's cross-tab claim was still in flight:
  /// send() must end its OWN claim journal-first before any repo.chat.
  bool _stopDuringClaim = false;
  Completer<StopResult>? _stopDuringClaimDone;

  /// Bootstrap found the pending record's ABANDONED tombstone (§4.2 crash
  /// ordering): never re-arm a waiting budget — only the local cleanup
  /// retry is offered, zero POSTs, no timers.
  bool _localCleanupOnly = false;

  String? get activeRunId {
    final l = live;
    if (l != null) return l.completed ? null : l.runId;
    if (!busy) return null;
    if (_stopping) return _stopRunId;
    if (_bootRunId != null) return _bootRunId;
    return store.loadPending(serverUrl, sid)?.runId;
  }

  bool get canStop =>
      !_localCleanupOnly && !stopBusy && !_stopping && activeRunId != null;

  /// R2 §4.3: the LOCAL end affordance — a busy page whose run the server
  /// never named (sending before run.started, recovering/uncertain after a
  /// runId-less bootstrap, incl. bootstrap history failures and budget-
  /// write refusals) with a pending human attempt record. stop() branches
  /// internally; the SAME entry point serves both kinds.
  bool get canEndLocalWaiting {
    if (_disposed || _localCleanupOnly) return false;
    if (!busy || activeRunId != null) return false;
    final p = store.loadPending(serverUrl, sid);
    return p != null && p.attemptId != null && !p.isAutoWake;
  }

  /// True while the ONLY local action is the cleanup retry (§4.2 step 3:
  /// abandoned tombstone, shared pending delete still outstanding).
  bool get localCleanupRetryAvailable =>
      !_disposed && _localCleanupOnly && phase == ChatPhase.uncertain;

  /// run 404-after-stop is terminal-by-the-user, not "vanished": the stop
  /// record is the only surviving evidence. `accepted` settles; a bare
  /// `requested` (POST outcome uncertain, e.g. 409-reload) must NOT be
  /// dressed up as a confirmed stop — history observation decides.
  String? _stopStatusFor(String runId) {
    final raw = store.stopRecord(serverUrl, sid);
    if (raw == null) return null;
    try {
      final rec = jsonDecode(raw) as Map;
      return rec['run_id'] == runId ? rec['status'] as String? : null;
    } catch (_) {
      return null;
    }
  }

  bool _isStoppedRun(String runId) => _stopStatusFor(runId) == 'accepted';
  bool _stopRequestedFor(String runId) {
    final s = _stopStatusFor(runId);
    return s == 'accepted' || s == 'requested';
  }

  Future<void> resolveApproval(String choice) async {
    final turn = live;
    final token = _turnToken;
    final id = turn?.approvalRunId; // R4: bridge events carry their own run_id
    if (turn == null || id == null || turn.approval == null || approvalBusy)
      return;
    approvalBusy = true;
    notifyListeners();
    try {
      await repo.resolveApproval(id, choice);
      if (_disposed ||
          !identical(live, turn) ||
          !identical(_turnToken, token)) {
        return; // the answer landed on a turn we no longer own
      }
      turn.approval = null;
      turn.approvalChoice = choice;
    } catch (e) {
      if (_owns(token)) {
        turn.approvalError = UiMessage.local(
          MessageKey.chatStateM013,
          args: {'error': messageForError(e)},
        );
      }
    } finally {
      approvalBusy = false;
      notifyListeners();
    }
  }

  final _beforeSend = <String>{};
  Timer? _silenceWatch;
  DateTime _lastEventAt = DateTime.now();

  /// SILENCE-DROP §3.1.1: the second clock. Heartbeats refresh transport
  /// freshness ([_lastEventAt]) but NOT this one, so a live-but-silent run
  /// accumulates "waiting for Xs" wording instead of any error claim.
  DateTime? _lastOutputAt;

  /// Cached whole seconds of the waiting notice; null hides it. Only the
  /// watchdog tick changes the value, so repaints stay cheap.
  int? _waitingSeconds;

  /// Turn-local recovery cause: the first start of a turn sets it; an
  /// explicitly observed stream failure upgrades a neutral one, and a
  /// neutral cause NEVER downgrades a failure (SILENCE-DROP §3.1.5).
  RecoveryCause? _turnRecoveryCause;

  bool get _observedStreamFailure =>
      _turnRecoveryCause == RecoveryCause.streamEnded ||
      _turnRecoveryCause == RecoveryCause.streamError;

  /// Exposed for tests and the widget's color choice; wording is always
  /// re-resolved from the LATEST cause at render/notify time.
  RecoveryCause? get recoveryCause => _turnRecoveryCause;

  /// SILENCE-DROP §3.2: "waiting for a reply (no output for Xs)" — only
  /// while a FOREGROUND page is actually sending; it rides the normal
  /// secondary tone in chat_page, never [error] and never [recoveryNotice].
  UiMessage? get streamWaitingNotice =>
      phase == ChatPhase.sending &&
          !backgrounded &&
          !_detached &&
          _waitingSeconds != null
      ? UiMessage.local(
          MessageKey.chatStreamWaiting,
          args: {'seconds': _waitingSeconds},
        )
      : null;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return; // idempotent: body + addTearDown both call it
    repo.releaseStreamKeepalive(sid);
    repo.cancelStream(sid);
    _watchTimer?.cancel();
    _deadlineTimer?.cancel();
    _countdownTicker?.cancel();
    _activityTimer?.cancel();
    _activityTimer = null;
    _activityEpoch++;
    // CROSSDEV-STOP R2: the remote observer dies with the controller — the
    // poll timer is cancelled and the generation bump rejects every late
    // completion (an aborted observer never leaks a write or a notify).
    _remoteStopTimer?.cancel();
    _remoteStopTimer = null;
    _remoteStopGen++;
    _remoteStopObserved = null;
    _remoteStopStartedAt = null;
    _leaseTimer?.cancel();
    _leaseTimer = null;
    _wakeDebounce?.cancel(); // APPWAKE: no timer may fire after dispose
    _wakeDebounce = null;
    _disposed = true;
    _recoveryEpoch++;
    _turnToken = null; // retire every observer of every retired turn
    _settledTurn = null;
    _settleGate = null;
    final claimStop = _stopDuringClaimDone;
    _stopDuringClaimDone = null;
    if (claimStop != null && !claimStop.isCompleted) {
      claimStop.complete(const StopResult(StopResultKind.failure));
    }
    WidgetsBinding.instance.removeObserver(this);
    ChatViewers.unregister(sid, this); // eviction ledger follows dispose
    _silenceWatch?.cancel();
    _waitingSeconds =
        null; // SILENCE-DROP §3.1.6: a dead controller shows nothing
    super.dispose();
  }

  void dismissStopNotice() {
    _setStop(StopNotice.none);
    notifyListeners();
  }

  void _setStop(StopNotice kind, [UiMessage? message]) {
    stopNoticeKind = kind;
    stopNoticeMessage = message;
  }

  Future<void> toggleDetail() async {
    detailed = !detailed;
    notifyListeners();
    await store.setDetailed(serverUrl, sid, detailed);
  }

  Future<void> load() async {
    if (loading || busy || _bootstrapping) return;
    loading = true;
    error = null;
    notifyListeners();
    final token = _turnToken;
    try {
      await _latest(token);
    } catch (e) {
      error = UiMessage.local(
        MessageKey.chatStateM014,
        args: {'error': messageForError(e)},
      );
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Pure read + identity-guarded commit (AUDIT-12): a page fetched BEFORE a
  /// new turn began must never overwrite that turn's messages. R1 (A3): the
  /// optional observation epoch is re-checked at the COMMIT point too — a
  /// late GET from a retired observation may not write rows even when the
  /// turn object still looks identical.
  Future<void> _latest([Object? token, int? epoch]) async {
    final page = await repo.messages(sid);
    if (_disposed || !identical(_turnToken, token)) return;
    if (epoch != null && epoch != _recoveryEpoch) return;
    messages = mergeMessages([], page);
    _offset = page.length;
    hasOlder = page.length == 200;
    _afterHistoryCommit(token);
  }

  /// The applied-revision bookkeeping every successful history GET shares.
  /// _pendingHistoryRev is the snapshot revision the fetch was scheduled FOR;
  /// it becomes the applied baseline ONLY once the rows are on screen. If the
  /// snapshot moved during the GET, one follow-up activity tick (rate-limited
  /// by the tick itself, never a hot loop) closes the remaining window.
  void _afterHistoryCommit(Object? token) {
    if (_disposed || !identical(_turnToken, token)) return;
    if (_pendingHistoryRev != null) {
      _appliedHistoryRevision = _pendingHistoryRev;
      _pendingHistoryRev = null;
    } else if (observedActivity != null) {
      _appliedHistoryRevision = observedActivity!.historyRevision;
    }
    _rebuildRemoteRows();
    final snap = observedActivity;
    if (snap != null &&
        (_appliedHistoryRevision == null ||
            !snap.historyRevision.sameAs(_appliedHistoryRevision!))) {
      _pendingHistoryRev = snap.historyRevision;
      unawaited(_activityTick());
    }
    // GHOST-DUP B1: the durable page is now ON SCREEN — publish it. The
    // activity tick that scheduled this GET already notified BEFORE the
    // await; without this frame the user stares at a stale pending/preview
    // until the next tick (the listener hole plan A2 proved).
    notifyListeners();
    // APPWAKE A/C: shadow scan rides ONLY the successful latest-page commit
    // of the CURRENT identity (never an old page, never a failed GET); the
    // dispatch check runs AFTER the scan so it sees the fresh queue — the
    // 1s debounce merges a burst into one request (plan §5).
    unawaited(
      _wakeObserver().onHistoryCommit(messages).then((_) {
        if (_disposed) return;
        notifyListeners(); // pending-count hints track the fresh queue
        if (((_wake?.state?['queued']) as List?)?.isNotEmpty == true) {
          _wakeSchedule();
        }
      }),
    );
  }

  /// Cold-start / re-entry entry (replaces attach()+load from the page):
  /// rejoin a turn the persisted pending record says is still outstanding —
  /// strictly read-only (run status + history), never a replayed POST.
  /// R1 (A2): a persisted pending turn is adopted, budgeted and PUBLISHED
  /// locally BEFORE any network read — a failing/hanging history GET can no
  /// longer hide the local exits. No pending → the original remote-read
  /// flow (+ lost reconciliation).
  Future<void> bootstrap() async {
    attach(); // warm re-entry keeps its existing semantics
    // APPWAKE D: ONLY an opted-in user is asked — a capability GET on a
    // cold default-off path would cost every session open (and leak a
    // pending timeout into every legacy test harness).
    if (store.autoWakeEnabled(serverUrl)) {
      unawaited(
        _wakeCapOnce().then((_) {
          if (!_disposed) notifyListeners();
        }),
      );
    }
    if (_disposed || busy || loading || _bootstrapping)
      return; // duplicate: no-op
    loading = _bootstrapping = true; // AUDIT-09: no send until decided
    error = null;
    notifyListeners();
    final pending = store.loadPending(serverUrl, sid);
    if (pending != null) {
      await _adoptPending(pending);
      return;
    }
    if (activityFreshness == ActivityFreshness.unknown) {
      // WAVE4: settle the first snapshot BEFORE the history GET joins it —
      // the attach-fired tick above is awaited here (same single-flight).
      // A write between the two GETs trips the revision check in
      // _afterHistoryCommit instead of a swallowed message_count delta.
      await _activityTick().timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
    }
    try {
      await _latest();
    } catch (e) {
      loading = false;
      error = UiMessage.local(
        MessageKey.chatStateM014,
        args: {'error': messageForError(e)},
      );
      notifyListeners();
      return;
    } finally {
      if (!_disposed) _bootstrapping = false;
    }
    loading = false;
    if (_disposed) return;
    if (busy || _turnToken != null) return; // a turn took over mid-read
    final appeared = store.loadPending(serverUrl, sid);
    if (appeared == null) {
      if (store.lostNotice(serverUrl, sid) != null) await _reconcileLost();
      if (!_disposed) notifyListeners();
      return;
    }
    // A record appeared while the reads were in flight (another tab's
    // claim): adopt it read-only through the SAME path.
    await _adoptPending(appeared);
  }

  /// Adopt the persisted turn as THIS controller's identity (AUDIT-12):
  /// every later observer captures the token and stale work dies on it.
  /// D2: remember the record's current owner token too — observation may
  /// settle (terminal seen), but the clear is compare-and-delete, so it
  /// can never wipe a claim another tab took in the meantime. No claim is
  /// written here: watching is not owning. Publishes the busy shape BEFORE
  /// any network await (R1/A2).
  Future<void> _adoptPending(PendingTurn pending) async {
    final adoptToken = _turnToken = Object();
    _pendingToken = pending.token;
    _bootRunId = pending.runId;
    // APPWAKE: a persisted auto-wake turn rides on its ledger batch — the
    // settle below will ack terminal, and its row projects as a system line.
    _wakeAdopted = pending.isAutoWake;
    _wakeBatchInFlight = pending.isAutoWake ? pending.wakeBatchId : null;
    _bootKnownText = pending.hasUserText;
    _bootUserText = pending.hasUserText ? pending.userText : null;
    _bootStartedAt = pending.startedAt;
    _bootFails = 0;
    recoveryNotice = null;
    // R2 §4.2 step 3 / §4.5: an ABANDONED tombstone matching this record is
    // a crash-between-journal-and-delete residue. It must never bootstrap
    // back into an active waiting window: no begin, no timers — publish
    // the cleanup-pending uncertain shape and offer ONLY the local cleanup
    // retry. Zero POSTs, no restore, no auto-send.
    final adoptedAttemptId = pending.attemptId;
    if (adoptedAttemptId != null && !pending.isAutoWake) {
      final entry = store.loadAttempt(serverUrl, sid, adoptedAttemptId);
      if (entry != null && entry.disposition == AttemptDisposition.abandoned) {
        _localCleanupOnly = true;
        _bootRunId = null;
        _bootstrapping = false;
        loading = false;
        phase = ChatPhase.uncertain;
        error = const UiMessage.local(MessageKey.chatStateM025);
        notifyListeners();
        return;
      }
    }
    // STUCK-BUSY B3: adopt (or stamp exactly once) the PERSISTED budget —

    // a reload gets the REMAINING time, never a fresh 60s, and a storage
    // that refuses the migration must not open a window either.
    PendingTurn? budget;
    try {
      final begun = await store.beginPendingRecovery(
        serverUrl,
        sid,
        token: pending.token,
        initialWindow: recoveryInitialWindow,
        now: _clock(),
      );
      if (begun.outcome == PendingRecoveryOutcome.mismatch ||
          begun.outcome == PendingRecoveryOutcome.missing) {
        // Another tab re-claimed mid-adoption: stop here, re-read the NEW
        // owner's state next entry, never race it.
        if (!_owns(adoptToken)) return;
        _bootstrapping = false;
        loading = false;
        _turnToken = null;
        _pendingToken = null;
        error = const UiMessage.local(MessageKey.chatStateM021);
        notifyListeners();
        return;
      }
      budget = begun.record;
    } catch (_) {
      // R1 table row 6: storage refused the budget. Land uncertain with
      // the honest notice, but KEEP the captured local identity — clearing
      // the token here would make every later compare-clear a no-op and
      // strand the page busy forever.
      if (!_disposed) {
        _bootstrapping = false;
        loading = false;
        phase = ChatPhase.uncertain;
        error = const UiMessage.local(MessageKey.chatRecoveryStorageFailed);
        notifyListeners();
      }
      return;
    }
    if (_disposed || !identical(_turnToken, adoptToken)) return;
    _bootstrapping = false;
    loading = false; // local actions stay reachable while the GETs follow
    _bootDeadline = budget?.recoveryDeadline;
    _bootRetryUsed = budget?.recoveryRetryUsed ?? false;
    _bootHistoryAfterId = budget?.historyAfterId;
    if (_bootDeadline != null && !_clock().isBefore(_bootDeadline!)) {
      // Persisted budget already spent (reload after expiry, incl. the
      // exact deadline — A4): uncertain IMMEDIATELY — observing again
      // would be a fresh window in disguise. The ADOPTED identity stays:
      // the 「結束本機等待」 action and the compare-clear need this
      // turn's token (an expired observation is still THIS page's turn).
      phase = ChatPhase.uncertain;
      error = UiMessage.local(
        budget != null && budget.recoveryRetryUsed
            ? MessageKey.chatRecoveryExhausted
            : MessageKey.chatRecoveryUncertain,
      );
      notifyListeners();
      return;
    }
    _bootActive = true;
    phase = ChatPhase.recovering; // busy: waiting, never idle-without-trying
    notifyListeners(); // PUBLISH before the first GET (A2)
    _watchTimer?.cancel();
    _watchTimer = Timer.periodic(
      watchInterval,
      (_) => unawaited(_bootstrapTick()),
    );
    _armDeadlineTimer();
    _armCountdownTicker();
    unawaited(_bootstrapTick());
    // Display rows ride a READ-ONLY best-effort load: a transient miss is
    // retried by the observation ticks (their expiry publishes the honest
    // state) and must never escape this already-published bootstrap.
    unawaited(_latest(adoptToken, _recoveryEpoch).catchError((_) {}));
  }

  void _cancelBootstrapWaiting() {
    _watchTimer?.cancel();
    _watchTimer = null;
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
    _bootRunId = null;
    _bootUserText = null;
    _bootStartedAt = null;
    _bootDeadline = null;
    _bootActive = false;
    _bootKnownText = true;
    _bootTick = false;
    _bootFails = 0;
  }

  /// STUCK-BUSY B3 / OFFLINE-SEND R1 (A4): the deadline fires on its own
  /// one-shot timer, so a hung GET can never hold busy past the budget.
  /// The armed time NEVER collapses to Duration.zero: when the deadline
  /// passed but positive active evidence still defers the landing, the
  /// retry is scheduled at the positive remaining (or the poll cadence),
  /// never as a zero-delay spin against the same stale deadline.
  void _armDeadlineTimer() {
    _deadlineTimer?.cancel();
    var deadline = _bootActive ? _bootDeadline : _budgetDeadline;
    if (deadline == null) return;
    final seen = _lastActiveSeen;
    if (seen != null) {
      final floor = seen.add(recoveryInitialWindow);
      if (floor.isAfter(deadline)) deadline = floor;
    }
    var remaining = deadline.difference(_clock());
    if (remaining <= Duration.zero) {
      remaining = const Duration(seconds: 5);
    }
    _deadlineTimer = Timer(
      remaining,
      () => unawaited(_bootActive ? _bootstrapTick() : _budgetTick()),
    );
  }

  /// Budget expiry check shared by the bootstrap ticks and the runId-less
  /// live poll. A CONFIRMED-active run defers it (active outranks the
  /// timer — "仍在執行" is never relabelled incomplete); otherwise the
  /// observation stops here and lands in uncertain with its actions.
  /// R1: expiry is `now >= deadline` (exact-deadline ticks count), the
  /// retry-flag snapshot happens BEFORE the bootstrap fields die (A4),
  /// and only THIS turn's own run counts as active evidence (plan §5).
  bool _budgetExpiredNow() {
    final deadline = _bootActive ? _bootDeadline : _budgetDeadline;
    if (deadline == null || _clock().isBefore(deadline)) return false;
    final ownRun = activeRunId;
    final activeFresh =
        (_lastActiveSeen != null &&
            _clock().difference(_lastActiveSeen!) <= recoveryInitialWindow) ||
        (ownRun != null &&
            activityFreshness == ActivityFreshness.fresh &&
            (observedActivity?.activeRuns.any(
                  (r) => !r.isTerminal && r.runId == ownRun,
                ) ??
                false));
    if (activeFresh) {
      _armDeadlineTimer(); // still working: watch the NEXT window edge
      return false;
    }
    // A4: snapshot the wording flags BEFORE any field cancellation —
    // _cancelBootstrapWaiting clears _bootActive and the retry snapshot
    // must still describe THIS observation.
    final retryUsed = _bootActive ? _bootRetryUsed : _budgetRetryUsed;
    _recoveryEpoch++; // kill late continuations of this observation
    if (_bootActive) {
      _cancelBootstrapWaiting();
    } else {
      _watchTimer?.cancel();
      _watchTimer = null;
      _deadlineTimer?.cancel();
      _deadlineTimer = null;
    }
    _countdownTicker?.cancel();
    _countdownTicker = null;
    phase = ChatPhase.uncertain;
    // 保留 pending：逾時不等於中斷；「重新核對」最多一次，之後只剩清帳。
    error = UiMessage.local(
      retryUsed
          ? MessageKey.chatRecoveryExhausted
          : MessageKey.chatRecoveryUncertain,
    );

    notifyListeners();
    return true;
  }

  Future<void> _budgetTick() async {
    if (_disposed || !busy || live != null && live!.runId != null) return;
    _budgetExpiredNow();
  }

  /// begin-once for any caller that needs the allowance BEFORE consuming.
  /// Returns true when the caller must stop (error already surfaced).
  Future<bool> _ensureBudgetBegun(Object? token) async {
    if (_budgetBegun) return false;
    _budgetBegun = true;
    try {
      // R1 §3.2: compare against THIS observer's captured token only —
      // never borrow the token of a newer record seen after the reload.
      final begun = await store.beginPendingRecovery(
        serverUrl,
        sid,
        token: _pendingToken,
        initialWindow: recoveryInitialWindow,
        now: _clock(),
      );
      if (!_owns(token)) return true;
      if (begun.outcome == PendingRecoveryOutcome.mismatch) {
        error = const UiMessage.local(MessageKey.chatStateM021);
        notifyListeners();
        return true;
      }
      if (begun.outcome == PendingRecoveryOutcome.begun ||
          begun.outcome == PendingRecoveryOutcome.alreadyPresent) {
        _budgetDeadline = begun.record?.recoveryDeadline;
        _budgetRetryUsed = begun.record?.recoveryRetryUsed ?? false;
      }
    } catch (_) {
      if (_owns(token)) {
        phase = ChatPhase.uncertain;
        error = const UiMessage.local(MessageKey.chatRecoveryStorageFailed);
        notifyListeners();
      }
      return true;
    }
    return false;
  }

  /// Ensures the live (in-tab) observation runs inside the SAME persisted
  /// budget as bootstrap: stamped once, adopted on takeover, and a
  /// refused write surfaces honestly instead of silently re-arming.
  /// Returns true when the caller must STOP (already landed uncertain).
  Future<bool> _budgetGate(Object? token) async {
    if (_disposed || !busy) return false;
    if (!_budgetBegun) {
      _budgetBegun = true;
      try {
        final begun = await store.beginPendingRecovery(
          serverUrl,
          sid,
          token: _pendingToken,
          initialWindow: recoveryInitialWindow,
          now: _clock(),
        );
        if (!_owns(token)) return false;
        if (begun.outcome == PendingRecoveryOutcome.begun ||
            begun.outcome == PendingRecoveryOutcome.alreadyPresent) {
          _budgetDeadline = begun.record?.recoveryDeadline;
          _budgetRetryUsed = begun.record?.recoveryRetryUsed ?? false;
          _armDeadlineTimer();
        }
      } catch (_) {
        if (_owns(token)) {
          _watchTimer?.cancel();
          _watchTimer = null;
          phase = ChatPhase.uncertain;
          error = const UiMessage.local(MessageKey.chatRecoveryStorageFailed);
          notifyListeners();
        }
        return true;
      }
    }
    return _budgetExpiredNow();
  }

  Future<void> _bootstrapTick() async {
    if (_disposed || !_bootActive) return;
    // Checked BEFORE the single-flight guard: an in-flight GET must not
    // delay the budget's expiry (B3: "到限 even if GET未完成").
    if (_budgetExpiredNow()) return;
    if (_bootTick) return;
    _bootTick = true;
    final epoch = _recoveryEpoch;
    final token = _turnToken;
    try {
      final runId = _bootRunId;
      if (runId != null) {
        Json status;
        try {
          status = await repo.runStatus(runId);
        } on ApiException catch (e) {
          if (!_owns(token) || epoch != _recoveryEpoch) return;
          if (e.status == 404) {
            if (_isStoppedRun(runId)) {
              // A stopped run is never resurrected by observation: the user
              // ended it, the gateway already forgot it. Settle now instead
              // of parking the page in busy forever (input locked).
              _setStop(
                StopNotice.accepted,
                const UiMessage.local(MessageKey.chatStateStoppedByYou),
              );
              await _bootstrapSettled(token);
              return;
            }
            // The gateway forgot this run: fall back to history observation
            // instead of declaring the turn dead.
            _bootRunId = null;
            return;
          }
          if (++_bootFails > 12) {
            error = const UiMessage.local(MessageKey.chatStateM016);
            notifyListeners();
          }
          return; // Transient: retry on the next tick.
        } catch (_) {
          if (!_owns(token) || epoch != _recoveryEpoch) return;
          if (++_bootFails > 12) {
            error = const UiMessage.local(MessageKey.chatStateM016);
            notifyListeners();
          }
          return;
        }
        if (!_owns(token) || epoch != _recoveryEpoch) return;
        _bootFails = 0;
        final state = status['status'];
        if (state == 'completed') {
          // B2 rule 5: an explicit terminal settles EVEN when the history
          // read fails (with the honest "history unreadable" notice) — a
          // GET miss must not push a dead-topped turn back into
          // recovering. When history IS read and this turn has no final,
          // the incomplete notice rides along.
          List<Message>? page;
          try {
            page = await repo.messages(sid); // 對帳：final 由歷史取得。
          } catch (_) {}
          if (!_owns(token) || epoch != _recoveryEpoch) return;
          if (page != null) {
            messages = mergeMessages([], page);
            _offset = page.length;
            hasOlder = page.length == 200;
          }
          final inspection = page == null
              ? null
              : _bootstrapInspectionFor(page);
          await _settleTurn(
            token,
            page: page,
            errorMessage: page == null
                ? const UiMessage.local(MessageKey.chatTerminalHistoryUnknown)
                : (inspection != null &&
                      inspection.anchorFound &&
                      !inspection.hasFinal)
                ? const UiMessage.local(MessageKey.chatTurnIncomplete)
                : null,
          );
          return;
        }
        if (state == 'cancelled') {
          // A cancelled run with this session's stop record is the user's
          // hand, not the server's own end — keep the provenance.
          _setStop(
            _stopRequestedFor(runId)
                ? StopNotice.accepted
                : StopNotice.serverEnded,
            UiMessage.local(
              _stopRequestedFor(runId)
                  ? MessageKey.chatStateStoppedByYou
                  : MessageKey.chatStateM012,
            ),
          );
          await _bootstrapSettled(token);
          return;
        }
        if (state == 'failed') {
          await _bootstrapSettled(token);
          if (!_owns(token)) return;
          // Server-provided error text stays raw; only the wrapper is local.
          error = UiMessage.local(
            MessageKey.chatStateM018,
            args: {
              'detail': status['error'] is String
                  ? UiMessage.raw(status['error'] as String)
                  : const UiMessage.local(MessageKey.chatStateM017),
            },
          );
          notifyListeners();
          return;
        }
        // OFFLINE-SEND R1 §3.3.5: ONLY the whitelisted statuses count as
        // active (queued/running/waiting_for_approval/stopping). An unknown
        // status string stays UNKNOWN — it never refreshes freshness, so a
        // garbled answer can neither extend the wait nor show 發言中.
        if (state == 'queued' ||
            state == 'running' ||
            state == 'waiting_for_approval' ||
            state == 'stopping') {
          _lastActiveSeen = _clock();
        }
        return;
      }
      try {
        await _latest(token);
      } catch (_) {
        return; // Transient read miss: retry next tick.
      }
      if (!_owns(token) || epoch != _recoveryEpoch) return;
      final inspection = _bootstrapInspection();
      if (inspection.anchorFound && inspection.hasFinal) {
        await _bootstrapSettled(token);
        return;
      }
      // No final yet. A unique anchor + the LOST terminal (run 404 earlier
      // in this budget, or no runId at all) + CONFIRMED quiet (activity →
      // history → activity, same epoch/revision, zero active) is evidence
      // the turn ended without a final answer → settle with the notice.
      // Anything weaker (quiet insufficient, ambiguous anchor, remote
      // rows only) stays unknown — observation continues inside the
      // persisted budget (B2 rules 2 and 4).
      if (inspection.anchorFound &&
          !inspection.ambiguous &&
          (_bootRunId == null)) {
        final quiet = await _quietRound(token, epoch, () => _latest(token));
        if (!_owns(token) || epoch != _recoveryEpoch) return;
        final verdict = evaluateRecoveryEvidence(
          quietConfirmed: quiet,
          activeConfirmed:
              activityFreshness == ActivityFreshness.fresh &&
              (observedActivity?.activeRuns.any((r) => !r.isTerminal) ?? false),
          history: _bootstrapInspection(),
        );
        switch (verdict) {
          case RecoveryVerdict.incompleteTerminal:
            await _settleTurn(
              token,
              errorMessage: const UiMessage.local(
                MessageKey.chatTurnIncomplete,
              ),
            );
            return;
          case RecoveryVerdict.normalTerminal:
            await _bootstrapSettled(token);
            return;
          case RecoveryVerdict.running:
          case RecoveryVerdict.unknown:
            break; // keep watching inside the budget
        }
      }
    } finally {
      if (!_disposed) _bootTick = false;
    }
  }

  /// B2 rule 2's paired quiet read: activity #1 (fresh, zero active, no
  /// overflow) → the history GET → activity #2 with UNCHANGED
  /// serverEpoch/historyRevision and still zero active. A stale,
  /// unsupported, overflowed or erroring snapshot is NEVER quiet
  /// evidence; a moved revision just retries within the remaining budget.
  Future<bool> _quietRound(
    Object? token,
    int epoch,
    Future<void> Function() historyStep,
  ) async {
    SessionActivity? first;
    var snap = observedActivity;
    bool quietish(SessionActivity? s) =>
        s != null && !s.overflow && s.activeRuns.every((r) => r.isTerminal);
    bool freshOk(SessionActivity? s) =>
        activityFreshness == ActivityFreshness.fresh &&
        quietish(s) &&
        lastActivitySuccess != null &&
        _clock().difference(lastActivitySuccess!) <= syncInterval;
    if (!freshOk(snap)) {
      await _activityTick();
      if (!_owns(token) || epoch != _recoveryEpoch) return false;
      snap = observedActivity;
      if (activityFreshness != ActivityFreshness.fresh || !quietish(snap)) {
        return false;
      }
    }
    first = snap!;
    await historyStep();
    if (!_owns(token) || epoch != _recoveryEpoch) return false;
    await _activitySnapshot();
    if (!_owns(token) || epoch != _recoveryEpoch) return false;
    final second = observedActivity;
    return activityFreshness == ActivityFreshness.fresh &&
        second != null &&
        !second.overflow &&
        second.activeRuns.every((r) => r.isTerminal) &&
        second.serverEpoch == first.serverEpoch &&
        second.resolvedSessionId == first.resolvedSessionId &&
        second.historyRevision.sameAs(first.historyRevision);
  }

  /// Pending-inspection of the loaded page for the bootstrap-adopted turn
  /// (shared matcher, STUCK-BUSY B1): time floor = persisted startedAt −
  /// 5s; a legacy record WITHOUT user_text can never anchor.
  PendingHistoryInspection _bootstrapInspection() =>
      _bootstrapInspectionFor(messages);

  PendingHistoryInspection _bootstrapInspectionFor(List<Message> rows) =>
      inspectPendingHistory(
        rows: rows,
        pendingText: _bootKnownText ? (_bootUserText ?? '') : null,
        knownText: _bootKnownText,
        timeFloor: (_bootStartedAt?.millisecondsSinceEpoch ?? 0) / 1000 - 5,
        historyAfterId: _bootHistoryAfterId,
      );

  Future<void> _bootstrapSettled(Object? token) async {
    _recovery = null;
    await _settleTurn(token); // one gate for every terminal exit (AUDIT-12)
  }

  Future<void> loadOlder() async {
    if (loadingOlder || !hasOlder || busy || _bootstrapping) return;
    loadingOlder = true;
    error = null;
    notifyListeners();
    final token = _turnToken;
    try {
      final page = await repo.messages(sid, offset: _offset);
      if (_disposed || !identical(_turnToken, token))
        return; // new turn owns state
      messages = mergeMessages(messages, page);
      _offset += page.length; // Raw page size, NOT de-duplicated rendered rows.
      hasOlder = page.length == 200;
      // GHOST-DUP B1: older rows can satisfy an observation's claim — the
      // projection must be rebuilt BEFORE the finally's notify paints. The
      // LATEST-page revision bookkeeping is deliberately NOT touched.
      _refreshUserProjections();
      // APPWAKE A: an OLD page may close a cursor gap — scan it WITHOUT
      // latest-page rights (it can queue rows, never advance the cursor).
      unawaited(_wakeObserver().onHistoryCommit(messages, latestPage: false));
    } catch (e) {
      error = UiMessage.local(
        MessageKey.chatStateM019,
        args: {'error': messageForError(e)},
      );
    } finally {
      loadingOlder = false;
      notifyListeners();
    }
  }

  /// APPWAKE C: [wakeBatch] marks a server-admitted auto-wake dispatch —
  /// the ledger CAS verdict (409/410) surfaces through the SAME ApiException
  /// surface; [suppressPending] keeps a wake turn from rendering its
  /// canonical sentence as a fake human bubble (the projection owns it).
  Future<void> send(
    String input, {
    String? draft,
    String? wakeBatch,
    bool suppressPending = false,
    String? rawDraft,
    String? retryOf,
  }) async {
    if (sendBlocked || input.trim().isEmpty) return; // AUDIT-09 gate
    final spentDraft = draft ?? input;
    final isWake = wakeBatch != null;
    // R3 §5.3: a retry child must still see its parent's UNRETRIED
    // notDispatched evidence at entry; a second view that already stamped
    // retriedBy loses here, before any state or claim is touched.
    if (retryOf != null) {
      final parent = store.loadAttempt(serverUrl, sid, retryOf);
      if (parent == null ||
          parent.delivery != AttemptDelivery.notDispatched ||
          parent.terminalEvidence?['retriedBy'] != null ||
          _txCapability() != StoreTxCapability.resolvedAvailable) {
        return;
      }
    }
    // OFFLINE-SEND R3 §5.2.2: the offline HINT may only gate whether THIS
    // app invokes a fresh human dispatch — never anything else. Blocked:
    // no claim, no prepare, no repo.chat, visible input EXACTLY as-is; the
    // recorded blockedBeforeDispatch decision is the notDispatched evidence.
    // (Slash commands run through client commands upstream and the
    // auto-wake dispatch path is deliberately NOT gated: it has its own
    // server ledger and this gate would strand admitted batches.)
    if (!isWake && _connectivity() == ConnectivityHint.offline) {
      await _blockSendBeforeDispatch(rawDraft ?? spentDraft, retryOf: retryOf);
      return;
    }
    // R3 §5.3 ORDER: `old.retriedBy = <child id>` is recorded BEFORE the
    // child claim/journal exists. The claim mints the durable child id, so
    // the stamp is re-issued with it below (`replacing:`); once this stamp
    // stands, no second child can be created by any view.
    String? retryProvisionalId;
    if (retryOf != null) {
      retryProvisionalId = LocalStore.newAttemptId();
      final stamped = await _stampRetriedBy(retryOf, retryProvisionalId);
      if (_disposed) return;
      if (!stamped) {
        error = const UiMessage.local(MessageKey.chatSendNotDispatched);
        notifyListeners();
        return;
      }
    }
    var accepted = false;
    // NEW TURN identity (AUDIT-12): minted HERE, retired only by settle/dispose.
    // The busy state must be observable BEFORE the first await — every
    // background/foreground/detach contract already depends on that.
    final token = _turnToken = Object();
    _settledTurn = null;
    _settleGate = null;
    recoveryNotice = null;
    _budgetBegun = false;
    _budgetDeadline = null;
    _budgetRetryUsed = false;
    _lastActiveSeen = null;
    _bootRetryUsed = false;
    _bootHistoryAfterId = null;
    _localOwnedRunId = null;
    _turnSendAt = null;
    _turnSendWatermark = null;
    _turnServerEpoch = null;
    _wakeBatchInFlight = wakeBatch;
    _wakeAdopted = false;
    sendOutcome = null; // this attempt owns its outcome from here on
    storageNotice = null;
    // R3: the evidence bookkeeping is PER TURN — a new send never inherits
    // the previous attempt's mirror, ack flag or dispatch view.
    _turnAttemptId = null;
    _attemptMirror = null;
    _mirrorAttemptId = null;
    _journalAckRecorded = false;
    _dispatchInFlight = false;
    _stopDuringClaim = false;
    _stopDuringClaimDone = null;
    _localCleanupOnly = false;

    _beforeSend
      ..clear()
      ..addAll(messages.map((m) => m.id));
    pendingInput = suppressPending ? null : input;
    live = LiveTurn();
    final turn = live!;
    phase = ChatPhase.sending;
    error = null;
    _setStop(StopNotice.none);
    // SILENCE-DROP B1: transport-freshness clock rides the injectable seam
    // (same one the recovery deadlines use) so timing is testable.
    _lastEventAt = _clock();
    // SILENCE-DROP §3.1.6: a new turn inherits NO waiting seconds and NO
    // recovery cause from the previous one.
    _lastOutputAt = _clock();
    _waitingSeconds = null;
    _turnRecoveryCause = null;
    _pendingStart = true; // claim in flight: detach defers to the mint point
    _detachArmed = false;
    notifyListeners();
    // AUDIT-21 (D2): the pending slot is a CROSS-TAB resource — claim it
    // before the POST. A live lease held by another tab means this
    // conversation already runs there: retire this never-sent turn and
    // surface the conflict instead of double-sending. The claim
    // serializes through the same store transaction as compare-update
    // and clear.
    final pendingSince = DateTime.now();
    // B3: the max numeric history id visible before the POST — the row
    // watermark recovery uses to drop older same-text candidates.
    int? historyAfterId;
    for (final m in messages) {
      final n = int.tryParse(m.id);
      if (n != null && (historyAfterId == null || n > historyAfterId)) {
        historyAfterId = n;
      }
    }
    _bootHistoryAfterId = historyAfterId;
    _turnSendAt = pendingSince; // B3 arbitration window for this turn
    _turnSendWatermark = historyAfterId;
    _turnServerEpoch = observedActivity?.serverEpoch; // R3 §5.4
    String? claim;
    Object? claimError;
    try {
      claim = await store.claimPending(
        serverUrl,
        sid,
        userText: input,
        turnId: '${++_turnSeq}', // turn layer; the tab layer lives in the store
        startedAt: pendingSince,
        historyAfterId: historyAfterId,
        // APPWAKE: an auto-wake turn carries its origin + ledger batch so a
        // reload adopts it as a wake (system-line projection), not a ghost.
        origin: isWake ? 'autoWake' : null,
        wakeBatchId: wakeBatch,
      );
    } catch (e) {
      // R2 §4.4: a claim that THROWS (journal write refused) must converge
      // to an operable error — never a stuck `_pendingStart`, never a POST.
      claimError = e;
    }
    _pendingStart = false;
    if (_stopDuringClaim) {
      _stopDuringClaim = false;
      final done = _stopDuringClaimDone;
      _stopDuringClaimDone = null;
      StopResult result;
      if (claim == null) {
        result = const StopResult(StopResultKind.noTurn);
      } else if (claimError == null && identical(_turnToken, token)) {
        _pendingToken = claim;
        // §4.3: the stop intent wins BEFORE any repo.chat — end this claim
        // journal-first (tombstone, zero POST) and retire the turn.
        result = await _endLocalAttempt(
          token,
          store.loadPending(serverUrl, sid)?.attemptId ?? '',
        );
      } else {
        result = const StopResult(StopResultKind.failure);
      }
      if (done != null && !done.isCompleted) done.complete(result);
      notifyListeners();
      return;
    }
    if (_disposed) return;
    if (claimError != null) {
      _turnToken = null;
      live = null;
      pendingInput = null;
      phase = ChatPhase.idle;
      error = claimError is PendingPersistenceFailure
          ? const UiMessage.local(MessageKey.chatRecoveryStorageFailed)
          : const UiMessage.local(MessageKey.chatStateM020);
      notifyListeners();
      return;
    }
    if (claim == null || !identical(_turnToken, token)) {
      if (claim == null) {
        // Full roll-back: the POST never happened, so no ghost bubble,
        // no pending state, input stays where the user can see it.
        _turnToken = null;
        live = null;
        pendingInput = null;
        _localOwnedRunId = null;
        _turnSendAt = null;
        _turnSendWatermark = null;
        phase = ChatPhase.idle;
        error = const UiMessage.local(MessageKey.chatStateM020);
        notifyListeners();
      } else {
        sendOutcome = SendOutcome.stale; // the turn was replaced mid-claim
      }
      return;
    }
    _pendingToken = claim;
    // R2 §4.1/§4.3: persist the attempt snapshot (raw draft VERBATIM,
    // attachment blob refs, editor revision) into the claim's journal entry
    // BEFORE any POST — a crash now preserves the draft, not just the claim.
    if (!isWake) {
      final attemptId = store.loadPending(serverUrl, sid)?.attemptId;
      final entry = attemptId == null
          ? null
          : store.loadAttempt(serverUrl, sid, attemptId);
      if (attemptId == null || entry == null) {
        // A human claim without a journal entry means the snapshot write
        // could not be proven — dispatchIntent can therefore NOT be
        // persisted, and §5.2.4 forbids dispatching without it.
        await _retireNeverDispatched(token, claim: claim, storage: true);
        return;
      }
      _turnAttemptId = attemptId;
      _mirrorAttemptId = attemptId;
      // R3 §5.3: re-issue the parent's retriedBy with the REAL claim-minted
      // child id before anything dispatchable is written for this child.
      if (retryOf != null) {
        final corrected = await _stampRetriedBy(
          retryOf,
          attemptId,
          replacing: retryProvisionalId,
        );
        if (_disposed || !identical(_turnToken, token)) return;
        if (!corrected) {
          // Another view moved the parent (or claimed the slot) mid-flight:
          // this child never dispatches.
          await _retireNeverDispatched(token, claim: claim);
          return;
        }
      }
      // R3 §5.2.4: the pre-dispatch record. dispatchIntent/stage=prepared
      // rides the R2 snapshot write INSIDE saveAttempt's session-lock
      // transaction, after verifying the claim/attempt still belong to
      // THIS sender — a crash now lands conservative unknown (never a
      // "safe to retry" mislabel).
      final pendingNow = store.loadPending(serverUrl, sid);
      final stillMine =
          identical(_turnToken, token) &&
          pendingNow?.token == claim &&
          pendingNow?.attemptId == attemptId;
      final attempt = LocalAttempt(
        attemptId: attemptId,
        server: serverUrl,
        sid: sid,
        createdAt: entry.createdAt,
        origin: 'human',
        rawDraft: rawDraft ?? spentDraft,
        preparedInput: entry.preparedInput,
        attachmentSnapshots: store.attachments(serverUrl, sid),
        editorRevision: store.draftRevision(serverUrl, sid),
        historyAfterId: historyAfterId,
        // R3 §5.4: keep the epoch this watermark was taken under — once
        // the epoch moves, it can no longer hard-attribute rows.
        serverEpoch:
            entry.serverEpoch ??
            int.tryParse(observedActivity?.serverEpoch ?? ''),
        recoveryStartedAt: entry.recoveryStartedAt,
        recoveryDeadline: entry.recoveryDeadline,
        retryUsed: entry.retryUsed,
        draftRestoredRevision: entry.draftRestoredRevision,
        terminalEvidence: const {'dispatchIntent': true, 'stage': 'prepared'},
      );
      _attemptMirror = attempt;
      final recorded =
          stillMine && await store.saveAttempt(serverUrl, sid, attempt);
      if (!recorded) {
        // The mirror must not hold an intent the disk refused: it falls
        // back to the journal's own (conservative) entry.
        _attemptMirror = entry;
        // A persist refusal before the network call means: do NOT dispatch.
        // Settle honestly (own claim compare-cleared, draft kept); the
        // journal stays exactly as conservative as it already is. While
        // the write was in flight the turn may already have retired behind
        // a settlement (R2 baseline shape) — then nothing here decides
        // anything anymore and the loop's own guards finish the turn.
        if (!_disposed && identical(_turnToken, token)) {
          await _retireNeverDispatched(
            token,
            claim: claim,
            moved: !stillMine,
            storage: stillMine,
          );
          return;
        }
      }
      _dispatchInFlight = true;
    }
    _leaseTimer = Timer.periodic(leaseInterval, (_) => unawaited(_leaseTick()));
    if (_detachArmed) {
      _detachArmed = false;
      detach(); // the viewer left while the claim was in flight
    }
    // A wedged socket (Android kills it when the app backgrounds) neither
    // errors nor completes; without this timer the UI would sit in `sending`
    // forever, which is the "I typed and nothing happened" report.
    _silenceWatch = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_disposed) return;
      if (!identical(_turnToken, token)) {
        _silenceWatch?.cancel(); // stale timer: retire itself
        return;
      }
      // SILENCE-DROP §3.2 (last row): background/detached pages show no
      // waiting notice and arm no NEW silence recover — their existing
      // lifecycle/poll UX stays in charge.
      if (backgrounded || _detached || phase != ChatPhase.sending) return;
      final now = _clock();
      if (now.difference(_lastEventAt) > silenceLimit) {
        _silenceWatch?.cancel();
        unawaited(recover(cause: RecoveryCause.silence));
        return;
      }
      final out = _lastOutputAt;
      if (out != null && now.difference(out) > noOutputNoticeLimit) {
        final secs = now.difference(out).inSeconds;
        if (secs != _waitingSeconds) {
          // §3.1.2: repaint ONLY when the notice appears or its value moves.
          _waitingSeconds = secs;
          notifyListeners();
        }
      }
    });
    // R3 §5.2: a fresh observation sink for THIS dispatch attempt, staged
    // for the real repository's chat() (wake stages nothing — its ledger
    // verdict is a different evidence track). Callbacks are identity-
    // guarded here; the journal CAS (monotonic stage, first-wins fields)
    // runs in the merge queue.
    final observation = !isWake && _turnAttemptId != null
        ? _JournalObservation(this, token, _turnAttemptId!)
        : null;
    repo.stageChatObservation(sid, observation);
    try {
      await for (final event in repo.chat(sid, input, wakeBatch: wakeBatch)) {
        if (!accepted) {
          accepted = true;
          if (isWake) _wakePostHappened = true; // POST proven at the server
          if (!isWake) sendOutcome = SendOutcome.accepted; // first frame =
          // server accepted THIS attempt (R2 §4.3 composer decisions).
          // 送達即清: the first frame proves the server accepted this POST
          // (SSE opened), so the draft is spent NOW. Clearing only after this
          // future resolved missed every path where send() returns late or
          // never (detach→poll takeover, EOF→recover backoff) while the user
          // reopened the page and initState re-loaded the stale draft.
          if (!isWake &&
              spentDraft.isNotEmpty &&
              store.draft(serverUrl, sid) == spentDraft) {
            await store.saveDraft(serverUrl, sid, '');
          }
        }
        if (_disposed) return;
        if (!identical(live, turn) || !identical(_turnToken, token)) continue;
        _lastEventAt = _clock();
        if (event.type == 'heartbeat') {
          continue; // Silence-proof liveness, no repaint. Heartbeats refresh
          // transport freshness ONLY — the no-output clock keeps aging (§3.1.1).
        }
        // R3 §5.1: the first CONTRACT BUSINESS frame is this attempt's
        // server-side ack (journal: acknowledged + firstEventType). A
        // heartbeat never reaches this line: it proves a live response
        // stream, never a committed human row.
        if (!isWake && !_journalAckRecorded && _turnAttemptId != null) {
          _journalAckRecorded = true;
          _mergeAttemptEvidence(
            token,
            _turnAttemptId!,
            delivery: AttemptDelivery.acknowledged,
            firstEventType: event.type,
          );
        }
        // Real business output: reset BOTH clocks and drop the waiting
        // notice if it was showing (the notify below publishes it).
        _lastOutputAt = _clock();
        _waitingSeconds = null;
        live!.apply(event, sid);
        // APPROVALPUSH B3 (R6): the inbox watches the same frames; with the
        // capability ON the exact-request cards live in the panel (terminal
        // frames fail-close their pending cards too).
        if (event.type == 'approval.request' ||
            event.type == 'approval.responded' ||
            event.type == 'approval.resolved' ||
            _approvalTerminalEvent(event.type)) {
          await _routeApprovalInbox(event, live!);
        }
        if (event.type == 'run.started' && turn.runId != null) {
          // Amend the recovery record: after this, reload can poll
          // /v1/runs/{id} directly instead of guessing from history.
          // Stale-stream guard (AUDIT-12): never amend AFTER settlement or
          // for another turn; D2: amend is compare-and-update against
          // THIS tab's claim — a failed compare means another tab took
          // the shared record over, and this page stops writing it.
          if (!identical(_turnToken, token)) return;
          // GHOST-DUP B3: run.started of the CURRENT turn names this tab's
          // renderer owner — recorded before any await so the identity
          // retires the preview even if the store amend is slow.
          _localOwnedRunId = turn.runId;
          // R3 §5.1: run identity is POSITIVE evidence for this attempt —
          // save it in the journal alongside the ack (runId stays its own
          // field, never conflated with attemptId).
          if (!isWake && _turnAttemptId != null) {
            _journalAckRecorded = true;
            _mergeAttemptEvidence(
              token,
              _turnAttemptId!,
              delivery: AttemptDelivery.acknowledged,
              runId: turn.runId,
            );
          }
          final held = await store.amendPendingRun(
            serverUrl,
            sid,
            token: claim,
            userText: input,
            runId: turn.runId!,
            startedAt: pendingSince,
          );
          if (_disposed || !identical(_turnToken, token)) return;
          if (!held) {
            _losePendingOwnership(
              const UiMessage.local(MessageKey.chatStateM021),
            );
          }
          // GHOST-DUP (B3): this run's identity now exists — retire its
          // observation preview on THIS frame, before the notify below.
          _refreshUserProjections();
          // APPWAKE: the ledger batch is provably RUNNING now — advance the
          // mirror + receipt (fire-forget; failures never touch the turn).
          if (isWake) _wakeRunStarted(turn.runId);
        }
        // CROSSDEV-STOP R3 §6: a known NON-completed terminal frame ends
        // THIS turn immediately — settle exactly once through the shared
        // known-terminal path (token-guarded; the _settleTurn gate makes a
        // concurrent/duplicate settle a join, never a second one).
        // run.completed keeps its established EOF-tail flow: while its
        // settle GET is in flight the completed transcript represents the
        // turn (GHOST-DUP R11), and that path is frozen behaviour.
        final terminal = turn.terminalStatus;
        if (terminal != null && terminal != 'completed') {
          await _convergeKnownTerminal(token, turn, state: terminal);
          return;
        }
        notifyListeners();
      }
      if (_disposed || !identical(live, turn)) return;
      if (_detached) return; // socket cut on purpose; _pollRun owns the outcome
      if (!turn.completed) {
        // SILENCE-DROP §3.1.4: unfinished EOF is an OBSERVED stream end —
        // route it straight to recovery with a typed cause instead of a
        // generic M022 throw, so the backoff says "reply stream ended",
        // not "the socket died". The `busy && token` guard kills the
        // settle race: when settlement's own cancelStream delivers this
        // `done`, the turn may already be retired — never resurrect a
        // recovery loop for a settled turn (it would strand on a zombie
        // phase AFTER idle).
        if (busy && identical(_turnToken, token)) {
          // CROSSDEV-STOP R3 §6: an EOF that carried NO terminal frame is
          // still an OBSERVED end of THIS stream — read the SAME run's
          // status once. A known terminal status converges through the
          // same known-terminal path (never inferred from assistant text);
          // a live/unknown/unreadable status leaves the EXISTING bounded
          // unconfirmed recovery below exactly as it was.
          // The `busy && token` race guard, same as the recover call below:
          // settlement's own cancelStream can deliver this EOF while the
          // gate is still publishing — a settle already in flight is
          // terminal, so neither the probe nor a recovery may start.
          if (!identical(_settledTurn, token)) {
            final runId = turn.runId;
            if (!turn.queued &&
                runId != null &&
                runId.isNotEmpty &&
                await _eofStatusConvergence(token, turn, runId)) {
              return;
            }
          }
          // UPD-COMPAT §4: an EOF after run.queued is the stream ending ON
          // PURPOSE while a live owner still holds the delivery — route it to
          // the neutral read-only reconcile (never "connection lost", never a
          // re-POST). A plain unfinished EOF stays an observed stream end.
          await recover(
            cause: turn.queued
                ? RecoveryCause.recheck
                : RecoveryCause.streamEnded,
          );
        }
        return;
      }
      await _finish(token: token);
    } on ApiException catch (e) {
      if (_disposed || !identical(live, turn) || _detached) return;
      if (isWake) _wakePostHappened = true; // a response = the POST arrived
      if (isWake && (e.status == 409 || e.status == 410)) {
        // APPWAKE C read-only recovery: the ledger already knows about this
        // batch (409 in-flight / 410 consumed-released). NEVER re-POST.
        // Reconcile history (a committed canonical anchor is proof of
        // acceptance) and land the batch honestly.
        await _wakeGateVerdict(wakeBatch, e.status!, token);
        return;
      }
      // R3 §5.1: structured never-dispatched evidence outranks any error
      // wording — the underlying call provably never ran, so this is the
      // notDispatched card, NOT an observation window (recovery is for
      // outcomeUnknown stretches only). No exception STRING is consulted.
      if (!isWake && observation?.neverDispatched == true) {
        await _evidenceQueue;
        await _retireNeverDispatched(token, claim: claim);
        return;
      }
      if (e.status != null && e.status! >= 400 && e.status! < 500) {
        // 4xx = the server rejected the POST outright: nothing to recover.
        // Settle through the gate so the send gate stays shut until the
        // pending record is really cleared (AUDIT-12/04).
        sendOutcome = SendOutcome.rejected;
        // R3 §5.1: rejected is journal evidence too — status comes from
        // the recorded headers, flushed BEFORE the settle retires the turn.
        if (!isWake && _turnAttemptId != null) {
          _mergeAttemptEvidence(
            token,
            _turnAttemptId!,
            delivery: AttemptDelivery.rejected,
            stage: TransportStage.headersReceived,
            httpStatus: e.status,
            failureKind: 'http${e.status}',
          );
          await _evidenceQueue;
        }
        await _settleTurn(
          token,
          errorMessage: UiMessage.local(
            MessageKey.chatStateM023,
            args: {'error': e.uiMessage},
          ),
          reason: SettlementReason.rejected,
        );
        // Keep input visible to the user; no automatic retry of a mutation.
      } else if (busy && identical(_turnToken, token)) {
        // Same retire-guard as the EOF tail: an error racing a settlement
        // must not fork a second observation of a retired turn.
        await recover(cause: RecoveryCause.streamError);
      }
    } catch (e) {
      if (_disposed || !identical(live, turn) || _detached) return;
      // R3 §5.1/§5.2.6: same structured checks as the ApiException path —
      // never-dispatched evidence wins outright, and a 4xx whose HEADERS
      // were recorded before a throwing body drain stays REJECTED (with
      // its status), never downgraded to an unknown stretch.
      if (!isWake && observation?.neverDispatched == true) {
        await _evidenceQueue;
        await _retireNeverDispatched(token, claim: claim);
        return;
      }
      final drain4xx =
          !isWake &&
              observation != null &&
              observation.httpStatus != null &&
              observation.httpStatus! >= 400 &&
              observation.httpStatus! < 500
          ? observation.httpStatus
          : null;
      if (drain4xx != null && _turnAttemptId != null) {
        sendOutcome = SendOutcome.rejected;
        _mergeAttemptEvidence(
          token,
          _turnAttemptId!,
          delivery: AttemptDelivery.rejected,
          stage: TransportStage.headersReceived,
          httpStatus: drain4xx,
          failureKind: 'drainError',
        );
        await _evidenceQueue;
        await _settleTurn(
          token,
          errorMessage: UiMessage.local(
            MessageKey.chatStateM023,
            args: {'error': messageForError(e)},
          ),
          reason: SettlementReason.rejected,
        );
        return;
      }
      if (busy && identical(_turnToken, token)) {
        await recover(cause: RecoveryCause.streamError);
      }
    } finally {
      if (identical(live, turn) || live == null) _silenceWatch?.cancel();
    }
    notifyListeners();
  }

  // ---- R3 §5.2: dispatch-evidence plumbing --------------------------------

  /// The offline short-circuit (§5.2.2): mint the attempt identity, persist
  /// it with the app's OWN decision not to dispatch, and stop there.
  /// delivery=notDispatched is earned by THIS record (never by the hint
  /// alone at render time); zero mutation POSTs by construction — nothing
  /// network-shaped runs between here and the return.
  Future<void> _blockSendBeforeDispatch(
    String rawDraft, {
    String? retryOf,
  }) async {
    // A retry that short-circuits offline still CONSUMES the parent: the
    // retriedBy stamp is written before this child record exists, so no
    // second child can ever be created (crash or second view alike).
    final attemptId = LocalStore.newAttemptId();
    if (retryOf != null) {
      if (!await _stampRetriedBy(retryOf, attemptId)) {
        if (!_disposed) {
          error = const UiMessage.local(MessageKey.chatSendNotDispatched);
          notifyListeners();
        }
        return;
      }
    }
    _turnAttemptId = attemptId;
    _mirrorAttemptId = attemptId;
    sendOutcome = null;
    storageNotice = null;
    final attempt = LocalAttempt(
      attemptId: attemptId,
      server: serverUrl,
      sid: sid,
      createdAt: _clock(),
      origin: 'human',
      rawDraft: rawDraft,
      attachmentSnapshots: store.attachments(serverUrl, sid),
      editorRevision: store.draftRevision(serverUrl, sid),
      disposition: AttemptDisposition.waiting,
      delivery: AttemptDelivery.notDispatched,
      terminalEvidence: const {
        'stage': 'prepared',
        'decision': 'blockedBeforeDispatch',
      },
    );
    _attemptMirror = attempt; // the card is honest even if the write fails
    _evidenceQueue = _evidenceQueue.then((_) async {
      if (!await store.saveAttempt(serverUrl, sid, attempt)) {
        storageNotice = const UiMessage.local(
          MessageKey.chatRecoveryStorageFailed,
        );
      }
    });
    await _evidenceQueue;
    // The draft/attachments are untouched by definition (nothing consumed
    // them); phase never left idle — no bubble, no dots, no SSE.
    error = const UiMessage.local(MessageKey.chatSendOffline);
    notifyListeners();
  }

  /// A turn that provably never dispatched retires WITHOUT a ghost: the
  /// in-memory state rolls back, OWN claim is compare-cleared (a moved
  /// record is left exactly alone), the journal keeps whatever conservative
  /// record it already holds, and the draft stays visible. `moved` (another
  /// tab owns the record now) and `storage` (the pre-dispatch write was
  /// refused) land with their own honest wordings.
  Future<void> _retireNeverDispatched(
    Object? token, {
    String? claim,
    bool moved = false,
    bool storage = false,
  }) async {
    if (!moved && claim != null) {
      // Best-effort: a refused compare-clear leaves the record (reload
      // re-observes it read-only) — never a pretend-clean settle.
      try {
        await store.clearPending(serverUrl, sid, token: claim);
      } catch (_) {}
    }
    if (_disposed || !identical(_turnToken, token)) return;
    _turnToken = null;
    live = null;
    pendingInput = null;
    _localOwnedRunId = null;
    _turnSendAt = null;
    _turnSendWatermark = null;
    _turnServerEpoch = null;
    _dispatchInFlight = false;
    _leaseTimer?.cancel();
    _leaseTimer = null;
    _silenceWatch?.cancel();
    _silenceWatch = null;
    _wakeBatchInFlight = null;
    phase = ChatPhase.idle;
    error = UiMessage.local(
      moved
          ? MessageKey.chatStateM021
          : storage
          ? MessageKey.chatRecoveryStorageFailed
          : MessageKey.chatSendNotDispatched,
    );
    notifyListeners();
  }

  /// Queue one structured-evidence merge into the attempt journal: stage is
  /// a monotonic CAS, httpStatus/firstEventType/failureKind are first-wins
  /// (a later error never overwrites a recorded fact), and every field the
  /// journal already holds is PRESERVED — this never rewrites history.
  /// The turn token is checked at enqueue AND again inside the serialized
  /// transaction (red line 8). Decision points `await _evidenceQueue`
  /// before retiring the token so a just-queued merge can never be lost.
  void _mergeAttemptEvidence(
    Object? token,
    String attemptId, {
    AttemptDelivery? delivery,
    TransportStage? stage,
    int? httpStatus,
    String? firstEventType,
    String? runId,
    String? failureKind,
    Map<String, Object?> evidence = const {},
  }) {
    if (_disposed || !identical(_turnToken, token)) return;
    _evidenceQueue = _evidenceQueue.then((_) async {
      if (_disposed || !identical(_turnToken, token)) return;
      final journal = store.loadAttempt(serverUrl, sid, attemptId);
      if (journal == null) return; // entry is gone: never resurrect one here
      final ev = Map<String, dynamic>.from(
        journal.terminalEvidence ?? const {},
      );
      if (stage != null) {
        final cur = _stageNamed(ev['stage']);
        if (cur == null || cur.index < stage.index) ev['stage'] = stage.name;
      }
      if (httpStatus != null) ev['httpStatus'] ??= httpStatus;
      if (firstEventType != null) ev['firstEventType'] ??= firstEventType;
      if (failureKind != null) ev['failureKind'] ??= failureKind;
      ev.addAll(evidence);
      final next = LocalAttempt(
        attemptId: journal.attemptId,
        server: journal.server,
        sid: journal.sid,
        createdAt: journal.createdAt,
        origin: journal.origin,
        rawDraft: journal.rawDraft,
        preparedInput: journal.preparedInput,
        attachmentSnapshots: journal.attachmentSnapshots,
        editorRevision: journal.editorRevision,
        disposition: journal.disposition,
        delivery: delivery ?? journal.delivery,
        runId: runId ?? journal.runId,
        historyAfterId: journal.historyAfterId,
        serverEpoch: journal.serverEpoch,
        recoveryStartedAt: journal.recoveryStartedAt,
        recoveryDeadline: journal.recoveryDeadline,
        retryUsed: journal.retryUsed,
        draftRestoredRevision: journal.draftRestoredRevision,
        terminalEvidence: ev,
      );
      _mirrorAttemptId = attemptId;
      _attemptMirror = next; // positive evidence lives even if the write dies
      if (!await store.saveAttempt(serverUrl, sid, next)) {
        storageNotice = const UiMessage.local(
          MessageKey.chatRecoveryStorageFailed,
        );
        if (!_disposed) notifyListeners();
      }
    });
  }

  static TransportStage? _stageNamed(Object? raw) {
    if (raw is! String) return null;
    for (final t in TransportStage.values) {
      if (t.name == raw) return t;
    }
    return null;
  }

  /// D2: another tab's token now owns the shared pending record. Stop the
  /// heartbeat and every future write; the run this page is already
  /// watching is server-side truth and keeps streaming — the page just
  /// stops pretending to own the ledger (settle's clear then compares
  /// against `null` and leaves the other tab's record alone).
  void _losePendingOwnership(UiMessage message) {
    _leaseTimer?.cancel();
    _leaseTimer = null;
    _pendingToken = null;
    // R2: stop claiming — but an already-accepted attempt keeps its
    // accepted outcome (the composer must not double-clear a delivered
    // send's attachments).
    sendOutcome ??= SendOutcome.lostOwnership;
    _waitingSeconds =
        null; // SILENCE-DROP §3.1.6: ownership loss resets UX state
    _turnRecoveryCause = null;
    error = message;
    notifyListeners();
  }

  Future<void> _leaseTick() async {
    if (_disposed) return;
    final token = _pendingToken;
    if (!busy || token == null) {
      _leaseTimer?.cancel();
      _leaseTimer = null;
      return;
    }
    final held = await store.touchPending(serverUrl, sid, token);
    if (_disposed) return;
    if (!held) {
      _losePendingOwnership(const UiMessage.local(MessageKey.chatStateM021));
    }
  }

  /// soft (AUDIT-05③): a known-terminal run's history GET failure must not
  /// leave busy+empty-schedule — settle anyway with a retry hint. The live
  /// SSE path stays strict (throw → recover backoff retries the read).
  Future<void> _finish({bool soft = false, Object? token}) async {
    final t = token ?? _turnToken;
    List<Message>? page;
    Object? pageError;
    try {
      page = await repo.messages(sid);
    } catch (e) {
      if (!soft) rethrow;
      pageError = e;
    }
    await _settleTurn(
      t,
      page: page,
      errorMessage: pageError == null
          ? null
          : const UiMessage.local(MessageKey.chatStateM024),
    );
  }

  /// CROSSDEV-STOP R3 §6: the known terminal statuses of a run (contract
  /// set — same membership as ActivityRun.isTerminal). Status WORDING is
  /// derived from these values, never from assistant text.
  static const _knownTerminalStatuses = {
    'completed',
    'cancelled',
    'failed',
    'interrupted',
  };

  /// R3 §6: the EOF-without-terminal-frame probe — ONE runStatus read for
  /// THIS turn's own run. True = the turn converged (or moved on); false =
  /// status stayed live/unknown/unreadable, so the caller keeps the
  /// EXISTING bounded unconfirmed recovery untouched.
  Future<bool> _eofStatusConvergence(
    Object? token,
    LiveTurn turn,
    String runId,
  ) async {
    Json status;
    try {
      status = await repo.runStatus(runId);
    } catch (_) {
      return false; // status/network unavailable: never fabricate one
    }
    if (_disposed || !identical(_turnToken, token) || !identical(live, turn)) {
      return true; // the turn already moved on: nothing left to decide
    }
    final state = status['status'];
    if (state is! String || !_knownTerminalStatuses.contains(state)) {
      return false; // live/unknown: the bounded recovery decides, as before
    }
    await _convergeKnownTerminal(token, turn, state: state, status: status);
    return true;
  }

  /// R3 §6: the ONE known-terminal convergence for the live SSE turn,
  /// whichever observer found the terminal (terminal frame or EOF status).
  /// Provenance is the turn's OWN stop record — a sender WITHOUT one shows
  /// the neutral server-ended wording, NEVER 「已由你停止」; failed/interrupted
  /// surface their own status honestly. SETTLE FIRST: a later history GET
  /// is bounded best-effort and can never resurrect busy or extend any
  /// recovery (token-guarded merge on an idle, un-replaced page only).
  Future<void> _convergeKnownTerminal(
    Object? token,
    LiveTurn turn, {
    required String state,
    Json? status,
  }) async {
    if (_disposed || !identical(_turnToken, token) || !identical(live, turn)) {
      return;
    }
    turn.terminalStatus = state;
    turn.completed = true;
    UiMessage? settleError;
    if (state == 'cancelled') {
      final runId = turn.runId;
      final mine =
          runId != null && runId.isNotEmpty && _stopRequestedFor(runId);
      _setStop(
        mine ? StopNotice.accepted : StopNotice.serverEnded,
        UiMessage.local(
          mine ? MessageKey.chatStateStoppedByYou : MessageKey.chatStateM012,
        ),
      );
    } else if (state == 'failed' || state == 'interrupted') {
      final detail = status?['error'] ?? turn.terminalDetail;
      settleError = UiMessage.local(
        MessageKey.chatStateM018,
        args: {
          'detail': detail is String && detail.isNotEmpty
              ? UiMessage.raw(detail)
              : const UiMessage.local(MessageKey.chatStateM017),
        },
      );
    }
    await _settleTurn(token, errorMessage: settleError);
    await _mergeTerminalHistory();
  }

  /// R3 §6: the best-effort history merge AFTER a known-terminal settle.
  /// It never touches phase/busy — a failing read adds only the honest
  /// "history unreadable" notice; a never-completing read leaves NOTHING
  /// pending here (no timer, no retry armed); a new turn or a disposed
  /// controller discards the late page outright.
  Future<void> _mergeTerminalHistory() async {
    List<Message> page;
    try {
      page = await repo.messages(sid);
    } catch (_) {
      if (_disposed || busy || live != null) return;
      error = const UiMessage.local(MessageKey.chatStateM024);
      notifyListeners();
      return;
    }
    if (_disposed || busy || live != null || _turnToken != null) return;
    messages = mergeMessages([], page);
    _offset = page.length;
    hasOlder = page.length == 200;
    _refreshUserProjections();
    notifyListeners();
  }

  /// AUDIT-12: the ONE idempotent settlement gate per turn. Every terminal
  /// exit — SSE finish, poll settle, stop settle, bootstrap settle, reconcile
  /// settle, 4xx rejection — funnels here:
  ///   1. while it runs the send gate stays shut (phase is still busy),
  ///   2. this turn's schedulers/streams die, and ONLY this turn's lost/
  ///      pending records are cleared (a failure leaves them as retry
  ///      evidence — never pretend-clean, never stuck busy),
  ///   3. the turn token retires and the final messages/error publish with a
  ///      REAL idle notification (AUDIT-04).
  Future<bool> _settleTurn(
    Object? token, {
    List<Message>? page,
    UiMessage? errorMessage,
    SettlementReason reason = SettlementReason.serverTerminal,
  }) async {
    if (_disposed) return false;
    if (identical(_settledTurn, token)) {
      final gate = _settleGate;
      if (gate != null)
        return gate; // same turn settling (again): join, never double-clear
    }
    if (!identical(_turnToken, token))
      return false; // not my turn anymore: no-op
    _settledTurn = token;
    final gate = _settleCore(
      token,
      page: page,
      errorMessage: errorMessage,
      reason: reason,
    );
    _settleGate = gate;
    return gate;
  }

  Future<bool> _settleCore(
    Object? token, {
    List<Message>? page,
    UiMessage? errorMessage,
    SettlementReason reason = SettlementReason.serverTerminal,
  }) async {
    // 1) Kill every scheduler/stream of this turn while busy still holds.
    _watchTimer?.cancel();
    _watchTimer = null;
    _silenceWatch?.cancel();
    _silenceWatch = null;
    _cancelBootstrapWaiting();
    _stopping = false;
    _stopRunId = null;
    _stopFails = 0;
    _detached = false;
    _pollCapped = false;
    _pollTickBusy = false;
    stopBusy = false;
    _recoveryEpoch++; // abandon stragglers of THIS turn
    _recovery = null;
    repo.releaseStreamKeepalive(sid);
    repo.cancelStream(sid);
    // 2) Turn-scoped persistence. A failed cleanup leaves the record (the
    //    next bootstrap reconsiders it read-only) instead of either stranding
    //    busy or claiming a clean settle. D2: the clear is COMPARE-AND-
    //    DELETE — a record another tab has since claimed stays theirs (the
    //    cleanupFailed path's "本機會自動重試" wording covers it honestly:
    //    the next bootstrap re-observes, never fabricates a clean settle).
    _leaseTimer?.cancel();
    _leaseTimer = null;
    var cleanupFailed = false;
    if (reason == SettlementReason.localAbandonment) {
      // The pending record was already cleared (or explicitly left in
      // place as evidence) by endLocalAttempt's journal-first ordering —
      // the gate must NOT issue a second, tombstone-less clear.
      _localCleanupOnly = false;
    } else {
      // R2 §4.3: a server-terminal settle of an attempt whose FIRST FRAME
      // was seen has positive delivery evidence — stamp it into the journal
      // (evidence only, disposition stays R2-conservative) so the snapshot
      // never resurfaces as a restore offer. Unknown outcomes keep it.
      final deliveredAttemptId = sendOutcome == SendOutcome.accepted
          ? store.loadPending(serverUrl, sid)?.attemptId
          : null;
      try {
        await store.clearLost(serverUrl, sid);
      } catch (_) {
        cleanupFailed = true;
      }
      try {
        if (!await store.clearPending(serverUrl, sid, token: _pendingToken)) {
          cleanupFailed = true;
        }
      } catch (_) {
        cleanupFailed = true;
      }
      if (!cleanupFailed && deliveredAttemptId != null) {
        final entry = store.loadAttempt(serverUrl, sid, deliveredAttemptId);
        if (entry != null &&
            entry.disposition == AttemptDisposition.waiting &&
            entry.terminalEvidence?['accepted_frame'] != true) {
          await store.saveAttempt(
            serverUrl,
            sid,
            LocalAttempt(
              attemptId: entry.attemptId,
              server: entry.server,
              sid: entry.sid,
              createdAt: entry.createdAt,
              origin: entry.origin,
              rawDraft: entry.rawDraft,
              preparedInput: entry.preparedInput,
              attachmentSnapshots: entry.attachmentSnapshots,
              editorRevision: entry.editorRevision,
              disposition: entry.disposition,
              delivery: entry.delivery,
              runId: entry.runId,
              historyAfterId: entry.historyAfterId,
              serverEpoch: entry.serverEpoch,
              recoveryStartedAt: entry.recoveryStartedAt,
              recoveryDeadline: entry.recoveryDeadline,
              retryUsed: entry.retryUsed,
              draftRestoredRevision: entry.draftRestoredRevision,
              terminalEvidence: {
                ...?entry.terminalEvidence,
                'accepted_frame': true,
              },
            ),
          );
        }
      }
    }
    _pendingToken = null;
    _budgetBegun = false;
    _budgetDeadline = null;
    _budgetRetryUsed = false;
    _lastActiveSeen = null;
    _bootRetryUsed = false;
    _bootHistoryAfterId = null;
    // SILENCE-DROP §3.1.6: settle retires the waiting notice and the turn's
    // recovery cause with the rest of the turn's state.
    _turnRecoveryCause = null;
    _waitingSeconds = null;
    _lastOutputAt = null;
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
    _countdownTicker?.cancel();
    _countdownTicker = null;
    // 3) Publish + release. Only dispose can race here: send can't, the gate
    //    held busy across step 2.
    if (_disposed || !identical(_turnToken, token)) {
      return reason == SettlementReason.localAbandonment || !cleanupFailed;
    }
    if (page != null) {
      messages = mergeMessages([], page);
      _offset = page.length;
      hasOlder = page.length == 200;
    }
    live = null;
    pendingInput = null;
    _localOwnedRunId = null; // GHOST-DUP B3: the turn is over; so is ownership
    _turnSendAt = null;
    _turnSendWatermark = null;
    _turnServerEpoch = null;
    _turnToken = null; // retire every late continuation of this turn
    phase = ChatPhase.idle;
    // A cleanup failure must not swallow the "ended without a final"
    // notice (B2): the notice keeps its own field so BOTH can show.
    recoveryNotice = cleanupFailed ? errorMessage : null;
    error = cleanupFailed
        ? const UiMessage.local(MessageKey.chatStateM025)
        : errorMessage;
    _refreshUserProjections(); // GHOST-DUP B1: settle publishes state AND
    // projections together — one final frame, never a half-cleared overlay.
    notifyListeners(); // AUDIT-04: terminals always notify
    // 4) APPWAKE: an auto-wake turn that reached a SETTLED end closes its
    //    ledger batch (fire-forget terminal ack), then the queue gets its
    //    next chance now that the session is idle again.
    //    R2 §4.2 (A8): a LOCAL abandonment is not a server terminal — it
    //    may never ack the wake ledger nor re-arm the queue dispatch.
    final wakeBatch = _wakeBatchInFlight;
    final adoptedWake = _wakeAdopted;
    _wakeBatchInFlight = null;
    _wakeAdopted = false;
    if (reason != SettlementReason.localAbandonment) {
      if (wakeBatch != null &&
          (adoptedWake || _wake?.batch(wakeBatch) != null)) {
        unawaited(_wakeTerminalAck(wakeBatch));
      }
      if (!_disposed &&
          ((_wake?.state?['queued']) as List?)?.isNotEmpty == true) {
        _wakeSchedule(); // queued reports get their chance now that we're idle
      }
    }
    return reason == SettlementReason.localAbandonment || !cleanupFailed;
  }

  /// Contract has NO replay/resume SSE endpoint. Reconnect read-only history
  /// with 1,2,4,8,16,30s delays; never replay a possibly accepted chat POST.
  /// Original completion frames take precedence; otherwise require a persisted
  /// final after this exact new user row. No terminal run status assumptions.
  ///
  /// SILENCE-DROP §3.1.3: `cause` only selects WORDING. The default stays
  /// neutral so generic callers never claim a connection drop; single-flight
  /// means an in-flight loop is never forked — an explicit stream failure
  /// arriving mid-loop merely upgrades the turn's cause for later rounds.
  Future<void> recover({RecoveryCause cause = RecoveryCause.recheck}) {
    if (_disposed || !busy) return Future.value();
    // A settlement for THIS turn is already in flight (the gate opened):
    // its outcome is terminal — starting a loop now would fork a zombie
    // behind it (_settleCore already cleared _recovery while busy is still
    // true mid-publish).
    if (identical(_settledTurn, _turnToken)) return Future.value();
    if (_recovery != null) {
      _noteRecoveryCause(cause); // upgrade wording, never fork a loop
      return _recovery!;
    }
    _noteRecoveryCause(cause);
    // §5.3: once a recovery loop opens, the neutral "dispatching" view ends —
    // from here on the attempt reads as its recorded delivery (unknown).
    _dispatchInFlight = false;
    reconnects++;
    final epoch = ++_recoveryEpoch;
    final task = _recover(epoch);
    _recovery = task;
    return task.whenComplete(() {
      if (epoch == _recoveryEpoch) _recovery = null;
    });
  }

  void _noteRecoveryCause(RecoveryCause cause) {
    final explicit =
        cause == RecoveryCause.streamEnded ||
        cause == RecoveryCause.streamError;
    if (explicit && !_observedStreamFailure) {
      _turnRecoveryCause = cause; // neutral → observed failure: upgrade
    } else {
      _turnRecoveryCause ??= cause; // first cause of this turn wins
    }
    // neutral causes never downgrade an observed stream failure.
  }

  Future<void> _recover(int epoch) async {
    final token = _turnToken;
    _silenceWatch?.cancel();
    repo.releaseStreamKeepalive(sid);
    phase = ChatPhase.recovering;
    // R1 §3.3.2: the live-recovery path shares the SAME begin-once
    // persisted budget gate — the 1/2/4/8/16/30 ladder stays the GET
    // cadence, but the total UI wait is bounded by the absolute deadline.
    if (await _ensureBudgetBegun(token)) return;
    if (!_owns(token) || epoch != _recoveryEpoch) return;
    _armDeadlineTimer();
    for (final seconds in [1, 2, 4, 8, 16, 30]) {
      if (!_owns(token) || epoch != _recoveryEpoch) return;
      final budget = _budgetDeadline;
      if (budget != null && !_clock().isBefore(budget)) {
        // The window (initial or the ONE consumed re-check) ended
        // mid-backoff: publish uncertain IMMEDIATELY from the retry-flag
        // snapshot — a hanging final GET must never delay the landing
        // (R1 §3.3.3). The WEBSYNC F1 read-only landing check may only
        // REFINISH the wording afterwards.
        final retryUsed = _bootActive ? _bootRetryUsed : _budgetRetryUsed;
        final whenAbsent = retryUsed
            ? MessageKey.chatRecoveryExhausted
            : MessageKey.chatRecoveryUncertain;
        _deadlineTimer?.cancel();
        _deadlineTimer = null;
        phase = ChatPhase.uncertain;
        error = UiMessage.local(whenAbsent);
        notifyListeners();
        await _uncertainTerminal(token, epoch, whenAbsent: whenAbsent);
        return;
      }
      error = UiMessage.local(
        // SILENCE-DROP §3.2: the wording rides the cause observed SO FAR —
        // re-read every round, because a late EOF/error upgrades a neutral
        // backoff that started as silence/recheck.
        _observedStreamFailure
            ? MessageKey.chatStateM026
            : MessageKey.chatStreamChecking,
        args: {'seconds': seconds},
      );
      notifyListeners();
      await wait(Duration(seconds: seconds));
      if (!_owns(token) || epoch != _recoveryEpoch) return;
      try {
        if (await _reconcile(epoch: epoch)) return;
      } catch (_) {
        /* Next read-only reconnect attempt. */
      }
      if (!_owns(token) || epoch != _recoveryEpoch) return;
    }
    if (!_owns(token) || epoch != _recoveryEpoch) return;
    // WEBSYNC F1 (three-state split): SILENCE-DROP §3.2 rows 6-7 already
    // stopped claiming "dropped" for neutral causes; F1 runs ONE final
    // read-only landing check. R1 §3.3.3: the uncertain state and its
    // wording are PUBLISHED first so a hanging refinement GET can never
    // strand the page; the GET may only refine afterwards.
    final whenAbsent = _observedStreamFailure
        ? MessageKey.chatStreamUnavailable
        : MessageKey.chatStreamUnconfirmed;
    phase = ChatPhase.uncertain;
    error = UiMessage.local(whenAbsent);
    notifyListeners();
    try {
      await store.markLost(serverUrl, sid);
    } catch (_) {}
    if (!_owns(token) || epoch != _recoveryEpoch) return;
    await _uncertainTerminal(token, epoch, whenAbsent: whenAbsent);
  }

  /// WEBSYNC F1 terminus shared by every exhausted-recovery path: one more
  /// READ-ONLY reconciliation (history GET), then the three-state wording.
  /// Acceptance evidence is POSITIVE only — a unique anchor in the freshly
  /// read page (or a run the server acknowledged) — never inferred from a
  /// failed or empty-and-never-checked read.
  Future<void> _uncertainTerminal(
    Object? token,
    int epoch, {
    required MessageKey whenAbsent,
  }) async {
    phase = ChatPhase.uncertain;
    List<Message>? page;
    try {
      final fresh = await repo.messages(sid);
      if (!_owns(token) || epoch != _recoveryEpoch) return;
      page = fresh;
      messages = mergeMessages([], fresh);
      _offset = fresh.length;
      hasOlder = fresh.length == 200;
    } catch (_) {
      // The check itself failed: fall back to the rows already in view
      // (they are still positive evidence if the anchor happens to be in
      // them) — absence is never concluded from a failed read.
      page = List<Message>.from(messages);
    }
    if (!_owns(token) || epoch != _recoveryEpoch) return;
    // R3 §5.4/A12: for an attempt-backed attempt the anchor is strict and
    // an AMBIGUOUS read can never be upgraded to "delivered" — only a
    // strict unique anchor or this turn's acknowledged run identity may
    // use the delivered wording.
    final backed = _turnAttemptBacked;
    final inspection = inspectPendingHistory(
      rows: page,
      pendingText: pendingInput,
      excludeIds: _beforeSend,
      historyAfterId: backed
          ? (_turnSendWatermark ?? _evidenceAttempt?.historyAfterId)
          : null,
      attemptBacked: backed,
      epochMoved:
          backed && (_sendEpochMoved || _attemptEpochMoved(_evidenceAttempt)),
    );
    final landed =
        (backed
            ? inspection.anchorFound
            : inspection.anchorFound || inspection.ambiguous) ||
        live?.runId != null;
    _refreshUserProjections();
    error = landed
        ? const UiMessage.local(MessageKey.chatDeliveredReplyLoading)
        : UiMessage.local(whenAbsent);
    notifyListeners();
  }

  /// Single-flight across EVERY caller (AUDIT-11) — but WEBSYNC-R1 §3.3.4:
  /// the flight is keyed by observation epoch. A NEW epoch never joins an
  /// old (possibly hung) future, and the old flight's completion may not
  /// clear the newer slot.
  int? _reconcileFlightEpoch;
  Future<bool> _reconcile({int? epoch}) {
    final e = epoch ?? _recoveryEpoch;
    final flight = _reconcileFlight;
    if (flight != null && _reconcileFlightEpoch == e) return flight;
    final task = _reconcileNow(e);
    _reconcileFlight = task;
    _reconcileFlightEpoch = e;
    return task.whenComplete(() {
      if (identical(_reconcileFlight, task)) {
        _reconcileFlight = null;
        _reconcileFlightEpoch = null;
      }
    });
  }

  Future<bool> _reconcileNow(int epoch) async {
    final turn = live;
    final token = _turnToken;
    final page = await repo.messages(sid);
    if (!_owns(token) || epoch != _recoveryEpoch) return false;
    if (!identical(live, turn)) return false;
    messages = mergeMessages([], page);
    _offset = page.length;
    hasOlder = page.length == 200;
    // Shared matcher (B1): the pending text in the SAME folded comparison
    // as bootstrap/claims; _beforeSend is this turn's row watermark.
    // R3 §5.4 note: settling on a FINAL LANDING here is the turn's state-
    // card settlement (allowed for every record shape); the delivered/
    // hide/claim decisions are tightened separately. A text-only anchor
    // may settle the state card but never deletes or rewrites history.
    final inspection = inspectPendingHistory(
      rows: page,
      pendingText: pendingInput,
      excludeIds: _beforeSend,
    );
    // hasFinal requires a strict anchor under attempt-backed rules; a
    // completed live turn is settled by its own identity, as before.
    if (live?.completed == true || inspection.hasFinal) {
      await _settleTurn(token, page: page); // AUDIT-04: settle notifies idle
      return true;
    }
    // GHOST-DUP B1: the replaced page may retire previews or deliver the
    // pending row — republish projections + state with the SAME frame the
    // caller's flow expects; a settled claim must not wait for the next
    // visible event.
    _refreshUserProjections();
    notifyListeners();
    return false;
  }

  /// Reopening a session that previously died mid-turn: check whether a later
  /// final answer exists anyway, otherwise surface the interruption banner.
  /// Reached from bootstrap only, and never while a pending turn says the run
  /// is still alive (no false "interrupted" banner over a living turn).
  Future<void> _reconcileLost() async {
    if (messages.isEmpty) return;
    final last = messages.last;
    if (last.role == 'assistant' && last.toolCalls.isEmpty) {
      await store.clearLost(serverUrl, sid);
      if (_disposed) return;
      // The final is here: the stale interruption banner must die with the
      // flag (stale-banner defect — clearing lost used to leave the notice).
      _setStop(StopNotice.none);
      return;
    }
    _setStop(StopNotice.lost, const UiMessage.local(MessageKey.chatStateM028));
  }

  Future<void> retryReconcile() async {
    if (phase != ChatPhase.uncertain) return;
    // R2 §4.2: an abandoned tombstone exposes NO re-check window — only
    // the local cleanup retry. Never spend (or mint) a budget here.
    if (_localCleanupOnly) return;
    final token = _turnToken;
    if (_pollCapped && live?.runId != null) {
      // AUDIT-05②: the transport-cap uncertain resumes the STATUS POLL
      // (the run exists; the network was the problem) — but only through
      // the SAME one-shot persisted allowance (B3): once spent, re-checks
      // can never re-arm a window from this branch either.
      if (await _ensureBudgetBegun(token)) return;
      final outcome = await store.consumeRecoveryRetry(
        serverUrl,
        sid,
        token: _pendingToken,
        retryWindow: recoveryRetryWindow,
        now: _clock(),
      );
      if (!_owns(token)) return;
      if (outcome.outcome == RecoveryRetryOutcome.mismatch) {
        error = const UiMessage.local(MessageKey.chatStateM021);
        notifyListeners();
        return;
      }
      if (outcome.outcome == RecoveryRetryOutcome.alreadyUsed) {
        error = const UiMessage.local(MessageKey.chatRecoveryExhausted);
        notifyListeners();
        return;
      }
      _budgetDeadline = outcome.record?.recoveryDeadline;
      _budgetRetryUsed = true;
      _pollCapped = false;
      _pollFails = 0;
      error = null;
      phase = ChatPhase.recovering;
      notifyListeners();
      _watchTimer?.cancel();
      _watchTimer = Timer.periodic(watchInterval, (_) => unawaited(_pollRun()));
      unawaited(_pollRun(fresh: true));
      return;
    }
    if (_stopping) {
      // Stopping watch hit its bounded-retry cap: 「重新核對」resumes
      // read-only checks on the SAME runId through the SAME one-shot
      // persisted allowance (R1 §3.3.7) — it can never re-arm from thin air.
      if (await _ensureBudgetBegun(token)) return;
      final outcome = await store.consumeRecoveryRetry(
        serverUrl,
        sid,
        token: _pendingToken,
        retryWindow: recoveryRetryWindow,
        now: _clock(),
      );
      if (!_owns(token)) return;
      if (outcome.outcome == RecoveryRetryOutcome.mismatch) {
        error = const UiMessage.local(MessageKey.chatStateM021);
        notifyListeners();
        return;
      }
      if (outcome.outcome == RecoveryRetryOutcome.alreadyUsed) {
        error = const UiMessage.local(MessageKey.chatRecoveryExhausted);
        notifyListeners();
        return;
      }
      _budgetDeadline = outcome.record?.recoveryDeadline;
      _budgetRetryUsed = true;
      error = null;
      phase = ChatPhase.recovering;
      _stopFails = 0;
      notifyListeners();
      _watchTimer?.cancel();
      _watchTimer = Timer.periodic(
        watchInterval,
        (_) => unawaited(_stopTick()),
      );
      unawaited(_stopTick());
      return;
    }
    if (live == null && pendingInput == null) {
      // Bootstrap observation timed out: "重新核對" gets EXACTLY ONE
      // persisted 30s window (B3) — double taps, the second tab and
      // post-reload retries all see `alreadyUsed` and re-arm nothing.
      final pending = store.loadPending(serverUrl, sid);
      if (pending == null) {
        await recover();
        return;
      }
      final outcome = await store.consumeRecoveryRetry(
        serverUrl,
        sid,
        token: pending.token,
        retryWindow: recoveryRetryWindow,
        now: _clock(),
      );
      switch (outcome.outcome) {
        case RecoveryRetryOutcome.mismatch:
          error = const UiMessage.local(MessageKey.chatStateM021);
          notifyListeners();
          return;
        case RecoveryRetryOutcome.alreadyUsed:
          final deadline = outcome.record?.recoveryDeadline;
          if (deadline != null && _clock().isBefore(deadline)) {
            error = const UiMessage.local(MessageKey.chatRecoveryUncertain);
          } else {
            error = const UiMessage.local(MessageKey.chatRecoveryExhausted);
          }
          notifyListeners();
          return;
        case RecoveryRetryOutcome.missing:
          await recover();
          return;
        case RecoveryRetryOutcome.consumed:
          break;
      }
      final retried = outcome.record ?? pending;
      if (retried.recoveryDeadline != null &&
          !_clock().isBefore(retried.recoveryDeadline!)) {
        error = const UiMessage.local(MessageKey.chatRecoveryExhausted);
        notifyListeners();
        return;
      }
      error = null;
      phase = ChatPhase.recovering;
      _bootRunId = retried.runId;
      _bootKnownText = retried.hasUserText;
      _bootUserText = retried.hasUserText ? retried.userText : null;
      _bootStartedAt = retried.startedAt;
      _bootDeadline = retried.recoveryDeadline;
      _bootRetryUsed = true;
      _bootHistoryAfterId = retried.historyAfterId;
      _bootFails = 0;
      _bootActive = true;
      if (!identical(_turnToken, token) || _turnToken == null) {
        _turnToken = Object(); // re-adopt: observation needs an identity
      }
      notifyListeners();
      _watchTimer?.cancel();
      _watchTimer = Timer.periodic(
        watchInterval,
        (_) => unawaited(_bootstrapTick()),
      );
      _armDeadlineTimer();
      _armCountdownTicker();
      unawaited(_bootstrapTick());
      return;
    }
    // Live turn fallback: re-running the read-only backoff must consume the
    // SAME persisted allowance too — no branch may re-arm a window (B3).
    final pending = store.loadPending(serverUrl, sid);
    if (pending != null) {
      if (await _ensureBudgetBegun(token)) return;
      final outcome = await store.consumeRecoveryRetry(
        serverUrl,
        sid,
        token: pending.token,
        retryWindow: recoveryRetryWindow,
        now: _clock(),
      );
      if (!_owns(token)) return;
      if (outcome.outcome == RecoveryRetryOutcome.mismatch) {
        error = const UiMessage.local(MessageKey.chatStateM021);
        notifyListeners();
        return;
      }
      if (outcome.outcome == RecoveryRetryOutcome.alreadyUsed) {
        error = const UiMessage.local(MessageKey.chatRecoveryExhausted);
        notifyListeners();
        return;
      }
      if (outcome.outcome == RecoveryRetryOutcome.consumed) {
        _budgetDeadline = outcome.record?.recoveryDeadline;
        _budgetRetryUsed = true;
        _armDeadlineTimer();
      }
    }
    await recover();
  }

  /// STUCK-BUSY B3: end THIS device's waiting — compare-clear the pending
  /// record through the settlement gate and return to idle. It is neither
  /// a server stop nor a resend: drafts, attachments and history stay as
  /// they are, and a record another tab re-claimed survives untouched.
  Future<void> clearLocalWaitingRecord() async {
    if (_disposed) return;
    final token = _turnToken;
    if (_localCleanupOnly) {
      await retryLocalCleanup();
      return;
    }
    if (token == null) return; // nothing waiting under this identity
    // R2 §4.2: when the record carries a human attempt identity, the clear
    // is journal-first (tombstone BEFORE the compare-delete) — the legacy
    // gate's plain clear would strand the attempt's preserved draft.
    final pending = store.loadPending(serverUrl, sid);
    final attemptId = pending?.attemptId;
    if (pending != null && attemptId != null && !pending.isAutoWake) {
      await _endLocalAttempt(token, attemptId);
      return;
    }
    await _settleTurn(token);
  }

  /// R2 §4.2 step 3's residue: an abandoned tombstone whose shared-pending
  /// delete never landed. Retry ONLY the local cleanup, with the token the
  /// tombstone recorded — never a POST, never a waiting budget. A record
  /// that moved (mismatch) is shown as ownership-moved and NEVER deleted.
  Future<StopResult> retryLocalCleanup() async {
    if (_disposed) return const StopResult(StopResultKind.failure);
    final token = _turnToken;
    final pending = store.loadPending(serverUrl, sid);
    LocalAttempt? tomb;
    final pendingAttempt = pending?.attemptId;
    if (pendingAttempt != null) {
      final e = store.loadAttempt(serverUrl, sid, pendingAttempt);
      if (e != null && e.disposition == AttemptDisposition.abandoned) {
        tomb = e;
      }
    } else {
      final all = [
        for (final a in store.listAttempts(serverUrl, sid))
          if (a.disposition == AttemptDisposition.abandoned &&
              a.origin == 'human')
            a,
      ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      tomb = all.isEmpty ? null : all.last;
    }
    if (tomb == null) {
      // Journal says nothing is owed: retire the local observation.
      await _settleTurn(token, reason: SettlementReason.localAbandonment);
      return const StopResult(
        StopResultKind.localWaitingEnded,
        cleanup: 'done',
      );
    }
    if (pending == null || pendingAttempt != tomb.attemptId) {
      // The shared key is already gone (or replaced): this page's waiting
      // shape retires; nothing shared is touched.
      await _settleTurn(token, reason: SettlementReason.localAbandonment);
      return StopResult(
        StopResultKind.localWaitingEnded,
        attemptId: tomb.attemptId,
        cleanup: 'done',
        message: const UiMessage.local(MessageKey.chatLocalWaitingEnded),
      );
    }
    final endedByToken = tomb.terminalEvidence?['ended_by_token'] is String
        ? tomb.terminalEvidence!['ended_by_token'] as String
        : null;
    final res = await store.endLocalAttempt(
      serverUrl,
      sid,
      token: endedByToken,
      attemptId: tomb.attemptId,
      tombstone: tomb,
    );
    switch (res.outcome) {
      case LocalAttemptEndOutcome.ended:
      case LocalAttemptEndOutcome.missing:
        await _settleTurn(
          token,
          errorMessage: const UiMessage.local(MessageKey.chatLocalWaitingEnded),
          reason: SettlementReason.localAbandonment,
        );
        return StopResult(
          StopResultKind.localWaitingEnded,
          attemptId: tomb.attemptId,
          cleanup: 'done',
          message: const UiMessage.local(MessageKey.chatLocalWaitingEnded),
        );
      case LocalAttemptEndOutcome.cleanupPending:
        // Evidence stays; retire the page's waiting shape around it.
        await _settleTurn(
          token,
          errorMessage: const UiMessage.local(MessageKey.chatLocalWaitingEnded),
          reason: SettlementReason.localAbandonment,
        );
        return StopResult(
          StopResultKind.localWaitingEnded,
          attemptId: tomb.attemptId,
          cleanup: 'pending',
          message: const UiMessage.local(MessageKey.chatLocalWaitingEnded),
        );
      case LocalAttemptEndOutcome.mismatch:
        if (!_disposed) {
          error = const UiMessage.local(MessageKey.chatStateM021);
          notifyListeners();
        }
        return const StopResult(
          StopResultKind.failure,
          message: UiMessage.local(MessageKey.chatStateM021),
        );
      case LocalAttemptEndOutcome.journalFailed:
        if (!_disposed) {
          error = const UiMessage.local(MessageKey.chatRecoveryStorageFailed);
          notifyListeners();
        }
        return const StopResult(
          StopResultKind.failure,
          message: UiMessage.local(MessageKey.chatRecoveryStorageFailed),
        );
    }
  }

  /// The §4.2 local settlement for [attemptId], fixed order, ZERO POSTS:
  /// refresh the journal snapshot (raw draft verbatim + attachment blob
  /// refs + editor revision), persist the abandoned tombstone, and only
  /// then the inlined compare-delete. A journal refusal changes NOTHING;
  /// a moved record is reported honestly (mismatch → M021, no delete).
  Future<StopResult> _endLocalAttempt(
    Object? turnToken,
    String attemptId,
  ) async {
    if (identical(_turnToken, turnToken)) _dispatchInFlight = false;
    final pending = store.loadPending(serverUrl, sid);
    if (pending == null) {
      await _settleTurn(turnToken);
      return const StopResult(StopResultKind.noTurn);
    }
    if (pending.attemptId != attemptId) {
      // The record moved between the caller's read and this transaction.
      if (!_disposed) {
        error = const UiMessage.local(MessageKey.chatStateM021);
        notifyListeners();
      }
      await _settleTurn(
        turnToken,
        errorMessage: const UiMessage.local(MessageKey.chatStateM021),
      );
      return const StopResult(
        StopResultKind.failure,
        message: UiMessage.local(MessageKey.chatStateM021),
      );
    }
    final journal = store.loadAttempt(serverUrl, sid, attemptId);
    final slot = store.draft(serverUrl, sid);
    final raw =
        journal?.rawDraft ?? (slot.isNotEmpty ? slot : pending.userText);
    final snapshots = journal != null && journal.attachmentSnapshots.isNotEmpty
        ? journal.attachmentSnapshots
        : store.attachments(serverUrl, sid);
    final revision = store.draftRevision(serverUrl, sid);
    final tombstone = LocalAttempt(
      attemptId: attemptId,
      server: serverUrl,
      sid: sid,
      createdAt: journal?.createdAt ?? pending.startedAt,
      origin: 'human',
      rawDraft: raw,
      preparedInput: journal?.preparedInput,
      attachmentSnapshots: snapshots,
      editorRevision: revision,
      disposition: AttemptDisposition.abandoned,
      // R3 §5.2.7: a local end NEVER rewrites the delivery classification —
      // whatever structured evidence the attempt holds (notDispatched,
      // acknowledged, …) rides along unchanged; R2 journals were always
      // outcomeUnknown, so old records are byte-identical.
      delivery: journal?.delivery ?? AttemptDelivery.outcomeUnknown,
      runId: journal?.runId ?? pending.runId,
      historyAfterId: journal?.historyAfterId ?? pending.historyAfterId,
      serverEpoch: journal?.serverEpoch,
      recoveryStartedAt:
          journal?.recoveryStartedAt ?? pending.recoveryStartedAt,
      recoveryDeadline: journal?.recoveryDeadline ?? pending.recoveryDeadline,
      retryUsed: journal?.retryUsed ?? pending.recoveryRetryUsed,
      draftRestoredRevision: journal?.draftRestoredRevision,
      terminalEvidence: {
        // Preserve the R3 stage/decision evidence; the tombstone only adds
        // who ended it (§4.2 — the marker is local, never a server claim).
        ...?journal?.terminalEvidence,
        'ended_by_token': _pendingToken,
      },
    );
    final LocalAttemptEndResult res;
    try {
      res = await store.endLocalAttempt(
        serverUrl,
        sid,
        token: _pendingToken,
        attemptId: attemptId,
        tombstone: tombstone,
      );
    } on Object {
      // A throw mid-transaction is indistinguishable from a crash at the
      // hook point: if the tombstone landed, the pending key may survive
      // (cleanupPending); if not, nothing was written (journalFailed).
      if (_disposed) {
        return const StopResult(StopResultKind.failure);
      }
      final tomb = store.loadAttempt(serverUrl, sid, attemptId);
      if (tomb != null && tomb.disposition == AttemptDisposition.abandoned) {
        sendOutcome ??= SendOutcome.localSettled;
        await _settleTurn(
          turnToken,
          errorMessage: const UiMessage.local(MessageKey.chatLocalWaitingEnded),
          reason: SettlementReason.localAbandonment,
        );
        return StopResult(
          StopResultKind.localWaitingEnded,
          attemptId: attemptId,
          restoreDraft: raw,
          restoreRevision: revision,
          cleanup: 'pending',
          message: const UiMessage.local(MessageKey.chatLocalWaitingEnded),
        );
      }
      if (!_disposed) {
        error = const UiMessage.local(MessageKey.chatRecoveryStorageFailed);
        notifyListeners();
      }
      return const StopResult(
        StopResultKind.failure,
        message: UiMessage.local(MessageKey.chatRecoveryStorageFailed),
      );
    }
    if (_disposed) {
      return const StopResult(StopResultKind.failure); // never claim success
    }
    const ended = UiMessage.local(MessageKey.chatLocalWaitingEnded);
    switch (res.outcome) {
      case LocalAttemptEndOutcome.ended:
        sendOutcome ??= SendOutcome.localSettled;
        await _settleTurn(
          turnToken,
          errorMessage: ended,
          reason: SettlementReason.localAbandonment,
        );
        return StopResult(
          StopResultKind.localWaitingEnded,
          attemptId: attemptId,
          restoreDraft: raw,
          restoreRevision: revision,
          cleanup: 'done',
          message: ended,
        );
      case LocalAttemptEndOutcome.cleanupPending:
        sendOutcome ??= SendOutcome.localSettled;
        await _settleTurn(
          turnToken,
          errorMessage: ended,
          reason: SettlementReason.localAbandonment,
        );
        return StopResult(
          StopResultKind.localWaitingEnded,
          attemptId: attemptId,
          restoreDraft: raw,
          restoreRevision: revision,
          cleanup: 'pending',
          message: ended,
        );
      case LocalAttemptEndOutcome.mismatch:
        if (!_disposed) {
          error = const UiMessage.local(MessageKey.chatStateM021);
          notifyListeners();
        }
        await _settleTurn(
          turnToken,
          errorMessage: const UiMessage.local(MessageKey.chatStateM021),
        );
        return const StopResult(
          StopResultKind.failure,
          message: UiMessage.local(MessageKey.chatStateM021),
        );
      case LocalAttemptEndOutcome.journalFailed:
        // Journal refused: pending UNTOUCHED, input untouched, the turn
        // stays unsettled so the local exit can be retried (the gate was
        // never armed for it).
        if (!_disposed) {
          error = const UiMessage.local(MessageKey.chatRecoveryStorageFailed);
          notifyListeners();
        }
        return const StopResult(
          StopResultKind.failure,
          message: UiMessage.local(MessageKey.chatRecoveryStorageFailed),
        );
      case LocalAttemptEndOutcome.missing:
        await _settleTurn(turnToken);
        return const StopResult(StopResultKind.noTurn);
    }
  }

  /// Countdown source for the recovering UI (B4): ceil remaining seconds
  /// over the persisted deadline; null = no recovery window in flight.
  int? get recoverySecondsRemaining {
    if (!busy || _localCleanupOnly) return null;
    final deadline =
        _bootDeadline ??
        _budgetDeadline ??
        store.loadPending(serverUrl, sid)?.recoveryDeadline;
    if (deadline == null) return null;
    final ms = deadline.difference(_clock()).inMilliseconds;
    return ms <= 0 ? 0 : (ms + 999) ~/ 1000;
  }

  /// Whether the ONE persisted re-check allowance is still unconsumed —
  /// the uncertain UI shows 「重新核對」 only while this is true (B4).
  bool get recoveryRetryAvailable =>
      !_localCleanupOnly &&
      !(_bootRetryUsed || _budgetRetryUsed) &&
      !(store.loadPending(serverUrl, sid)?.recoveryRetryUsed ?? false);

  /// True while POSITIVE evidence (active status / active snapshot) says
  /// the run is working — the generic 「發言中」 row belongs to THAT, and
  /// only the evidence-free observation stretch gets the countdown (B4).
  bool get recoveryActiveConfirmed =>
      _lastActiveSeen != null &&
      _clock().difference(_lastActiveSeen!) <= recoveryInitialWindow;

  /// The 「清除本機等待紀錄」 button only makes sense while a record IS
  /// here; another tab's claim is cleared by settlement compare rules, not
  /// by pretending this page can delete it.
  bool get hasLocalWaitingRecord =>
      busy && store.loadPending(serverUrl, sid) != null;

  Timer? _countdownTicker;

  /// B4: repaint the countdown once a second WITHOUT any extra GET; a
  /// hidden page never ticks, and returning recomputes from the persisted
  /// deadline (the getter is always pure arithmetic on _now()).
  void _armCountdownTicker() {
    if (_disposed) return;
    _countdownTicker?.cancel();
    _countdownTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed ||
          backgrounded ||
          !busy ||
          phase != ChatPhase.recovering ||
          (_bootDeadline ?? _budgetDeadline) == null) {
        _countdownTicker?.cancel();
        _countdownTicker = null;
        return;
      }
      notifyListeners();
    });
  }

  @visibleForTesting
  void debugSetRecoveryBudget(DateTime? deadline, {bool retryUsed = false}) {
    // R1: the expiry selector is `_bootActive ? boot : budget` — set both
    // so the helper behaves identically for bootstrap and live waits.
    _bootDeadline = deadline;
    _budgetDeadline = deadline;
    _bootRetryUsed = retryUsed;
    _budgetRetryUsed = retryUsed;
    if (deadline != null && phase == ChatPhase.recovering)
      _armCountdownTicker();
  }

  /// CROSSDEV-STOP R1 test seam: issue a RAW activity snapshot (the same
  /// direct path `_quietRound` uses, bypassing the single-flight) so
  /// overlapping requests with an out-of-order completion can be proven to
  /// never overwrite newer evidence.
  @visibleForTesting
  Future<void> debugActivitySnapshotRaw() => _activitySnapshot();

  /// CROSSDEV-STOP R1 test seam: mint a fresh TURN identity without any
  /// send/adopt (simulates the turn/session handover that must retire every
  /// in-flight observer) — zero network.
  @visibleForTesting
  void debugMintTurnToken() {
    if (!_disposed) _turnToken = Object();
  }

  /// CROSSDEV-STOP R1 test seam: simulate a settings URL/key move on THIS
  /// controller (in production providers mint a new repo + controller; this
  /// proves the generation fence retires in-flight old-connection answers).
  @visibleForTesting
  void debugBumpConnectionGeneration() {
    if (_disposed) return;
    _currentConnectionGeneration();
    _connectionGeneration++;
  }

  /// R2 §4.3: `Future<StopResult>` — a double-tap JOINS the same in-flight
  /// future (the old `stopBusy → return true` was a fabricated success).
  Future<StopResult> stop() {
    if (_disposed) return Future.value(const StopResult(StopResultKind.noTurn));
    final flight = _stopFlight;
    if (flight != null) return flight;
    final task = _stopCore();
    _stopFlight = task;
    unawaited(
      task.whenComplete(() {
        if (identical(_stopFlight, task)) _stopFlight = null;
      }),
    );
    return task;
  }

  Future<StopResult> _stopCore() async {
    if (_disposed) return const StopResult(StopResultKind.noTurn);
    // §4.5 residue first: an abandoned tombstone exposes ONLY cleanup retry.
    if (_localCleanupOnly) return retryLocalCleanup();
    // AUDIT-21 (D2): the claim mint is still in flight — NO server call can
    // be aimed at a run this page does not own yet. Land the intent; send()
    // ends its own claim journal-first BEFORE any repo.chat.
    if (_pendingStart) {
      _stopDuringClaim = true;
      final done = _stopDuringClaimDone ??= Completer<StopResult>();
      return done.future;
    }
    final token = _turnToken; // stop belongs to a TURN (AUDIT-12)
    final run = activeRunId;
    if (run == null) {
      final pending = store.loadPending(serverUrl, sid);
      final attemptId = pending?.attemptId;
      if (pending != null && attemptId != null && !pending.isAutoWake) {
        // LOCAL END (§4.2): zero POSTs, journal-first, tombstone abandoned.
        return _endLocalAttempt(token, attemptId);
      }
      // An auto-wake record without a run keeps its own ledger handling —
      // the human local-stop path must never consume a wake batch (§1.5,
      // §4.2). M029 noTurn stays the honest answer.
      if (pending == null) {
        // CROSSDEV-STOP R2 §5.1: local has NO target of its own (no run, no
        // attempt of any kind — a pending wake record keeps M029 above-only
        // semantics by falling through untouched). ONLY NOW may a remote
        // row be considered, and only from FRESH evidence:
        //   • exactly one stoppable row, no other rows, no overflow → run
        //     the unique target inline (typed outcome, never a local
        //     disposition);
        //   • more than one row OR overflow (even with stoppable rows) →
        //     the CHOOSER — nothing is guessed, nothing is POSTed;
        //   • one row that isn't stoppable (stopping/null/unknown) → the
        //     unchanged M029 noTurn below (reason via remoteDisabledReason).
        if (canRequestRemoteStop) {
          // (canRequestRemoteStop already means: fresh NOW + snapshot proves
          // this session — no evidence, no remote branch, no POST.)
          final candidates = remoteStopCandidates;
          final ambiguous =
              candidates.length > 1 ||
              observedActivity!.activeRuns.length > 1 ||
              observedActivity!.overflow;
          if (!ambiguous) {
            final outcome = await stopRemote(candidates.single);
            if (_disposed) {
              return const StopResult(StopResultKind.failure);
            }
            return StopResult(
              StopResultKind.remoteResult,
              remote: outcome,
              message: outcome.message,
            );
          }
          return const StopResult(StopResultKind.remoteChoice);
        }
      }
      error = const UiMessage.local(MessageKey.chatStateM029);
      notifyListeners();
      return const StopResult(StopResultKind.noTurn);
    }
    stopBusy = true;
    error = null;
    _setStop(
      StopNotice.requested,
      const UiMessage.local(MessageKey.chatStateM030),
    );
    notifyListeners();
    var settled = false; // result known → hand the run to the stopping watch
    UiMessage? failed;
    try {
      await store.saveStop(serverUrl, sid, run, 'requested');
      if (!identical(_turnToken, token)) {
        return const StopResult(StopResultKind.failure); // stale: never success
      }
      await repo.stop(run);
      if (!identical(_turnToken, token)) {
        return const StopResult(StopResultKind.failure);
      }
      _setStop(
        StopNotice.accepted,
        const UiMessage.local(MessageKey.chatStateStoppedByYou),
      );
      await store.saveStop(serverUrl, sid, run, 'accepted');
      if (!identical(_turnToken, token)) {
        return const StopResult(StopResultKind.failure);
      }
      // OFFLINE-SEND R1 §3.3.8: a 200 only proves the stop REQUEST landed.
      // The pending record is kept as the confirmed-request evidence and
      // compare-cleared when the terminal (or its 404) is SETTLED — never
      // the moment the stop response arrives. The runId lives on in
      // `_stopRunId` until the terminal check; D2's compare-delete still
      // protects a record another tab re-claimed.
      settled = true;
    } on ApiException catch (e) {
      if (!identical(_turnToken, token)) {
        return const StopResult(StopResultKind.failure); // stale answer
      }
      if (e.status == 409) {
        // Already being stopped server-side: that IS the request landing.
        // Keep the pending record (a reload must be able to re-check) and
        // poll for the terminal state — no error, no repeat POST.
        settled = true;
      } else if (e.status == 404) {
        // The gateway forgot the run: nothing to wait for. Settle from
        // history now; do not claim the POST itself killed anything, and do
        // NOT upgrade the record to a confirmed user stop. R1 §3.3.8: the
        // pending compare-clear happens inside the settle gate.
        _setStop(
          StopNotice.notFound,
          const UiMessage.local(MessageKey.chatStateM031),
        );
        if (identical(_turnToken, token)) stopBusy = false;
        await _settleStoppedRun(token);
        return const StopResult(
          StopResultKind.serverStopRequested,
          serverDisposition: 'alreadyGone',
          message: UiMessage.local(MessageKey.chatStateM031),
        );
      } else {
        failed = UiMessage.local(
          MessageKey.chatStateM032,
          args: {'error': messageForError(e)},
        );
        _setStop(StopNotice.failed, failed);
      }
    } catch (e) {
      if (!identical(_turnToken, token)) {
        return const StopResult(StopResultKind.failure);
      }
      // Transport-class failure: pending and the current observation stay
      // untouched; the user may retry. Never write accepted here.
      failed = UiMessage.local(
        MessageKey.chatStateM032,
        args: {'error': messageForError(e)},
      );
      _setStop(StopNotice.failed, failed);
    }
    if (identical(_turnToken, token)) stopBusy = false;
    if (settled && identical(_turnToken, token) && live == null && !_detached) {
      // Take over from _bootstrapTick (which may be mid-flight with the old
      // runId): one scheduler only — bump the epoch, swap the timer.
      _stopping = true;
      _stopRunId = run;
      _stopFails = 0;
      _recoveryEpoch++;
      _cancelBootstrapWaiting();
      _watchTimer = Timer.periodic(
        watchInterval,
        (_) => unawaited(_stopTick()),
      );
      unawaited(_stopTick());
    }
    // live / detached paths keep their existing owner (SSE or _pollRun, which
    // already understands a stopped run's 404).
    notifyListeners();
    if (settled && identical(_turnToken, token)) {
      return const StopResult(
        StopResultKind.serverStopRequested,
        serverDisposition: 'requested',
      );
    }
    return StopResult(StopResultKind.failure, message: failed);
  }

  Future<void> _stopTick() async {
    if (_disposed || !_stopping || _stopBusyTick) return;
    final run = _stopRunId;
    if (run == null) return;
    final token = _turnToken;
    _stopBusyTick = true;
    try {
      Json status;
      try {
        status = await repo.runStatus(run);
      } on ApiException catch (e) {
        if (!_owns(token)) return;
        if (e.status == 404) {
          // 404 on THIS run's stop intent is terminal (gateway forgets stopped
          // runs), not a vanishing — settle instead of widening bootstrap's
          // 404 fallback.
          await _settleStoppedRun(token, keepStopSource: true);
          return;
        }
        _stopFails++;
        // R1 §3.3.8: the stop watch shares the persisted budget — an
        // unreadable status can never park the page busy forever.
        if (await _budgetGate(token)) return;
        return; // other HTTP-class misses: retry next tick
      } catch (_) {
        if (!_owns(token)) return;
        if (++_stopFails > 12) {
          _watchTimer?.cancel();
          _watchTimer = null;
          if (busy) {
            phase = ChatPhase.uncertain;
            error = const UiMessage.local(MessageKey.chatStateM033);
            notifyListeners();
          }
        }
        if (await _budgetGate(token)) return;
        return; // Transient: bounded retry.
      }
      if (!_owns(token) || !_stopping) return;
      _stopFails = 0;
      final state = status['status'];
      if (state == 'completed' || state == 'cancelled' || state == 'failed') {
        await _settleStoppedRun(token, keepStopSource: true);
        return;
      }
      if (state == 'stopping') {
        // Positive drain progress for THIS run: freshness, not a new budget.
        _lastActiveSeen = _clock();
        return;
      }
      // queued/running/waiting_for_approval AFTER the stop landed is not
      // "still draining" evidence — the wait stays bounded by the
      // persisted budget (R1 §3.3.8: never endless busy on a good stop).
      if (await _budgetGate(token)) return;
    } finally {
      if (!_disposed) _stopBusyTick = false;
    }
  }

  /// Common settle for a user-stopped run: refresh history FIRST (best-effort),
  /// then release busy — a history-refresh failure must not re-arm running,
  /// it only adds a retry hint. The token guard keeps a delayed stop response
  /// from a RETIRED turn from touching the current turn (AUDIT-12).
  Future<void> _settleStoppedRun(
    Object? token, {
    bool keepStopSource = false,
  }) async {
    if (!_owns(token)) return;
    if (keepStopSource &&
        _stopRunId != null &&
        _stopRequestedFor(_stopRunId!)) {
      // Terminal reached while a stop request was outstanding: that confirms
      // the user's own hand — surface it instead of a silent/generic notice.
      _setStop(
        StopNotice.accepted,
        const UiMessage.local(MessageKey.chatStateStoppedByYou),
      );
    }
    _watchTimer?.cancel(); // stop this owner's ticks before the fetch
    _watchTimer = null;
    var refreshFailed = false;
    List<Message>? page;
    try {
      page = await repo.messages(sid); // settle from history
    } catch (_) {
      refreshFailed = true;
    }
    await _settleTurn(
      token,
      page: page,
      errorMessage: refreshFailed
          ? const UiMessage.local(MessageKey.chatStateM034)
          : null,
    );
  }

  Future<void> steer(String input) async {
    if (!canControl || steerBusy || input.trim().isEmpty) return;
    final token = _turnToken;
    steerBusy = true;
    error = null;
    notifyListeners();
    // STEERWEB R4: with the durable inbox live the LOCAL composer submits
    // through the SAME resolver/receipt path; the legacy POST is only the
    // capability-off fallback.
    await _probeSteerCap();
    if (steerInboxEnabled && live?.runId != null) {
      final snap = observedActivity;
      final runId = live!.runId!;
      final target =
          steerTargetForRun(runId) ??
          RemoteSteerTarget(
            connectionGeneration: connectionGeneration,
            accountGeneration: connectionGeneration,
            requestedSessionId: sid,
            resolvedSessionId: snap?.resolvedSessionId ?? sid,
            serverEpoch:
                snap?.serverEpoch ?? '${_steerCap?['server_epoch'] ?? ''}',
            observationId: null,
            runId: runId,
          );
      final outcome = await submitRemoteSteer(target, input);
      if (!_owns(token)) return;
      steerBusy = false;
      if (!outcome.tracked) {
        error = outcome.message ?? remoteSteerMessage(outcome.kind);
      }
      notifyListeners();
      return;
    }
    try {
      await repo.steer(live!.runId!, input.trim());
    } catch (e) {
      if (_owns(token)) {
        error = UiMessage.local(
          MessageKey.chatStateM035,
          args: {'error': messageForError(e)},
        );
      }
      rethrow;
    } finally {
      steerBusy = false;
      notifyListeners();
    }
  }

  // ---- STEERWEB R4: cross-device durable steer inbox ----------------------
  // Receipt cards live in their OWN ledger surface: they never enter
  // _remoteRows, LocalAttempt, pending-turn ownership or wake/settleTurn.
  // Drafts survive until a durable accepted receipt; an unknown answer keeps
  // the SAME client_request_id (idempotent retry), never a chat re-send.

  Map<String, dynamic>? _steerCap;
  Map<String, dynamic>? _notifyCap;
  bool _notifyCapAsked = false;
  final NotificationLedger _notifications = NotificationLedger();
  NotificationLedger get notifications => _notifications;

  // ---- 01412FIX F5 (M6): deep-link focus on THIS session -----------------
  // Navigation is decided OUTSIDE (exact identity in deep_link.dart); the
  // controller only applies what the link named: its event converges as
  // READ, its request focuses the approval card, its run is exposed for
  // any run-scoped surfacing. Unknown ids simply match nothing.
  RunLink? _deepLinkFocus;
  RunLink? get deepLinkFocus => _deepLinkFocus;
  String? get approvalFocus => _deepLinkFocus?.requestId;
  String? get focusedRunId => _deepLinkFocus?.runId;
  final Set<String> _deepLinkReadSent = {};

  void applyDeepLink(RunLink link) {
    _deepLinkFocus = link;
    final eventId = link.eventId;
    if (eventId != null && eventId.isNotEmpty &&
        !_deepLinkReadSent.contains(eventId)) {
      _deepLinkReadSent.add(eventId);
      unawaited(markNotificationRead(eventId)); // idempotent; read != approve
    }
    if (!_disposed) notifyListeners();
  }

  bool get notificationEventsEnabled =>
      _notifyCap != null && _notifyCap!['enabled'] == true;
  String get notificationServerChannel =>
      '${_notifyCap?['system_channel'] ?? ''}';
  bool _notifyPolling = false;

  Future<void> _probeNotifyCap() async {
    if (_notifyCap != null && _notifyCap!['enabled'] == true) return;
    if (_notifyCapAsked) return; // one probe until the ledger appears
    _notifyCapAsked = true;
    final f = await repo.notificationEventsFeature(); // never throws
    if (_disposed) return;
    if (f != null && f['enabled'] == true) {
      _notifyCap = f;
      notifyListeners();
    }
  }

  /// Ledger-cursor poll piggybacked on the activity tick (no second timer).
  /// Overflow is CONTINUED from the actual last delivered seq (01412 M3);
  /// the cursor never jumps to the global head and drops the tail.
  Future<void> _notificationPoll() async {
    if (_notifyPolling || _disposed) return;
    if (!notificationEventsEnabled) return;
    _notifyPolling = true;
    try {
      var changed = false;
      for (var page = 0; page < 10; page++) {
        final cursorBefore = _notifications.cursor;
        final pageResult = NotificationPage.fromJson(
          await repo.notificationEvents(after: cursorBefore),
        );
        if (_disposed) return;
        final before = _notifications.unread.length;
        _notifications.merge(pageResult);
        if (_notifications.unread.length != before) changed = true;
        if (!pageResult.overflow) break;
        if (_notifications.cursor <= cursorBefore) break; // never spin
      }
      if (changed) notifyListeners();
      await _convergeBrowserAlerts();
    } on Object {
      // A failed poll changes NOTHING (never reads as "all read").
    } finally {
      _notifyPolling = false;
    }
  }

  // ---- 01412FIX F4 (M5): the browser delivery channel's claim->show->
  // report convergence. The SERVER ledger decides who may alert (exactly
  // one claim per event); this client only claims its turn, shows through
  // the OS surface when granted, and reports the honest outcome. show is
  // NOT read — reminders stay alive until the user actually reads (R6).

  NotificationSurface _notifySurface = createNotificationSurface();

  /// Test seam: a fake surface records permission/claim/show in one binary.
  set notifySurfaceForTest(NotificationSurface surface) =>
      _notifySurface = surface;

  bool _notifyPermissionAsked = false;
  bool _notifyPermissionGranted = false;
  final Set<String> _notifyClaimAsked = {};
  late final String _notifyDeviceId =
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '-${math.Random().nextInt(1 << 30).toRadixString(36)}';

  /// True once the browser granted OS alerts (false = panel-only, honest).
  bool get browserAlertsGranted => _notifyPermissionGranted;

  Future<void> _convergeBrowserAlerts() async {
    if (!notificationEventsEnabled ||
        notificationServerChannel != 'browser' ||
        _disposed) {
      return;
    }
    if (!_notifyPermissionAsked) {
      _notifyPermissionAsked = true;
      _notifyPermissionGranted = await _notifySurface.ensurePermission();
      if (_disposed) return;
    }
    if (!_notifyPermissionGranted) return; // panel-only fallback
    for (final e in _notifications.unread) {
      if (_disposed) return;
      if (!_notifyClaimAsked.add(e.eventId)) continue;
      Map<String, dynamic> verdict;
      try {
        verdict = await repo.notificationClaim(
          e.eventId,
          deviceId: _notifyDeviceId,
        );
      } on Object {
        _notifyClaimAsked.remove(e.eventId); // retry the claim next poll
        return;
      }
      if (_disposed) return;
      if (verdict['verdict'] != 'claimed') {
        // Another device/tab won and alerted: converge this one locally.
        _notifications.markRead(e.eventId);
        notifyListeners();
        continue;
      }
      final shown = _notifySurface.show(
        title: 'Hermes',
        body: AppStrings.forLocale(
          store.loadLocale(),
        ).resolve(_notificationKey(e.kind)),
      );
      try {
        await repo.notificationDelivery(
          e.eventId,
          deliveryId: '${verdict['delivery_id'] ?? ''}',
          showToken: '${verdict['show_token'] ?? ''}',
          outcome: shown ? 'shown' : 'failed',
        );
      } on Object {
        // An unreported claim is not a lie: the row simply stays claimed.
      }
      notifyListeners();
    }
  }

  static MessageKey _notificationKey(NotificationKind kind) =>
      switch (kind) {
        NotificationKind.approvalRequest => MessageKey.notificationApproval,
        NotificationKind.completed => MessageKey.notificationCompleted,
        NotificationKind.failed => MessageKey.notificationFailed,
        NotificationKind.steerReady => MessageKey.notificationSteerReady,
        _ => MessageKey.notificationSettled,
      };

  Future<void> markNotificationRead(String eventId) async {
    try {
      await repo.notificationRead(eventId);
      _notifications.markRead(eventId);
    } on Object {
      // honest: a failed ack leaves the event unread
    }
    if (!_disposed) notifyListeners();
  }

  /// Explicit opt-in for steer.ready on ONE run (R7: per-run, never per msg).
  Future<void> watchSteerReady(String runId, {bool on = true}) async {
    try {
      await repo.notificationWatch(runId, on: on);
    } on Object {
      // opt-in is best-effort; the ledger records only explicit watches
    }
  }

  final Map<String, SteerListing> _steerListings = {};
  final Map<String, SteerReceipt> _steerTracked = {};
  final Map<String, String> _steerDrafts = {}; // clientRequestId -> text
  final Map<String, String> _steerDraftKeys = {}; // runId -> clientRequestId
  bool _steerPolling = false;
  final Set<String> _steerUnconfirmed = {};

  bool get steerInboxEnabled =>
      _steerCap != null && _steerCap!['enabled'] == true;

  Future<void> _probeSteerCap() async {
    if (_steerCap != null && _steerCap!['enabled'] == true) return;
    final f = await repo.steerInboxFeature(); // never throws
    if (_disposed) return;
    if (f != null && f['enabled'] == true) {
      _steerCap = f;
      notifyListeners();
    }
  }

  /// Steerable candidates: running AND waiting_for_approval rows (queued /
  /// stopping / terminal are never steerable targets — stoppable ≠ steerable).
  List<RemoteSteerTarget> get steerTargets {
    final snap = observedActivity;
    if (snap == null || !activityEvidenceFreshNow) return const [];
    final now = _clock();
    final gen = connectionGeneration;
    return [
      for (final r in snap.activeRuns)
        if (_classifySnapshotRunForSteer(snap, r, now) case final k
            when k == RemoteRunSteerKind.steerable ||
                k == RemoteRunSteerKind.approvalWait)
          RemoteSteerTarget(
            connectionGeneration: gen,
            accountGeneration: gen,
            requestedSessionId: sid,
            resolvedSessionId: snap.resolvedSessionId,
            serverEpoch: snap.serverEpoch,
            observationId: r.observationId,
            runId: r.runId!,
          ),
    ];
  }

  RemoteRunSteerKind _classifySnapshotRunForSteer(
    SessionActivity snap,
    ActivityRun r,
    DateTime now,
  ) => classifyRemoteSteer(
    r,
    now: now,
    lastActivitySuccess: lastActivitySuccess,
    syncInterval: syncInterval,
    requestedSessionId: sid,
    snapshotSessionId: snap.sessionId,
    resolvedSessionId: snap.resolvedSessionId,
    epoch: snap.serverEpoch,
    isLocallyRepresented: isLocallyRepresentedRun(r),
  );

  RemoteSteerTarget? steerTargetForRun(String runId) {
    for (final t in steerTargets) {
      if (t.runId == runId) return t;
    }
    return null;
  }

  RemoteSteerBlock get steerBlockReason {
    if (_disposed) return RemoteSteerBlock.stale;
    if (!steerInboxEnabled) return RemoteSteerBlock.unsupported;
    if (steerTargets.isNotEmpty) return RemoteSteerBlock.none;
    final snap = observedActivity;
    if (snap == null || lastActivitySuccess == null) {
      return RemoteSteerBlock.noSnapshot;
    }
    if (!activityEvidenceFreshNow) return RemoteSteerBlock.stale;
    return RemoteSteerBlock.noSteerableTarget;
  }

  /// Receipt cards tracked for this session (newest sequence first per run).
  List<SteerReceipt> get steerReceipts {
    final out = _steerTracked.values.toList()
      ..sort((a, b) => b.sequence.compareTo(a.sequence));
    return List.unmodifiable(out);
  }

  Set<String> get steerUnconfirmedRuns => Set.unmodifiable(_steerUnconfirmed);

  String? steerDraftFor(String runId) => _steerDrafts[_steerDraftKeys[runId]];

  String _mintClientRequestId() {
    final rng = math.Random.secure();
    final b = List<int>.generate(16, (_) => rng.nextInt(256));
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }

  /// The single entry point for remote AND local (capability-on) steers.
  Future<RemoteSteerOutcome> submitRemoteSteer(
    RemoteSteerTarget target,
    String text,
  ) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const RemoteSteerOutcome(RemoteSteerKind.failed);
    }
    if (!target.isValid) {
      return const RemoteSteerOutcome(RemoteSteerKind.staleTarget);
    }
    if (_connectivity() == ConnectivityHint.offline) {
      _steerDraftKeys[target.runId] =
          _steerDraftKeys[target.runId] ?? _mintClientRequestId();
      _steerDrafts[_steerDraftKeys[target.runId]!] = trimmed;
      notifyListeners();
      return const RemoteSteerOutcome(RemoteSteerKind.offline);
    }
    await _probeSteerCap();
    if (_disposed || !steerInboxEnabled) {
      return const RemoteSteerOutcome(RemoteSteerKind.notReady);
    }
    final key =
        _steerDraftKeys.remove(target.runId) ??
        _steerDrafts.keys.firstWhere(
          (k) => _steerDraftKeys.containsValue(k),
          orElse: () => _mintClientRequestId(),
        );
    final draft = _steerDrafts.remove(key) ?? trimmed;
    // R4: re-validate the target BEFORE submitting — the SERVER's listing
    // decides acceptance; a failed precheck is unconfirmed, never a POST.
    late final SteerListing listing;
    try {
      listing = SteerListing.fromJson(await repo.runSteers(target.runId));
    } on Object {
      _steerDraftKeys[target.runId] = key;
      _steerDrafts[key] = draft;
      notifyListeners();
      return const RemoteSteerOutcome(RemoteSteerKind.unconfirmed);
    }
    if (_disposed) return const RemoteSteerOutcome(RemoteSteerKind.failed);
    _steerListings[target.runId] = listing;
    if (!listing.accepting) {
      final kind = switch (listing.acceptingReason) {
        'closed' ||
        'run_closed' ||
        'run_stopping' ||
        'run_expired' => RemoteSteerKind.closed,
        'run_not_ready' => RemoteSteerKind.notReady,
        _ => RemoteSteerKind.staleTarget,
      };
      // ANY rejection keeps the durable draft under the SAME key — the
      // wording differs, the retry promise does not (R4/R10).
      _steerDraftKeys[target.runId] = key;
      _steerDrafts[key] = draft;
      notifyListeners();
      return RemoteSteerOutcome(kind, message: remoteSteerMessage(kind));
    }
    Json env;
    try {
      env = await repo.submitSteer(
        target.runId,
        input: draft,
        clientRequestId: key,
        sessionId: target.requestedSessionId,
        serverEpoch: listing.serverEpoch ?? target.serverEpoch,
      );
    } on Object {
      // Network-unknown: SAME key retained; a later retry/receipt lookup
      // resolves idempotently (never mint a second id, never chat-send).
      _steerDraftKeys[target.runId] = key;
      _steerDrafts[key] = draft;
      notifyListeners();
      return const RemoteSteerOutcome(RemoteSteerKind.unconfirmed);
    }
    if (_disposed) return const RemoteSteerOutcome(RemoteSteerKind.failed);
    if (env['accepted'] == true) {
      final receipt = SteerReceipt.fromJson(env);
      _steerTracked[receipt.steerId] = receipt;
      _steerUnconfirmed.remove(target.runId);
      unawaited(_steerPollRun(target.runId));
      notifyListeners();
      // 202 and an idempotent replay answer with the SAME durable receipt;
      // both mean the ledger HOLDS it (a replay is not a second steer).
      return RemoteSteerOutcome(RemoteSteerKind.accepted, receipt: receipt);
    }
    final code =
        (env['error'] is Map ? (env['error'] as Map)['code'] : null) ?? '';
    final kind = steerKindForError('$code');
    // Not admitted: the draft survives under the SAME client_request_id for
    // an idempotent retry (never a fresh id, never a chat re-send).
    _steerDraftKeys[target.runId] = key;
    _steerDrafts[key] = draft;
    notifyListeners();
    return RemoteSteerOutcome(kind, message: remoteSteerMessage(kind));
  }

  /// activityTick success hook: incremental receipt tracking for active
  /// runs that still have pending receipts (R6: cursor-based, never empty-
  /// on-error).
  Future<void> _steerPoll() async {
    if (_steerPolling || _disposed) return;
    if (!steerInboxEnabled) return;
    final pendingRuns = {
      for (final r in _steerTracked.values)
        if (!r.settled) r.runId,
    };
    // History identity retires transient cards: an exactly-matching server
    // batch row (typed steer_provenance) IS the durable record (R4).
    final seenBatches = {
      for (final m in messages)
        if (m.steerProvenance case final p?) p.batchId,
    };
    for (final id in [
      for (final e in _steerTracked.entries)
        if (e.value.batchId != null && seenBatches.contains(e.value.batchId))
          e.key,
    ]) {
      _steerTracked.remove(id);
    }
    if (pendingRuns.isEmpty) return;
    _steerPolling = true;
    try {
      for (final runId in pendingRuns) {
        await _steerPollRun(runId);
      }
    } finally {
      _steerPolling = false;
    }
  }

  Future<void> _steerPollRun(String runId) async {
    final after = _steerListings[runId]?.revision ?? 0;
    try {
      final listing = SteerListing.fromJson(
        await repo.runSteers(runId, afterSeq: after),
      );
      if (_disposed) return;
      final prev = _steerListings[runId];
      _steerListings[runId] = prev == null
          ? listing
          : SteerListing(
              accepting: listing.accepting,
              acceptingReason: listing.acceptingReason,
              revision: listing.revision,
              overflow: listing.overflow,
              serverEpoch: listing.serverEpoch,
              items: [...prev.items, ...listing.items],
            );
      for (final r in _steerListings[runId]!.items) {
        _steerTracked[r.steerId] = r;
      }
      _steerUnconfirmed.remove(runId);
      // R4: a delivered receipt retires its transient card; the durable
      // history row (exact batch identity) carries it from here.
      for (final id in [
        for (final e in _steerTracked.entries)
          if (e.value.state == SteerState.delivered) e.key,
      ]) {
        _steerTracked.remove(id);
      }
      notifyListeners();
    } on Object {
      if (_disposed) return;
      _steerUnconfirmed.add(runId); // never treat failure as empty/settled
      notifyListeners();
    }
  }

  /// Same-key idempotent retry for a kept draft (UI "retry this steer").
  Future<RemoteSteerOutcome> retrySteerDraft(String runId) async {
    final target = steerTargetForRun(runId);
    final draft = steerDraftFor(runId);
    if (target == null || draft == null) {
      return const RemoteSteerOutcome(RemoteSteerKind.staleTarget);
    }
    return submitRemoteSteer(target, draft);
  }

  Future<void> discardSteerDraft(String runId) async {
    final key = _steerDraftKeys.remove(runId);
    if (key != null) _steerDrafts.remove(key);
    notifyListeners();
  }
}

/// R3 §5.2: the controller-side observation sink for ONE dispatch attempt.
/// It extends the transport-level [DispatchObservation] (whose stage is the
/// monotonic source of truth) and adds the two policy guards the transport
/// knows nothing about: the R2 identity check (every merge only for THIS
/// live turn) and the journal merge itself.
class _JournalObservation extends DispatchObservation {
  _JournalObservation(this._c, this._token, this._attemptId);
  final ChatController _c;
  final Object? _token;
  final String _attemptId;

  bool get _live => !_c._disposed && identical(_c._turnToken, _token);

  @override
  void dispatchInvoked() {
    if (!_live) return;
    super.dispatchInvoked();
    _c._mergeAttemptEvidence(_token, _attemptId, stage: stage);
  }

  @override
  void headersReceived(int status) {
    if (!_live) return;
    super.headersReceived(status);
    _c._mergeAttemptEvidence(
      _token,
      _attemptId,
      stage: stage,
      httpStatus: status,
    );
  }

  @override
  void firstEvent(String type) {
    if (!_live) return;
    super.firstEvent(type);
    // Heartbeat included: a heartbeat records firstEvent but NEVER an ack
    // (§5.1 — the ack comes from the caller's business-event handling).
    _c._mergeAttemptEvidence(
      _token,
      _attemptId,
      stage: stage,
      firstEventType: type,
    );
  }

  @override
  void failedBeforeDispatch(String failureKind) {
    if (!_live) return;
    super.failedBeforeDispatch(failureKind);
    // The ONLY path allowed to CAS a live attempt to notDispatched:
    // structured before-dispatch evidence AND no earlier dispatch record.
    if (!neverDispatched) return;
    _c._mergeAttemptEvidence(
      _token,
      _attemptId,
      delivery: AttemptDelivery.notDispatched,
      failureKind: failureKind,
      evidence: const {'decision': 'failedBeforeDispatch'},
    );
  }
}
