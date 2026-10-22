# RENDERX 渲染審計

## 動工前的專業清單

1. 文件以外還應做什麼：先驗證探針自身能抓到尖峰與假人，區分冷啟動、字體／圖片解碼、build、layout、paint 和 raster 成本；檢查不同 viewport、文字縮放、session 與身分切換的快取失效。記錄環境與原始輸出，避免以 debug widget 時間冒充裝置 GPU 時間。
2. 第一手材料：倉庫實作與既有測試、Flutter framework／rendering 原始碼、逐幀 ScrollPosition／Sliver 幾何、Element rebuild 回呼、RenderObject layout／paint 計數、Chrome 原始 trace、實際測試與分析輸出。
3. 方法與儀器：先跑原有探針建立基線；以逐幀極值而非最後一筆判定軌跡；掛 Element rebuild 與 RenderObject 尺寸／繪製觀察；使用受控 Future 模擬圖片晚到、長拖曳與連續 jump；使用 Stopwatch 及瀏覽器測試／trace 交叉驗證。所有新增工具置於倉庫或 /tmp。
4. 外部裁判：保留原有測試並增加能對舊實作失敗的客觀斷言；全量 flutter test、flutter analyze、Chrome 契約與可重跑原始紀錄。未執行或未通過的驗證一律不能宣稱完成。

## 執行紀錄

- 初始工作區僅 TASK-RENDERX.md 為未追蹤檔案；不改 git 歷史。
- Flutter SDK 的 toolchain/flutter 是指向 /Users/zaber/development/flutter 的符號連結。原啟動指令因 SDK cache 位於沙箱寫入範圍外而失敗；改嘗試複製到 /private/tmp/renderx-flutter，遵守工具安裝範圍。
- 初讀發現待驗證事項：motion 探針 maxStep 每輪覆寫而非取最大值；_LazyRow 高度記憶未直接觀察子樹 layout 變動。此處尚未將推測當作量測結論。

## 停止原因：環境不具備必要量測前提

日期：2026-10-22。依使用者「若任務前提不成立……寫進最終回覆後停止（不要假 touch）」條款停止。本文件是未完成紀錄，不是驗收報告。

已成功將 SDK 複製到 /private/tmp/renderx-flutter，以 `--suppress-analytics` 與 `XDG_CONFIG_HOME=/private/tmp/renderx-config` 排除工作區外 SDK cache、telemetry、tool_state 寫入限制。版本為 Flutter 3.47.7、Dart 3.13.5、macos_arm64。

在 app/ 執行：

```sh
XDG_CONFIG_HOME=/private/tmp/renderx-config /private/tmp/renderx-flutter/bin/flutter --suppress-analytics test --no-pub test/scrollfix_jank_test.dart test/scrollfix_motion_test.dart test/timeline_virtualization_test.dart
```

退出碼 1。三個檔案均在載入時失敗，0 個斷言執行；原始輸出保存在 [baseline.log](renderx-evidence/baseline.log)。關鍵輸出：

```text
Failed to create server socket (OS Error: Operation not permitted, errno = 1), address = 127.0.0.1, port = 0
package:flutter_tools/src/test/flutter_tester_device.dart 89:15  FlutterTesterTestDevice.start
00:00 +0 -3: Some tests failed.
```

這是 Flutter 測試 runner 的本機 server socket 遭環境禁止，並非產品斷言失敗。當前權限政策為 never，不能提升權限；移動 SDK 並不能解除 socket 限制。因此無法建立任務要求的 CI 儀器基線、全量 flutter test 全綠或瀏覽器量測鏈路。未執行全量回歸與 analyze，未宣稱任何效能數字、假設驗證或修復成立。

沒有修改產品程式或既有測試；沒有動 API、serve.py、git 歷史；沒有建立 /Users/zaber/.hermes/logs/renderx.done。未經量測的兩項初讀疑點保留供後續驗證。後續執行需允許 Flutter runner 綁定本機 loopback socket，並提供完成標記路徑的寫入權限（目前該路徑亦不在允許寫入範圍）。

## Worker #2 續作（2026-10-22）

保留上方 worker #1 的歷史停止紀錄。先以同一 /private/tmp SDK 執行全量基線，原始輸出為 `renderx-evidence/baseline-worker2.log`。本次測試 runner 已成功綁定 socket 並執行斷言；全量測試中既有 P3 keepalive 個案包含 75s + 13s 的真實等待，不能把這段時間誤判成渲染卡頓。

