# IMGVIEW 完工報告

## 實作
- 新增共用全螢幕 MessageImageViewer：PageView、頁碼、左右切換鈕、系統/AppBar 返回、單擊 1x/2x、InteractiveViewer 縮放、長圖垂直捲動。
- 同則訊息的 MEDIA、Markdown 圖片與具圖片檔名的附件收據組成圖集；點開時定位被點的圖片。
- ServerPathImage / MessageImageMemory 現在可點開；沿用 server-path State 的 Future 與認證 repository，開啟當張已下載圖片時重用 bytes。
- data URL 保留原解碼快取、大小限制與縮圖下載；HTTP 圖片改由受控 bytes 載入，檢視器各來源皆有下載鈕。
- HTTP 僅同 origin 帶 Bearer，外站不帶金鑰；認證請求禁止自動重新導向。既有媒體/附件 API 路由透過 repository 下載，保留原驗證；一般 HTTP 有逾時及 attachmentMaxBytes 上限。
- 沿用 saveBytesAs：web Blob 下載、本機 FilePicker 目的地選擇（Android 可選下載目錄）。無新依賴、無 Python 修改、無 commit。
- 台繁版沿用既有圖片/下載文案；新增切換鈕為「上一張／下一張」。

## 驗證
- 新增 app/test/imgview_test.dart：縮圖開啟及返回、指定起始頁與滑動/箭頭切換、當頁下載呼叫注入假下載器、下載失敗後可重試。
- SDK dart format 完成；三個本任務 Dart 檔案的 Analysis Server 診斷均為空；git diff --check 通過。
- 遵守任務紅線，未執行 flutter test，因此不宣稱 widget / contract 測試已通過，交由主 agent 全套驗收。
- Flutter wrapper 與一般 dart analyze 因 sandbox 外的 SDK/分析快取寫入受限，改用既有 SDK 執行格式化、Analysis Server --cache=/tmp/imgview-dart-cache 完成靜態分析。

## 平台取捨與限制
- web 不以新分頁代替下載，避免漏認證或只開圖無法儲存；跨站 HTTP 仍需來源允許 CORS，重新導向回應及取圖失敗提供錯誤回饋。未做瀏覽器/Android 真機手動驗證。
- 本機沿用原生目的地選擇，不硬寫 Android 公共下載資料夾；使用者可取消。
- 圖集涵蓋同則訊息可辨識的 MEDIA 與一般 Markdown inline 圖片；複雜 Markdown reference 語法仍可單張開啟。
- 保留工作區既有與執行期間其他任務的變更（例如 .build-profile、STEERVIS 相關檔案），未納入本任務。
