# Hermes App

繁體中文版在下方，English version below.

---

## 繁體中文

Android／Web 的 Flutter app：瀏覽既有 session、看詳略歷史、串流聊天、停止／插話與 skill autocomplete。API 行為以 repository 實作與 `web/test_*.py` 案例為準；本 app 不新建 session。介面內建英文／繁體中文切換，預設英文。

這是一個**客戶端＋服務端相容層**的組合：app 端在本 repo 的 `app/`，Hermes 主機端建議裝本 repo 附帶的 `hermes-app-compat` user plugin（`compat/`，見下方「Hermes 端相容層」）。只裝 app 也能跑，但大檔上傳、附件下載、審核卡與即時跨裝置同步會退化。

### 功能

- Session 列表：offset 拉完、時間排序、本地已讀、下拉刷新、health 指示
- 聊天：SSE 串流顯示、工具／旁白／系統事件投影、Markdown 與程式碼複製、圖片與附件
- 控制：停止、詳細模式插話（steer）、skill autocomplete
- 介面語言：英文／繁體中文，設定頁切換、即時生效並持久化
- 設定頁：Server URL 與 API key 由使用者填入；key 只存裝置端 secure storage

### 設定（唯一的 env 來源）

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

### Build 與測試

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

### Hermes 端相容層（hermes-app-compat，建議安裝）

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

### 產生公開快照

```bash
bash scripts/export_public.sh
```

依導出演算法產生乾淨的公開快照目錄：取「已追蹤且未被 ignore」的檔案集合，拒絕 symlink／submodule／私有用途路徑，要求必要檔案（含 LICENSE）存在，把普通檔案逐字節複製到新的暫存目錄，驗證暫存內容與集合完全相同且不含 `.git`，最後通過 `python3 tools/hygiene_gate.py --export` 才輸出 `EXPORT-OK` 與目錄路徑。發佈該目錄的內容即可；不發佈任何 Git 歷史。gate 規則在 `tools/hygiene_gate.py` ＋ `tools/hygiene_patterns.json`（已知私有字串只存雜湊），回歸 canary 自測：`python3 tools/test_hygiene_gate.py`。

### 限制

- 依賴 server 實際 capabilities 的功能（如 artifacts 上下載）以 server 為準；未啟用時 app 顯示原因而不是假成功。
- 背景／鎖屏後的串流持續性受平台限制，斷線以歷史比對兜底；卡住的復原核對有持久化上限，不會永久鎖輸入。
- 手機端的 secure storage、私人網路連通性與觸控互動需在 Android 實機上驗收。

---

## English

A Flutter app for Android and Web: browse existing sessions, read history in brief or full detail, chat over streaming, stop or steer mid-turn, with skill autocomplete. The API contract is whatever the repository layer and the `web/test_*.py` cases implement; this app never creates sessions. The UI ships bilingual — English by default, Traditional Chinese one toggle away.

It is a **client plus a server-side compatibility layer**: the app lives in `app/` in this repo, and the Hermes host should install the bundled `hermes-app-compat` user plugin (`compat/`, see the section below). The app works without it, but large-file uploads, attachment downloads, tool approval cards and live cross-device sync degrade.

### Features

- Session list: full offset paging, chronological sort, local read state, pull to refresh, health indicator
- Chat: SSE streaming, tool/narration/system event projection, Markdown with code copy, images and attachments
- Control: stop, steer mid-turn in detail mode, skill autocomplete
- UI language: English / Traditional Chinese, switched in Settings, applied instantly and persisted
- Settings: server URL and API key entered by the user; the key lives only in on-device secure storage

### Configuration (single env source)

All non-secret settings and build defines come from one dotenv file: `~/.hermes/.env` (override the path with `HERMES_ENV_FILE`). Merge the fields from `.env.example` into your own file rather than overwriting existing config. `API_SERVER_KEY` is read from that file at runtime only — it never enters the APK, the web bundle, `--dart-define` or process env.

