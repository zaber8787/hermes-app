# NTFY-PORT 實作判定與偏離記錄

日期：2026-09-27。規格：`TASK/NTFY-PORT-PLAN.md`（掛點對照表）＋ `TASK/TASK-NTFY-PORT-IMPL.md`。
後者明定新 unit 名為 **push**（計畫原文用 ntfy；以 task 定案為準，見偏離 1）。

## 判定（計畫 §2 逐掛點，實作時複核）

| 舊掛點 | 判定 | 實作歸屬 |
|---|---|---|
| socket reset/abort/broken pipe/OSError 不 drain、背景 turn 繼續 | 真缺 → 已實作 | push：`_drain_session_stream_task_on_disconnect` wrapper 辨識「SSE client disconnected」+`shield_wait=False`（即 socket 分支），標記 detached 且跳過 drain；`_track_background_task` 繼續持有 `_run_and_signal` |
| SSE timeout 寫 `: keepalive` 偵測 dead socket | 已覆蓋 heartbeat | 未改動；它是 detach 的觸發寫入點之一 |
| `viewer={gone}` per-run flag | 真缺 → 已實作 | push：`(id(adapter), run_id)` registry state（含 session_id、settings 快照、pending/terminal/dedup/discard）；非全域布林、不只鍵 session_id |
| approval 推播 | 橋已覆蓋（native callback），ntfy 缺 | push 只在 native `_set_run_status(waiting_for_approval, approval=…)` 旁開 side-channel；未再 register 任何同 key callback（計畫 §2 紅線） |
| reply ready 推播 | 缺 → 已實作 | 同一 `_set_run_status` 入口；terminal outcome 由 `terminal_run_status` 語意決定，正常 return 未必 completed |
| run failed 推播 | 缺 → 已實作 | exception 型用現有 `_redact_api_error_text`（`error` field）；結果型用 `turn_exit_reason`；同 run 只推一個 terminal |
| 取消路徑 drain/interrupt | 保留 | CancelledError（shield_wait=True）、explicit stop、shutdown interrupt 全走原生；只有 socket 分支改 detach |
| MEDIA resolver | 已覆蓋（history unit） | 未觸碰 |
| Live Bot Chat handoff | 本機掛點無法覆蓋 | 明列 unsupported；該路徑不登記 state、不產生假推播（offline case 以 ctxvar 隔離驗證） |

config：`load_user_config_effective` 不刪未知 root key，`push:` 讀得到；profile scope 內
（request task）於 `_register_session_stream_approval` 包裝處 snapshot，loader 失敗時降級
raw-read 僅取 `push` 鍵（`get_config_path()`，profile-aware，未硬編碼 `~/.hermes`）。
設定缺失 → 不登記 state → 斷線維持原 drain 行為（已測）。

ntfy adapter 同 topic 衝突：publisher 一律帶 `hermes-agent` echo tag；offline case 把 hub
實際收到的 POST 餵真 `NtfyAdapter._on_message`，不 dispatch 新 prompt（並有無 tag 對照組）。

## CancelledError 調查（計畫 §3 要求測出並記錄）

離線實測：本部署 aiohttp session SSE 的純客戶端離線在**下一次寫入**（事件或 keepalive）時以
`ConnectionResetError/BrokenPipeError/OSError` 進入 socket 分支；`CancelledError` 只出現在
task cancel/shutdown 路徑。因此 push 的 detach 判定綁「interrupt_message == 'SSE client
disconnected' 且非 shield_wait」即覆蓋全部純離線情形，CancelledError 維持原生 drain，
不把任何 cancellation 誤解為 viewer gone。

## 偏離清單（計畫 → 實作）

1. **unit 名**：`ntfy`/`_install_ntfy` → **`push`/`_install_push`**（task 定案）。
2. **state 建立點**：計畫寫在 `_session_stream_target` 內聯（run_id/events 後、task 前）。
   實作改掛在 `_register_session_stream_approval` 的 class-level wrapper——時序等價
   （owner+queued 已存在、`_run_and_signal` 尚未建立），但綁定走 class attr，
   **hot reload 即全面生效**（aiohttp router 在 connect() 綁定 handler，改 copy 內聯碼
   需 cold restart 才生效，而本任務禁止重啟 gateway）。舊 module 綁定的 copy 之後所有
   `self.` 呼叫都經新 class 綁定，故 push 全功能不依賴重啟。
3. **detach 判定點**：同理改在 drain wrapper 內辨認 socket 分支（含 keepalive 寫入失敗與
   `_prepare_sse_response` 階段的 socket 失敗——後者以 `_prepare_sse_response` wrapper 捕捉
   OSError，補上計畫 §3 明列的「task 已啟動、prepare 失敗會漏標 viewer-gone」race）。
4. **delivery acknowledgement**：以 `_prepare_sse_response` 回傳 response 的 `write` 觀察器
   記錄 `run.completed`/`run.failed` 幀「成功寫出」；僅限 ctxvar 對號的 session stream，
   OpenAI streams / live Bot Chat 不受影響。terminal 已交付後斷線不補推；未交付即斷線補推
   一次；approval 則以「仍未解決」為條件（resolution 經 `approval.responded` 狀態清除 pending）。
5. **測試位置**：repo 現況無 `compat/tests/`；push case family 依計畫 §6 放入
   `tools/compat_probe_cases/push.py`（fake hub 為 in-process loopback aiohttp），
   offline gate 由 7 組改 8 組。task 文中「compat/tests」按源碼現況解讀。
6. **approval 去重錨**：核對 `_approval_request_event` 後確認 approval.request 事件恆含
   `request_id`（native 路徑），以其為 dedup key；缺值時降級 per-run 單調 generation。
7. **publish 機制**：reference 版每推播起一條 daemon thread、`_CACHE` 永久快取；改為單一出
   worker 執行緒＋有界佇列（128，溢出丟棄記 debug），settings 為 per-run snapshot，
   不保留 module-global 快取（計畫 §4 明令捨棄）。HTTP 語意保留：ASCII Title、UTF-8 body、
   Priority 3/4/5、5 秒 timeout、無 retry；body 以 UTF-8 **bytes** 有界截斷（≤1900）。
   失敗僅記 exception 型別，不輸含 topic 的 URL。
8. **base backend**：`_install_push` 開頭 fail closed（`skipped_incompatible`），與計畫 §3.4 一致。
9. **unload/清理**：registry 存於共享 compat state（跨 manager、跨熱重載同一物件）；
   最後 owner 釋放時關閉推播、清空並 cancel discard consumers。terminal state 有界保留
   （900s TTL／64 entries，超額逐出最舊），不在第一次 terminal status 即刪除。

## 覆蓋範圍聲明

僅本機 session-SSE turn。`/v1/runs` streams、OpenAI streams、cron、其他平台 turn 與
Live Bot Chat handoff 不在本 unit 範圍；SSE server 無法直接知道手機是否進背景——代理仍在
讀流時保持 attached、零推播（真機驗收需涵蓋此偵測延遲）。