專業清單沿用本報告開頭四題，新增落地決策：所有幀探針必須保留全程極值；高度觀察必須位於 RenderObject layout 邊界而不是依賴祖先重建；冷啟動時間需區分首幀與真正 tail 可交互；若瀏覽器不可用則按任務允許的 Stopwatch + rebuild 計數替代，明列無法證明的 GPU 成本。

已校正 motion 探針的全域 maxStep 並將 extent 單幀上限收緊到 300px，舊產品實作的兩支 motion 測試仍通過（`motion-corrected-before.log`）。因此不能宣稱這組既有場景已抓出產品退化；探針覆寫缺陷需要額外的早期尖峰樣本裁判。

### Worker #2 停止：驗收環境前提仍有衝突

本次全量基線成功，真實末行：

```text
02:03 +793: All tests passed!
```

完整原始輸出：[`baseline-worker2.log`](renderx-evidence/baseline-worker2.log)。這只證明未修改產品的 793 支既有測試全綠，不是 RENDERX 完工證據。

`flutter analyze` 連續兩次因 analysis server 寫入沙箱外的 telemetry 檔而失敗，並非 Dart 診斷。第二次已加 `DASH__SUPPRESS_ANALYTICS=true` 及 `--suppress-analytics`，仍退出 255；沒有變更 HOME 或系統設定，也沒有修改 SDK 來繞過分析器。真實輸出節錄：

```text
PathAccessException: Cannot delete file, path = '/Users/zaber/.dart-tool/dart-flutter-telemetry.log' (OS Error: Operation not permitted, errno = 1)
#6 AnalyticsManager.sendMemoryUsage (package:analysis_server/src/analytics/analytics_manager.dart:280)
analysis server exited with code 255
```

原始輸出：[`analyze-first.log`](renderx-evidence/analyze-first.log)、[`analyze.log`](renderx-evidence/analyze.log)。目前必要的 `flutter analyze` 零問題驗收鏈無法成立；不能把 analysis server 崩潰當成零問題。依使用者「若任務前提不成立或與 repo 現況衝突……停止（不要假 touch）」停止。

另外已把官方 Chrome for Testing 156.0.8078.47 headless shell 安裝於 `/private/tmp/renderx-chrome`，未動系統目錄；`--version` 可執行，但 P1/P4/圖片生命週期 Chrome 契約在啟動瀏覽器時被 macOS Mach service 權限拒絕，0 個斷言執行。Flutter 已使用 `--no-sandbox --headless`，仍出現：

```text
FATAL:base/apple/mach_port_rendezvous_mac.cc:159
bootstrap_check_in org.chromium.Chromium.MachPortRendezvousServer.83187: Permission denied (1100)
Failed to launch browser after 3 tries.
```

原始輸出：[`chrome-contracts.log`](renderx-evidence/chrome-contracts.log)。沒有取得真實 web scroll trace，也未宣稱 CanvasKit 等價性。

### 停止前的探索與工作區處理

- `maxStep` 的全域極值校正與 extent cap 300px：兩支 motion 測試通過，見 [`motion-corrected-before.log`](renderx-evidence/motion-corrected-before.log)。這是探針校正，不是產品缺陷修復的紅綠證據。
- 嘗試以 RenderProxyBox 觀察子樹 layout、於 scroll-active 保留已公布行高，撤掉每次 scroll 重設的 400ms Timer。單獨幾何測試通過；整合 ExpansionTile 測試首次漏 ProviderScope，補 fixture 後展開通過但收合斷言仍失敗（82px 對 734px）。最後修正測試點擊目標尚未重跑。見 [`geometry.log`](renderx-evidence/geometry.log)；未據此認定修法成立。
- 為免留下尚未完成驗證的產品修改，已將本次兩個既有檔案還原到動工前內容，移除本次新增的產品／測試檔案。未完成草稿另存 [`worker2-unvalidated.patch`](renderx-evidence/worker2-unvalidated.patch)，僅供續作參考，**不可視為可合併修復**。
- 最終沒有修改或刪除任何既有測試；沒有改 API、serve.py、git 歷史；沒有 commit／push。
- 未完成每幀 rebuild／paint 儀器、完整假設對抗、跨域三項實作對照、修復後全量回歸及 RENDERX 驗收。原問題尚未修復。沒有建立 done marker。

