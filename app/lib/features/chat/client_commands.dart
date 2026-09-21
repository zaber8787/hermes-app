import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/hermes_repository.dart';
import '../../l10n/app_strings.dart';
import '../../l10n/date_labels.dart';
import '../../l10n/localized_text.dart';
import '../../l10n/message_key.dart';
import '../../l10n/ui_message.dart';
import '../../providers.dart';
import '../../models/session_activity.dart';
import 'chat_controller.dart';
import 'chat_page.dart';
import 'viewers.dart';

/// Enter 傳送的按鍵判定（chat_page 與測試共用）。shiftDown 由呼叫端從
/// HardwareKeyboard 實體狀態讀取——中文 IME 選字按 Enter 事件不帶 shift
/// 旗標，读 KeyEvent.shift 會誤判。
///
/// platform 是「有效輸入平台」（chatInputPlatform，非 defaultTargetPlatform
/// 直讀）：Android/iOS 的 Enter（含 numpad、含 Shift）一律由呼叫端插入換行
/// 並吞掉事件（不送出）；桌面/任何 Web 維持 Enter 傳送、Shift+Enter 換行。
/// 換行由框架自己落地（insertNewline），不依賴引擎行為——widget 測試測得到；
/// 實機驗證項：極少數嵌入端若同時自行插入會產生雙換行。
KeyEventResult decideChatInputKey(
  KeyEvent event, {
  required bool shiftDown,
  required bool composing,
  required bool sendAllowed,
  required TargetPlatform platform,
  required void Function() send,
  required void Function() insertNewline,
}) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }
  final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
      event.logicalKey == LogicalKeyboardKey.numpadEnter;
  if (!isEnter) return KeyEventResult.ignored;
  // 中文選字中的 Enter 屬 IME（引擎會提交選字），框架不插手、更不發傳送
  if (composing) return KeyEventResult.ignored;
  if (platform == TargetPlatform.android || platform == TargetPlatform.iOS) {
    // 行動端 Enter＝換行鍵（第一優先）：自己插入並回 handled。
    insertNewline();
    return KeyEventResult.handled;
  }
  if (shiftDown) return KeyEventResult.ignored; // 換行由 multiline 處理
  if (sendAllowed) send();
  return KeyEventResult.handled;
}

/// 一個 slash 指令的 client 端實作。
/// run 回 true＝指令已被吃掉，別把原文當訊息送出。
/// api_server 這條路不做 gateway slash 攔截（實測 2026-09-14：`/reset` 原文
/// 直達模型），要能用的指令必須在 app 端落地。`/stop`、`/steer` 在
/// chat_page 的 send() 先行攔截，不在這裡重複列。
class ClientCommand {
  const ClientCommand(
    this.name,
    this.descriptionKey, {
    this.worksWhileBusy = false,
    required this.run,
  });

  final String name;

  /// Catalog key (I18N-PLAN §4.4): descriptions resolve at render; the
  /// provider never rebuilds for language (callback identity stays fixed).
  final MessageKey descriptionKey;

  /// true 時 agent 跑著也能用（中斷類指令）。
  final bool worksWhileBusy;
  final Future<bool> Function(
    BuildContext,
    WidgetRef,
    ChatController,
    String args,
  )
  run;
}

