#!/usr/bin/env python3
"""STATION-LANE D3：站點分層判定的純函式，以及 D2 殼層用的決策 CLI。

判定表（由上往下第一個成立者生效）：
    local 壞                    → SERVE
    gateway 壞                  → UPSTREAM
    tsnet 來源是 ssh-fail，或探針過舊 → PROBE-STALE
    tsnet 的 ok 為 false        → TAILNET
    以上都不成立                → OK

PROBE-STALE 對 verdict 是無狀態的：既不寫入也不清空 .last 檔，否則
TAILNET→PROBE-STALE→TAILNET 會重發告警。

CLI（由 station-watch.sh 呼叫）：stdin 讀 tailscale status --json，
stdout 恰好印三行：verdict、action（none|alert|recover）、summary。
"""
import argparse
import json
import sys
import time

STALE_SEC = 180
ZABER2_DNS = "zaber-2.tail592d86.ts.net."


def verdict(local_ok, gateway_ok, tsnet_ok, tsnet_source, probe_age_sec):
    if not local_ok:
        return "SERVE"
    if not gateway_ok:
        return "UPSTREAM"
    if (tsnet_source == "ssh-fail" or probe_age_sec is None
            or probe_age_sec > STALE_SEC):
        return "PROBE-STALE"
    if not tsnet_ok:
        return "TAILNET"
    return "OK"


def parse_tsnet(rc, line, now):
    """回 (tsnet_ok, source, age, err)。rc!=0、空行、JSON 解析失敗、
    ts 不是 int 這四種情況都算 ssh-fail。"""
    if rc != 0 or not line.strip():
        return (False, "ssh-fail", None, None)
    try:
        data = json.loads(line)
    except ValueError:
        return (False, "ssh-fail", None, None)
    ts = data.get("ts")
    if not isinstance(ts, int):
        return (False, "ssh-fail", None, None)
    return (data.get("ok") is True, "probe", now - ts, data.get("err"))


def peer_state(status_json_text):
    """回 (label, relay)。用 DNSName 比對：HostName 在兩台上都是 zaber。
    走中繼端的條件是 Active 為真且 CurAddr 為空。"""
    try:
        status = json.loads(status_json_text)
    except ValueError:
        return ("missing", "-")
    peers = status.get("Peer")
    if not isinstance(peers, dict):
        return ("missing", "-")
    for peer in peers.values():
        if not isinstance(peer, dict):
            continue
        if peer.get("DNSName") != ZABER2_DNS:
            continue
        relay = peer.get("Relay") or "-"
        if not peer.get("Active"):
            return ("idle", relay)
        if not peer.get("CurAddr"):
            return ("relay", relay)
        return ("direct", relay)
    return ("missing", "-")


def transition(prev, v):
    """回 (action, new_state)。new_state 為 None 表示不動狀態檔。"""
    if v == "PROBE-STALE":
        return ("none", None)
    if v == "OK":
        if prev:
            return ("recover", "")
        return ("none", None)
    if prev != v:
        return ("alert", v)
    return ("none", None)


def tsnet_label(tsnet_ok, source, age):
    if source == "ssh-fail":
        return "ssh-fail"
    if age is None or age > STALE_SEC:
        return "stale"
    return "ok" if tsnet_ok else "fail"


def summary(local_ok, gateway_ok, tsnet_lbl, age, peer, relay, err):
    return ("local=%s gateway=%s tsnet=%s age=%s peer=%s relay=%s err=%s"
            % ("ok" if local_ok else "bad",
               "ok" if gateway_ok else "bad",
               tsnet_lbl,
               "null" if age is None else age,
               peer, relay,
               err if err else "-"))


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--local", type=int, required=True)
    ap.add_argument("--gateway", type=int, required=True)
    ap.add_argument("--tsnet-rc", type=int, required=True)
    ap.add_argument("--tsnet-line", default="")
    ap.add_argument("--state", required=True)
    args = ap.parse_args(argv)

    now = int(time.time())
    tsnet_ok, source, age, err = parse_tsnet(
        args.tsnet_rc, args.tsnet_line, now)
    peer, relay = peer_state(sys.stdin.read())
    v = verdict(args.local == 1, args.gateway == 1, tsnet_ok, source, age)

    try:
        with open(args.state, "r", encoding="utf-8") as fh:
            prev = fh.read().strip()
    except OSError:
        prev = ""
    action, new_state = transition(prev, v)
    if new_state is not None:
        try:
            with open(args.state, "w", encoding="utf-8") as fh:
                fh.write(new_state)
        except OSError:
            pass

    print(v)
    print(action)
    print(summary(args.local == 1, args.gateway == 1,
                  tsnet_label(tsnet_ok, source, age), age, peer, relay, err))
    return 0


if __name__ == "__main__":
    sys.exit(main())