### 移交項

1. 必須先提供可正常執行原版 `flutter analyze` 的環境，消除 analysis server 對 telemetry 路徑的權限衝突；不能用修改分析器或吞掉退出碼取代。
2. 真實 Chrome 契約／trace 仍受 macOS Mach service 沙箱限制；本機 loopback socket 已解除不代表瀏覽器啟動權限也解除。
3. 後續再續行高度變動、冷啟動、快取失效及 refine loop 的量測。現有兩支 motion 場景通過不能證明峰速、長拖曳、連續 jump 或圖片晚到時均符合指標。
4. `/Users/zaber/.hermes/logs` 仍不在本次允許寫入範圍，且任務尚未完工，未嘗試建立完成標記。

## Worker #3 前提複核（2026-10-22）

保留前兩輪紀錄。本輪直接使用 `/Users/zaber/development/flutter/bin/flutter`，沒有使用或複製 /tmp SDK；沿用本文開頭四題清單，尚未修改產品程式或既有測試。

直接執行全量 `flutter test` 首次因 telemetry 寫入權限退出 255。改用 `XDG_CONFIG_HOME=/private/tmp/renderx-worker3-config` 與 `--suppress-analytics` 後測試 runner 可執行；全量輸出保存在 [baseline-worker3.log](renderx-evidence/baseline-worker3.log)。

必要驗收鏈仍不成立：在 app/ 直接使用原 SDK 執行 `flutter --suppress-analytics analyze`，以及加上 `DASH__SUPPRESS_ANALYTICS=true` 的重試，兩次均退出 **255**。原始輸出為 [analyze-worker3.log](renderx-evidence/analyze-worker3.log) 與 [analyze-worker3-suppressed.log](renderx-evidence/analyze-worker3-suppressed.log)。共同錯誤如下：

```text
PathAccessException: Cannot delete file, path = '/Users/zaber/.dart-tool/dart-flutter-telemetry.log' (OS Error: Operation not permitted, errno = 1)
AnalyticsManager.sendMemoryUsage (package:analysis_server/src/analytics/analytics_manager.dart:280)
analysis server exited with code 255
```

SDK cache 可寫解決不了 analysis server 對另一個路徑的寫入。本輪沒有修改 SDK、分析器或 HOME，也沒有將崩潰冒充零診斷。任務續派「環境已修到底」的前提與實際權限仍衝突；依使用者明示的前提不成立停止條款，停止產品工作。這不是 Chrome 問題導致的停止，也不是完成報告；效能修復、儀器、假設對抗與修復後全量回歸均未完成。未 touch 完成標記。

本輪全量基線最終退出碼 0，原始末行為 `02:04 +793: All tests passed!`。這只證明既有測試基線通過，不能替代未成功執行的 analyze 或尚未進行的渲染修復驗收。

## Worker #4 開工清單與分支紀錄

沿用開頭四題並全部作為本輪動工前清單：直接讀 framework layout/rebuild 原始碼，驗證探針尖峰保留能力；量測 descendant-only layout、收合與流式 paint 邊界；區分 VM CPU 與瀏覽器 GPU 證據。先跑全量基線及 analyze，輸出 baseline-worker4-*。原 SDK 設定路徑不可寫，選 XDG_CONFIG_HOME=/private/tmp/renderx-worker4-config，不改 SDK。analyze 已退出 0、No issues found。產品修改尚未開始。

## Worker #4 修復與驗收報告（2026-10-22，續寫）

上面三輪是歷史紀錄，不代表本輪狀態。本輪原 SDK 的 VM socket、SDK cache、analyzer telemetry 均已可用。基線實際結果：`02:03 +793: All tests passed!`，`No issues found! (ran in 2.1s)`；原始輸出 [baseline-worker4-test.log](renderx-evidence/baseline-worker4-test.log)、[baseline-worker4-analyze.log](renderx-evidence/baseline-worker4-analyze.log)。沒有改 API、serve.py、git 歷史，沒有刪測試。

### 第一手材料與實際儀器

