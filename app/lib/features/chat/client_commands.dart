import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/hermes_repository.dart';
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
    this.description, {
    this.worksWhileBusy = false,
    required this.run,
  });

  final String name;
  final String description;

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
      messenger?.showSnackBar(SnackBar(content: Text('開新對話失敗：$e')));
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
    final sid = chat.sid;
    final runId = chat.activeRunId;
    var runLine = '目前沒有執行中的 run';
    if (runId != null) {
      try {
        final status = await ref.read(repositoryProvider).runStatus(runId);
        runLine = 'run $runId：${(status['status'] as String?) ?? '狀態不明'}';
      } on ApiException catch (e) {
        // 404 = gateway 已遺忘這個 run：顯示「已結束」；既有核對流程照跑，
        // status 查詢本身不改 phase／pending。
        runLine = e.status == 404
            ? 'run $runId：已結束'
            : 'run $runId：狀態查詢失敗';
      } catch (_) {
        runLine = 'run $runId：狀態查詢失敗';
      }
    }
    if (!context.mounted) return true;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final phaseLabel = switch ((chat.phase, chat.detached)) {
      (ChatPhase.idle, _) => '空閒',
      (ChatPhase.sending, _) => '執行中',
      (ChatPhase.recovering, true) => '觀察中（背景輪詢）',
      (ChatPhase.recovering, false) => '觀察中',
      (ChatPhase.uncertain, _) => '待確認',
    };
    // WAVE4：本地 phase 之外，快照證明「其他裝置也在這個 session 跑」。
    final remoteLines = [for (final r in chat.remoteActiveRuns) chat.remoteRunLabel(r)];
    final activityText = switch (chat.activityFreshness) {
      ActivityFreshness.unknown => '即時觀察：尚未取得快照',
      ActivityFreshness.unsupported => '即時觀察：此伺服器不支援即時快照',
      ActivityFreshness.stale =>
        '即時觀察：擷取失敗，最後成功 '
        '${chat.lastActivitySuccess == null ? '（無）' : TimeOfDay.fromDateTime(chat.lastActivitySuccess!).format(context)}；可能還有未顯示的回合',
      ActivityFreshness.fresh => remoteLines.isEmpty
          ? '即時觀察：無其他進行中回合'
          : '其他裝置進行中：\n${remoteLines.join('\n')}',
    };
    final summary =
        '狀態：$phaseLabel｜run：${runId ?? '未知'}｜訊息 ${chat.messages.length} 則'
        '${chat.remoteBusy ? '｜其他裝置進行中（${remoteLines.first}）' : chat.activityBlocksSend ? '｜狀態確認中，暫停送出' : ''}';
    if (chat.busy || chat.remoteBusy || chat.activityBlocksSend) {
      // 忙碌（本機或遠端）時不打斷畫面：簡版 SnackBar（長版留給空閒結果卡）。
      // 遠端回合只觀察：這裡絕不對它 stop/steer。
      messenger?.showSnackBar(SnackBar(content: Text(summary)));
      return true;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('/status'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('工作階段：$sid'),
            Text('狀態：$phaseLabel'),
            Text(runLine),
            Text('訊息數：本地已載入 ${chat.messages.length} 則'),
            Text('本頁觀察者：${ChatViewers.count(chat.sid)} 個'),
            Text(activityText),
            if (chat.observedActivity?.overflow ?? false)
              const Text('（進行中回合過多，快照僅顯示部分）'),
            Text('錯誤：${chat.error ?? '無'}'),
            Text('重新連線次數：${chat.reconnects}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              chat.refreshActivity();
            },
            child: const Text('立即重新核對'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('關閉'),
          ),
        ],
      ),
    );
    return true;
  }

  return [
    ClientCommand('reset', '清空脈絡，開一個全新對話',
        worksWhileBusy: true, run: startFresh),
    ClientCommand('new', '同 /reset：開一個全新對話',
        worksWhileBusy: true, run: startFresh),
    ClientCommand('status', '顯示工作階段與執行中回合狀態',
        worksWhileBusy: true, run: showStatus),
  ];
});
