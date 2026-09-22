# Changelog

技術變更紀錄。本檔為公開版本：真機交付與個人部署證據保留在本機
`CHANGELOG-PRIVATE.md`（不入版本庫）。`<SERVER_ORIGIN>` 代表部署者自設的
伺服器位址。

## 2026-09-22 — 進行中不再出現第二條自己的訊息

- 修正回合進行中偶爾重複顯示自己訊息的問題：歷史已有該訊息時，待送與觀察預覽會即時退場；已確認的觀察預覽不會在下一次更新重新出現。保留其他裝置發言的即時顯示，不改變訊息內容或重新送出請求。

## 2026-09-22 — 重載後不再卡在「發言中」：有界的回合復原核對

- 重新整理或重開 App 後，若上一回合早已結束但歷史沒有最終回覆（例如審閱預算用盡、工具列結尾），App 現在會在最多 60 秒的核對期後自行收尾：保留現有結果、顯示「該回合未正常收尾」，並立刻解除輸入限制；不再無限顯示「發言中」。
- 核對期改用「寫進本機等待紀錄」的預算：重新整理不會延長等待；「重新核對」全回合只有一次（30 秒），重複點按、另一分頁、重開都無法再多要一次；随时可選「清除本機等待紀錄」提早回待機——這不是停止伺服器任務，也不會重送訊息，草稿與附件不受影響。
- 伺服器仍回報執行中的回合絕不會被時間到判死；Discord 等跨平台重排過的訊息現在能用同样的摺疊比對正確歸位。本機儲存無法寫入時會明確告知，不會假裝仍在追蹤。

## 2026-09-22 — 雙語介面（English / 繁體中文）與語言切換

- 新增应用内语言选择：设定页可选 English 或繁體中文，立即生效且重开保留；默认固定英文，不再跟随系统语言显示中文。切换不重启引擎、不清草稿、不断流、不重放任何请求。
- 全 app 文字（聊天、附件、审批、通知、错误、日期标签、管理页、平台选单）经单一目录双轨呈现；服务器回传文字与协议字串原样保留。Android 前台通知的频道名与标题随语言就地更新（同 ID、不重置权限）。
- 验收：analyze 0；全量逐檔绿（含新增 i18n 契约测试与通知派发测试）；残留扫描工具 `tools/i18n_scan.py` 除目录外零中文常量。

## 2026-09-21 — v0.13.17+37 幽靈列根治（跨平台觀察宣示）

- 根因修復：其他平台（Discord 等）起 run 時，歷史落盤文字與即時觀察預覽存在換行／附件標註等格式差異，舊版逐字比對認親永遠失敗，時間軸下方永久殘留數輪前的「⋯（尚未於歷史確認）」幽靈列。宣示邏輯改為三層：精確比對 → 摺疊比對（並空白字元、去附件標註，僅比對不改渲染）→ 歷史優先的位置宣示（觀察點之後出現更新的落盤使用者列即證明該回合已持久化）；terminal 列找不到視窗內對應者直接退場，不再掛註記。
- 驗收：`audit_cross_device_sync_test` 11/11（新增 2 回歸案例，在舊宣示邏輯下紅）；flutter 逐檔全綠、analyze 0。修 `scripts/build_app.py` profile 切換清理的 tuple 語法 bug。

## 2026-09-21 — v0.13.16+36 WAVE4：即時跨裝置同步（sessionActivity）＋/status 雙軌＋管理頁摺疊

- 根因修復：舊版以 `message_count` 為訊號，工具執行中不落 DB 會整輪漏看。gateway 端由 compat plugin 新增 `GET /api/sessions/{sid}/activity`（run 受理即登記，queued/running/waiting/stopping 即時，含 user preview、DB revision、server_epoch）；app 端以它取代計數輪詢：他端發言 ≤6 秒顯示 user 列＋「另一裝置執行中」＋鎖送出（草稿可編）；remoteBusy 與本機 busy 三口徑分離，觀察者不觸碰他人 lease/stop/approval。`/status` 分「本頁操作」與「伺服器活動」兩軌；離線/未知老實顯示待確認。Skills／Model 區塊可摺疊（本機持久化）。
- 驗收：compat offline probe 全綠（activity 群含 control 與 lifecycle）；Flutter 逐檔全綠、analyze 0；大歷史 snapshot RTT 走索引路徑。

