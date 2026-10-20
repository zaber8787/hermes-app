# STREAMRESIL2 報告

## 實作

僅修改 app/ 程式及測試；另依要求於 root 建立 PLAN 與本報告。未 commit、未修改
Python、SW、messages 分頁/include_compacted 或 sendBlocked。

Web 第一次 EOF/error 即接管到既有 run polling，包含零事件 EOF。N=1 的安全理由
見 PLAN；不重送 chat POST。降級 tick 復用 activity 的 revision-driven history
merge，hidden 仍可更新，foreground 仍使用既有 fresh status 查詢。已知終態共用
known-terminal settlement 與 messages 合併，清除提示與輪詢。

新增台繁／英文 locale key；沿用現有輕量狀態列呈現。非 Web 預設路徑不變。

## 測試與限制

新增 app/test/stream_resilience_test.dart，注入虛擬 EOF/error/零事件序列與 widget
測試時鐘，檢查降級、定期 GET、messages 合併、running 前景恢復維持輪詢、
terminal 前景恢復移除輪詢，以及本機保留原 recovery；全程斷言 chat POST 僅一次。
測試復用 audit05_poll_owner_test.dart 的 FakePollRepo，以新 subclass 提供變動的
activity history revision，沒有修改既有 fake 或 contract 測試語義。

Flutter wrapper 無法寫 SDK cache（沙箱 Operation not permitted），未執行 flutter
test。直接 Dart format 已完成。一般 dart analyze 的預設 ~/.dartServer cache 亦
受阻，改用 analysis server --cache=/private/tmp/streamresil2-analysis 執行全 app 分析。
全 app 靜態分析完成（ANALYSIS_COMPLETE 0，零診斷），git diff --check 通過。
主 agent 仍須執行 Flutter 測試全套。

瀏覽器真實背景節流無法由 widget fake clock 模擬；實際 GET cadence 受瀏覽器排程
限制。伺服端 SSE 接回能力缺口已列 Server asks，本任務不依賴該端點。
