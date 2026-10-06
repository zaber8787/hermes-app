"""Push unit: real session-SSE lifecycle against a loopback fake ntfy hub.

Only the agent factory is substituted; HTTP, SSE, approval, registry and the
plugin's push bindings all run for real. Positive cases wait for the hub to
settle (the publisher is one FIFO worker); negative cases assert zero after
run/writer/publisher have all settled.
"""
from __future__ import annotations
import asyncio
import json
import os
from pathlib import Path
import threading
import time
from unittest.mock import patch
from aiohttp import web
from .offline import AUTH
from .approval import next_event

TITLE_APPROVAL = "Hermes: approval needed"
TITLE_REPLY = "Hermes: reply ready"
TITLE_FAILED = "Hermes: run failed"
COMMAND = "rm -rf /tmp/compat-probe-never-executed"
COMMAND2 = "rm -rf /tmp/compat-probe-never-executed-second"
SENTINEL = "".join(["sk-", "a1b2c3d4e5f6g7h8i9j0abcdefgh"])  # synthetic; join keeps hygiene-gate's credential-value capture empty


APPROVAL_TITLE_PREFIX = "Hermes 待核准\uff5c"  # compose() zh-TW initial template


def _approval_posts(hub):
    """JSON-body posts (Unicode title path) that are approval notes."""
    out = []
    for post in hub.posts:
        try:
            payload = json.loads(post["body"].decode("utf-8"))
        except Exception:
            continue
        if str(payload.get("title", "")).startswith(APPROVAL_TITLE_PREFIX):
            out.append(post)
    return out


