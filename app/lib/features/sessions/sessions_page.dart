import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_strings.dart';
import '../../l10n/localized_text.dart';
import '../../l10n/message_key.dart';
import '../../l10n/ui_message.dart';
import '../../models/session.dart';
import '../../providers.dart';
import '../chat/chat_page.dart';
import '../chat/viewers.dart';
import '../settings/local_store.dart';
import '../settings/management_page.dart';
import '../settings/settings_page.dart';
import 'session_selection.dart';
import 'session_visibility.dart';

class SessionsPage extends ConsumerStatefulWidget {
  const SessionsPage({super.key});
  @override
  ConsumerState<SessionsPage> createState() => _SessionsPageState();
}

/// Order for the sessions list: pinned float to the top (their relative
/// order follows the server's pinned_at ordering via stable sort), hidden
/// rows sink below active ones even when newer — hiding means "get it off
/// my front page" — and everything else sorts by recency.
void sortSessionRows(
  List<Session> rows, {
  required bool Function(Session) hidden,
}) {
  rows.sort((a, b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    final ah = hidden(a), bh = hidden(b);
    if (ah != bh) return ah ? 1 : -1;
    return b.activity.compareTo(a.activity);
  });
}

class _SessionsPageState extends ConsumerState<SessionsPage> {
  Timer? timer;
  final search = TextEditingController();
  String query = '';
  bool showHidden = false;

  /// 最愛篩選：true 時列表只顯示釘選中的 session。
  bool onlyPinned = false;
  bool _creating = false;

  // ---- BULK-HIDE B4: selection mode ----------------------------------------
  // id-keyed only; filters never clear it, only a COMPLETE list drop does.
  final SessionSelection _selection = SessionSelection();
  bool applying = false; // Phase 2 freezes the list while a batch runs

  // BULK-HIDE B3 resolver state: values THIS page confirmed (they outrank
  // older GETs), plus the frozen legacy local-only hidden ids.
  final Map<String, bool> _confirmed = {};
  Set<String> _legacy = {};

  // BULK-HIDE B4 batch state: freeze snapshots, progress and the
  // persistent partial-failure summary.
  Map<String, VisibilityResult> _visFailures = {};
  bool _batchTarget = true;
  int _batchDone = 0, _batchTotal = 0;
  List<Session> _frozenRows = const [];
  List<Session> _lastRows = const [];
  List<Session> _lastVisible = const [];
  String? _lastServer;

