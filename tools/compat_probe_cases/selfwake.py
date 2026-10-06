"""SELFWAKE S2: durable intents, generation/cutoff, reconciliation, modes.

Real components only: the plugin-loaded bridge store writing intents in the
SAME transaction as receipts, real SessionDB report rows, real drainer math,
and fail-closed profile config parsing. No model turn, no HTTP dispatch —
shadow mode must prove it records WITHOUT admitting anything.
"""
from __future__ import annotations
import json
import os
import sqlite3
import time
from pathlib import Path

from .cron_bridge import profile_db, set_lease
from .offline import AUTH


def sw_ref():
    from gateway.platforms import api_server as api
    return getattr(api, "_hermes_app_compat_state_v1")["selfwake"]["module"]


def bridge_store():
    from gateway.platforms import api_server as api
    return getattr(api, "_hermes_app_compat_state_v1")["cron_bridge"]["store"]


def set_mode(mode):
    home = Path(os.environ["HERMES_HOME"])
    cfg = json.loads((home / "config.yaml").read_text())
    if mode is None:
        cfg.pop("wake", None)
    elif isinstance(mode, str):
        cfg["wake"] = {"selfwake": mode}
    else:
        cfg["wake"] = mode
    (home / "config.yaml").write_text(json.dumps(cfg))


def intents(home):
    conn = sqlite3.connect(str(Path(home) / "cron_bridge.db"))
    conn.row_factory = sqlite3.Row
    rows = [dict(r) for r in conn.execute(
        "SELECT delivery_key, state, reason, generation, cutoff FROM selfwake_intents"
        " ORDER BY created_at")]
    conn.close()
    return rows


def batches(home):
    path = Path(home) / "wake_ledger.db"
    if not path.exists():
        return []
    conn = sqlite3.connect(str(path))
    rows = conn.execute("SELECT batch_id FROM wake_batches").fetchall()
    conn.close()
    return rows