async def _wait_approval(hub, count=1, timeout=25.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if len(_approval_posts(hub)) >= count:
            return
        await asyncio.sleep(0.02)
    raise AssertionError(f"hub did not record {count}x immediate approval notes")


class Hub:
    def __init__(self):
        self.posts = []
        self.app = web.Application()
        self.app.router.add_post("/{tail:.*}", self._post)
        self._site = None

    async def start(self):
        runner = web.AppRunner(self.app)
        await runner.setup()
        self._site = web.TCPSite(runner, "127.0.0.1", 0)
        await self._site.start()
        return self.url

    @property
    def url(self):
        return "http://127.0.0.1:" + str(self._site._server.sockets[0].getsockname()[1])

    async def _post(self, request):
        body = await request.read()
        self.posts.append({"path": request.path, "title": request.headers.get("Title", ""),
                           "priority": request.headers.get("Priority", ""),
                           "tags": request.headers.get("Tags", ""), "body": body})
        return web.json_response({"id": str(len(self.posts))})

    def kind(self, title):
        return [post for post in self.posts if post["title"] == title]

    async def settle(self, timeout=25.0, idle=0.3):
        deadline = time.monotonic() + timeout
        last = -1
        while time.monotonic() < deadline:
            await asyncio.sleep(idle)
            if len(self.posts) == last:
                return len(self.posts)
            last = len(self.posts)
        raise AssertionError("fake hub never went quiet (publisher still active?)")

    async def wait_for(self, title, count=1, timeout=25.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if len(self.kind(title)) >= count:
                return
            await asyncio.sleep(0.02)
        raise AssertionError(f"hub did not record {count}x {title!r} ({self.posts})")


def fixture_config(hub_url, *, push=True, timeout=30):
    home = Path(os.environ["HERMES_HOME"])
    config = json.loads((home / "config.yaml").read_text())
    config.setdefault("approvals", {})["timeout"] = timeout
    if push:
        config["push"] = {"ntfy_server": hub_url, "ntfy_topic": "compat-probe-push"}
    else:
        config.pop("push", None)
    (home / "config.yaml").write_text(json.dumps(config))


async def case_push(args, server, check):
    from gateway.platforms import api_server as api
    from hermes_state import SessionDB
    from tools import approval
    from tools.approval_detection import detect_dangerous_command

    check(detect_dangerous_command(COMMAND)[0], "fixture command trips the real guard")
    hub = Hub()
    hub_url = await hub.start()
    fixture_config(hub_url)
    outcomes, agents = {}, []
    gates = {name: threading.Event() for name in ("approval", "block", "one", "two", "after")}

    class Agent:
        session_prompt_tokens = session_total_tokens = session_completion_tokens = 0
        provider, model = "fixture", "compat-fixture"

        def __init__(self, **kwargs):
            self.session_id = kwargs.get("session_id")
            self.interrupted = False
            self._stop = threading.Event()
            self._delta = kwargs.get("stream_delta_callback")
            agents.append(self)

        def interrupt(self, *a, **k):
            self.interrupted = True
            self._stop.set()

        def _gate(self, event):
            while not event.is_set() and not self._stop.is_set():
                event.wait(0.05)
            return self._stop.is_set()

        def run_conversation(self, user_message, **kwargs):
            label = user_message
            if label.startswith("ok"):
                return {"final_response": "pong", "messages": [], "completed": True}
            if label == "error":
                raise RuntimeError(f"upstream exploded credential {SENTINEL}")
            if label == "approval-inline":
                outcomes[label] = approval.check_dangerous_command(COMMAND, env_type="local")
                stopped = self._gate(gates["after"])
                return {"final_response": "done after approval", "messages": [],
                        "completed": not stopped, "interrupted": stopped}
            if label == "approval-armed":
                gates["approval"].wait(40)
                outcomes[label] = approval.check_dangerous_command(COMMAND, env_type="local")
                return {"final_response": "approved" if outcomes[label]["approved"] else "denied",
                        "messages": [], "interrupted": self.interrupted}
            if label == "approval-two":
                gates["one"].wait(40)
                outcomes["two-1"] = approval.check_dangerous_command(COMMAND, env_type="local")
                gates["two"].wait(40)
                outcomes["two-2"] = approval.check_dangerous_command(COMMAND2, env_type="local")
                return {"final_response": "both decided", "messages": [],
                        "interrupted": self.interrupted}
            if label.startswith("block"):
                if self._gate(gates["block"]):
                    return {"final_response": "", "messages": [], "interrupted": True}
                if label == "block-error":
                    raise RuntimeError(f"upstream exploded credential {SENTINEL}")
                if label == "block-failed":
                    return {"final_response": "", "messages": [], "failed": True,
                            "completed": False, "turn_exit_reason": "provider_error"}
                if label == "block-partial":
                    return {"final_response": "partial", "messages": [], "partial": True,
                            "completed": True}
                if label == "block-unfinished":
                    return {"final_response": "", "messages": [], "completed": False,
                            "turn_exit_reason": "iteration_budget"}
                if label == "block-many":
                    for _ in range(4000):
                        if self._delta is not None:
                            self._delta("x" * 16)
                    outcomes["many-emitted"] = True
                    return {"final_response": "many", "messages": [], "completed": True}
                if label == "block-cjk":
                    return {"final_response": "漢" * 1500, "messages": [], "completed": True}
                if label == "block-media":
                    return {"final_response": "圖 data:image/png;base64," + "A" * 400 + " 結束",
                            "messages": [], "completed": True}
                return {"final_response": "blocked reply", "messages": [], "completed": True}
            raise AssertionError(f"unknown fixture label {label}")

    state = getattr(api, "_hermes_app_compat_state_v1")

    def push_state(adapter, run_id):
        return state.get("push", {}).get("runs", {}).get((id(adapter), run_id))

    async def wait_detached(adapter, run_id, timeout=10.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            st = push_state(adapter, run_id)
            if st is not None and st["detached"]:
                return st
            await asyncio.sleep(0.01)
        raise AssertionError(f"run {run_id} never detached")

    async def wait_settled(adapter, run_id, timeout=40.0):
        terminal = {"completed", "failed", "cancelled", "interrupted"}
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if adapter._run_statuses.get(run_id, {}).get("status") in terminal:
                return adapter._run_statuses[run_id]
            await asyncio.sleep(0.01)
        raise AssertionError(f"run {run_id} never settled")

    async def resolve(client, run_id, choice="once", timeout=25.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            async with client.get(f"/v1/runs/{run_id}", headers=AUTH) as response:
                status = await response.json()
            request_id = (status.get("approval") or {}).get("request_id")
            if request_id:
                async with client.post(f"/v1/runs/{run_id}/approval",
                                       json={"choice": choice, "request_id": request_id},
                                       headers=AUTH) as response:
                    if response.status == 200:
                        return 200, request_id
            await asyncio.sleep(0.05)
        return 0, None

    async def wait_outcome(key, timeout=10.0):
        deadline = time.monotonic() + timeout
        while key not in outcomes:
            if time.monotonic() > deadline:
                raise AssertionError(f"outcome {key} never recorded")
            await asyncio.sleep(0.02)

    async def start_turn(client, sid, label):
        response = await client.post(f"/api/sessions/{sid}/chat/stream",
                                     json={"message": label}, headers=AUTH)
        assert response.status == 200, f"{label}: SSE HTTP {response.status}"
        _, event = await next_event(response, "run.started")
        return response, event["run_id"]

    async def drain_to_eof(response, timeout=25.0):
        async def _read():
            async for _ in response.content:
                pass
        try:
            await asyncio.wait_for(_read(), timeout)
        except Exception:
            pass
        response.close()

    async def start_blocked(client, sid, label):
        gates["block"].clear()
        return await start_turn(client, sid, label)

    async with server() as (adapter, client):
        db = SessionDB(Path("push.db"))
        sid = db.create_session("compat-push", "api_server")
        adapter._session_db = db
        adapter._max_concurrent_runs = 8
        with patch.object(adapter, "_create_agent", side_effect=lambda **kw: Agent(**kw)), \
                patch.object(api, "CHAT_COMPLETIONS_SSE_KEEPALIVE_SECONDS", 0.03):

            # -- A: attached approval, answered in-session, then success -> zero pushes
            response = await client.post(f"/api/sessions/{sid}/chat/stream",
                                         json={"message": "approval-inline"}, headers=AUTH)
            _, card = await next_event(response, "approval.request")
            check(bool(card.get("request_id")), "attached approval card carries request_id")
            code, _ = await resolve(client, card["run_id"])
            check(code == 200, "in-session approval resolves HTTP200")
            gates["after"].set()
            await drain_to_eof(response)
            check(outcomes["approval-inline"]["approved"], "guard obeyed the in-session approval")
            posted = await hub.settle()
            check(posted == 1 and len(_approval_posts(hub)) == 1
                  and not hub.kind(TITLE_APPROVAL) and not hub.kind(TITLE_REPLY),
                  "approval note is IMMEDIATE and once, viewer-independent (B4/R4); "
                  "attached success still adds no reply push")
            hub.posts.clear()

            # -- B: attached exception / attached success -> zero pushes
            response = await client.post(f"/api/sessions/{sid}/chat/stream",
                                         json={"message": "error"}, headers=AUTH)
            await next_event(response, "error")
            await drain_to_eof(response)
            check(await hub.settle() == 0, "attached exception pushed nothing (error not swallowed)")
            hub.posts.clear()
            response = await client.post(f"/api/sessions/{sid}/chat/stream",
                                         json={"message": "ok-attached"}, headers=AUTH)
            await drain_to_eof(response)
            check(await hub.settle() == 0, "attached success pushed nothing")
            hub.posts.clear()

            # -- C: disconnect, THEN an approval request; HTTP resolve; completed
            response, run_id = await start_turn(client, sid, "approval-armed")
            response.close()
            await wait_detached(adapter, run_id)
            gates["approval"].set()
            await _wait_approval(hub, 1)
            check("approval-armed" not in outcomes, "dangerous action stays blocked until resolved")
            code, _ = await resolve(client, run_id)
            check(code == 200, "detached approval resolves over HTTP via the polled request_id")
            settled = await wait_settled(adapter, run_id)
            await hub.settle()
            check(settled["status"] == "completed", "post-detached run completed, not cancelled")
            check(len(_approval_posts(hub)) == 1 and len(hub.kind(TITLE_REPLY)) == 1
                  and not hub.kind(TITLE_FAILED) and not hub.kind(TITLE_APPROVAL),
                  "approval=1 (immediate) reply=1 failed=0; no legacy-title duplicate")
            hub.posts.clear()

            # -- D: disconnect mid-turn; the turn keeps running (barrier), reply once
            response, run_id = await start_blocked(client, sid, "block")
            response.close()
            await wait_detached(adapter, run_id)
            await asyncio.sleep(0.3)
            check(not agents[-1].interrupted, "detached turn was NOT interrupted (keep-running)")
            gates["block"].set()
            settled = await wait_settled(adapter, run_id)
            await hub.settle()
            check(settled["status"] == "completed" and settled.get("output") == "blocked reply",
                  "GET /v1/runs carries the completed output for the detached run")
            check(len(hub.kind(TITLE_REPLY)) == 1 and not hub.kind(TITLE_FAILED),
                  "disconnect + completion pushed reply exactly once")
            hub.posts.clear()

            # -- E: disconnect then exception -> failed once, redacted
            response, run_id = await start_blocked(client, sid, "block-error")
            response.close()
            await wait_detached(adapter, run_id)
            gates["block"].set()
            settled = await wait_settled(adapter, run_id)
            await hub.settle()
            check(settled["status"] == "failed", "post-detached exception settled failed")
            check(len(hub.kind(TITLE_FAILED)) == 1 and not hub.kind(TITLE_REPLY), "failed=1 reply=0")
            check(SENTINEL.encode() not in hub.kind(TITLE_FAILED)[0]["body"],
                  "failure push is redacted")
            hub.posts.clear()

            # -- F: result-shaped failures (failed / partial / completed=False)
            for label in ("block-failed", "block-partial", "block-unfinished"):
                response, run_id = await start_blocked(client, sid, label)
                response.close()
                await wait_detached(adapter, run_id)
                gates["block"].set()
                settled = await wait_settled(adapter, run_id)
                await hub.settle()
                check(settled["status"] == "failed", f"{label}: result maps to failed")
                check(len(hub.kind(TITLE_FAILED)) == 1 and not hub.kind(TITLE_REPLY),
                      f"{label}: failed=1 reply=0, aligned with terminal_run_status")
                hub.posts.clear()

            # -- G: replayed status writes after detach push at most once
            response, run_id = await start_blocked(client, sid, "block")
            response.close()
            await wait_detached(adapter, run_id)
            adapter._set_run_status(run_id, "completed", output="replay one")
            adapter._set_run_status(run_id, "completed", output="replay two")
            await asyncio.sleep(0.2)
            gates["block"].set()
            await wait_settled(adapter, run_id)
            await hub.settle()
            check(len(hub.kind(TITLE_REPLY)) == 1,
                  "replayed/repeated terminal events produced exactly one push")
            hub.posts.clear()

            # -- H: two different approvals after one disconnect: each pushed once
            response, run_id = await start_turn(client, sid, "approval-two")
            response.close()
            await wait_detached(adapter, run_id)
            gates["one"].set()
            await _wait_approval(hub, 1)
            code, _ = await resolve(client, run_id)
            await wait_outcome("two-1")
            check(code == 200 and outcomes["two-1"]["approved"], "first card resolved over HTTP")
            gates["two"].set()
            await _wait_approval(hub, 2)
            code, _ = await resolve(client, run_id)
            check(code == 200, "second card resolved over HTTP")
            await wait_settled(adapter, run_id)
            await hub.settle()
            check(len(_approval_posts(hub)) == 2 and len(hub.kind(TITLE_REPLY)) == 1
                  and not hub.kind(TITLE_APPROVAL),
                  "two distinct cards -> approval=2 reply=1 (no run-id-wide dedup)")
            hub.posts.clear()

            # -- I: resolved while attached, THEN disconnect -> the answered card stays 0
            gates["one"].clear()
            gates["two"].clear()
            response, run_id = await start_turn(client, sid, "approval-two")
            gates["one"].set()
            code, _ = await resolve(client, run_id)
            await wait_outcome("two-1")
            check(code == 200, "first card resolved while attached")
            await hub.settle()
            check(len(_approval_posts(hub)) == 1,
                  "the first request's note is immediate (B4); the RESOLVED card "
                  "adds nothing beyond that one note")
            response.close()
            await wait_detached(adapter, run_id)
            gates["two"].set()
            code, _ = await resolve(client, run_id, choice="deny")
            check(code == 200, "post-detach second card denied via HTTP")
            await wait_settled(adapter, run_id)
            await hub.settle()
            check(len(_approval_posts(hub)) == 2 and not hub.kind(TITLE_APPROVAL),
                  "two requests -> exactly two immediate notes, none duplicated by detach")
            hub.posts.clear()

            # -- J: explicit stop after detach keeps cancel semantics, pushes nothing
            response, run_id = await start_blocked(client, sid, "block")
            response.close()
            await wait_detached(adapter, run_id)
            async with client.post(f"/v1/runs/{run_id}/stop", json={}, headers=AUTH) as stopped:
                check(stopped.status == 200, "stop HTTP200")
            settled = await wait_settled(adapter, run_id)
            await hub.settle()
            check(settled["status"] in {"cancelled", "interrupted"},
                  "detached + stopped settles cancelled, never a fabricated reply")
            check(not hub.posts, "stop after detach pushed nothing")
            hub.posts.clear()

            # -- K: detached token flood: bounded queue, one agent, one push
            response, run_id = await start_blocked(client, sid, "block-many")
            response.close()
            st = await wait_detached(adapter, run_id)
            gates["block"].set()
            peak, deadline = 0, time.monotonic() + 20
            while "many-emitted" not in outcomes and time.monotonic() < deadline:
                peak = max(peak, st["queue"].qsize())
                await asyncio.sleep(0.002)
            settled = await wait_settled(adapter, run_id)
            await hub.settle()
            check(peak < 3000, f"detached queue stayed bounded (peak={peak})")
            check(settled["status"] == "completed", "flooded run still completed")
            check(st["discard"] is None or st["discard"].done(), "discard consumer ended at the sentinel")
            check(len(hub.kind(TITLE_REPLY)) == 1, "flood pushed reply once")
            check(adapter.active_agent_work_count() == 0, "discard consumer never counted as agent work")
            hub.posts.clear()

            # -- L: long CJK body + data URL: ASCII title, echo tag, byte bound
            response, run_id = await start_blocked(client, sid, "block-cjk")
            response.close()
            await wait_detached(adapter, run_id)
            gates["block"].set()
            await wait_settled(adapter, run_id)
            await hub.wait_for(TITLE_REPLY)
            post = hub.kind(TITLE_REPLY)[0]
            check(post["title"].isascii() and post["title"] == TITLE_REPLY, "ASCII title")
            check("hermes-agent" in post["tags"].split(","), "echo tag on every push")
            check("dart" in post["tags"].split(","), "dart tag on reply")
            check(post["priority"] == "3", "default priority maps to 3")
            check(len(post["body"]) <= 1900 and post["body"].decode("utf-8").strip(),
                  "body is valid UTF-8 inside the byte cap")
            await hub.settle()
            hub.posts.clear()
            response, run_id = await start_blocked(client, sid, "block-media")
            response.close()
            await wait_detached(adapter, run_id)
            gates["block"].set()
            await wait_settled(adapter, run_id)
            await hub.wait_for(TITLE_REPLY)
            body = hub.kind(TITLE_REPLY)[0]["body"].decode("utf-8")
            check("base64" not in body and "[附件]" in body, "data URLs collapse to a placeholder")
            await hub.settle()

            # -- M: the recorded push must not re-enter the ntfy platform adapter as a prompt
            from plugins.platforms.ntfy.adapter import NtfyAdapter
            from gateway.config import PlatformConfig
            dispatched = []

            async def record(message_event):
                dispatched.append(message_event)

            ntfy = NtfyAdapter(PlatformConfig(enabled=True, extra={
                "topic": "compat-probe-push", "server": hub_url}))
            ntfy.handle_message = record
            post = hub.kind(TITLE_REPLY)[-1]
            await ntfy._on_message({"id": "probe-echo-1", "topic": "compat-probe-push",
                                    "message": post["body"].decode("utf-8"),
                                    "tags": post["tags"].split(","), "time": int(time.time())})
            check(not dispatched, "echo-tagged hub event never dispatches as a new prompt")
            await ntfy._on_message({"id": "probe-echo-2", "topic": "compat-probe-push",
                                    "message": "unrelated subscriber note", "tags": [],
                                    "time": int(time.time())})
            check(len(dispatched) == 1, "without the echo tag the adapter path is live (control)")

            # -- N: unconfigured keeps the ORIGINAL disconnect behavior
            fixture_config(hub_url, push=False)
            hub.posts.clear()
            response, run_id = await start_blocked(client, sid, "block")
            response.close()
            settled = await wait_settled(adapter, run_id)
            check(push_state(adapter, run_id) is None, "unconfigured turn registers no push state")
            check(agents[-1].interrupted and settled["status"] in {"cancelled", "interrupted"},
                  "unconfigured disconnect still interrupts (original drain semantics)")
            check(await hub.settle() == 0, "unconfigured pushed nothing")
            fixture_config(hub_url)

            check(len(state["push"]["runs"]) <= 64, "push registry stayed bounded")
            check(adapter.active_agent_work_count() == 0, "no inflight/admission leak")
        db.close()
    return ("PASS", "attached zero-push x3; detached approval/reply/failed once each with "
                    "keep-running barrier; result-failures; replay idempotence; two-card dedup; "
                    "resolved-first zero; stop/cancel kept; bounded queue; redaction; byte/title/"
                    "echo-tag contract; unconfigured original behavior")