  Future<void> _applyBatch(bool target, {bool isRetry = false}) async {
    if (applying || _selection.selectedIds.isEmpty) return;
    // B4 "applying": workers keep the CAPTURED repo/server; later filter
    // or settings changes can never repoint an in-flight batch.
    final repoRef = ref.read(repositoryProvider);
    final storeRef = ref.read(localStoreProvider);
    final server = ref.read(settingsProvider).url;
    final rowsById = {for (final s in _lastRows) s.id: s};
    final ids = _selection.selectedIds.toSet();
    final retryIds = <String>{
      for (final e in _visFailures.entries)
        if (e.value.outcome == VisibilityOutcome.localSyncFailure &&
            ids.contains(e.key))
          e.key,
    };
    final noop = <String>{
      for (final id in ids)
        if (rowsById[id]?.hidden == target &&
            storeRef.isHidden(server, id) == target &&
            !_legacy.contains(id))
          id,
    };
    final toPatch = ids.difference(noop);
    final legacyTouched = ids.intersection(_legacy);
    // B4: mixed selections carry BOTH targets; a batch never rewrites the
    // opposite flag just because the selection was mixed.
    final foreign = <String>{
      for (final id in ids)
        if (rowsById[id]?.pinned == true && target) id,
    };
    _confirmed.addEntries(noop.map((e) => MapEntry(e, target)));
    setState(() {
      applying = true;
      _batchTarget = target;
      _batchDone = noop.length;
      _batchTotal = ids.length;
      _visFailures = {};
      _frozenRows = _lastVisible;
    });
    final report = await VisibilityService(repoRef, storeRef, server).apply(
      toPatch,
      target,
      onProgress: (d, t) {
        if (mounted) setState(() => _batchDone = noop.length + d);
      },
      retryIds: retryIds,
    );
    _confirmed.addAll(report.confirmations);
    if (legacyTouched.isNotEmpty) {
      try {
        await storeRef.resolveLegacyHidden(server, legacyTouched);
      } on Object {
        /* next snapshot retries */
      }
      try {
        _legacy = storeRef.legacyPending(server);
      } on Object {
        /* keep the stale view; refresh re-reads */
      }
    }
    if (!mounted) {
      // Forced dispose mid-batch: workers only wrote to the ORIGINAL
      // server's mirror — nothing here touches a new page's state.
      return;
    }
    final failed = report.failuresById;
    for (final id in foreign) {
      failed.putIfAbsent(
        id,
        () => VisibilityResult(
          id,
          target,
          VisibilityOutcome.outcomeUnknown,
          detail: const UiMessage.local(MessageKey.sessionsVisibilityUnknown),
        ),
      );
    }
    setState(() {
      applying = false;
      _frozenRows = const [];
      if (failed.isEmpty) {
        _selection.exit();
        _visFailures = {};
      } else {
        _selection.selectedIds
          ..clear()
          ..addAll(failed.keys);
        _visFailures = failed;
      }
    });
    _snack(
      UiMessage.local(
        MessageKey.sessionsVisibilitySummary,
        args: {
          'success': report.successCount + noop.length,
          'failed': failed.length,
        },
      ),
    );
    if (failed.values.every(
          (f) => f.outcome == VisibilityOutcome.outcomeUnknown,
        ) &&
        failed.isNotEmpty) {
      _snack(const UiMessage.local(MessageKey.sessionsVisibilityUnavailable));
    }
    // B4: ONE invalidate at batch end; the COMPLETE GET that follows
    // lands snapshots, prunes vanished ids and reports them.
    ref.invalidate(sessionsProvider);
  }

  /// One effective-hidden rule for count, filter, sort and row style.
  bool _effHidden(Session s, String server, LocalStore store) {
    final c = _confirmed[s.id];
    if (c != null) return c;
    if (_legacy.contains(s.id) && (s.hidden == null || s.hidden == false)) {
      return true; // an unsynced old preference is kept, not erased
    }
    return s.hidden ?? store.isHidden(server, s.id);
  }

  void _enterSelection([String? id]) =>
      setState(() => _selection.enter(id == null ? const [] : [id]));

  void _exitSelection() => setState(_selection.exit);

  void _toggleSelected(String id) => setState(() => _selection.toggle(id));

  String _safeTitle(String id, AppStrings strings) {
    final rows = _lastRows.where((x) => x.id == id);
    return rows.isEmpty ? id : displaySessionTitle(strings, rows.first.title);
  }

