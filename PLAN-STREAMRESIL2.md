# PLAN-STREAMRESIL2

以 TASK/TASK-STREAMRESIL2.md 的修正版裁定為準；不使用舊任務的 SSE 接回方案。

## 觸發與排程

Web 選 N=1，首次串流建立失敗、無事件 EOF 或中途非終態 EOF/error 就降級。
理由：POST 可能已被伺服端接受；沒有可安全重試的訂閱端點，不能為湊連敗次數重送
POST。沒有 POST 重試或退避；改為立即唯讀查詢，之後沿用 watchInterval（預設 5 秒）
定期查詢。明確 4xx 與 neverDispatched 仍保留原本的拒絕／未送出語義。

## GET 與合併

沿用 _watchTimer / _pollRun 單一 run 輪詢 owner，每 5 秒 GET /v1/runs/{run_id}。
降級且頁面未 detach 時，同一輪也進既有 single-flight _activityTick：
GET /api/sessions/{sid}/activity，revision 有變才由 _latest 讀取 messages GET。
可見頁面原有 activity 6 秒 timer 繼續存在，同時觸發時共用同一 flight；降級 watch
讓 hidden 分頁也能觀察 activity（Chrome 可延遲計時，5 秒是目標而非時間保證）。
messages 沿用既有最新頁讀取、revision bookkeeping、mergeMessages、既有 timeline
與 livemerge fold；不改 offset/include_compacted 或增設訊息狀態機。

沒有 run.started 的零事件失敗，沿用 _pollRun 的無 runId 歷史核對與持久 recovery
budget；不猜 runId、不重送。HTTP 失敗與不確定狀態保留 M0xx 核對／重試規則。

## UI 與前景恢復

輕量 secondary 文字：「串流暫時中斷，已改用定期更新；訊息不會重送。」
由 locale key 渲染，不寫入 durable message、draft 或 POST。
Flutter web 的 visibilitychange 由既有 WidgetsBinding lifecycle hidden/resumed
轉達；resumed 走 reconcileForeground → _pollRun(fresh: true)。仍在執行則保留原
timer；終態走 _convergeKnownTerminal → _settleTurn → messages GET 合併。
清除 timer、提示與 live owner。已 running 的 run 絕不再呼叫 chat/stream POST；
下個新回合依原本 send 流程建立。

## 既有系統交互

- detach/attach：不把降級偽裝為離頁；真正 detach 仍停止 activity 並沿用原 run
  status timer，attach 恢復 activity、立即查狀態，降級旗標保留到 settle。
- StreamKeepalive：降級釋放既有 lease；不新增 lease 或 MethodChannel 行為。
- auto_wake：同一 run 共用這條降級路徑，不重 POST、不重取 ledger batch；busy、
  sendBlocked、dispatch claim 與 settle/ack 語義不變。
- M0xx contract：原來 rejection、neverDispatched、未知 run 的 budget、404、連續
  GET 失敗上限與人工核對保留；Web 已知終態沿用現成 known-terminal 收尾。
- 本機：新路徑由 kIsWeb 預設 gate；測試可注入平台開關，本機預設沿用原 recovery。
- dispose／settle：原 timer teardown 不變；settle 同時清除降級提示。

## Server asks

compat session chat/stream 建立的 run 沒登記 _run_streams，所以
GET /v1/runs/{run_id}/events 對這些 run 回 404。本任務不依賴它。
未來如需同回合恢復 SSE，伺服端須提供安全的唯讀訂閱／重播通道。
write failed 不應中止 agent；現有 drain 行為須維持。是否改善背景分頁 SSE 初始
寫入判斷，屬伺服端後續議題。
