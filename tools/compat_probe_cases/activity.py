"""WAVE4 activity unit: registry, hooks, endpoint and lifecycle over REAL HTTP.

Only the expensive external agent factory is substituted; gateway, registry,
session-stream, /v1/runs, auth and DB code all stay real. Fixtures persist NO
transcript rows, so message_count/latest_id freeze while runs move — exactly
the shape the app must observe (the 340-frozen bug).
"""
from __future__ import annotations
import asyncio
import json
import sys
import sys
import threading
import time
from pathlib import Path
from unittest.mock import patch
from .offline import AUTH, profiles

ROT = "compat-activity-rotated"


class Harness:
    def __init__(self):
        self.gates = {}
        self.inits = []   # agent-creation captures (prompt-cache red line)
        self.turns = []   # run_conversation captures
        self.rotate_to = None  # live rotation target set by the case

    def gate(self, name):
        return self.gates.setdefault(name, threading.Event())


def make_agent(harness):
    class Agent:
        session_prompt_tokens = session_completion_tokens = session_total_tokens = 0
        provider, model = "fixture", "compat-fixture"

        def __init__(self, **kwargs):
            self.session_id = kwargs.get("session_id")
            self.interrupted = False
            self._event = threading.Event()
            harness.inits.append({"keys": sorted(kwargs),
                                  "prompt": kwargs.get("ephemeral_system_prompt")})

        def interrupt(self, *args, **kwargs):
            self.interrupted = True
            self._event.set()

        def run_conversation(self, user_message, **kwargs):
            harness.turns.append({"user": user_message,
                                  "history": json.dumps(kwargs.get("conversation_history"),
                                                        sort_keys=True)})
            text = user_message if isinstance(user_message, str) else ""
            if text.startswith("hold:"):
                gate = harness.gate(text[5:])
                while not gate.is_set() and not self.interrupted:
                    self._event.wait(0.02)
                if self.interrupted:
                    return {"final_response": "", "messages": [], "interrupted": True}
            elif text == "approve-me":
                from tools import approval
                approval.check_dangerous_command(
                    "rm -rf /tmp/compat-activity-never-executed", env_type="local")
            elif text == "boom":
                raise RuntimeError("fixture agent failure")
            elif text == "rotate":
                # A real compression rotation moves the AGENT's session_id scalar
                # (_finish_turn_result projects it as the effective id).
                self.session_id = harness.rotate_to or ROT
                return {"final_response": "rotated", "messages": [],
                        "interrupted": self.interrupted}
            return {"final_response": "done:" + text, "messages": [],
                    "interrupted": self.interrupted}
    return Agent


