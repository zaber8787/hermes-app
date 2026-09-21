import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/session.dart';
import '../../providers.dart';
import '../chat/chat_page.dart';
import '../chat/viewers.dart';
import '../settings/management_page.dart';
import '../settings/settings_page.dart';

class SessionsPage extends ConsumerStatefulWidget {
  const SessionsPage({super.key});
  @override
  ConsumerState<SessionsPage> createState() => _SessionsPageState();
}

/// Order for the sessions list: pinned float to the top (their relative
/// order follows the server's pinned_at ordering via stable sort), hidden
/// rows sink below active ones even when newer — hiding means "get it off
/// my front page" — and everything else sorts by recency.
void sortSessionRows(List<Session> rows, {required bool Function(Session) hidden}) {
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
          SnackBar(content: Text('建立對話失敗：$e')),
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
      await ref.read(sessionsProvider.future);
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
      builder: (context) => AlertDialog(
        title: const Text('重新命名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 120,
          decoration: const InputDecoration(hintText: '對話名稱'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('儲存'),
          ),
        ],
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('改名失敗')));
      }
    }
  }

  Future<void> hide(Session s, bool hidden) async {
    await ref
        .read(localStoreProvider)
        .setHidden(ref.read(settingsProvider).url, s.id, hidden);
    if (mounted) setState(() {});
  }

  Future<void> pin(Session s, bool pinned) async {
    try {
      await ref.read(repositoryProvider).setSessionPinned(s.id, pinned);
      ref.invalidate(sessionsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('釘選失敗：$e')),
        );
      }
    }
  }

  Future<void> delete(Session s) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('刪除對話'),
        content: Text('確定刪除「${s.title}」？這會從伺服器移除整個對話。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('刪除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(repositoryProvider).deleteSession(s.id);
      await hide(s, false); // No orphan entries in the local hidden list.
      ref.invalidate(sessionsProvider);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('刪除失敗')));
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
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'HERMES',
          style: TextStyle(letterSpacing: 3, fontSize: 18),
        ),
        actions: [
          IconButton(
            tooltip: '新對話',
            onPressed: _creating ? null : _createSession,
            icon: _creating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_comment_outlined),
          ),
          Tooltip(
            message: online ? '已連線' : '離線或檢查中',
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
            tooltip: '管理',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const ManagementPage()),
            ),
            icon: const Icon(Icons.grid_view_outlined),
          ),
          IconButton(
            tooltip: '設定',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
            ),
            icon: const Icon(Icons.tune),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: refresh,
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
              const Text('暫時無法載入對話', textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text('$error', textAlign: TextAlign.center),
              TextButton(onPressed: refresh, child: const Text('重新連線')),
            ],
          ),
          data: (list) {
            // Local title cache keeps a fresh rename visible immediately.
            final rows = list
                .map(
                  (s) => s.withTitle(store.cachedTitle(server, s.id) ?? s.title),
                )
                .toList();
            final hiddenCount = rows
                .where((s) => store.isHidden(server, s.id))
                .length;
            final pinnedCount = rows.where((s) => s.pinned).length;
            final visible = rows.where((s) {
              if (onlyPinned && !s.pinned) return false;
              if (!showHidden && store.isHidden(server, s.id)) return false;
              if (query.isEmpty) return true;
              final q = query.toLowerCase();
              return s.title.toLowerCase().contains(q) ||
                  s.id.toLowerCase().contains(q);
            }).toList();
            sortSessionRows(
              visible,
              hidden: (s) => store.isHidden(server, s.id),
            );
            return ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
              itemCount: visible.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '對話',
                          style: Theme.of(context).textTheme.headlineLarge,
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: search,
                          decoration: InputDecoration(
                            hintText: '搜尋對話標題（含已隱藏）',
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
                              label: const Text('全部'),
                              selected: !onlyPinned,
                              onSelected: (_) =>
                                  setState(() => onlyPinned = false),
                            ),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              avatar: Icon(
                                Icons.push_pin,
                                size: 16,
                                color: onlyPinned
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                              ),
                              label: Text('最愛（$pinnedCount）'),
                              selected: onlyPinned,
                              onSelected: (_) =>
                                  setState(() => onlyPinned = true),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Switch(
                              value: showHidden,
                              onChanged: (v) => setState(() => showHidden = v),
                            ),
                            Expanded(
                              child: Text(
                                '顯示已隱藏（$hiddenCount）',
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
                        Text(
                          visible.isEmpty
                              ? (query.isEmpty
                                    ? '目前沒有可瀏覽的對話。'
                                    : '找不到符合「$query」的對話。')
                              : '${visible.length} 段對話 · 最近活躍優先',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (skillState.hasError)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text('Skills 目錄尚未載入，可下拉重試。'),
                          ),
                      ],
                    ),
                  );
                }
                final s = visible[index - 1];
                final hidden = store.isHidden(server, s.id);
                final unread =
                    !hidden &&
                    s.count > 0 &&
                    store.readFingerprint(server, s.id) != s.readFingerprint;
                final date = DateTime.fromMillisecondsSinceEpoch(
                  (s.activity * 1000).round(),
                ).toLocal();
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 10,
                    ),
                    leading: CircleAvatar(
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
                            s.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: unread ? FontWeight.w700 : FontWeight.w400,
                              decoration: hidden ? TextDecoration.lineThrough : null,
                              color: hidden ? Colors.grey : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '${s.count} 則訊息 · ${date.month}/${date.day} · ${s.source}',
                      ),
                    ),
                    trailing: unread
                        ? Icon(
                            Icons.circle,
                            size: 7,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        : const Icon(Icons.more_vert, size: 20),
                    onTap: () => open(s),
                    onLongPress: () => showModalBottomSheet<void>(
                      context: context,
                      builder: (sheet) => SafeArea(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(
                              leading: Icon(
                                s.pinned
                                    ? Icons.push_pin
                                    : Icons.push_pin_outlined,
                              ),
                              title: Text(s.pinned ? '取消釘選' : '釘選在最上面'),
                              onTap: () {
                                Navigator.pop(sheet);
                                pin(s, !s.pinned);
                              },
                            ),
                            ListTile(
                              leading: const Icon(Icons.drive_file_rename_outline),
                              title: const Text('重新命名'),
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
                              title: Text(hidden ? '取消隱藏' : '隱藏此對話'),
                              onTap: () {
                                Navigator.pop(sheet);
                                hide(s, !hidden);
                              },
                            ),
                            ListTile(
                              leading: const Icon(
                                Icons.delete_outline,
                                color: Colors.red,
                              ),
                              title: const Text('刪除', style: TextStyle(color: Colors.red)),
                              onTap: () {
                                Navigator.pop(sheet);
                                delete(s);
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
