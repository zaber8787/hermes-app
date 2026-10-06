"""APPROVALPUSH B1 (R2/R3): real guard + real HTTP for the cross-device inbox.

Real api adapter, real dangerous-command guard, real SSE + JSON HTTP. Fixture
substitutions are only the agent factory and (for the timeout row) the
approvals.timeout read — no shell command is ever executed. Covers matrix
groups C1/C4/C5/C6/C8; C2/C7 policy/atomicity rows live in the pytest helper
suite and the control worker."""
from __future__ import annotations
import asyncio
import contextvars
import json
import sys
import threading
import time
from pathlib import Path
from unittest.mock import patch

COMMAND_A = "rm -rf /tmp/compat-probe-alpha"
COMMAND_B = "rm -rf /tmp/compat-probe-beta"
COMMAND_C = "rm -rf /tmp/compat-probe-coalesce"


async def next_event(response, wanted=None, timeout=25, log=None):
    name, data = None, []
    async def read():
        nonlocal name, data
        async for raw in response.content:
            line = raw.decode().rstrip("\r\n")
            if line.startswith("event:"):
                name = line[6:].strip()
            elif line.startswith("data:"):
                data.append(line[5:].strip())
            elif not line and data:
                payload = json.loads("\n".join(data))
                event = name or payload.get("type") or payload.get("event")
                name, data = None, []
                if log is not None:
                    log.append((event, payload))
                if wanted is None or event == wanted or payload.get("type") == wanted:
                    return event, payload
        raise AssertionError(f"SSE ended before {wanted}; stream={json.dumps([(e, str(p)[:160]) for e, p in (log or [])])[-1200:]}")
    return await asyncio.wait_for(read(), timeout)


def inbox_module():
    for name, mod in list(sys.modules.items()):
        if name.endswith("compat.approval_inbox"):
            return mod
    raise AssertionError("approval_inbox module not loaded by the plugin")


