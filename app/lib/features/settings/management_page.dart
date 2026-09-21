import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../api/hermes_repository.dart';
import '../../models/session.dart';
import '../../providers.dart';

/// Management surface. R3: the blocks are real now — skills toggle through
/// the reverse proxy's PATCH (upstream /v1/skills stays the list source),
/// MEMORY.md/USER.md edit through /api/memories, and the model catalog
/// survives mixed string/dict model entries (R3a).
class ManagementPage extends ConsumerStatefulWidget {
  const ManagementPage({super.key, this.sessionId});

  /// When set, the model block switches THIS session's model lock.
  final String? sessionId;

  @override
  ConsumerState<ManagementPage> createState() => _ManagementPageState();
}

class _ManagementPageState extends ConsumerState<ManagementPage> {
  // WAVE4 §3.7: only Skills/Model collapse, per SERVER (never per session).
  String? _server;
  final _collapsed = <String, bool>{}; // visible value
  final _persisted = <String, bool>{}; // last value confirmed on disk
  final _writes = <String, Future<void>>{}; // serialized per-section writes

  static const _sections = ['skills', 'model'];

  void _syncServer(String server) {
    if (_server == server) return;
    _server = server;
    final store = ref.read(localStoreProvider);
    for (final s in _sections) {
      final v = store.managementSectionCollapsed(server, s);
      _collapsed[s] = v;
      _persisted[s] = v;
    }
  }

  Future<void> _toggle(String section) async {
    final store = ref.read(localStoreProvider);
    final server = _server!;
    final next = !(_collapsed[section] ?? false);
    setState(() => _collapsed[section] = next);
    // Rapid taps must SERIALIZE — each write waits for the section's
    // previous one, so the LAST choice is what lands on disk.
    final mine = (_writes[section] ?? Future<void>.value()).then(
      (_) => store.setManagementSectionCollapsed(server, section, next),
    );
    _writes[section] = mine.catchError((_) {});
    try {
      await mine;
      _persisted[section] = next;
    } catch (_) {
      if (!mounted) return;
      setState(() => _collapsed[section] = _persisted[section] ?? false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('儲存失敗，摺疊狀態已還原')));
    }
  }

  String _summary<T>(AsyncValue<T> value, String Function(T) f) => value.when(
    loading: () => '載入中',
    error: (_, _) => '載入失敗',
    data: f,
  );

  @override
  Widget build(BuildContext context) {
    final server = ref.watch(settingsProvider).url;
    _syncServer(server);
    final models = ref.watch(modelOptionsProvider);
    final skills = ref.watch(skillsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('管理')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Section(
            title: 'Skills',
            icon: Icons.extension_outlined,
            collapsed: _collapsed['skills'] ?? false,
            summary: _summary(
              skills,
              (list) =>
                  '已啟用 ${list.where((s) => s.enabled).length} / 共 ${list.length}',
            ),
            onToggle: () => _toggle('skills'),
            child: const _SkillsBlock(),
          ),
          const _Section(
            title: 'Memory / USER',
            icon: Icons.psychology_outlined,
            child: _MemoryBlock(),
          ),
          _Section(
            title: 'Model',
            icon: Icons.memory_outlined,
            collapsed: _collapsed['model'] ?? false,
            summary: _summary(
              models,
              (c) => '全域目前：${c.global.isEmpty ? '未知' : c.global}',
            ),
            onToggle: () => _toggle('model'),
            child: models.when(
              loading: () => const _LoadingRow(),
              error: (e, _) =>
                  _ErrorRow(retry: () => ref.invalidate(modelOptionsProvider)),
              data: (catalog) => Column(
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '全域目前：${catalog.global.isEmpty ? '（未知）' : catalog.global}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (widget.sessionId == null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        '從對話頁開啟才能切換該對話的模型；此處為全域預設模型清單。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ...catalog.models.map(
                    (m) => ListTile(
                      dense: true,
                      leading: Icon(
                        m['current'] == true
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      title: Text('${m['model']}'),
                      subtitle: Text('${m['providerName']}'),
                      trailing: widget.sessionId == null || m['current'] == true
                          ? null
                          : TextButton(
                              onPressed: () async {
                                try {
                                  await ref
                                      .read(repositoryProvider)
                                      .setSessionModel(
                                        widget.sessionId!,
                                        '${m['model']}',
                                      );
                                  if (context.mounted) {
                                    ref.invalidate(modelOptionsProvider);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          '此對話改用 ${m['model']}',
                                        ),
                                      ),
                                    );
                                  }
                                } catch (_) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('換模型失敗')),
                                    );
                                  }
                                }
                              },
                              child: const Text('改用'),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Skills: the /v1/skills list + a real switch per row. Essential skills are
/// lock-only (the local mirror AND the server's own 400 keep them on); a
/// toggle invalidates the provider and the block states the one-turn lag.
class _SkillsBlock extends ConsumerStatefulWidget {
  const _SkillsBlock();
  @override
  ConsumerState<_SkillsBlock> createState() => _SkillsBlockState();
}

class _SkillsBlockState extends ConsumerState<_SkillsBlock> {
  final _toggling = <String>{};
  // Essentials the server confirmed by 400 this session (icon lock follows
  // the truth even if the local mirror above is outdated).
  final _lockedByServer = <String>{};

  Future<void> _toggle(Skill s, bool next) async {
    setState(() => _toggling.add(s.name));
    try {
      await ref.read(repositoryProvider).setSkillEnabled(s.name, next);
      ref.invalidate(skillsProvider);
    } on ApiException catch (e) {
      if (e.status == 400) setState(() => _lockedByServer.add(s.name));
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('切換失敗：$e')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('切換失敗')));
      }
    } finally {
      if (mounted) setState(() => _toggling.remove(s.name));
    }
  }

  @override
  Widget build(BuildContext context) {
    final skills = ref.watch(skillsProvider);
    return skills.when(
      loading: () => const _LoadingRow(),
      error: (e, _) => _ErrorRow(retry: () => ref.invalidate(skillsProvider)),
      data: (list) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${list.length} 個 skills',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          ...list.map((s) {
            final essential =
                essentialSkillNames.contains(s.name) ||
                _lockedByServer.contains(s.name);
            return ExpansionTile(
              dense: true,
              title: Text(s.name),
              subtitle: s.category.isEmpty ? null : Text(s.category),
              trailing: essential
                  ? const Icon(Icons.lock_outline, size: 18)
                  : Switch(
                      value: s.enabled,
                      onChanged: _toggling.contains(s.name)
                          ? null
                          : (v) => _toggle(s, v),
                    ),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.description),
                if (essential) ...[
                  const SizedBox(height: 6),
                  Text(
                    '核心 skill：不可停用',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            );
          }),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '開關在下個回合生效。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// Memory: the two whitelisted files with char counts/limits and mtime,
/// each tapping into a full-screen editor.
class _MemoryBlock extends ConsumerWidget {
  const _MemoryBlock();

  static String _mtime(Object? raw) {
    if (raw is! num) return '（尚無檔案）';
    final t = DateTime.fromMillisecondsSinceEpoch((raw * 1000).round());
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final files = ref.watch(memoriesProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'memory 在對話中的生效方式：MEMORY.md 每次對話注入；USER.md 同。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        ...files.when(
          loading: () => const [_LoadingRow()],
          error: (e, _) => [
            _ErrorRow(retry: () => ref.invalidate(memoriesProvider)),
          ],
          data: (list) => [
            for (final f in list)
              ListTile(
                dense: true,
                leading: const Icon(Icons.description_outlined, size: 18),
                title: Text('${f['name']}'),
                subtitle: Text(
                  '${f['chars']}/${f['limit']} 字元 · 最後修改 ${_mtime(f['mtime'])}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final saved = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => _MemoryEditor(
                        name: '${f['name']}',
                        limit: (f['limit'] as num?)?.toInt() ?? 0,
                        content: f['content'] as String? ?? '',
                      ),
                    ),
                  );
                  if (saved == true) ref.invalidate(memoriesProvider);
                },
              ),
          ],
        ),
      ],
    );
  }
}

