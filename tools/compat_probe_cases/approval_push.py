"""APPROVALPUSH B2 (R4/R5): immediate approval push and reminder lifecycle
against a loopback fake ntfy hub with a REAL api adapter and guard. The
publisher worker, the timers, the inbox capture and the push-unit exit
hand-off all run for real; only the hub and the agent are fixtures.
Covers P1/P2/P4/P5 here; P3's exact formula lives in the pytest suite."""
from __future__ import annotations
import asyncio
import json
import os
import sys
import time
from pathlib import Path
from unittest.mock import patch

from aiohttp import web

COMMAND = "rm -rf /tmp/compat-probe-push-never"
LEGACY_TITLE = "Hermes: approval needed"


class JsonHub:
    """Records JSON-body publishes (Unicode titles) AND legacy header pushes."""

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
        return "http://127.0.0.1:" + str(self._site._server.sockets[0].getsockname()[1])

    async def _post(self, request):
        raw = await request.read()
        ctype = request.headers.get("Content-Type", "")
        if "json" in ctype:
            try:
                body = json.loads(raw)
            except Exception:
                body = {}
            self.posts.append({"title": body.get("title", ""),
                               "message": body.get("message", ""),
                               "priority": str(body.get("priority", "")),
                               "tags": body.get("tags", []), "json": True})
        else:
            self.posts.append({"title": request.headers.get("Title", ""),
                               "message": raw.decode(errors="replace"),
                               "priority": request.headers.get("Priority", ""),
                               "tags": request.headers.get("Tags", "").split(","),
                               "json": False})
        return web.json_response({"id": str(len(self.posts))})

    def approval(self):
        return [p for p in self.posts if "待核准" in p["title"] or (
            "Hermes approval" in p["title"] and "expiring" not in p["title"])]

    def expiring(self):
        return [p for p in self.posts if "即將逾時" in p["title"] or "expiring" in p["title"]]

    def legacy(self):
        return [p for p in self.posts if p["title"] == LEGACY_TITLE]

    async def settle(self, timeout=25.0, idle=0.3):
        deadline = time.monotonic() + timeout
        last = -1
        while time.monotonic() < deadline:
            await asyncio.sleep(idle)
            if len(self.posts) == last:
                return len(self.posts)
            last = len(self.posts)
        raise AssertionError("fake hub never went quiet (publisher still active?)")

    async def wait_for(self, predicate, timeout=15.0, what="post"):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate(self.posts):
                return
            await asyncio.sleep(0.02)
        raise AssertionError(f"hub did not record {what}: {[(p['title'], p['json']) for p in self.posts]}")


def inbox_module():
    for name, mod in list(sys.modules.items()):
        if name.endswith("compat.approval_inbox"):
            return mod
    raise AssertionError("approval_inbox module not loaded by the plugin")


async def next_event(response, wanted=None, timeout=25):
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
                if wanted is None or event == wanted or payload.get("type") == wanted:
                    return event, payload
        raise AssertionError(f"SSE ended before {wanted}")
    return await asyncio.wait_for(read(), timeout)


