import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../platform/store_tx.dart';
import '../attachments/attachment.dart';
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
  static const defaultUrl =
      String.fromEnvironment('HERMES_APP_DEFAULT_URL', defaultValue: '');
  static const legacyUrl =
      String.fromEnvironment('HERMES_APP_LEGACY_URL', defaultValue: '');
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
  });
  final String? runId;
  final String userText;
  final DateTime startedAt;
  final String? ownerTab, ownerTurn;
  final DateTime? leaseUntil;

  /// Compare tag for claim/amend/clear; null = unowned (legacy or empty).
  String? get token =>
      ownerTab == null && ownerTurn == null
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
  String draft(String server, String sid) =>
      prefs.getString(_scope(server, sid, 'draft')) ?? '';
  Future<void> saveDraft(String server, String sid, String text) => text.isEmpty
      ? prefs.remove(_scope(server, sid, 'draft'))
      : prefs.setString(_scope(server, sid, 'draft'), text);

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

  Map<String, dynamic>? _pendingRaw(String server, String sid) {
    final raw = prefs.getString(_scope(server, sid, 'pending'));
    if (raw == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null; // Corrupt or foreign-shape record: treat as none.
    }
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
  }) => prefs.setString(_scope(server, sid, 'pending'), jsonEncode({
    'run_id': runId,
    'user_text': userText,
    'started_at': startedAt.toIso8601String(),
    if (ownerTurn != null && leaseUntil != null) ...{
      'owner_tab': tabId,
      'owner_turn': ownerTurn,
      'lease_until': leaseUntil.toIso8601String(),
    },
  }));

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
    final rec = _pendingRaw(server, sid);
    await _writePending(
      server,
      sid,
      runId: runId ?? rec?['run_id'] as String?,
      userText: userText.isEmpty
          ? (rec?['user_text'] as String? ?? '')
          : userText,
      startedAt:
          DateTime.tryParse(rec?['started_at'] as String? ?? '') ?? now,
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
    Duration lease = pendingLease,
  }) => withStoreTx('pending.$server.$sid', () async {
    final now = DateTime.now();
    final rec = _pendingRaw(server, sid);
    if (rec != null && _leaseHeldByOther(rec, now)) return null;
    await _writePending(
      server,
      sid,
      userText: userText,
      startedAt: startedAt ?? now,
      ownerTurn: turnId,
      leaseUntil: now.add(lease),
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
    final rec = _pendingRaw(server, sid);
    if (rec == null) return false;
    final held =
        rec['owner_tab'] == tabId &&
        '${rec['owner_tab']}|${rec['owner_turn']}' == token;
    if (!held) return false;
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
    final rec = _pendingRaw(server, sid);
    if (rec == null) return false;
    // token embeds the tab layer; equality already implies this tab owns it.
    if ('${rec['owner_tab']}|${rec['owner_turn']}' != token) return false;
    await _writePending(
      server,
      sid,
      runId: rec['run_id'] as String?,
      userText: rec['user_text'] as String? ?? '',
      startedAt:
          DateTime.tryParse(rec['started_at'] as String? ?? '') ?? now,
      ownerTurn: rec['owner_turn'] as String?,
      leaseUntil: now.add(lease),
    );
    return true;
  });

  /// Compare-and-delete (AUDIT-12 rule 2 generalized across tabs): only
  /// the holder of `token` may clear; an unowned record is cleared by an
  /// unowned clear (legacy semantics preserved). False = somebody else's
  /// turn is now recorded here — leave their evidence alone.
  Future<bool> clearPending(String server, String sid, {String? token}) =>
      withStoreTx('pending.$server.$sid', () async {
        final rec = _pendingRaw(server, sid);
        if (rec == null) return true;
        final current = rec['owner_tab'] == null && rec['owner_turn'] == null
            ? null
            : '${rec['owner_tab']}|${rec['owner_turn']}';
        if (current != token) return false;
        await prefs.remove(_scope(server, sid, 'pending'));
        return true;
      });

  // ---- P2: hidden (archived) sessions; local-only, never deletes server-side ----
  Set<String> _hiddenSet(String server) {
    final raw = prefs.getStringList('hidden.$server') ?? const [];
    return raw.toSet();
  }

  bool isHidden(String server, String sid) => _hiddenSet(server).contains(sid);
  Future<void> setHidden(String server, String sid, bool hidden) async {
    final set = _hiddenSet(server);
    hidden ? set.add(sid) : set.remove(sid);
    await prefs.setStringList('hidden.$server', set.toList());
  }

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
