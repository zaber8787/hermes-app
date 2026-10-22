# TASK-RENDERX: 渲染质量全面扫描与一次性修复

你是被派来**独立**完成这个任务的工程师，没有人在中途回答问题。SCAN → FIX → 全量回归 → REPORT 一口气跑完再收工。停在「計畫」或回來問問題視為未完成。任務文件條款是唯一權威。

## 目標（altitude：這不是「修一個 bug」）

讓 hermes-app（Flutter，web + Android 雙端）在**長 session 瀏覽的一切渲染表現達到感知上完全順滑**：上下滾動、fling、回到底端、圖載入、ExpansionTile 收合、分頁加載、session 切換——沒有一帧肉眼可見的跳動、閃爍、空白閃假人、卡頓。這不是口號，下面有可測量的定義。卡頓是 bug，跳動是 bug，「大概順」不是完成。

這些目標完全可達，Flutter 就是為這個 performance budget 設計的；如果某個目標你暫時做不到，那是你還沒找到方法，繼續挖。

## 第 0 步：先把專業清單寫出來（寫進你的 REPORT，再動工）

在碰任何代碼前，於 `docs/RENDER-AUDIT.md` 開頭回答四題——一個頂尖的 Flutter 渲染性能工程師接到這個任務會做而本文件**沒有**要求的事是什麼？他手上最生猛的材料是什麼（不是別人消化過的摘要）？他會用的具體方法與儀器？除了你和我，什麼東西能證明結果是對的？把答案列出來，然後把你能落地的全部落地。

## 儀器（不许用眼睛代替儀器）

最少建立/使用這些量測工具，全部做成可在 CI（flutter test）裡跑的斷言，放在 `app/test/renderx_instruments/` 或倉庫內合適位置：

1. **每幀 rebuild 計數器**：掛進 Element/RenderObject（`debugPrintRebuildDirtyWidgets` / `debugPrintLayouts` 或自建 counter hook），在滾動模擬中量「每幀 rebuild 的 widget 數」。onstage 行以外不該被 rebuild。
2. **frame timeline**：`flutter test --help` 之外的真儀器——用 `flutter build web` + headless Chrome 的 trace（`--enable-gpu-rasterization --trace-to-file` 之類，你自己找出本機跑得通的鏈路；工具裝在倉庫內或 /tmp，別動系統目錄），量真實的 scroll 場景掉幀。做不到真 trace 就用 (1) 的計數器 + Stopwatch 逐幀 build 成本，但要說明取捨。
3. **滾動位置穩定性斷言**（參考 `app/test/scrollfix_jank_test.dart` / `scrollfix_motion_test.dart` 現有 5 支探針，擴展而不是重寫）：settle 後零漂移、extent 震盪上限、fling 軌跡無瞬移、viewport 內無殘留假人、anchor 收斂無振盪。
4. **Repaint 邊界檢查**：用 `debugRepaintRainbowEnabled` 的等價物（計數 `RepaintBoundary` 命中率/`needsPaint`）證明流式輸出與動畫不會整頁重繪。

## 修復標準（挑釁性指標；全部視為合理可達）

- 200 行重 history：冷開到可交互 < 300ms（測試環境量，現 P1 pin 是 1200ms——把 cap 降到你能達到的最低並鎖進測試）。
- 滾動模擬（现有 motion 探針的 drag+fling）中，單幀 position 位移不得超過物理速度上限（探針已有），單幀 maxScrollExtent 變化 < 300px。
- 滾動时每幀被 rebuild 的行數 ≤ onstage 行數 × 1.5（計數器量，鎖進測試）。
- 圖片/late-landing 內容導致的行高變化只能落在 viewport 之外或 scroll-idle 時（探針證明）。
- 你掃出的其他問題自定指標，寫進 REPORT。

## 假設對抗（ adversarial check，逐條用數據覆核或推翻）

前一位工程師留下這些斷言，**不要相信它們**，用儀器重驗：

1. `_extentMemory`（page 級 keyValue→實測高）讓已讀區幾何穩定——驗證記憶值與真實高一致（圖片載入後、ExpansionTile 收合後會過時嗎？）。
2. `_LazyRow._near()` 的 viewport×2 窗口足够跟上 fling 速度——fling 峰值速度下會不會仍有帶狀假人來得及在視窗內才落地？
3. refine loop 的 `isScrollingNotifier` 等待不會餓死（等不到 scroll end 的場景：無敵直拖、程序性連环 jumpTo）。
4. OPENPERF P1/P3/P4 契約測試鎖的行為與真實 web (CanvasKit) 行為一致性——contract 綠不代表 web 不閃（web 上 SliverList 惰性、字體度量都不同；至少把能跑的契約在 `flutter test --platform chrome` 下跑一遍，跑不動就寫清楚為什麼）。
5. `cachedServerFile` 的 30s 失敗冷卻不會讓「檔案剛好」的圖永远黑著。
6. 你自己找出前一位工程師沒說出口的假設，加進這張表。

