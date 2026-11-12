# web/ops：站點 ts.net 入口間歇失聯的儀表與分層告警（STATION-LANE）

`https://bot.tail592d86.ts.net` 偶爾整個連不上、過一下自己好。日誌是請求驅動的，
請求死在 tailscaled 之前時 serve.py 一行都不留，所以無法區分是哪一層壞。這裡的
三個探測點把三層拉開，讓下次發生時自動留下證據。

## 三個探測點各自能證明與無法證明什麼

| 探測點 | 位置 | 能證明 | 無法證明 |
| --- | --- | --- | --- |
| `station-probe.py`（D1） | zaber-2，從站外打 ts.net | L1：tailnet／tailscale serve 到本機入口这一段壞過，留下帶時間戳的失敗行 | 站內其他機器對入口的感覺；serve.py 內部細節 |
| `/healthz`＋heartbeat／`/metricsz`（D4） | Mac 本機 8700 | L2：serve.py 事件迴圈落後量（lag）、在途請求數、drainer 數、大串流佔用（bigslots）。卡住時 lag 會暴衝而進程看起來活著 | tailscaled、TLS、DERP |
| gateway `/health`（8642） | Mac 本機 | L3：上游反代目標死不死 | 反代路徑之外的任何事 |

判定順序（`station_watch_lib.py` 的 `verdict()`）：local 壞→`SERVE`，gateway 壞→
`UPSTREAM`，探針來源是 ssh 失敗或超過 180 秒沒更新→`PROBE-STALE`，探針 ok=false→
`TAILNET`，否則 `OK`。

## zaber-2 側安裝（探針 D1）

```sh
scp web/ops/station-probe.py zaber@100.82.116.119:bin/
```

並在 zaber-2 上加一行 crontab，每分鐘執行一次：

```cron
* * * * * /usr/bin/python3 bin/station-probe.py >/dev/null 2>&1
```

探針永不非零退出；輸出逐行 append 到 `~/station-probe.jsonl`，超過 2MB 單層輪替成
`.1`。實測 zaber-2 目前 CurAddr 為空、走 hkg 中繼端，所以「走中繼」本身不告警，
只有探針失敗才算 L1。

## Mac 側建檔（判定 D2，主 Agent 落地）

先複製腳本（cron 只收 `~/.hermes/scripts/` 底下的相對路徑，symlink 會被先
resolve 再擋）：

```sh
cp web/ops/station-watch.sh ~/.hermes/scripts/
```

再建檔：

```sh
hermes cron create "every 1m" --name station-watch --script station-watch.sh --no-agent --deliver local
```

`--monitor-script` 與 `--no-agent` 互斥；「空輸出靜默」是 `--no-agent` 的語意。
cron 環境 PATH 不保證有 tailscale 與 venv python，所以腳本內一律絕對路徑
（`/Users/zaber/hermes-app/.venv-web/bin/python3`、
`/Users/zaber/hermes-app/web/ops/station_watch_lib.py`、
`/Applications/Tailscale.app/Contents/MacOS/tailscale`）。

三個測試用環境覆寫：`STATION_WATCH_TSNET_CMD`（整段取代 ssh 取探針行）、
`STATION_WATCH_NTFY=0`（跳過發送）、`STATION_WATCH_STATE`（狀態檔路徑）。
serve.py 側 `HERMES_WEB_HEARTBEAT=0` 同時關掉心跳 task、middleware 計數與
`/metricsz`（回 404）；開關直讀 `os.environ`，刻意不進 `_ALLOW` 白名單。

## 已知盲點（照實寫，不是待辦）

- **`--deliver local` 下 stdout 不投遞。** `hermes cron list` 看得到 last_output，
  但不會送到任何人。因此 ntfy 送不出去時印出的 `NTFY-FAIL` 只是留給事後翻查，
  不是即時備援；要即時就把建檔改用真實通道（如 `--deliver telegram`）。
- **ntfy 只監 `100.81.24.33:8090`，那是本機自己的 tailnet IP。** tailscaled
  停擺時告警通道可能一起失效，這是 L1 告警的固有盲點。
- **PROBE-STALE 每分鐘印一行**（zaber-2 的 cron 掛掉期間）。選擇印出而不是靜默：
  探針失效若完全無訊號會變永久盲點。恢復探針更新後自動安靜。

## 人工排查台階

1. 先看 ntfy 有無 `[站點]` 告警（verdict 直接點名層）。
2. `launchctl list | grep hermes-web`：LaunchAgent 在不在、退出碼。
3. `/Applications/Tailscale.app/Contents/MacOS/tailscale serve status`：serve 規則還在不在。
4. `/Applications/Tailscale.app/Contents/MacOS/tailscale status`：zaber-2 peer 直連與否、有無中繼跳動。
5. `curl -s http://127.0.0.1:8700/metricsz` 與 `grep heartbeat ~/Library/Logs/hermes-web.log | tail`：
   看 lag 與 inflight；lag 大代表 L2 事件迴圈卡過。
