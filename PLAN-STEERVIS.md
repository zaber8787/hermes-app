# PLAN-STEERVIS

## 溯源與判定

A 成立於未經 API 的背景工作；B 不是橫幅消失的原因。這是觀測範圍限制，不能直接推論使用者當時的特定 session。

- `compat/compat.py:1303–1324` session chat/stream 登記；`:1390` runs launch、`:1497–1549` status 與 /v1/runs executor 登記。會進 active_runs：session SSE、/v1/runs（含 live-owner 分支，:1633）、同步 session chat（:1551–1627，只有 observation_id，無法 run-bound steer）。
- `compat/compat.py:1753` 明示 coverage=api_process；`:1365–1376` coverage 只掃 adapter 的 active tasks/agents，不是整個 gateway 或所有子行程。
- 本機 `/Users/zaber/.hermes/hermes-agent/cron/scheduler.py:1977` 直接 agent.run_conversation，`:2578` 建立 cron agent；不經上述 API 登記。
- 同 repo `hermes_cli/kanban_db_dispatch.py:2741,2829,2949` 派工啟動 CLI 子行程，不經 API 登記。其他 worker/pipeline 是否可見取決於實際啟動路徑；不能以「背景」一概判斷。
- App auto-wake：`compat/compat.py:2598–2687` 唯一 dispatch 門是 chat/stream；server self-wake：`compat/self_wake.py:1150` 亦呼叫 chat/stream。因此這兩種續跑有既有登記，不能歸入缺口。外部 CLI 續跑若繞過 API 則沒有。
- `app/lib/features/chat/chat_controller.dart:604–607` remoteBusy 只看 snapshot activeRuns；`chat_page.dart:1691–1726` 有 run 就畫列與 capability gated 插話。freshness 不隱藏橫幅，僅限制送出（controller :615 起、remote_steer.dart:112）。

## 現場 evidence

讀取 `~/.hermes/logs/agent.log`：2026-10-20 14:28:08 的 worker-done-watch，session `cron_5a9a2d6576d6_20261020_142808`，thread=cron-parallel_1，14:28:28 完成。這證明有直接 cron agent 工作；未取得同一時刻的 activity HTTP snapshot，不能宣稱已現場重現「空 active_runs」。不輸出憑證或完整對話。

## 既有訊號與修法

Session 模型只有 source / last_active / message_count，無可依賴的 live status（`app/lib/models/session.dart:35–57`）；server session list `gateway/platforms/api_server.py:2998` 的 last_active 是排序資料。近期訊息不證明仍在工作。notification-events 是 terminal / approval / steer-ready 通知（`compat/notification_events.py:294–325`），不是完整 started/heartbeat/ended 日誌，且受 owner、watch 與保存範圍限制。不能用最新歷史 run id 或時間猜插話對象；既有 steer 是 run-bound，沒有 session-level admission。

App 改善：空的遠端觀測時提供可見「插話與執行狀態」說明與重新確認按鈕；明示背景工作可能未回報，並說明有可用目標才顯示插話。已有 run 時把泡泡 icon 改成有「插話」文字的按鈕，保留所有 identity/freshness gates。沒有可靠資料前不加虛假的執行中角標。若 server 日後提供可信 live status，session 列表可加執行中角標，點入既有 ChatPage 即見橫幅。

## Server asks

1. 提供跨行程的 session activity registry：cron、CLI worker、外部續跑的 start/heartbeat/terminal、owner scope、穩定 run identity、compression session alias、失聯過期語意與 coverage，不能把空 api_process 當全域 idle。
2. 讓背景 run 登記 steer inbox 與真正的消費邊界，回傳明確 capability；若提供 session-level steer，須定義原子選擇目標、同時多 run、重試冪等、epoch、授權，不能由 client 猜最新 id。
3. Session list 若要角標，補明確 live status 與 freshness/coverage；notification ledger 若要推導狀態，補可重播完整生命週期與失聯/重啟處理。

## 驗證

新增空觀測提示 widget 測試（窄螢幕、重新確認），並跑既有 cross-device steer、activity/觀測相關測試與 analyze。只改 app 原始碼及本任務文件；不改 Python、不 commit。