- 直接讀本機 Flutter `widgets/framework.dart` 的 `Element.rebuild`／`debugOnRebuildDirtyWidget`，以及 `rendering/object.dart` 的 `PaintingContext.paintChild`、`rendering/proxy_box.dart` 的 RepaintBoundary 指標。不是把 flutter test 的 help 當 timeline。
- `test/renderx_instruments/frame_probe.dart` 掛真 Element rebuild callback，逐幀統計所有 widget 與 EntryView（包括 cache 區域），逐幀斷言 rebuild 行數 ≤ 實際 onstage 行數 × 1.5。按真 viewport rect 掃每個 `_LazyRow` 子樹，逐幀禁止 viewport 中出現未實體化行，並以 Stopwatch 記錄整次 pump 的 CPU／runner 壁鐘上界，每幀 < 16667µs。
- 保留並擴充原有五支 scrollfix 探針。新增 7500px/s 高速手勢，明確事件時間戳，每一幀採樣 16ms；速度上界按輸入每幀距離 + 10px，extent 上界 300px。原探針最後幀覆蓋尖峰的錯誤改用共用 `maxSampleStep`，另以 `[0,2100,2110,2110,2110]` 樣本鎖住早期尖峰 2100px。
- `row_geometry_test.dart`：RenderObject descendant-only layout 的 80→280→40px 受控變化、真正 ServerPathImage 下載 Future 完成＋有效 PNG 解碼、ExpansionTile 完整展開／收合後的 memory 對照。
- `repaint_test.dart`：掛 `debugOnProfilePaint`，只計邊界**內部** render object 的繪製。邊界本身被父層訪問／cached layer composite 不等於重新畫子樹。另斷言穩定 markdown 不重新 build。
- `idle_and_probe_test.dart`：連續 300 幀（4.8 秒）保持 scrolling，零 anchor correction、零自發排程幀；idle 後最新 callback 恰好一次；替換及 dispose 後舊 callback 不可復活。
- 冷開分開量首兩次 pump（P1）與現有 app shell 中 cold session 開啟至 settle 且真尾行 m199 已實體化（P4）。P4 不把 Flutter engine／MaterialApp 初次初始化混算成歷史列表成本，也沒有預先構造 ChatPage／markdown。原先整個 app 冷啟動的輸出 421／520ms 保留在探索 log；它不是現在這個 session-open 指標。沒有把它藏成 <300ms。
- 新增 `app/dart_test.yaml` 固定 concurrency=1：牆鐘效能斷言不能與其他 tester VM 搶 CPU。全部測試仍執行，沒有 skip、刪除、改用 release 假裝 debug。平行時的 307／349／411ms 失敗保留，串行測試是可重現的驗收條件。

### 問題總表

