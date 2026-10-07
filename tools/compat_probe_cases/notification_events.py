"""STEERWEB R6 (B4): the notification events ledger families.

The ledger is exercised through its REAL integration points: the single
_set_run_status terminal entrance, approval_push's dispatcher gate (real
capture + real ntfy JSON worker into a loopback hub), the browser claim REST,
and the steer.ready opt-in hook. Only the agent turn and the hub are fixtures.
"""
from __future__ import annotations
import asyncio
import os
import sys
import threading
import time
from pathlib import Path
from unittest.mock import patch

COMMAND = "rm -rf /tmp/compat-probe-events-never"


def _module(suffix):
    for name, mod in list(sys.modules.items()):
        if name.endswith("compat." + suffix):
            return mod
    raise AssertionError(f"{suffix} module not loaded by the plugin")


async def case_notification_events(args, server, check):
    from hermes_state import SessionDB
    from gateway.platforms import api_server as api
    from .approval_push import JsonHub
    from tools import approval as approval_mod
    from .offline import AUTH

    events = _module("notification_events")
    store = _module("notification_store")
    hub = JsonHub()
    hub_url = await hub.start()
    home = Path(os.environ["HERMES_HOME"])

    def configure(*, push="hub"):
        import json as _json
        config = _json.loads((home / "config.yaml").read_text())
        config.setdefault("approvals", {})["mode"] = "manual"
        config.setdefault("security", {})["tirith_fail_open"] = True
        if push == "hub":
            config["push"] = {"ntfy_server": hub_url, "ntfy_topic": "compat-probe-events"}
        else:
            config.pop("push", None)
        (home / "config.yaml").write_text(_json.dumps(config))

    configure(push="hub")
    state = getattr(api, "_hermes_app_compat_state_v1")
    check(state["manifest"]["notification_events"]["status"] == "applied",
          "notification_events applied")
    check(state.get("approval_inbox", {}).get("notify_gate") is not None,
          "approval dispatcher gate wired")
    check(state.get("steer_inbox", {}).get("ready_hook") is not None,
          "steer.ready hook wired")
    events.set_capability(True)

    class Agent:
        session_prompt_tokens = session_completion_tokens = session_total_tokens = 0
        provider, model = "fixture", "compat-fixture"

        def __init__(self, **kwargs):
            self.session_id = kwargs.get("session_id")
            self.interrupted = False
            self._released = threading.Event()
            self.approve_once = False

        def interrupt(self, *args, **kwargs):
            self.interrupted = True
            self._released.set()

        def run_conversation(self, user_message, **kwargs):
            label = str(user_message)
            if label.startswith("GATE"):
                check(self._released.wait(60), "fixture turn released")
            elif label.startswith("ASK"):
                approval_mod.check_dangerous_command(COMMAND, env_type="local")
            return {"final_response": "done", "messages": [],
                    "interrupted": self.interrupted}

    agents = []

    def make_agent(**kw):
        agent = Agent(**kw)
        agents.append(agent)
        return agent

    async def hub_settled(timeout=25.0):
        await hub.settle(timeout=timeout)
        counts = (len(hub.approval()), len([p for p in hub.legacy()]),
                  len([p for p in hub.posts if "run completed" in p["title"] or
                       "run failed" in p["title"]]))
        hub.posts.clear()
        return counts

    try:
        async with server() as (adapter, client):
            db = SessionDB(Path("notification_events.db"))
            sid = db.create_session("compat-events", "api_server")
            adapter._session_db = db
            adapter._max_concurrent_runs = 8
            with patch.object(adapter, "_create_agent", side_effect=make_agent):

                async def start(label, *, hold):
                    response = await client.post(f"/api/sessions/{sid}/chat/stream",
                                                 json={"message": label}, headers=AUTH)
                    check(response.status == 200, f"{label}: SSE accepted")
                    run_id, seen = None, len(agents)
                    deadline = time.monotonic() + 20
                    while len(agents) == seen:
                        rows = [rid for rid, st in getattr(adapter, "_run_statuses", {}).items()
                                if (st or {}).get("session_id") == sid]
                        if rows:
                            run_id = rows[-1]
                        check(time.monotonic() < deadline, f"{label}: agent created")
                        await asyncio.sleep(0.02)
                    agent = agents[-1]
                    if not hold:
                        agent._released.set()
                    return run_id, agent, response

                async def events_get(after=0):
                    async with client.get("/api/notification-events",
                                          params={"after": after}, headers=AUTH) as r:
                        return r.status, await r.json()

                async def events_walk(after=0):
                    """Full pass following next_cursor; returns (events, cursor)."""
                    seen, cursor, pages = [], after, 0
                    while True:
                        status, listed = await events_get(cursor)
                        check(status == 200, "events page answers")
                        seen.extend(listed["data"])
                        cursor = int(listed.get("next_cursor", listed["head_seq"]))
                        pages += 1
                        if not listed["overflow"]:
                            return seen, cursor
                        check(pages <= 10, "overflow pages terminate")

                # R7 click spy on the single worker's send seam (real publish path)
                ntfy_mod = None
                for name, mod in list(sys.modules.items()):
                    if name.endswith("compat.ntfy_notify"):
                        ntfy_mod = mod
                check(ntfy_mod is not None, "compat ntfy worker module present")
                clicks = []
                orig_send = ntfy_mod._send
                def spy(job):
                    if job[0] == "json" and len(job[1]) > 7:
                        clicks.append(job[1][7])
                    return orig_send(job)
                ntfy_mod._send = spy

                # ---- terminal completed: ledger owns ONE publish, SSE attached ----
                run1, agent1, resp1 = await start("FREE-ONE", hold=False)
                counts = await hub_settled()
                check(counts[2] == 1, f"exactly ONE completed publish for the terminal "
                                     f"event (counts={counts})")
                deep = [c for c in clicks if c and "#/chat" in c]
                check(len(deep) == 1 and "run=" in deep[0] and "event=" in deep[0]
                      and deep[0].startswith("https://")
                      and "key=" not in deep[0] and "topic=" not in deep[0]
                      and "Bearer" not in deep[0],
                      f"the completed push carries the R7 deep link, no secrets (clicks={clicks})")
                status, listed = await events_get()
                check(status == 200 and listed["server_channel"] == "ntfy"
                      and any(e["kind"] == "completed" and e["run_id"] == run1
                              and e["payload"].get("summary") is not None
                              for e in listed["data"]),
                      "completed recorded once with a whitelisted payload")
                event1 = next(e for e in listed["data"] if e["kind"] == "completed")
                eid = store.event_id_for(event1["run_id"] and
                                         _scope(adapter, client) or "", run1,
                                         "completed", "terminal")
                check(eid == event1["event_id"], "event_id is the stable owner+run+kind hash")
                replay = events.deliver(events.registry(),
                                        owner_scope=_scope(adapter, client),
                                        run_id=run1, sid=sid, kind="completed",
                                        source_id="terminal", payload={},
                                        publish=lambda: True)
                check(replay[1].startswith("already") and replay[0] == event1["event_id"],
                      "replaying the same semantic event publishes NOTHING again")
                await hub.settle(timeout=6)
                check(not [p for p in hub.posts if "run completed" in p["title"]],
                      "the ledger replay produced no hub traffic")
                hub.posts.clear()
                resp1.close()

                # ---- cancelled: recorded, never pushed ----------------------------
                run2, agent2, resp2 = await start("GATE-TWO", hold=True)
                async with client.post(f"/v1/runs/{run2}/stop", headers=AUTH) as r:
                    check(r.status == 200, "stop accepted")
                deadline = time.monotonic() + 15
                while True:
                    async with client.get(f"/v1/runs/{run2}", headers=AUTH) as r:
                        settled = (await r.json())["status"] in ("cancelled", "completed")
                    check(time.monotonic() < deadline, "cancelled settles")
                    if settled:
                        break
                    await asyncio.sleep(0.05)
                counts = await hub_settled()
                check(counts[2] == 0, "cancelled terminals publish NOTHING")
                status, listed = await events_get()
                check(any(e["kind"] == "cancelled" and e["run_id"] == run2
                          for e in listed["data"]),
                      "the cancelled terminal is still recorded for the inbox")

                # ---- approval: initial publish routed ONCE through the ledger -----
                run3, agent3, resp3 = await start("ASK-THREE", hold=True)
                deadline = time.monotonic() + 20
                while not hub.approval():
                    check(time.monotonic() < deadline, "approval initial published")
                    await asyncio.sleep(0.05)
                await hub.settle(timeout=6)
                check(len(hub.approval()) == 1, "exactly ONE initial approval publish")
                aclicks = [c for c in clicks if c and "request=" in c]
                check(len(aclicks) == 1 and aclicks[0].startswith("https://")
                      and "run=" in aclicks[0] and "key=" not in aclicks[0],
                      "the approval push carries its exact deep link locator")
                status, listed = await events_get()
                approval_events = [e for e in listed["data"]
                                   if e["kind"] == "approval_request"]
                check(status == 200 and len(approval_events) == 1,
                      "the approval request is one semantic event")
                aevent = approval_events[0]
                reg = events.registry()
                scope = _scope(adapter, client)
                check(events.reminder_allowed(reg, owner_scope=scope, run_id=run3,
                                              request_id=aevent["source_id"],
                                              pending=True) is True,
                      "a reminder is allowed while unread and unclaimed")
                # 01412 M4: allowed must mean DELIVERED. The reminder is a new
                # phase on the SAME channel — it really publishes.
                rem = []
                handled, rem_ok = events.approval_initial_hook(reg)(
                    "reminder", {"entry": {"owner_scope": scope, "run_id": run3,
                                           "session_id": sid,
                                           "request_id": aevent["source_id"]},
                                 "pending": True,
                                 "publish": lambda: rem.append(1) or True})
                check(handled and rem_ok and rem == [1],
                      f"initial -> reminder publishes TWICE on the same channel "
                      f"(handled={handled} ok={rem_ok} calls={rem})")
                phases = {p for p, _c, _s in store.sent_phases(
                    events.home_of(reg), aevent["event_id"])}
                check({"initial", "reminder"} <= phases,
                      "the ledger shows BOTH delivery phases of the event")
                # 01412 M2: a device B that pulled everything up to THIS cursor
                # must SEE device A's later read on the very next delta.
                _, cursorB = await events_walk()
                async with client.post(f"/api/notification-events/{aevent['event_id']}/read",
                                       headers=AUTH) as r:
                    check(r.status == 200, "read ack accepted")
                async with client.post(f"/api/notification-events/{aevent['event_id']}/read",
                                       headers=AUTH) as r:
                    check(r.status == 200, "read is idempotent")
                status, delta = await events_get(cursorB)
                check(status == 200 and any(
                    e["event_id"] == aevent["event_id"] and e.get("read_at")
                    for e in delta["data"]),
                    "a converged read is OBSERVABLE on the incremental cursor "
                    "from the already-caught-up position (no phantom unread)")
                check(events.reminder_allowed(reg, owner_scope=scope, run_id=run3,
                                              request_id=aevent["source_id"],
                                              pending=True) is False,
                      "a READ approval event cancels later reminders (cross-device)")
                status, listed = await events_get()
                read_now = next(e for e in listed["data"]
                                if e["event_id"] == aevent["event_id"])
                check(read_now["read_by"] >= 1 and read_now["read_at"],
                      "the read ledger surfaces acks on the events cursor")
                # settle the native approval unchanged: read is NOT approve
                async with client.get(f"/v1/runs/{run3}/approvals", headers=AUTH) as r:
                    pending = (await r.json())
                check(len(pending.get("pending") or pending.get("requests") or []) == 1,
                      "read did not touch the native pending approval")
                rid = (pending.get("pending") or pending.get("requests"))[0]["request_id"]
                async with client.post(f"/v1/runs/{run3}/approval",
                                       json={"choice": "once", "request_id": rid},
                                       headers=AUTH) as r:
                    check(r.status == 200, "exact approval answer still works")
                # ---- 01412 M3: a >100-event backlog pages WITHOUT skipping -----
                _, base = await events_walk()
                for i in range(101):
                    store.record_event(events.home_of(reg), owner_scope=scope,
                                       run_id=f"paged-{i}", sid=sid,
                                       kind="completed", source_id="terminal",
                                       payload={"summary": f"page-{i}"})
                status, first = await events_get(base)
                check(status == 200 and first["overflow"] is True
                      and len(first["data"]) == 100,
                      "a 101-event backlog answers a full page and says overflow")
                check(int(first["next_cursor"]) == int(first["data"][-1]["created_seq"])
                      and int(first["next_cursor"]) < int(first["head_seq"]),
                      "next cursor is the LAST DELIVERED seq, never the head")
                collected, endCursor = await events_walk(base)
                ids = [e["event_id"] for e in collected]
                check(len(ids) == len(set(ids)) and len(ids) >= 101,
                      f"continuation pages deliver every event exactly once "
                      f"(got {len(ids)})")
                agent3._released.set()
                resp3.close()

                # ---- steer.ready: ONLY for opted-in runs ---------------------------
                run4, agent4, resp4 = await start("GATE-FOUR", hold=True)
                async with client.post("/api/notification-events/steer-ready-watch",
                                       json={"run_id": "run-not-live"}, headers=AUTH) as r:
                    check(r.status == 200, "watch endpoint answers")
                status, listed = await events_get()
                check(not any(e["kind"] == "steer_ready" for e in listed["data"]),
                      "no steer.ready without a watch registration")
                agent4._released.set()
                resp4.close()
                # register a watch, then a fresh run's queued->running transition fires it
                # (M3 made the backlog multi-page: full-list views must FOLLOW
                # next_cursor, never assume page 1 is everything)
                watch_target = "run_watch_probe"
                async with client.post("/api/notification-events/steer-ready-watch",
                                       json={"run_id": watch_target, "watch": True},
                                       headers=AUTH) as r:
                    check(r.status == 200, "watch registered")
                events.steer_ready(reg, owner_scope=scope, run_id=watch_target, sid=sid)
                listed, _ = await events_walk()
                check(any(e["kind"] == "steer_ready" for e in listed),
                      "an opted-in run's accepting transition records steer.ready")
                events.steer_ready(reg, owner_scope=scope, run_id="run-never-watched",
                                   sid=sid)
                listed, _ = await events_walk()
                check(len([e for e in listed if e["kind"] == "steer_ready"]) == 1,
                      "non-watched runs never generate steer.ready events")

                # ---- browser channel: claim once, never re-routed ------------------
                configure(push="none")
                status, caps = None, None
                async with client.get("/v1/capabilities", headers=AUTH) as r:
                    caps = (await r.json())["features"]["notification_events"]
                check(caps["system_channel"] == "browser", "no-ntfy accounts route to browser")
                event_id, created = store.record_event(
                    events.home_of(reg), owner_scope=scope, run_id="run-browser",
                    sid=sid, kind="failed", source_id="terminal",
                    payload={"summary": "queued for browser"})
                check(created, "browser event recorded")
                async with client.post(f"/api/notification-events/{event_id}/claim",
                                       json={"device_id": "dev-A",
                                             "delivery_id": "d-1"}, headers=AUTH) as r:
                    first = await r.json()
                    check(r.status == 200 and first["verdict"] == "claimed"
                          and first["show_token"], "first claim gets the one show grant")
                async with client.post(f"/api/notification-events/{event_id}/claim",
                                       json={"device_id": "dev-B",
                                             "delivery_id": "d-2"}, headers=AUTH) as r:
                    second = await r.json()
                    check(second["verdict"] == "already_claimed"
                          and second["show_token"] is None,
                          "the second device/tab is told already_claimed")
                async with client.post(f"/api/notification-events/{event_id}/delivery",
                                       json={"delivery_id": first["delivery_id"],
                                             "show_token": first["show_token"],
                                             "outcome": "shown"}, headers=AUTH) as r:
                    check(r.status == 200, "claim owner reports shown")
                # 01412 M1: the report transaction refuses anything but the
                # claim owner's exact token/device — the row is not a free-for-all.
                async with client.post(f"/api/notification-events/{event_id}/delivery",
                                       json={"delivery_id": first["delivery_id"],
                                             "show_token": "not-the-token",
                                             "outcome": "failed"}, headers=AUTH) as r:
                    check(r.status == 404,
                          "a wrong show_token cannot rewrite a delivery")
                async with client.post(f"/api/notification-events/{event_id}/delivery",
                                       json={"delivery_id": first["delivery_id"],
                                             "show_token": first["show_token"],
                                             "device_id": "not-the-claimer",
                                             "outcome": "failed"}, headers=AUTH) as r:
                    check(r.status == 404,
                          "a foreign device_id cannot rewrite the claim owner's row")
                listed, _ = await events_walk()
                shown_now = next((e for e in listed if e["event_id"] == event_id), None)
                check(shown_now is not None, "the browser event is still listed")
                check(store.delivery_state(events.home_of(reg), event_id,
                                           "initial", "browser") == "shown",
                      "refused reports leave the delivery state exactly 'shown'")
                # 01412 M5: the REAL deliver() path must leave a pending
                # INTENT a device can actually win (server pre-claim was the
                # bug that made the whole browser channel dead).
                eidB, verdictB = events.deliver(events.registry(), owner_scope=scope,
                                                run_id="run-browser-2", sid=sid,
                                                kind="failed", source_id="terminal",
                                                payload={})
                check(verdictB == "queued",
                      f"deliver queues a pending INTENT, not a server claim "
                      f"({verdictB})")
                async with client.post(f"/api/notification-events/{eidB}/claim",
                                       json={"device_id": "dev-C"}, headers=AUTH) as r:
                    claimC = await r.json()
                    check(r.status == 200 and claimC["verdict"] == "claimed"
                          and claimC["show_token"],
                          "the device wins the pending intent with a show grant")
                async with client.post(f"/api/notification-events/{eidB}/delivery",
                                       json={"delivery_id": claimC["delivery_id"],
                                             "show_token": claimC["show_token"],
                                             "outcome": "shown"}, headers=AUTH) as r:
                    check(r.status == 200, "the claiming device reports shown")
                replayV = events.deliver(events.registry(), owner_scope=scope,
                                         run_id="run-browser-2", sid=sid,
                                         kind="failed", source_id="terminal",
                                         payload={})
                check(replayV[1].startswith("already"),
                      f"a settled delivery replays as already_* ({replayV[1]})")

                configure(push="hub")  # config change must NOT re-route the claim
                outcome = events.deliver(events.registry(), owner_scope=scope,
                                         run_id="run-browser", sid=sid, kind="failed",
                                         source_id="terminal", payload={},
                                         publish=lambda: hub.posts.append(
                                             {"title": "MUST NOT HAPPEN", "message": "",
                                              "priority": "", "tags": [], "json": True}))
                check(outcome[1].startswith("already"),
                      "an already-claimed delivery is never re-routed to ntfy")
                check(not [p for p in hub.posts if "run failed" in p["title"]],
                      "no ntfy publish happened for the browser-claimed event")
                hub.posts.clear()

                # ---- kill switch: old policy, routes closed -------------------------
                events.set_capability(False)
                status, listed = await events_get()
                check(status == 404, "events endpoint closes with the kill switch")
                run5, agent5, resp5 = await start("FREE-OFF", hold=False)
                counts = await hub_settled()
                check(counts[2] == 0, "cap-off attached SSE keeps the LEGACY zero-push policy")
                resp5.close()

    finally:
        events.set_capability(False)
    return None


def _scope(adapter, client=None):
    """Same derivation the routes use for this single-key probe listener."""
    import hashlib
    from gateway.platforms import api_server as api
    key = adapter._expected_api_key() or "unauthenticated-test-listener"
    profile = api._api_request_profile.get() or "default"
    return hashlib.sha256(("\0").join([str(profile), str(key)]).encode()).hexdigest()