  void _snack(UiMessage m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: LocalizedText(m)));
  }

  Future<void> _createSession() async {
    if (_creating) return;
    setState(() => _creating = true);
    try {
      final s = await ref.read(repositoryProvider).createSession();
      ref.invalidate(sessionsProvider);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          // A brand-new sid cannot collide, but the route still carries
          // the chat name so open()'s focus guard sees it uniformly.
          settings: RouteSettings(name: _chatRoute(s.id)),
          builder: (_) => ChatPage(session: s),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: LocalizedText(
              UiMessage.local(
                MessageKey.sessionsM001,
                args: {'error': messageForError(e)},
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => ref.invalidate(healthProvider),
    );
    search.addListener(() => setState(() => query = search.text.trim()));
    // BULK-HIDE B3 migration: freeze the old local-only hidden ids once,
    // in the hidden lock, BEFORE any dual write.
    unawaited(() async {
      final store = ref.read(localStoreProvider);
      final server = ref.read(settingsProvider).url;
      try {
        await store.ensureHiddenMigration(server);
      } on Object {
        /* banner stays silent; next boot retries */
      }
      if (mounted) setState(() => _legacy = store.legacyPending(server));
    }());
  }

  @override
  void dispose() {
    timer?.cancel();
    search.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    ref.invalidate(compatibilityProvider);
    ref.invalidate(sessionsProvider);
    ref.invalidate(skillsProvider);
    ref.invalidate(healthProvider);
    try {
      final list = await ref.read(sessionsProvider.future);
      // BULK-HIDE B3: the COMPLETE list lands its known server flags into
      // the mirror (server false DOES overwrite a synced local true);
      // absent ids are untouched, and the fresh truth retires confirmations.
      if (mounted) {
        final known = {
          for (final item in list)
            if (item.hidden != null) item.id: item.hidden!,
        };
        try {
          await ref
              .read(localStoreProvider)
              .syncHiddenSnapshot(ref.read(settingsProvider).url, known);
        } on Object {
          /* mirror retry happens on the next successful list */
        }
        _confirmed.removeWhere((id, _) => known.containsKey(id));
        if (mounted) {
          setState(
            () => _legacy = ref
                .read(localStoreProvider)
                .legacyPending(ref.read(settingsProvider).url),
          );
        }
      }
      // BULK-HIDE B4 "refresh": a successful COMPLETE list keeps the
      // selected ids that still exist; only truly vanished rows leave the
      // selection — reported, never silently dropped. Loading/error keep
      // the selection untouched (the catch below does nothing).
      if (mounted &&
          _selection.selecting &&
          _selection.selectedIds.isNotEmpty) {
        final removed = _selection.retainExisting(list.map((s) => s.id));
        if (mounted) {
          setState(() {});
          if (removed.isNotEmpty) {
            _snack(
              UiMessage.local(
                MessageKey.sessionsSelectionMissing,
                args: {'count': removed.length},
              ),
            );
          }
        }
      }
    } catch (_) {
      /* AsyncValue below renders the failure. */
    }
    // AUDIT-16: keep the resident idle-controller set bounded after every
    // list refresh too (a session that got deleted server-side must not
    // stay pinned as an idle controller just because nobody popped it).
    if (mounted) {
      evictIdleChatControllers(
        readChat: (sid) => ref.read(chatProvider(sid)),
        drop: ref.invalidate,
      );
    }
  }

  static String _chatRoute(String sid) => 'chat:$sid';

  Future<void> open(Session s) async {
    // AUDIT-21(D1): SYNCHRONOUS navigation dedupe, before any await and
    // before markRead in particular — markRead's await was the window
    // where a fast second tap sailed past every guard and stacked a
    // second ChatPage for the same sid (both pages' pop-dispose then
    // fought over detach()). If a route for this sid already exists,
    // focus it instead of pushing a second one.
    if (ChatViewers.count(s.id) > 0) {
      Navigator.of(
        context,
      ).popUntil((r) => r.settings.name == _chatRoute(s.id) || r.isFirst);
      return;
    }
    if (!ChatViewers.claimOpening(s.id)) return; // another tap owns the open
    final store = ref.read(localStoreProvider);
    final server = ref.read(settingsProvider).url;
    try {
      await store.markRead(server, s.id, s.readFingerprint);
      if (!mounted) return;
      setState(() {});
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          settings: RouteSettings(name: _chatRoute(s.id)),
          builder: (_) => ChatPage(session: s),
        ),
      );
    } finally {
      ChatViewers.releaseOpening(s.id);
    }
    if (!mounted) return;
    ref.invalidate(sessionsProvider);
    try {
      final list = await ref.read(sessionsProvider.future);
      // BULK-HIDE B3: the COMPLETE list lands its known server flags into
      // the mirror (server false DOES overwrite a synced local true);
      // absent ids are untouched, and the fresh truth retires confirmations.
      if (mounted) {
        final known = {
          for (final item in list)
            if (item.hidden != null) item.id: item.hidden!,
        };
        try {
          await ref
              .read(localStoreProvider)
              .syncHiddenSnapshot(ref.read(settingsProvider).url, known);
        } on Object {
          /* mirror retry happens on the next successful list */
        }
        _confirmed.removeWhere((id, _) => known.containsKey(id));
        if (mounted) {
          setState(
            () => _legacy = ref
                .read(localStoreProvider)
                .legacyPending(ref.read(settingsProvider).url),
          );
        }
      }
      final current = list.where((item) => item.id == s.id);
      if (current.isNotEmpty) {
        await store.markRead(server, s.id, current.first.readFingerprint);
      }
    } catch (_) {
      /* Preserve the last successful read fingerprint. */
    }
    if (mounted) setState(() {});
    // AUDIT-16: a chat pop is the natural eviction point for the bounded
    // idle-controller LRU (running turns and visible pages are exempt).
    if (mounted) {
      evictIdleChatControllers(
        readChat: (sid) => ref.read(chatProvider(sid)),
        drop: ref.invalidate,
      );
    }
  }

  Future<void> rename(Session s) async {
    final controller = TextEditingController(text: s.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => Builder(
        // Builder re-resolves on a live language switch while open (§4.5).
        builder: (context) {
          final strings = AppStrings.of(context);
          return AlertDialog(
            title: Text(strings.resolve(MessageKey.sessionsRename)),
            content: TextField(
              controller: controller,
              autofocus: true,
              maxLength: 120,
              decoration: InputDecoration(
                hintText: strings.resolve(MessageKey.sessionsName),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(strings.resolve(MessageKey.commonCancel)),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, controller.text.trim()),
                child: Text(strings.resolve(MessageKey.commonSave)),
              ),
            ],
          );
        },
      ),
    );
    if (title == null || title.isEmpty || title == s.title || !mounted) return;
    try {
      await ref.read(repositoryProvider).renameSession(s.id, title);
      await ref
          .read(localStoreProvider)
          .cacheTitle(ref.read(settingsProvider).url, s.id, title);
      ref.invalidate(sessionsProvider);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: LocalizedText(
              UiMessage.local(MessageKey.sessionsRenameFailed),
            ),
          ),
        );
      }
    }
  }

  /// Single hide = N=1 of the batch pipeline (B2): server first, mirror
  /// after, honest state on every branch — no local-only shortcut anymore.
  Future<void> hide(Session s, bool hidden) async {
    final store = ref.read(localStoreProvider);
    final server = ref.read(settingsProvider).url;
    final r = await VisibilityService(
      ref.read(repositoryProvider),
      store,
      server,
    ).set(s.id, hidden);
    if (!mounted) return;
    if (r.outcome == VisibilityOutcome.success) {
      _confirmed[s.id] = hidden;
      ref.invalidate(sessionsProvider);
    }
    setState(() {});
    switch (r.outcome) {
      case VisibilityOutcome.success:
        break;
      case VisibilityOutcome.serverFailure:
        _snack(
          r.detail ??
              const UiMessage.local(MessageKey.sessionsVisibilityUnknown),
        );
      case VisibilityOutcome.outcomeUnknown:
        _snack(
          r.detail ??
              const UiMessage.local(MessageKey.sessionsVisibilityUnknown),
        );
      case VisibilityOutcome.localSyncFailure:
        _snack(const UiMessage.local(MessageKey.sessionsLocalSyncFailed));
    }
  }

  /// The single-item sheet, now also reachable from the visible menu button
  /// (BULK-HIDE B4: long-press was repurposed for selection, so the menu
  /// must be a real control — this change is part of the public behaviour).
  void _rowSheet(Session s) {
    final server = ref.read(settingsProvider).url;
    final hidden = ref.read(localStoreProvider).isHidden(server, s.id);
    showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => Builder(
        builder: (sheet) {
          final strings = AppStrings.of(sheet);
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(
                    s.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                  ),
                  title: Text(
                    strings.resolve(
                      s.pinned
                          ? MessageKey.sessionsM022
                          : MessageKey.sessionsM023,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(sheet);
                    pin(s, !s.pinned);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.drive_file_rename_outline),
                  title: Text(strings.resolve(MessageKey.sessionsRename)),
                  onTap: () {
                    Navigator.pop(sheet);
                    rename(s);
                  },
                ),
                ListTile(
                  leading: Icon(
                    hidden
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  title: Text(
                    strings.resolve(
                      hidden
                          ? MessageKey.sessionsM024
                          : MessageKey.sessionsM025,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(sheet);
                    hide(s, !hidden);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.red),
                  title: Text(
                    strings.resolve(MessageKey.commonDelete),
                    style: const TextStyle(color: Colors.red),
                  ),
                  onTap: () {
                    Navigator.pop(sheet);
                    delete(s);
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> pin(Session s, bool pinned) async {
    try {
      await ref.read(repositoryProvider).setSessionPinned(s.id, pinned);
      ref.invalidate(sessionsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: LocalizedText(
              UiMessage.local(
                MessageKey.sessionsM002,
                args: {'error': messageForError(e)},
              ),
            ),
          ),
        );
      }
    }
  }

  Future<void> delete(Session s) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => Builder(
        builder: (context) {
          final strings = AppStrings.of(context);
          return AlertDialog(
            title: Text(strings.resolve(MessageKey.sessionsM003)),
            content: Text(
              strings.resolve(
                MessageKey.sessionsM004,
                args: {'title': displaySessionTitle(strings, s.title)},
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(strings.resolve(MessageKey.commonCancel)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red.shade700,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: Text(strings.resolve(MessageKey.commonDelete)),
              ),
            ],
          );
        },
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(repositoryProvider).deleteSession(s.id);
      // BULK-HIDE B2: DELETE-success cleanup is PURE LOCAL (forgetHidden)
      // — a PATCH after DELETE would 404 the deleted id.
      final server = ref.read(settingsProvider).url;
      await ref.read(localStoreProvider).forgetHidden(server, s.id);
      _confirmed.remove(s.id);
      ref.invalidate(sessionsProvider);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: LocalizedText(UiMessage.local(MessageKey.sessionsM005)),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(sessionsProvider);
    final online = ref.watch(healthProvider).asData?.value ?? false;
    final skillState = ref.watch(
      skillsProvider,
    ); // Startup cache, retained until refresh.
    final store = ref.watch(localStoreProvider);
    final server = ref.watch(settingsProvider).url;
    final strings = AppStrings.of(context);
    return PopScope(
      // BULK-HIDE B4 "leave": Back exits selection FIRST, never pops the
      // list page while a selection is on screen.
      canPop: !(_selection.selecting || applying),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (applying) {
          // B4: Back during a batch is intercepted — progress stays on
          // screen, the list page does not pop.
          _snack(
            UiMessage.local(
              MessageKey.sessionsVisibilityProgress,
              args: {'done': _batchDone, 'total': _batchTotal},
            ),
          );
          return;
        }
        if (_selection.selecting) _exitSelection();
      },
      child: Focus(
        // While selecting, the page owns key routing so Escape lands even
        // when no row/widget holds focus (B4 "leave").
        autofocus: _selection.selecting,
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape &&
              _selection.selecting) {
            _exitSelection();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Scaffold(
          appBar: AppBar(
            title: const Text(
              'HERMES',
              style: TextStyle(letterSpacing: 3, fontSize: 18),
            ),
            actions: [
              if (_selection.selecting)
                IconButton(
                  // visible Select/Cancel pair on EVERY platform (B4).
                  tooltip: strings.resolve(MessageKey.commonCancel),
                  onPressed: applying ? null : _exitSelection,
                  icon: const Icon(Icons.close),
                )
              else
                IconButton(
                  tooltip: strings.resolve(MessageKey.sessionsSelect),
                  onPressed: applying ? null : _enterSelection,
                  icon: const Icon(Icons.checklist),
                ),
              IconButton(
                tooltip: strings.resolve(MessageKey.sessionsM006),
                onPressed: _creating || applying ? null : _createSession,
                icon: _creating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_comment_outlined),
              ),
              Tooltip(
                message: strings.resolve(
                  online ? MessageKey.sessionsM007 : MessageKey.sessionsM008,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Icon(
                    Icons.circle,
                    size: 10,
                    color: online ? const Color(0xff72e0be) : Colors.orange,
                  ),
                ),
              ),
              IconButton(
                tooltip: strings.resolve(MessageKey.managementTitle),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const ManagementPage(),
                  ),
                ),
                icon: const Icon(Icons.grid_view_outlined),
              ),
              IconButton(
                tooltip: strings.resolve(MessageKey.sessionsM009),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
                ),
                icon: const Icon(Icons.tune),
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: applying ? () async {} : refresh,
            child: sessions.when(
              loading: () => ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 100),
                  Center(child: CircularProgressIndicator()),
                ],
              ),
              error: (error, _) => ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(32),
                children: [
                  const Icon(Icons.cloud_off_outlined, size: 48),
                  const SizedBox(height: 16),
                  Text(
                    strings.resolve(MessageKey.sessionsM010),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  // Typed descriptors render translated; raw server/transport
                  // text stays byte-for-byte.
                  LocalizedText(
                    messageForError(error),
                    textAlign: TextAlign.center,
                  ),
                  TextButton(
                    onPressed: refresh,
                    child: Text(strings.resolve(MessageKey.sessionsM011)),
                  ),
                ],
              ),
              data: (list) {
                // B4 "server switch": selections never cross servers.
                if (_lastServer != server) {
                  _lastServer = server;
                  _selection.exit();
                  _visFailures.clear();
                  _frozenRows = const [];
                }
                _lastRows = list;
                // Local title cache keeps a fresh rename visible immediately.
                final rows = list
                    .map(
                      (s) => s.withTitle(
                        store.cachedTitle(server, s.id) ?? s.title,
                      ),
                    )
                    .toList();
                final hiddenCount = rows
                    .where((s) => _effHidden(s, server, store))
                    .length;
                final pinnedCount = rows.where((s) => s.pinned).length;
                final visible = rows.where((s) {
                  if (onlyPinned && !s.pinned) return false;
                  if (!showHidden && _effHidden(s, server, store)) return false;
                  if (query.isEmpty) return true;
                  final q = query.toLowerCase();
                  return s.title.toLowerCase().contains(q) ||
                      s.id.toLowerCase().contains(q);
                }).toList();
                sortSessionRows(
                  visible,
                  hidden: (s) => _effHidden(s, server, store),
                );
                _lastVisible = visible;
                // B4 "applying": row order is FROZEN for the whole batch —
                // rows leave the list only once, at batch end.
                final shown = applying ? _frozenRows : visible;
                return ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
                  itemCount: shown.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              strings.resolve(MessageKey.sessionsM012),
                              style: Theme.of(context).textTheme.headlineLarge,
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: search,
                              enabled: !applying,
                              decoration: InputDecoration(
                                hintText: strings.resolve(
                                  MessageKey.sessionsM013,
                                ),
                                prefixIcon: const Icon(Icons.search),
                                suffixIcon: query.isEmpty
                                    ? null
                                    : IconButton(
                                        icon: const Icon(Icons.clear),
                                        onPressed: search.clear,
                                      ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                isDense: true,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                ChoiceChip(
                                  label: Text(
                                    strings.resolve(MessageKey.sessionsM014),
                                  ),
                                  selected: !onlyPinned,
                                  onSelected: applying
                                      ? null
                                      : (_) =>
                                            setState(() => onlyPinned = false),
                                ),
                                const SizedBox(width: 8),
                                ChoiceChip(
                                  avatar: Icon(
                                    Icons.push_pin,
                                    size: 16,
                                    color: onlyPinned
                                        ? Theme.of(context).colorScheme.primary
                                        : Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                  ),
                                  label: Text(
                                    strings.resolve(
                                      MessageKey.sessionsM015,
                                      args: {'count': pinnedCount},
                                    ),
                                  ),
                                  selected: onlyPinned,
                                  onSelected: applying
                                      ? null
                                      : (_) =>
                                            setState(() => onlyPinned = true),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Switch(
                                  value: showHidden,
                                  onChanged: applying
                                      ? null
                                      : (v) => setState(() => showHidden = v),
                                ),
                                Expanded(
                                  child: Text(
                                    strings.resolve(
                                      MessageKey.sessionsM016,
                                      args: {'count': hiddenCount},
                                    ),
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            // BULK-HIDE B4 selection toolbar: count (+ outside
                            // note), union-select-all, clear — never a silent
                            // drop when filters hide selected rows.
                            if (_selection.selecting) ...[
                              Text(
                                strings.resolve(
                                  MessageKey.sessionsSelectedCount,
                                  args: {
                                    'count': _selection.selectedIds.length,
                                  },
                                ),
                              ),
                              Wrap(
                                spacing: 4,
                                children: [
                                  TextButton(
                                    key: const ValueKey('select-current'),
                                    onPressed: applying
                                        ? null
                                        : () => setState(
                                            () => _selection.selectAll(
                                              shown.map((s) => s.id),
                                            ),
                                          ),
                                    child: Text(
                                      strings.resolve(
                                        MessageKey.sessionsSelectCurrent,
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: _selection.selectedIds.isEmpty
                                        ? null
                                        : () => setState(_selection.clearIds),
                                    child: Text(
                                      strings.resolve(
                                        MessageKey.sessionsClearSelection,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (_selection.outsideCount(
                                    shown.map((s) => s.id),
                                  ) >
                                  0)
                                Text(
                                  strings.resolve(
                                    MessageKey.sessionsSelectedFiltered,
                                    args: {
                                      'count': _selection.outsideCount(
                                        shown.map((s) => s.id),
                                      ),
                                    },
                                  ),
                                ),
                              // Apply controls: BOTH targets are always
                              // offered (mixed selection); a batch only
                              // SETS its own flag — never the opposite
                              // pinned/hidden side.
                              Wrap(
                                spacing: 4,
                                children: [
                                  TextButton(
                                    key: const ValueKey('hide-selected'),
                                    onPressed: _selection.selectedIds.isEmpty
                                        ? null
                                        : () => _applyBatch(true),
                                    child: Text(
                                      strings.resolve(
                                        MessageKey.sessionsHideSelected,
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    key: const ValueKey('unhide-selected'),
                                    onPressed: _selection.selectedIds.isEmpty
                                        ? null
                                        : () => _applyBatch(false),
                                    child: Text(
                                      strings.resolve(
                                        MessageKey.sessionsUnhideSelected,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (applying)
                                Text(
                                  strings.resolve(
                                    MessageKey.sessionsVisibilityProgress,
                                    args: {
                                      'done': _batchDone,
                                      'total': _batchTotal,
                                    },
                                  ),
                                ),
                            ],
                            // Legacy migration banner (B3): never silent
                            // until the old preferences are processed.
                            if (_legacy
                                .where((id) => _lastRows.any((r) => r.id == id))
                                .isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      strings.resolve(
                                        MessageKey.sessionsHiddenLegacy,
                                        args: {
                                          'count': _legacy
                                              .where(
                                                (id) => _lastRows.any(
                                                  (r) => r.id == id,
                                                ),
                                              )
                                              .length,
                                        },
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    key: const ValueKey('select-legacy'),
                                    onPressed: applying
                                        ? null
                                        : () => setState(() {
                                            showHidden = true;
                                            _selection.enter(
                                              _legacy.where(
                                                (id) => _lastRows.any(
                                                  (r) => r.id == id,
                                                ),
                                              ),
                                            );
                                          }),
                                    child: Text(
                                      strings.resolve(
                                        MessageKey.sessionsSelectLegacy,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            if (!applying && _visFailures.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              // Persistent partial-failure summary: safe
                              // display titles; survives toast expiry and
                              // filters that hide the failed rows.
                              for (final entry in _visFailures.entries)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 2,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(_safeTitle(entry.key, strings)),
                                      if (entry.value.detail != null)
                                        LocalizedText(entry.value.detail!),
                                    ],
                                  ),
                                ),
                              TextButton(
                                key: const ValueKey('retry-unfinished'),
                                onPressed: () =>
                                    _applyBatch(_batchTarget, isRetry: true),
                                child: Text(
                                  strings.resolve(
                                    MessageKey.sessionsVisibilityRetry,
                                  ),
                                ),
                              ),
                            ],
                            Text(
                              visible.isEmpty
                                  ? (query.isEmpty
                                        ? strings.resolve(
                                            MessageKey.sessionsM017,
                                          )
                                        : strings.resolve(
                                            MessageKey.sessionsM018,
                                            args: {'query': query},
                                          ))
                                  : strings.resolve(
                                      MessageKey.sessionsM019,
                                      args: {'count': visible.length},
                                      count: visible.length,
                                    ),
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                            if (skillState.hasError)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  strings.resolve(MessageKey.sessionsM020),
                                ),
                              ),
                          ],
                        ),
                      );
                    }
                    final s = shown[index - 1];
                    final hidden = _effHidden(s, server, store);
                    final unread =
                        !hidden &&
                        s.count > 0 &&
                        store.readFingerprint(server, s.id) !=
                            s.readFingerprint;
                    final date = DateTime.fromMillisecondsSinceEpoch(
                      (s.activity * 1000).round(),
                    ).toLocal();
                    return Card(
                      // BULK-HIDE B4: identity by server+id, never by index or
                      // Session-object equality (refetches create new objects).
                      key: ValueKey('$server|${s.id}'),
                      margin: const EdgeInsets.only(bottom: 10),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 10,
                        ),
                        leading: _selection.selecting
                            ? Checkbox(
                                // Space toggles the focused checkbox for free;
                                // the checked state rides standard semantics.
                                value: _selection.selectedIds.contains(s.id),
                                onChanged: applying
                                    ? null
                                    : (_) => _toggleSelected(s.id),
                              )
                            : CircleAvatar(
                                backgroundColor: Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                                child: Icon(
                                  hidden
                                      ? Icons.visibility_off_outlined
                                      : unread
                                      ? Icons.chat_bubble
                                      : Icons.chat_bubble_outline,
                                  size: 20,
                                ),
                              ),
                        title: Row(
                          children: [
                            if (s.pinned)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: Icon(
                                  Icons.push_pin,
                                  size: 15,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            Expanded(
                              child: Text(
                                // Display fallback ONLY; the model stays raw.
                                displaySessionTitle(strings, s.title),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: unread
                                      ? FontWeight.w700
                                      : FontWeight.w400,
                                  decoration: hidden
                                      ? TextDecoration.lineThrough
                                      : null,
                                  color: hidden ? Colors.grey : null,
                                ),
                              ),
                            ),
                          ],
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            strings.resolve(
                              MessageKey.sessionsM021,
                              args: {
                                'count': s.count,
                                'month': date.month,
                                'day': date.day,
                                'source': s.source,
                              },
                              count: s.count,
                            ),
                          ),
                        ),
                        trailing: Row(
                          // unread dot and the single-item menu coexist (B4).
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (unread)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: Icon(
                                  Icons.circle,
                                  size: 7,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            IconButton(
                              key: ValueKey('menu-${s.id}'),
                              tooltip: strings.resolve(MessageKey.sessionsMenu),
                              onPressed: applying ? null : () => _rowSheet(s),
                              icon: const Icon(Icons.more_vert, size: 20),
                            ),
                          ],
                        ),
                        // Selecting: tap TOGGLES — no navigation, no markRead.
                        // Not selecting: long-press enters selection and picks
                        // this row; the single-item sheet lives in the menu.
                        onTap: applying
                            ? null
                            : _selection.selecting
                            ? () => _toggleSelected(s.id)
                            : () => open(s),
                        onLongPress: applying
                            ? null
                            : () => _enterSelection(s.id),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
