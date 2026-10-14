"""Human checkpoints cannot be blocked or forged by canonical wake rows."""
import sqlite3
import sys
import tempfile
import types
from pathlib import Path
from unittest.mock import patch

from compat import auto_wake, auto_wake_store, self_wake


SID = "lineage"


class State:
    def __init__(self):
        self.conn = sqlite3.connect(":memory:")
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("CREATE TABLE messages(id INTEGER PRIMARY KEY, session_id TEXT,"
                          " role TEXT, display_kind TEXT, timestamp REAL, content TEXT)")

    def add(self, mid, stamp, content, kind=None):
        self.conn.execute("INSERT INTO messages VALUES(?,?,'user',?,?,?)",
                          (mid, SID, kind, stamp, content))
        self.conn.commit()

    def _read_all(self, sql, params):
        return [dict(row) for row in self.conn.execute(sql, params)]

    def resolve_resume_session_id(self, sid):
        return sid


def home():
    root = Path.cwd() / ".wakefix4-evidence"
    root.mkdir(exist_ok=True)
    return tempfile.TemporaryDirectory(prefix="pytest-checkpoint-", dir=root)


def seed_chain(path, fires=4):
    conn = auto_wake_store.open_ledger(path)
    conn.execute("INSERT INTO selfwake_chain(session_id,fires,last_fire_at,fused,updated_at)"
                 " VALUES(?,?,?,?,?)", (SID, fires, 100.0, 0, 100.0))
    conn.commit()
    return conn


def test_canonical_and_bridge_rows_do_not_checkpoint_but_human_does():
    db = State()
    db.add(1, 110.0, auto_wake.CANONICAL_INPUT)
    db.add(2, 120.0, auto_wake.CANONICAL_INPUT + "\n" + auto_wake.CANONICAL_INPUT)
    db.add(3, 130.0, "[Cron report: worker-done-watch]\nHEARTBEAT_OK\n"
                      + auto_wake.CANONICAL_INPUT)
    db.add(4, 140.0, "cron bridge report", "internal_notification")
    with home() as scratch:
        path = Path(scratch)
        conn = seed_chain(path)
        try:
            assert not self_wake.chain_human_checkpoint(path, db, SID, 100.0)
            db.add(5, 150.0, "A real human response")
            assert self_wake.chain_human_checkpoint(path, db, SID, 100.0)
            with patch.object(self_wake, "settings", return_value=(
                    "on", {"chain_limit": 5, "cooldown_seconds": 0}, None)):
                self_wake.chain_gate_checkpoint(path, SID, db, SID)
            assert conn.execute("SELECT fires FROM selfwake_chain WHERE session_id=?",
                                (SID,)).fetchone()[0] == 0
        finally:
            auto_wake_store.reset()


def test_periodic_worker_resets_below_limit_without_due_intent():
    db = State()
    db.add(1, 110.0, auto_wake.CANONICAL_INPUT)
    db.add(2, 150.0, "A real human response")
    with home() as scratch:
        path = Path(scratch)
        conn = seed_chain(path)
        try:
            registry = types.SimpleNamespace(acquire=lambda _: db,
                                             release_or_close=lambda _: None)
            with patch.dict(sys.modules, {"hermes_state_registry": registry}):
                cursor = self_wake.checkpoint_active_chains(path)
            assert cursor == ""
            assert conn.execute("SELECT fires FROM selfwake_chain WHERE session_id=?",
                                (SID,)).fetchone()[0] == 0
            audit = conn.execute("SELECT reason FROM selfwake_audit WHERE phase='chain-reset'"
                                 ).fetchone()[0]
            assert audit == "human-checkpoint"
        finally:
            auto_wake_store.reset()