| Variable | Purpose | When unset |
|---|---|---|
| `HERMES_APP_DEFAULT_URL` | factory URL of the personal APK (build define) | personal build fails outright; public build stays empty |
| `HERMES_APP_LEGACY_URL` | exact legacy-URL migration (personal only) | no migration |
| `HERMES_LIVE_BASE_URL` | gateway address for live tools/probes | live tools fail before any network request |
| `HERMES_WEB_API` / `HERMES_WEB_HOST` / `HERMES_WEB_PORT` | reverse proxy upstream / bind / port | loopback `127.0.0.1:8700` → `http://127.0.0.1:8642`; no public interface by default |
| `HERMES_WEB_ROOT` / `HERMES_WEB_HOME` | static root / memories home | `web/current` in the repo / `~/.hermes` |
| `HERMES_PROXY_MAX_BODY` / `HERMES_PROXY_BIG_SLOTS` | upload cap / big-file concurrency | 600 MiB / 2 |

`python3 web/serve.py --check-config [--require-auth-key]` validates the config before anything binds (names and sources only, keys never printed). Startup also logs the effective config and where each value came from.

### Build and test

Run everything from the repo root; only `flutter`/`dart` commands go inside `app/`.

```bash
python3 scripts/install_toolchain.py     # installs Flutter/Android SDK/JDK into toolchain/
source scripts/env.sh
bash scripts/build_app.sh --target apk --mode debug   --profile personal  # personal: injects your URL
bash scripts/build_app.sh --target apk --mode release --profile public    # public: env never opened, defines empty
bash scripts/build_app.sh --target web --mode release --profile public
bash scripts/run-tests-detached.sh       # full per-file flutter test sweep

cd app
flutter pub get
flutter analyze
flutter test                             # single files / debugging; use the script above for full sweeps
```

`--profile` is required, no default. `--profile public` never opens the env file, same-named variables from the outer environment are ignored, and both URL defines are explicitly empty — a fresh install lands on the Settings page and makes zero requests until you enter your own server. Bare `flutter build` still works but behaves like a public empty build; it does not count as personal acceptance.

The whole toolchain lives in `toolchain/` (never in Git): the installer checks free disk space, downloads with timeouts and retries, verifies checksums for Flutter and the command-line tools, and unpacks a JDK from the distro repo into `toolchain/jdk/` when the system has none, without touching system packages. Gradle heap and concurrency are capped; Gradle may still fetch required components itself. The APK lands in `app/build/app/outputs/flutter-apk/`, installable on a test device via `adb install -r`. First launch (or any invalid setting) stops at the Settings page: enter your server URL and API key; the key is not in the source, the APK or build flags. If your server sits on a private network, join that network first.

Web publishing (copies into `web/releases/` only after a successful build, then flips `web/current` atomically): `bash web/publish.sh`; `--build-only` produces artifacts without publishing.

