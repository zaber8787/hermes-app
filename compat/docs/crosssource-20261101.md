# 跨來源通道：app 對 Discord session 發訊息（TASK-CROSSSOURCE）

日期 2026-11-01。core 為 `~/.hermes/hermes-agent`，全程唯讀。

## 問題

app 的 `POST /api/sessions/{id}/chat[/stream]` 最後都走 API admission。`gateway/session_api_turn.py:215` 在 target session 的 `source` 不是 `api_server` 或 `bot_room` 時直接丟 `permission_denied`，所以 Discord thread session（例如 `20260910_151843_94d2209a`，`source=discord`、`session_key=agent:main:discord:thread:1547506583351853116:1547506583351853116`）從 app 發言一定失敗。這是 core 的設計，不能改白名單也不能繞 admission。

## 兩條路的利弊

A. 來源代表發送（compat 以 kanade bot 的 token 把訊息 POST 到 thread，讓 Discord inbound 觸發 turn）

- 利：訊息真的出現在 Discord thread 裡，Discord 那端的人看得到 app 說了什麼。
- 利：core 端完全視為一般 Discord 訊息，不需要任何 plugin 權限設定。
- 弊：已證實不會觸發 turn。`plugins/platforms/discord/adapter.py:1679` 的 `_discord_message_admission` 對 `message.author == self._client.user` 直接回 `(False, False)`，bot 自己發的訊息一律丟棄，`DISCORD_ALLOW_BOTS`（`adapter.py:5072`）只管別的 bot，救不了自己。要繞開就得換 webhook 或第二顆 bot，作者身分會變成非授權使用者，又撞上 allowlist。
- 弊：compat 要自己持有並使用 bot token、自己打 Discord REST，等於多一條 token 外洩與 rate limit 的面，且 token 失效時 compat 與 adapter 會各自失敗、各自回報。
- 弊：訊息是以 bot 身分進 transcript，agent 看到的作者是自己，語義錯位；還要另外處理 Discord 2000 字上限與附件。

B. core 正式跨面接口：`PluginContext.inject_message(content, session_key=...)`

- 利：這是 core 公開給 plugin 的 messaging bridge 接口。`hermes_cli/plugins.py:596` 定義，`website/docs/user-guide/features/plugins.md:1086` 明寫用途包含 messaging bridges，閘門在 `hermes_cli/plugins.py:640`（`plugins.entries.<id>.allow_gateway_injection`）。
- 利：路由走 session 自己的 Discord adapter。`gateway/run_plugin_injection.py:188` 以 `session_key` 找回原 source，`:208` 取該 source 的 delivery adapter，`:363`/`:385` 在 session authority 下以 `admit_automation` 進 durable FIFO，執行完的回覆走 adapter 正常 send 回原 thread。
- 利：不碰 token、不打 Discord API，所有授權由 core 現行檢查負責（`run_plugin_injection.py:125` 的 `_plugin_injection_authorized`、profile 擁有權檢查）。
- 弊：使用者在 app 打的那句話不會以一則 Discord 訊息出現在 thread，只有 agent 的回覆會出現；transcript 中這一列以 `internal_notification` 存（`gateway/response_filters.py:125`），app 上顯示為系統事件而非使用者泡泡。
- 弊：`inject_message` 回 `True` 只代表 host 接受排程，dispatch 階段若被拒（例如授權不過）只寫 gateway log，plugin 端看不到。需要 operator 在 config 開 `allow_gateway_injection`，預設是關的。

選 B。A 的致命傷是已證實觸發不了 turn，而 B 是 core 文件化的正式接口，紅線（不 monkeypatch core、不改白名單、不直寫 SQL）全部守得住。B 的「訊息本體不在 thread 中」以內容尾註 `[經 Hermes App 代發]` 補標示，讓 agent 與 transcript 分得出這句從哪邊來。

## 實作

`compat/crosssource.py`，由 `compat/compat.py` 的 `_install_crosssource` 掛上，排在 `UNITS` 最後，所以它包住 approval／wake 已經包好的兩個 chat handler。

- 路由（`crosssource.py:152` 起）：先跑 `_check_auth`，再讀 session。`source` 在 `PLATFORMS={"discord"}` 且有 `session_key` 才走通道；api_server session、不存在的 session、帶 `wake_batch` 的請求全部原樣交回原 handler。非文字輸入回 415 `crosssource_text_only`。
- 傳送：每則訊息先寫進 `$HERMES_HOME/crosssource_spool.db` 的 `outbox`（status `pending`），然後最多 3 次嘗試（`MAX_ATTEMPTS`，間隔 0.5s、1.5s）。一次嘗試的失敗原因分四種：`plugin_context_missing`、`platform_disconnected`（Discord adapter 不在或 `is_connected` 為假，bot token 失效與 Discord API 斷線都落在這裡）、`inject_error`（host 丟例外）、`inject_refused`（host 回 False，含 `allow_gateway_injection` 未開）。
- 成功：stream 路由回 SSE `run.started`、`run.queued{status:"queued", delivery_id, via:"discord"}`、`done`，這是 app 既有的 live-owner handoff 形狀（`app/lib/features/chat/live_turn.dart:91`），app 會把 EOF 當作刻意結束並做唯讀 reconcile。sync 路由回 202 `hermes.session.chat.queued`。outbox 列標 `accepted`。
- 最終失敗：HTTP 502，body 帶 `kind:"bridge_unavailable"`、`error.code:"bridge_unavailable"`、`reason`、`delivery_id`。outbox 列標 `failed` 並保留全文與 `session_key`，訊息不丟。
- app 端：`HermesRepository._open` 只在 502 且 body `kind == bridge_unavailable` 時丟 `ApiException.local(apiM029, kind: bridge_unavailable)`，其餘 502 照舊是 `apiM007`。`ChatController` 把這個 kind 當作和 4xx 同一種「伺服器拒收」：不進 recovery、輸入保留，畫面錯誤為「訊息未送出：Discord 通道暫時無法使用，訊息已保留在伺服器但尚未送達。」

