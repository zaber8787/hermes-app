# TASK-STEERVIS 完工報告

## 判定

假設 A 對未經 API 的 cron / CLI 派工成立：activity 明示 `coverage=api_process`，不涵蓋所有背景工作。App auto-wake / server self-wake 都走 chat/stream，屬既有觀測範圍，不能概括成所有背景續跑都不可見。假設 B 無法解釋「橫幅從不出現」：freshness gate 限制插話送出，並不隱藏已有 run 的橫幅。詳細行號、工作形態、近期 cron log 證據及 Server asks 見 [PLAN-STEERVIS.md](PLAN-STEERVIS.md)。未取得使用者當時同時段 snapshot，故未宣稱現場重現其特定 session。

## App 修改

- 無本地或遠端執行、且伺服器提供 steer 時，顯示可展開的「插話與執行狀態」入口，說明背景工作可能未回報，提供唯讀重新確認按鈕；讀取期間停用重複點擊。
- 已有可插話 run 時，按鈕改為泡泡圖示＋「插話」文字，提升辨識度。
- 保留 capability / identity / freshness / run-bound admission 規則，不猜 run id、不把 last_active 當執行中、不改 Python、不 commit。
- Session list 無可信 live status，通知亦非完整執行生命週期，故本次不添加可能誤導的執行中角標。真正背景工作插話需 Server asks 補齊 registry 與消費邊界。

## 驗證結果與限制

- 6 個修改檔的 Flutter analyze 通過：chat_page、remote_activity_notice、catalog、message_key 及兩個測試檔，No issues found。
- Dart format 與 git diff --check 通過。
- 新增窄螢幕提示展開、唯讀 refresh 與重複點擊保護 widget 測試；新增 controller 測試驗證 stale 保留 remoteBusy 但無 steer target，以及空 activity 不提供背景插話目標。
- 最終嘗試執行 `flutter test --no-pub test/remote_activity_notice_test.dart test/cross_device_steer_test.dart test/i18n_catalog_test.dart`：全部在載入時被環境禁止綁定 `127.0.0.1:0`（Operation not permitted）擋住，0 tests executed，**動態測試未通過驗證**。需在允許 localhost socket 的環境重跑以上命令。
- 先前包含 audit_cross_device_sync 的執行另遇同時修改中的 message_content.dart 缺 BytesBuilder；本任務未修補或覆寫該檔。最新驗證的阻礙為上述 socket 限制。
- SDK 是指向 workspace 外的 symlink，直接啟動會碰到 cache 寫入權限；驗證使用 /private/tmp/steervis-flutter 的暫存 SDK 入口及暫存 XDG config，未改外部 SDK。

## 範圍

本次修改只有 app 內插話可見性、台繁／英文文案、測試及本任務兩份文件。工作中另有 .build-profile、message_content.dart、image_viewer、IMGVIEW 文件／測試等其他變更，均保留原樣。
