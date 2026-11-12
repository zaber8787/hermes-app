#!/bin/bash
# STATION-LANE D2：Mac 側分層判定與告警，由 Hermes cron 以 no-agent 模式
# 每分鐘跑（空 stdout 在 no-agent 是靜默回合）。
#
# 不用 set -e：ssh 與 curl 的失敗一律轉成參考值，每個分支都 exit 0，
# 因為 no_agent 模式下非零退出會被 cron 當成腳本壞掉而發錯誤告警。
# cron 環境的 PATH 不保證有 tailscale，所以一律絕對路徑。

PY=/Users/zaber/hermes-app/.venv-web/bin/python3
LIB=/Users/zaber/hermes-app/web/ops/station_watch_lib.py
TS=/Applications/Tailscale.app/Contents/MacOS/tailscale
NTFY=http://100.81.24.33:8090/hermes
STATE=${STATION_WATCH_STATE:-/tmp/hermes-station-watch.last}

if curl -s -f -o /dev/null -m 4 http://127.0.0.1:8700/healthz; then
    lok=1
else
    lok=0
fi
if curl -s -f -o /dev/null -m 4 http://127.0.0.1:8642/health; then
    gok=1
else
    gok=0
fi

if [ -n "${STATION_WATCH_TSNET_CMD+x}" ]; then
    # 刻意不加引號、不用 eval：eval 與 bash -c 會讓測試用的
    # echo {"ts":N,"ok":true} 被 brace expansion 拆掉，不再是 JSON。
    tline=$($STATION_WATCH_TSNET_CMD 2>/dev/null)
    trc=$?
else
    tline=$(ssh -o BatchMode=yes -o ConnectTimeout=5 zaber@100.82.116.119 \
        'tail -n 1 ~/station-probe.jsonl' 2>/dev/null)
    trc=$?
fi

pjson=$("$TS" status --json 2>/dev/null)
decided=$(printf '%s' "$pjson" | "$PY" "$LIB" \
    --local "$lok" --gateway "$gok" --tsnet-rc "$trc" \
    "--tsnet-line=$tline" --state "$STATE" 2>/dev/null)
verdict=$(printf '%s\n' "$decided" | sed -n 1p)
action=$(printf '%s\n' "$decided" | sed -n 2p)
summary=$(printf '%s\n' "$decided" | sed -n 3p)

if [ -z "$verdict" ]; then
    echo "WATCH-ERROR decider produced no verdict"
    exit 0
fi

# OK 之外一律印一行（PLAN C1：PROBE-STALE 也印，否則探針斷線是永久盲點，
# 且驗收閘 5 要求 stdout 含 PROBE-STALE）。
if [ "$verdict" != OK ]; then
    echo "$verdict $summary"
fi

if [ "$action" = alert ] || [ "$action" = recover ]; then
    if [ "${STATION_WATCH_NTFY:-1}" != 0 ]; then
        if [ "$action" = recover ]; then
            title="[站點] 恢復"
        else
            title="[站點] $verdict"
        fi
        # ntfy 只監本機自己的 tailnet IP，L1 壞掉時可能一起送不出去；
        # 送不出去就把同一行丟到 stdout，讓 cron 的 no-agent 投遞兼作備援。
        curl -s -f -o /dev/null -m 10 -H "Title: $title" "$NTFY" \
            -d "$summary" \
            || echo "NTFY-FAIL $verdict $summary"
    fi
fi
exit 0