async def case_approval_push(args, server, check):
    from hermes_state import SessionDB
    from tools import approval
    from tools.approval_detection import detect_dangerous_command
    from .offline import AUTH

    check(detect_dangerous_command(COMMAND)[0], "fixture command trips the real guard")
    inbox_mod = inbox_module()

    class Agent:
        session_prompt_tokens = session_completion_tokens = session_total_tokens = 0
        provider, model = "fixture", "compat-fixture"

        def __init__(self, **kwargs):
            self.session_id = kwargs.get("session_id")
            self.interrupted = False

        def interrupt(self, *args, **kwargs):
            self.interrupted = True

        def run_conversation(self, user_message, **kwargs):
            result = approval.check_dangerous_command(COMMAND, env_type="local")
            outcomes[str(user_message)] = result
            return {"final_response": "approved" if result["approved"] else "denied",
                    "messages": [], "interrupted": self.interrupted}

    outcomes = {}

    def configure(home, hub_url, *, timeout, locale=None):
        config = json.loads((home / "config.yaml").read_text())
        config.setdefault("approvals", {})["timeout"] = timeout
        push = {"ntfy_server": hub_url, "ntfy_topic": "compat-probe-push"}
        if locale:
            push["approval_locale"] = locale
        config["push"] = push
        (home / "config.yaml").write_text(json.dumps(config))

    hub = JsonHub()
    hub_url = await hub.start()
    home = Path(os.environ["HERMES_HOME"])
    configure(home, hub_url, timeout=300)
    from gateway.platforms import api_server as api_probe
    _state = getattr(api_probe, "_hermes_app_compat_state_v1", {})
    check(_state.get("manifest", {}).get("approval_inbox", {}).get("status") == "applied",
          f"approval_inbox unit applied: {_state.get('manifest', {}).get('approval_inbox')}")
    check(_state.get("approval_inbox", {}).get("dispatch") is not None,
          "approval push dispatcher attached at install")

    inbox_mod.set_capability(True)
    try:
        async with server() as (adapter, client):
            db = SessionDB(Path("approval_push.db"))
            sid = db.create_session("compat-push", "api_server")
            adapter._session_db = db
            adapter._max_concurrent_runs = 8
            with patch.object(adapter, "_create_agent", side_effect=lambda **kw: Agent(**kw)):

                async def start(label, timeout, locale=None):
                    configure(home, hub_url, timeout=timeout, locale=locale)
                    response = await client.post(f"/api/sessions/{sid}/chat/stream",
                                                 json={"message": label}, headers=AUTH)
                    check(response.status == 200, f"{label}: SSE accepted")
                    _, event = await next_event(response, "approval.request")
                    return response, event

                async def answer(run_id, event, choice="once"):
                    async with client.post(f"/v1/runs/{run_id}/approval",
                                           json={"choice": choice,
                                                 "request_id": event["request_id"]},
                                           headers=AUTH) as r:
                        check(r.status == 200, "exact answer accepted")
                        return r.status

                # ---- P1: CONNECTED viewer still gets the immediate push ------
                # This is the exact root cause: SSE alive, human absent, and
                # the old exit stayed silent until a socket failure.
                label = "p1-connected"
                response, event = await start(label, timeout=300)
                try:
                    await hub.wait_for(lambda p: any("待核准" in x["title"] for x in p),
                                       what="initial approval push while connected")
                except AssertionError as exc:
                    _ib = api_probe._hermes_app_compat_state_v1["approval_inbox"]
                    raise AssertionError(f"{exc}; metrics={_ib['metrics']} "
                                         f"entries={[list(b['entries']) for b in _ib['by_run'].values()]}"
                                         f" dispatch={_ib['dispatch'] is not None}")
                post = [x for x in hub.posts if "待核准" in x["title"]][0]
                check(post["json"] is True and post["priority"] == "4",
                      "P5: Unicode JSON title published at high priority (4)")
                check("hermes-agent" in post["tags"], "P5: echo tag rides every push")
                check("compat-probe-push" not in post["message"] + post["title"],
                      "P5: the topic never rides into a push")
                check("允許一次" in post["message"] and "拒絕" in post["message"]
                      and "約剩" in post["message"],
                      "R7: zh-TW choices and remaining time live in the body")
                await answer(event["run_id"], event)
                await asyncio.wait_for(response.read(), 20)
                response.close()
                await hub.settle()
                check(len(hub.approval()) == 1, "P1/P2: exactly ONE initial per request (connected)")
                check(not hub.legacy(), "B2: legacy approval exit fully replaced (no double)")
                check(not hub.expiring(), "no reminder for an answered request")
                hub.posts.clear()

                # ---- P2: detached AFTER the initial adds no second push ------
                label = "p2-detached"
                response, event = await start(label, timeout=300)
                await hub.wait_for(lambda p: any("待核准" in x["title"] for x in p),
                                   what="initial push before detach")
                response.close()  # viewer gone: old exit would push HERE
                await asyncio.sleep(0.6)
                check(len(hub.approval()) == 1, "P2: detach never re-pushes the same request")
                await answer(event["run_id"], event, choice="deny")
                await asyncio.sleep(0.5)
                await hub.settle()
                check(not hub.expiring(), "P4: answered request's reminder timer cancelled")
                hub.posts.clear()

                # ---- P3/P4: one reminder near the deadline, then silence -----
                hub.posts.clear()
                label = "p3-reminder"
                response, event = await start(label, timeout=8)  # remind ~4s, expire 8s
                try:
                    await hub.wait_for(lambda p: any("即將逾時" in x["title"] for x in p),
                                       timeout=7, what="one near-timeout reminder")
                except AssertionError as exc:
                    _ib = api_probe._hermes_app_compat_state_v1["approval_inbox"]
                    _e = list(_ib["by_run"].values())[-1]["entries"]
                    _summary = [(k, v["phase"], v["timeout"], round(v["created_mono"], 1),
                                 v["timer"] is not None, v["pushed"]) for k, v in _e.items()]
                    raise AssertionError(f"{exc}; metrics={_ib['metrics']} entry={_summary}")
                check(len(hub.expiring()) == 1, "P3: never a second reminder")
                try:
                    await asyncio.wait_for(response.read(), 12)  # past the native timeout
                except Exception:
                    pass
                response.close()
                await hub.settle()
                check(len(hub.expiring()) == 1, "P3: exactly one reminder, never a repeat")
                check(outcomes["p3-reminder"]["approved"] is False,
                      "P3: nobody answered; fail-closed as before")
                hub.posts.clear()

                label = "p4-stop"
                response, event = await start(label, timeout=300)
                await hub.wait_for(lambda p: any("待核准" in x["title"] for x in p),
                                   what="initial before stop")
                async with client.post(f"/v1/runs/{event['run_id']}/stop", headers=AUTH) as r:
                    check(r.status < 300, "stop accepted")
                await asyncio.sleep(0.8)
                check(not hub.expiring(), "P4: stopped request never gets a reminder")
                hub.posts.clear()

                # ---- R7: en locale labels ------------------------------------
                label = "p5-en"
                response, event = await start(label, timeout=300, locale="en")
                await hub.wait_for(lambda p: any("Hermes approval |" in x["title"] for x in p),
                                   what="en-locale title")
                post = [x for x in hub.posts if "Hermes approval |" in x["title"]][0]
                check("Allow once" in post["message"] and "Deny" in post["message"],
                      "R7: en push labels")
                await answer(event["run_id"], event, choice="deny")
                try:
                    await asyncio.wait_for(response.read(), 15)
                except Exception:
                    pass
                response.close()
                await hub.settle()

                # ---- legacy rollback flag: dispatch=None restores old exit ---
                from gateway.platforms import api_server as api_module
                inbox = api_module._hermes_app_compat_state_v1["approval_inbox"]
                saved = inbox["dispatch"]
                inbox["dispatch"] = None  # emulate push.approval_dispatcher=legacy
                try:
                    label = "legacy-flag"
                    hub.posts.clear()
                    configure(home, hub_url, timeout=300)
                    response = await client.post(f"/api/sessions/{sid}/chat/stream",
                                                 json={"message": label}, headers=AUTH)
                    response.close()  # gone BEFORE the request frame: first write fails
                    await asyncio.sleep(1.5)
                    check(len(hub.approval()) == 0,
                          "B2 rollback: with dispatcher detached no immediate push happens")
                    check(len(hub.legacy()) == 1,
                          "B2 rollback: legacy detached exit restored intact")
                    async with client.get(f"/v1/runs/{[r for r in adapter._run_statuses if adapter._run_statuses[r].get('status') == 'waiting_for_approval'][-1]}/approvals", headers=AUTH) as r:
                        snap = await r.json()
                    async with client.post(f"/v1/runs/{snap['run_id']}/approval",
                                           json={"choice": "deny",
                                                 "request_id": snap["pending"][0]["request_id"]},
                                           headers=AUTH) as r:
                        check(r.status == 200, "legacy-flag answered")
                finally:
                    inbox["dispatch"] = saved
                await hub.settle()

                metrics = inbox["metrics"]
                check(metrics.get("push_enqueued", 0) >= 4,
                      "R4: enqueue observability counted")
                check("send_success" in metrics and "send_fail" in metrics,
                      "R4: send outcome counters exist (sanitized types only)")
    finally:
        inbox_mod.set_capability(False)