## 2026-09-10 — Phase 0 API capability probe

- 新增 `probe/probe_p0.py`：stdlib、八項獨立探測、HTTP/SSE 時間戳與完整證據、key 遮蔽、JSON/Markdown 摘要；僅修改探測建立的 session，並全部清理。
- 位址來自 canonical env（`HERMES_LIVE_BASE_URL`），無硬編碼主機。
- 限制（當時 gateway 狀態）：附件端點 404；分頁比對僅達 200+200；run TTL 僅 source 證據。

## 2026-09-10 — Phase 1 骨架

- Flutter 專案（app/）、api 層（repository/SSE）、chat 層（雙模式 timeline）、toolchain 自動安裝（`toolchain/` 內 Flutter+Android SDK+JDK，`scripts/env.sh` 一鍵 environment）。
- 驗收：`flutter analyze` 0 issues；`flutter test` 通過（projection 判別、SSE parser、分頁去重、key 不外洩、slash）；debug APK 建置成功。

## 2026-09-11 — Phase 1 integration 與文件定稿

- 新增 `app/tool/integration_walkthrough.dart`：直接用 app repository／SSE parser／LiveTurn／訊息模型走訪 `<SERVER_ORIGIN>`；通過相容性／401、列表刷新與 skills、歷史分頁與投影、工具串流、skill 改寫 round-trip、stop 後重用、steer、completion 後斷線與歷史核對。
- 探測建立的暫定 session 全部 DELETE 後 GET=404；key 遮蔽；既有真實 session 僅讀取。詳細 log 留本機（gitignore）。
- 驗收邊界：ADB 沒有連接 Android 裝置，手機觸控、網路切換與 Keystore 待實機驗證；contract 沒有 SSE resume 端點，歷史核對不等於無損事件續傳。

## 2026-09-11 — Phase 2

- **送出不假死**：SSE 靜默逾時即觸發歷史對帳，不再卡在 sending；中斷回合寫本地 lost 標記。根因：app 背景化 → Android 殺 socket → server interrupt run。
- **Session rename**：列表與對話頁皆可改名＋本機 title 快取即時顯示。
- **隱藏＝歸檔**：本機 hidden 清單，列表預設過濾、搜尋可撈回、隱藏項沉底、不計未讀。
- **草稿持久化**：per-session 輸入草稿 debounce 寫 prefs，送出後清除。
- **管理頁**：Skills 清單＋唯讀、Memory/USER 佔位、Model 清單＋per-session 切換。

## 2026-09-11 午後 — v0.2.1 hotfix：假判斷線

- v0.2 的 silence watchdog 把「server 活著但在等模型」誤判成斷線——空轉 SSE 只有每 30s 的 `: keepalive` 註解，parser 丟掉註解使 watchdog 收不到活線證據，且随后的 socket 關閉讓 server interrupt 該 run。
- 修法：`: keepalive` 註解在 parser 轉 heartbeat 事件（其他註解照舊靜默），controller 計入活線但不 repaint。新增 heartbeat 與交錯 keepalive 測試。

## 2026-09-11 — v0.2.2 P2FIX：診斷與背景回前景對帳

- 設定頁自 package 讀實際版本；SSE 事件以 UTC 寫入本機 JSONL（排除金鑰、URL、對話 payload、原始例外），2 MiB 輪替保留前一檔，可用文件選擇器匯出。
- Controller 監聽 `AppLifecycleState.hidden/paused/resumed`；回前景立即核對最新歷史，不等 recovery 倒數；不主動關閉仍健康的 SSE、不重送 POST。斷線文案改為「可能未完成」。
- 邊界：無法保證 Android 不殺 socket；鎖屏與原生匯出流程待手機驗收。

## 2026-09-11 — v0.2.3 P2FIX2：foreground service 保護背景 SSE

- Kotlin `HermesStreamService`（dataSync、START_NOT_STICKY）＋`hermes/stream-keepalive` channel；通知低重要性、固定文字、不含對話資訊。
- 服務按串流 token 計數；run.completed／done／error／EOF、recovering 或 idle 即釋放；歷史輪詢不重新啟動；不常駐。
- 根因定案：client disconnect 必 interrupt live run（contract 已勘誤）；server 端未修改。headers 到達前切背景時 Android 仍可能拒絕 FGS 啟動，須以 log 確認。真機保活與通知權限待驗收。

