import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/message.dart';
import '../../models/session_activity.dart';
import '../../models/session.dart';
import '../../platform/chat_input_platform.dart';
import '../../providers.dart';
import '../attachments/file_drop.dart';
import '../attachments/gallery_picker.dart';
import '../settings/local_store.dart';
import '../settings/management_page.dart';
import 'chat_controller.dart';
import 'client_commands.dart';
import 'viewers.dart';
import 'typing_dots.dart';
import 'message_timeline.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key, required this.session});
  final Session session;
  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final input = TextEditingController();
  final scroll = ScrollController();
  bool follow = true;
  bool preparing = false, suppressDraft = false;
  bool firstLoaded = false;
  String draftError = '';
  Timer? draftTimer;
  late String title;
  bool _dragging = false;
  DropTarget? _dropTarget;
  // Riverpod 3 forbids `ref` after unmount: keep the controller so dispose()
  // can still detach() (a throw there skipped detach and let the stale draft
  // haunt the input box on re-entry).
  late final ChatController chat;
  // AUDIT-03: dispose() flushes the last unsent draft without touching ref.
  late final LocalStore _store;
  late final String _serverUrl;
  @override
  void initState() {
    super.initState();
    // AUDIT-21(D1): register as a viewer synchronously, before the
    // controller is even built — dedupe and the detach rule below read
    // this count, and neither may ever see a half-mounted page.
    ChatViewers.acquire(widget.session.id);
    title = widget.session.title;
    chat = ref.read(chatProvider(widget.session.id));
    final store = ref.read(localStoreProvider);
    _store = store;
    final serverUrl = ref.read(settingsProvider).url;
    _serverUrl = serverUrl;
    final saved = store.draft(serverUrl, widget.session.id);
    // A draft identical to the last delivered user message is the ghost of an
    // already-sent turn (its clearing raced a disposed page); drop it here so
    // re-entry opens with an empty box.
    input.text = _isGhostDraft(saved, chat) ? '' : saved;
    input.addListener(() {
      setState(() {});
      if (suppressDraft) return;
      // Debounced draft save so leaving (or dying) mid-typing keeps the text.
      draftTimer?.cancel();
      draftTimer = Timer(const Duration(milliseconds: 400), () {
        ref
            .read(localStoreProvider)
            .saveDraft(
              ref.read(settingsProvider).url,
              widget.session.id,
              input.text,
            );
      });
    });
    scroll.addListener(() {
      follow = scroll.position.maxScrollExtent - scroll.offset < 120;
      if (scroll.offset < 80 && firstLoaded) {
        final controller = ref.read(chatProvider(widget.session.id));
        if (controller.hasOlder &&
            !controller.loadingOlder &&
            !controller.busy) {
          unawaited(older());
        }
      }
    });
    Future.microtask(() async {
      // Re-entering (or F5-reopening) the session: bootstrap replaces
      // attach()+load — warm pages keep attach semantics, cold controllers
      // rejoin an outstanding turn read-only from the pending record.
      await chat.bootstrap();
      if (!mounted) return;
      final stale = store.draft(serverUrl, widget.session.id);
      if (_isGhostDraft(stale, chat)) {
        draftTimer?.cancel();
        suppressDraft = true;
        input.clear();
        suppressDraft = false;
        unawaited(store.saveDraft(serverUrl, widget.session.id, ''));
      }
    });
    if (fileDropSupported) {
      _dropTarget = DropTarget(
        onFiles: (files) => unawaited(
          ref.read(attachmentsProvider(widget.session.id)).addFiles(files),
        ),
        onEnter: () {
          if (mounted) setState(() => _dragging = true);
        },
        onLeave: () {
          if (mounted) setState(() => _dragging = false);
        },
      );
      attachFileDrop(_dropTarget!);
    }
  }

  @override
  void dispose() {
    draftTimer?.cancel();
    // AUDIT-03: the debounce window must never swallow the last keystrokes —
    // commit the current snapshot through the captured store (fire-and-forget,
    // no ref). After a send the box is already empty, so this can only ever
    // persist UNSSENT text; the ghost-draft rule on re-entry stays intact.
    unawaited(_store.saveDraft(_serverUrl, widget.session.id, input.text));
    if (_dropTarget case final t?) detachFileDrop(t);
    // Leaving the page: cut this session's SSE so the server counts the run as
    // unwatched — that arms ntfy push and, with the v0.12 patch, the run keeps
    // executing server-side. A poll timer surfaces its result on re-entry.
    // AUDIT-21(D1): only the LAST viewer's pop may cut the stream — a
    // second route for the same sid still watching must keep its attach.
    // The viewer bookkeeping stays synchronous (open()/LRU read it right
    // after), but detach() notifies listeners and riverpod 3 forbids
    // that inside the build-phase unmount a Navigator pop performs —
    // run it in the same-tick microtask instead; the SSE still dies
    // before any network can observe a change.
    if (ChatViewers.release(widget.session.id)) {
      final leaving = chat;
      scheduleMicrotask(leaving.detach);
    }
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  /// Ghost draft = unsent-looking text that equals the last delivered user
  /// turn; it can only be the echo of a message this client already sent.
  bool _isGhostDraft(String text, ChatController controller) {
    if (text.isEmpty) return false;
    for (final m in controller.messages.reversed) {
      if (m.isUserTurn) return m.content == text;
    }
    return false;
  }

  Future<void> rename() async {
    final controller = TextEditingController(text: title);
    final next = await showDialog<String>(
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
    if (next == null || next.isEmpty || next == title || !mounted) return;
    try {
      await ref.read(repositoryProvider).renameSession(widget.session.id, next);
      await ref
          .read(localStoreProvider)
          .cacheTitle(ref.read(settingsProvider).url, widget.session.id, next);
      if (mounted) setState(() => title = next);
      ref.invalidate(sessionsProvider);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('改名失敗')));
      }
    }
  }

  Future<void> older() async {
    if (!scroll.hasClients) return;
    final extent = scroll.position.maxScrollExtent;
    final offset = scroll.offset;
    await ref.read(chatProvider(widget.session.id)).loadOlder();
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) {
        scroll.jumpTo(
          (offset + scroll.position.maxScrollExtent - extent).clamp(
            0.0,
            scroll.position.maxScrollExtent,
          ),
        );
      }
    });
  }

  // Enter 傳送、Shift+Enter 換行（桌面/網頁鍵盤慣例）；行動端 Enter 由下方
  // insertNewline 落地換行（decideChatInputKey 依有效輸入平台判定）。
  KeyEventResult _inputKey(FocusNode _, KeyEvent event) => decideChatInputKey(
    event,
    shiftDown: HardwareKeyboard.instance.isShiftPressed,
    composing: input.value.composing.isValid,
    sendAllowed: !preparing,
    platform: chatInputPlatform,
    send: () => unawaited(send()),
    insertNewline: _insertNewlineAtCaret,
  );

  void _insertNewlineAtCaret() {
    final v = input.value;
    final sel = v.selection.isValid
        ? v.selection
        : TextSelection.collapsed(offset: v.text.length);
    input.value = v.copyWith(
      text: v.text.replaceRange(sel.start, sel.end, '\n'),
      selection: TextSelection.collapsed(offset: sel.start + 1),
    );
  }

  static bool get _mobileComposer =>
      chatInputPlatform == TargetPlatform.android ||
      chatInputPlatform == TargetPlatform.iOS;

  /// 軟鍵盤的送出 action：走同一個 send()，slash/附件/草稿/busy 守則共用，
  /// 不直接呼叫 controller.send 繞過流程。
  void _submitFromIme() {
    final attachments = ref.read(attachmentsProvider(widget.session.id));
    if (input.text.trim().isEmpty && attachments.drafts.isEmpty) return;
    unawaited(send());
  }

  /// busy 時仍可執行的 slash 指令（/stop、/steer 與 worksWhileBusy 指令），
  /// 給送出按鈕的啟用條件用；未知 slash／一般文字在忙碌時一律不放行。
  bool _busyCommandAllowed(ChatController c, String text) {
    final value = text.trim();
    if (value == '/stop' || value.startsWith('/steer ')) return true;
    final m = RegExp(r'^/(\S+)(?:\s+.*)?$').firstMatch(value);
    final name = m?.group(1);
    if (name == null) return false;
    final cmd = ref
        .read(clientCommandsProvider)
        .where((c) => c.name == name && c.worksWhileBusy)
        .firstOrNull;
    return cmd != null;
  }

  Future<void> send() async {
    final controller = ref.read(chatProvider(widget.session.id));
    final value = input.text.trim();
    if (value == '/stop') {
      // stop() 現在會回結果：失敗（無 runId／停止未確認）必須看得到原因，
      // 不能無聲 no-op；成功才清輸入框。
      final ok = await controller.stop();
      if (ok) input.clear();
      return;
    }
    if (value.startsWith('/steer ')) {
      if (!controller.detailed || !controller.canControl) {
        setState(() => draftError = '請在詳細模式中對進行中的對話插話。');
        return;
      }
      try {
        await controller.steer(value.substring(7));
        input.clear();
      } catch (_) {
        /* Controller renders the error; retain draft. */
      }
      return;
    }
    final attachments = ref.read(attachmentsProvider(widget.session.id));
    if (value.startsWith('/')) {
      final m = RegExp(r'^/(\S+)(?:\s+(.*))?$').firstMatch(value);
      final name = m?.group(1) ?? '';
      final args = m?.group(2) ?? '';
      final cmd = ref
          .read(clientCommandsProvider)
          .where((c) => c.name == name)
          .firstOrNull;
      if (cmd != null) {
        if (preparing ||
            (controller.displayBusy && !cmd.worksWhileBusy)) {
          return;
        }
        input.clear();
        await cmd.run(context, ref, controller, args);
        return;
      }
    }
    // AUDIT-09: bootstrap 尚未判定 pending 前也不得送新訊息（sendBlocked）。
    if (controller.sendBlocked || preparing || attachments.busy) return;
    setState(() => preparing = true);
    try {
      final rewritten = rewriteSkills(
        value,
        ref.read(skillsProvider).asData?.value ?? [],
      );
      await ref
          .read(localStoreProvider)
          .saveDraft(ref.read(settingsProvider).url, widget.session.id, value);
      final prompt = await attachments.prepare(rewritten);
      if (!mounted) return;
      setState(() {
        draftError = '';
        preparing = false;
      });
      draftTimer?.cancel();
      suppressDraft = true;
      input.clear();
      suppressDraft = false;
      follow = true;
      // 送達即清: the controller voids the draft the moment the stream opens
      // (server accepted the message). Waiting for send() to return first left
      // the sent text haunting the input box whenever detach/recover made it
      // resolve only at run end, and an attachments.clear() throw used to
      // skip the clearing entirely.
      await controller.send(prompt, draft: value);
      if (controller.error == null) await attachments.clear();
      if (!mounted) return;
      ref.invalidate(sessionsProvider);
      if (mounted &&
          controller.error != null &&
          controller.phase == ChatPhase.idle) {
        input.text = value;
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => draftError =
              attachments.error ??
              (e is FormatException ? e.message : '傳送失敗，草稿已保留。'),
        );
      }
    } finally {
      if (mounted) setState(() => preparing = false);
    }
  }

  Future<void> showSteer() async {
    final draft = TextEditingController();
    final guidance = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('插話'),
        content: TextField(
          controller: draft,
          autofocus: true,
          minLines: 2,
          maxLines: 6,
          decoration: const InputDecoration(hintText: '補充指示或調整方向'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, draft.text),
            child: const Text('送出'),
          ),
        ],
      ),
    );
    // Dialog route may still animate while its TextField is mounted.
    Future<void>.delayed(const Duration(seconds: 1), draft.dispose);
    if (guidance == null || guidance.trim().isEmpty || !mounted) return;
    try {
      await ref.read(chatProvider(widget.session.id)).steer(guidance);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('插話已接受')));
      }
    } catch (_) {
      /* Error shown inline. */
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(chatProvider(widget.session.id));
    final attachments = ref.watch(attachmentsProvider(widget.session.id));
    final skills = ref.watch(skillsProvider).asData?.value ?? <Skill>[];
    final match = RegExp(r'(?:^|\s)/([^\s]*)$').firstMatch(input.text);
    // 清單三分層：app 指令（能跑）→ gateway 指令（原文直通模型）→ skills。
    final suggestions = input.text.startsWith('/') && match != null
        ? [
            for (final c in ref.watch(clientCommandsProvider))
              if (c.name.startsWith(match.group(1)!))
                _SlashItem('/${c.name}', c.description),
            for (final (name, desc) in gatewayPassthroughCommands)
              if (name.startsWith(match.group(1)!))
                _SlashItem('/$name', '問 agent：$desc'),
            ...skills
                .where((s) => s.name.startsWith(match.group(1)!))
                .map((s) => _SlashItem('/${s.name}', s.description)),
          ].take(8).toList()
        : const <_SlashItem>[];
    if (!c.loading && (!firstLoaded || follow) && !c.loadingOlder) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (scroll.hasClients && mounted) {
          scroll.jumpTo(scroll.position.maxScrollExtent);
          firstLoaded = true;
        }
      });
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          PopupMenuButton<String>(
            tooltip: '對話選單',
            onSelected: (v) {
              if (v == 'rename') rename();
              if (v == 'model') {
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        ManagementPage(sessionId: widget.session.id),
                  ),
                );
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'rename',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.drive_file_rename_outline),
                  title: Text('重新命名'),
                ),
              ),
              PopupMenuItem(
                value: 'model',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.memory_outlined),
                  title: Text('切換模型'),
                ),
              ),
            ],
          ),
          IconButton(
            tooltip: c.detailed ? '切換簡略模式' : '切換詳細模式',
            onPressed: c.toggleDetail,
            icon: Icon(
              c.detailed ? Icons.view_agenda_outlined : Icons.short_text,
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  child: Row(
                    children: [
                  Text(
                    c.detailed ? '詳細時間軸' : '簡略對話',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const Spacer(),
                  if (c.busy)
                    const Text('進行中', style: TextStyle(fontSize: 12))
                  else if (c.remoteBusy)
                    const Text(
                      '其他裝置進行中',
                      style: TextStyle(fontSize: 12),
                    )
                  else if (c.activityBlocksSend)
                    const Text('狀態確認中…', style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
            if (c.backgrounded)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('背景中，連線可能中斷；回前景將立即核對歷史。'),
              ),
            if (c.remoteBusy)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final r in c.remoteActiveRuns)
                      Row(
                        children: [
                          Text(
                            c.remoteRunLabel(r),
                            style: const TextStyle(fontSize: 12),
                          ),
                          const SizedBox(width: 8),
                          if (!r.isTerminal) const TypingDots(),
                        ],
                      ),
                    if (c.observedActivity?.overflow == true)
                      const Text('⋯（進行中回合過多，僅顯示部分）',
                          style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            if (c.activityFreshness == ActivityFreshness.stale)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  '即時狀態擷取失敗，顯示最後一次成功核對的結果'
                  '${c.lastActivitySuccess == null ? '' : '（${TimeOfDay.fromDateTime(c.lastActivitySuccess!).format(context)}）'}'
                  '；可能還有未顯示的進行中回合。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            if (c.stopNotice != null)
              MaterialBanner(
                content: Text(
                  c.stopNotice!.startsWith('{') ? '此對話曾由你要求停止' : c.stopNotice!,
                ),
                actions: [
                  TextButton(
                    onPressed: c.dismissStopNotice,
                    child: const Text('收起'),
                  ),
                ],
              ),
            if (c.error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        c.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                    if (c.phase == ChatPhase.uncertain)
                      TextButton(
                        onPressed: c.retryReconcile,
                        child: const Text('重新核對'),
                      ),
                    if (!c.busy)
                      TextButton(onPressed: c.load, child: const Text('重試')),
                  ],
                ),
              ),
            Expanded(
              child: c.loading
                  ? const Center(child: CircularProgressIndicator())
                  : RefreshIndicator(
                      onRefresh: () async {
                        ref.invalidate(skillsProvider);
                        await c.load();
                      },
                      child: ListView(
                        controller: scroll,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        children: [
                          if (c.hasOlder)
                            Center(
                              child: TextButton(
                                onPressed: c.loadingOlder || c.busy
                                    ? null
                                    : older,
                                child: Text(c.loadingOlder ? '載入中…' : '載入較早訊息'),
                              ),
                            ),
                          if (c.messages.isEmpty && c.live == null)
                            const Padding(
                              padding: EdgeInsets.all(40),
                              child: Text(
                                '這段對話還沒有訊息。',
                                textAlign: TextAlign.center,
                              ),
                            ),
                          MessageTimeline(
                            messages: c.messages,
                            remoteRows: c.remoteRows,
                            detailed: c.detailed,
                          ),
                          // R2: every busy shape must look busy. The pending
                          // bubble follows one rule in both branches (never
                          // twice-drawn once history carries the row); the
                          // "發言中" row covers what LiveTurnView does not
                          // narrate: live==null busy states — the sending
                          // gap before the stream attaches, bootstrap
                          // recovering, and the detached poll pass.
                          if (c.pendingBubbleText != null)
                            EntryView(
                              entry: DisplayEntry(
                                EntryKind.user,
                                Message(
                                  id: 'pending',
                                  role: 'user',
                                  content: c.pendingBubbleText!,
                                ),
                              ),
                            ),
                          if (c.busy && c.live == null)
                            Padding(
                              padding: const EdgeInsets.only(right: 20, bottom: 4),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  Text(
                                    '發言中',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  const TypingDots(),
                                ],
                              ),
                            ),
                          if (c.live != null)
                            LiveTurnView(
                              turn: c.live!,
                              detailed: c.detailed,
                              onResolve: c.resolveApproval,
                            ),
                        ],
                      ),
                    ),
            ),
            if (suggestions.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView(
                  shrinkWrap: true,
                  children: suggestions
                      .map(
                        (s) => ListTile(
                          dense: true,
                          title: Text(s.command),
                          subtitle: Text(
                            s.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () {
                            final prefix = input.text.substring(
                              0,
                              match!.start,
                            );
                            input.text =
                                '$prefix${prefix.isEmpty ? '' : ' '}${s.command} ';
                            input.selection = TextSelection.collapsed(
                              offset: input.text.length,
                            );
                          },
                        ),
                      )
                      .toList(),
                ),
              ),
            if (draftError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  draftError,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  if (c.busy)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (c.detailed)
                          TextButton.icon(
                            onPressed: c.canControl && !c.steerBusy
                                ? showSteer
                                : null,
                            icon: const Icon(Icons.add_comment_outlined),
                            label: const Text('插話'),
                          ),
                        TextButton.icon(
                          onPressed: c.canStop
                              ? () => unawaited(c.stop())
                              : null,
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: const Text('停止'),
                        ),
                      ],
                    ),
                  if (attachments.error != null)
                    Text(
                      attachments.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  if (attachments.busy) const LinearProgressIndicator(),
                  if (attachments.drafts.isNotEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 120),
                      child: SingleChildScrollView(
                        child: Wrap(
                          children: attachments.drafts
                              .asMap()
                              .entries
                              .map(
                                (e) => InputChip(
                                  label: Text(
                                    '${e.value.filename}${e.value.uploaded ? '（已上傳）' : ''}',
                                  ),
                                  onDeleted:
                                      c.busy || preparing || attachments.busy
                                      ? null
                                      : () => attachments.remove(e.key),
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      IconButton(
                        tooltip: '加入附件',
                        icon: const Icon(Icons.add),
                        onPressed: c.busy || preparing || attachments.busy
                            ? null
                            : () async {
                                final picked = await pickFromGallery(
                                  context,
                                  onPickOther: attachments.pick,
                                );
                                if (picked != null) {
                                  await attachments.pickSource(
                                    picked.source,
                                    picked.filename,
                                  );
                                }
                              },
                      ),
                      Expanded(
                        child: Focus(
                          onKeyEvent: _inputKey,
                          child: TextField(
                            controller: input,
                            enabled: !preparing && !attachments.busy,
                            keyboardType: TextInputType.multiline,
                            minLines: 1,
                            maxLines: 6,
                            // 兩端 action=newline：行動端 Enter（含軟鍵盤）
                            // 必定換行（第一優先，Flutter 版本間 maxLines 行為
                            // 有漂移）。實機驗證項：行動端以 ↑ 送出鍵傳送；若
                            // IME 仍送來 send/done action，由 onSubmitted 接手。
                            textInputAction: TextInputAction.newline,
                            // onSubmitted 前框架預設會先清 composing 並 unfocus
                            // ——提供 onEditingComplete 攔下預設流程（保留 focus
                            // 與 composing），選字未確認時的 send action 才會
                            // 在下方守門被擋掉（零 POST、候選文字保留）。
                            onEditingComplete: () {},
                            onSubmitted: (_) {
                              if (input.value.composing.isValid) return;
                              _submitFromIme();
                            },
                            decoration: InputDecoration(
                              hintText: c.busy
                                  ? '可輸入 /stop'
                                  : c.remoteBusy
                                  ? '此工作階段正由其他裝置執行'
                                  : c.activityBlocksSend
                                  ? '狀態確認中，暫停送出'
                                  : _mobileComposer
                                  ? 'Enter 換行，按送出鍵傳送'
                                  : '傳送訊息，Enter 傳送 / Shift+Enter 換行',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(22),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        tooltip: '傳送',
                        onPressed:
                            preparing ||
                                attachments.busy ||
                                (input.text.trim().isEmpty &&
                                    attachments.drafts.isEmpty) ||
                                (c.sendBlocked &&
                                    !_busyCommandAllowed(c, input.text))
                            ? null
                            : send,
                        icon: const Icon(Icons.arrow_upward),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          ),
          ),
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.08),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 3,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Center(
                    child: Text('放進來，我會當成附件'),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// `/` 聯想清單列（app 指令、gateway 直通指令、skills 共用）。
class _SlashItem {
  const _SlashItem(this.command, this.description);
  final String command, description;
}
