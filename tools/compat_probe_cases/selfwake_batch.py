"""SELFWAKE2 (T4): zombie-batch red lines — the ledger is NEVER cleaned here.

The production incident had 7 reserved + 1 accepted wake_batches whose intents
are ALL done (run.cancelled / ignored / uncertain-consumed). This family pins
the ONLY sweep behaviors that are allowed around them (TASK/SELFWAKE2.md S4):

  * _due selects pending/watching only — done zombie intents never resurface;
  * reconcile must not reopen or re-add anything for a batch whose intent is
    already done;
  * a pending sibling on another session still progresses through a real
    tick, which then completes and releases _busy (不卡循環);
  * the wake_batches rows keep their exact states — no fabricated terminal
    transitions, no ledger surgery as part of keeping the worker alive.

Ledger/intents termination inconsistency is a SEPARATE, scoped follow-up;
admission, quotas, generation cutoffs and delivery-key consumption are
untouched by design. Fixture mirrors .sw2-scratch/batch_probe.py with real
_due/reconcile/tick code and zero HTTP.
"""
from __future__ import annotations
import asyncio
import os
import time
from pathlib import Path
from unittest.mock import patch

from .cron_bridge import profile_db


def _intents(home):
    import sqlite3
    conn = sqlite3.connect(str(Path(home) / "cron_bridge.db"))
    conn.row_factory = sqlite3.Row
    rows = [dict(r) for r in conn.execute(
        "SELECT delivery_key, state, batch_id, session_id FROM selfwake_intents")]
    conn.close()
    return rows


def _batches(home):
    import sqlite3
    path = Path(home) / "wake_ledger.db"
    if not path.exists():
        return []
    conn = sqlite3.connect(str(path))
    rows = conn.execute("SELECT batch_id, state FROM wake_batches ORDER BY batch_id").fetchall()
    conn.close()
    return [(r[0], r[1]) for r in rows]


async def case_selfwake_batch(args, server, check):
    home = Path(os.environ["HERMES_HOME"])
    from gateway.platforms import api_server as api
    sw = getattr(api, "_hermes_app_compat_state_v1")["selfwake"]["module"]
    db = profile_db()
    b = sw._bridge(home)
    sw.ensure_bridge_schema(b)
    l = sw._ledger(home)
    now = time.time()

    # 7 reserved + 1 accepted with DONE intents — the production shape.
    for i in range(8):
        batch = f"t4-batch-{i}"
        state = "accepted" if i == 7 else "reserved"
        db.create_session(f"t4-zombie-{i}", model="compat-fixture", source="api_server")
        l.execute(
            "INSERT INTO wake_batches(batch_id,session_id,state,canonical_input,batch_keys,"
            "created_at,updated_at,owner,run_id) VALUES(?,?,?,?,?,?,?,?,?)",
            (batch, f"t4-zombie-{i}", state, "", "[]", now - 86400, now - 86400,
             "self:fixture", "fixture-run" if i == 7 else None))
        b.execute(
            "INSERT INTO selfwake_intents(delivery_key,home,session_id,generation,cutoff,"
            "reason,batch_id,state,next_attempt_at,created_at,updated_at,detail)"
            " VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
            (f"{i:064x}", str(home), f"t4-zombie-{i}", 1, now - 172800, "fixture", batch,
             "done", now - 86400, now - 86400, now - 86400,
             "uncertain-consumed" if i == 7 else "run.cancelled"))
    b.commit()
    l.commit()
    ledger_before = _batches(home)
    check(len(ledger_before) == 8 and sorted(s for _, s in ledger_before) ==
          ["accepted"] + ["reserved"] * 7, "fixture: 7 reserved + 1 accepted batches")

    w = sw.SelfWakeWorker(home)
    check(not w._due(now), "done zombie intents are NEVER due")
    rec = await asyncio.to_thread(sw.reconcile, home)
    check(len(_intents(home)) == 8,
          f"reconcile neither reopens nor re-adds intents for done zombies ({rec})")
    check(all(r["state"] == "done" for r in _intents(home)), "no zombie intent was reopened")

    # One genuinely pending sibling: the sweep must progress through it while
    # skipping every zombie (real candidate selection; only the terminal
    # dispatch is stubbed to keep the family HTTP-free).
    db.create_session("t4-active", model="compat-fixture", source="api_server")
    b.execute(
        "INSERT INTO selfwake_intents(delivery_key,home,session_id,generation,cutoff,reason,"
        "state,next_attempt_at,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
        ("f" * 64, str(home), "t4-active", 1, now - 172800, "fixture", "pending",
         now - 1, now, now))
    b.commit()
    due = w._due(now)
    check([r["session_id"] for r in due] == ["t4-active"],
          "_due surfaces ONLY the pending sibling")
    calls = []

    async def process(session, items, params, at):
        calls.append(session)
        b.execute("UPDATE selfwake_intents SET state='done', detail='fixture-consumed'"
                  " WHERE delivery_key=?", ("f" * 64,))
        b.commit()
    with patch.object(sw, "settings", return_value=("on", {
            "chain_limit": 3, "cooldown_seconds": 60}, None)), \
         patch.object(sw, "reconcile", return_value={}), \
         patch.object(w, "_process", process):
        await asyncio.wait_for(w.tick(), timeout=2)
    check(calls == ["t4-active"], "tick processed the pending sibling only")
    check(not w._busy, "tick completed and released _busy (loop not wedged)")

    check(_batches(home) == ledger_before,
          "wake_batches untouched: no fabricated terminals, no ledger cleaning")
    check(all(r["state"] == "done" for r in _intents(home)
              if r["session_id"] != "t4-active"),
          "zombie intents still done, untouched")
    b.execute("DELETE FROM selfwake_intents")
    l.execute("DELETE FROM wake_batches")
    b.commit()
    l.commit()
