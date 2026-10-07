import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_strings.dart';
import '../../l10n/date_labels.dart';
import '../../l10n/localized_text.dart';
import '../../l10n/message_key.dart';
import '../../l10n/ui_message.dart';
import '../../models/message.dart';
import '../../models/session_activity.dart';
import '../../models/session.dart';
import '../../platform/chat_input_platform.dart';
import '../../platform/store_tx.dart';
import '../../providers.dart';
import '../attachments/attachment_controller.dart';
import '../attachments/file_drop.dart';
import '../attachments/gallery_picker.dart';
import '../settings/local_store.dart';
import '../settings/management_page.dart';
import 'approval_inbox_view.dart';
import 'notification_inbox.dart';
import 'remote_steer.dart';
import 'run_link.dart';
import 'chat_controller.dart';
import 'client_commands.dart';
import 'local_attempt.dart';
import 'remote_stop.dart';
import 'viewers.dart';
import 'typing_dots.dart';
import 'message_timeline.dart';
import 'tool_timeline_projection.dart';

/// Attachment-button pick feedback (IOS-PICKER-PLAN B4 — presentation
/// wiring only, never the chat state machine): await the pick, then show
/// ONE SnackBar per unsuccessful result. A cancel leaves `error` null and
/// stays silent; the controller stores only locale-free descriptors (no
/// BuildContext, no pretranslated strings). Calling pick starts the DOM
/// input on this synchronous path — no await before the browser click.
Future<void> pickWithFeedback(
  AttachmentController attachments,
  BuildContext context,
) async {
  await attachments.pick();
  if (!context.mounted) return;
  final message = attachments.error;
  if (message == null) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(AppStrings.of(context).render(message))),
  );
}

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key, required this.session, this.deepLink});
  final Session session;

  /// 01412FIX F5: the exact deep link this page was opened FROM (if any);
  /// it focuses the approval/request the link named — navigation, not a
  /// guess.
  final RunLink? deepLink;
  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final input = TextEditingController();
  final scroll = ScrollController();
  bool follow = true;
  bool preparing = false, suppressDraft = false;
  bool firstLoaded = false;
  UiMessage? draftError;
  Timer? draftTimer;
  late String title;
  bool _dragging = false;
  DropTarget? _dropTarget;
  // Riverpod 3 forbids `ref` after unmount: keep the controller so dispose()
  // can still detach() (a throw there skipped detach and let the stale draft
  // haunt the input box on re-entry).
  late final ChatController chat;
  bool _focused = false; // APPWAKE: editor focus feeds the typing gate
  // AUDIT-03: dispose() flushes the last unsent draft without touching ref.
  late final LocalStore _store;
  late final String _serverUrl;
  bool _wakeSessionOff = false; // APPWAKE D: per-session opt-out
  // ---- OFFLINE-SEND R2 §4.3: draft discipline ------------------------------
  // Every composer write (debounce, dispose flush, restore, first-frame
  // clear) rides the SAME draft-revision CAS: the revision counter — never
  // the text — decides write ownership. A stale callback loses the CAS and
  // must not write, even when the texts happen to match.
  int _draftRev = 0;
  String? _restoreAttemptId; // journal attempt whose rawDraft awaits restore
  bool _restoreConflict = false; // chatDraftRestoreConflict notice showing
  final Set<String> _restoredOnce = {}; // restore executes ONCE per attempt
  bool _pageGone = false;
  @override
  void initState() {
    super.initState();
    // AUDIT-21(D1): register as a viewer synchronously, before the
    // controller is even built — dedupe and the detach rule below read
    // this count, and neither may ever see a half-mounted page.
    ChatViewers.acquire(widget.session.id);
    title = widget.session.title;
    chat = ref.read(chatProvider(widget.session.id));
    final deepLink = widget.deepLink;
    if (deepLink != null) chat.applyDeepLink(deepLink);
    final store = ref.read(localStoreProvider);
    _store = store;
    final serverUrl = ref.read(settingsProvider).url;
    _serverUrl = serverUrl;
    _draftRev = store.draftRevision(serverUrl, widget.session.id);
    final saved = store.draft(serverUrl, widget.session.id);
    _wakeSessionOff = store.autoWakeSessionOff(serverUrl, widget.session.id);
    // A draft identical to the last delivered user message is the ghost of an
    // already-sent turn (its clearing raced a disposed page); drop it here so
    // re-entry opens with an empty box. R2: an attempt-backed draft is NEVER
    // ghost-cleared on text equality alone (revision-gated CAS instead).
    input.text = _isGhostDraft(saved, chat) ? '' : saved;
    // R2 §4.3: an UNSAVED-slot residue — an abandoned/unresolved attempt's
    // rawDraft with the slot empty — surfaces as the restore action only,
    // never silently into the editor.
    _scanJournalRestore();
    input.addListener(() {
      setState(() {});
      // APPWAKE: typing (focus or text) pauses auto-dispatch; putting the
      // editor down resumes it (the controller owns the queue check).
      chat.noteInputActive(_focused || input.text.trim().isNotEmpty);
      if (suppressDraft) return;
      // A real keystroke re-grounds the revision: the live editor is the
      // freshest content, and the debounce write below claims whatever
      // revision the store has reached SINCE the last successful write.
      final rev = _store.draftRevision(_serverUrl, widget.session.id);
      if (rev != _draftRev) _draftRev = rev;
      // Debounced draft save so leaving (or dying) mid-typing keeps the text.
      draftTimer?.cancel();
      draftTimer = Timer(const Duration(milliseconds: 400), () {
        unawaited(_persistDraft(input.text));
      });
    });
    scroll.addListener(() {
      follow = scroll.position.maxScrollExtent - scroll.offset < 120;
      // Auto-load near the TOP only. A clamped jumpTo at the bottom of a
      // momentarily short viewport reports offset < 80 with offset == max;
      // that is not a reader scrolling into older rows (and the in-list
      // load-older button covers pages too short to ever pass this gate).
      if (scroll.offset < 80 && !follow && firstLoaded) {
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
        // R2 §4.3: even the first-frame clear rides the CAS — a draft that
        // moved under us (new tab, restore) is never wiped by a stale clear.
        unawaited(_persistDraft(''));
      }
      if (input.text.isEmpty) {
        final found = _scanJournalRestore();
        if (found) setState(() {});
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

  /// 01412FIX F5: the notification card locates its EXACT event. Same
  /// session → focus in place (event read + approval/run focus); another
  /// session → hand the exact link to the ROOT router (which re-resolves
  /// hidden/deleted identity itself) and pop there — never a local guess.
  void _openNotification(RunLink link) {
    if (link.sessionId == widget.session.id) {
      chat.applyDeepLink(link);
      return;
    }
    unawaited(_store.stashDeepLink(link.toUrl()));
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  void dispose() {
    _pageGone = true;
    // APPWAKE: this editor is gone — a stale "typing" flag must not park
    // the queue forever for a controller that outlives the page.
    chat.noteInputActive(false);
    draftTimer?.cancel();
    // AUDIT-03: the debounce window must never swallow the last keystrokes —
    // commit the current snapshot through the captured store (fire-and-forget,
    // no ref). R2 §4.3: the flush is CAS-gated. An EMPTY editor only proves
    // THIS composer is empty — it must never overwrite a newer draft, an
    // unrestored attempt snapshot's slot, or a reopened page's fresh write.
    final text = input.text;
    final rev = _draftRev;
    unawaited(() async {
      final ok = await _store.saveDraftCas(
        _serverUrl,
        widget.session.id,
        text,
        expectedRevision: rev,
      );
      if (!ok && _store.draft(_serverUrl, widget.session.id) == text) {
        // The slot already holds exactly this text: nothing to flush.
        _draftRev = _store.draftRevision(_serverUrl, widget.session.id);
      }
      // Otherwise this page lost the CAS: the newer writer stands.
    }());
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
  /// R2 §4.3/§5.4: when a human attempt owns the draft (a live pending
  /// record, or the latest unresolved attempt whose snapshot matches), text
  /// equality alone must NEVER clear it — identity/revision decide, not the
  /// bytes. Legacy (pre-R2, attemptId-less) records keep the old rule.
  bool _isGhostDraft(String text, ChatController controller) {
    if (text.isEmpty) return false;
    final pending = _store.loadPending(_serverUrl, widget.session.id);
    if (pending != null && pending.attemptId != null && !pending.isAutoWake) {
      return false;
    }
    if (pending == null) {
      final all = [
        for (final a in _store.listAttempts(_serverUrl, widget.session.id))
          if (a.origin == 'human' && a.rawDraft == text) a,
      ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final latest = all.isEmpty ? null : all.last;
      if (latest != null && latest.disposition != AttemptDisposition.settled) {
        return false; // an unresolved attempt's draft — identity-gated, not text
      }
    }
    for (final m in controller.messages.reversed) {
      if (m.isUserTurn) return m.content == text;
    }
    return false;
  }

  /// R2 §4.3: the ONE composer-write rule. CAS on the tracked revision; a
  /// loss against a MOVED revision retries only while the LIVE editor still
  /// shows this exact text (then the editor is the freshest content). A dead
  /// page never retries; a stale snapshot never overwrites anything.
  Future<void> _persistDraft(String text) async {
    final ok = await _store.saveDraftCas(
      _serverUrl,
      widget.session.id,
      text,
      expectedRevision: _draftRev,
    );
    if (ok) {
      _draftRev = _store.draftRevision(_serverUrl, widget.session.id);
      return;
    }
    if (_pageGone) {
      if (_store.draft(_serverUrl, widget.session.id) == text) {
        _draftRev = _store.draftRevision(_serverUrl, widget.session.id);
      }
      return;
    }
    final current = _store.draftRevision(_serverUrl, widget.session.id);
    if (current != _draftRev && mounted && input.text == text) {
      _draftRev = current;
      final retried = await _store.saveDraftCas(
        _serverUrl,
        widget.session.id,
        text,
        expectedRevision: current,
      );
      if (retried) {
        _draftRev = _store.draftRevision(_serverUrl, widget.session.id);
      }
      return;
    }
    if (_store.draft(_serverUrl, widget.session.id) == text) {
      _draftRev = _store.draftRevision(_serverUrl, widget.session.id);
    }
    // else: stale callback — silently refuse (the newer writer stands).
  }

  /// R2 §4.3: surface an unrestored attempt snapshot as the restore action
  /// ONLY when the draft slot is empty and the journal holds a human
  /// attempt's raw draft that was never restored into this revision.
  /// Returns true when a candidate was found (caller may repaint).
  bool _scanJournalRestore() {
    if (_restoreAttemptId != null) return false;
    if (_store.draft(_serverUrl, widget.session.id).isNotEmpty) return false;
    final pending = _store.loadPending(_serverUrl, widget.session.id);
    final all = [
      for (final a in _store.listAttempts(_serverUrl, widget.session.id))
        if (a.origin == 'human' &&
            a.rawDraft != null &&
            a.rawDraft!.isNotEmpty &&
            a.draftRestoredRevision == null &&
            // First-frame-accepted evidence: a delivered attempt's snapshot
            // is spent, never a restore offer (the ghost rule's journal
            // twin, §4.3/M16).
            a.terminalEvidence?['accepted_frame'] != true &&
            (a.disposition == AttemptDisposition.abandoned ||
                (a.disposition == AttemptDisposition.waiting &&
                    (pending == null || pending.attemptId != a.attemptId))))
          a,
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (all.isEmpty) return false;
    _restoreAttemptId = all.last.attemptId;
    return true;
  }

  /// Consume the restore snapshot ONCE. Current user text always wins (the
  /// conflict notice keeps the button available); an empty editor receives
  /// the VERBATIM draft through the draft CAS, and the attempt records the
  /// revision it was restored at (reload never offers it twice).
  Future<void> _performRestore() async {
    final id = _restoreAttemptId;
    if (id == null || _restoredOnce.contains(id)) return;
    final a = _store.loadAttempt(_serverUrl, widget.session.id, id);
    final raw = a?.rawDraft;
    if (a == null || raw == null || raw.isEmpty) {
      _restoreAttemptId = null;
      return;
    }
    if (a.draftRestoredRevision != null) {
      _restoredOnce.add(id);
      if (mounted) setState(() => _restoreAttemptId = null);
      return; // idempotent consume: the journal already says "restored"
    }
    if (!mounted) return;
    if (input.text.isNotEmpty) {
      setState(() => _restoreConflict = true);
      return; // current text untouched; the button stays available
    }
    var ok = await _store.saveDraftCas(
      _serverUrl,
      widget.session.id,
      raw,
      expectedRevision: _draftRev,
    );
    if (ok) {
      _draftRev = _store.draftRevision(_serverUrl, widget.session.id);
    } else {
      final current = _store.draftRevision(_serverUrl, widget.session.id);
      if (_store.draft(_serverUrl, widget.session.id) == raw) {
        _draftRev = current;
        ok = true; // the slot already holds exactly the snapshot
      } else if (current != _draftRev && mounted && input.text.isEmpty) {
        _draftRev = current;
        ok = await _store.saveDraftCas(
          _serverUrl,
          widget.session.id,
          raw,
          expectedRevision: current,
        );
        if (ok) _draftRev = _store.draftRevision(_serverUrl, widget.session.id);
      }
    }
    if (!ok) {
      if (mounted) setState(() => _restoreConflict = true);
      return;
    }
    suppressDraft = true;
    input.text = raw; // VERBATIM: leading/trailing spaces, newlines, unicode
    suppressDraft = false;
    if (mounted) {
      await ref
          .read(attachmentsProvider(widget.session.id))
          .mergeForRestore(a.attachmentSnapshots);
    }
    await _store.saveAttempt(
      _serverUrl,
      widget.session.id,
      LocalAttempt(
        attemptId: a.attemptId,
        server: a.server,
        sid: a.sid,
        createdAt: a.createdAt,
        origin: a.origin,
        rawDraft: a.rawDraft,
        preparedInput: a.preparedInput,
        attachmentSnapshots: a.attachmentSnapshots,
        editorRevision: a.editorRevision,
        disposition: a.disposition,
        delivery: a.delivery,
        runId: a.runId,
        historyAfterId: a.historyAfterId,
        serverEpoch: a.serverEpoch,
        recoveryStartedAt: a.recoveryStartedAt,
        recoveryDeadline: a.recoveryDeadline,
        retryUsed: a.retryUsed,
        draftRestoredRevision: _draftRev,
        terminalEvidence: a.terminalEvidence,
      ),
    );
    _restoredOnce.add(id);
    if (mounted) {
      setState(() {
        _restoreAttemptId = null;
        _restoreConflict = false;
      });
    }
  }

  /// The ONE stop entry (R2 §4.3): `/stop` command and the stop affordance
  /// route here. The command string + revision are captured BEFORE the
  /// await; the command text clears only if the editor still holds EXACTLY
  /// that command at the SAME revision. A local end then seeds the restore
  /// snapshot into an EMPTY editor — otherwise it is the conflict notice,
  /// never an overwrite.
  Future<void> _stopPath(ChatController c, {bool isCommand = false}) async {
    final commandText = input.text;
    final commandRevision = _draftRev;
    var result = await c.stop();
    if (!mounted) return;
    if (result.kind == StopResultKind.remoteChoice) {
      // CROSSDEV-STOP R2 §5.1: nothing was picked, nothing was POSTed. The
      // chooser only names a target; cancelling it has zero side effects and
      // leaves the typed /stop exactly where it is.
      final target = await _showRemoteStopChooser(c);
      if (!mounted) return;
      if (target == null) {
        setState(() {});
        return;
      }
      final remote = await c.stopRemote(target);
      if (!mounted) return;
      result = StopResult(
        StopResultKind.remoteResult,
        remote: remote,
        message: remote.message,
      );
    }
    // §5.3: only an accepted-and-not-failed outcome consumes the COMMAND
    // (never a draft). targetChanged / failed / unconfirmed keep the input,
    // and no remote outcome ever reaches the restore path below.
    if (isCommand &&
        result.success &&
        input.text == commandText &&
        _draftRev == commandRevision) {
      draftTimer?.cancel();
      suppressDraft = true;
      input.clear();
      suppressDraft = false;
    }
    if (result.kind == StopResultKind.localWaitingEnded &&
        result.attemptId != null) {
      _restoreAttemptId = result.attemptId;
      if ((result.restoreDraft ?? '').isEmpty) {
        // Journal-side snapshot: fall back to the reload-style scan so a
        // persisted (or crash-left) tombstone entry still surfaces.
        _scanJournalRestore();
      }
      if (input.text.isEmpty && _restoreAttemptId != null) {
        await _performRestore();
      } else if (input.text.isNotEmpty && _restoreAttemptId != null) {
        setState(() => _restoreConflict = true);
      } else if (mounted) {
        setState(() {});
      }
    } else if (mounted) {
      setState(() {}); // publish whatever the stop attempt surfaced
    }
  }

  /// CROSSDEV-STOP R2 §5.1/§5.3: the target chooser. Rows carry source,
  /// status and the SHORT run id — NEVER a preview as identity; entries the
  /// server cannot name appear DISABLED with a readable reason. Under
  /// overflow the listed rows stay individually actionable and the note
  /// states the list may not be everything.
  Future<RemoteStopTarget?> _showRemoteStopChooser(ChatController c) {
    final rows = c.remoteStopChooserRows;
    final overflow = c.remoteCandidatesOverflowed;
    return showModalBottomSheet<RemoteStopTarget>(
      context: context,
      builder: (context) {
        final strings = AppStrings.of(context);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  strings.resolve(MessageKey.chatStopRemoteChoose),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (overflow)
                Padding(
                  key: const ValueKey('chat.stopChooserOverflow'),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    strings.resolve(MessageKey.chatM016),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final row in rows)
                      if (row.actionable)
                        ListTile(
                          key: ValueKey(
                            'chat.stopChooser.${remoteStopShortId(row.target!.runId)}',
                          ),
                          title: Text(row.label),
                          onTap: () => Navigator.pop(context, row.target),
                        )
                      else
                        ListTile(
                          key: ValueKey('chat.stopChooser.blocked'),
                          enabled: false,
                          title: Text(row.label),
                          subtitle: Text(
                            strings.resolve(row.blockReason!),
                            key: const ValueKey('chat.stopChooser.reason'),
                          ),
                        ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(strings.resolve(MessageKey.commonCancel)),
              ),
            ],
          ),
        );
      },
    );
  }

  /// A remote row's stop action: it aims at the NAMED row only and never
  /// touches the composer, the local attempt machinery or the draft.
  Future<void> _remoteStopRow(ChatController c, RemoteStopTarget target) async {
    await c.stopRemote(target);
    if (mounted) setState(() {});
  }

  Widget _remoteStopAction(
    AppStrings strings,
    ChatController c,
    ActivityRun r,
  ) {
    final runId = r.runId;
    if (runId == null || runId.trim().isEmpty) {
      // A row the server never named: DISABLED affordance + the reason in
      // readable text next to it (§5.3). Flexible so the pair can never
      // overflow the row at narrow widths.
      return Expanded(
        child: Row(
          key: const ValueKey('chat.remoteStopDisabled'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              label: strings.resolve(MessageKey.chatStopRemoteNoRunId),
              button: true,
              child: IconButton(
                onPressed: null,
                tooltip: strings.resolve(MessageKey.chatStopRemoteHelp),
                icon: const Icon(Icons.stop_circle_outlined),
              ),
            ),
            Flexible(
              child: Text(
                strings.resolve(MessageKey.chatStopRemoteNoRunId),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }
    final target = c.remoteTargetForRun(runId);
    if (target != null) {
      return IconButton(
        key: ValueKey('chat.remoteStop.$runId'),
        onPressed: c.remoteStopInFlight
            ? null
            : () => unawaited(_remoteStopRow(c, target)),
        tooltip: strings.resolve(MessageKey.chatStopRemoteHelp),
        icon: const Icon(Icons.stop_circle_outlined),
      );
    }
    // Visible ≠ stoppable: a row this page may not control says so in
    // readable text, never tooltip-only (§5.3/V16).
    final reason =
        c.remoteDisabledReason ?? MessageKey.chatStopRemoteRefreshRequired;
    return Expanded(
      child: Row(
        key: const ValueKey('chat.remoteStopDisabled'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            label: strings.resolve(reason),
            button: true,
            child: IconButton(
              onPressed: null,
              tooltip: strings.resolve(MessageKey.chatStopRemoteHelp),
              icon: const Icon(Icons.stop_circle_outlined),
            ),
          ),
          Flexible(
            child: Text(
              strings.resolve(reason),
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  // ---- STEERWEB R4: per-row steer affordance ------------------------------
  Widget _remoteSteerAction(
    AppStrings strings,
    ChatController c,
    ActivityRun r,
  ) {
    final runId = r.runId;
    if (runId == null || runId.trim().isEmpty) return const SizedBox.shrink();
    final steerable =
        c.steerTargetForRun(runId) != null ||
        r.status == 'waiting_for_approval';
    if (!steerable) {
      return Expanded(
        child: Row(
          key: ValueKey('chat.remoteSteerDisabled.$runId'),
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.chat_bubble_outline, size: 18),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                strings.resolve(MessageKey.steerUnavailable),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }
    return IconButton(
      key: ValueKey('chat.remoteSteer.$runId'),
      onPressed: () => unawaited(_steerDialog(c, runId)),
      tooltip: strings.resolve(MessageKey.steerAction),
      icon: const Icon(Icons.chat_bubble_outline),
    );
  }

  Future<void> _steerDialog(ChatController c, String runId) async {
    final strings = AppStrings.of(context);
    final controller = TextEditingController(
      text: c.steerDraftFor(runId) ?? '',
    );
    var watch = false;
    final send = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(strings.resolve(MessageKey.steerAction)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                strings.resolve(MessageKey.steerNextBoundary),
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('chat.steerInput'),
                controller: controller,
                autofocus: true,
                maxLines: 3,
                maxLength: 8192,
              ),
              // R7: steer.ready is an EXPLICIT per-run opt-in (the ledger
              // records nothing without this), never a per-message nag.
              CheckboxListTile(
                key: const ValueKey('chat.steerWatch'),
                value: watch,
                onChanged: (v) => setState(() => watch = v ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  strings.resolve(MessageKey.steerNotifyReady),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(strings.resolve(MessageKey.commonCancel)),
            ),
            FilledButton(
              key: const ValueKey('chat.steerSend'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(strings.resolve(MessageKey.steerAction)),
            ),
          ],
        ),
      ),
    );
    final text = controller.text.trim();
    if (send != true || text.isEmpty) return;
    if (watch) await c.watchSteerReady(runId);
    final target = c.steerTargetForRun(runId);
    final outcome = target == null
        ? const RemoteSteerOutcome(RemoteSteerKind.staleTarget)
        : await c.submitRemoteSteer(target, text);
    if (!mounted) return;
    final message = outcome.message ?? remoteSteerMessage(outcome.kind);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        key: const ValueKey('chat.steerOutcome'),
        content: Text(
          message is UiLocal
              ? strings.resolve(message.key, args: message.args)
              : '$message',
        ),
      ),
    );
  }

  Future<void> rename() async {
    final controller = TextEditingController(text: title);
    final next = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppStrings.of(context).resolve(MessageKey.sessionsRename)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 120,
          decoration: InputDecoration(
            hintText: AppStrings.of(context).resolve(MessageKey.sessionsName),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              AppStrings.of(context).resolve(MessageKey.commonCancel),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(AppStrings.of(context).resolve(MessageKey.commonSave)),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            // Resolved inside the route: follows a later language switch.
            content: const LocalizedText(
              UiMessage.local(MessageKey.sessionsRenameFailed),
            ),
          ),
        );
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
      // stop() now reports WHAT it did. The command text clears only while
      // the editor still holds exactly this command (§4.3); a failure keeps
      // it (with the reason visible), a local end seeds the restore.
      await _stopPath(controller, isCommand: true);
      return;
    }
    if (value.startsWith('/steer ')) {
      if (!controller.detailed || !controller.canControl) {
        setState(() => draftError = const UiMessage.local(MessageKey.chatM001));
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
        if (preparing || (controller.displayBusy && !cmd.worksWhileBusy)) {
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
    final rawText = input.text; // R2 §4.3: the VERBATIM draft for the journal
    try {
      final rewritten = rewriteSkills(
        value,
        ref.read(skillsProvider).asData?.value ?? [],
      );
      await _persistDraft(value);
      final prompt = await attachments.prepare(rewritten);
      if (!mounted) return;
      setState(() {
        draftError = null;
        preparing = false;
      });
      final consumed = List.of(attachments.drafts);
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
      await controller.send(prompt, draft: value, rawDraft: rawText);
      // R2 §4.3: decide from THIS attempt's outcome — never from the shared
      // error slot. Attachments clear only for a confirmed-accepted send; a
      // rejected/localSettled/lost attempt keeps draft AND attachments, and
      // text the user typed in the meantime is never overwritten.
      final outcome = controller.sendOutcome;
      if (outcome == SendOutcome.accepted ||
          (outcome == null &&
              controller.error == null &&
              controller.phase == ChatPhase.idle)) {
        await attachments.clearForAttempt(consumed);
      }
      if (!mounted) return;
      ref.invalidate(sessionsProvider);
      if (mounted &&
          controller.error != null &&
          controller.phase == ChatPhase.idle &&
          outcome != SendOutcome.accepted &&
          // R2 §4.3: a local settlement owns the draft through the restore
          // snapshot (§4.2) — re-inserting `value` here would race that
          // seeding and win with the TRIMMED text.
          outcome != SendOutcome.localSettled &&
          input.text.isEmpty) {
        input.text = value;
      }
      if (mounted && outcome == SendOutcome.localSettled) {
        if (_scanJournalRestore()) setState(() {});
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => draftError =
              attachments.error ??
              (e is FormatException
                  ? messageForError(e)
                  : const UiMessage.local(MessageKey.chatM002)),
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
        title: Text(AppStrings.of(context).resolve(MessageKey.chatSteer)),
        content: TextField(
          controller: draft,
          autofocus: true,
          minLines: 2,
          maxLines: 6,
          decoration: InputDecoration(
            hintText: AppStrings.of(context).resolve(MessageKey.chatM003),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              AppStrings.of(context).resolve(MessageKey.commonCancel),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, draft.text),
            child: Text(AppStrings.of(context).resolve(MessageKey.chatM004)),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const LocalizedText(UiMessage.local(MessageKey.chatM005)),
          ),
        );
      }
    } catch (_) {
      /* Error shown inline. */
    }
  }

  /// Pending-count / quota hint text; null = show nothing.
  String? _wakeHintText(AppStrings strings, ChatController c) {
    if (!ref.read(localStoreProvider).autoWakeEnabled(_serverUrl) ||
        _wakeSessionOff) {
      return null;
    }
    if (c.wakeQuotaHit) {
      return strings.resolve(MessageKey.wakeQuotaNotice);
    }
    if (c.wakePendingCount > 0) {
      return strings.resolve(
        MessageKey.wakePendingCount,
        args: {'count': '${c.wakePendingCount}'},
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final c = ref.watch(chatProvider(widget.session.id));
    // TOOLCARD-DUP: ONE tool-overlap projection computed per build from
    // this snapshot and passed to BOTH sibling views — the two sides must
    // never compute removals independently and drop the same tool twice.
    // Identity candidates come from the durable `c.messages` rows only
    // (never remoteRows or the pending bubble).
    final toolOverlap = projectToolOverlap(
      sessionId: widget.session.id,
      history: c.messages,
      live: c.live,
    );
    final attachments = ref.watch(attachmentsProvider(widget.session.id));
    final skills = ref.watch(skillsProvider).asData?.value ?? <Skill>[];
    final match = RegExp(r'(?:^|\s)/([^\s]*)$').firstMatch(input.text);
    // 清單三分層：app 指令（能跑）→ gateway 指令（原文直通模型）→ skills。
    // Descriptions are descriptors (keys or RAW server text), rendered by
    // LocalizedText so an open menu follows a language switch (§4.5).
    final suggestions = input.text.startsWith('/') && match != null
        ? [
            for (final c in ref.watch(clientCommandsProvider))
              if (c.name.startsWith(match.group(1)!))
                _SlashItem('/${c.name}', UiMessage.local(c.descriptionKey)),
            for (final (name, desc) in gatewayPassthroughCommands)
              if (name.startsWith(match.group(1)!))
                _SlashItem(
                  '/$name',
                  UiMessage.local(
                    MessageKey.chatM006,
                    args: {'desc': UiMessage.local(desc)},
                  ),
                ),
            ...skills
                .where((s) => s.name.startsWith(match.group(1)!))
                .map(
                  (s) => _SlashItem('/${s.name}', UiMessage.raw(s.description)),
                ),
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
        title: Text(
          // Raw cacheTitle; untitled fallback happens only at render.
          displaySessionTitle(AppStrings.of(context), title),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: strings.resolve(MessageKey.chatM007),
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
              if (v == 'wake') {
                // APPWAKE D: session-level opt-out (mirrored in the store;
                // the dispatch gate re-reads it at every attempt).
                setState(() => _wakeSessionOff = !_wakeSessionOff);
                unawaited(
                  ref
                      .read(localStoreProvider)
                      .setAutoWakeSessionOff(
                        ref.read(settingsProvider).url,
                        widget.session.id,
                        _wakeSessionOff,
                      ),
                );
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'rename',
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.drive_file_rename_outline),
                  title: Text(strings.resolve(MessageKey.sessionsRename)),
                ),
              ),
              PopupMenuItem(
                value: 'model',
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.memory_outlined),
                  title: Text(strings.resolve(MessageKey.chatM008)),
                ),
              ),
              // APPWAKE D: the menu only EXISTS where the server offers
              // auto-wake — a pure install never shows an inert toggle.
              if (c.wakeFeatureOffered)
                PopupMenuItem(
                  value: 'wake',
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.schedule_outlined),
                    title: Text(
                      strings.resolve(
                        _wakeSessionOff
                            ? MessageKey.chatWakeSessionOn
                            : MessageKey.chatWakeSessionOff,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          IconButton(
            tooltip: strings.resolve(
              c.detailed ? MessageKey.chatM009 : MessageKey.chatM010,
            ),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      Text(
                        strings.resolve(
                          c.detailed
                              ? MessageKey.chatM011
                              : MessageKey.chatM012,
                        ),
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      const Spacer(),
                      if (c.busy)
                        Text(
                          strings.resolve(MessageKey.chatM013),
                          style: const TextStyle(fontSize: 12),
                        )
                      else if (c.remoteBusy)
                        Text(
                          strings.resolve(MessageKey.chatRemoteBusy),
                          style: const TextStyle(fontSize: 12),
                        )
                      else if (c.activityBlocksSend)
                        Text(
                          strings.resolve(MessageKey.chatM014),
                          style: const TextStyle(fontSize: 12),
                        ),
                    ],
                  ),
                ),
                if (c.backgrounded)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(strings.resolve(MessageKey.chatM015)),
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
                              Expanded(
                                flex: 3,
                                child: Text(
                                  ChatController.formatRemoteRunLabel(
                                    strings,
                                    r,
                                  ),
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                              // CROSSDEV-STOP §3.3/§5.2: a `stopping` row shows
                              // 「正在核對」 purely from the fresh activity — no
                              // local state, no pending, no POST of any kind.
                              if (c.remoteStoppingRunIds.contains(r.runId))
                                Text(
                                  strings.resolve(
                                    MessageKey.chatStopRemoteChecking,
                                  ),
                                  style: const TextStyle(fontSize: 12),
                                )
                              else if (!r.isTerminal)
                                const TypingDots(),
                              // §5.1/§5.3: per-row stop action; disabled rows
                              // carry a READABLE reason, never tooltip-only.
                              _remoteStopAction(strings, c, r),
                              if (c.steerInboxEnabled)
                                _remoteSteerAction(strings, c, r),
                            ],
                          ),
                        if (c.observedActivity?.overflow == true)
                          Text(
                            strings.resolve(MessageKey.chatM016),
                            style: const TextStyle(fontSize: 12),
                          ),
                      ],
                    ),
                  ),
                if (c.activityFreshness == ActivityFreshness.stale)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      // Fixed local HH:mm in both locales (I18N-PLAN §7).
                      strings.resolve(
                        MessageKey.chatActivityStaleSummary,
                        args: {
                          'time': c.lastActivitySuccess == null
                              ? ''
                              : strings.resolve(
                                  MessageKey.commonParenthesized,
                                  args: {
                                    'value': formatLocalClock(
                                      c.lastActivitySuccess!,
                                    ),
                                  },
                                ),
                        },
                      ),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (c.stopNoticeKind != StopNotice.none)
                  MaterialBanner(
                    content: Text(
                      // Explicit provenance replaces the old startsWith('{')
                      // heuristic (§4.4); the stored JSON is never displayed.
                      c.stopNoticeMessage != null
                          ? strings.render(c.stopNoticeMessage!)
                          : strings.resolve(MessageKey.chatM019),
                    ),
                    actions: [
                      TextButton(
                        onPressed: c.dismissStopNotice,
                        child: Text(strings.resolve(MessageKey.chatM020)),
                      ),
                    ],
                  ),
                // CROSSDEV-STOP R2 §5.2/§5.3: remote wording rides the SECONDARY
                // tone — requested/checking/unavailable/unconfirmed/ended are
                // reconciliation states, never the red error slot, and never a
                // local stop-banner.
                if (c.remoteStopFeedback != null)
                  Padding(
                    key: const ValueKey('chat.remoteStopFeedback'),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      strings.render(c.remoteStopFeedback!),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.tertiary,
                      ),
                    ),
                  ),
                // SILENCE-DROP §3.3: "waiting for a reply" is its own
                // secondary-tone line — never red, never folded into the
                // error slot (the stream is alive; nothing failed).
                if (c.streamWaitingNotice != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      strings.render(c.streamWaitingNotice!),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (c.error != null ||
                    c.recoveryNotice != null ||
                    c.failedCard != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (c.error != null)
                          Text(
                            strings.render(c.error!),
                            style: TextStyle(
                              // SILENCE-DROP §3.3: neutral recovery wording
                              // (silence/recheck) renders in the secondary
                              // tone; ONLY observed stream failures stay red.
                              color: switch (c.error) {
                                UiLocal(key: MessageKey.chatStreamChecking) ||
                                UiLocal(
                                  key: MessageKey.chatStreamUnconfirmed,
                                ) ||
                                // WEBSYNC F1: delivered is a fact, not a fault.
                                UiLocal(
                                  key: MessageKey.chatDeliveredReplyLoading,
                                ) => Theme.of(context).colorScheme.tertiary,
                                _ => Theme.of(context).colorScheme.error,
                              },
                            ),
                          ),
                        // STUCK-BUSY B2: the "ended without a final" notice has
                        // its own slot so a cleanup failure never masks it.
                        if (c.recoveryNotice != null)
                          Text(
                            strings.render(c.recoveryNotice!),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.tertiary,
                            ),
                          ),
                        // R3 §5.3: the notDispatched card survives into idle
                        // reloads (journal-sourced), where no live `error` was
                        // ever set for it.
                        if (c.failedCard != null && c.error == null)
                          Text(
                            strings.render(c.failedCard!),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        // R3 §5.3/§6: the neutral delivery note for an
                        // attempt-backed attempt still stuck at "unknown".
                        if (c.deliveryNotice != null)
                          Text(
                            strings.render(c.deliveryNotice!),
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        Row(
                          children: [
                            // STUCK-BUSY B4: 「重新核對」 shows only while the
                            // ONE persisted allowance is still unconsumed.
                            if (c.phase == ChatPhase.uncertain &&
                                c.recoveryRetryAvailable)
                              TextButton(
                                onPressed: c.retryReconcile,
                                child: Text(
                                  strings.resolve(MessageKey.chatM021),
                                ),
                              ),
                            // R3 §5.3: the ONLY retry POST affordance — the
                            // notDispatched card's. Without RESOLVED Web Locks
                            // it renders DISABLED beside the degraded notice
                            // (§4.5); unknown/rejected never offer retry.
                            if (c.retryUnsentAttemptId != null)
                              TextButton(
                                key: const ValueKey('chat.retryUnsent'),
                                onPressed: c.retryUnsentAvailable
                                    ? () => unawaited(
                                        c.retryUnsent(c.retryUnsentAttemptId!),
                                      )
                                    : null,
                                child: Text(
                                  strings.resolve(MessageKey.chatRetryUnsent),
                                ),
                              ),
                            // R2 §4.2: an abandoned tombstone's ONLY action is
                            // the local cleanup retry — zero POSTs, no budget.
                            if (c.localCleanupRetryAvailable)
                              TextButton(
                                onPressed: () =>
                                    unawaited(c.retryLocalCleanup()),
                                child: Text(
                                  strings.resolve(
                                    MessageKey.chatClearLocalWaiting,
                                  ),
                                ),
                              ),
                            if (c.phase == ChatPhase.uncertain &&
                                c.hasLocalWaitingRecord &&
                                !c.localCleanupRetryAvailable)
                              TextButton(
                                onPressed: c.clearLocalWaitingRecord,
                                child: Text(
                                  strings.resolve(
                                    MessageKey.chatClearLocalWaiting,
                                  ),
                                ),
                              ),
                            // §4.3: the uncertain-row clear above routes through
                            // the SAME journal-first local end (clearLocalWaiting
                            // Record → endLocalAttempt) — one exit, no second
                            // button duplicating it.
                            if (!c.busy)
                              TextButton(
                                onPressed: c.load,
                                child: Text(
                                  strings.resolve(MessageKey.commonRetry),
                                ),
                              ),
                          ],
                        ),
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
                                    child: Text(
                                      strings.resolve(
                                        c.loadingOlder
                                            ? MessageKey.chatM022
                                            : MessageKey.chatM023,
                                      ),
                                    ),
                                  ),
                                ),
                              if (c.messages.isEmpty && c.live == null)
                                Padding(
                                  padding: const EdgeInsets.all(40),
                                  child: Text(
                                    strings.resolve(MessageKey.chatM024),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              MessageTimeline(
                                messages: c.messages,
                                remoteRows: c.remoteRows,
                                wakeRowIds: c.wakeRowIds,
                                detailed: c.detailed,
                                toolOverrides: toolOverlap.durableOverrides,
                                slotScope: toolOverlap.scope,
                              ),
                              // APPWAKE D: quiet status line while reports wait
                              // for their (rate-limited) auto-read.
                              if (c.wakeFeatureOffered &&
                                  _wakeHintText(strings, c) != null)
                                Padding(
                                  key: const ValueKey('chat.wakeHint'),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                    vertical: 2,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.schedule,
                                        size: 14,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.outline,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        _wakeHintText(strings, c)!,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ],
                                  ),
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
                                  padding: const EdgeInsets.only(
                                    right: 20,
                                    bottom: 4,
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      // STUCK-BUSY B4 / OFFLINE-SEND R1 (A5) /
                                      // R3 §5.3: the controller derives ONE
                                      // presentation state; this row only
                                      // renders it. `dispatching` says「正在送出
                                      // 訊息…」with NO dots (never 發言中);
                                      // `activeConfirmed` keeps the existing
                                      // 發言中 row; `countdown` shows the
                                      // persisted recovery countdown; `silent`
                                      // (uncertain / evidence-less) shows and
                                      // animates nothing.
                                      if (c.livePresentation ==
                                          LivePresentation.countdown)
                                        Text(
                                          strings.render(
                                            UiMessage.local(
                                              MessageKey.chatRecoveryCountdown,
                                              args: {
                                                'seconds':
                                                    c.recoverySecondsRemaining!,
                                              },
                                            ),
                                          ),
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                        )
                                      else if (c.livePresentation ==
                                          LivePresentation.dispatching)
                                        Text(
                                          strings.resolve(
                                            MessageKey.chatSendDispatching,
                                          ),
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                        )
                                      else if (c.livePresentation ==
                                          LivePresentation.activeConfirmed) ...[
                                        Text(
                                          strings.resolve(MessageKey.chatM025),
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        const TypingDots(),
                                      ],
                                    ],
                                  ),
                                ),
                              // APPROVALPUSH B3 (R6): exact-request cards for
                              // every pending approval in this session (local OR
                              // remote — never a fake turn row).
                              if (c.approvalInboxSupported)
                                PendingApprovalsPanel(
                                  requests: c.pendingApprovals(),
                                  unconfirmedRuns: c.approvalUnconfirmedRuns,
                                  onResolve: c.resolveApprovalExact,
                                  onReconfirm: c.reconfirmApprovals,
                                  focusRequestId: c.approvalFocus,
                                ),
                              if (c.approvalLegacyNotice)
                                Padding(
                                  key: const ValueKey('approval-legacy-notice'),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 4,
                                  ),
                                  child: Text(
                                    strings.resolve(
                                      MessageKey.approvalCrossDeviceUnavailable,
                                    ),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              // STEERWEB R4: durable steer receipt cards — their
                              // OWN surface; never message rows, never a turn.
                              if (c.steerInboxEnabled &&
                                  c.steerReceipts.isNotEmpty)
                                Padding(
                                  key: const ValueKey('steer-receipts-panel'),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 4,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      for (final r in c.steerReceipts)
                                        Row(
                                          key: ValueKey(
                                            'steer-receipt-${r.steerId}',
                                          ),
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(Icons.outbox, size: 16),
                                            const SizedBox(width: 6),
                                            Flexible(
                                              child: Text(
                                                strings.resolve(
                                                  steerStateKey(r),
                                                  args: {
                                                    'sequence': r.sequence,
                                                  },
                                                ),
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      for (final runId in {
                                        for (final r in c.steerReceipts)
                                          r.runId,
                                      })
                                        if (c.steerDraftFor(runId) != null)
                                          TextButton.icon(
                                            key: ValueKey('steer-retry-$runId'),
                                            onPressed: () => unawaited(
                                              c.retrySteerDraft(runId),
                                            ),
                                            icon: const Icon(
                                              Icons.refresh,
                                              size: 16,
                                            ),
                                            label: Text(
                                              strings.resolve(
                                                MessageKey.steerRetrySame,
                                              ),
                                            ),
                                          ),
                                    ],
                                  ),
                                ),
                              // STEERWEB R7: the account notification ledger —
                              // exact-event cards with read acks; NEVER text-
                              // derived, NEVER an approval action disguised.
                              if (c.notificationEventsEnabled &&
                                  c.notifications.hasUnread)
                                Padding(
                                  key: const ValueKey('notification-panel'),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 4,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      for (final e in c.notifications.unread)
                                        Row(
                                          key: ValueKey(
                                            'notification-${e.eventId}',
                                          ),
                                          children: [
                                            Expanded(
                                              child: InkWell(
                                                key: ValueKey(
                                                  'notification-open-${e.eventId}',
                                                ),
                                                onTap: () =>
                                                    _openNotification(e.link),
                                                child: Text(
                                                  strings.resolve(switch (e
                                                      .kind) {
                                                    NotificationKind
                                                        .approvalRequest =>
                                                      MessageKey
                                                          .notificationApproval,
                                                    NotificationKind
                                                        .completed =>
                                                      MessageKey
                                                          .notificationCompleted,
                                                    NotificationKind.failed =>
                                                      MessageKey
                                                          .notificationFailed,
                                                    NotificationKind
                                                        .steerReady =>
                                                      MessageKey
                                                          .notificationSteerReady,
                                                    _ =>
                                                      MessageKey
                                                          .notificationSettled,
                                                  }),
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ),
                                            ),
                                            TextButton(
                                              key: ValueKey(
                                                'notification-read-${e.eventId}',
                                              ),
                                              onPressed: () => unawaited(
                                                c.markNotificationRead(
                                                  e.eventId,
                                                ),
                                              ),
                                              child: Text(
                                                strings.resolve(
                                                  MessageKey.notificationRead,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                    ],
                                  ),
                                ),
                              if (c.live != null)
                                LiveTurnView(
                                  turn: c.live!,
                                  detailed: c.detailed,
                                  onResolve: c.resolveApproval,
                                  // R1 (A5): the transcript owns its dots on the
                                  // SAME phase rule as before — uncertain never
                                  // "types". (R3 §5.3 changes the WORDING of an
                                  // unacknowledged send, not this animation.)
                                  showTyping: switch (c.phase) {
                                    ChatPhase.sending => true,
                                    ChatPhase.recovering =>
                                      c.recoveryActiveConfirmed,
                                    _ => false,
                                  },
                                  // GHOST-DUP B4 (legacy) + R3 §5.4: attempt-
                                  // backed turns exclude transcript rows by
                                  // durable ID ONLY — never on text.
                                  transcriptUserAnchor: c.pendingInput,
                                  identityOnlyExclusion: c.turnIsAttemptBacked,
                                  representedUserIds: {
                                    for (final m in c.messages) m.id,
                                  },
                                  toolProjection: toolOverlap,
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
                                strings.render(s.description),
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
                if (draftError != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      strings.render(draftError!),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                // R2 §4.5: a browser WITHOUT Web Locks cannot coordinate tabs —
                // say it out loud instead of pretending cross-tab safety.
                if (storeTxCapability == StoreTxCapability.unavailable)
                  Padding(
                    key: const ValueKey('chat.crossTabSafetyReduced'),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      strings.resolve(MessageKey.chatCrossTabSafetyReduced),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                // R2 §4.3: the restore snapshot is consumed EXACTLY ONCE and
                // never overwrites current text — with text present it is the
                // conflict notice plus the (still available) restore action.
                if (_restoreAttemptId != null || _restoreConflict)
                  Padding(
                    key: const ValueKey('chat.restoreDraft'),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        if (_restoreConflict)
                          Expanded(
                            child: Text(
                              strings.resolve(
                                MessageKey.chatDraftRestoreConflict,
                              ),
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        if (_restoreAttemptId != null)
                          TextButton(
                            onPressed: () => unawaited(_performRestore()),
                            child: Text(
                              strings.resolve(MessageKey.chatRestoreDraft),
                            ),
                          ),
                      ],
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
                                label: Text(
                                  strings.resolve(MessageKey.chatSteer),
                                ),
                              ),
                            TextButton.icon(
                              // R2 §4.3: ONE stop entry — server control when a
                              // run exists, the local end when only this page's
                              // attempt waiting is (stop() branches internally).
                              // CROSSDEV-STOP §5.3: a stoppable remote row also
                              // enables it (stop() still routes LOCAL FIRST; the
                              // remote branch only runs when local has no target,
                              // and never while a remote flight is in flight).
                              onPressed:
                                  (c.canStop ||
                                          c.canEndLocalWaiting ||
                                          c.canRequestRemoteStop) &&
                                      !c.remoteStopInFlight
                                  ? () => unawaited(_stopPath(c))
                                  : null,
                              icon: const Icon(Icons.stop_circle_outlined),
                              label: Text(
                                strings.resolve(
                                  c.canStop || c.canEndLocalWaiting
                                      ? MessageKey.chatM026
                                      : MessageKey.chatStopRemote,
                                ),
                              ),
                            ),
                          ],
                        )
                      else if (c.canRequestRemoteStop ||
                          c.remoteDisabledReason != null ||
                          c.remoteStopInFlight)
                        // CROSSDEV-STOP §5.3: the remote affordance outside the
                        // local busy row. Honest enablement matrix: enabled only
                        // with a stoppable target and never mid-flight; a disabled
                        // pair shows the reason as READABLE text (chatStopRemote
                        // NoRunId / RefreshRequired), never tooltip-only.
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          key: const ValueKey('chat.remoteStopAffordance'),
                          children: [
                            if (c.remoteDisabledReason != null &&
                                !c.canRequestRemoteStop)
                              Flexible(
                                child: Text(
                                  strings.resolve(c.remoteDisabledReason!),
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            TextButton.icon(
                              onPressed:
                                  c.canRequestRemoteStop &&
                                      !c.remoteStopInFlight
                                  ? () => unawaited(_stopPath(c))
                                  : null,
                              icon: const Icon(Icons.stop_circle_outlined),
                              label: Text(
                                strings.resolve(MessageKey.chatStopRemote),
                              ),
                            ),
                          ],
                        ),
                      if (attachments.error != null)
                        Text(
                          strings.render(attachments.error!),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        )
                      else if (attachments.batchParts.isNotEmpty)
                        // Locale-specific join happens HERE (plan §4.3): the
                        // controller kept typed counts + descriptors only.
                        Text(
                          strings.resolve(
                            attachments.batchSucceeded == 0
                                ? MessageKey.attachmentBatchM005
                                : MessageKey.attachmentBatchM006,
                            args: {
                              'parts': strings.joinParts(
                                attachments.batchParts
                                    .map(strings.render)
                                    .toList(),
                              ),
                              'count': attachments.batchSucceeded,
                            },
                            count: attachments.batchSucceeded,
                          ),
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
                                        '${e.value.filename}'
                                        '${e.value.uploaded ? strings.resolve(MessageKey.chatM027) : ''}',
                                      ),
                                      onDeleted:
                                          c.busy ||
                                              preparing ||
                                              attachments.busy
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
                            tooltip: strings.resolve(MessageKey.chatM028),
                            icon: const Icon(Icons.add),
                            onPressed: c.busy || preparing || attachments.busy
                                ? null
                                : () async {
                                    final picked = await pickFromGallery(
                                      context,
                                      onPickOther: () => unawaited(
                                        pickWithFeedback(attachments, context),
                                      ),
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
                              onFocusChange: (has) {
                                _focused = has;
                                chat.noteInputActive(
                                  has || input.text.trim().isNotEmpty,
                                );
                              },
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
                                  hintText: strings.resolve(
                                    c.busy
                                        ? MessageKey.chatM029
                                        : c.remoteBusy
                                        ? MessageKey.chatM030
                                        : c.activityBlocksSend
                                        ? MessageKey.chatM031
                                        : _mobileComposer
                                        ? MessageKey.chatM032
                                        : MessageKey.chatM033,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(22),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filled(
                            tooltip: strings.resolve(MessageKey.chatM034),
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
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.08),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 3,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Center(
                    child: LocalizedText(UiMessage.local(MessageKey.chatM035)),
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
  final String command;

  /// Descriptor: catalog key or RAW server skill description (§5).
  final UiMessage description;
}
