"""TASK-WSBRIDGE live probe: drive the bridge the way the app will and print raw JSON-RPC.

Two modes:

  --inprocess        start a Bridge on an ephemeral loopback port with a throwaway key
                     (no service, no API_SERVER_KEY read); upstream is the real gateway.
  --url URL          an already running bridge; the key comes from $WSBRIDGE_KEY.

Steps, each printed with its raw request/answer (message bodies are reduced to counts):
  1. connect with an ``Origin`` header (the bridge must not carry it upstream: 4403 otherwise)
  2. ``shell.exec``                 -> expect method_not_found (allowlist)
  3. ``prompt.submit`` pre-resume   -> expect permission_denied
  4. ``session.resume --session``   -> the owner's answer through the ticketed path
     with ``--liveness``: ``session.liveness`` once before that resume and once after,
     each expected to answer exactly the keys ``session_id``, ``listed``, ``status``
     (the cheap read-only verb: one row, no history, own upstream connection)
  5. with ``--submit TEXT`` (only for a session whose thread is in ``--test-thread``):
     ``prompt.submit`` -> receipt, wait for an assistant event, then check ``messages`` in
     state.db for the user row
  6. with ``--reconnect-after N``: close, wait N s (> 30 s ticket TTL), reconnect and resume again

Exit 0 only when every executed step matched its expectation.
"""
import argparse
import asyncio
import json
import os
import secrets
import sqlite3
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from compat import wsbridge  # noqa: E402


def brief(frame):
    """The frame with transcript bodies replaced by their size."""
    out = json.loads(json.dumps(frame))
    result = out.get("result")
    if isinstance(result, dict):
        for key in ("messages", "display_messages"):
            if isinstance(result.get(key), list):
                result[key] = f"<{len(result[key])} rows>"
        for key in ("info", "todo_state", "pending_connection"):
            if key in result:
                result[key] = "<omitted>"
    return out