| 問題／症狀 | 修前客觀證據與根因 | 修法 | 外部裁判／修後數據 |
|---|---|---|---|
| 高度記憶根本沒有首次寫入 | `_reported = double.nan`；`abs(h - NaN) > 1` 永遠 false。新 ExpansionTile 測試對原版失敗於 memory 無 m0，見 geometry-before.log | 拿掉祖先 build／400ms Timer 量測，改 RenderProxyBox layout 觀察，每次實際尺寸變化 post-frame 寫回 | 初始量測可見；展開增加 >100px，收合回原值 ±0.01px；geometry-worker4.log、late-image.log |
| 圖片晚到／子樹 layout 不通知祖先；拖動中行高變動 | 舊版只在 row build 或 scroll Timer 觸發量測；深層 Future/ExpansionTile 不一定重建 row | TimelineRowGeometry 在 scroll-active 保留上次公布尺寸並 clip，idle 重新發布 natural size；取消每筆 scroll 都建立的 Timer | 80→280 時拖動行高維持 80、idle 變 280、再縮成40；真正下載 PNG 前後 active 行高維持120、idle 才改高 |
| fling 探針自我虛偽 | maxStep 每圈覆寫，且手勢事件全部 timestamp=0；最初「通過」的 maxStep=0，根本沒有 ballistic motion | 全域極值函式、尖峰自測、遞增 timestamp、非零 ballistic travel 斷言 | 真實低／高速 maxStep 39.518／119.355px，分別 cap50／130px；peak-fling.log |
| scrollbar extent 中途跳動 | 校正手勢後真實 maxExtentStep=376px，超出300；Sliver 預設用當前短小窗口平均高度推估整頁 | delegate 只從 trailingScrollOffset 加未 layout suffix 的 prefix sum；已量高度取 memory，未量部分使用一致估計 | 相同手勢降至48.4842px／幀；geometry-budgets.log、peak-fling.log |
| refine 等待會在長拖動後強制 jump | 舊版 wait<240，超過後即使 scrolling 仍執行 correction；每次依賴下一幀，idle 無幀時也可能不醒 | ScrollIdleGate 監聽真正 scroll end，取代 frame polling，最新任務替換舊任務，dispose 取消 | 300幀 active 零回調且不自行排程；idle一次；原 load-older 收斂契約保留 |
| 冷開先排頂端再跳尾端，尾塊過大 | 原 P1 cap1200ms、P4 cap2500ms，無法鎖300；coldInteractive421ms 探索輸出 | 首次內容抵達先用純 placeholder 尋尾；尾部實體化塊12→4，其餘由 proximity 自然補入；對相同文字／repo 重用 MessageContent 子樹，避免父層更新重解析 | 串行 coldFirst36ms、coldInteractive275ms，P1 cap100ms、完整互動cap300ms；serial-instruments.log。最終全量數字另列下方 |
| 父層 rebuild 讓不變 markdown 重解析 | MessageContent 每次 build 重新 split（還 split兩次）、建立 GptMarkdown/link callbacks | 每個 mounted MessageContent 以 text＋repository identity 保留 child；文字或帳號變更重建，子樹自己的 inherited dependencies 照常更新 | streaming 時穩定 markdown rebuild=0；Render paint hook 證明穩定 sibling 內部paint=0 |
| 檔案剛生成，失敗縮圖永遠留在下載圖塊；帳號間冷卻互相污染 | State `_future` 保留 failed Future；手動下載成功只 saveBytesAs，不更新縮圖。原 cooldown 是 baseUrl＋path 全域，另一帳號也被擋 | AttachmentTile 下載成功回傳 bytes 給同 identity 的 ServerPathImage，清冷卻並更新 inline Future；冷卻改 repository Expando | 同identity rebuild只下載1次；失敗後手動retry總2次且 MessageImageMemory 恢復；同URL的另一repository不受失敗污染，cooldown仍防同帳號重試風暴 |

### 假設對抗（逐條裁決）

1. **推翻「extentMemory 原先穩定已讀幾何」**：NaN 比較讓首次寫入永遠失敗，不只是圖片後過時。新測試對舊碼紅，layout observer 修後可量得初值、展開值與收合值。舊碼只改 maxStep 仍綠不構成修復證據，故另補有時間戳的真 fling。
2. **有條件支持 viewport×2 視窗**：2500 與7500px/s，各70幀，逐幀 viewport 內零 placeholder；每幀最多1／2行重建，extent峰48.4842px。保留窗口而未盲目擴大，避免增加預先 markdown layout。證據範圍是這兩個受控速度與測試 viewport，不宣稱無限速度／所有裝置已測。
3. **推翻 refine 等待安全性**：原 wait240 只是到期強制修正，不是安全的 starvation 防護。現在 scroll end 事件喚醒、保留最新 correction；長拖動無 layout polling／jump，連續程序 jump 的 idle 狀態不需等待。disposed／已取代 correction 不得執行。
4. **不能以 VM contract 綠推導 CanvasKit 等價**：本輪指定本機存在的 `/private/tmp/renderx-chrome/chrome-headless-shell-mac-arm64/chrome-headless-shell`，執行 `flutter test --platform chrome`（P1/P4 bootstrap/image lifecycle）；仍在 browser launch 被 macOS Mach service `bootstrap_check_in … Permission denied (1100)` 拒絕，0個 browser 斷言。見 chrome-worker4.log。web build 成功不等於 web timeline 驗證。
5. **推翻「30s冷卻不影響恢復」的強版本**：僅等時間不會替換 mounted failed Future，另帳號也被全域冷卻誤傷。現用同一 download 操作恢復縮圖，不另外自動發網路請求，且跨帳號隔離；既有失敗可下載契約保留。
6. **新增假設：repaint boundary 被畫到＝內部重新 raster**：錯。邊界 metrics 包含 cached layer 訪問；本測試顯示穩定 boundary metric 仍增加5，但邊界內 paint hook為0。不能用 metric 差值自動斷言整頁重繪。
7. **新增假設：壁鐘pump＝GPU frame timeline**：錯。Stopwatch含 runner/CPU，不含裝置GPU；本輪只能用文件允許的 fallback。另有全量並行 CPU 競爭，故固定單VM執行。冷開300ms的適用條件見上，不誇大為 app process cold start。

