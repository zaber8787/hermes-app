# Hermes App

English version: [README.md](README.md).

Android／Web 的 Flutter app：瀏覽既有 session、看詳略歷史、串流聊天、停止／插話與 skill autocomplete。API 行為以 repository 實作與 `web/test_*.py` 案例為準；本 app 不新建 session。介面內建英文／繁體中文切換，預設英文。

這是一個**客戶端＋服務端相容層**的組合：app 端在本 repo 的 `app/`，Hermes 主機端建議裝本 repo 附帶的 `hermes-app-compat` user plugin（`compat/`，見下方「Hermes 端相容層」）。只裝 app 也能跑，但大檔上傳、附件下載、審核卡與即時跨裝置同步會退化。

## 功能

- Session 列表：offset 拉完、時間排序、本地已讀、下拉刷新、health 指示
- 聊天：SSE 串流顯示、工具／旁白／系統事件投影、Markdown 與程式碼複製、圖片與附件
- 控制：停止、詳細模式插話（steer）、skill autocomplete
- 介面語言：英文／繁體中文，設定頁切換、即時生效並持久化
- 設定頁：Server URL 與 API key 由使用者填入；key 只存裝置端 secure storage

## 設定（唯一的 env 來源）

非機密設定與 build define 一律來自同一個 dotenv 檔：`~/.hermes/.env`（可用 `HERMES_ENV_FILE` 指定其他路徑）。把 `.env.example` 的欄位合併進你自己的檔案，不要整檔覆蓋既有設定。`API_SERVER_KEY` 只在 runtime 從該檔讀取——永遠不進 APK、Web bundle、`--dart-define` 或 process env。

| 變數 | 用途 | 未設定時 |
|---|---|---|
| `HERMES_APP_DEFAULT_URL` | personal APK 的出廠 URL（build define） | personal build 直接失敗；public build 固定空 |
| `HERMES_APP_LEGACY_URL` | 精確舊 URL 遷移（僅 personal） | 不做任何遷移 |
| `HERMES_LIVE_BASE_URL` | live tools／probe 的 gateway 位址 | live tools 在任何網路請求前失敗 |
| `HERMES_WEB_API` / `HERMES_WEB_HOST` / `HERMES_WEB_PORT` | 反代 upstream／bind／port | loopback `127.0.0.1:8700` → `http://127.0.0.1:8642`；不預設公開介面 |
| `HERMES_WEB_ROOT` / `HERMES_WEB_HOME` | 靜態根／memories 家目錄 | repo 內 `web/current`／`~/.hermes` |
| `HERMES_PROXY_MAX_BODY` / `HERMES_PROXY_BIG_SLOTS` | 上傳上限／大檔併發 | 600 MiB／2 |

`python3 web/serve.py --check-config [--require-auth-key]` 在任何 bind 前驗證設定（只列名稱與來源，不明文列 key）。啟動時也會印出生效設定與來源。

## Build 與測試

以下指令一律從 repo root 執行；只有 `flutter`／`dart` 指令在 `app/` 底下跑。

```bash
python3 scripts/install_toolchain.py     # Flutter/Android SDK/JDK 裝進 toolchain/
source scripts/env.sh
bash scripts/build_app.sh --target apk --mode debug   --profile personal  # 自用：注入自己的 URL
bash scripts/build_app.sh --target apk --mode release --profile public    # 公開：不讀 env、defines 全空
bash scripts/build_app.sh --target web --mode release --profile public
bash scripts/run-tests-detached.sh       # 完整逐檔 flutter test 掃描

cd app
flutter pub get
flutter analyze
flutter test                             # 單檔/除錯用；全量掃描請用上面的腳本
```

`--profile` 必填、無預設。`--profile public` 完全不開 env 檔、外部環境同名變數也被忽略，兩個 URL define 明確傳空——全新安裝啟動後停在設定頁、零請求，等你填自己的伺服器。裸 `flutter build` 仍可用，但等同 public 空值行為，不算 personal 驗收。

工具鏈全部放 `toolchain/`（不入 Git）：安裝器檢查可用空間、下載有 timeout 與重試、Flutter／command-line tools 驗 checksum；系統沒有可用 JDK 時從套件倉庫解壓一份到 `toolchain/jdk/`，不改系統套件。Gradle heap 與併發有上限設定，建置所需元件可能由 Gradle 自行下載。APK 輸出在 `app/build/app/outputs/flutter-apk/`，可用 `adb install -r` 安裝到測試裝置。首次啟動（或任何一項無效）停在設定頁：填入你的 Server URL 與 API key；key 不在程式碼、APK 或 build flags 中。若伺服器在私人網路，請先連上該網路。

Web 發佈（先 build 成功才放入 `web/releases/` 並原子翻 `web/current` 連結）：`bash web/publish.sh`；`--build-only` 只產物不發佈。

