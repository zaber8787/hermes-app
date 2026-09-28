"""APPWAKE: provenance exposure (A) + admission ledger/quota/receipts (B).

Real components only: the plugin-loaded message projection, the reviewed
bridge writer, real SessionDB rows and real HTTP. Network guard stays on.
"""
from __future__ import annotations
import json
import os
import sqlite3
from pathlib import Path

from .offline import AUTH
from .cron_bridge import profile_db, set_lease


def wake_ref():
    from gateway.platforms import api_server as api
    return getattr(api, "_hermes_app_compat_state_v1")["wake"]


def bridge_store():
    from gateway.platforms import api_server as api
    return getattr(api, "_hermes_app_compat_state_v1")["cron_bridge"]["store"]


async def deliver_report(store, sid, body, *, job, execution):
    outcome = await __import__("asyncio").to_thread(
        store.deliver, session_id=sid, content=body,
        identity={"job_id": job, "execution_id": execution, "name": job})
    return outcome


async def case_wake(args, server, check):
    import asyncio
    home = Path(os.environ["HERMES_HOME"])
    refs = wake_ref()
    mod, wstore = refs["module"], refs["store"]
    bstore = bridge_store()

    async with server() as (api_adapter, client):
        db = profile_db()

        # ---- capabilities advertisement ------------------------------------
        async with client.get("/v1/capabilities", headers=AUTH) as r:
            caps = await r.json()
        wake_cap = (caps.get("features") or {}).get("auto_wake") or {}
        check(wake_cap.get("enabled") is True and wake_cap.get("ledger")
              == "durable-delivery-key", "capabilities advertise the durable ledger")
        check(wake_cap.get("canonical_input") == mod.CANONICAL_INPUT
              and wake_cap.get("limits", {}).get("session_per_hour") == 6
              and wake_cap.get("limits", {}).get("profile_per_hour") == 12,
              "canonical sentence and shared limits are advertised")
        for name in ("auto_wake_admit", "auto_wake_receipt", "auto_wake_report",
                     "auto_wake_release"):
            check(name in caps.get("endpoints", {}), f"endpoint {name} advertised")

        # ---- A provenance legs (regression) ---------------------------------
        sid = "api_wake_happy1"
        db.create_session(sid, model="compat-fixture", source="api_server")
        out1 = await deliver_report(bstore, sid, "status ok", job="jobH", execution="execH1")
        check(out1["status"] == "delivered", "bridge wrote the report row")
        async with client.get(f"/api/sessions/{sid}/messages", headers=AUTH) as r:
            rows = (await r.json())["data"]
        key1 = rows[-1]["cron_provenance"]["delivery_key"]
        check(len(key1) == 64 and all(c in "0123456789abcdef" for c in key1),
              "provenance exposes a 64-hex bridge delivery_key")

        # ---- admit happy path + receipt lifecycle ---------------------------
        async with client.post(f"/api/sessions/{sid}/auto-wake/admit", headers=AUTH,
                               json={"delivery_keys": [key1]}) as r:
            admitted = await r.json()
        check(r.status == 200 and admitted["status"] == "admitted"
              and len(admitted["accepted"]) == 1
              and admitted["canonical_input"] == mod.CANONICAL_INPUT
              and admitted["state"] == "reserved", "admit claims exactly one report")
        batch = admitted["batch_id"]
        async with client.post(f"/api/sessions/{sid}/auto-wake/admit", headers=AUTH,
                               json={"delivery_keys": [key1]}) as r:
            dup = await r.json()
        check(dup["status"] == "empty" and dup["rejected"][0]["reason"] == "already_consumed"
              and dup["rejected"][0]["batch_id"] == batch,
              "second client same report: no second batch, original receipt named")
        async with client.post(f"/api/sessions/{sid}/auto-wake/admit", headers=AUTH,
                               json={"delivery_keys": ["0" * 64]}) as r:
            unknown = await r.json()
        check(unknown["status"] == "empty"
              and unknown["rejected"][0]["reason"] == "unknown_provenance",
              "a delivery_key the DB cannot vouch for is never admitted")
        # dispatch CAS -> accepted (run_id required) -> terminal
        check(await asyncio.to_thread(wstore.gate_dispatch, home, batch_id=batch,
                                      resolved=sid, input_text=mod.CANONICAL_INPUT) is None,
              "gate dispatch reserved->dispatching persists BEFORE the run")
        replay = await asyncio.to_thread(wstore.gate_dispatch, home, batch_id=batch,
                                         resolved=sid, input_text=mod.CANONICAL_INPUT)
        check(replay["code"] == "wake_in_flight" and replay["status"] == 409,
              "replayed dispatch answers with the in-flight receipt, no second run")
        async with client.post(f"/api/sessions/{sid}/auto-wake/receipt", headers=AUTH,
                               json={"batch_id": batch, "state": "accepted"}) as r:
            check(r.status == 400, "accepted without run_id is refused")
        async with client.post(f"/api/sessions/{sid}/auto-wake/receipt", headers=AUTH,
                               json={"batch_id": batch, "state": "accepted",
                                     "run_id": "run_h1"}) as r:
            acc = await r.json()
        check(acc["status"] == "ok" and acc["receipt"]["state"] == "accepted",
              "accepted records the run id")
        async with client.post(f"/api/sessions/{sid}/auto-wake/receipt", headers=AUTH,
                               json={"batch_id": batch, "state": "terminal"}) as r:
            term = await r.json()
        check(term["receipt"]["state"] == "terminal" and term["receipt"]["terminal_at"],
              "terminal closes the batch")
        async with client.get(f"/api/sessions/{sid}/auto-wake/receipt?batch_id={batch}",
                              headers=AUTH) as r:
            got = await r.json()
        check(got["receipt"]["delivery_keys"] == [key1], "receipt names its rows")

        # ---- NO_REPLY / empty: ignored-consumed, quota-free ------------------
        sid_n = "api_wake_ignored1"
        db.create_session(sid_n, model="compat-fixture", source="api_server")
        await deliver_report(bstore, sid_n, "NO_REPLY", job="jobN", execution="execN1")
        await deliver_report(bstore, sid_n, "we discussed NO_REPLY policy today",
                             job="jobN", execution="execN2")
        async with client.get(f"/api/sessions/{sid_n}/messages", headers=AUTH) as r:
            rows = (await r.json())["data"]
        keys = [row["cron_provenance"]["delivery_key"] for row in rows]
        async with client.post(f"/api/sessions/{sid_n}/auto-wake/admit", headers=AUTH,
                               json={"delivery_keys": keys}) as r:
            ign = await r.json()
        check(ign["status"] == "admitted" and len(ign["ignored"]) == 1
              and len(ign["accepted"]) == 1,
              "exact NO_REPLY ignored; a report MENTIONING it stays eligible")

        # ---- busy: a live turn lease defers admission, nothing consumed ------
        sid_b = "api_wake_busy1"
        db.create_session(sid_b, model="compat-fixture", source="api_server")
        outb = await deliver_report(bstore, sid_b, "busy report", job="jobB", execution="execB1")
        keyb = bstore.delivery_key(home=str(home), job_id="jobB",
                                   execution_id="execB1", session_id=sid_b)
        set_lease(db, sid_b, "pid=4242")
        async with client.post(f"/api/sessions/{sid_b}/auto-wake/admit", headers=AUTH,
                               json={"delivery_keys": [keyb]}) as r:
            busy = await r.json()
        check(r.status == 200 and busy["status"] == "busy" and busy["retry_after_s"] > 0,
              "live turn lease: retryable busy, no claim, no quota")
        set_lease(db, sid_b, None)
        async with client.post(f"/api/sessions/{sid_b}/auto-wake/admit", headers=AUTH,
                               json={"delivery_keys": [keyb]}) as r:
            after = await r.json()
        check(after["status"] == "admitted", "after the lease, admission proceeds")
        # release returns an UNDISPATCHED claim
        async with client.post(f"/api/sessions/{sid_b}/auto-wake/release", headers=AUTH,
                               json={"batch_id": after["batch_id"]}) as r:
            rel = await r.json()
        check(rel["status"] == "ok" and rel["receipt"]["state"] == "released",
              "reserved batch releases its claim + quota reservation")
        async with client.post(f"/api/sessions/{sid_b}/auto-wake/admit", headers=AUTH,
                               json={"delivery_keys": [keyb]}) as r:
            readmit = await r.json()
        check(readmit["status"] == "admitted", "released report is admissible again")
        # dispatched batches cannot release
        check(await asyncio.to_thread(wstore.gate_dispatch, home,
                                      batch_id=readmit["batch_id"], resolved=sid_b,
                                      input_text=mod.CANONICAL_INPUT) is None,
              "dispatch gate for release-negative test")
        async with client.post(f"/api/sessions/{sid_b}/auto-wake/release", headers=AUTH,
                               json={"batch_id": readmit["batch_id"]}) as r:
            negrel = await r.json()
        await asyncio.to_thread(wstore.dispatch_failed, home, readmit["batch_id"])
        check(r.status == 409 and negrel["error"]["code"] == "wake_transition_conflict",
              "dispatching batches refuse release (only provably-unsent releases)")

        # ---- session opt-out: hidden targets refuse --------------------------
        sid_x = "api_wake_hidden1"
        db.create_session(sid_x, model="compat-fixture", source="api_server")
        await deliver_report(bstore, sid_x, "hidden report", job="jobX", execution="execX1")
        keyx = bstore.delivery_key(home=str(home), job_id="jobX",
                                   execution_id="execX1", session_id=sid_x)
        with db._lock:
            db._conn.execute("UPDATE sessions SET hidden=1 WHERE id = ?", (sid_x,))
            db._conn.commit()
        async with client.post(f"/api/sessions/{sid_x}/auto-wake/admit", headers=AUTH,
                               json={"delivery_keys": [keyx]}) as r:
            hid = await r.json()
        check(hid["status"] == "error" and hid["error"] == "session_not_allowed",
              "hidden session: admission refused, reports unaffected")

        # ---- hourly quota is server-shared -----------------------------------
        sid_q = "api_wake_quota1"
        db.create_session(sid_q, model="compat-fixture", source="api_server")
        seen_batches = set()
        for i in range(6):
            o = await deliver_report(bstore, sid_q, f"quota report {i}",
                                     job=f"jobQ{i}", execution=f"execQ{i}")
            kq = bstore.delivery_key(home=str(home), job_id=f"jobQ{i}",
                                      execution_id=f"execQ{i}", session_id=sid_q)
            async with client.post(f"/api/sessions/{sid_q}/auto-wake/admit", headers=AUTH,
                                   json={"delivery_keys": [kq]}) as r:
                q = await r.json()
            check(q["status"] == "admitted", f"quota batch {i + 1} admitted")
            seen_batches.add(q["batch_id"])
        o = await deliver_report(bstore, sid_q, "quota overflow",
                                 job="jobQX", execution="execQX")
        kx = bstore.delivery_key(home=str(home), job_id="jobQX",
                                 execution_id="execQX", session_id=sid_q)
        async with client.post(f"/api/sessions/{sid_q}/auto-wake/admit", headers=AUTH,
                               json={"delivery_keys": [kx]}) as r:
            over = await r.json()
        check(over["status"] == "quota_exceeded" and r.status == 200
              and over["quota"]["session_remaining"] == 0,
              "session cap 6/h enforced SERVER-side, shared across devices")
        # consumed reports keep their verdict even when quota blocks: quota
        # refusal must not re-open consumption (claim-free rejection).
        async with client.post(f"/api/sessions/{sid_q}/auto-wake/admit", headers=AUTH,
                               json={"delivery_keys": [keys[1]]}) as r:
            dupq = await r.json()
        check(dupq["status"] in ("quota_exceeded", "empty"),
              "quota-blocked duplicate cannot create a batch")

        # ---- causal suspect: reports produced INSIDE an in-flight wake --------
        sid_c = "api_wake_causal1"
        db.create_session(sid_c, model="compat-fixture", source="api_server")
        oc1 = await deliver_report(bstore, sid_c, "seed report", job="jobS", execution="execS1")
        kc = bstore.delivery_key(home=str(home), job_id="jobS",
                                 execution_id="execS1", session_id=sid_c)
        async with client.post(f"/api/sessions/{sid_c}/auto-wake/admit", headers=AUTH,
                               json={"delivery_keys": [kc]}) as r:
            seed = await r.json()
        await asyncio.to_thread(wstore.gate_dispatch, home, batch_id=seed["batch_id"],
                                resolved=sid_c, input_text=mod.CANONICAL_INPUT)
        await asyncio.to_thread(wstore.report, home, batch_id=seed["batch_id"],
                                resolved=sid_c, state="accepted", run_id="run_c")
        await deliver_report(bstore, sid_c, "tool-made follow-up", job="jobT", execution="execT1")
        kt = bstore.delivery_key(home=str(home), job_id="jobT",
                                 execution_id="execT1", session_id=sid_c)
        async with client.post(f"/api/sessions/{sid_c}/auto-wake/admit", headers=AUTH,
                               json={"delivery_keys": [kt]}) as r:
            caus = await r.json()
        check(caus["status"] == "empty"
              and caus["rejected"][0]["reason"] == "causal_suspect",
              "report landing during an in-flight wake stops the loop (no auto fire)")
        check(await asyncio.to_thread(wstore.ledger_state_for, home, kt) is None,
              "causal_suspect consumed NOTHING (manual reading stays open)")
        await asyncio.to_thread(wstore.report, home, batch_id=seed["batch_id"],
                                resolved=sid_c, state="terminal")
        async with client.post(f"/api/sessions/{sid_c}/auto-wake/admit", headers=AUTH,
                               json={"delivery_keys": [kt]}) as r:
            caus2 = await r.json()
        check(caus2["status"] == "admitted",
              "after the wake run ends the next report is eligible again")

        # ---- permanence: the ledger outlives native 24h TTL semantics --------
        conn = sqlite3.connect(str(home / "wake_ledger.db"))
        conn.execute("UPDATE wake_batches SET created_at = created_at - 100000"
                     " WHERE session_id = ?", (sid,))
        conn.commit()
        conn.close()
        async with client.post(f"/api/sessions/{sid}/auto-wake/admit", headers=AUTH,
                               json={"delivery_keys": [key1]}) as r:
            aged = await r.json()
        check(aged["rejected"][0]["reason"] == "already_consumed"
              and aged["rejected"][0]["batch_id"] == batch,
              "consumption survives 24h+ — no TTL rebuild of the namespace")
        # quota window frees, consumption does NOT: admit a NEW report succeeds
        await deliver_report(bstore, sid, "fresh after window", job="jobH", execution="execH2")
        k2 = bstore.delivery_key(home=str(home), job_id="jobH",
                                 execution_id="execH2", session_id=sid)
        async with client.post(f"/api/sessions/{sid}/auto-wake/admit", headers=AUTH,
                               json={"delivery_keys": [k2]}) as r:
            fresh = await r.json()
        check(fresh["status"] == "admitted",
              "quota window frees while old reports stay consumed (ledger != window)")

        # ---- sync chat refuses wake batches ------------------------------------
        async with client.post(f"/api/sessions/{sid}/chat", headers=AUTH,
                               json={"input": mod.CANONICAL_INPUT,
                                     "wake_batch": fresh["batch_id"]}) as r:
            sync = await r.json()
        check(r.status == 400 and sync["error"]["code"] == "wake_transport_unsupported",
              "sync chat never consumes a wake batch")

        # ---- auth: anonymous admit is refused ---------------------------------
        async with client.post(f"/api/sessions/{sid}/auto-wake/admit",
                               json={"delivery_keys": [key1]}) as r:
            check(r.status in (401, 403), "anonymous admission refused")

    return None
