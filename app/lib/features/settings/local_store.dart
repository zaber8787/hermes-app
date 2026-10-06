import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../l10n/app_locale.dart';
import '../../platform/store_tx.dart';
import '../attachments/attachment.dart';
import '../chat/local_attempt.dart';
import 'key_vault.dart';
import 'server_url.dart';

class AppSettings {
  const AppSettings({this.url = defaultUrl, this.key = ''});
  final String url, key;

  /// A page may only start networking with a VALID server URL *and* a key —
  /// a stored-but-blank or junk URL must land on SettingsPage, never fire
  /// requests at a relative endpoint (ENVHYGIENE §4.1.2).
  bool get configured => isValidServerUrl(url) && key.trim().isNotEmpty;

  /// Per-install endpoints come from --dart-define only (build_app.sh):
  /// public builds compile both to '' and the app stays on the settings
  /// page until the user supplies their own server. Nothing hardcodes any
  /// operator's host, and no port-wide 8642->8700 guesswork happens.
  static const defaultUrl = String.fromEnvironment(
    'HERMES_APP_DEFAULT_URL',
    defaultValue: '',
  );
  static const legacyUrl = String.fromEnvironment(
    'HERMES_APP_LEGACY_URL',
    defaultValue: '',
  );
}

/// Minimal identity of a turn this client started but has not seen finish:
/// enough to rejoin the run (runId) or recognise its rows in history after
/// a page reload. Nullable runId covers "reload before run.started".
///
/// AUDIT-21 (D2) adds the cross-tab ownership layer: a TWO-LAYER token
/// (`tabId|turnId` — which client instance holds it × which send) plus a
/// lease deadline that the owning tab heartbeats while its turn lives.
/// Records written before D2 parse with all three null: they carry no
/// owner, may be claimed by any tab, and keep the AUDIT-12 identity
/// semantics untouched (schema migration by tolerance, not rewriting).
class PendingTurn {
  const PendingTurn({
    this.runId,
    required this.userText,
    required this.startedAt,
    this.hasUserText = true,
    this.ownerTab,
    this.ownerTurn,
    this.leaseUntil,
    this.recoveryStartedAt,
    this.recoveryDeadline,
    this.recoveryRetryUsed = false,
    this.historyAfterId,
    this.origin,
    this.wakeBatchId,
    this.attemptId,
  });
  final String? runId;
  final String userText;
  final DateTime startedAt;
  final String? ownerTab, ownerTurn;
  final DateTime? leaseUntil;

  /// OFFLINE-SEND R2 §4.1: the durable attempt identity this record belongs
  /// to. Null on every record written before R2 (migrated exactly once,
  /// inside the first lock-based op that touches it) and on autoWake
  /// records (an auto-wake dispatch is never a human attempt).
  final String? attemptId;

  /// APPWAKE: backward-compatible origin tag. Null = ordinary human send
  /// (byte-identical old semantics); 'autoWake' marks a coordinator turn
  /// carrying [wakeBatchId] (the durable server receipt identity).
  final String? origin;
  final String? wakeBatchId;
  bool get isAutoWake => origin == 'autoWake';

  // ---- STUCK-BUSY B3: persisted recovery budget ---------------------------
  // The FIRST entry into recovery stamps started_at/deadline (now + initial
  // window); a reload adopts them instead of re-arming a fresh window. The
  // retry flag is consumed exactly once, atomically, for ALL retry paths.
  // All four fields are OPTIONAL on disk: legacy records parse with
  // null/false and migrate on their first recovery (never rewritten just
  // because they were read).
  final DateTime? recoveryStartedAt, recoveryDeadline;
  final bool recoveryRetryUsed;

  /// Max numeric history id observed BEFORE the send POST — a row
  /// watermark for dropping older same-text candidates, never proof of
  /// content attribution (B3).
  final int? historyAfterId;

  /// OFFLINE-SEND R1: the ONLY flag decision code may read — a PARSEABLE
  /// deadline exists, i.e. a bounded observation window is genuinely in
  /// flight. Watermark/owner/wake metadata alone is NOT a budget (A1): a
  /// watermark-only legacy record must still get its first 60s window.
  bool get hasRecoveryBudget => recoveryDeadline != null;

  /// Raw-field presence only (legacy reporting/diagnostics). NEVER use this
  /// to decide begin/consume: it counts watermarks as "recovery metadata"
  /// and turns watermark-only records into budget-less zombies (A1 fix).
  bool get hasRecoveryMetadata =>
      recoveryStartedAt != null ||
      recoveryDeadline != null ||
      recoveryRetryUsed ||
      historyAfterId != null;

  /// Compare tag for claim/amend/clear; null = unowned (legacy or empty).
  String? get token => ownerTab == null && ownerTurn == null
      ? null
      : '${ownerTab ?? ''}|${ownerTurn ?? ''}';

  /// False only for legacy records written WITHOUT a `user_text` field. A
  /// genuinely empty string (`''`, a whitespace-free re-send) keeps true so
  /// the empty-text turn can still anchor; a MISSING field cannot anchor and
  /// must be observed, never fabricated (AUDIT-12).
  final bool hasUserText;
  factory PendingTurn.fromJson(Map<String, dynamic> json) => PendingTurn(
    runId: json['run_id'] as String?,
    userText: json['user_text'] as String? ?? '',
    startedAt:
        DateTime.tryParse(json['started_at'] as String? ?? '') ??
        DateTime.now(),
    hasUserText: json.containsKey('user_text'),
    ownerTab: json['owner_tab'] as String?,
    ownerTurn: json['owner_turn'] as String?,
    leaseUntil: DateTime.tryParse(json['lease_until'] as String? ?? ''),
    recoveryStartedAt: DateTime.tryParse(
      json['recovery_started_at'] as String? ?? '',
    ),
    recoveryDeadline: DateTime.tryParse(
      json['recovery_deadline'] as String? ?? '',
    ),
    recoveryRetryUsed: json['recovery_retry_used'] == true,
    historyAfterId: (json['history_after_id'] as num?)?.toInt(),
    origin: json['origin'] as String?,
    wakeBatchId: json['wake_batch_id'] as String?,
    attemptId: json['attempt_id'] is String &&
            (json['attempt_id'] as String).isNotEmpty
        ? json['attempt_id'] as String
        : null,
  );
}

class LocalStore {
  LocalStore(this.prefs, {KeyVault? vault}) : vault = vault ?? newKeyVault();
  final SharedPreferences prefs;
  final KeyVault vault;
  Future<AppSettings> loadSettings() async => AppSettings(
    url: _resolveUrl(prefs.getString('server.url')),
    key: await vault.read('server.key') ?? '',
  );