class Probe:
    def __init__(self, url, key):
        self.url, self.key, self.n, self.ws, self.events = url, key, 0, None, []
        self.failures = []

    async def open(self):
        from websockets.asyncio.client import connect
        self.ws = await connect(self.url, additional_headers={"Authorization": f"Bearer {self.key}",
                                                              "Origin": "https://probe.invalid"}, proxy=None,
                                max_size=None)  # a big resume must not be cut at 1009

    async def close(self):
        await self.ws.close()

    async def call(self, method, **params):
        self.n += 1
        request = {"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}
        print(">>", json.dumps(request, ensure_ascii=False))
        await self.ws.send(json.dumps(request))
        while True:
            frame = json.loads(await asyncio.wait_for(self.ws.recv(), 60))
            if frame.get("id") == self.n and "method" not in frame:
                print("<<", json.dumps(brief(frame), ensure_ascii=False))
                return frame
            self.events.append(frame)

    def expect(self, label, ok):
        print(f"[{'PASS' if ok else 'FAIL'}] {label}")
        if not ok:
            self.failures.append(label)

    async def wait_event(self, predicate, seconds):
        deadline = time.monotonic() + seconds
        for frame in self.events:
            if predicate(frame):
                return frame
        while time.monotonic() < deadline:
            try:
                frame = json.loads(await asyncio.wait_for(self.ws.recv(), deadline - time.monotonic()))
            except asyncio.TimeoutError:
                break
            self.events.append(frame)
            print("<< event", json.dumps(frame, ensure_ascii=False)[:300])
            if predicate(frame):
                return frame
        return None


def user_row(state_db, session_id, text):
    con = sqlite3.connect(f"file:{state_db}?mode=ro", uri=True, timeout=5)
    try:
        return con.execute("SELECT id, role FROM messages WHERE session_id = ? AND role = 'user' AND content LIKE ?"
                           " ORDER BY id DESC LIMIT 1", (session_id, f"%{text}%")).fetchone()
    finally:
        con.close()


async def probe(args, url, key):
    p = Probe(url, key)
    await p.open()
    p.expect("allowlist: shell.exec is method_not_found",
             (await p.call("shell.exec", command="true")).get("error", {}).get("message") == "method_not_found")
    p.expect("submit before resume is permission_denied",
             (await p.call("prompt.submit", session_id=args.session, submission_id="probe-pre",
                           text="x")).get("error", {}).get("message") == "permission_denied")
    if args.liveness:
        # Before resume: the verb must not need a resume on this connection.
        alive = await p.call("session.liveness", session_id=args.session)
        p.expect("liveness before resume answers one row",
                 set(alive.get("result", {})) == {"session_id", "listed", "status"})
    resumed = await p.call("session.resume", session_id=args.session)
    if args.expect_resume_error:
        p.expect(f"resume reaches the authority and answers {args.expect_resume_error}",
                 resumed.get("error", {}).get("message") == args.expect_resume_error)
    else:
        p.expect("resume answers a snapshot", "result" in resumed)
    if args.liveness:
        after = await p.call("session.liveness", session_id=args.session)
        p.expect("liveness after resume answers one row",
                 set(after.get("result", {})) == {"session_id", "listed", "status"})
    if args.submit and "result" in resumed:
        sid = resumed["result"]["session_id"]   # lineage root, not necessarily --session
        marker = f"{args.submit} [{uuid.uuid4().hex[:8]}]"
        receipt = await p.call("prompt.submit", session_id=args.session, submission_id=uuid.uuid4().hex,
                               text=marker)
        p.expect("submit admitted", "result" in receipt)
        if "result" in receipt:
            done = await p.wait_event(lambda f: f.get("method") == "event"
                                      and f["params"].get("type") in ("message.complete", "message.delta"),
                                      args.wait)
            p.expect("event stream carried assistant output", done is not None)
            row = user_row(args.state_db, sid, marker)
            print("messages user row:", row)
            p.expect("messages table has the user row", row is not None)
    await p.close()
    if args.reconnect_after:
        print(f"... waiting {args.reconnect_after}s (past the 30 s ticket TTL) before reconnecting")
        await asyncio.sleep(args.reconnect_after)
        await p.open()
        again = await p.call("session.resume", session_id=args.session)
        expected = args.expect_resume_error
        p.expect("reconnect remints and reaches the authority again",
                 (again.get("error", {}).get("message") == expected) if expected else "result" in again)
        await p.close()
    return p.failures


async def main_async(args):
    if args.inprocess:
        key = secrets.token_urlsafe(24)   # throwaway; never the real API_SERVER_KEY
        home = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes"))
        bridge = wsbridge.Bridge(key=key, test_thread_ids=args.test_thread,
                                 thread_of=wsbridge.state_db_thread_of(home / "state.db"))
        server = await bridge.serve("127.0.0.1", 0)
        url = f"ws://127.0.0.1:{server.sockets[0].getsockname()[1]}{wsbridge.BRIDGE_PATH}"
        try:
            return await probe(args, url, key)
        finally:
            server.close()
            await server.wait_closed()
    return await probe(args, args.url, os.environ.get("WSBRIDGE_KEY", ""))


def main():
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--inprocess", action="store_true")
    mode.add_argument("--url")
    parser.add_argument("--session", required=True)
    parser.add_argument("--expect-resume-error")
    parser.add_argument("--submit")
    parser.add_argument("--test-thread", action="append", default=[])
    parser.add_argument("--wait", type=float, default=180)
    parser.add_argument("--reconnect-after", type=float, default=0)
    parser.add_argument("--state-db", default=str(Path.home() / ".hermes" / "state.db"))
    parser.add_argument("--liveness", action="store_true")
    args = parser.parse_args()
    import logging
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    failures = asyncio.run(main_async(args))
    print("PROBE", "GREEN" if not failures else f"RED {failures}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
