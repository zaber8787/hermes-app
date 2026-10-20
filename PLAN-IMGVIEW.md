# IMGVIEW 實作計畫

現況已覆核：MessageImage 的 data URL/HTTP 有單圖點開，但只有 data URL 可下載；ServerPathImage → MessageImageMemory 是不可互動原圖。故前提是部分缺漏，仍需補齊。

使用同一全螢幕 viewer，PageView 左右滑動同則訊息圖片，標示頁碼並提供前後鈕；系統返回與 AppBar 返回可關閉。每頁單擊在 1x/2x 間切換，InteractiveViewer 可縮放，垂直 ScrollView 可閱讀長圖。下載鈕有 busy、成功/取消/失敗回饋，可注入假下載器。

來源：data URL 沿用解碼快取；伺服器路徑沿用 repository.downloadServerFile 的認證與 lifecycle Future；附件 ID 沿用 downloadAttachment；HTTP URL 僅同 origin 才附認證，外站不帶金鑰。避免將認證 URL 交給新分頁，下載實際 bytes。

依賴：既有 flutter、http、file_picker、path_provider、url_launcher、web、photo_manager；不新增。web 沿用 Blob + download anchor，避免新分頁無認證且不能可靠下載；跨站 HTTP 仍受瀏覽器 CORS 限制，失敗會顯示回饋。Android/桌面沿用 FilePicker.saveFile 原生目的地選擇，可選下載目錄，無需新增儲存權限或重依賴。

驗證：新增 widget 測試覆蓋縮圖開啟、多圖切換、假下載器；只執行格式與靜態分析，不執行 flutter test（由主 agent 全套驗收）。不 commit、不修改 Python。