Official tool docs: [Flutter manual install](https://docs.flutter.dev/install/manual), [Android sdkmanager](https://developer.android.com/tools/sdkmanager).

### Hermes-side compatibility layer (hermes-app-compat, recommended)

`compat/` is the full source of a Hermes user plugin you install on your Hermes host so upstream behavior matches what this app needs. It monkey-patches at runtime only, never modifies Hermes sources, and survives `hermes update`. Hooks are pinned to specific upstream commits — after a Hermes upgrade, run the offline probe first (details in `compat/README.md`).

```bash
bash compat/install.sh
hermes plugins enable hermes-app-compat
# then restart the gateway however you usually do
```

| Feature that depends on it | Without it |
|---|---|
| Large-file upload (raised cap) | falls back to upstream limits |
| Attachment/image download route | attachments show but cannot be fetched |
| Tool approval cards | only auto-approval, or approving from another surface |
| Live cross-device activity sync (`/activity`) | degrades to history-count polling; idle misdetection during multi-tool turns |

Everything is fail-safe: mismatched hooks skip their group with a log line, the app keeps working, and the gateway never goes red.

### Producing a public snapshot

```bash
bash scripts/export_public.sh
```

Produces a clean public snapshot directory by a derivation algorithm: take the tracked-and-not-ignored file set, reject symlinks/submodules/private-purpose paths, require the mandatory files (LICENSE included), byte-copy regular files into a fresh staging dir, verify the staging content equals the set exactly and carries no `.git`, and only then pass `python3 tools/hygiene_gate.py --export` and print `EXPORT-OK` with the path. Publish that directory; publish no Git history. Gate rules live in `tools/hygiene_gate.py` plus `tools/hygiene_patterns.json` (known private strings stored as hashes only); regression canary: `python3 tools/test_hygiene_gate.py`.

### Architecture

**Riverpod** because providers inject the repository and local store so API, controllers and widgets test separately: settings via `NotifierProvider`, lists/compatibility/skills via `FutureProvider`, one streaming controller per session via `ChangeNotifierProvider.family`. No code generation.

- `app/lib/api/`: one repository function per endpoint in use; `dart:io HttpClient` handles bearer auth, connect/read timeouts, and refusing to follow redirects with the key; hand-written SSE parser, no third-party SSE package.
- `app/lib/models/`: data parsing, final-reply determination, narration/tool/system event projection, ID dedup and skills rewriting.
- `app/lib/features/`: sessions (list with health indicators), chat (latest page first, page upward, merge with dedup, brief/detail preference stored locally), settings (URL and UI preferences via SharedPreferences; the key via flutter_secure_storage only, app backup disabled on Android).

### Streaming and disconnect semantics

`run.started` saves `session_id/run_id`; `assistant.delta` renders immediately but is clearly marked as unconfirmed streaming content, `assistant.completed` overwrites tentative text, and the persisted history is re-read at the end for dedup. Stop persists its own requested/accepted record first; even if the server ultimately reports `completed` with `interrupted=false`, the UI keeps "stopped by you". Detail mode allows steering; `/stop` and `/steer ...` go through control endpoints; `/model` and `/approve` are unsupported and never disguised as text sent to the model.

The contract offers no SSE replay URL, cursor or chat idempotency guarantee, so after a disconnect the app reconnects with backoff to `GET .../messages` and reconciles against history — never re-POSTing the chat message. When the state can't be confirmed it stays visibly uncertain, keeps the draft, and lets the user re-check. This is history-data reconciliation, not a claim of lossless SSE resume.

### Test coverage

`flutter test` includes:

- Three **synthetic** session turn fixtures (synthetic IDs, fixed timestamps, no real conversations) pinning final IDs, tool-response pairing, narration and hidden rows; synthetic cases also cover the system whitelist, unknown values and multi-turn boundaries.
- SSE splitting at arbitrary UTF-8 byte/CRLF boundaries, BOM, comments, multi-line data, trailing frames, duplicate seqs, wrong sessions, completion rewind and tool.progress.
- Paging-overlap dedup verified against a local fake HTTP server, and the key never appearing in error messages.
- Explicit-stop persistence, read-only reconnect after disconnect with a backoff cap, slash/control command routing, plus widget tests for the settings page and hidden events.

A real-device integration walkthrough (reusing the app's own repository/parser/models):

```bash
source scripts/env.sh
cd app
HERMES_ENV_FILE="$HOME/.hermes/.env" dart run tool/integration_walkthrough.dart
```

It reads the key from a local file (never printed), touches only the scratch session it created, deletes it at the end and confirms 404; output goes to `logs/` (gitignored per repo rules). Integration output and probe results are private evidence — desensitize before turning them into fixtures or public summaries.

### Limitations

- Anything depending on actual server capabilities (artifact upload/download, etc.) defers to the server; when disabled the app says why instead of pretending success.
- Stream persistence after backgrounding/lock is bound by platform limits; disconnects fall back to history reconciliation. A stuck recovery check has a persisted budget, so the input can never stay locked forever.
- Mobile secure storage, private-network reachability and touch interactions need acceptance on real Android hardware.
