import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import '../../diagnostics/diagnostics.dart';
import '../../api/hermes_repository.dart';
import '../../l10n/app_strings.dart';
import '../../l10n/message_key.dart';
import '../../l10n/ui_message.dart';
import '../../models/message.dart';
import '../../models/session_activity.dart';
import '../settings/local_store.dart';
import 'live_turn.dart';
import 'turn_history_match.dart';
import 'viewers.dart';

enum ChatPhase { idle, sending, recovering, uncertain }

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
  }) : wait = wait ?? ((duration) => Future<void>.delayed(duration)),
       serverUrl = serverUrl ?? repo.baseUrl,
       _now = now ?? DateTime.now,
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
  final HermesRepository repo;
  final LocalStore store;
  final String sid, serverUrl;

  /// AUDIT-21 (D2): lease heartbeat cadence — well inside the store's
  /// pendingLease so a live owner never loses its claim to a takeover.
  final Duration leaseInterval;

  /// Server emits `: keepalive` frames on idle chat streams, so silence longer
  /// than this means the socket is wedged rather than the run being slow.
  static const silenceLimit = Duration(seconds: 75);

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
  Future<void>? _settleGate;
  Future<void>? _recovery;
  Future<void>? _foregroundCheck;
  Future<bool>? _reconcileFlight; // single-flight GET across ALL observers

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
    ActivityFreshness.stale =>
      observedActivity?.activeRuns.isNotEmpty ?? false,
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
          // Bootstrap-observation uncertain (timer expired): the REAL
          // read-only re-check path, not a fresh recover() backoff.
          if (_detached || _watchTimer != null) {
            unawaited(_pollRun(fresh: true));
          } else if (phase == ChatPhase.uncertain) {
            unawaited(retryReconcile());
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
        if (await _reconcile()) return;
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
    return messages.any(
      (m) =>
          !_beforeSend.contains(m.id) &&
          m.isUserTurn &&
          foldedTurnTextEquals(m.content, p),
    );
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
    if (p != null && !pendingDelivered) return p;
    if (live == null) {
      final b = _bootUserText;
      if (b != null && !_bootstrapInspection().anchorFound) return b;
    }
    return null;
  }

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

  bool isLocallyRepresentedRun(ActivityRun r) {
    final id = r.runId;
    return id != null &&
        (id == activeRunId || id == _localOwnedRunId || id == _bootRunId);
  }

  bool _unknownPreviewOverlapsPending(ActivityRun r) {
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

  Future<void> _activityTick() =>
      _disposed ? Future.value() : _activityFlight ??= _activitySnapshot()
          .whenComplete(() => _activityFlight = null);

  Future<void> _activitySnapshot() async {
    final token = _turnToken;
    final epoch = _activityEpoch;
    final fresh =
        !_disposed && identical(_turnToken, token) && epoch == _activityEpoch;
    try {
      final snap = await repo.sessionActivity(sid);
      if (!fresh) return;
      _applyActivity(snap, token);
    } on ApiException catch (e) {
      if (!fresh) return;
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
    } catch (_) {
      if (!fresh) return;
      activityFreshness = observedActivity == null
          ? ActivityFreshness.unknown // cold fail: still unconfirmed
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
    }
    final remoteGone =
        prev != null &&
        remoteActive(prev.activeRuns, activeRunId).any(
          (r) => !snap.activeRuns.any((x) => x.observationId == r.observationId),
        );
    observedActivity = snap;
    lastActivitySuccess = DateTime.now();
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
        if (!isLocallyRepresentedRun(r) && r.user != null &&
            !snap.activeRuns.any((a) => a.observationId == r.observationId)) r,
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
      if (_unknownPreviewOverlapsPending(r)) continue;
      final raw = text ?? '';
      final hint = r.isTerminal
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
  bool get _bootstrapWaiting => _bootActive && live == null && pendingInput == null;

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
    if (!_detached) return;
    _detached = false;
    _watchTimer?.cancel();
    _watchTimer = null;
    if (busy) unawaited(_pollRun(fresh: true));
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
          settled = await _reconcile();
        } catch (_) {}
        if (settled) return;
        if (!_owns(token)) return; // the turn was settled/replaced mid-GET
        if (await _budgetGate(token)) return; // expiry during the GETs
        _ensurePollTimer(token); // AUDIT-05①: keep the schedule, don't strand busy
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
          settled = await _reconcile();
        } catch (_) {}
        if (settled || !_owns(token)) return;
        if (!busy) return;
        final quiet = await _quietRound(
          token,
          _recoveryEpoch,
          () async {
            try {
              await _reconcile();
            } catch (_) {}
          },
        );
        if (!_owns(token)) return;
        if (await _budgetGate(token)) return;
        final pendingTurn = store.loadPending(serverUrl, sid);
        final verdict = evaluateRecoveryEvidence(
          runGone: true,
          quietConfirmed: quiet,
          activeConfirmed:
              activityFreshness == ActivityFreshness.fresh &&
              (observedActivity?.activeRuns.any((r) => !r.isTerminal) ??
                  false),
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
          _stopRequestedFor(runId) ? StopNotice.accepted : StopNotice.serverEnded,
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
        turn.approval = Map<String, dynamic>.from(a);
        turn.approvalChoice = null;
        notifyListeners();
      }
      _ensurePollTimer(token); // AUDIT-05①: the card waits WITH a live scheduler
      return; // the card lets the user answer from here
    }
    // Still running: make sure SOMETHING keeps polling — attach() may have
    // cleared the timer mid-request, and there is no SSE re-subscribe route.
    _ensurePollTimer(token);
  }
  bool approvalBusy = false;
  bool get canControl => live?.runId != null && !live!.completed && busy;

  // ---- stopping a turn the user can see but the SSE may not know ----------
  // runId order for a stop target: live turn → bootstrap-known runId →
  // persisted pending record. `canControl` stays SSE-only (steer needs a live
  // socket); stopping only needs a runId and a read-only settle path.
  bool _stopping = false, _stopBusyTick = false;
  String? _stopRunId;
  int _stopFails = 0;
  int reconnects = 0;

  String? get activeRunId {
    final l = live;
    if (l != null) return l.completed ? null : l.runId;
    if (!busy) return null;
    if (_stopping) return _stopRunId;
    if (_bootRunId != null) return _bootRunId;
    return store.loadPending(serverUrl, sid)?.runId;
  }

  bool get canStop => !stopBusy && !_stopping && activeRunId != null;

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
    if (turn == null || id == null || turn.approval == null || approvalBusy) return;
    approvalBusy = true;
    notifyListeners();
    try {
      await repo.resolveApproval(id, choice);
      if (_disposed || !identical(live, turn) || !identical(_turnToken, token)) {
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
    _leaseTimer?.cancel();
    _leaseTimer = null;
    _disposed = true;
    _recoveryEpoch++;
    _turnToken = null; // retire every observer of every retired turn
    _settledTurn = null;
    _settleGate = null;
    WidgetsBinding.instance.removeObserver(this);
    ChatViewers.unregister(sid, this); // eviction ledger follows dispose
    _silenceWatch?.cancel();
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
  /// new turn began must never overwrite that turn's messages.
  Future<void> _latest([Object? token]) async {
    final page = await repo.messages(sid);
    if (_disposed || !identical(_turnToken, token)) return;
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
  }

  /// Cold-start / re-entry entry (replaces attach()+load from the page):
  /// read history, then rejoin a turn the persisted pending record says is
  /// still outstanding — strictly read-only (run status + history), never a
  /// replayed POST. No pending → today's idle behaviour (+ lost reconciliation).
  Future<void> bootstrap() async {
    attach(); // warm re-entry keeps its existing semantics
    if (_disposed || busy || loading || _bootstrapping) return; // duplicate: no-op
    loading = _bootstrapping = true; // AUDIT-09: no send until decided
    error = null;
    notifyListeners();
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
    final pending = store.loadPending(serverUrl, sid);
    if (pending == null) {
      if (store.lostNotice(serverUrl, sid) != null) await _reconcileLost();
      if (!_disposed) notifyListeners();
      return;
    }
    // Adopt the persisted turn as THIS controller's identity (AUDIT-12):
    // every later observer captures the token and stale work dies on it.
    // D2: remember the record's current owner token too — observation may
    // settle (terminal seen), but the clear is compare-and-delete, so it
    // can never wipe a claim another tab took in the meantime. No claim
    // is written here: watching is not owning.
    final adoptToken = _turnToken = Object();
    _pendingToken = pending.token;
    _bootRunId = pending.runId;
    _bootKnownText = pending.hasUserText;
    _bootUserText = pending.hasUserText ? pending.userText : null;
    _bootStartedAt = pending.startedAt;
    _bootFails = 0;
    recoveryNotice = null;
    _bootstrapping = true; // the begin write must not admit a concurrent send
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
        _turnToken = null;
        _pendingToken = null;
        error = const UiMessage.local(MessageKey.chatStateM021);
        notifyListeners();
        return;
      }
      budget = begun.record;
    } catch (_) {
      if (!_disposed) {
        _bootstrapping = false;
        _turnToken = null;
        _pendingToken = null;
        phase = ChatPhase.uncertain;
        error = const UiMessage.local(MessageKey.chatRecoveryStorageFailed);
        notifyListeners();
      }
      return;
    }
    if (!_disposed) _bootstrapping = false;
    if (_disposed || !identical(_turnToken, adoptToken)) return;
    _bootDeadline = budget?.recoveryDeadline;
    _bootRetryUsed = budget?.recoveryRetryUsed ?? false;
    _bootHistoryAfterId = budget?.historyAfterId;
    if (_bootDeadline != null && _clock().isAfter(_bootDeadline!)) {
      // Persisted budget already spent (reload after expiry): uncertain
      // IMMEDIATELY — observing again would be a fresh window in disguise.
      // The ADOPTED identity stays: the 「清除本機等待紀錄」 action and the
      // compare-clear need this turn's token (an expired observation is
      // still THIS page's turn, unlike a mid-adoption takeover mismatch).
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
    notifyListeners();
    _watchTimer?.cancel();
    _watchTimer = Timer.periodic(watchInterval, (_) => unawaited(_bootstrapTick()));
    _armDeadlineTimer();
    _armCountdownTicker();
    unawaited(_bootstrapTick());
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

  /// STUCK-BUSY B3: the deadline fires on its own one-shot timer, so a
  /// hung GET (single-flight guard stuck) can never hold busy past the
  /// budget. Late responses die on the epoch bump below.
  void _armDeadlineTimer() {
    _deadlineTimer?.cancel();
    final deadline = _bootDeadline ?? _budgetDeadline;
    if (deadline == null) return;
    final remaining = deadline.difference(_clock());
    _deadlineTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () => unawaited(_bootActive ? _bootstrapTick() : _budgetTick()),
    );
  }

  /// Budget expiry check shared by the bootstrap ticks and the runId-less
  /// live poll. A CONFIRMED-active run defers it (active outranks the
  /// timer — "仍在執行" is never relabelled incomplete); otherwise the
  /// observation stops here and lands in uncertain with its actions.
  bool _budgetExpiredNow() {
    final deadline = _bootActive ? _bootDeadline : _budgetDeadline;
    if (deadline == null || !_clock().isAfter(deadline)) return false;
    final activeFresh =
        (activityFreshness == ActivityFreshness.fresh &&
            (observedActivity?.activeRuns.any((r) => !r.isTerminal) ??
                false)) ||
        (_lastActiveSeen != null &&
            _clock().difference(_lastActiveSeen!) <= recoveryInitialWindow);
    if (activeFresh) {
      _armDeadlineTimer(); // still working: watch the NEXT window edge
      return false;
    }
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
      (_bootActive ? _bootRetryUsed : _budgetRetryUsed)
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
      final begun = await store.beginPendingRecovery(
        serverUrl,
        sid,
        token: _pendingToken ?? store.loadPending(serverUrl, sid)?.token,
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
        // queued/running/waiting_for_approval: still going, keep watching.
        _lastActiveSeen = _clock();
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
      if (_disposed || !identical(_turnToken, token)) return; // new turn owns state
      messages = mergeMessages(messages, page);
      _offset += page.length; // Raw page size, NOT de-duplicated rendered rows.
      hasOlder = page.length == 200;
      // GHOST-DUP B1: older rows can satisfy an observation's claim — the
      // projection must be rebuilt BEFORE the finally's notify paints. The
      // LATEST-page revision bookkeeping is deliberately NOT touched.
      _refreshUserProjections();
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

  Future<void> send(String input, {String? draft}) async {
    if (sendBlocked || input.trim().isEmpty) return; // AUDIT-09 gate
    final spentDraft = draft ?? input;
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
    _beforeSend
      ..clear()
      ..addAll(messages.map((m) => m.id));
    pendingInput = input;
    live = LiveTurn();
    final turn = live!;
    phase = ChatPhase.sending;
    error = null;
    _setStop(StopNotice.none);
    _lastEventAt = DateTime.now();
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
    final claim = await store.claimPending(
      serverUrl,
      sid,
      userText: input,
      turnId: '${++_turnSeq}', // turn layer; the tab layer lives in the store
      startedAt: pendingSince,
      historyAfterId: historyAfterId,
    );
    _pendingStart = false;
    if (_disposed) return;
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
      }
      return;
    }
    _pendingToken = claim;
    _leaseTimer = Timer.periodic(
      leaseInterval,
      (_) => unawaited(_leaseTick()),
    );
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
      if (!backgrounded &&
          phase == ChatPhase.sending &&
          DateTime.now().difference(_lastEventAt) > silenceLimit) {
        _silenceWatch?.cancel();
        unawaited(recover());
      }
    });
    try {
      await for (final event in repo.chat(sid, input)) {
        if (!accepted) {
          accepted = true;
          // 送達即清: the first frame proves the server accepted this POST
          // (SSE opened), so the draft is spent NOW. Clearing only after this
          // future resolved missed every path where send() returns late or
          // never (detach→poll takeover, EOF→recover backoff) while the user
          // reopened the page and initState re-loaded the stale draft.
          if (spentDraft.isNotEmpty &&
              store.draft(serverUrl, sid) == spentDraft) {
            await store.saveDraft(serverUrl, sid, '');
          }
        }
        if (_disposed) return;
        if (!identical(live, turn) || !identical(_turnToken, token)) continue;
        _lastEventAt = DateTime.now();
        if (event.type == 'heartbeat') {
          continue; // Silence-proof liveness, no repaint.
        }
        live!.apply(event, sid);
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
        }
        notifyListeners();
      }
      if (_disposed || !identical(live, turn)) return;
      if (_detached) return; // socket cut on purpose; _pollRun owns the outcome
      if (!turn.completed) {
        throw const ApiException.local(MessageKey.chatStateM022);
      }
      await _finish(token: token);
    } on ApiException catch (e) {
      if (_disposed || !identical(live, turn) || _detached) return;
      if (e.status != null && e.status! >= 400 && e.status! < 500) {
        // 4xx = the server rejected the POST outright: nothing to recover.
        // Settle through the gate so the send gate stays shut until the
        // pending record is really cleared (AUDIT-12/04).
        await _settleTurn(
          token,
          errorMessage: UiMessage.local(
            MessageKey.chatStateM023,
            args: {'error': e.uiMessage},
          ),
        );
        // Keep input visible to the user; no automatic retry of a mutation.
      } else {
        await recover();
      }
    } catch (_) {
      if (_disposed || !identical(live, turn) || _detached) return;
      await recover();
    } finally {
      if (identical(live, turn) || live == null) _silenceWatch?.cancel();
    }
    notifyListeners();
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
      _losePendingOwnership(
        const UiMessage.local(MessageKey.chatStateM021),
      );
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

  /// AUDIT-12: the ONE idempotent settlement gate per turn. Every terminal
  /// exit — SSE finish, poll settle, stop settle, bootstrap settle, reconcile
  /// settle, 4xx rejection — funnels here:
  ///   1. while it runs the send gate stays shut (phase is still busy),
  ///   2. this turn's schedulers/streams die, and ONLY this turn's lost/
  ///      pending records are cleared (a failure leaves them as retry
  ///      evidence — never pretend-clean, never stuck busy),
  ///   3. the turn token retires and the final messages/error publish with a
  ///      REAL idle notification (AUDIT-04).
  Future<void> _settleTurn(
    Object? token, {
    List<Message>? page,
    UiMessage? errorMessage,
  }) async {
    if (_disposed) return;
    if (identical(_settledTurn, token)) {
      final gate = _settleGate;
      if (gate != null) return gate; // same turn settling (again): join, never double-clear
    }
    if (!identical(_turnToken, token)) return; // not my turn anymore: no-op
    _settledTurn = token;
    final gate = _settleCore(token, page: page, errorMessage: errorMessage);
    _settleGate = gate;
    return gate;
  }

  Future<void> _settleCore(
    Object? token, {
    List<Message>? page,
    UiMessage? errorMessage,
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
    _pendingToken = null;
    _budgetBegun = false;
    _budgetDeadline = null;
    _budgetRetryUsed = false;
    _lastActiveSeen = null;
    _bootRetryUsed = false;
    _bootHistoryAfterId = null;
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
    _countdownTicker?.cancel();
    _countdownTicker = null;
    // 3) Publish + release. Only dispose can race here: send can't, the gate
    //    held busy across step 2.
    if (_disposed || !identical(_turnToken, token)) return;
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
  }

  /// Contract has NO replay/resume SSE endpoint. Reconnect read-only history
  /// with 1,2,4,8,16,30s delays; never replay a possibly accepted chat POST.
  /// Original completion frames take precedence; otherwise require a persisted
  /// final after this exact new user row. No terminal run status assumptions.
  Future<void> recover() {
    if (_disposed || !busy) return Future.value();
    if (_recovery != null) return _recovery!;
    reconnects++;
    final epoch = ++_recoveryEpoch;
    final task = _recover(epoch);
    _recovery = task;
    return task.whenComplete(() {
      if (epoch == _recoveryEpoch) _recovery = null;
    });
  }

  Future<void> _recover(int epoch) async {
    final token = _turnToken;
    _silenceWatch?.cancel();
    repo.releaseStreamKeepalive(sid);
    phase = ChatPhase.recovering;
    for (final seconds in [1, 2, 4, 8, 16, 30]) {
      if (!_owns(token) || epoch != _recoveryEpoch) return;
      final budget = _budgetDeadline;
      if (budget != null && _clock().isAfter(budget)) {
        // The consumed 30s re-check window ended mid-backoff: stop with
        // the honest exhausted state, never loop on into a new window.
        phase = ChatPhase.uncertain;
        error = const UiMessage.local(MessageKey.chatRecoveryExhausted);
        notifyListeners();
        return;
      }
      error = UiMessage.local(
        MessageKey.chatStateM026,
        args: {'seconds': seconds},
      );
      notifyListeners();
      await wait(Duration(seconds: seconds));
      if (!_owns(token) || epoch != _recoveryEpoch) return;
      try {
        if (await _reconcile()) return;
      } catch (_) {
        /* Next read-only reconnect attempt. */
      }
      if (!_owns(token) || epoch != _recoveryEpoch) return;
    }
    if (!_owns(token) || epoch != _recoveryEpoch) return;
    // AUDIT-11 regression guard: exhausted rounds MUST leave recovering —
    // dropping this line strands the UI spinning in 「連線中斷…」 forever
    // (both the send-failure and keepalive-recovery paths end here).
    phase = ChatPhase.uncertain;
    // 現況（8700 反代）：SSE 死掉不等於 server 殺 run——反代会替客戶端讀完
    // 串流，run 很可能仍在執行並照常落庫。這裡只在六輪歷史核對都拿不到結果
    // 時才標記 lost，作為「可能中斷」的保守提示；下次冷啟動的 bootstrap 會
    // 依 pending 紀錄用 read-only 輪詢重新驗證，而不是據此宣稱回合已死。
    try {
      await store.markLost(serverUrl, sid);
    } catch (_) {}
    if (!_owns(token) || epoch != _recoveryEpoch) return;
    error = const UiMessage.local(MessageKey.chatStateM027);
    notifyListeners();
  }

  /// Single-flight across EVERY caller (AUDIT-11): one runStatus/history GET
  /// may be in flight for this turn; late joiners wait for the SAME request.
  Future<bool> _reconcile() =>
      _reconcileFlight ??= _reconcileNow().whenComplete(
        () => _reconcileFlight = null,
      );

  Future<bool> _reconcileNow() async {
    final turn = live;
    final token = _turnToken;
    final page = await repo.messages(sid);
    if (!_owns(token) || !identical(live, turn)) return false;
    messages = mergeMessages([], page);
    _offset = page.length;
    hasOlder = page.length == 200;
    // Shared matcher (B1): the pending text in the SAME folded comparison
    // as bootstrap/claims; _beforeSend is this turn's row watermark.
    final inspection = inspectPendingHistory(
      rows: page,
      pendingText: pendingInput,
      excludeIds: _beforeSend,
    );
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
    _setStop(
      StopNotice.lost,
      const UiMessage.local(MessageKey.chatStateM028),
    );
  }

  Future<void> retryReconcile() async {
    if (phase != ChatPhase.uncertain) return;
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
      // Stopping watch hit its bounded-retry cap: resume read-only checks
      // on the SAME runId (kept in memory since the stop POST).
      error = null;
      phase = ChatPhase.recovering;
      _stopFails = 0;
      notifyListeners();
      _watchTimer?.cancel();
      _watchTimer = Timer.periodic(watchInterval, (_) => unawaited(_stopTick()));
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
          _clock().isAfter(retried.recoveryDeadline!)) {
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
    if (token == null) return; // nothing waiting under this identity
    await _settleTurn(token);
  }

  /// Countdown source for the recovering UI (B4): ceil remaining seconds
  /// over the persisted deadline; null = no recovery window in flight.
  int? get recoverySecondsRemaining {
    if (!busy) return null;
    final deadline = _bootDeadline ?? _budgetDeadline;
    if (deadline == null) return null;
    final ms = deadline.difference(_clock()).inMilliseconds;
    return ms <= 0 ? 0 : (ms + 999) ~/ 1000;
  }

  /// Whether the ONE persisted re-check allowance is still unconsumed —
  /// the uncertain UI shows 「重新核對」 only while this is true (B4).
  bool get recoveryRetryAvailable =>
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
  bool get hasLocalWaitingRecord => busy && store.loadPending(serverUrl, sid) != null;

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
    _bootDeadline = deadline;
    _bootRetryUsed = retryUsed;
    if (deadline != null && phase == ChatPhase.recovering) _armCountdownTicker();
  }

  Future<bool> stop() async {
    if (_disposed || stopBusy) return true; // double-tap: the first owns it
    final token = _turnToken; // stop belongs to a TURN (AUDIT-12)
    final run = activeRunId;
    if (run == null) {
      error = const UiMessage.local(MessageKey.chatStateM029);
      notifyListeners();
      return false;
    }
    stopBusy = true;
    error = null;
    _setStop(
      StopNotice.requested,
      const UiMessage.local(MessageKey.chatStateM030),
    );
    notifyListeners();
    var settled = false; // result known → hand the run to the stopping watch
    try {
      await store.saveStop(serverUrl, sid, run, 'requested');
      if (!identical(_turnToken, token)) return true; // turn settled under us
      await repo.stop(run);
      if (!identical(_turnToken, token)) return true;
      _setStop(
        StopNotice.accepted,
        const UiMessage.local(MessageKey.chatStateStoppedByYou),
      );
      await store.saveStop(serverUrl, sid, run, 'accepted');
      if (!identical(_turnToken, token)) return true;
      // A stopped turn is over — the reload-recovery record must die with it,
      // or the next page load resurrects the zombie runId and parks the page
      // in busy (input locked) polling a run the gateway already forgot.
      // The runId itself lives on in `_stopRunId` until the terminal check.
      // D2: compare-and-delete — a record another tab re-claimed is theirs.
      await store.clearPending(serverUrl, sid, token: _pendingToken);
      if (!identical(_turnToken, token)) return true;
      settled = true;
    } on ApiException catch (e) {
      if (!identical(_turnToken, token)) return true; // stale answer, new turn
      if (e.status == 409) {
        // Already being stopped server-side: that IS the request landing.
        // Keep the pending record (a reload must be able to re-check) and
        // poll for the terminal state — no error, no repeat POST.
        settled = true;
      } else if (e.status == 404) {
        // The gateway forgot the run: nothing to wait for. Settle from
        // history now; do not claim the POST itself killed anything, and do
        // NOT upgrade the record to a confirmed user stop.
        _setStop(
          StopNotice.notFound,
          const UiMessage.local(MessageKey.chatStateM031),
        );
        await store.clearPending(serverUrl, sid, token: _pendingToken);
        if (identical(_turnToken, token)) stopBusy = false;
        await _settleStoppedRun(token);
        return true;
      } else {
        _setStop(
          StopNotice.failed,
          UiMessage.local(
            MessageKey.chatStateM032,
            args: {'error': messageForError(e)},
          ),
        );
      }
    } catch (e) {
      if (!identical(_turnToken, token)) return true;
      // Transport-class failure: pending and the current observation stay
      // untouched; the user may retry. Never write accepted here.
      _setStop(
        StopNotice.failed,
        UiMessage.local(
          MessageKey.chatStateM032,
          args: {'error': messageForError(e)},
        ),
      );
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
      _watchTimer = Timer.periodic(watchInterval, (_) => unawaited(_stopTick()));
      unawaited(_stopTick());
    }
    // live / detached paths keep their existing owner (SSE or _pollRun, which
    // already understands a stopped run's 404).
    notifyListeners();
    return settled;
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
        return; // Transient: bounded retry.
      }
      if (!_owns(token) || !_stopping) return;
      _stopFails = 0;
      final state = status['status'];
      if (state == 'completed' || state == 'cancelled' || state == 'failed') {
        await _settleStoppedRun(token, keepStopSource: true);
      }
      // queued/running/waiting_for_approval: the stop is still draining.
    } finally {
      if (!_disposed) _stopBusyTick = false;
    }
  }

  /// Common settle for a user-stopped run: refresh history FIRST (best-effort),
  /// then release busy — a history-refresh failure must not re-arm running,
  /// it only adds a retry hint. The token guard keeps a delayed stop response
  /// from a RETIRED turn from touching the current turn (AUDIT-12).
  Future<void> _settleStoppedRun(Object? token, {bool keepStopSource = false}) async {
    if (!_owns(token)) return;
    if (keepStopSource && _stopRunId != null && _stopRequestedFor(_stopRunId!)) {
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
}