  /// Precedence (§4.1.3): a valid stored URL wins — and ONLY an exact match
  /// against a non-empty legacy define with a valid target migrates (public
  /// builds carry no legacy value, so other people's 8642 URLs are never
  /// rewritten). A stored blank counts as missing; a stored INVALID value
  /// is kept verbatim for the user to fix (configured=false, no silent
  /// switch to another station). With nothing stored: Web falls back to
  /// its own origin (never an Android define), Android to the compile-time
  /// default — possibly '' (fresh public install: SettingsPage, zero
  /// requests).
  static String _resolveUrl(String? saved) {
    final value = saved?.trim() ?? '';
    if (value.isNotEmpty) {
      if (AppSettings.legacyUrl.isNotEmpty &&
          value == AppSettings.legacyUrl &&
          isValidServerUrl(AppSettings.defaultUrl)) {
        return AppSettings.defaultUrl;
      }
      return value;
    }
    if (kIsWeb) return Uri.base.origin;
    return AppSettings.defaultUrl;
  }

  Future<void> saveSettings(AppSettings value) async {
    await vault.write('server.key', value.key);
    await prefs.setString('server.url', value.url);
  }

  // ---- I18N: global UI language (I18N-PLAN §4.2) --------------------------
  // `ui.locale` is GLOBAL (never _scope-d), independent of credentials: a
  // corrupt/missing value normalizes to English and must never block
  // settings loading, and a saved language must survive a vault failure.
  AppLocale loadLocale() => AppLocale.normalize(prefs.getString('ui.locale'));
  Future<bool> saveLocale(AppLocale value) async {
    try {
      // false (write refused) or a throw is a failure; the caller keeps
      // the old locale and surfaces the descriptor-based warning.
      return await prefs.setString('ui.locale', value.tag);
    } catch (_) {
      return false;
    }
  }

  String _scope(String server, String sid, String field) =>
      '${Uri.encodeComponent(server)}.$sid.$field';

  // WAVE4 §3.7: management section collapse is per SERVER (never per
  // session, never in the pending namespace): the "sid" slot of _scope is
  // the literal 'management' and field carries '<section>.collapsed'.
  static const managementSections = {'skills', 'model'};
  bool managementSectionCollapsed(String server, String section) {
    assert(managementSections.contains(section));
    return prefs.getBool(_scope(server, 'management', '$section.collapsed')) ??
        false;
  }

  Future<void> setManagementSectionCollapsed(
    String server,
    String section,
    bool value,
  ) {
    assert(managementSections.contains(section));
    return prefs.setBool(
      _scope(server, 'management', '$section.collapsed'),
      value,
    );
  }

  bool detailed(String server, String sid) =>
      prefs.getBool(_scope(server, sid, 'detail')) ?? false;
  Future<void> setDetailed(String server, String sid, bool value) =>
      prefs.setBool(_scope(server, sid, 'detail'), value);
  String? readFingerprint(String server, String sid) =>
      prefs.getString(_scope(server, sid, 'read'));
  Future<void> markRead(String server, String sid, String fingerprint) =>
      prefs.setString(_scope(server, sid, 'read'), fingerprint);
  String? stopRecord(String server, String sid) =>
      prefs.getString(_scope(server, sid, 'stop'));
  Future<void> saveStop(String server, String sid, String run, String status) =>
      prefs.setString(
        _scope(server, sid, 'stop'),
        jsonEncode({'run_id': run, 'status': status}),
      );

  // ---- P2: per-session input draft (survives navigation AND app kill) ----
  // OFFLINE-SEND R2 §4.3: every composer write goes through the same draft
  // CAS rule — a monotonically bumped revision int, never the text itself,
  // is the write-ownership token. A late callback holding an old revision
  // must not overwrite what a newer editor (or restore) stored.
  String draft(String server, String sid) =>
      prefs.getString(_scope(server, sid, 'draft')) ?? '';

  /// Persisted composer-write counter: 0 until the first write. NOT a
  /// content hash — equal text at a new revision is still a new write.
  int draftRevision(String server, String sid) =>
      prefs.getInt(_scope(server, sid, 'draftRev')) ?? 0;

  /// Write the draft and bump the revision. With `expectedRevision` set,
  /// a stale counter refuses the write outright (false, nothing touched).
  /// False = stale expectation OR the prefs write was refused.
  Future<bool> saveDraftCas(
    String server,
    String sid,
    String text, {
    int? expectedRevision,
  }) async {
    if (expectedRevision != null &&
        draftRevision(server, sid) != expectedRevision) {
      return false;
    }
    final key = _scope(server, sid, 'draft');
    // Empty means GONE, not "an empty string is stored": a refused remove
    // that nonetheless left no value counts (same discipline as pending).
    final ok = text.isEmpty
        ? await prefs.remove(key) || prefs.getString(key) == null
        : await prefs.setString(key, text);
    if (!ok) return false;
    // The counter bump is best effort after a durable text write; losing
    // it only weakens the CAS to last-writer-wins, it never reorders text.
    await prefs.setInt(_scope(server, sid, 'draftRev'), draftRevision(server, sid) + 1);
    return true;
  }

  /// Pre-R2 writer kept as-is (`Future<void>`): writes through the same
  /// CAS path so the revision bumps, but the write result is not surfaced.
  Future<void> saveDraft(String server, String sid, String text) async {
    await saveDraftCas(server, sid, text);
  }

  List<AttachmentDraft> attachments(String server, String sid) {
    final raw = prefs.getString(_scope(server, sid, 'attachments'));
    if (raw == null) return [];
    return (jsonDecode(raw) as List)
        .map(
          (e) => AttachmentDraft.fromJson(Map<String, dynamic>.from(e as Map)),
        )
        .toList();
  }

  Future<void> saveAttachments(
    String server,
    String sid,
    List<AttachmentDraft> values,
  ) => prefs.setString(
    _scope(server, sid, 'attachments'),
    jsonEncode(values.map((a) => a.toJson()).toList()),
  );

  /// R2 §4.4: the checked variant — false means the snapshot did NOT
  /// persist and the caller must not treat memory as saved. `saveAttachments`
  /// keeps its old `Future<void>` shape for existing out-of-file callers.
  Future<bool> saveAttachmentsChecked(
    String server,
    String sid,
    List<AttachmentDraft> values,
  ) => prefs.setString(
    _scope(server, sid, 'attachments'),
    jsonEncode(values.map((a) => a.toJson()).toList()),
  );

