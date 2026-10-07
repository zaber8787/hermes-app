"""APPROVALFIX (APPROVALSCAN §探針契約): the single _set_run_status capture cut.

Families: API producers (session / runs-without-SSE / runs-detach / OpenAI
chat stream), escalation shapes, dedup/status-replay, error isolation and
rollback. Real admission, real guard, real callback registry, real status
machine; the ONLY push oracle is the loopback hub's exact call count and only
the agent factory is a fixture. Boundary rows are asserted, not hidden: the
sync/API-unattended path and mode-off keep their original policy with zero
push; real cron and generic gateway cards write no API status at all and are
outside this unit by design (evidence docs), never pretended covered here.
"""
from __future__ import annotations
import asyncio
import json
import os
import time
from pathlib import Path
from unittest.mock import patch

from .approval_push import JsonHub, inbox_module, next_event

COMMAND_A = "rm -rf /tmp/compat-central-alpha"
COMMAND_B = "rm -rf /tmp/compat-central-beta"


def _llm(verdict):
    """Guardian verdict seam: tools.approval calls _smart_verdict at the gate;
    a guardian-LLM timeout/empty answer converges to 'escalate' inside
    _smart_approve, so the failure shapes assert their resolved verdict here."""
    return lambda *a, **k: verdict


async def case_approval_central(args, server, check):
    from hermes_state import SessionDB
    from tools import approval, approval_context, approval_gateway_wait, approval_prompt
    from gateway.platforms import api_server as api
    from tools.approval_detection import detect_dangerous_command
    from .offline import AUTH

    for command in (COMMAND_A, COMMAND_B):
        check(detect_dangerous_command(command)[0], f"fixture command guarded: {command}")
    inbox_mod = inbox_module()
    hub = JsonHub()
    hub_url = await hub.start()
    home = Path(os.environ["HERMES_HOME"])

    def configure(*, mode="manual", push="hub"):
        config = json.loads((home / "config.yaml").read_text())
        config.setdefault("approvals", {})["mode"] = mode
        config.setdefault("security", {})["tirith_fail_open"] = True
        if push == "hub":
            config["push"] = {"ntfy_server": hub_url, "ntfy_topic": "compat-probe-central"}
        elif push == "dead":
            config["push"] = {"ntfy_server": "http://127.0.0.1:9",
                              "ntfy_topic": "compat-probe-central"}
        else:
            config.pop("push", None)
        (home / "config.yaml").write_text(json.dumps(config))

    class Agent:
        session_prompt_tokens = session_completion_tokens = session_total_tokens = 0
        provider, model = "fixture", "compat-fixture"

        def __init__(self, **kwargs):
            self.session_id = kwargs.get("session_id")
            self.interrupted = False

        def interrupt(self, *args, **kwargs):
            self.interrupted = True

        def _session_key(self):
            return approval_context.get_current_session_key(default="")

        def _wait(self, description, pattern):
            key = self._session_key()
            decision = approval_gateway_wait._await_gateway_decision(
                key, approval._gateway_notify_cb(key),
                {"command": COMMAND_A, "description": description,
                 "pattern_key": pattern, "pattern_keys": [pattern]},
                surface=pattern)
            return bool(decision.get("resolved")) and decision.get("choice") in (
                "once", "session", "always")

        def run_conversation(self, user_message, **kwargs):
            label = str(user_message)
            if label.startswith("ROLLBACK"):
                outcomes[label] = [approval.check_dangerous_command(COMMAND_A, env_type="local"),
                                   approval.check_dangerous_command(COMMAND_B, env_type="local")]
                approved = all(r.get("approved") for r in outcomes[label])
            elif label.startswith("QFULL"):
                ra = approval.check_dangerous_command(COMMAND_A, env_type="local")
                rb = approval.check_dangerous_command(COMMAND_B, env_type="local")
                outcomes[label] = {"a": ra, "b": rb}
                approved = bool(ra.get("approved") and rb.get("approved"))
            elif label.startswith("RACE"):
                key = self._session_key()
                entry = approval_gateway_wait._ApprovalEntry(
                    {"command": COMMAND_A, "description": "settled-before-notify race",
                     "pattern_key": "race", "pattern_keys": ["race"]})
                with approval._lock:
                    approval._gateway_queues.setdefault(key, []).append(entry)
                with approval._lock:  # the human answered BEFORE the notify ran
                    queue = approval._gateway_queues.get(key, [])
                    if entry in queue:
                        queue.remove(entry)
                    if not queue:
                        approval._gateway_queues.pop(key, None)
                approval._gateway_notify_cb(key)(dict(entry.data))
                outcomes[label] = {"approved": False, "notified": True}
                approved = False
            elif label.startswith("MCP"):
                verdict = approval_prompt.request_elicitation_consent(
                    "fixture mcp action", "fixture elicitation consent")
                outcomes[label] = {"verdict": verdict}
                approved = verdict == "accept"
            elif label.startswith("PLUGIN"):
                outcomes[label] = {"approved": self._wait("fixture plugin escalation",
                                                          "plugin-escalation")}
                approved = outcomes[label]["approved"]
            elif label.startswith("PWRITE"):
                outcomes[label] = {"approved": self._wait("fixture protected write",
                                                          "protected-instruction-write")}
                approved = outcomes[label]["approved"]
            else:  # MANUAL rows ride the pattern-layer gate; SMART rows the real
                   # terminal guard (check_all_command_guards is what passes smart=
                   # to the human gate; check_dangerous_command never consults it)
                _gate = (approval.check_all_command_guards
                         if approval_context._get_approval_mode() == "smart"
                         else approval.check_dangerous_command)
                outcomes[label] = _gate(COMMAND_A, env_type="local")
                approved = bool(outcomes[label].get("approved"))
            return {"final_response": "approved" if approved else "denied",
                    "messages": [], "interrupted": self.interrupted}

    outcomes = {}
    server_loop = asyncio.get_running_loop()
    state = getattr(api, "_hermes_app_compat_state_v1")
    check(state["manifest"]["approval_inbox"]["status"] == "applied", "approval_inbox applied")
    check(state.get("approval_inbox", {}).get("dispatch") is not None,
          "dispatcher attached (immediate mode)")
    inbox_mod.set_capability(True)
    _timeout_guard = patch.object(approval_context, "_get_approval_timeout", lambda: 30)
    _timeout_guard.start()
    agent_patch = None
    try:
        async with server() as (adapter, client):
            inbox = state["approval_inbox"]
            db = SessionDB(Path("approval_central.db"))
            sid = db.create_session("compat-central", "api_server")
            adapter._session_db = db
            adapter._max_concurrent_runs = 8
            agent_patch = patch.object(adapter, "_create_agent",
                                       side_effect=lambda **kw: Agent(**kw))
            agent_patch.start()

            def delta(before, key):
                return inbox["metrics"].get(key, 0) - before.get(key, 0)

            async def hub_counts(timeout=25.0):
                # the ONLY push oracle: quiet hub, exact per-family counts, cleared
                await hub.settle(timeout=timeout)
                counts = (len(hub.approval()), len(hub.expiring()), len(hub.legacy()))
                hub.posts.clear()
                return counts

            async def wait_delta(before, key, want, timeout=20.0):
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    if delta(before, key) >= want:
                        return
                    await asyncio.sleep(0.05)
                raise AssertionError(f"metric {key} delta<{want} before={before} "
                                     f"now={dict(inbox['metrics'])}")

            async def start_stream(label):
                response = await client.post(f"/api/sessions/{sid}/chat/stream",
                                             json={"message": label}, headers=AUTH)
                check(response.status == 200, f"{label}: SSE accepted")
                return response

            async def pending_of(run_id):
                async with client.get(f"/v1/runs/{run_id}/approvals", headers=AUTH) as r:
                    check(r.status == 200, "GET approvals HTTP200")
                    return await r.json()

            async def answer(run_id, request_id, choice="once"):
                async with client.post(f"/v1/runs/{run_id}/approval",
                                       json={"choice": choice, "request_id": request_id},
                                       headers=AUTH) as r:
                    check(r.status == 200, f"exact answer accepted ({choice})")

            async def finish(response, label, timeout=25):
                try:
                    await asyncio.wait_for(response.read(), timeout)
                except Exception:
                    pass
                response.close()
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    if label in outcomes:
                        return
                    await asyncio.sleep(0.02)
                check(False, f"{label}: worker exits after decisions")

            async def entry_of(run_id, request_id):
                return inbox["by_run"].get((id(adapter), run_id), {}).get("entries", {}).get(
                    request_id)

            async def one_approval(label, *, native=False, llm=None, mode="manual"):
                """One guard pending -> answer on a session stream or /v1/runs,
                with the whole correlation contract asserted inline."""
                configure(mode=mode)
                before = dict(inbox["metrics"])
                patches = [patch.object(approval, "_smart_verdict", new=llm)] if llm else []
                for p in patches:
                    p.start()
                try:
                    if native:
                        async with client.post("/v1/runs", json={"input": label,
                                                                "session_id": sid},
                                               headers=AUTH) as r:
                            run_id = (await r.json())["run_id"]
                        event, deadline = None, time.monotonic() + 20
                        while event is None:
                            snap = await pending_of(run_id)
                            if snap["pending"]:
                                event = snap["pending"][0]
                            else:
                                check(time.monotonic() < deadline,
                                      f"{label}: runs pending appears without any SSE")
                                await asyncio.sleep(0.05)
                    else:
                        response = await start_stream(label)
                        _, event = await next_event(response, "approval.request")
                        run_id = event["run_id"]
                    initial, _rem, legacy = await hub_counts()
                    check(initial == 1 and legacy == 0,
                          f"{label}: initial publish exactly 1 (no legacy double)")
                    snap = await pending_of(run_id)
                    check([p["request_id"] for p in snap["pending"]] == [event["request_id"]],
                          f"{label}: core and inbox agree on the exact request_id")
                    check(snap["server_epoch"] == inbox["epoch"],
                          f"{label}: epoch correlation")
                    entry = await entry_of(run_id, event["request_id"])
                    check(entry is not None and entry["loop"] is server_loop,
                          f"{label}: admission owner loop bound, never loop=None")
                    await answer(run_id, event["request_id"])
                    check(delta(before, "registry_accepted") == 1,
                          f"{label}: registry_accepted counted exactly once")
                    if native:
                        deadline = time.monotonic() + 20
                        while True:
                            async with client.get(f"/v1/runs/{run_id}", headers=AUTH) as r:
                                done = (await r.json())["status"] == "completed"
                            if done or time.monotonic() > deadline:
                                check(done, f"{label}: run completes")
                                break
                            await asyncio.sleep(0.05)
                    else:
                        await finish(response, label)
                    return event
                finally:
                    for p in patches:
                        p.stop()

                # ---- API producers ------------------------------------------
            # session chat stream
            await one_approval("session-producer")
            # /v1/runs WITHOUT any SSE subscription: the callback is run-owned
            await one_approval("runs-nosse", native=True)
            initial, reminders, _legacy = await hub_counts()
            check(not reminders, "runs no-SSE: answered -> zero reminders")

            # /v1/runs viewer DETACHES after the frame: detach never unregisters
            async with client.post("/v1/runs", json={"input": "runs-detach", "session_id": sid},
                                   headers=AUTH) as r:
                run_id = (await r.json())["run_id"]
            response = await client.get(f"/v1/runs/{run_id}/events", headers=AUTH)
            _, event = await next_event(response, "approval.request")
            response.close()  # viewer gone BEFORE the answer
            entry = await entry_of(run_id, event["request_id"])
            check(entry is not None, "runs detach: capture stands on the status cut alone")
            initial, _rem, _leg = await hub_counts()
            check(initial == 1, "producer: detach never adds a second publish")
            await answer(run_id, event["request_id"])
            _i, reminders, _l = await hub_counts()
            check(not reminders, "runs detach: answered -> zero reminders")

            # streaming /v1/chat/completions: the THIRD producer, previously
            # uncaptured — the APPROVALSCAN red row, now on the real route.
            response = await client.post("/v1/chat/completions",
                                         json={"model": "compat-fixture", "stream": True,
                                               "messages": [{"role": "user",
                                                             "content": "openai-producer"}]},
                                         headers=AUTH)
            check(response.status == 200, "openai: SSE accepted")
            _, event = await next_event(response, "approval.request")
            completion_id = event["run_id"]
            initial, _rem, _leg = await hub_counts()
            check(initial == 1, "OpenAI chat stream publishes exactly 1: the RED row is GREEN")
            snap = await pending_of(completion_id)
            check([p["request_id"] for p in snap["pending"]] == [event["request_id"]],
                  "openai: GET approvals answers on the completion id")
            entry = await entry_of(completion_id, event["request_id"])
            check(entry is not None and entry["loop"] is server_loop,
                  "openai: owner loop bound at admission, never a worker get_running_loop")
            await answer(completion_id, event["request_id"])
            try:
                await asyncio.wait_for(response.read(), 20)
            except Exception:
                pass
            response.close()
            _i, reminders, _l = await hub_counts()
            check(not reminders, "openai: answered -> zero reminders")

            # ---- escalation shapes ------------------------------------------
            for label, llm in (("esc-escalate", _llm("escalate")),
                               ("esc-timeout", _llm("escalate")),
                               ("esc-empty", _llm("escalate"))):
                before = dict(inbox["metrics"])
                await one_approval(label, llm=llm, mode="smart")
                check(delta(before, "registry_accepted") == 1,
                      f"{label}: escalation shares the ONE inbox/cut")
            # smart APPROVE: never a human pending, never a push
            configure(mode="smart")
            with patch.object(approval, "_smart_verdict", new=_llm("approve")):
                response = await start_stream("esc-approve")
                await finish(response, "esc-approve")
            initial, _rem, _leg = await hub_counts()
            check(initial == 0 and outcomes["esc-approve"].get("approved") is True,
                  "smart APPROVE: no human pending, zero publish, policy outcome kept")
            # smart DENY WITH a live API owner: ONE smart_denied card (a DENY
            # with NO owner produces no human pending at all — the sync row below)
            with patch.object(approval, "_smart_verdict", new=_llm("deny")):
                response = await start_stream("esc-deny")
                _, event = await next_event(response, "approval.request")
                initial, _rem, _leg = await hub_counts()
                check(initial == 1, "smart DENY with owner: exactly one smart_denied card")
                snap = await pending_of(event["run_id"])
                check(snap["pending"][0]["choices"] == ["once", "deny"],
                      "smart DENY card offers once/deny only")
                await answer(event["run_id"], event["request_id"])
                await finish(response, "esc-deny")
            check(bool(outcomes["esc-deny"].get("approved")), "owner override obeyed")
            configure()

            # shapes sharing the SAME common wait (plugin escalation gate,
            # protected instruction write, MCP consent) — not special submits:
            for label in ("PLUGIN", "PWRITE", "MCP"):
                before = dict(inbox["metrics"])
                await one_approval(label)
                check(delta(before, "registry_accepted") == 1, f"{label}: one registry entry")
                if label == "MCP":
                    check(outcomes[label]["verdict"] == "accept",
                          "MCP consent obeys the exact answer (accept, never decline)")
                else:
                    check(outcomes[label].get("approved") is True,
                          f"{label}: the wait shares the API answer authority")

            # settled-before-notify race: capture must find nothing
            before = dict(inbox["metrics"])
            response = await start_stream("RACE")
            _, event = await next_event(response, "approval.request")
            initial, _rem, _leg = await hub_counts()
            check(initial == 0, "error isolation: settle-before-notify publishes no phantom")
            check(delta(before, "capture_entry_missing") >= 1,
                  "error isolation: core-entry miss is counted, not silent")
            snap = await pending_of(event["run_id"])
            check(snap["pending"] == [], "no phantom entry survives the race")
            await finish(response, "RACE")

            # ---- dedup / status replay --------------------------------------
            response = await start_stream("replay")
            _, event = await next_event(response, "approval.request")
            run_id, request_id = event["run_id"], event["request_id"]
            entry = await entry_of(run_id, request_id)
            created, timer = entry["created_mono"], entry["timer"]
            before = dict(inbox["metrics"])
            adapter._set_run_status(run_id, "waiting_for_approval",
                                    last_event="approval.request",
                                    approval=dict(adapter._run_statuses[run_id]["approval"]))
            cb = approval._gateway_notify_cb(run_id)
            cb(dict(approval.list_gateway_approvals(run_id)[0]))  # duplicate notify
            initial, _rem, _leg = await hub_counts()
            check(initial == 1, "replay: still exactly ONE initial publish")
            check(delta(before, "registry_accepted") == 0
                  and delta(before, "capture_replay") >= 2,
                  "replay: no second admission; replays counted")
            check(entry["created_mono"] == created and entry["timer"] is timer,
                  "replay: deadline untouched, reminder not re-armed")
            snap = await pending_of(run_id)
            check([p["request_id"] for p in snap["pending"]] == [request_id],
                  "replay: still the one entry, no duplicate settle chain")
            await answer(run_id, request_id)
            await finish(response, "replay")
            _i, reminders, _l = await hub_counts()
            check(not reminders, "replay: answered once -> settled once, reminders 0")

            # ---- error isolation --------------------------------------------
            # effective push settings missing: counted drop, action path intact
            before = dict(inbox["metrics"])
            configure(push="none")
            response = await start_stream("CFGMISSING")
            _, event = await next_event(response, "approval.request")
            configure()
            initial, _rem, legacy = await hub_counts()
            check(initial == 0 and legacy == 0,
                  "no config -> silence preserved (never a fake success)")
            check(delta(before, "push_dropped_config") == 1,
                  "error isolation: push_dropped has a config-vs-queue reason")
            await answer(event["run_id"], event["request_id"])
            await finish(response, "CFGMISSING")
            check(outcomes["CFGMISSING"]["approved"] is True,
                  "a push drop never blocks the answer path")

            # capture raising must not disturb the native chain
            capture_calls = {"n": 0}
            real_capture = inbox_mod.capture

            def flaky_capture(inbox_, **kwargs):
                capture_calls["n"] += 1
                if capture_calls["n"] == 1:
                    raise RuntimeError("injected capture failure")
                return real_capture(inbox_, **kwargs)

            before = dict(inbox["metrics"])
            with patch.object(inbox_mod, "capture", flaky_capture):
                response = await start_stream("CAPFAIL")
                _, event = await next_event(response, "approval.request")
                check(True, "capture exception never reaches the native notify chain")
            check(delta(before, "capture_error") >= 1, "capture failures are counted")
            await answer(event["run_id"], event["request_id"])
            await finish(response, "CAPFAIL")
            check(outcomes["CAPFAIL"]["approved"] is True,
                  "the guarded action still obeys the answer")

            # native SSE frame raising AFTER the status write: notify_failed
            real_enqueue = api._SessionEventQueue.enqueue
            fired = {"n": 0}

            def flaky_enqueue(self_q, name, payload):
                if name == "approval.request" and fired["n"] == 0:
                    fired["n"] += 1
                    raise RuntimeError("injected SSE enqueue failure")
                return real_enqueue(self_q, name, payload)

            with patch.object(api._SessionEventQueue, "enqueue", flaky_enqueue):
                response = await start_stream("NOTIFYRAISE")
                try:
                    await next_event(response, "approval.request", timeout=4)
                    frame = True
                except AssertionError:
                    frame = False
                check(not frame, "notify raise: the frame never claims delivery")
            await finish(response, "NOTIFYRAISE")
            check(outcomes["NOTIFYRAISE"].get("approved") is False,
                  "error isolation: a notify failure never auto-executes the action")
            initial, _rem, _leg = await hub_counts()
            check(initial <= 1, "notify raise: at most the one honest initial")
            check(not any(e["phase"] == "pending"
                          for bucket in inbox["by_run"].values()
                          for e in bucket["entries"].values()),
                  "notify raise: no pending card survives")

            # send-path failure: enqueue accepted, send failed, counted apart
            configure(push="dead")
            before = dict(inbox["metrics"])
            response = await start_stream("SENDFAIL")
            _, event = await next_event(response, "approval.request")
            check(delta(before, "push_enqueued") >= 1,
                  "send failure: accepted-enqueue must NOT be reported as delivered")
            await wait_delta(before, "send_fail", 1)
            await answer(event["run_id"], event["request_id"])
            await finish(response, "SENDFAIL")
            configure()

            # registry overflow: degraded + available False, answers still fine
            before = dict(inbox["metrics"])
            with patch.object(inbox_mod, "INBOX_MAX_PENDING", 1):
                response = await start_stream("QFULL")
                _, first = await next_event(response, "approval.request")
                await answer(first["run_id"], first["request_id"])
                _, second = await next_event(response, "approval.request")
                check(delta(before, "registry_dropped") >= 1, "overflow counted, not silent")
                snap = await pending_of(second["run_id"])
                check(snap["overflow"] is True and snap["available"] is False,
                      "overflow/unmapped ids surface honestly, never folded into []")
                await answer(second["run_id"], second["request_id"])
            await finish(response, "QFULL", timeout=30)
            results = outcomes["QFULL"]
            check(results["a"].get("approved") and results["b"].get("approved"),
                  "overflow entries stay answerable through the native contract")
            bucket = inbox["by_run"].get((id(adapter), second["run_id"]))
            if bucket is not None:
                bucket["degraded"] = False

            # ---- boundary rows (asserted limits, not hidden gaps) -----------
            # sync /chat has no answerable approval run: original unattended
            # policy, no pending, no push, no five-minute park.
            await hub_counts()  # QFULL publishes stay in the QFULL row's oracle
            before = dict(inbox["metrics"])
            t0 = time.monotonic()
            async with client.post(f"/api/sessions/{sid}/chat", json={"message": "SYNC-DENY"},
                                   headers=AUTH) as r:
                check(r.status == 200, "sync chat completes")
            check(time.monotonic() - t0 < 20, "sync path never parks 300 seconds")
            initial, _rem, _leg = await hub_counts()
            check(initial == 0 and delta(before, "registry_accepted") == 0,
                  "boundary: no answerable run -> no pending, no push (not covered, by design)")

            # approvals.mode=off: original policy outcome, zero pending, zero push
            configure(mode="off")
            response = await start_stream("MODEOFF")
            await finish(response, "MODEOFF")
            initial, _rem, _leg = await hub_counts()
            check(outcomes["MODEOFF"].get("approved") is True and initial == 0,
                  "mode off: policy outcome kept, nothing pushed")
            configure()

            # ---- rollback ----------------------------------------------------
            # capability off AFTER the callback exists: the per-invocation check
            # silences the already-built producer immediately.
            response = await start_stream("ROLLBACK")
            _, first = await next_event(response, "approval.request")
            inbox_mod.set_capability(False)
            async with client.get(f"/v1/runs/{first['run_id']}/approvals", headers=AUTH) as r:
                check(r.status == 404, "disabled GET is a stable 404, never fake pending")
            async with client.get("/v1/capabilities", headers=AUTH) as r:
                caps = await r.json()
                check(caps["features"]["approval_inbox"]["enabled"] is False,
                      "disabled capability advertised honestly")
            await answer(first["run_id"], first["request_id"])
            _, second = await next_event(response, "approval.request")
            await asyncio.sleep(0.4)
            entries = inbox["by_run"].get((id(adapter), second["run_id"]), {}).get("entries", {})
            check(second["request_id"] not in entries,
                  "rollback: a callback built earlier stops capturing the moment it flips")
            initial, _rem, _leg = await hub_counts()
            check(initial == 1, "rollback: the disabled window pushes nothing new")
            async with client.post(f"/v1/runs/{second['run_id']}/approval",
                                   json={"choice": "once", "request_id": second["request_id"]},
                                   headers=AUTH) as r:
                check(r.status == 200, "native answer path is untouched by the kill switch")
            await finish(response, "ROLLBACK", timeout=30)
            inbox_mod.set_capability(True)
            _i, reminders, _l = await hub_counts()
            check(not reminders, "rollback: settled requests never get reminders")

            # loop-metadata / dispatcher-liveness summary for the whole case
            check(inbox["metrics"].get("loop_unbound", 0) == 0,
                  "loop metadata: no capture ever ran without its admission loop")
            check(inbox["metrics"].get("dispatch_none", 0) == 0,
                  "dispatcher was live for every admission in this case")
    finally:
        if agent_patch is not None:
            agent_patch.stop()
        _timeout_guard.stop()
        inbox_mod.set_capability(True)  # back to the shipped default