final clientCommandsProvider = Provider<List<ClientCommand>>((ref) {
  Future<bool> startFresh(
    BuildContext context,
    WidgetRef ref,
    ChatController chat,
    _,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final created = await ref.read(repositoryProvider).createSession();
      ref.invalidate(sessionsProvider);
      if (!context.mounted) return true;
      // 取代而非 push：返回鍵會回列表，不會掉回剛清掉的舊對話。
      Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(builder: (_) => ChatPage(session: created)));
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(
          content: LocalizedText(
            UiMessage.local(
              MessageKey.commandsM001,
              args: {'error': messageForError(e)},
            ),
          ),
        ),
      );
    }
    return true;
  }

  Future<bool> showStatus(
    BuildContext context,
    WidgetRef ref,
    ChatController chat,
    _,
  ) async {
    // 快照優先：先抓本輪身份再 await，頁面 dispose／切 session 後不誤貼。
    // Only RAW data is snapshotted here; all app wording stays as catalog
    // keys resolved INSIDE the dialog/snackbar (§4.5), so an open /status
    // follows a language switch.
    final sid = chat.sid;
    final runId = chat.activeRunId;
    var runStatusToken = ''; // raw server status token
    var runLineFailed = false, runLineFinished = false;
    if (runId != null) {
      try {
        final status = await ref.read(repositoryProvider).runStatus(runId);
        runStatusToken = (status['status'] as String?) ?? '';
      } on ApiException catch (e) {
        // 404 = gateway 已遺忘這個 run：顯示「已結束」；既有核對流程照跑，
        // status 查詢本身不改 phase／pending。
        if (e.status == 404) {
          runLineFinished = true;
        } else {
          runLineFailed = true;
        }
      } catch (_) {
        runLineFailed = true;
      }
    }
    if (!context.mounted) return true;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final errorDescriptor = chat.error; // UiMessage? — stays a descriptor
    final remoteRuns = chat.remoteActiveRuns;
    final lastActivity = chat.lastActivitySuccess;
    final freshness = chat.activityFreshness;
    final overflow = chat.observedActivity?.overflow ?? false;
    final messageCount = chat.messages.length;
    final reconnects = chat.reconnects;
    final viewers = ChatViewers.count(chat.sid);

    MessageKey phaseKey(
      ChatPhase p,
      bool d,
    ) => switch ((p, d)) {
      (ChatPhase.idle, _) => MessageKey.commandsM006,
      (ChatPhase.sending, _) => MessageKey.commandsM007,
      (ChatPhase.recovering, true) => MessageKey.commandsM008,
      (ChatPhase.recovering, false) => MessageKey.commandsM009,
      (ChatPhase.uncertain, _) => MessageKey.commandsM010,
    };

    UiMessage runLine() {
      if (runId == null) return const UiMessage.local(MessageKey.commandsM002);
      if (runLineFinished) {
        return UiMessage.local(
          MessageKey.commandsM004,
          args: {'runId': runId},
        );
      }
      if (runLineFailed) {
        return UiMessage.local(
          MessageKey.commandsM005,
          args: {'runId': runId},
        );
      }
      return runStatusToken.isEmpty
          ? UiMessage.local(
              MessageKey.chatStateRunLabel,
              args: {
                'who': UiMessage.raw('run $runId'),
                'what': const UiMessage.local(MessageKey.commandsM003),
              },
            )
          : UiMessage.local(
              MessageKey.chatStateRunLabel,
              args: {
                'who': UiMessage.raw('run $runId'),
                'what': UiMessage.raw(runStatusToken),
              },
            );
    }

    String activityText(AppStrings strings) =>
        switch (freshness) {
          ActivityFreshness.unknown => strings.resolve(MessageKey.commandsM011),
          ActivityFreshness.unsupported => strings.resolve(
            MessageKey.commandsM012,
          ),
          ActivityFreshness.stale => strings.resolve(
            // Fixed local HH:mm in both locales (I18N-PLAN §7).
            MessageKey.commandsActivityStale,
            args: {
              'time': lastActivity == null
                  ? strings.resolve(MessageKey.commonNoneParenthesized)
                  : formatLocalClock(lastActivity),
            },
          ),
          ActivityFreshness.fresh => remoteRuns.isEmpty
              ? strings.resolve(MessageKey.commandsM015)
              : strings.resolve(
                  MessageKey.commandsM016,
                  args: {
                    'lines': remoteRuns
                        .map(
                          (r) => ChatController.formatRemoteRunLabel(strings, r),
                        )
                        .join('\n'),
                  },
                ),
        };

    if (chat.busy || chat.remoteBusy || chat.activityBlocksSend) {
      // 忙碌（本機或遠端）時不打斷畫面：簡版 SnackBar（長版留給空閒結果卡）。
      // 遠端回合只觀察：這裡絕不對它 stop/steer。
      messenger?.showSnackBar(
        SnackBar(
          // Builder resolves through Localizations, so a visible SnackBar
          // re-renders when the language changes under it (§4.5).
          content: Builder(
            builder: (context) {
              final strings = AppStrings.of(context);
              final suffix = (chat.remoteBusy && remoteRuns.isNotEmpty)
                  ? strings.resolve(
                      MessageKey.commandsM018,
                      args: {
                        'line': ChatController.formatRemoteRunLabel(
                          strings,
                          remoteRuns.first,
                        ),
                      },
                    )
                  : chat.activityBlocksSend
                  ? strings.resolve(MessageKey.commandsM019)
                  : '';
              return Text(
                strings.resolve(
                  MessageKey.commandsM017,
                  count: messageCount,
                  args: {
                    'phase': strings.resolve(
                      phaseKey(chat.phase, chat.detached),
                    ),
                    'runId': runId ?? strings.resolve(MessageKey.commonUnknown),
                    'count': messageCount,
                  },
                ) +
                suffix,
              );
            },
          ),
        ),
      );
      return true;
    }
    await showDialog<void>(
      context: context,
      builder: (context) {
        final strings = AppStrings.of(context);
        return AlertDialog(
          title: const Text('/status'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                strings.resolve(
                  MessageKey.commandsM020,
                  args: {'sid': sid},
                ),
              ),
              Text(
                strings.resolve(
                  MessageKey.commandsM021,
                  args: {
                    'phase': UiMessage.local(
                      phaseKey(chat.phase, chat.detached),
                    ),
                  },
                ),
              ),
              Text(strings.render(runLine())),
              Text(
                strings.resolve(
                  MessageKey.commandsM022,
                  args: {'count': messageCount},
                ),
              ),
              Text(
                strings.resolve(
                  MessageKey.commandsM023,
                  args: {'count': viewers},
                  count: viewers,
                ),
              ),
              Text(activityText(strings)),
              if (overflow)
                Text(strings.resolve(MessageKey.commandsM024)),
              Text(
                strings.resolve(
                  MessageKey.commandsM025,
                  args: {
                    'error':
                        errorDescriptor ??
                        const UiMessage.local(MessageKey.commonNone),
                  },
                ),
              ),
              Text(
                strings.resolve(
                  MessageKey.commandsM026,
                  args: {'count': reconnects},
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                chat.refreshActivity();
              },
              child: Text(strings.resolve(MessageKey.commandsM027)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(strings.resolve(MessageKey.commonClose)),
            ),
          ],
        );
      },
    );
    return true;
  }

  return [
    ClientCommand(
      'reset',
      MessageKey.commandsM028,
      worksWhileBusy: true,
      run: startFresh,
    ),
    ClientCommand(
      'new',
      MessageKey.commandsM029,
      worksWhileBusy: true,
      run: startFresh,
    ),
    ClientCommand(
      'status',
      MessageKey.commandsM030,
      worksWhileBusy: true,
      run: showStatus,
    ),
  ];
});