async def case_activity(args, server, check):
    from hermes_state import SessionDB
    from gateway.platforms import api_server as api
    from gateway.platforms import api_server_runs as runs
    from hermes_cli.plugins import get_plugin_manager
    harness = Harness()
    Agent = make_agent(harness)

    async with server() as (adapter, client):
        db = SessionDB(Path("activity.db"))
        sid = db.create_session("compat-activity", "api_server")
        db.append_message(sid, "user", "舊列")
        db.append_message(sid, "assistant", "舊回覆")
        harness.rotate_to = db.create_session(ROT, "api_server")
        adapter._session_db = db
        adapter._max_concurrent_runs = 64

        async def get_json(method, url, *, auth=AUTH, prefix="", **kw):
            async with client.request(method, prefix + url, headers=auth, **kw) as r:
                body = await r.json() if r.status == 200 else None
                return r.status, body, r.headers

        async def snap(target=sid, auth=AUTH, prefix=""):
            return await get_json("GET", f"/api/sessions/{target}/activity",
                                  auth=auth, prefix=prefix)

        async def start_run(text, extra=None):
            async with client.post("/v1/runs", json={"input": text, "session_id": sid},
                                   headers={**(extra or {}), **AUTH}) as r:
                check(r.status == 202, f"/v1/runs accepted, got {r.status}")
                return (await r.json())["run_id"]

        async def stream_turn(text):
            response = await client.post(f"/api/sessions/{sid}/chat/stream",
                                         json={"message": text}, headers=AUTH)
            check(response.status == 200, "session SSE HTTP200")
            return response

        async def wait_active(target=sid, *, match, tries=1200):
            for _ in range(tries):
                status, payload, _ = await snap(target)
                if status == 200:
                    rows = [e for e in payload["active_runs"] if match(e)]
                    if rows:
                        return payload, rows
                await asyncio.sleep(0.01)
            raise AssertionError(f"no active entry under {target}")

        async def wait_idle(target=sid, tries=1200):
            for _ in range(tries):
                status, payload, _ = await snap(target)
                if status == 200 and not payload["active_runs"]:
                    return payload
                await asyncio.sleep(0.01)
            raise AssertionError(f"runs never left active under {target}: {payload}")

        async def sync_turn(text):
            r = await client.post(f"/api/sessions/{sid}/chat",
                                  json={"message": text}, headers=AUTH)
            body = await r.read()
            check(r.status == 200, f"sync chat 200, got {r.status}")
            return body

        # ---- contract basics ---------------------------------------------------
        status, payload, headers = await snap()
        check(status == 200 and payload["object"] == "hermes.session.activity"
              and payload["schema_version"] == 1, "snapshot contract fields")
        check(headers.get("Cache-Control") == "no-store", "snapshot is no-store")
        check(payload["coverage"] == "api_process" and payload["server_epoch"],
              "coverage/epoch present")
        frozen = dict(payload["history_revision"])
        check(frozen["count"] == 2 and frozen["latest_id"] > 0, f"revision baseline {frozen}")
        check(payload["active_runs"] == [] and payload["overflow"] is False,
              "idle session: zero active runs")
        epoch = payload["server_epoch"]

        with patch.object(adapter, "_create_agent", side_effect=lambda **kw: Agent(**kw)):
            # ---- native /v1/runs: queued-before-agent, count frozen -----------
            run_id = await start_run("hold:native")
            payload, rows = await wait_active(
                match=lambda e: e.get("run_id") == run_id and e.get("user"))
            check(rows[0]["status"] in {"queued", "running"},
                  f"queued-before-agent visible: {rows[0]['status']}")
            check(rows[0]["user"]["text"] == "hold:native"
                  and rows[0]["user"]["truncated"] is False
                  and rows[0]["user"]["after_id"] == frozen["latest_id"],
                  "queued user preview + after_id")
            check(payload["history_revision"] == frozen,
                  "count/latest FROZEN while the remote run works (the 340 shape)")
            check(sum(1 for e in payload["active_runs"] if e.get("run_id") == run_id) == 1,
                  "one entry per run (no double registration)")
            harness.gate("native").set()
            payload = await wait_idle()
            check(any(e["run_id"] == run_id and e["status"] == "completed"
                      and e["user"]["after_id"] == frozen["latest_id"]
                      for e in payload["recent_terminal"]),
                  "terminal lands in recent_terminal with after_id/preview")

            # ---- idempotency replay must not double-register -------------------
            idem = {"Idempotency-Key": "activity-replay-1"}
            first = await start_run("hold:replay", idem)
            async with client.post("/v1/runs", json={"input": "hold:replay", "session_id": sid},
                                   headers={**idem, **AUTH}) as r:
                check(r.status == 202 and (await r.json())["run_id"] == first,
                      "replay returns the same run")
            payload, rows = await wait_active(
                match=lambda e: e.get("run_id") == first and e.get("user"))
            check(len(rows) == 1, "replay did not create a second entry")
            harness.gate("replay").set()
            await wait_idle()

            # ---- session SSE path -----------------------------------------------
            stream = await stream_turn("hold:stream")
            payload, rows = await wait_active(
                match=lambda e: e.get("user") and e["user"]["text"] == "hold:stream")
            check(rows[0]["source"] == "session_stream" and rows[0]["run_id"],
                  "SSE source tagged, real run_id")
            harness.gate("stream").set()
            await asyncio.wait_for(stream.read(), 20)
            stream.close()
            payload = await wait_idle()
            check(any(e["status"] in {"completed", "cancelled"}
                      and e["user"]["text"] == "hold:stream"
                      for e in payload["recent_terminal"]), "SSE turn terminal in recent")

            # ---- synchronous chat: synthetic observation ------------------------
            task = asyncio.create_task(sync_turn("hold:sync"))
            payload, rows = await wait_active(match=lambda e: e.get("run_id") is None
                                             and e.get("user")
                                             and e["user"]["text"] == "hold:sync")
            check(rows[0]["observation_id"].startswith("obs_")
                  and rows[0]["source"] == "session_sync",
                  "synthetic obs: obs_ id, null run_id (never sent to /v1/runs)")
            harness.gate("sync").set()
            await task
            payload = await wait_idle()
            check(any(e["observation_id"] == rows[0]["observation_id"]
                      and e["status"] == "completed"
                      for e in payload["recent_terminal"]), "synthetic obs terminal completed")

            # ---- waiting_for_approval surfaces (no command leak) ---------------
            stream = await stream_turn("approve-me")
            payload, rows = await wait_active(
                match=lambda e: e["status"] == "waiting_for_approval")
            check(rows[0]["user"]["text"] == "approve-me", "approval wait keeps preview")
            check("command" not in json.dumps(rows[0]),
                  "snapshot never carries the approval command")
            await asyncio.wait_for(stream.read(), 30)  # fixture timeout=3s fails closed
            stream.close()
            payload = await wait_idle()
            check(any(e["status"] in {"completed", "failed", "cancelled"}
                      and e["user"]["text"] == "approve-me"
                      for e in payload["recent_terminal"]), "approval turn settled")

            # ---- exception: failed, not idle -------------------------------------
            stream = await stream_turn("boom")
            await asyncio.wait_for(stream.read(), 20)
            stream.close()
            payload = await wait_idle()
            check(any(e["status"] == "failed" and e["user"]["text"] == "boom"
                      for e in payload["recent_terminal"]), "exception lands failed")

            # ---- parallel: terminal A must not clear B ---------------------------
            runA = await start_run("hold:parA")
            runB = await start_run("hold:parB")
            await wait_active(match=lambda e: e.get("run_id") == runB and e.get("user"))
            async with client.post(f"/v1/runs/{runA}/stop", json={}, headers=AUTH) as r:
                check(r.status == 200, "stop A accepted")
            seenB = False
            for _ in range(1200):
                status, payload, _ = await snap()
                if status == 200:
                    a = [e for e in payload["active_runs"] if e.get("run_id") == runA]
                    b = [e for e in payload["active_runs"] if e.get("run_id") == runB]
                    if b and not a:
                        seenB = True
                        break
                await asyncio.sleep(0.01)
            check(seenB, "terminal A did not clear active B")
            harness.gate("parB").set()
            await wait_idle()

            # ---- rotation/alias: dedup by observation_id under both ids ---------
            stream = await stream_turn("rotate")
            await asyncio.wait_for(stream.read(), 20)
            stream.close()
            await wait_idle()
            _, under_old, _ = await snap(sid)
            _, under_new, _ = await snap(harness.rotate_to)
            old_hits = [e for e in under_old["recent_terminal"] if e["status"] == "completed"
                        and e["user"] and e["user"]["text"] == "rotate"]
            new_hits = [e for e in under_new["recent_terminal"] if e["status"] == "completed"
                        and e["user"] and e["user"]["text"] == "rotate"]
            check(old_hits and new_hits, "effective sid recorded as alias")
            check(len({e["observation_id"] for e in new_hits}) == len(new_hits),
                  "alias snapshot dedupes by observation_id")

            # ---- overflow: display cap honoured ------------------------------------
            # 4 CPUs give the DEFAULT executor only 8 threads; each held turn keeps
            # one, so 10 simultaneous active runs would starve the gateway's own
            # to_thread reads. The cap CODE PATH is exercised by lowering the
            # display cap to 4 (module constant the snapshot reads live) and
            # running 5 gated turns: 4 shown + overflow=true.
            compat_module = next(m for m in sys.modules.values()
                                 if getattr(m, "_ACTIVITY", None)
                                 is getattr(api, "_hermes_app_compat_state_v1").get("activity"))
            posts = [asyncio.create_task(sync_turn(f"hold:ov{i}")) for i in range(5)]
            ok = False
            compat_module.ACTIVITY_ACTIVE_CAP = 4
            try:
                for _ in range(1200):
                    status, payload, _ = await snap()
                    if status == 200 and len(payload["active_runs"]) == 4 \
                            and payload["overflow"] is True:
                        ok = True
                        break
                    await asyncio.sleep(0.01)
            finally:
                compat_module.ACTIVITY_ACTIVE_CAP = 8
            check(ok, "display cap honoured with overflow=true (cap 4, 5 active)")
            for i in range(5):
                harness.gate(f"ov{i}").set()
            await asyncio.gather(*posts)
            await wait_idle()

            # ---- auth / authorization ---------------------------------------------
            status, _, _ = await snap(auth={})
            check(status == 401, "missing bearer -> 401")
            status, _, _ = await snap(auth={"Authorization": "Bearer wrong-key-not-a-match"})
            check(status == 401, "wrong bearer -> 401")
            status, _, _ = await snap(auth={"Authorization": "HermesRoom probe-only-token"})
            check(status == 403, f"room-grant-only token refused with 403, got {status}")
            status, _, _ = await snap("no-such-session")
            check(status == 404, "unknown session -> 404")
            status, cap, _ = await get_json("GET", "/v1/capabilities")
            check(cap["endpoints"]["session_activity"] == {
                "method": "GET", "path": "/api/sessions/{session_id}/activity"},
                "capability matches route")
            run_id = await start_run("hold:profile")
            await wait_active(match=lambda e: e.get("run_id") == run_id and e.get("user"))
            with profiles(adapter) as entries:
                name, headers, root = entries[0]
                status, payload, _ = await snap(prefix=f"/p/{name}/", auth=headers)
                leaked = any("user" in e for e in payload["active_runs"]) if payload else True
                check(status == 404 or not leaked,
                      "foreign profile sees nothing or only previewless entries")
            harness.gate("profile").set()
            await wait_idle()

            # ---- stale coverage: unregistered live run -> 503, never fake idle --
            adapter._active_run_agents["run_ghost"] = Agent()
            status, _, _ = await snap()
            check(status == 503, "unregistered live run -> 503 (coverage gap refused)")
            adapter._active_run_agents.pop("run_ghost", None)
            getattr(api, "_hermes_app_compat_state_v1")["activity"]["blind"] = None
            status, payload, _ = await snap()
            check(status == 200 and payload["server_epoch"] == epoch,
                  "epoch stable within one process")

            # ---- prompt-cache red line: identical agent work, plugin on vs off ------
        harness.inits.clear(); harness.turns.clear()
        with patch.object(adapter, "_create_agent", side_effect=lambda **kw: Agent(**kw)):
            stream = await stream_turn("redline")
            await asyncio.wait_for(stream.read(), 20)
            stream.close()
            rows_before = db._read_one("SELECT COUNT(*) AS c FROM messages")["c"]
            on_init, on_turn = harness.inits[-1], harness.turns[-1]
            get_plugin_manager().unload()
            stream = await stream_turn("redline")
            await asyncio.wait_for(stream.read(), 20)
            stream.close()
        off_init, off_turn = harness.inits[-1], harness.turns[-1]
        rows_off = db._read_one("SELECT COUNT(*) AS c FROM messages")["c"]
        check(on_init["keys"] == off_init["keys"], "same agent kwargs surface plugin on/off")
        check(on_init["prompt"] == off_init["prompt"], "system prompt bytes identical")
        check(json.loads(on_turn["history"]) == json.loads(off_turn["history"]),
              "conversation_history identical plugin on/off")
        check(rows_before == rows_off, "activity paths inserted no DB message rows")

        if args.full_size:
            # get_plugin_manager().unload() above stopped the hooks; reinstall so
            # the big-history snapshot reads through the (still correct) endpoint.
            from hermes_cli.plugins import PluginContext, discover_plugins
            discover_plugins()
            manager = get_plugin_manager()
            loaded = next(p for p in manager._plugins.values()
                          if p.manifest.name == "hermes-app-compat")
            loaded.module.register(PluginContext(loaded.manifest, manager))
            big = db.create_session("compat-activity-big", "api_server")
            for i in range(3000):
                db.append_message(big, "user" if i % 2 else "assistant", "歷史列" * 40 + str(i))
            plan = " ".join(str(cell) for row in db._read_all(
                "EXPLAIN QUERY PLAN SELECT id FROM messages WHERE session_id = ? "
                "AND active = 1 ORDER BY id DESC LIMIT 1", (big,)) for cell in row).lower()
            check("index" in plan, f"tail read uses an index: {plan}")
            start = time.monotonic()
            status, payload, _ = await snap(big)
            rtt = time.monotonic() - start
            check(status == 200 and payload["history_revision"]["count"] == 3000,
                  "big-history snapshot correct")
            check(rtt < 1.0, f"big-history snapshot RTT {rtt:.3f}s")
            db.close()
            return "PASS", (f"registry/hooks/auth/overflow/alias/503-coverage/red-line green; "
                            f"big-history RTT {rtt*1000:.1f}ms, plan={'index' in plan}")
    db.close()
    return "PASS", "registry/hooks/auth/overflow/alias/503-coverage/prompt-cache green"