async def case_selfwake(args, server, check):
    import asyncio
    home = Path(os.environ["HERMES_HOME"])
    sw = sw_ref()
    bstore = bridge_store()
    db = profile_db()

    async def deliver(sid, body, job, execution):
        return await asyncio.to_thread(
            bstore.deliver, session_id=sid, content=body,
            identity={"job_id": job, "execution_id": execution, "name": job})

    async def dkey(sid, job, execution):
        return bstore.delivery_key(home=str(home), job_id=job, execution_id=execution,
                                   session_id=sid)

    # ---- default: OFF, no block -> nothing is recorded -----------------------
    set_mode(None)
    mode, params, why = sw.settings(home)
    check(mode == "off" and why is None, "absent wake block reads off")
    sid_o = "api_sw_off"
    db.create_session(sid_o, model="compat-fixture", source="api_server")
    await deliver(sid_o, "pre-enable report", "jobPre", "execPre")
    check(not intents(home), "off mode records NO self-wake intent")

    # ---- enable shadow: generation+cutoff persist, pre-cutoff never replays --
    set_mode("shadow")
    mode, _p, _w = sw.settings(home)
    check(mode == "shadow", "shadow mode parses")
    rec = await asyncio.to_thread(sw.reconcile, home)
    check(not intents(home) and rec.get("added", 0) + rec.get("backfilled_receipts_only", 0) == 0,
          "shadow reconcile does NOT replay the pre-enable report (cutoff)")

    # fresh delivered -> exactly one shadow intent, dedup never adds a second
    sid_s = "api_sw_shadow"
    db.create_session(sid_s, model="compat-fixture", source="api_server")
    await deliver(sid_s, "shadow report one", "jobS1", "execS1")
    rows = intents(home)
    check(len(rows) == 1 and rows[0]["state"] == "shadow"
          and rows[0]["reason"] == "delivered-direct",
          "fresh delivered writes the intent in the receipt transaction")
    await deliver(sid_s, "shadow report one", "jobS1", "execS1")  # dedup redelivery
    check(len(intents(home)) == 1, "dedup never adds a second wake task")
    check(not batches(home), "shadow admits NOTHING: zero batches, zero quota")
    conn = sqlite3.connect(str(Path(home) / "cron_bridge.db"))
    gen = conn.execute("SELECT value FROM meta WHERE key='selfwake_generation'").fetchone()[0]
    cut = conn.execute("SELECT value FROM meta WHERE key='selfwake_cutoff'").fetchone()[0]
    conn.close()
    check(gen == "1" and float(cut) > 0,
          f"enable generation+cutoff persisted (gen={gen!r} cut={cut!r})")

    # ---- drainer path: fresh vs dedup counted apart --------------------------
    sid_d = "api_sw_drain"
    db.create_session(sid_d, model="compat-fixture", source="api_server")
    set_lease(db, sid_d, f"selfwake:pid={os.getpid()}")  # live holder -> busy, durable queued
    q = await deliver(sid_d, "drain queued report", "jobD1", "execD1")
    check(q["status"] == "queued", "busy session queues durably")
    check(not [r for r in intents(home) if r["reason"] == "delivered-drainer"],
          "queued delivery registers no intent (delivered only)")
    set_lease(db, sid_d, None)
    conn = sqlite3.connect(str(bstore.bridge_file(home)))
    conn.execute("UPDATE pending SET next_retry_at = 0")
    conn.commit()
    conn.close()
    summary = await asyncio.to_thread(bstore.drain_home, home)
    check(summary["delivered"] == 1 and summary["deduped"] == 0,
          "drainer counts fresh delivered apart")
    drows = [r for r in intents(home) if r["reason"] == "delivered-drainer"]
    check(len(drows) == 1 and drows[0]["state"] == "shadow",
          "drainer-delivered registers one intent in its transaction")
    # replay the SAME key through the spool: deduped, never a second intent
    conn = sqlite3.connect(str(bstore.bridge_file(home)))
    conn.execute("""INSERT INTO pending(delivery_key, home, session_id, identity, content,
                    next_retry_at, created_at, updated_at)
                    SELECT delivery_key, home, session_id, ?, 'drain queued report', ?, ?, ?
                    FROM receipts WHERE session_id = ? AND status='delivered'
                    LIMIT 1""",
                 (json.dumps({"job_id": "jobD1", "execution_id": "execD1", "name": "D"}),
                  time.time(), time.time(), time.time(), sid_d))
    conn.commit()
    conn.close()
    summary = await asyncio.to_thread(bstore.drain_home, home)
    check(summary["delivered"] == 0 and summary["deduped"] == 1,
          "dedup drain result is counted as deduped, never delivered")
    check(len([r for r in intents(home) if r["reason"] == "delivered-drainer"]) == 1,
          "dedup drain adds NO wake task")

    # ---- crash gap: SessionDB committed, receipt/intent never committed ------
    sid_g = "api_sw_gap"
    db.create_session(sid_g, model="compat-fixture", source="api_server")
    key_g = await dkey(sid_g, "jobG1", "execG1")

    def _raw_write():
        from hermes_state_registry import acquire, release_or_close
        d = acquire(Path(home) / "state.db")
        try:
            bstore._write_once(d, sid_g, sid_g, "crash gap report",
                               {"job_id": "jobG1", "execution_id": "execG1",
                                "name": "G"}, key_g)
        finally:
            release_or_close(d)
    await asyncio.to_thread(_raw_write)  # report row committed; NO receipt, NO intent
    check(not [r for r in intents(home) if r["delivery_key"] == key_g],
          "crash-gap report starts without an intent")
    rec = await asyncio.to_thread(sw.reconcile, home)
    got = [r for r in intents(home) if r["delivery_key"] == key_g]
    check(len(got) == 1 and got[0]["reason"] == "reconciled"
          and rec["added"] == 1, "reconciliation recovers the crash-gap report once")
    rec2 = await asyncio.to_thread(sw.reconcile, home)
    check(rec2["added"] == 0 and len([r for r in intents(home)
                                      if r["delivery_key"] == key_g]) == 1,
          "reconciliation is idempotent (delivery_key dedup)")

    # ---- restart keeps the generation (never re-baselines the cutoff) --------
    conn = sqlite3.connect(str(Path(home) / "cron_bridge.db"))
    before = conn.execute("SELECT value FROM meta WHERE key='selfwake_cutoff'").fetchone()[0]
    conn.close()
    await asyncio.to_thread(sw.reconcile, home)
    conn = sqlite3.connect(str(Path(home) / "cron_bridge.db"))
    after = conn.execute("SELECT value FROM meta WHERE key='selfwake_cutoff'").fetchone()[0]
    conn.close()
    check(before == after, "later sweeps KEEP the enable cutoff (no re-baseline)")

    # ---- malformed config fails CLOSED with a reason -------------------------
    set_mode({"selfwake": "yes-please"})
    mode, _p, why = sw.settings(home)
    check(mode == "off" and why and "malformed" in why, "malformed selfwake fails closed")
    set_mode({"selfwake": True, "selfwake_chain_limit": "many"})
    mode, _p, why = sw.settings(home)
    check(mode == "off" and why, "malformed chain limit fails closed")
    set_mode({"selfwake": True, "selfwake_chain_limit": 3, "selfwake_cooldown_seconds": 60})
    mode, params, _w = sw.settings(home)
    check(mode == "on" and params["chain_limit"] == 3 and params["cooldown_seconds"] == 60.0,
          "on mode with documented defaults parses")

    # off while pending: switching off records nothing NEW (existing intents
    # stay for audit; accepted/consumed batches are never released by toggles)
    set_mode("shadow")
    sid_off = "api_sw_toff"
    db.create_session(sid_off, model="compat-fixture", source="api_server")
    await deliver(sid_off, "before toggle off", "jobT1", "execT1")
    before_n = len(intents(home))
    set_mode(None)
    await deliver(sid_off, "after toggle off", "jobT2", "execT2")
    check(len(intents(home)) == before_n, "disabling stops NEW intents; existing rows stay")
    _wd = getattr(sw, "SelfWakeWorker")(home)
    _wd._mode_seen = "on"          # the worker observed the on->off transition
    await _wd.tick()
    conn = sqlite3.connect(str(Path(home) / "cron_bridge.db"))
    offs = conn.execute("SELECT state FROM selfwake_intents"
                        " WHERE session_id = ?", (sid_off,)).fetchall()
    conn.close()
    check(len(offs) == 1 and offs[0][0] == "void",
          f"disable sweep voids undispatched pending intents: {offs}")


    # ---- S3: the gateway worker (one tick = one deterministic pass) ---------
    from .offline import server as fixture_server
    Worker = getattr(sw, "SelfWakeWorker")
    async with fixture_server() as (api_adapter, client):
        port = api_adapter._site._server.sockets[0].getsockname()[1]

        def listener(on=True, host="127.0.0.1", with_key=True):
            cfg = json.loads((home / "config.yaml").read_text())
            api = {"enabled": bool(on), "host": host, "port": port}
            if with_key:
                api["key"] = "compat-probe-only-0123456789abcdef0123456789"
            cfg["gateway"] = {"api_server": api}
            (home / "config.yaml").write_text(json.dumps(cfg))

        def intent_rows():
            return intents(home)

        # (A) idle direct fire: exactly ONE self batch, terminal, run recorded
        set_mode({"selfwake": True, "selfwake_chain_limit": 3,
                  "selfwake_cooldown_seconds": 60})
        listener()
        sid_w = "api_sw_fire1"
        db.create_session(sid_w, model="compat-fixture", source="api_server")
        await deliver(sid_w, "worker fire report", "jobW1", "execW1")
        w = Worker(home)
        w._mode_seen = "off"       # persistent worker saw the off->on transition
        await w.tick()
        rows = [r for r in intent_rows() if r["reason"] == "delivered-direct"
                and r["state"] == "done"]
        conn = sqlite3.connect(str(Path(home) / "wake_ledger.db"))
        conn.row_factory = sqlite3.Row
        wb = [dict(r) for r in conn.execute(
            "SELECT batch_id, state, run_id, owner FROM wake_batches WHERE session_id = ?",
            (sid_w,))]
        conn.close()
        check(len(wb) == 1 and wb[0]["state"] == "terminal" and wb[0]["run_id"]
              and (wb[0]["owner"] or "").startswith("self:"),
              f"self worker dispatched ONE batch to completion: {wb}")
        conn = sqlite3.connect(str(Path(home) / "cron_bridge.db"))
        ist = conn.execute("SELECT state, detail FROM selfwake_intents WHERE session_id = ?",
                           (sid_w,)).fetchall()
        conn.close()
        check(len(ist) == 1 and ist[0][0] == "done", f"intent closed: {ist}")

        # (B) App consumed first: self yields forever, no second batch
        sid_a = "api_sw_app1"
        db.create_session(sid_a, model="compat-fixture", source="api_server")
        await deliver(sid_a, "app first report", "jobA1", "execA1")
        ka = await dkey(sid_a, "jobA1", "execA1")
        async with client.post(f"/api/sessions/{sid_a}/auto-wake/admit", headers=AUTH,
                               json={"delivery_keys": [ka]}) as r:
            appadm = await r.json()
        check(appadm["status"] == "admitted", "App admits first")
        await Worker(home).tick()
        conn = sqlite3.connect(str(Path(home) / "wake_ledger.db"))
        batches_a = [r[0] for r in conn.execute(
            "SELECT batch_id FROM wake_batches WHERE session_id = ?", (sid_a,))]
        n = len(batches_a)
        conn.close()
        check(n == 1 and batches_a == [appadm["batch_id"]],
              "App reserved batch untouched by self: still exactly one batch")

        # (C) busy: retry with backoff, zero claims
        sid_b = "api_sw_busy1"
        db.create_session(sid_b, model="compat-fixture", source="api_server")
        await deliver(sid_b, "busy selfwake report", "jobB1", "execB1")
        set_lease(db, sid_b, f"selfwake:pid={os.getpid()}")
        await Worker(home).tick()
        conn = sqlite3.connect(str(Path(home) / "cron_bridge.db"))
        st = conn.execute("SELECT state, detail, next_attempt_at FROM selfwake_intents"
                          " WHERE session_id = ?", (sid_b,)).fetchall()
        allp = conn.execute("SELECT session_id, state, detail FROM selfwake_intents"
                            " WHERE state IN ('pending','watching')").fetchall()
        conn.close()
        check(len(st) == 1 and st[0][0] == "pending" and st[0][2] > time.time(),
              f"busy keeps the intent pending with a future retry, claims nothing:"
              f" {st} pendings={allp} now={time.time()}")
        set_lease(db, sid_b, None)

        # (D) crash recovery on our OWN dispatching batch: settle uncertain,
        # NEVER re-POST (no second batch, no second provider run)
        sid_c = "api_sw_crash1"
        db.create_session(sid_c, model="compat-fixture", source="api_server")
        await deliver(sid_c, "crash settle report", "jobC1", "execC1")
        kc = await dkey(sid_c, "jobC1", "execC1")
        conn = sqlite3.connect(str(Path(home) / "wake_ledger.db"))
        import secrets as _secrets
        from .wake import wake_ref
        crash_batch = "wb_" + _secrets.token_hex(12)
        conn.execute("INSERT INTO wake_batches(batch_id, session_id, state,"
                     " canonical_input, batch_keys, created_at, updated_at, owner)"
                     " VALUES(?, ?, 'dispatching', ?, ?, ?, ?, 'self:crash1')",
                     (crash_batch, sid_c,
                      wake_ref()["module"].CANONICAL_INPUT,
                      json.dumps([kc]), time.time(), time.time()))
        conn.execute("INSERT INTO wake_consumption(delivery_key, batch_id, session_id,"
                     " message_id, report_order, ignored, state, created_at, updated_at)"
                     " VALUES(?, ?, ?, NULL, 0, 0, 'consumed', ?, ?)",
                     (kc, crash_batch, sid_c, time.time(), time.time()))
        conn.commit()
        conn.close()
        conn = sqlite3.connect(str(Path(home) / "cron_bridge.db"))
        conn.execute("UPDATE selfwake_intents SET state='watching', batch_id = ?"
                     " WHERE delivery_key = ?", (crash_batch, kc))
        conn.commit()
        conn.close()
        await Worker(home).tick()
        conn = sqlite3.connect(str(Path(home) / "wake_ledger.db"))
        stt = conn.execute("SELECT state FROM wake_batches WHERE batch_id = ?",
                           (crash_batch,)).fetchone()[0]
        nb = conn.execute("SELECT COUNT(*) FROM wake_batches WHERE session_id = ?",
                          (sid_c,)).fetchone()[0]
        conn.close()
        check(stt == "uncertain-consumed" and nb == 1,
              f"own dispatching batch after crash settles uncertain-consumed once: {stt}")

        # (E) listener unavailable: fail closed, stay pending, never another entry
        listener(on=False)
        sid_u = "api_sw_listen1"
        db.create_session(sid_u, model="compat-fixture", source="api_server")
        await deliver(sid_u, "no listener report", "jobU1", "execU1")
        await Worker(home).tick()
        conn = sqlite3.connect(str(Path(home) / "cron_bridge.db"))
        sU = conn.execute("SELECT state, detail FROM selfwake_intents WHERE session_id = ?",
                          (sid_u,)).fetchall()
        conn.close()
        check(len(sU) == 1 and sU[0][0] == "pending" and "unavailable" in (sU[0][1] or ""),
              f"listener down stays pending-unavailable: {sU}")
        listener()

        # (F) disable mid-stream: NEW pending intents void, claims never released
        set_mode(None)
        sid_v = "api_sw_void1"
        db.create_session(sid_v, model="compat-fixture", source="api_server")
        set_mode({"selfwake": True})
        await deliver(sid_v, "void me report", "jobV1", "execV1")
        set_mode(None)
        _wv = Worker(home)
        _wv._mode_seen = "on"      # persistent worker observes the on->off edge
        await _wv.tick()
        conn = sqlite3.connect(str(Path(home) / "cron_bridge.db"))
        sV = conn.execute("SELECT state, detail FROM selfwake_intents WHERE session_id = ?",
                          (sid_v,)).fetchall()
        conn.close()
        check(len(sV) == 1 and sV[0][0] == "void" and sV[0][1] == "disabled",
              "disabling voids undispatched pending intents")

        # (G) fault fuse: three consecutive uncertain settlements fuse the
        # lineage; an audited admin reset reopens it.
        set_mode({"selfwake": True, "selfwake_chain_limit": 5,
                  "selfwake_cooldown_seconds": 0})
        sid_f = "api_sw_fuse1"
        db.create_session(sid_f, model="compat-fixture", source="api_server")
        for k in range(3):
            await deliver(sid_f, f"fuse crash report {k}", f"jobF{k}", f"execF{k}")
            kf = await dkey(sid_f, f"jobF{k}", f"execF{k}")
            conn = sqlite3.connect(str(Path(home) / "wake_ledger.db"))
            cb = "wb_fuse" + _secrets.token_hex(10)
            conn.execute("INSERT INTO wake_batches(batch_id, session_id, state,"
                         " canonical_input, batch_keys, created_at, updated_at, owner)"
                         " VALUES(?, ?, 'dispatching', ?, ?, ?, ?, 'self:fuse')",
                         (cb, sid_f, wake_ref()["module"].CANONICAL_INPUT,
                          json.dumps([kf]), time.time(), time.time()))
            conn.execute("INSERT INTO wake_consumption(delivery_key, batch_id,"
                         " session_id, message_id, report_order, ignored, state,"
                         " created_at, updated_at) VALUES(?, ?, ?, NULL, 0, 0,"
                         " 'consumed', ?, ?)", (kf, cb, sid_f, time.time(), time.time()))
            conn.commit()
            conn.close()
            conn = sqlite3.connect(str(Path(home) / "cron_bridge.db"))
            conn.execute("UPDATE selfwake_intents SET state='watching', batch_id = ?"
                         " WHERE delivery_key = ?", (cb, kf))
            conn.commit()
            conn.close()
            await Worker(home).tick()
        conn = sqlite3.connect(str(Path(home) / "wake_ledger.db"))
        ch = conn.execute("SELECT fires, fails, fused FROM selfwake_chain"
                          " WHERE session_id = ?", (sid_f,)).fetchone()
        fuse_rows = conn.execute("SELECT COUNT(*) FROM selfwake_audit"
                                 " WHERE phase = 'fuse'").fetchone()[0]
        conn.close()
        check(ch is not None and ch[2] == 1 and ch[1] >= 3 and fuse_rows >= 1,
              f"three consecutive uncertain settlements fault-fuse the lineage: {ch}")
        await deliver(sid_f, "after fuse report", "jobF9", "execF9")
        await Worker(home).tick()
        conn = sqlite3.connect(str(Path(home) / "cron_bridge.db"))
        sF = conn.execute("SELECT state, detail FROM selfwake_intents"
                          " WHERE session_id = ? AND batch_id IS NULL"
                          " AND reason = 'delivered-direct'", (sid_f,)).fetchall()
        conn.close()
        check(len(sF) == 1 and sF[0][0] == "pending" and "fused" in (sF[0][1] or ""),
              f"fused lineage blocks NEW claims, stays pending: {sF}")
        sw.chain_release(home, sid_f)
        conn = sqlite3.connect(str(Path(home) / "wake_ledger.db"))
        rst = conn.execute("SELECT COUNT(*) FROM selfwake_audit"
                           " WHERE phase = 'chain-reset'").fetchone()[0]
        conn.close()
        check(rst >= 1, "admin reset is audited")
        conn = sqlite3.connect(str(Path(home) / "cron_bridge.db"))
        conn.execute("UPDATE selfwake_intents SET next_attempt_at = ?"
                     " WHERE session_id = ? AND state = 'pending'",
                     (time.time(), sid_f))   # the fuse backoff elapsed
        conn.commit()
        conn.close()
        for _ in range(8):   # one tick = one due group; drain older retries first
            await Worker(home).tick()
            conn = sqlite3.connect(str(Path(home) / "cron_bridge.db"))
            _d = conn.execute("SELECT state FROM selfwake_intents WHERE session_id = ?"
                              " AND reason = 'delivered-direct'"
                              " AND COALESCE(batch_id,'') NOT LIKE 'wb_fuse%'",
                              (sid_f,)).fetchone()
            conn.close()
            if _d is not None and _d[0] == "done":
                break
        conn = sqlite3.connect(str(Path(home) / "cron_bridge.db"))
        sR = conn.execute("SELECT state, detail, batch_id FROM selfwake_intents WHERE session_id = ?"
                          " AND reason = 'delivered-direct'"
                          " AND COALESCE(batch_id,'') NOT LIKE 'wb_fuse%'", (sid_f,)).fetchall()
        conn.close()
        check(sR and sR[0][0] == "done", f"reset reopens the lineage for dispatch: {sR}")

        # (H) crash point 3 — died AFTER admit, BEFORE intent association:
        # the owner column proves the reserved batch is ours; adopt and run
        # it once, never a second batch.
        sid_h = "api_sw_admc1"
        db.create_session(sid_h, model="compat-fixture", source="api_server")
        await deliver(sid_h, "adopt report", "jobH1", "execH1")
        kh = await dkey(sid_h, "jobH1", "execH1")
        conn = sqlite3.connect(str(Path(home) / "wake_ledger.db"))
        adopt_batch = "wb_" + _secrets.token_hex(12)
        conn.execute("INSERT INTO wake_batches(batch_id, session_id, state,"
                     " canonical_input, batch_keys, created_at, updated_at, owner)"
                     " VALUES(?, ?, 'reserved', ?, ?, ?, ?, 'self:adopt')",
                     (adopt_batch, sid_h, wake_ref()["module"].CANONICAL_INPUT,
                      json.dumps([kh]), time.time(), time.time()))
        conn.execute("INSERT INTO wake_consumption(delivery_key, batch_id, session_id,"
                     " message_id, report_order, ignored, state, created_at, updated_at)"
                     " VALUES(?, ?, ?, NULL, 0, 0, 'consumed', ?, ?)",
                     (kh, adopt_batch, sid_h, time.time(), time.time()))
        conn.commit()
        conn.close()
        await Worker(home).tick()
        conn = sqlite3.connect(str(Path(home) / "wake_ledger.db"))
        nb_h = conn.execute("SELECT COUNT(*) FROM wake_batches WHERE session_id = ?",
                            (sid_h,)).fetchone()[0]
        st_h = conn.execute("SELECT state, run_id FROM wake_batches WHERE batch_id = ?",
                            (adopt_batch,)).fetchone()
        conn.close()
        check(nb_h == 1 and st_h[0] in ("terminal", "accepted") and st_h[1],
              f"own reserved batch adopted and dispatched once: {st_h}")

        # (I) crash point 6 — died AFTER the accepted report, BEFORE terminal:
        # the run store is unknown to the worker; settle uncertain ONCE and
        # never re-POST (no second batch, no second provider run).
        sid_i = "api_sw_acc1"
        db.create_session(sid_i, model="compat-fixture", source="api_server")
        await deliver(sid_i, "accepted crash report", "jobI1", "execI1")
        ki = await dkey(sid_i, "jobI1", "execI1")
        conn = sqlite3.connect(str(Path(home) / "wake_ledger.db"))
        acc_batch = "wb_" + _secrets.token_hex(12)
        conn.execute("INSERT INTO wake_batches(batch_id, session_id, state,"
                     " canonical_input, batch_keys, created_at, updated_at, owner,"
                     " run_id) VALUES(?, ?, 'accepted', ?, ?, ?, ?, 'self:acc',"
                     " 'run_unseen_by_store')",
                     (acc_batch, sid_i, wake_ref()["module"].CANONICAL_INPUT,
                      json.dumps([ki]), time.time(), time.time()))
        conn.execute("INSERT INTO wake_consumption(delivery_key, batch_id, session_id,"
                     " message_id, report_order, ignored, state, created_at, updated_at)"
                     " VALUES(?, ?, ?, NULL, 0, 0, 'consumed', ?, ?)",
                     (ki, acc_batch, sid_i, time.time(), time.time()))
        conn.commit()
        conn.close()
        conn = sqlite3.connect(str(Path(home) / "cron_bridge.db"))
        conn.execute("UPDATE selfwake_intents SET state='watching', batch_id = ?"
                     " WHERE delivery_key = ?", (acc_batch, ki))
        conn.commit()
        conn.close()
        await Worker(home).tick()
        conn = sqlite3.connect(str(Path(home) / "wake_ledger.db"))
        nb_i = conn.execute("SELECT COUNT(*) FROM wake_batches WHERE session_id = ?",
                            (sid_i,)).fetchone()[0]
        st_i = conn.execute("SELECT state FROM wake_batches WHERE batch_id = ?",
                            (acc_batch,)).fetchone()[0]
        conn.close()
        check(nb_i == 1 and st_i == "uncertain-consumed",
              f"accepted-batch crash settles uncertain once, never re-POSTs:"
              f" {st_i} batches={nb_i}")

    return None