官方工具文件：[Flutter manual install](https://docs.flutter.dev/install/manual)、[Android sdkmanager](https://developer.android.com/tools/sdkmanager)。

## Hermes 端相容層（hermes-app-compat，建議安裝）

`compat/` 是 Hermes user plugin 的完整源碼，裝在你（操作者）的 Hermes 主機上，讓 upstream 行為對齊這個 app 的需要。它只在執行期 monkey-patch，不修改 Hermes 原始碼，`hermes update` 不會沖刷它；掛鉤綁定特定 upstream commit，Hermes 升級後請先跑離線探針驗證（`compat/README.md` 有驗證與裝法細節）。

```bash
bash compat/install.sh
hermes plugins enable hermes-app-compat
# 之後照你平时的慣例重啟 gateway
```

| 依賴它的功能 | 不裝時 |
|---|---|
| 大檔案上傳（上限放寬） | 退回 upstream 限制 |
| 附件／圖片下載路由 | 顯示附件但抓不到檔 |
| 工具審核卡 | 只能等 auto-approval 或從其他介面核准 |
| 即時跨裝置活動同步（`/activity`） | 退化為歷史計數輪詢，多工具回合期間會誤判空閒 |

全部 fail-safe：掛鉤不匹配時 skip 該群並留日誌，app 照常可用，不會讓 gateway 變紅。

## 產生公開快照

```bash
bash scripts/export_public.sh
```

依導出演算法產生乾淨的公開快照目錄：取「已追蹤且未被 ignore」的檔案集合，拒絕 symlink／submodule／私有用途路徑，要求必要檔案（含 LICENSE）存在，把普通檔案逐字節複製到新的暫存目錄，驗證暫存內容與集合完全相同且不含 `.git`，最後通過 `python3 tools/hygiene_gate.py --export` 才輸出 `EXPORT-OK` 與目錄路徑。發佈該目錄的內容即可；不發佈任何 Git 歷史。gate 規則在 `tools/hygiene_gate.py` ＋ `tools/hygiene_patterns.json`（已知私有字串只存雜湊），回歸 canary 自測：`python3 tools/test_hygiene_gate.py`。

## 架構

選 **Riverpod**：provider 注入 repository／local store，API、控制器與 widget 可各自測試；設定用 `NotifierProvider`，列表／相容性／skills 用 `FutureProvider`，每個 session 的串流控制器用 `ChangeNotifierProvider.family`，不用 code generation。

- `app/lib/api/`：每個使用中的端點各一個 repository 函數；`dart:io HttpClient` 負責 bearer auth、連線／讀取 timeout、禁止帶 key 跟隨 redirect；手寫 SSE parser，不使用第三方 SSE 套件。
- `app/lib/models/`：資料解析、最終回覆判定、旁白／工具／系統事件投影、ID 去重與 skills 改寫。
- `app/lib/features/`：sessions（列表與 health 指示）、chat（latest 頁起步、向上分頁、合併去重、詳略偏好本地儲存）、settings（URL 與 UI 偏好走 SharedPreferences；key 只用 flutter_secure_storage，Android 禁止 app backup）。

## 串流與斷線語意

`run.started` 保存 `session_id/run_id`；`assistant.delta` 即時顯示但明示為尚未確認的串流內容，`assistant.completed` 覆寫暫定文字，最後重新讀持久化歷史去重。stop 先持久化自己的 requested/accepted 紀錄；即使 server 最後回 `completed`、`interrupted=false`，UI 仍保留「由你停止」。詳細模式可插話；`/stop` 與 `/steer ...` 走控制端點；`/model`、`/approve` 不支援且不會偽裝成文字送進模型。

contract 未提供 SSE replay URL、cursor 或 chat idempotency 保證，因此斷線後以退避重連 `GET .../messages` 做**歷史比對**，不重送聊天 POST；無法確認時保留不確定狀態與草稿，由使用者再次核對。這是歷史資料重連，不宣稱支援中斷 SSE 的無損續傳。

## 測試涵蓋

`flutter test` 包含：

- 三個**合成** session turn fixtures（合成 ID 與固定時間戳記，非真實對話），核對固定 final ID、工具回應配對、旁白與 hidden；合成用例補足系統白名單／未知值與多 turn 邊界。
- SSE 任意 UTF-8 byte/CRLF 分割、BOM、comments、多行 data、尾 frame、重複 seq、錯誤 session、completion 回溯與 tool.progress。
- 分頁重疊去重、本地假 HTTP 伺服器驗證，以及 key 不出現在錯誤訊息。
- 明確停止的持久化、斷線後只讀重連與退避上限、slash／control command 路由，以及設定頁和隱藏事件的 widget 測試。

真機整合走查（使用 app 現有 repository／parser／models）：

```bash
source scripts/env.sh
cd app
HERMES_ENV_FILE="$HOME/.hermes/.env" dart run tool/integration_walkthrough.dart
```

它從本機檔案讀 key（不印出），只修改自己建立的暫定 session，結束時刪除並確認 404；輸出寫入 `logs/`（依 repo 規則不入 Git）。整合輸出與 probe 結果屬私密證據，未經脫敏不得轉為 fixtures 或公開摘要。

## 限制

- 依賴 server 實際 capabilities 的功能（如 artifacts 上下載）以 server 為準；未啟用時 app 顯示原因而不是假成功。
- 背景／鎖屏後的串流持續性受平台限制，斷線以歷史比對兜底；卡住的復原核對有持久化上限，不會永久鎖輸入。
- 手機端的 secure storage、私人網路連通性與觸控互動需在 Android 實機上驗收。