### 跨域對照（實際落地）

- **UITableView／UICollectionView** 用 estimated cell height 尋位、實測後修正；我們保留 key→實測 extent，並只估算尚未 layout suffix，避免把眼前短行的均值放大全頁。差異：Flutter sliver 可丟棄 Element；記憶由 page 持有，收合／深層圖片需 RenderObject 回報，不能只靠 cell build。
- **RecyclerView anchor／stackFromEnd** 保持尾部或可見 anchor identity，而不是重放全部資料；我們冷開以 placeholder 純估計直達尾區、只實體化小塊，load-older 保留 key＋dy，scroll idle 後有界 refine。差異：Flutter 的 variable-height Markdown 是逐次 layout，不能預先相信 item index×平均就是最終座標。
- **瀏覽器 scroll anchoring** 在 late content 改高時保護讀者位置，使用者滾動期間抑制不恰當補償；我們 active 時鎖住已公布行高、clip 新內容，idle 才採用 natural height，anchor correction 用真 scroll-end 通知。差異：不是引擎層自動 overflow-anchor；需要在自訂 row render boundary 明確執行。
- **遊戲引擎 frame budget／time slicing** 以實際幀預算管理工作，不依靠「最後一幀很快」。我們保留全程極值、每次scroll通知合併一幀、去掉每行每scroll重設Timer、鎖16.667ms CPU probe，並將尾塊12縮4。差異：VM debug pump不是 GPU present，GPU驗收分工另列。

### 既有測試逐項修改理由

- scrollfix_motion_test.dart：修正錯誤極值、真正模擬 fling 時間，擴充高速度；1500px extent cap收緊300，position cap按輸入物理速度計算；加入每幀rebuild、CPU、placeholder裁判。原兩項功能均保留。
- scrollfix_jank_test.dart：settled drift 容差1px收緊到0.001px，其餘既有探針保留。
- timeline_virtualization_test.dart：P1 1200ms cap→100ms並輸出真實數字，保留原mount數與anchor契約。
- openperf_regression_test.dart：P4 2500ms cap→300ms；固定已啟動app shell下開冷session，包含所有ChatPage/history建構及settle、真尾行確認；16ms settle cadence避免100ms測試時間跳躍混淆初始可互動定義。
- imgperf_image_lifecycle_test.dart：保留下載失敗後原有retry契約，增加下載成功inline thumbnail恢復斷言，以及一項跨repository失敗隔離測試。既有四項沒有刪。
- 新測試與儀器放 renderx_instruments/；`dart_test.yaml`只改併發數，不改test selection。

### Web 驗證分工與移交項

- **本輪工程端**：完成 VM CPU/layout/rebuild/paint 斷言，建立 web release build 與 Chrome 啟動失敗原始紀錄；不把 VM probe 當 CanvasKit trace。
- **驗收方（派工者）**：依續派說明#2，在可啟動真瀏覽器的環境執行 `flutter test --platform chrome test/timeline_virtualization_test.dart test/openperf_regression_test.dart test/openperf_bootstrap_test.dart test/imgperf_image_lifecycle_test.dart`；對 `flutter build web` 的 CanvasKit 頁面收 Chrome Performance trace，量真scroll掉幀及圖片解碼／GPU raster。這是明確分工，不因Chrome阻止VM任務。
- 原版 build web 成功，但工具提示缺 CupertinoIcons font family（app 未包含該包）；這不是本輪引入。保留 build-web.log，不以修改 pubspec 或圖示系統擴張渲染修復範圍。
- `serve.py` ARTIFACT-PERSIST 與 app/lib/api/ 全未改；沒有發現需要順手更動網路契約的修復。
- 實測 envelope 是200行、既有中英文重Markdown資料、16ms步進、2500/7500px/s；未取得實機Android GPU或Chrome trace。裝置級順滑不能由VM測試代簽。

### 最終回歸前校正紀錄

首輪全量 `03:44 +800 -1`，唯一失敗是新增真圖片探針把「解碼後自然高度」誤寫成應該小於120px：有效1×1正方形 PNG 在200px tight width下實際高度208px（200＋上下padding8）。已校正為**active維持120，idle採用208**，單檔3項通過，見 late-image.log。沒有為了它修改產品。第一輪完整輸出保留 full-regression-first.log；不將它當成全綠。