  // ---- APPWAKE: durable wake queue/cursor/receipt state (versioned) -------
  // One JSON blob per normalized server + session. It holds the armed
  // cutoff, the scan cursor (lastSeenOrder — scan progress, NOT proof every
  // older row was woken), the queued report ids + delivery keys, consumed /
  // ignored keys, batch/receipt identities and the uncertain flags. Bearer
  // tokens are never part of any key. A corrupt blob reads as "none" and
  // the next successful latest-page commit rebuilds a fresh armed baseline.
  static const wakeStateVersion = 1;

  Map<String, dynamic>? wakeState(String server, String sid) {
    final raw = prefs.getString(_scope(server, sid, 'wakeState'));
    if (raw == null) return null;
    try {
      final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      if (map['v'] != wakeStateVersion) return null; // foreign shape: none
      return map;
    } catch (_) {
      return null;
    }
  }

  /// True only when the write PERSISTED — callers must not pretend the
  /// queue survived a refused write (same discipline as pending).
  Future<bool> saveWakeState(String server, String sid, Map<String, dynamic> state) =>
      withStoreTx('wake.$server.$sid', () async {
        final payload = {...state, 'v': wakeStateVersion};
        return await prefs.setString(
          _scope(server, sid, 'wakeState'),
          jsonEncode(payload),
        );
      });

  Future<void> clearWakeState(String server, String sid) =>
      withStoreTx('wake.$server.$sid', () => prefs.remove(_scope(server, sid, 'wakeState')));

  // The kill switches are plain booleans, DEFAULT OFF, scoped per server —
  // enabling them is batch D; the coordinator must stay silent while off.
  bool autoWakeEnabled(String server) =>
      prefs.getBool(_scope(server, 'wake', 'enabled')) ?? false;
  Future<void> setAutoWakeEnabled(String server, bool value) =>
      prefs.setBool(_scope(server, 'wake', 'enabled'), value);

  /// Session-level opt-out: true blocks dispatch for THAT session only;
  // reports keep displaying normally.
  bool autoWakeSessionOff(String server, String sid) =>
      prefs.getBool(_scope(server, sid, 'wakeOff')) ?? false;
  Future<void> setAutoWakeSessionOff(String server, String sid, bool value) =>
      prefs.setBool(_scope(server, sid, 'wakeOff'), value);

  // ---- P2: in-flight turn identity so a page reload can rejoin the run ----
  // ---- AUDIT-21 (D2): the same record is also the cross-tab ownership
  // ledger. claim / compare-update / clear all run through the SAME
  // serializer (withStoreTx) keyed per session, so two tabs cannot
  // interleave a read-modify-write on it. ----

  /// How long a lease stays valid without a heartbeat; the owner tab
  /// renews at well under this interval, so a crashed tab's claim expires
  /// on its own and another tab may take over (崩潰接手).
  static const pendingLease = Duration(seconds: 45);