async def case_approval_inbox(args, server, check):
    from hermes_state import SessionDB
    from tools import approval
    from gateway.platforms import api_server as api
    from tools.approval_detection import detect_dangerous_command
    from .offline import AUTH

    for command in (COMMAND_A, COMMAND_B, COMMAND_C):
        check(detect_dangerous_command(command)[0], f"fixture command guarded: {command}")

    outcomes = {}

    class Agent:
        session_prompt_tokens = session_completion_tokens = session_total_tokens = 0
        provider, model = "fixture", "compat-fixture"

        def __init__(self, **kwargs):
            self.session_id = kwargs.get("session_id")
            self.interrupted = False

        def interrupt(self, *args, **kwargs):
            self.interrupted = True

        def _guard(self, command, sink, key):
            sink[key] = approval.check_dangerous_command(command, env_type="local")

        def run_conversation(self, user_message, **kwargs):
            label = str(user_message)
            if label.startswith("AB"):
                results = {}
                # Tool threads must inherit the run's approval/session
                # contextvars (the real parallel-tool executor does the same);
                # a context-less thread would read as unattended and deny.
                ctx_a, ctx_b = contextvars.copy_context(), contextvars.copy_context()
                threads = [threading.Thread(target=ctx_a.run, args=(self._guard, COMMAND_A, results, "a")),
                           threading.Thread(target=ctx_b.run, args=(self._guard, COMMAND_B, results, "b"))]
                threads[0].start()
                time.sleep(0.8)          # deterministic queue order: A then B
                threads[1].start()
                for t in threads:
                    t.join()
                outcomes[label] = results
                approved = all(r.get("approved") for r in results.values())
            elif label.startswith("CO"):
                results = {}
                ctx_1, ctx_2 = contextvars.copy_context(), contextvars.copy_context()
                threads = [threading.Thread(target=ctx_1.run, args=(self._guard, COMMAND_C, results, "t1")),
                           threading.Thread(target=ctx_2.run, args=(self._guard, COMMAND_C, results, "t2"))]
                threads[0].start()
                time.sleep(0.8)          # leader first; follower coalesces after
                threads[1].start()
                for t in threads:
                    t.join()
                outcomes[label] = results
                approved = all(r.get("approved") for r in results.values())
            else:
                result = approval.check_dangerous_command(COMMAND_A, env_type="local")
                outcomes[label] = result
                approved = result["approved"]
            return {"final_response": "approved" if approved else "denied",
                    "messages": [], "interrupted": self.interrupted}

    STREAM_LOG = []
    inbox_mod = inbox_module()
    state = getattr(api, "_hermes_app_compat_state_v1")
    inbox = state["approval_inbox"]

    async with server() as (adapter, client):
        # ---- C8 first: EXPLICITLY disabled (B4 kill-switch path) -------------
        _was_on = inbox_mod._capability_on
        inbox_mod.set_capability(False)
        async with client.get("/v1/runs/run_missing/approvals", headers=AUTH) as r:
            check(r.status == 404 and (await r.json())["error"]["code"] == "approval_inbox_disabled",
                  "disabled inbox answers a stable disabled 404, not fake pending")
        async with client.get("/v1/capabilities", headers=AUTH) as r:
            caps = await r.json()
            check(caps["features"]["approval_inbox"]["enabled"] is False,
                  "disabled capability is advertised honestly")

        inbox_mod.set_capability(True)
        import tools.approval_context as approval_context
        _timeout_guard = patch.object(approval_context, "_get_approval_timeout", lambda: 120)
        _timeout_guard.start()
        try:
            async with client.get("/v1/capabilities", headers=AUTH) as r:
                caps = await r.json()
                check(caps["features"]["approval_inbox"]["enabled"] is True
                      and caps["features"]["approval_inbox"]["server_epoch"] == inbox["epoch"],
                      "enabled capability advertises the server epoch")

            db = SessionDB(Path("approval_inbox.db"))
            sid = db.create_session("compat-inbox", "api_server")
            adapter._session_db = db
            adapter._max_concurrent_runs = 8
            with patch.object(adapter, "_create_agent", side_effect=lambda **kw: Agent(**kw)):

                async def start(label, native=False):
                    if native:
                        async with client.post("/v1/runs", json={"input": label, "session_id": sid},
                                               headers=AUTH) as r:
                            run_id = (await r.json())["run_id"]
                        response = await client.get(f"/v1/runs/{run_id}/events", headers=AUTH)
                    else:
                        response = await client.post(f"/api/sessions/{sid}/chat/stream",
                                                     json={"message": label}, headers=AUTH)
                    check(response.status == 200, f"{label}: SSE accepted")
                    _, event = await next_event(response, "approval.request", log=STREAM_LOG)
                    return response, event

                async def pending_of(run_id):
                    async with client.get(f"/v1/runs/{run_id}/approvals", headers=AUTH) as r:
                        check(r.status == 200, "GET approvals HTTP200")
                        return await r.json()

                async def answer(run_id, body):
                    async with client.post(f"/v1/runs/{run_id}/approval", json=body,
                                           headers=AUTH) as r:
                        return r.status, await r.json()

                async def finish(response, label, timeout=30):
                    try:
                        await asyncio.wait_for(response.read(), timeout)
                    except (asyncio.TimeoutError, Exception):
                        pass
                    response.close()
                    for _ in range(int(timeout * 100)):
                        if label in outcomes:
                            return
                        await asyncio.sleep(.01)
                    check(False, f"{label}: worker exits after decisions")

                # ---- C1: session stream — SSE and GET expose the SAME id -----
                response, event = await start("once")
                snapshot = await pending_of(event["run_id"])
                check(snapshot["available"] is True and snapshot["object"] == "hermes.run.approvals",
                      "C8: snapshot object/available")
                check([p["request_id"] for p in snapshot["pending"]] == [event["request_id"]],
                      "C1: GET pending carries the exact SSE request_id")
                card = snapshot["pending"][0]
                for field in ("run_id", "session_id", "server_epoch", "choices", "created_at",
                              "expires_at", "remaining_seconds", "deadline_estimated"):
                    check(field in card, f"R2 payload field present: {field}")
                check(card["deadline_estimated"] is True
                      and card["server_epoch"] == inbox["epoch"],
                      "R5: deadline is estimated, epoch matches server")
                check("compat-probe" in card["command"],
                      "display payload carries the redacted command")
                status, body = await answer(event["run_id"], {
                    "choice": "once", "request_id": event["request_id"],
                    "server_epoch": "stale-epoch"})
                check(status == 409 and body["error"]["code"] == "approval_epoch_stale",
                      "C8: stale epoch cannot answer the live request")
                status, _body = await answer(event["run_id"], {
                    "choice": "once", "request_id": event["request_id"],
                    "server_epoch": inbox["epoch"]})
                check(status == 200, "fresh-epoch exact answer accepted")
                snapshot = await pending_of(event["run_id"])
                check(snapshot["pending"] == [] and snapshot["available"] is True,
                      "answered request leaves the pending list, queue read healthy")
                await finish(response, "once")
                check(outcomes["once"]["approved"] is True, "guard obeyed the inbox answer")

                # ---- C1: /v1/runs surface shares the same inbox + contract ---
                response, event = await start("runs-once", native=True)
                snapshot = await pending_of(event["run_id"])
                check([p["request_id"] for p in snapshot["pending"]] == [event["request_id"]],
                      "C1: /v1/runs notify is captured by the SAME registry")
                # legacy client, single pending: EXACT id backfilled, never FIFO
                status, body = await answer(event["run_id"], {"choice": "once"})
                check(status == 200 and body.get("request_id") == event["request_id"],
                      "C5: legacy single-pending POST is backfilled with the exact id")
                await finish(response, "runs-once")

                # ---- C4: same run, entries A and B, exact correspondence -----
                response, _first = await start("AB-both")   # start() consumed A's request
                await next_event(response, "approval.request")  # B's request
                snapshot = await pending_of(_first["run_id"])
                ordered = [p["request_id"] for p in snapshot["pending"]]
                check(len(set(ordered)) == 2, f"C4: one run exposes BOTH pending entries: {ordered}")
                a_id, b_id = ordered[0], ordered[1]   # queue order: oldest first
                status, body = await answer(_first["run_id"], {"choice": "once"})
                check(status == 409 and body["error"]["code"] == "approval_request_required",
                      "C5 root cause: multi-pending legacy POST refuses FIFO, answers nothing")
                snapshot = await pending_of(_first["run_id"])
                check(len(snapshot["pending"]) == 2, "refused submit changed nothing")
                _, _ = await answer(_first["run_id"], {"choice": "once", "request_id": b_id,
                                                       "server_epoch": inbox["epoch"]})
                _, restored = await next_event(response, "approval.request")
                check(restored["request_id"] == a_id,
                      "R2: after answering B the earliest pending A is restored, not B")
                snapshot = await pending_of(_first["run_id"])
                check([p["request_id"] for p in snapshot["pending"]] == [a_id],
                      "C4: exactly one entry survives the exact answer")
                async with client.get(f"/v1/runs/{_first['run_id']}", headers=AUTH) as r:
                    check((await r.json())["status"] == "waiting_for_approval",
                          "R2: status returns to waiting_for_approval while A is pending")
                status, body = await answer(_first["run_id"], {"choice": "once"})  # single left
                check(status == 200 and body.get("request_id") == a_id,
                      "C5: once B settled, the legacy POST backfills A exactly")
                await finish(response, "AB-both", timeout=40)
                check(all(r.get("approved") for r in outcomes["AB-both"].values()),
                      "C4: both guards obeyed their own exact answers")

                # ---- C4 coalesced leader/follower: once covers the leader ----
                response, leader = await start("CO-both")
                first_id = leader["request_id"]
                status, _body = await answer(leader["run_id"], {"choice": "once",
                                                               "request_id": first_id,
                                                               "server_epoch": inbox["epoch"]})
                check(status == 200, "coalesced leader answered once")
                _, follower = await next_event(response, "approval.request")
                check(follower["request_id"] != first_id,
                      "C4: follower gets a FRESH request id; once never covers it")
                snapshot = await pending_of(leader["run_id"])
                check([p["request_id"] for p in snapshot["pending"]] == [follower["request_id"]],
                      "C4: pending list tracks the follower, not the answered leader")
                await answer(leader["run_id"], {"choice": "deny",
                                               "request_id": follower["request_id"],
                                               "server_epoch": inbox["epoch"]})
                await finish(response, "CO-both", timeout=40)
                results = outcomes["CO-both"]
                check(results["t1"].get("approved") is True and results["t2"].get("approved") is False,
                      "C4: leader approved once, follower denied — no silent double-run")

                # ---- C6: stop settles every open card fail-closed ------------
                response, event = await start("stop-me")
                async with client.post(f"/v1/runs/{event['run_id']}/stop", headers=AUTH) as r:
                    check(r.status < 300, "stop accepted")
                await finish(response, "stop-me", timeout=20)
                snapshot = await pending_of(event["run_id"])
                check(snapshot["pending"] == [], "C6: stop leaves no pending card")
                entries = inbox["by_run"].get((id(adapter), event["run_id"]), {}).get("entries", {})
                check(all(e["phase"] != "pending" for e in entries.values()) and entries,
                      "C6: settle callback marked the stopped request resolved")

                # ---- C6: timeout resolves as timeout, not as a user deny -----
                response, event = None, None
                with patch.object(approval_context, "_get_approval_timeout", lambda: 2):
                    response, event = await start("timeout-me")
                    await finish(response, "timeout-me", timeout=25)
                snapshot = await pending_of(event["run_id"])
                check(snapshot["pending"] == [], "C6: timed-out request leaves the queue")
                entries = inbox["by_run"].get((id(adapter), event["run_id"]), {}).get("entries", {})
                outcomes_seen = [e.get("outcome") for e in entries.values()]
                check("timeout" in outcomes_seen,
                      f"C6: settle outcome distinguishes timeout: {outcomes_seen}")
                check(outcomes["timeout-me"]["approved"] is False
                      and outcomes["timeout-me"].get("outcome") == "timeout",
                      "C6: core timed out fail-closed with the timeout outcome; nothing ran")

                # ---- C8: auth and unknown-run contracts ----------------------
                async with client.get(f"/v1/runs/run-nope/approvals",
                                      headers={"Authorization": "Bearer wrong"}) as r:
                    check(r.status == 401, "C8: wrong auth cannot read pending approvals")
                async with client.get("/v1/runs/run-nope/approvals", headers=AUTH) as r:
                    check(r.status == 404, "C8: unknown run is 404, never an empty list")

                # ---- push-set metrics present (B2 consumes them) -------------
                check(isinstance(inbox["metrics"], dict) and "registry_accepted" in inbox["metrics"],
                      "R4 observability counters exist on the registry")
        finally:
            _timeout_guard.stop()
            inbox_mod.set_capability(_was_on)  # back to the shipped default
