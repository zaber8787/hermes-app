"""STEERWEB (R9): the durable run-scoped steer inbox server contract.

Real HTTP routes, real adapter/run binding, real installed hooks (the tool
boundary wrapper and the flush-confirmation wrapper are called THROUGH the
replaced class/module bindings); only the agent turn itself is a fixture.
Families: auth/capability, admission/idempotency, two-device ordering,
stop/finish races, safe tool boundary, persist confirmation, restart recovery
and the kill switch. Legacy only-input bodies stay on the SAME inbox while
enabled — the native _pending_steer bypass is only ever the cap-off path.
"""
from __future__ import annotations
import asyncio
import os
import sys
import threading
import time
from pathlib import Path
from unittest.mock import patch


def _steer_module(suffix):
    for name, mod in list(sys.modules.items()):
        if name.endswith("compat." + suffix):
            return mod
    raise AssertionError(f"{suffix} module not loaded by the plugin")


async def case_steer_inbox(args, server, check):
    from hermes_state import SessionDB
    from gateway.platforms import api_server as api
    from agent import prompt_builder as pb
    from .offline import AUTH

    steer_inbox = _steer_module("steer_inbox")
    steer_store = _steer_module("steer_store")
    home = Path(os.environ["HERMES_HOME"])
    state = getattr(api, "_hermes_app_compat_state_v1")
    check(state["manifest"]["steer_inbox"]["status"] == "applied", "steer_inbox applied")
    inbox = state["steer_inbox"]
    check(inbox["epoch"] == state.get("activity_epoch"), "epoch correlation with activity")
    steer_inbox.set_capability(True)

    class Agent:
        session_prompt_tokens = session_completion_tokens = session_total_tokens = 0
        provider, model = "fixture", "compat-fixture"

        def __init__(self, **kwargs):
            self.session_id = kwargs.get("session_id")
            self.interrupted = False
            self.steer_notes = []
            self.label = None
            # run_conversation executes on the run's worker thread: threading,
            # not asyncio, is the honest primitive here.
            self._released = threading.Event()

        def interrupt(self, *args, **kwargs):
            self.interrupted = True
            self._released.set()

        def steer(self, text):  # native buffer surface, cap-off rows only
            self.steer_notes.append(text)
            return True

        def run_conversation(self, user_message, **kwargs):
            self.label = str(user_message)
            check(self._released.wait(90), "fixture turn released before fuse")
            return {"final_response": "done", "messages": [], "interrupted": self.interrupted}

    agents = []

    def make_agent(**kw):
        agent = Agent(**kw)
        agents.append(agent)
        return agent

    try:
        async with server() as (adapter, client):
            db = SessionDB(Path("steer_inbox.db"))
            sid = db.create_session("compat-steer", "api_server")
            adapter._session_db = db
            adapter._max_concurrent_runs = 8
            with patch.object(adapter, "_create_agent", side_effect=make_agent):

                async def start_stream(label, *, release=True):
                    response = await client.post(f"/api/sessions/{sid}/chat/stream",
                                                 json={"message": label}, headers=AUTH)
                    check(response.status == 200, f"{label}: SSE accepted")
                    run_id = None
                    agent = None
                    deadline = time.monotonic() + 20
                    while agent is None:
                        snap = _activity_runs(adapter, sid)
                        if snap:
                            run_id = snap[-1]
                            agent = getattr(adapter, "_active_run_agents", {}).get(run_id)
                        check(time.monotonic() < deadline,
                              f"{label}: bound run appears (snap={snap} statuses="
                              f"{ {k: (v or {}).get('status') for k, v in getattr(adapter, '_run_statuses', {}).items()} }"
                              f" agents={list(getattr(adapter, '_active_run_agents', {}))})")
                        if agent is None:
                            await asyncio.sleep(0.02)
                    if release:
                        agent._released.set()
                    return run_id, agent, response

                def _activity_runs(adp, session_id):
                    return [rid for rid, st in getattr(adp, "_run_statuses", {}).items()
                            if (st or {}).get("session_id") == session_id]

                async def steer_post(run_id, *, body, headers=None):
                    async with client.post(f"/v1/runs/{run_id}/steer", json=body,
                                           headers=headers or AUTH) as r:
                        return r.status, await r.json()

                async def steers_get(run_id, **qs):
                    async with client.get(f"/v1/runs/{run_id}/steers", params=qs,
                                          headers=AUTH) as r:
                        return r.status, await r.json()

                async def receipt_get(run_id, steer_id):
                    async with client.get(f"/v1/runs/{run_id}/steers/{steer_id}",
                                          headers=AUTH) as r:
                        return r.status, await r.json()

                # ---- auth ----------------------------------------------------
                status, _ = await steers_get("run_never_existed")
                check(status in (403, 404), f"unknown run is refused: {status}")
                async with client.get("/v1/runs/whatever/steers",
                                      headers={"Authorization": "***"}) as r:
                    check(r.status in (401, 403), "no/wrong key refused")

                # ---- capability advertisement --------------------------------
                async with client.get("/v1/capabilities", headers=AUTH) as r:
                    caps = (await r.json())["features"]["steer_inbox"]
                check(caps["enabled"] is True and caps["idempotent"] is True
                      and caps["contract_version"] == 1 and caps["run_bound"] is True
                      and "{run_id}" in caps["receipt_endpoint"],
                      "capability advertises the exact R1 shape while enabled")

                # ---- live admission rows --------------------------------------
                run_id, agent, response = await start_stream("STEER-ROW", release=False)
                status, body = await steer_post(run_id, body={
                    "input": "  use the second index  ", "client_request_id": "k-1",
                    "session_id": sid, "server_epoch": inbox["epoch"]})
                check(status == 200 and body["accepted"] is True and body["sequence"] == 1
                      and body["state"] == "accepted" and body["object"] == "hermes.run.steer"
                      and body["run_id"] == run_id and body["server_epoch"] == inbox["epoch"],
                      "v1 admission receipt is exact")
                check(body.get("session_id") in (sid, None) or body["session_id"] == sid,
                      "receipt echoes the run's session")
                status, lst = await steers_get(run_id)
                check(status == 200 and lst["accepting"] is True
                      and lst["revision"] == 1 and len(lst["steers"]) == 1
                      and lst["steers"][0]["steer_id"] == body["steer_id"],
                      f"GET lists the admitted item with revision "
                      f"(status={status} accepting={lst.get('accepting')} "
                      f"reason={lst.get('accepting_reason')} rev={lst.get('revision')} "
                      f"n={len(lst.get('steers', []))})")
                status, one = await steers_get(run_id, after_seq=1)
                check(status == 200 and one["steers"] == [], "seq cursor pages forward")
                status, rc = await receipt_get(run_id, body["steer_id"])
                check(status == 200 and rc["sequence"] == 1 and rc["state"] == "accepted"
                      and "input" not in rc, "receipt endpoint matches, never echoes input")
                status, err = await steer_post(run_id, body={
                    "input": "x", "client_request_id": "k-9",
                    "server_epoch": "epoch-from-another-life"})
                check(status == 409 and err["error"]["code"] == "steer_epoch_stale",
                      f"foreign server_epoch is refused without side effects "
                      f"(status={status} err={err})")
                status, err = await steer_post(run_id, body={
                    "input": "x", "client_request_id": "k-8", "session_id": "sid-not-this"})
                check(status == 409 and err["error"]["code"] == "steer_stale_target",
                      "mismatched session is refused")
                status, err = await steers_get(run_id, after_seq="not-a-number")
                check(status == 400, "cursor is validated")

                # ---- idempotency -----------------------------------------------
                codes = await asyncio.gather(*[steer_post(run_id, body={
                    "input": "same text", "client_request_id": "k-dup"})
                    for _ in range(100)])
                ids = {b["steer_id"] for c, b in codes}
                dup_id = codes[0][1]["steer_id"]
                seqs = {b["sequence"] for c, b in codes}
                check(all(c == 200 for c, _ in codes) and len(ids) == 1 and len(seqs) == 1,
                      "100 same-key posts -> ONE receipt (two-device retry safe)")
                status, err = await steer_post(run_id, body={
                    "input": "different content", "client_request_id": "k-dup"})
                check(status == 409 and err["error"]["code"] == "steer_identity_conflict",
                      "same key, other content is a hard conflict")
                more = [await steer_post(run_id, body={"input": f"q{ i}",
                                                       "client_request_id": f"kq-{i}"})
                        for i in range(30)]
                check(all(c == 200 for c, _ in more), "queue fills to the 32-outstanding cap")
                status, err = await steer_post(run_id, body={"input": "one too many",
                                                            "client_request_id": "k-over"})
                check(status == 429 and err["error"]["code"] == "steer_queue_full",
                      "over-cap POST is 429 without a half receipt")
                _s, lst = await steers_get(run_id)
                check(len(lst["steers"]) == 32, "exactly 32 outstanding receipts exist")

                # ---- body limits / legacy ---------------------------------------
                status, _ = await steer_post(run_id, body={"input": "x" * (9 * 1024)})
                check(status == 400, "oversized input is 400")
                async with client.post(f"/v1/runs/{run_id}/steer",
                                       data=b"{}" + b"x" * (64 * 1024 + 10),
                                       headers={**AUTH, "Content-Type": "application/json"}) as r:
                    check(r.status == 413, "oversized body is 413 before parsing")

                # ---- kill switch: legacy native ONLY with cap OFF ----------------
                steer_inbox.set_capability(False)
                async with client.get("/v1/capabilities", headers=AUTH) as r:
                    caps = (await r.json())["features"]["steer_inbox"]
                check(caps["enabled"] is False, "capability follows the kill switch at once")
                status, _ = await steer_post(run_id, body={"input": "native only when off"})
                check(status == 200 and "native only when off" in agent.steer_notes,
                      "cap-off legacy steer rides the native buffer (no receipt minted)")
                _s, lst = await steers_get(run_id)
                check(len(lst["steers"]) == 32, "cap-off steer created no inbox receipt")
                steer_inbox.set_capability(True)

                # ---- legacy input-only stays on the SAME inbox when enabled ------
                run2, agent2, resp2 = await start_stream("STEER-LEGACY", release=False)
                status, body2 = await steer_post(run2, body={"input": "legacy body"})
                check(status == 200 and body2["accepted"] is True
                      and body2.get("steer_id") and body2["sequence"] == 1,
                      "legacy body is admitted through the SAME inbox when enabled")
                check(not agent2.steer_notes, "enabled legacy rows never take the bypass")

                # ---- two-device ordering -----------------------------------------
                run3, agent3, resp3 = await start_stream("STEER-ORDER", release=False)
                races = await asyncio.gather(*[
                    steer_post(run3, body={"input": f"from-{ i}", "client_request_id": f"kr-{i}"})
                    for i in range(8)])
                seqs = sorted(b["sequence"] for c, b in races)
                check(seqs == list(range(1, 9)) and len({b["steer_id"] for _, b in races}) == 8,
                      "concurrent device POSTs get distinct monotonic server seq")
                _s, lst = await steers_get(run3)
                check([r["sequence"] for r in lst["steers"]] == list(range(1, 9)),
                      "listing is server-commit ordered")

                # ---- stop / finish races ------------------------------------------
                agent2._released.set()
                agent3._released.set()
                # stop FIRST: the running turn is interrupted (the fixture gate
                # opens via interrupt()); releasing first would let the run
                # complete and the stop answer 409 instead of 200.
                async with client.post(f"/v1/runs/{run_id}/stop", headers=AUTH) as r:
                    check(r.status == 200, f"stop accepted (status={r.status})")
                deadline = time.monotonic() + 15
                while True:
                    async with client.get(f"/v1/runs/{run_id}", headers=AUTH) as r:
                        done = (await r.json())["status"] in ("cancelled", "completed")
                    check(time.monotonic() < deadline, "stopped run settles")
                    if done:
                        break
                    await asyncio.sleep(0.05)
                status, err = await steer_post(run_id, body={"input": "too late",
                                                            "client_request_id": "k-after"})
                check(status == 409 and err["error"]["code"] == "run_closed",
                      "terminal/stop seal refuses new admission")
                _s, lst = await steers_get(run_id)
                states = {r["state"] for r in lst["steers"]}
                check(states == {"not_delivered"},
                      "unclaimed accepted items retired exactly to not_delivered")
                status, rc = await receipt_get(run_id, body["steer_id"])
                check(status == 200 and rc["state"] == "not_delivered",
                      "receipt still answers after the run is gone")
                status, dup = await steer_post(run_id, body={"input": "same text",
                                                            "client_request_id": "k-dup"})
                check(status == 200 and dup["steer_id"] == dup_id
                      and dup.get("accepted") is not False,
                      f"post-terminal same-key retry answers with the ORIGINAL receipt "
                      f"(status={status} dup={dup})")

                # ---- safe tool boundary: the INSTALLED class wrapper ----------------
                class Steerable:
                    def _drain_pending_steer(self):
                        return ""  # native buffer empty: only the inbox path acts

                fake = Steerable()
                fake_adapter = type("A", (), {"_run_owners": {"probe-run": "scope-probe"}})()
                steer_inbox.bind_agent(inbox, fake_adapter, "probe-run", fake)
                import run_agent as run_agent_module
                apply_hook = run_agent_module.AIAgent._apply_pending_steer_to_tool_results

                def inject(n, tail):
                    return apply_hook(fake, tail, n)

                def tail_complete(extra_user=None):
                    rows = [{"role": "user", "content": "go"},
                            {"role": "assistant", "tool_calls": [{"id": "t1"}, {"id": "t2"}]},
                            {"role": "tool", "tool_call_id": "t1", "content": "ok"},
                            {"role": "tool", "tool_call_id": "t2", "content": "ok"}]
                    if extra_user is not None:
                        rows.append(extra_user)
                    return rows

                # seed accepted items directly through the store (admission already proven)
                store = steer_store.open_store(steer_inbox.home_of(inbox))
                steer_store.register_run(store, "scope-probe", "probe-run",
                                         owner_epoch=inbox["epoch"])
                v1, r1 = steer_store.admit(store, "scope-probe", "probe-run",
                                           key="b1", input_text="first steer")
                v2, r2 = steer_store.admit(store, "scope-probe", "probe-run",
                                           key="b2", input_text="second steer")
                check(v1 == v2 == "admitted", "store admits the boundary fixtures")
                # (a) incomplete tool tail: NOTHING is injected
                msgs = [{"role": "assistant", "tool_calls": [{"id": "t1"}, {"id": "t2"}]},
                        {"role": "tool", "tool_call_id": "t1", "content": "ok"}]
                inject(2, msgs)
                check(all(not (m.get("display_kind") == pb.STEER_DISPLAY_KIND) for m in msgs),
                      "incomplete tool batch injects nothing (stays accepted)")
                # (b) plain user tail: waits for the next safe batch
                msgs = [{"role": "user", "content": "regular prompt"}]
                inject(2, msgs)
                check(len(msgs) == 1, "plain user tail injects nothing")
                # (c) full batch: exactly ONE user row carrying BOTH items in seq order
                msgs = tail_complete()
                inject(2, msgs)
                rows = [m for m in msgs if m.get("display_kind") == pb.STEER_DISPLAY_KIND]
                check(len(msgs) == 5 and len(rows) == 1, "one batch appends exactly ONE row")
                block = rows[0]["display_metadata"][steer_inbox.STEER_METADATA_FIELD]
                check([i["sequence"] for i in block["items"]] == [1, 2]
                      and "#1: first steer" in rows[0]["content"]
                      and "#2: second steer" in rows[0]["content"]
                      and pb.STEER_MARKER_OPEN.strip() in rows[0]["content"],
                      "the row merges items with seq and the OOB marker "
                      f"(seqs={[i['sequence'] for i in block['items']]} "
                      f"content={rows[0]['content']!r})")
                check("_db_persisted" not in rows[0], "the new row is unpersisted (flush will own it)")
                # (d) accepted drained: a second boundary injects nothing
                msgs = tail_complete()
                inject(2, msgs)
                check(not any(m.get("display_kind") == pb.STEER_DISPLAY_KIND for m in msgs),
                      "drained run appends no empty batch")
                # (e) native gateway steer already appended THIS batch's row: MERGE
                v3, r3 = steer_store.admit(store, "scope-probe", "probe-run",
                                           key="b3", input_text="merged steer")
                native_row = pb.steer_user_row("native words")
                msgs = tail_complete(extra_user=native_row)
                inject(2, msgs)
                rows = [m for m in msgs if m.get("display_kind") == pb.STEER_DISPLAY_KIND]
                check(len(rows) == 1 and rows[0] is native_row
                      and "merged steer" in rows[0]["content"]
                      and "native words" in rows[0]["content"]
                      and rows[0]["display_metadata"][steer_inbox.STEER_METADATA_FIELD]
                      ["items"][0]["steer_id"] == r3["steer_id"],
                      "unpersisted native row is MERGED into, never duplicated")
                # (f) persisted steer row is untouchable scaffolding: wait
                persisted = pb.steer_user_row("old words")
                persisted[steer_inbox._persisted_marker()] = True
                v_p, r_p = steer_store.admit(store, "scope-probe", "probe-run",
                                             key="b5", input_text="must wait")
                msgs = tail_complete(extra_user=persisted)
                inject(2, msgs)
                check(len(msgs) == 5 and persisted["content"].endswith("old words\n"
                      + pb.STEER_MARKER_CLOSE)
                      and steer_inbox.STEER_METADATA_FIELD not in (persisted.get("display_metadata") or {})
                      and steer_store.get_steer(store, "scope-probe", "probe-run",
                                                r_p["steer_id"])["state"] == "accepted",
                      "a PERSISTED steer row is never rewritten; the item waits accepted")
                # (g) seal: claims stop, unclaimed become not_delivered
                steer_store.admit(store, "scope-probe", "probe-run", key="b4", input_text="post-seal")
                steer_store.seal_run(store, "scope-probe", "probe-run", "run_completed")
                msgs = tail_complete()
                inject(2, msgs)
                check(not any(m.get("display_kind") == pb.STEER_DISPLAY_KIND for m in msgs),
                      "sealed run injects NOTHING at later boundaries")

                # ---- persist confirmation: the INSTALLED flush wrapper --------------
                store = steer_store.open_store(steer_inbox.home_of(inbox))
                # re-open the fixture run row BEFORE admitting: claims and
                # admits are both refused while the run is sealed.
                with steer_store._LOCK, store:
                    store.execute("UPDATE runs SET closed_reason=NULL WHERE run_id='probe-run'"
                                  " AND owner_scope='scope-probe'")
                v4, r4 = steer_store.admit(store, "scope-probe", "probe-run",
                                           key="cf", input_text="confirm me")
                batch_id = "probe-batch-confirm"
                items = steer_store.claim_batch(store, "scope-probe", "probe-run", batch_id)
                check(items and r4["steer_id"] in [i["steer_id"] for i in items],
                      "claim stages the accepted item")
                meta = {"schema": 1, "run_id": "probe-run", "batch_id": batch_id,
                        "items": [{"steer_id": items[0]["steer_id"], "sequence": 1,
                                   "input": "confirm me"}]}
                msg = pb.steer_user_row("confirm me")
                msg["display_metadata"] = {steer_inbox.STEER_METADATA_FIELD: meta}
                msg["_row_id"] = 987654
                from agent import session_persistence as sp
                stub_db = type("DB", (), {"session_id": "s", "appended": [],
                                          "append_messages_batch": lambda self, **kw: (
                                              self.appended.append(kw["messages"]),
                                              [row.__setitem__("_row_id", 987654)
                                               for row in kw["messages"]], None)[-1]})()
                flush_agent = type("FA", (), {"session_id": "s", "_session_db": stub_db})()
                sp._db_flush_write(flush_agent, [dict(msg, **{"_row_id": 987654})], [msg], [msg])
                row_now = steer_store.get_steer(store, "scope-probe", "probe-run",
                                                r4["steer_id"])
                check(row_now["state"] == "delivered" and row_now["row_id"] == "987654",
                      "history commit confirmation promotes staged->delivered by exact metadata")
                # failure BEFORE commit: the wrapper never reaches confirmation
                boom = type("DB", (), {"append_messages_batch": None})()
                def bad_append(**kw):
                    raise RuntimeError("disk full")
                boom.append_messages_batch = bad_append
                v5, r5 = steer_store.admit(store, "scope-probe", "probe-run",
                                           key="cf2", input_text="never committed")
                items = steer_store.claim_batch(store, "scope-probe", "probe-run", "probe-batch-fail")
                msg2 = pb.steer_user_row("never committed")
                msg2["display_metadata"] = {steer_inbox.STEER_METADATA_FIELD:
                                            {"schema": 1, "run_id": "probe-run",
                                             "batch_id": "probe-batch-fail",
                                             "items": [{"steer_id": r5["steer_id"],
                                                        "sequence": 1, "input": "never committed"}]}}
                try:
                    sp._db_flush_write(type("FA", (), {"session_id": "s", "_session_db": boom})(),
                                       [msg2], [msg2], [msg2])
                except RuntimeError:
                    pass
                row_now = steer_store.get_steer(store, "scope-probe", "probe-run", r5["steer_id"])
                check(row_now["state"] == "staged",
                      "a failed commit leaves the batch staged, never delivered, never auto-requeued")

                # ---- restart recovery: exact evidence, never replay -----------------
                default_db = SessionDB()
                rec_sid = default_db.create_session("compat-steer-recovery", "api_server")
                with steer_store._LOCK, store:
                    store.execute("UPDATE runs SET resolved_sid=? WHERE owner_scope=? AND run_id=?",
                                  (rec_sid, "scope-probe", "probe-run"))
                v6, r6 = steer_store.admit(store, "scope-probe", "probe-run",
                                           key="rec", input_text="evidence exists")
                steer_store.claim_batch(store, "scope-probe", "probe-run", "probe-batch-evidence")
                default_db.append_message(
                    rec_sid, "user", pb.format_steer_marker("evidence exists").lstrip(),
                    display_kind=pb.STEER_DISPLAY_KIND,
                    display_metadata={steer_inbox.STEER_METADATA_FIELD: {
                        "schema": 1, "run_id": "probe-run", "batch_id": "probe-batch-evidence",
                        "items": [{"steer_id": r6["steer_id"], "sequence": 1,
                                   "input": "evidence exists"}]}})
                v7, r7 = steer_store.admit(store, "scope-probe", "probe-run",
                                           key="lost", input_text="no evidence")
                steer_store.claim_batch(store, "scope-probe", "probe-run", "probe-batch-lost")
                repaired = steer_inbox.recover(inbox)
                row6 = steer_store.get_steer(store, "scope-probe", "probe-run", r6["steer_id"])
                row7 = steer_store.get_steer(store, "scope-probe", "probe-run", r7["steer_id"])
                check(row6["state"] == "delivered" and row6["row_id"],
                      "recovery promotes ONLY from exact committed batch metadata")
                check(row7["state"] == "outcome_unknown",
                      "unconfirmed staged batches become outcome_unknown, never replayed")
                check(repaired["delivered"] >= 1 and repaired["outcome_unknown"] >= 1,
                      "recovery reports both reconcile arms")

                # ---- R6 projection: whitelisted typed field only ---------------------
                proj = api.APIServerAdapter._message_response(
                    {"role": "user", "content": pb.format_steer_marker("#1: human text"),
                     "display_kind": "steer",
                     "display_metadata": {"hermes_app_steer": {
                         "schema": 1, "run_id": "run-x", "batch_id": "batch-x",
                         "items": [{"steer_id": "s" * 32, "sequence": 1,
                                    "input": "human text"}]}}})
                check(proj.get("steer_provenance", {}).get("items", [{}])[0]["input"]
                      == "human text" and proj["steer_provenance"]["batch_id"] == "batch-x",
                      "server-written steer rows project typed steer_provenance")
                forged = api.APIServerAdapter._message_response(
                    {"role": "user", "content": "whatever", "display_kind": "steer",
                     "display_metadata": {"hermes_app_steer": {
                         "schema": 2, "items": [{"input": "x"}]}}})
                check("steer_provenance" not in forged,
                      "wrong-schema (client-forged) blocks project NOTHING")
                plain = api.APIServerAdapter._message_response({"role": "user",
                                                                "content": "hi"})
                check("steer_provenance" not in plain
                      and plain["content"] == "hi", "ordinary rows stay byte-identical")

                # ---- no-replay guarantee: nothing entered a native buffer -----------
                check(all(not a.steer_notes for a in agents[2:]),
                      "no inbox item was ever pushed back into native _pending_steer")

                for extra in (resp2, resp3):
                    extra.close()
                response.close()
        # capability rollback keeps the ledger readable while stopping admission
        steer_inbox.set_capability(False)
    finally:
        steer_inbox.set_capability(False)
    return None