  /// This client instance's layer of every owner token minted here.
  final String tabId = _newTabId();
  static String _newTabId() {
    final r = Random.secure();
    String hex(int n) =>
        List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(8)}';
  }

  /// OFFLINE-SEND R2 §4.1: a durable attempt identity — 128 random bits,
  /// deliberately NOT derived from tabId/turnId: a lease takeover or a
  /// reload must not (re)name the attempt.
  static String newAttemptId() {
    final r = Random.secure();
    return List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  Map<String, dynamic>? _pendingRaw(String server, String sid) {
    final raw = prefs.getString(_scope(server, sid, 'pending'));
    if (raw == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null; // Corrupt or foreign-shape record: treat as none.
    }
  }

  /// WEBSYNC F9: the AUTHORITATIVE pending read for every compare/write.
  /// Web Locks serialize the critical section across tabs, but the
  /// shared_preferences web backend serves getString from a per-instance
  /// `_preferenceCache` that only refreshes on getAll()/reload() — so a
  /// tab that pre-loaded "empty" would still claim successfully INSIDE
  /// the lock. Every transaction must therefore re-read through the
  /// lock before deciding. Unlike the hidden-list helper, the "empty
  /// falls back to the pre-reload view" rule is deliberately NOT applied
  /// here: for the pending slot a foreign DELETION is real state, and
  /// resurrecting it from a stale cache is exactly the bug class this
  /// closes. A store whose reload throws keeps the cache (best effort —
  /// the degraded path is labelled, not hidden).
  Future<Map<String, dynamic>?> _rereadPending(String server, String sid) async {
    try {
      await prefs.reload();
    } on Object {
      /* reload unsupported on this backend: keep the cache */
    }
    return _pendingRaw(server, sid);
  }

  /// WEBSYNC F9 degraded path, stated out loud once per tab — and stated
  /// HONESTLY per OFFLINE-SEND R2 §4.5/A10: without Web Locks the critical
  /// section only SERIALIZES THIS TAB. Cross-tab claims are not exclusive
  /// (last-writer-wins) AND the cross-tab compare operations (claim /
  /// compare-update / compare-delete) are NOT atomic — another tab can
  /// slip a write in between the reread and the remove. High-risk paths
  /// (local settlement, shared clear) surface cleanupPending instead of
  /// claiming a shared success; `storeTxCapability` reports whether locks
  /// were actually probed, `storeTxIsCrossTab` carries the flag.
  static bool _noLocksWarned = false;
  static void _warnNoWebLocksOnce() {
    if (_noLocksWarned) return;
    _noLocksWarned = true;
    debugPrint(
      'LocalStore: Web Locks unavailable in this browser — storage '
      'transactions serialize THIS tab only; cross-tab claims and '
      'compare-update/compare-delete are NOT atomic. Keep one tab per '
      'server session (R2 §4.5).',
    );
  }

  bool _leaseHeldByOther(Map<String, dynamic> rec, DateTime now) {
    final tab = rec['owner_tab'] as String?;
    if (tab == null) return false; // unowned (legacy): claimable
    final lease = DateTime.tryParse(rec['lease_until'] as String? ?? '');
    if (lease != null && !lease.isAfter(now)) return false; // expired
    return tab != tabId;
  }

  Future<void> _writePending(
    String server,
    String sid, {
    String? runId,
    required String userText,
    required DateTime startedAt,
    String? ownerTurn,
    DateTime? leaseUntil,
    Map<String, dynamic> recovery = const {},
    Map<String, dynamic> wake = const {},
    Map<String, dynamic> attempt = const {},
  }) => prefs.setString(
    _scope(server, sid, 'pending'),
    jsonEncode({
      'run_id': runId,
      'user_text': userText,
      'started_at': startedAt.toIso8601String(),
      if (ownerTurn != null && leaseUntil != null) ...{
        'owner_tab': tabId,
        'owner_turn': ownerTurn,
        'lease_until': leaseUntil.toIso8601String(),
      },
      ...wake,
      ...recovery,
      ...attempt,
    }),
  );

  /// OFFLINE-SEND R2 §4.1: the attempt identity carried over from an
  /// existing record — touch / amend / legacy-save must never drop it
  /// (rebuilding the record from scratch is exactly how a stable identity
  /// would get lost).
  static Map<String, dynamic> _attemptKeys(Map<String, dynamic>? rec) {
    final id = rec?['attempt_id'] is String &&
            (rec!['attempt_id'] as String).isNotEmpty
        ? rec['attempt_id'] as String
        : null;
    return {'attempt_id': ?id};
  }

  /// APPWAKE: the wake identity carried over from an existing record
  /// (touch/amend must never drop it; a NEW claim sets it explicitly).
  static Map<String, dynamic> _wakeKeys(Map<String, dynamic>? rec) {
    final origin = rec?['origin'] is String ? rec!['origin'] as String : null;
    final batch = rec?['wake_batch_id'] is String
        ? rec!['wake_batch_id'] as String
        : null;
    return {'origin': ?origin, 'wake_batch_id': ?batch};
  }

  /// STUCK-BUSY B3: the persisted recovery keys carried over from an
  /// existing record (amend / touch / legacy-save must not erase them).
  static Map<String, dynamic> _recoveryKeys(Map<String, dynamic>? rec) => {
    if (rec?['recovery_started_at'] is String)
      'recovery_started_at': rec!['recovery_started_at'],
    if (rec?['recovery_deadline'] is String)
      'recovery_deadline': rec!['recovery_deadline'],
    if (rec?['recovery_retry_used'] == true) 'recovery_retry_used': true,
    if (rec?['history_after_id'] is num)
      'history_after_id': rec!['history_after_id'],
  };

  static Map<String, dynamic> _recoveryJson(
    DateTime started,
    DateTime deadline,
    bool retryUsed,
    int? historyAfterId,
  ) => {
    'recovery_started_at': started.toIso8601String(),
    'recovery_deadline': deadline.toIso8601String(),
    if (retryUsed) 'recovery_retry_used': true,
    'history_after_id': ?historyAfterId,
  };

  /// True when a compare-and-set write was REFUSED (false from
  /// setString) — the caller must not pretend the state persisted.
  Future<void> _setPendingJson(String server, String sid, String json) async {
    if (!await prefs.setString(_scope(server, sid, 'pending'), json)) {
      throw const PendingPersistenceFailure();
    }
  }

  String _attemptKey(String server, String sid, String attemptId) =>
      _scope(server, sid, 'attempt.$attemptId');

  /// Persist ONE journal entry and confirm it. False = the write was
  /// refused or the readback disagreed; the caller decides what that
  /// means for its own operation. Journal + pending are separate prefs
  /// keys — no ACID claim: ordering (journal first) is the guarantee.
  Future<bool> _writeAttempt(
    String server,
    String sid,
    String attemptId,
    Map<String, dynamic> json,
  ) async {
    if (debugFailAttemptWrites) return false;
    final key = _attemptKey(server, sid, attemptId);
    final payload = jsonEncode(json);
    final bool ok;
    try {
      ok = await prefs.setString(key, payload);
    } on Object {
      return false;
    }
    if (!ok) return false;
    try {
      return prefs.getString(key) == payload; // readback (§4.2 step 2)
    } on Object {
      return false;
    }
  }

  /// R2 §4.1: the record's attempt identity, guaranteed to EXIST for
  /// human records by the time the calling (locked) op writes the record.
  /// A legacy human record (no attempt_id) mints exactly once here — its
  /// journal entry (rawDraft null: the raw text is genuinely unknown)
  /// lands BEFORE the pending stamp, so every later op sees the SAME id
  /// and never mints a second one. autoWake records are never migrated:
  /// a coordinator dispatch is not a human attempt. Storage refusal
  /// throws before the pending write — nothing half-stamped survives.
  Future<String?> _migrateAttemptLocked(
    String server,
    String sid,
    Map<String, dynamic> rec,
  ) async {
    final existing = rec['attempt_id'];
    if (existing is String && existing.isNotEmpty) return existing;
    if (rec['origin'] == 'autoWake') return null;
    final id = newAttemptId();
    if (!await _writeAttempt(
      server,
      sid,
      id,
      LocalAttempt(
        attemptId: id,
        server: server,
        sid: sid,
        createdAt:
            DateTime.tryParse(rec['started_at'] as String? ?? '') ??
            DateTime.now(),
        runId: rec['run_id'] is String ? rec['run_id'] as String : null,
      ).toJson(),
    )) {
      throw const PendingPersistenceFailure();
    }
    return id;
  }

  /// B3 / OFFLINE-SEND R1 §3.2: stamp the recovery budget onto a pending
  /// record EXACTLY ONCE, inside the same per-session store transaction as
  /// claim/amend/clear, after RELOADING the authoritative prefs and matching
  /// the captured token. Migration is shape-driven (never "metadata seen →
  /// freeze"): a watermark-only record gets its first 60s window NOW; a
  /// valid deadline survives verbatim; a spent retry allowance migrates to
  /// an already-expired deadline (never a fresh 30s). The window starts at
  /// the FIRST entry into unknown recovery, never at the send's startedAt.
  Future<PendingRecoveryResult> beginPendingRecovery(
    String server,
    String sid, {
    String? token,
    Duration initialWindow = const Duration(seconds: 60),
    DateTime? now,
  }) => withStoreTx('pending.$server.$sid', () async {
    final at = now ?? DateTime.now();
    final rec = await _rereadPending(server, sid);
    if (rec == null) {
      return const PendingRecoveryResult(PendingRecoveryOutcome.missing, null);
    }
    final current = rec['owner_tab'] == null && rec['owner_turn'] == null
        ? null
        : '${rec['owner_tab']}|${rec['owner_turn']}';
    if (current != token) {
      return const PendingRecoveryResult(PendingRecoveryOutcome.mismatch, null);
    }
    final turn = PendingTurn.fromJson(rec);
    // R2 §4.1: this op is one of the sanctioned one-shot migration
    // points — a legacy HUMAN record mints (and journals) its attemptId
    // here, exactly once, before any branch writes the record.
    final hadAttempt =
        rec['attempt_id'] is String && (rec['attempt_id'] as String).isNotEmpty;
    final migrated = hadAttempt
        ? rec['attempt_id'] as String
        : await _migrateAttemptLocked(server, sid, rec);
    if (turn.recoveryDeadline != null) {
      // Valid deadline present: keep it verbatim. A missing recovery
      // started stamp MAY be back-computed (deadline − window) — that
      // never extends anything, it only documents the window's origin.
      if (turn.recoveryStartedAt == null) {
        await _setPendingJson(
          server,
          sid,
          jsonEncode({
            ...rec,
            'attempt_id': ?migrated,
            'recovery_started_at':
                turn.recoveryDeadline!.subtract(initialWindow).toIso8601String(),
          }),
        );
        return PendingRecoveryResult(
          PendingRecoveryOutcome.alreadyPresent,
          PendingTurn.fromJson(_pendingRaw(server, sid)!),
        );
      }
      if (!hadAttempt && migrated != null) {
        // Migration-only stamp: the budget itself stays verbatim.
        await _setPendingJson(
          server,
          sid,
          jsonEncode({...rec, 'attempt_id': migrated}),
        );
        return PendingRecoveryResult(
          PendingRecoveryOutcome.alreadyPresent,
          PendingTurn.fromJson(_pendingRaw(server, sid)!),
        );
      }
      return PendingRecoveryResult(
        PendingRecoveryOutcome.alreadyPresent,
        turn,
      );
    }
    // No parseable deadline. A record whose single retry allowance is
    // ALREADY spent migrates to an expired deadline — observing it again
    // would be a second 30s window in disguise.
    if (turn.recoveryRetryUsed) {
      await _setPendingJson(
        server,
        sid,
        jsonEncode({
          ...rec,
          'attempt_id': ?migrated,
          ..._recoveryJson(turn.recoveryStartedAt ?? at, at, true, turn.historyAfterId),
        }),
      );
      return PendingRecoveryResult(
        PendingRecoveryOutcome.begun,
        PendingTurn.fromJson(_pendingRaw(server, sid)!),
      );
    }
    // Recovery started earlier but the deadline write crashed midway:
    // complete the ORIGINAL window (started + window) — expired means
    // expired, never re-based to now+60.
    if (turn.recoveryStartedAt != null) {
      final deadline = turn.recoveryStartedAt!.add(initialWindow);
      await _setPendingJson(
        server,
        sid,
        jsonEncode({
          ...rec,
          'attempt_id': ?migrated,
          ..._recoveryJson(turn.recoveryStartedAt!, deadline, false, turn.historyAfterId),
        }),
      );
      return PendingRecoveryResult(
        PendingRecoveryOutcome.begun,
        PendingTurn.fromJson(_pendingRaw(server, sid)!),
      );
    }
    // Nothing time-shaped (including watermark-only legacy records): this
    // is the FIRST entry into unknown recovery — stamp now + window once.
    await _setPendingJson(
      server,
      sid,
      jsonEncode({
        ...rec,
        'attempt_id': ?migrated,
        ..._recoveryJson(at, at.add(initialWindow), false, turn.historyAfterId),
      }),
    );
    return PendingRecoveryResult(
      PendingRecoveryOutcome.begun,
      PendingTurn.fromJson(_pendingRaw(server, sid)!),
    );
  });

  /// B3: atomically consume the ONE retry allowance. Only the first
  /// caller (per record token) flips retry_used and re-arms the deadline
  /// at now + retryWindow; every other caller (double tap, second tab,
  /// post-reload) gets `alreadyUsed` and must NOT open a new window —
  /// the persisted deadline is shared verbatim.
  Future<RecoveryRetryResult> consumeRecoveryRetry(
    String server,
    String sid, {
    String? token,
    Duration retryWindow = const Duration(seconds: 30),
    DateTime? now,
  }) => withStoreTx('pending.$server.$sid', () async {
    final at = now ?? DateTime.now();
    final rec = await _rereadPending(server, sid);
    if (rec == null) {
      return const RecoveryRetryResult(RecoveryRetryOutcome.missing, null);
    }
    final current = rec['owner_tab'] == null && rec['owner_turn'] == null
        ? null
        : '${rec['owner_tab']}|${rec['owner_turn']}';
    if (current != token) {
      return const RecoveryRetryResult(RecoveryRetryOutcome.mismatch, null);
    }
    final turn = PendingTurn.fromJson(rec);
    // R1: the retry only extends a window that GENUINELY EXISTS. No
    // parseable deadline (or the flag-only legacy shape) never buys a
    // fresh 30s — the caller observes the persisted state or lands
    // exhausted, it does not mint budget out of nothing.
    if (!turn.hasRecoveryBudget || turn.recoveryRetryUsed) {
      return RecoveryRetryResult(RecoveryRetryOutcome.alreadyUsed, turn);
    }
    await _setPendingJson(
      server,
      sid,
      jsonEncode({
        ...rec,
        ..._recoveryJson(
          turn.recoveryStartedAt ?? turn.startedAt,
          at.add(retryWindow),
          true,
          turn.historyAfterId,
        ),
      }),
    );
    return RecoveryRetryResult(
      RecoveryRetryOutcome.consumed,
      PendingTurn.fromJson(_pendingRaw(server, sid)!),
    );
  });

  /// Pre-D2 writers kept this API; records it produces are UNOWNED
  /// (anyone may claim; compare-clear sees token null == null).
  Future<void> savePending(
    String server,
    String sid, {
    String userText = '',
    String? runId,
    DateTime? startedAt,
  }) => withStoreTx('pending.$server.$sid', () async {
    final now = DateTime.now();
    final rec = await _rereadPending(server, sid);
    await _writePending(
      server,
      sid,
      runId: runId ?? rec?['run_id'] as String?,
      userText: userText.isEmpty
          ? (rec?['user_text'] as String? ?? '')
          : userText,
      // STUCK-BUSY B3: the startedAt argument was silently ignored until
      // now (only the old value or now was used). It wins when given.
      startedAt:
          startedAt ??
          DateTime.tryParse(rec?['started_at'] as String? ?? '') ??
          now,
      recovery: _recoveryKeys(rec),
      wake: _wakeKeys(rec),
      attempt: _attemptKeys(rec),
    );
  });

  PendingTurn? loadPending(String server, String sid) {
    final rec = _pendingRaw(server, sid);
    if (rec == null) return null;
    try {
      return PendingTurn.fromJson(rec);
    } catch (_) {
      return null;
    }
  }

  /// Take ownership of the session's pending slot BEFORE a chat POST.
  /// Returns the two-layer token to keep, or null when another tab's
  /// lease is still alive — the caller must then NOT POST (a second run
  /// on one conversation is exactly what this prevents). A stale lease
  /// (crashed tab) is silently takeable.
  Future<String?> claimPending(
    String server,
    String sid, {
    required String userText,
    required String turnId,
    DateTime? startedAt,
    int? historyAfterId,
    String? origin,
    String? wakeBatchId,
    Duration lease = pendingLease,
  }) => withStoreTx('pending.$server.$sid', () async {
    final now = DateTime.now();
    if (kIsWeb && !storeTxIsCrossTab) _warnNoWebLocksOnce();
    final rec = await _rereadPending(server, sid);
    if (rec != null && _leaseHeldByOther(rec, now)) return null;
    // A NEW claim belongs to a NEW turn: the old turn's recovery budget
    // must not leak into it (B3 — only metadata set after this claim
    // counts, and begin stamps it at first recovery). Same for the
    // attempt identity (R2): a human claim mints a FRESH id — never a
    // carry-over of the stale record's — while an autoWake dispatch gets
    // none (it never becomes a human attempt).
    final attemptId = origin == 'autoWake' ? null : newAttemptId();
    if (attemptId != null &&
        !await _writeAttempt(
          server,
          sid,
          attemptId,
          LocalAttempt(
            attemptId: attemptId,
            server: server,
            sid: sid,
            createdAt: now,
            origin: 'human',
          ).toJson(),
        )) {
      // Journal refused: the claim is refused BEFORE anything is written,
      // so the caller never POSTs onto an identity-less attempt.
      throw const PendingPersistenceFailure();
    }
    await _writePending(
      server,
      sid,
      userText: userText,
      startedAt: startedAt ?? now,
      ownerTurn: turnId,
      leaseUntil: now.add(lease),
      recovery: {'history_after_id': ?historyAfterId},
      wake: {'origin': ?origin, 'wake_batch_id': ?wakeBatchId},
      attempt: {'attempt_id': ?attemptId},
    );
    return '$tabId|$turnId';
  });

  /// Compare-update the runId onto a record THIS tab claimed, refreshing
  /// the lease. False = the record died or moved to another tab mid-send:
  /// the caller keeps observing its own run read-only but must stop
  /// writing the shared key.
  Future<bool> amendPendingRun(
    String server,
    String sid, {
    required String token,
    required String userText,
    required String runId,
    DateTime? startedAt,
    Duration lease = pendingLease,
  }) => withStoreTx('pending.$server.$sid', () async {
    final now = DateTime.now();
    final rec = await _rereadPending(server, sid);
    if (rec == null) return false;
    final held =
        rec['owner_tab'] == tabId &&
        '${rec['owner_tab']}|${rec['owner_turn']}' == token;
    if (!held) return false;
    final attemptId = await _migrateAttemptLocked(server, sid, rec);
    await _writePending(
      server,
      sid,
      runId: runId,
      userText: userText,
      startedAt:
          DateTime.tryParse(rec['started_at'] as String? ?? '') ??
          startedAt ??
          now,
      ownerTurn: rec['owner_turn'] as String?,
      leaseUntil: now.add(lease),
      recovery: _recoveryKeys(rec),
      wake: _wakeKeys(rec),
      attempt: {'attempt_id': ?attemptId}, // preserved, migrated once §4.1
    );
    return true;
  });

  /// Heartbeat: renew the lease iff this tab still owns the record with
  /// exactly this token. False = ownership moved → stop claiming, watch.
  Future<bool> touchPending(
    String server,
    String sid,
    String token, {
    Duration lease = pendingLease,
  }) => withStoreTx('pending.$server.$sid', () async {
    final now = DateTime.now();
    final rec = await _rereadPending(server, sid);
    if (rec == null) return false;
    // token embeds the tab layer; equality already implies this tab owns it.
    if ('${rec['owner_tab']}|${rec['owner_turn']}' != token) return false;
    final attemptId = await _migrateAttemptLocked(server, sid, rec);
    await _writePending(
      server,
      sid,
      runId: rec['run_id'] as String?,
      userText: rec['user_text'] as String? ?? '',
      startedAt: DateTime.tryParse(rec['started_at'] as String? ?? '') ?? now,
      ownerTurn: rec['owner_turn'] as String?,
      leaseUntil: now.add(lease),
      recovery: _recoveryKeys(rec),
      wake: _wakeKeys(rec),
      attempt: {'attempt_id': ?attemptId}, // preserved, migrated once §4.1
    );
    return true;
  });

  /// Compare-and-delete (AUDIT-12 rule 2 generalized across tabs): only
  /// the holder of `token` may clear; an unowned record is cleared by an
  /// unowned clear (legacy semantics preserved). False = somebody else's
  /// turn is now recorded here — leave their evidence alone.
  Future<bool> clearPending(String server, String sid, {String? token}) =>
      withStoreTx('pending.$server.$sid', () async {
        final rec = await _rereadPending(server, sid);
        if (rec == null) return true;
        final current = rec['owner_tab'] == null && rec['owner_turn'] == null
            ? null
            : '${rec['owner_tab']}|${rec['owner_turn']}';
        if (current != token) return false;
        final removed = await prefs.remove(_scope(server, sid, 'pending'));
        // STUCK-BUSY B3: "cleared" means the key is GONE, not that a
        // write was attempted — a refused remove must never report a
        // clean settle that will not survive reload.
        return removed || _pendingRaw(server, sid) == null;
      });

  // ---- OFFLINE-SEND R2 §4.1/§4.2: the local attempt journal --------------
  // ONE prefs key per attemptId under `_scope(server, sid, 'attempt.x')`
  // (field = 'attempt.<attemptId>'),
  // never one shared JSON list (a lock-less tab could then overwrite
  // another tab's entries wholesale). Every write rides the SAME per-
  // session `withStoreTx` chain as claim/amend/touch/clear, so a locked op
  // must use the PRIVATE helpers — calling the public methods from inside
  // a transaction would re-acquire the same lock. Journal + pending are
  // separate keys: fixes here are multi-key writes ordered journal-first,
  // NOT an atomic transaction across keys.

  /// Test seam: makes every journal write behave exactly like a REFUSED
  /// prefs write (false), so callers' storage-failure paths are reachable.
  @visibleForTesting
  static bool debugFailAttemptWrites = false;

  /// Test seam: invoked inside `endLocalAttempt` with 'afterJournal' right
  /// after the tombstone persisted but BEFORE the pending compare-delete
  /// (throwing there simulates a crash between §4.2 steps 2 and 3), and
  /// with 'afterDelete' once the delete landed. Null in production.
  @visibleForTesting
  static Future<void> Function(String phase)? debugEndAttemptHook;

  /// Persist one journal entry (create or update by attemptId). False =
  /// the write was refused or failed readback; nothing is thrown here —
  /// the caller decides what a refusal means for its own operation.
  Future<bool> saveAttempt(String server, String sid, LocalAttempt attempt) =>
      withStoreTx('pending.$server.$sid', () =>
          _writeAttempt(server, sid, attempt.attemptId, attempt.toJson()));

  LocalAttempt? loadAttempt(String server, String sid, String attemptId) {
    final raw = prefs.getString(_attemptKey(server, sid, attemptId));
    if (raw == null) return null;
    try {
      return LocalAttempt.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } on Object {
      return null; // corrupt entry reads as none
    }
  }

  /// Enumerate the session's attempts by STRICT scoped prefix (the prefix
  /// ends in `attempt.` and the remainder must be a single dot-free id,
  /// so a sibling sid like `sid-extra` or an adversarial dotted id cannot
  /// bleed in even though encodeComponent(server) may itself carry dots).
  /// The key scan IS the index; nothing is TTL-dropped — unknown
  /// or unsent drafts (and abandoned tombstones) outlive every window
  /// until something explicit removes them. Corrupt entries are skipped.
  List<LocalAttempt> listAttempts(String server, String sid) {
    final prefix = '${Uri.encodeComponent(server)}.$sid.attempt.';
    final out = <LocalAttempt>[];
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(prefix)) continue;
      final id = key.substring(prefix.length);
      if (id.isEmpty || id.contains('.')) continue;
      final raw = prefs.getString(key);
      if (raw == null) continue;
      try {
        final a = LocalAttempt.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map),
        );
        if (a != null) out.add(a);
      } on Object {
        // corrupt entry: skip it, never drop the ones that parse.
      }
    }
    return out;
  }

  /// Remove one attempt entry (terminal + no draft/blob references is the
  /// caller's policy, §4.1). Inside the SAME session lock; false when the
  /// key was never there or the removal did not land.
  Future<bool> removeAttempt(String server, String sid, String attemptId) =>
      withStoreTx('pending.$server.$sid', () async {
        final key = _attemptKey(server, sid, attemptId);
        if (prefs.getString(key) == null) return false; // nothing to remove
        final removed = await prefs.remove(key);
        return removed || prefs.getString(key) == null;
      });

  /// The local settlement of §4.2, fixed order, entirely inside the same
  /// per-session lock as every other pending op: compare FIRST (a moved
  /// token or attempt writes NOTHING), persist the abandoned tombstone
  /// SECOND (refusal stops everything, pending untouched), only then the
  /// inlined compare-delete (a refused delete keeps tombstone AND pending
  /// and reports cleanupPending). A crash between the last two leaves
  /// tombstone + pending side by side — later readers see the matching
  /// abandoned entry and must not re-arm a waiting budget for it. This is
  /// explicitly NOT atomic across keys; it degrades LOUDLY (no
  /// cross-tab-atomic claim without Web Locks — same caveat as §4.5).
  Future<LocalAttemptEndResult> endLocalAttempt(
    String server,
    String sid, {
    String? token,
    required String attemptId,
    required LocalAttempt tombstone,
  }) => withStoreTx('pending.$server.$sid', () async {
    // (a) authoritative compare before ANY side effect.
    final rec = await _rereadPending(server, sid);
    if (rec == null) {
      return const LocalAttemptEndResult(LocalAttemptEndOutcome.missing, null);
    }
    final current = rec['owner_tab'] == null && rec['owner_turn'] == null
        ? null
        : '${rec['owner_tab']}|${rec['owner_turn']}';
    if (current != token || rec['attempt_id'] != attemptId) {
      return const LocalAttemptEndResult(
        LocalAttemptEndOutcome.mismatch,
        null,
      );
    }
    // (b) tombstone before touch: the abandoned entry is the crash-proof
    // anti-resurrection marker, NOT a server terminal statement.
    if (!await _writeAttempt(server, sid, attemptId, tombstone.toJson())) {
      return const LocalAttemptEndResult(
        LocalAttemptEndOutcome.journalFailed,
        null,
      );
    }
    final hook = debugEndAttemptHook;
    if (hook != null) await hook('afterJournal');
    // (c) compare-delete, inlined (never a nested public clearPending —
    // that would re-acquire this very lock) and re-compared: a token
    // observed moved at this point still means cleanupPending, because
    // the tombstone write above already happened.
    final now = await _rereadPending(server, sid);
    if (now != null) {
      final nowToken =
          now['owner_tab'] == null && now['owner_turn'] == null
          ? null
          : '${now['owner_tab']}|${now['owner_turn']}';
      if (nowToken != token) {
        return const LocalAttemptEndResult(
          LocalAttemptEndOutcome.cleanupPending,
          null,
        );
      }
      final removed = await prefs.remove(_scope(server, sid, 'pending'));
      if (!(removed || _pendingRaw(server, sid) == null)) {
        return const LocalAttemptEndResult(
          LocalAttemptEndOutcome.cleanupPending,
          null,
        );
      }
    }
    if (hook != null) await hook('afterDelete');
    return LocalAttemptEndResult(LocalAttemptEndOutcome.ended, attemptId);
  });

  // ---- BULK-HIDE B2/B3: hidden namespace — one serializer per server ----
  // All hidden writers (single, batch, snapshot, migration, legacy) share
  // ONE lock per server: they mutate the same list. Five HTTP PATCHes may
  // run in parallel; the read-modify-write below never does.

  /// Typed storage refusal: the write must not be reported as applied.
  Future<void> _writeHiddenSet(String server, Set<String> set) async {
    final ok = await prefs.setStringList('hidden.$server', set.toList());
    if (!ok) throw const HiddenPersistenceFailure();
  }

  Set<String> _hiddenSet(String server) =>
      (prefs.getStringList('hidden.$server') ?? const []).toSet();

  /// Re-read a hidden-namespace key across contexts. Some backends —
  /// notably the widget-test mock — make reload() RESET instead of
  /// refresh; when the reload comes back empty for a key the cache had,
  /// the pre-reload view wins. A genuinely foreign-deleted key self-heals
  /// through the next snapshot sync (server is the truth; B3).
  Future<Set<String>> _rereadList(String key) async {
    final before = prefs.getStringList(key);
    try {
      await prefs.reload();
    } on Object {
      /* reload unsupported: keep the cache */
    }
    return (prefs.getStringList(key) ?? before ?? const []).toSet();
  }

  bool isHidden(String server, String sid) => _hiddenSet(server).contains(sid);

  Future<void> setHidden(String server, String sid, bool hidden) =>
      withStoreTx('hidden.$server', () async {
        final set = await _rereadList('hidden.$server');
        hidden ? set.add(sid) : set.remove(sid);
        await _writeHiddenSet(server, set);
      });

  /// Remove an id from BOTH hidden mirrors — the DELETE-success cleanup
  /// (B2: pure local, never the upgraded hide) and legacy resolution.
  Future<void> forgetHidden(String server, String sid) =>
      withStoreTx('hidden.$server', () async {
        final set = (await _rereadList('hidden.$server'))..remove(sid);
        await _writeHiddenSet(server, set);
        final legacy = (await _rereadList('hidden.legacyPending.$server'))
          ..remove(sid);
        await prefs.setStringList(
          'hidden.legacyPending.$server',
          legacy.toList(),
        );
      });

  /// A COMPLETE list snapshot with known server flags lands atomically:
  /// latest server value (true OR false) wins over the mirror; ids absent
  /// from the snapshot are untouched (pruning needs a contract promise we
  /// do not have). A legacy id the server confirms true leaves the
  /// pending set; server-false legacy ids KEEP their pending marker
  /// (B3: an old local preference is never silently erased).
  Future<void> syncHiddenSnapshot(
    String server,
    Map<String, bool> knownFlags,
  ) => withStoreTx('hidden.$server', () async {
    final set = await _rereadList('hidden.$server');
    final legacy = await _rereadList('hidden.legacyPending.$server');
    knownFlags.forEach((id, flag) {
      flag ? set.add(id) : set.remove(id);
      if (flag) legacy.remove(id);
    });
    await _writeHiddenSet(server, set);
    await prefs.setStringList('hidden.legacyPending.$server', legacy.toList());
  });

  Set<String> _legacyPending(String server) =>
      (prefs.getStringList('hidden.legacyPending.$server') ?? const []).toSet();

  Set<String> legacyPending(String server) => _legacyPending(server);

  /// First run of the dual-write build: freeze the old LOCAL-ONLY hidden
  /// ids as "pending sync" (an old preference, not a completed write) and
  /// drop the schema marker — all inside the same hidden lock.
  Future<void> ensureHiddenMigration(String server) =>
      withStoreTx('hidden.$server', () async {
        if (prefs.getBool('hidden.migrated.$server') == true) return;
        await prefs.setStringList(
          'hidden.legacyPending.$server',
          (await _rereadList('hidden.$server')).toList(),
        );
        await prefs.setBool('hidden.migrated.$server', true);
      });

  /// An explicit successful operation for this id retires its legacy
  /// marker (server-confirmed truth from now on).
  Future<void> resolveLegacyHidden(String server, Iterable<String> ids) =>
      withStoreTx('hidden.$server', () async {
        final legacy = (await _rereadList('hidden.legacyPending.$server'))
          ..removeAll(ids);
        await prefs.setStringList(
          'hidden.legacyPending.$server',
          legacy.toList(),
        );
      });

  // ---- P2: last-known titles so renamed/hidden rows render before refresh ----
  Future<void> cacheTitle(String server, String sid, String title) =>
      prefs.setString(_scope(server, sid, 'title'), title);
  String? cachedTitle(String server, String sid) =>
      prefs.getString(_scope(server, sid, 'title'));

  // ---- P2: interrupted-by-disconnect marker (client-side truth) ----
  String? lostNotice(String server, String sid) =>
      prefs.getString(_scope(server, sid, 'lost'));
  Future<void> markLost(String server, String sid) => prefs.setString(
    _scope(server, sid, 'lost'),
    DateTime.now().toIso8601String(),
  );
  Future<void> clearLost(String server, String sid) =>
      prefs.remove(_scope(server, sid, 'lost'));
}

