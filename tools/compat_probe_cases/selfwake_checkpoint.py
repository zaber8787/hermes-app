"""WAKEFIX3: a chain limit opens only after a proven new human message."""
from __future__ import annotations

import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path
from unittest.mock import patch

from .cron_bridge import profile_db
from .selfwake import set_mode, sw_ref


async def case_selfwake_checkpoint(args, server, check):
    from .wake import wake_ref
    home = Path(os.environ["HERMES_HOME"])
    sw = sw_ref()
    store = wake_ref()["store"]
    db = profile_db()
    set_mode({"selfwake": True, "selfwake_chain_limit": 2,
              "selfwake_cooldown_seconds": 0})
    canonical = wake_ref()["module"].CANONICAL_INPUT

    async def decision(label, *, role=None, kind=None, content="human reply", newer=True):
        sid = "wf3_" + label
        db.create_session(sid, model="compat-fixture", source="api_server")
        fired_at = time.time() - 100
        sw.chain_note(home, sid, now=fired_at - 1)
        sw.chain_note(home, sid, now=fired_at)
        if role is not None:
            conn = sqlite3.connect(str(home / "state.db"))
            conn.execute(
                "INSERT INTO messages(session_id,role,content,display_kind,timestamp)"
                " VALUES(?,?,?,?,?)",
                (sid, role, content, kind, fired_at + 1 if newer else fired_at - 1))
            conn.commit()
            conn.close()
        admitted = []

        def fake_admit(*_args, **_kwargs):
            admitted.append(sid)
            return {"status": "busy"}  # no HTTP or provider call

        worker = sw.SelfWakeWorker(home)
        item = {"delivery_key": label.encode().hex().ljust(64, "0")[:64],
                "session_id": sid, "batch_id": None, "row_id": 1}
        with patch.object(store, "admit", fake_admit):
            await worker._process(sid, [item], {"chain_limit": 2,
                                               "cooldown_seconds": 0}, time.time())
        ledger = sw._ledger(home)
        row = ledger.execute("SELECT fires FROM selfwake_chain WHERE session_id=?",
                             (sid,)).fetchone()
        reset = ledger.execute(
            "SELECT COUNT(*) FROM selfwake_audit WHERE session_resolved=?"
            " AND phase='chain-reset' AND reason='human-checkpoint'", (sid,)).fetchone()[0]
        return bool(admitted), row["fires"], reset

    check(await decision("no_human") == (False, 2, 0),
          "at-limit chain without a checkpoint stays closed")
    check(await decision("bridge", role="user", kind="internal_notification") == (False, 2, 0),
          "bridge role=user is not a human checkpoint")
    check(await decision("canonical", role="user", content=canonical) == (False, 2, 0),
          "canonical wake input is not a human checkpoint")
    check(await decision("old_human", role="user", newer=False) == (False, 2, 0),
          "a human message before last_fire_at is not a checkpoint")
    check(await decision("new_human", role="user") == (True, 0, 1),
          "new human message resets the chain and admits the next sweep decision")

    admin = subprocess.run(
        [sys.executable, str(Path(__file__).resolve().parents[1] / "wake_chain_admin.py"),
         "--home", str(home), "--session", "wf3_no_human",
         "--expect-fires", "2", "--apply"],
        capture_output=True, text=True, check=True)
    import json
    result = json.loads(admin.stdout)
    check(result["applied"] and result["before"]["chain"]["fires"] == 2
          and result["after"]["chain"]["fires"] == 0,
          "Hermes admin entry resets exactly the requested chain")
    check(result["after"]["last_admin_reset_seq"] is not None,
          "admin reset writes a durable chain-reset audit")