## 部署前提（operator 動作，本任務未執行）

1. `compat/scripts/sync-deploy.sh` 同步（或 install.sh，已加入 `crosssource.py`）。
2. `~/.hermes/config.yaml` 加上下列設定。沒有它，`hermes_cli/plugins_injection.py:36-40` 會讓每次嘗試都 `inject_refused`，app 收到的是 502 `bridge_unavailable`，訊息留在 outbox。

   ```yaml
   plugins:
     entries:
       hermes-app-compat:
         allow_gateway_injection: true
   ```

   entry 名稱取自 `PluginContext.plugin_id`（`hermes_cli/plugins.py:245`，`manifest_key(manifest)`），以 manifest `name: hermes-app-compat` 推論為 `hermes-app-compat`，尚未在 live gateway 實測。
3. gateway 冷重啟由主 Agent 安排。

## 已證實、推論、待測

已證實（tmp SessionDB + fake gateway，見 `tests/test_crosssource.py`）：Discord session 走 injection、api_server session 與 wake 保持原生、未授權請求不碰 outbox、三次失敗回 502 並保留全文、adapter 斷線不呼叫 injection、重試中途恢復即送達、outbox 跨 instance 留存、unit 能掛上真的 `APIServerAdapter` 並由 Transaction 還原、core 的 `permission_denied` 守門仍在。

推論：Discord 回覆會出現在原 thread。依據是 `run_plugin_injection.py:208` 取原 source 的 delivery adapter 與 `session_automation.py:365-388` 借用該 thread 已提交的人類訊息 provenance，但尚未在 live gateway 上實測。

待測：

- dispatch 階段的授權。`_plugin_injection_authorized` 以 `allow_adapter_delegation=False` 檢查，Discord 角色授權不算數；若 zaber 的 Discord 帳號只靠 role 授權，turn 會在 dispatch 被丟棄而 app 已收到 queued。這要在 live gateway 看 log `Plugin message injection denied` 確認。
- `run.queued` 之後 app 的唯讀 reconcile 只讀一次，Discord 回覆較慢時要靠既有的 activity／輪詢才會出現在 app 畫面。
- `is_connected` 在 discord.py 自動重連期間是否仍為真，未實測，所以「Discord API 掛」可能有一段時間被判為可送，訊息此時會進 FIFO 等 adapter 恢復。
- 若 thread 的 `session_key` 已輪替到新 session（`/new`），訊息會進新 session，app 正在看的舊 session 不會出現回覆。

## TASK-CROSSSOURCE2：投遞改走 Discord REST（2026-11-01）

上線後 app 三連發全部 `inject_refused`，spool 留下 4 列 `failed`（同一段 `test from app` 文字，05:33:56、05:34:01、05:34:06、05:35:13）。`~/.hermes/config.yaml` 沒有 `allow_gateway_injection`，而 `hermes_cli/plugins.py:640` 只在該值為 `True` 時放行，所以推論 refused 的直接原因是這個開關未開，尚未在 live gateway 以 log 證實。不論原因，投遞已不再依賴 inject。

投遞段改為 Discord REST 直發 `POST /api/v10/channels/{thread_id}/messages`。thread_id 取自 `session_key` 尾段（`agent:<profile>:discord:thread:<channel>:<thread>`，其他形狀記 `session_key_unparsed`）。token 照 discord plugin 的讀法（`plugins/platforms/discord/adapter.py:7123-7127`）：先取 live Discord adapter 的 `config.token`，再取 runner 的 `PlatformConfig.token`，最後 `get_secret("DISCORD_BOT_TOKEN")`，沒有新增配置項。client 用 aiohttp，因為 compat（`self_wake.py`）與 discord plugin 的 standalone send 都是 aiohttp；proxy 也照 plugin 的 `resolve_proxy_url(platform_env_var="DISCORD_PROXY")`。成功條件是 HTTP 2xx 且回應帶 message id，log 記一行 message id，token 不進 log。payload 帶 `allowed_mentions: {parse: []}`，app 打的 `@everyone` 不會真的 ping。

送達後照舊呼叫一次 `inject_message` 嘗試觸發 turn，因為 bot 自己的訊息會被 adapter self-skip（`adapter.py:1679`），只靠 REST 不會有回覆。觸發結果寫進 spool 的 `trigger` 欄（`injected`、`inject_refused`、`inject_error`、`plugin_context_missing`），失敗只降級成 warning，不算投遞失敗也不重試。

spool 新增 `message_id`、`trigger` 兩欄，舊檔開啟時以 `ALTER TABLE` 補上。狀態改為 `pending`、`delivered`、`failed`、`merged`。去重規則：同 session 同文字時，24 小時內有未送達列就併進最舊的那列並重送（retry 鈕因此救得回 failed 列），否則 60 秒內已送達的列直接回成功不重發；同一列同時只有一個投遞在跑。drain 撈 24 小時內的 `pending` 與 `failed`，同 session 同文字的列先收斂到最舊一列（其餘標 `merged`），再各給一輪 3 次嘗試。每次 plugin 載入後 drain 一次：冷啟動由 api_server 的 route sync factory 觸發，熱重載由 live adapter 掃描觸發，延遲 10 秒讓平台先連上。超過 2000 字（含尾註）的訊息在進 spool 前回 413 `crosssource_too_long`。

待測：live gateway 上的 REST 實發與 drain 實際觸發點未實測；`allow_gateway_injection` 開啟前，訊息會出現在 thread，但 agent 不會回覆。