/// Thrown when a pending-record write was REFUSED — the caller must not
/// claim the recovery budget (or a clear) persisted.
class PendingPersistenceFailure implements Exception {
  const PendingPersistenceFailure();
}

/// BULK-HIDE B2: storage refused the hidden write (setStringList false).
class HiddenPersistenceFailure implements Exception {
  const HiddenPersistenceFailure();
}

enum PendingRecoveryOutcome {
  /// Metadata stamped by this call (first recovery for this record).
  begun,

  /// Metadata already present: the SAME deadline/retry state is returned,
  /// untouched (reload never re-arms a window).
  alreadyPresent,

  /// Another tab's token owns the record now — nothing was touched.
  mismatch,

  /// No record at all.
  missing,
}

class PendingRecoveryResult {
  const PendingRecoveryResult(this.outcome, this.record);
  final PendingRecoveryOutcome outcome;
  final PendingTurn? record;
}

enum RecoveryRetryOutcome {
  /// This call flipped retry_used and re-armed the 30s window.
  consumed,

  /// The single allowance is spent (or metadata is absent): the caller
  /// must NOT start a new window — it may only observe the persisted one.
  alreadyUsed,

  /// Another tab's token owns the record — nothing was touched.
  mismatch,
  missing,
}

class RecoveryRetryResult {
  const RecoveryRetryResult(this.outcome, this.record);
  final RecoveryRetryOutcome outcome;
  final PendingTurn? record;
}

/// OFFLINE-SEND R2 §4.2: how a local settlement ended. None of these is a
/// server statement — `ended` means THIS client stopped waiting and left
/// an abandoned tombstone, with the delivery outcome still unknown.
enum LocalAttemptEndOutcome {
  /// Tombstone persisted and the matching pending key is gone.
  ended,

  /// Tombstone persisted but the pending delete did not land (or the
  /// record moved mid-flight): both survive; only local cleanup retries.
  cleanupPending,

  /// Token or attemptId moved — nothing was written at all.
  mismatch,

  /// No pending record.
  missing,

  /// The tombstone write was refused: pending untouched, no tombstone.
  journalFailed,
}

class LocalAttemptEndResult {
  const LocalAttemptEndResult(this.outcome, [this.attemptId]);
  final LocalAttemptEndOutcome outcome;
  final String? attemptId;
}
