# Hermes App

繁體中文版：[README.zh-TW.md](README.zh-TW.md)。

A Flutter app for Android and Web: browse existing sessions, read history in brief or full detail, chat over streaming, stop or steer mid-turn, with skill autocomplete. The API contract is whatever the repository layer and the `web/test_*.py` cases implement; this app never creates sessions. The UI ships bilingual — English by default, Traditional Chinese one toggle away.

It is a **client plus a server-side compatibility layer**: the app lives in `app/` in this repo, and the Hermes host should install the bundled `hermes-app-compat` user plugin (`compat/`, see the section below). The app works without it, but large-file uploads, attachment downloads, tool approval cards and live cross-device sync degrade.

## Features

- Session list: full offset paging, chronological sort, local read state, pull to refresh, health indicator
- Chat: SSE streaming, tool/narration/system event projection, Markdown with code copy, images and attachments
- Control: stop, steer mid-turn in detail mode, skill autocomplete
- UI language: English / Traditional Chinese, switched in Settings, applied instantly and persisted
- Settings: server URL and API key entered by the user; the key lives only in on-device secure storage

## Configuration (single env source)

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

## Build and test

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

## Hermes-side compatibility layer (hermes-app-compat, recommended)

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

## Producing a public snapshot

```bash
bash scripts/export_public.sh
```

Produces a clean public snapshot directory by a derivation algorithm: take the tracked-and-not-ignored file set, reject symlinks/submodules/private-purpose paths, require the mandatory files (LICENSE included), byte-copy regular files into a fresh staging dir, verify the staging content equals the set exactly and carries no `.git`, and only then pass `python3 tools/hygiene_gate.py --export` and print `EXPORT-OK` with the path. Publish that directory; publish no Git history. Gate rules live in `tools/hygiene_gate.py` plus `tools/hygiene_patterns.json` (known private strings stored as hashes only); regression canary: `python3 tools/test_hygiene_gate.py`.

## Architecture

**Riverpod** because providers inject the repository and local store so API, controllers and widgets test separately: settings via `NotifierProvider`, lists/compatibility/skills via `FutureProvider`, one streaming controller per session via `ChangeNotifierProvider.family`. No code generation.

- `app/lib/api/`: one repository function per endpoint in use; `dart:io HttpClient` handles bearer auth, connect/read timeouts, and refusing to follow redirects with the key; hand-written SSE parser, no third-party SSE package.
- `app/lib/models/`: data parsing, final-reply determination, narration/tool/system event projection, ID dedup and skills rewriting.
- `app/lib/features/`: sessions (list with health indicators), chat (latest page first, page upward, merge with dedup, brief/detail preference stored locally), settings (URL and UI preferences via SharedPreferences; the key via flutter_secure_storage only, app backup disabled on Android).

## Streaming and disconnect semantics

`run.started` saves `session_id/run_id`; `assistant.delta` renders immediately but is clearly marked as unconfirmed streaming content, `assistant.completed` overwrites tentative text, and the persisted history is re-read at the end for dedup. Stop persists its own requested/accepted record first; even if the server ultimately reports `completed` with `interrupted=false`, the UI keeps "stopped by you". Detail mode allows steering; `/stop` and `/steer ...` go through control endpoints; `/model` and `/approve` are unsupported and never disguised as text sent to the model.

The contract offers no SSE replay URL, cursor or chat idempotency guarantee, so after a disconnect the app reconnects with backoff to `GET .../messages` and reconciles against history — never re-POSTing the chat message. When the state can't be confirmed it stays visibly uncertain, keeps the draft, and lets the user re-check. This is history-data reconciliation, not a claim of lossless SSE resume.

## Test coverage

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

## Limitations

- Anything depending on actual server capabilities (artifact upload/download, etc.) defers to the server; when disabled the app says why instead of pretending success.
- Stream persistence after backgrounding/lock is bound by platform limits; disconnects fall back to history reconciliation. A stuck recovery check has a persisted budget, so the input can never stay locked forever.
- Mobile secure storage, private-network reachability and touch interactions need acceptance on real Android hardware.