## 2026-09-19 — v0.13.10：按停止後輸入框鎖死（殭屍 pending）

- 症狀：web 端按過「停止」的對話之後每次進頁都卡在「進行中」；pending 紀錄指向一個 gateway 已遺忘（404）的 run。
- 根因：reload 接回把 pending-turn 生命週期掛在「有 final」上，但被手動停止的回合永遠不會有 final；`stop()` 沒清 pending → bootstrap 輪詢 404 → 觀察迴圈 → 逾時重來，busy 恆真。
- 修法：`stop()` 成功即清 pending；bootstrap/detach 輪詢的 404 路徑查 stop record，run_id 相符且 accepted 即認領結帳回 idle＋「已由你停止」。無 stop record 的 404 維持原觀察語意。
- 驗收：analyze 0 issues；全量 flutter test 全綠（新增 3 個回歸）。

## 2026-09-20 — WAVE2：AUDIT 11/12、18/19、16、21 批次修正

- **AUDIT-11/12**：回合世代化——每個觀察者捕捉 mint 時的 token，settle/dispose 之外一律不得覆寫回合狀態。
- **AUDIT-18/19**：反代雙向 chunked 串流：上傳 peak RSS 有界、Content-Length 越 cap 在讀取前 413、未知長度串流越線中斷、>8MiB 大檔共用 2 併發配額、SSE drain 語意不變。`web/test_upstream.py` 為真 assert 回歸。
- **AUDIT-21 前半**：ChatViewers 觀看者帳本——導航去重在 markRead 之前同步完成；只在 1→0 觀看者轉換才 detach 切斷 SSE。
- **AUDIT-16**：idle controller 有界 LRU（cap 8，可見頁/執行中豁免）；resume 只核對可見頁與活躍 run。
- **AUDIT-21 後半**：pending-turn 跨分頁擁有權——owner token 為 tab×turn 兩層；web 端 Web Locks、不支援則降級 in-process 佇列並明示；lease＋heartbeat；A 分頁結算 compare-and-delete，永不誤刪 B 的接管紀錄；舊 schema 照單採納。

## 2026-09-20 — compat plugin 來源

- 新增 compat plugin 來源（安裝為部署者動作，見 `compat/README.md`）。

## 2026-09-21 — v0.13.15+35 WAVE3：跨裝置同步（R1）＋動畫收尾（R2）＋管理頁實裝（R3）＋審核卡接線（R4）

- **R1**：可見頁面定期 GET `/api/sessions/{sid}` 盯 `message_count`，變了才抓一次歷史（token 守門、single-flight、異常靜默下 tick 重試）。其後由 WAVE4 的 activity 快照取代。
- **R2**：補 fourth 形態「stopping drain」的 TypingDots 回歸。
- **R3**：Model 目錄解析容錯；Skills 開關走反代 `PATCH /api/skills/{name}`（Bearer auth；存在性用全掃描避免關閉後找不回；essential 400、未知 404、import 失敗 503）；Memory 兩檔經 `GET/PUT /api/memories`（白名單、tmp+os.replace 原子寫、GET 附 mtime）。反代測試 `web/test_serve_skills.py`、`web/test_serve_memories.py`。
- **R4**：審核卡接線——事件自帶 run_id 作為 POST 目標 fallback；404/409 顯示「回覆失敗」可重試；無 run_id 時降級為純顯示。批准前指令實際未執行。

## 2026-09-21 — ENVHYGIENE：設定外移與乾淨建置

- 所有私有位址退出 repo：`defaultUrl`/`legacyUrl` 改 `--dart-define`（public build 恆空），反代/upstream/bind 走 env 檔＋loopback 安全預設；`web/serve.py --check-config` 在任何 bind 前驗證並只列名稱與來源。
- 新增 `scripts/build_app.sh`（`--profile personal|public` 必填）、`scripts/runtime_config.py`、`app/tool/runtime_config.dart`、`.env.example`、`tools/hygiene_gate.py`。
- 測試 fixtures 全面合成化；私人工作紀錄停止追蹤（本機保留原位）。
