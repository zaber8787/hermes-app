# 部署目錄 vs repo 對帳（TASK-PLUGINSYNC）

盤點時間 2026-11-01。部署目錄 `~/.hermes/plugins/hermes-app-compat/`，repo 端 `compat/`（HEAD `485f944`）。動檔前整目錄備份為 `~/.hermes/plugins/.hermes-app-compat.bak-pluginsync/hermes-app-compat-20261101-pre-pluginsync.tar.gz`。備份刻意做成 tarball，因為 `hermes_cli/plugins_discovery.py` 的 `scan_directory` 只略過 dunder 目錄，不略過點開頭的目錄，展開的複本會帶著第二份 `plugin.yaml` 被掃到。

## 原始差異

```
$ diff -rq -x __pycache__ compat ~/.hermes/plugins/hermes-app-compat
Files compat/README.md and /Users/zaber/.hermes/plugins/hermes-app-compat/README.md differ
Files compat/compat.py and /Users/zaber/.hermes/plugins/hermes-app-compat/compat.py differ
Only in /Users/zaber/.hermes/plugins/hermes-app-compat: patch_clarify.py
Only in /Users/zaber/.hermes/plugins/hermes-app-compat: patch_dupguard.py
Only in /Users/zaber/.hermes/plugins/hermes-app-compat: tests
Only in /Users/zaber/.hermes/plugins/hermes-app-compat: verify_v022_seams.py
```

其餘 20 個檔兩邊位元組相同。`compat.py` 的 diff 在 hunk 標頭上只有 `12c12`、`36c36`、`346a347,355`、`742a752,756`、`4611a4626,4838`，兩個 `c` 都是在原行尾端追加（`closing` import 與 UNITS 加上 `"media_persist", "clarify"`），所以部署版是 repo 版的純增量，沒有任何 repo 端內容被部署端覆寫掉。README 也是純增量（新增 `### MEDIA persistence` 一節）。

## 游離項目逐條

| 項目 | 部署 mtime | 來源推定 | 被誰 import / 呼叫 | 開關與現況 |
|---|---|---|---|---|
| `patch_dupguard.py` | 2026-10-25 22:35 | 檔頭自述 DUPGUARD (2026-10-25)，修送出端裝置 tool step 顯示兩次 | `compat.py:347-355`，在 `install()` 內以 `from . import patch_dupguard` 載入，每次 plugin 載入都跑，例外只記 warning | 無開關。gateway.log `2026-11-01 03:11:02 DUPGUARD: message double-write triggers active`，已證實生效中 |
| `patch_clarify.py` | 2026-10-27 15:11 | clarify 表單 API（`/v1/sessions/{sid}/clarify`），對應 app 端 `app/lib/features/chat/clarify_inbox.dart` | `compat.py:754-756` 的 `_install_clarify`，由 `compat.py:395` 的 UNITS 迴圈以 `globals()["_install_" + unit]` 呼叫 | 無設定開關，seam 不符時走 `skipped_incompatible`。gateway log 找不到 clarify 被跳過的紀錄，因此推論為已套用，尚未從 manifest 實測 |
| `compat.py` media_persist 段 | 2026-10-27 15:10（整檔） | README 新增節所述的 MEDIA 持久化 contract 1 | `compat.py:4737` `_install_media_persist`，同樣由 UNITS 迴圈呼叫；`tests/test_media_persist.py` 以路徑載入 `compat.py` | `app_compat.media_persist.enabled`，預設 true（`compat.py:4633-4642`）；`~/.hermes/config.yaml` 沒有這個區塊，所以設定上是開的。但 gateway.log `2026-11-01 03:11:02 media_persist skipped_incompatible: cron bridge backend not reviewed for this source`，`_cron_fingerprint`（`compat.py:259-263`）因 backend 不在 reviewed 表而拒絕，已證實目前生產上未生效 |
| `README.md` 新增節 | 2026-10-24 02:04 | 與 media_persist 同批 | 文件 | 無 |
| `tests/test_media_persist.py`、`tests/run_media_persist_offline.py`、`tests/media_persist_results.txt` | 2026-10-24 | 與 media_persist 同批的驗證；results.txt 是 offline adapter 的一次執行輸出 | 測試，不被 plugin import | 無 |
| `tests/test_clarify_bridge.py` | 2026-10-27 15:11 | 與 patch_clarify 同批 | 測試，需 hermes-agent 的 `tools.clarify_gateway` | 無 |
| `verify_v022_seams.py` | 2026-10-17 14:22 | v022 backend 審查時的離線 fingerprint 驗證腳本 | 不被任何模組 import；獨立執行，唯讀讀取 `compat.py` 與 `/Users/zaber/.hermes/hermes-agent` 原始碼 | 無 |

## 收檔結果

全部項目都以原樣搬入 `compat/`，位置對應部署目錄的相對路徑，所以 repo 不需要額外的 import 改寫就能重建部署目錄。`compat.py` 與 `README.md` 直接採用部署版（純增量，見上）。唯一的接線改動是 `compat/install.sh` 的檔案清單補上 `patch_clarify.py` 與 `patch_dupguard.py`，否則舊安裝路徑重建出來的部署會缺這兩個模組，`compat.py:351` 的 dupguard 會降級成 warning，clarify unit 會整個 `skipped_incompatible`。

沒有任何補丁的行為語義被改動，也沒有項目被列為待決。有兩點留給後續判斷，但不在本任務範圍：

- media_persist 目前在生產上被 fingerprint 閘門擋下，收進版控不會改變這件事。要讓它生效需要另一棒審查新的 backend 指紋。
- `patch_dupguard.py` 檔頭與 `compat.py:347-349` 註解寫 `<plugin dir>/state.db`，實際路徑是 `get_hermes_home()/state.db`。2026-10-25 22:37 有一筆 `DUPGUARD: skipped (no such table: main.messages)`，之後已正常。註解與程式不一致，本任務不改。

## 之後的同步

一律用 `compat/tools/sync-deploy.sh`。`--check` 只比對，`--dry-run` 列出會動什麼，不帶參數會先在上述備份目錄打 tarball、rsync repo→部署、清 `__pycache__`，再自動跑一次 `--check`。部署端若出現 repo 沒有的檔，同步會在寫入任何東西之前以 exit 3 停下，必須先把檔收進 repo 或明確用 `--prune` 刪除。`compat/docs/` 與 `compat/tools/` 是 repo 專用，不部署。