新增真解碼探針還發現既有 identity 測試沿用的 PNG fixture 無法成功解碼，只能證明 Future／bytes identity，不能證明像素成功顯示。本輪新增 probe 使用標準PNG chunk/CRC產生的有效 fixture，並 await precacheImage 以真 codec 完成為判準；原 identity 測試不冒稱 pixel 測試。此項是測試材料品質發現，不是 server 圖檔損壞或 API bug。

完成代碼的 web release build 再跑一次退出0，真實末行：

```text
Compiling lib/main.dart for the Web...                             17.2s
✓ Built build/web
```

原始輸出：[build-web-final.log](renderx-evidence/build-web-final.log)。Chrome/GPU仍按上方明確分工由驗收方執行。

### 探針覆蓋邊界最後複核

最後複核把 position／extent 樣本起點提前到 drag **之前**，涵蓋10個drag幀、release交界及60個ballistic幀；ballistic非零斷言仍只比較release座標與末幀，避免用drag位移冒充fling。只採ballistic的歷史48.4842px峰值仍保留，但完整drag+fling峰值應讀203.3876px，低於300px。兩速position全段峰值40／120px，符合2500／7500px/s在16ms內的物理位移。見 drag-and-fling.log；最終全量亦會執行這版探針。

### 最終驗收結果（完成代碼）

在 `app/`，使用原 SDK，設定 `XDG_CONFIG_HOME=/private/tmp/renderx-worker4-config`，執行：

```sh
/Users/zaber/development/flutter/bin/flutter --suppress-analytics test
/Users/zaber/development/flutter/bin/flutter --suppress-analytics analyze
/Users/zaber/development/flutter/bin/flutter --suppress-analytics build web
```

三者退出碼均0。真實輸出：

```text
03:42 +801: All tests passed!
No issues found! (ran in 1.1s)
Compiling lib/main.dart for the Web...                             17.2s
✓ Built build/web
```

完整原始輸出：[final-test.log](renderx-evidence/final-test.log)、[final-analyze.log](renderx-evidence/final-analyze.log)、[build-web-final.log](renderx-evidence/build-web-final.log)。工具版本：[toolchain.log](renderx-evidence/toolchain.log)，Flutter3.47.7／Dart3.13.5／Darwin arm64。

| 最終完整回歸量測 | 2500px/s | 7500px/s | 鎖定上限 |
|---|---:|---:|---:|
| drag＋fling採樣幀數 | 70 | 70 | 全程採樣 |
| 每幀所有widget rebuild峰值 | 63 | 121 | 留原始數字 |
| 每幀EntryView rebuild峰值 | 1 | 2 | 每幀 ≤ onstage×1.5 |
| 整次pump CPU壁鐘峰值 | 3845µs | 9084µs | <16667µs |
| 單幀position峰值 | 40px | 120px | <50／130px |
| 單幀extent峰值 | 203.3876px | 203.3876px | <300px |
| viewport殘留placeholder | 0 | 0 | 每一幀禁止 |

其他最終數字：200重行 cold first 36ms（cap100）、既有shell內 cold session可互動276ms（cap300且真m199已built）；settled漂移≤0.001px；穩定row內部paint=0，穩定markdown rebuild=0；late image active120px／idle208px；300幀長拖動零強制anchor跳動，idle最新一次執行。最終 `git diff --check` 退出0，API與serve.py diff空白。793項既有測試全部保留，加8項=801；沒有commit／push。

本輪完成VM範圍的修復、客觀儀器與全量驗收；CanvasKit真trace／實機GPU按上方分工移交驗收方，不能由此推斷已量得裝置級零掉幀。最後另執行使用者指定done marker，結果續記如下。

### 完成標記受權限阻擋（不可假稱已收工）

最終驗收通過後，確實執行 `touch /Users/zaber/.hermes/logs/renderx.done`，退出碼1：

```text
touch: /Users/zaber/.hermes/logs/renderx.done: Operation not permitted
```

該路徑不在本輪可寫根；目前 approval policy=never，不能提升權限。未改用其他位置建立假標記，也不宣稱done marker已成立。代碼／801測試／analyze／web build的上述結果有效，但使用者指定的最後檔案系統動作仍未完成。依前提衝突條款在此停止，由派工者提供該路徑寫入權限或自行執行同一touch。
