#!/usr/bin/env python3
"""TASK-COLDTURN live probe. Stdlib only; reads state.db / the spool read-only.

  python3 probe/probe_coldturn.py --cold <session id> --hot <session id> [--live]

Both sessions must be Discord thread sessions whose thread id is listed in
``test_thread_ids`` of the TASK-WSBRIDGE config (``$HERMES_APP_WSBRIDGE_CONFIG``, else
``~/.hermes/app-wsbridge.json``; the same file and key the bridge reads). Anything else
is refused before a request is sent. Without ``--live`` it only resolves and prints the plan.

Expectations once the gateway has loaded the COLDTURN compat (pending a restart):
the cold session (no committed native envelope) answers 502 ``bridge_unavailable``
with reason ``no_route_envelope`` and its spool row stays ``failed``; the hot one
answers 202, its row is ``delivered`` and gateway.log shows the admission.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import runtime_config as _rc  # noqa: E402

HOME = Path.home() / ".hermes"
# TASK-WSBRIDGE's config (compat/wsbridge.py CONFIG_ENV / CONFIG_NAME) and its whitelist key.
CONFIG_ENV, CONFIG_NAME, WHITELIST_KEY = "HERMES_APP_WSBRIDGE_CONFIG", "app-wsbridge.json", "test_thread_ids"


def test_threads():
    path = Path(os.environ.get(CONFIG_ENV) or HOME / CONFIG_NAME)
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return path, frozenset()
    threads = raw.get(WHITELIST_KEY) if isinstance(raw, dict) else None
    if not isinstance(threads, list):
        sys.exit(f"{path}: {WHITELIST_KEY} must be a list")
    return path, frozenset(str(t) for t in threads)
THREAD_KEY = re.compile(r"^agent:[^:]+:discord:thread:(\d+):(\d+)$")


def ro(path):
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True)


def session(sid):
    with ro(HOME / "state.db") as conn:
        row = conn.execute("SELECT source, session_key FROM sessions WHERE id=?", (sid,)).fetchone()
    if row is None:
        sys.exit(f"{sid}: no such session")
    source, key = row
    match = THREAD_KEY.match(key or "")
    if source != "discord" or match is None:
        sys.exit(f"{sid}: not a discord thread session (source={source})")
    return key, match.group(2)


def envelope_count(sid):
    with ro(HOME / "state.db") as conn:
        return conn.execute("SELECT count(*) FROM session_admissions WHERE target_session_id=? "
                            "AND payload_json LIKE '%native_text_v1%' AND payload_json LIKE '%provenance%'",
                            (sid,)).fetchone()[0]


def spool_row(delivery_id):
    with ro(HOME / "crosssource_spool.db") as conn:
        row = conn.execute("SELECT status, attempts, last_error, trigger FROM outbox WHERE id=?",
                           (delivery_id,)).fetchone()
    return dict(zip(("status", "attempts", "last_error", "trigger"), row)) if row else None


def post(base, key, sid, text):
    req = urllib.request.Request(f"{base}/api/sessions/{sid}/chat", data=json.dumps({"input": text}).encode(),
                                 headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
                                 method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read() or b"{}")


def admitted_in_log(session_key, since, wait=15.0):
    log, needle = HOME / "logs" / "gateway.log", f"Plugin message injection admitted: plugin=hermes-app-compat session={session_key} "
    deadline = time.time() + wait
    while time.time() < deadline:
        for line in log.read_text(errors="replace").splitlines()[-2000:]:
            if needle in line and line[:19] >= since:
                return line[:23]
        time.sleep(1)
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cold", required=True)
    parser.add_argument("--hot", required=True)
    parser.add_argument("--live", action="store_true", help="send the probe messages")
    args = parser.parse_args()
    config, allowed = test_threads()
    plan = {}
    for role, sid in (("cold", args.cold), ("hot", args.hot)):
        key, thread = session(sid)
        if thread not in allowed:
            sys.exit(f"{role} {sid}: thread {thread} is not in {config} {WHITELIST_KEY}; refusing")
        plan[role] = {"session_id": sid, "session_key": key, "envelopes": envelope_count(sid)}
    if plan["cold"]["envelopes"] or not plan["hot"]["envelopes"]:
        sys.exit(f"precondition: cold needs 0 envelopes and hot at least 1: {plan}")
    print(json.dumps({"plan": plan, "live": args.live}, ensure_ascii=False, indent=2))
    if not args.live:
        return 0
    resolver = _rc.Resolver()
    base = _rc.validate_url(resolver.resolve("HERMES_LIVE_BASE_URL", required=True),
                            name="HERMES_LIVE_BASE_URL", allow_path=True)
    key = _rc.read_key(resolver.path)
    if key is None:
        sys.exit("API key unavailable")
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    result, ok = {}, True
    status, body = post(base, key, args.cold, f"[COLDTURN probe cold {stamp}]")
    row = spool_row(body.get("delivery_id")) if body.get("delivery_id") else None
    cold_ok = (status == 502 and body.get("kind") == "bridge_unavailable"
               and body.get("reason") == "no_route_envelope" and (row or {}).get("status") == "failed")
    result["cold"] = {"status": status, "kind": body.get("kind"), "reason": body.get("reason"), "spool": row,
                      "ok": cold_ok}
    status, body = post(base, key, args.hot, f"[COLDTURN probe hot {stamp}]")
    row = spool_row(body.get("delivery_id")) if body.get("delivery_id") else None
    admitted = admitted_in_log(plan["hot"]["session_key"], stamp) if status == 202 else None
    hot_ok = status == 202 and (row or {}).get("status") == "delivered" and admitted is not None
    result["hot"] = {"status": status, "spool": row, "admitted_log_at": admitted, "ok": hot_ok}
    ok = cold_ok and hot_ok
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