class _MemoryEditor extends ConsumerStatefulWidget {
  const _MemoryEditor({
    required this.name,
    required this.limit,
    required this.content,
  });
  final String name;
  final int limit;
  final String content;
  @override
  ConsumerState<_MemoryEditor> createState() => _MemoryEditorState();
}

class _MemoryEditorState extends ConsumerState<_MemoryEditor> {
  late final TextEditingController _text =
      TextEditingController(text: widget.content);
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(repositoryProvider).saveMemory(widget.name, _text.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('儲存失敗：$e')));
      }
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final over =
        widget.limit > 0 && _text.text.characters.length > widget.limit;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('儲存'),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              if (over)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '已超過 ${widget.limit} 字元上限（agent 側慣例，非硬性閘門）——仍可強制儲存。',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Expanded(
                child: TextField(
                  controller: _text,
                  maxLines: null,
                  expands: true,
                  keyboardType: TextInputType.multiline,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(fontSize: 16, height: 1.5),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    required this.child,
    this.collapsed = false,
    this.summary,
    this.onToggle,
  });
  final String title;
  final IconData icon;
  final Widget child;

  /// WAVE4: collapsible sections pass the header toggle. Collapsing hides
  /// the body behind Offstage+TickerMode — stateful blocks (`_toggling`,
  /// `_lockedByServer`, in-flight PATCHes) survive; nothing is re-GET, and
  /// the body leaves tab order and accessibility.
  final bool collapsed;
  final String? summary;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final collapsible = onToggle != null;
    final headerRow = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          if (collapsed && summary != null) ...[
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                summary!,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ] else
            const Spacer(),
          if (collapsible)
            Icon(collapsed ? Icons.chevron_right : Icons.expand_less),
        ],
      ),
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!collapsible)
              headerRow
            else
              Semantics(
                button: true,
                expanded: !collapsed,
                child: Focus(
                  onKeyEvent: (node, event) {
                    if (event is KeyDownEvent &&
                        (event.logicalKey == LogicalKeyboardKey.enter ||
                            event.logicalKey == LogicalKeyboardKey.numpadEnter ||
                            event.logicalKey == LogicalKeyboardKey.space)) {
                      onToggle!();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: Tooltip(
                    message: collapsed ? '展開 $title' : '收合 $title',
                    child: InkWell(onTap: onToggle, child: headerRow),
                  ),
                ),
              ),
            // SAME element position and type in both modes — only flags
            // and padding flip — so the block's State (PATCH bookkeeping,
            // locks) lives through the fold. Offstage takes no room.
            Padding(
              padding: EdgeInsets.only(top: collapsed ? 0 : 12),
              child: TickerMode(
                enabled: !collapsed,
                child: Offstage(offstage: collapsed, child: child),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingRow extends StatelessWidget {
  const _LoadingRow();
  @override
  Widget build(BuildContext context) => const LinearProgressIndicator();
}

class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.retry});
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Text('載入失敗'),
      TextButton(onPressed: retry, child: const Text('重試')),
    ],
  );
}