## 跨域借鑑（range）

用其他領域的成熟方案對照你的修法：UITableView/UICollectionView 的 cell 高度回收與 content offset compensation、RecyclerView 的 `stackFromEnd/anchor` 錨定算法、瀏覽器 scroll anchoring（overflow-anchor）算法、遊戲引擎的 frame budget / time slicing。REPORT 裡至少三處要寫出「某领域怎麼做 → 我們對應怎麼做 → 差異在哪」。

## 邊界（硬規則）

- 不 commit、不 push、不動 git 歷史。改動留在工作區，`touch` done marker 即收工。
- 現有測試（793 支）**一支都不許刪**；可以改，但每改一支要在 REPORT 寫理由。
- 不碰 `~/hermes-app/web/serve.py` 的 ARTIFACT-PERSIST 路由與 `app/lib/api/` 的網路契約（另一條戰線剛定案）；發現相關 bug 記進 REPORT 的「移交項」，別顺手改。
- 安裝任何工具只能進倉庫目錄或 /tmp。
- 全量回归 = `flutter test` 全綠 + `flutter analyze` 零問題，貼出真實輸出。

## 交付物

1. 代碼修復（掃出的每個問題都要有對應修復或「不修的理由比修的理由強」的書面論證）。
2. 新測試：每個修復一條客觀斷言（外部裁判條款：你的「看起來順了」不算數）。
3. `docs/RENDER-AUDIT.md`：問題總表（症狀/證據數字/根因/修法/驗證數字）、假設對抗結果、跨域對照、移交項。

## 續派說明（2026-10-22，worker #1 因沙箱無本地 socket 權限停止後）

- 沙箱已開 `network_access=true`，`flutter test` 的 flutter_tester vm-service socket 現行得通。你（worker #2）先跑一次全量基線確認量測鏈可用，再進行正題。`docs/renderx-evidence/baseline.log` 與 `docs/RENDER-AUDIT.md` 的既有內容是 worker #1 的誠實紀錄，保留並續寫。
- worker #1 已經替你標出兩個真問題，直接列進問題總表並修復：
  1. `app/test/scrollfix_motion_test.dart` fling 探針的 `maxStep` 每輪迴圈覆寫而不是取全域最大——探針自我虛偽，先讓它對舊實作會紅。
  2. `_LazyRow` 的高度記憶只在 build/idle 報，子樹自身 layout 變化（圖片落地於深處）沒有觀察點。

## 續派說明 #2（worker #3）

- 前兩輪的「沙箱禁止」真相：flutter 每次啟動會重寫 SDK 自己的 `bin/cache/engine.stamp`／`engine.realm`，沙箱原本唯讀擋掉。**SDK cache 已加入沙箱可寫根**，直接用 `~/development/flutter/bin/flutter`，worker #2 複製到 /private/tmp/renderx-flutter 的 SDK 副本作廢（別再用它，也別再複製）。
- 若 chrome 契約（`--platform chrome`）仍起不來，用 `CHROME_EXECUTABLE` 指向本機存在的瀏覽器試一次；環境真的沒有 Chrome 就把「web 端驗證由驗收方（派工者）在真瀏覽器執行」寫成明確分工放進 REPORT，其餘量測照常在 VM target 做，不准因此停整个任務。
- 本輪是第三次派工，同一個環境借口不接受第二次：環境問題已由派工者修到底，剩下純代碼與方法問題。完成它。

## 續派說明 #3（worker #4）

- `~/.dart-tool`（Flutter telemetry 日誌目錄）已加入沙箱可寫根——這輪 analyze 應該能跑通。這是派工者第四次修環境地板，探測已驗證（沙箱內 append 該目錄 exit=0）。
- 本輪起點：`flutter test` 與 `flutter analyze` 兩條基線都要綠跑並把輸出存進 docs/renderx-evidence/，開工 20 分鐘內做不到就代表仍有環境問題——那就改用最原始手段（直接逐檔 flutter test 分塊跑）繼續推進任務，不准再次以環境為由停工。任務的代碼部分還一行都還沒開始。
