"""Regression for repeated cron executions and packaged heartbeat rows.

Shapes mirror state.db rows 42378/42385/42386; the exact private rows are
also replayed read-only by .wakefix4-evidence/repro.py on the deployment host.
"""
import hashlib
import json
import tempfile
from pathlib import Path

from compat import auto_wake, auto_wake_store


SID = "session"
JOB = "worker-done-watch"
FOOTER = ('To stop or manage this job, send me a new message '
          '(e.g. "stop reminder worker-done-watch").')


def wrapped(body):
    return (f"[Cron report: {JOB}]\nCronjob Response: {JOB}\n"
            f"(job_id: job-1)\n-------------\n\n{body}\n\n{FOOTER}")


class State:
    def __init__(self):
        self.rows = {}

    def add(self, mid, key, content, timestamp, job_id="job-1"):
        self.rows[key] = {
            "id": mid, "timestamp": timestamp, "content": content,
            "sch": 1, "job_id": job_id, "role": "user",
            "display_kind": "internal_notification",
            "display_metadata": json.dumps({"hermes_app_cron": {
                "schema": 1, "job_id": job_id,
                "execution_id": f"execution-{mid}", "delivery_key": key}}),
        }

    def get_session(self, sid):
        return {"source": "api_server", "hidden": 0, "archived": 0,
                "ended_at": None} if sid == SID else None

    def _session_turn_lease_key(self, sid):
        return sid

    def _read_all(self, sql, params):
        if "session_turn_leases" in sql:
            return []
        if "WHERE id = ? LIMIT 1" in sql:
            return [row for row in self.rows.values() if row["id"] == params[0]]
        return [self.rows[params[-1]]] if params[-1] in self.rows else []


def key(label):
    return hashlib.sha256(label.encode()).hexdigest()


def home():
    root = Path.cwd() / ".wakefix4-evidence"
    root.mkdir(exist_ok=True)
    return tempfile.TemporaryDirectory(prefix="pytest-", dir=root)


def test_packaged_idle_heartbeat_is_ignored_but_real_mention_is_not():
    idle = wrapped("步1 輸出 `idle`，無新事項。\n\nHEARTBEAT_OK")
    assert auto_wake.is_ignored_report(idle)
    assert auto_wake.is_ignored_report(idle + "\n" + auto_wake.CANONICAL_INPUT)
    assert auto_wake.is_ignored_report(wrapped("HEARTBEAT_OK"))
    assert not auto_wake.is_ignored_report(
        wrapped("Action required: previous HEARTBEAT_OK was wrong."))


def test_same_source_body_has_one_batch_per_cooldown_window():
    source = wrapped("COMMIT_WITHOUT_DONE: action needed")
    variant = source + "\n" + auto_wake.CANONICAL_INPUT
    assert auto_wake.normalized_report_body(source) == auto_wake.normalized_report_body(variant)
    state = State()
    k1, k2, k3 = key("first"), key("second"), key("third")
    state.add(1, k1, source, 10000)
    state.add(2, k2, variant, 10300)
    state.add(3, k3, variant, 10901)
    with home() as path:
        p = Path(path)
        auto_wake_store.configure(reviewed=True)
        try:
            one = auto_wake_store.admit(p, session_id=SID, resolved=SID,
                                        keys=[k1], db=state, now=10000)
            assert one["status"] == "admitted"
            conn = auto_wake_store.open_ledger(p)
            conn.execute("UPDATE wake_batches SET state='terminal', terminal_at=10010"
                         " WHERE batch_id=?", (one["batch_id"],))
            conn.commit()
            two = auto_wake_store.admit(p, session_id=SID, resolved=SID,
                                        keys=[k2], db=state, now=10300)
            assert two["status"] == "empty" and two["ignored"] == [k2]
            assert conn.execute("SELECT ignored FROM wake_consumption WHERE delivery_key=?",
                                (k2,)).fetchone()[0] == 1
            three = auto_wake_store.admit(p, session_id=SID, resolved=SID,
                                          keys=[k3], db=state, now=10901)
            assert three["status"] == "admitted"
        finally:
            auto_wake_store.reset()


def test_different_job_same_body_is_not_cooldown_duplicate():
    source = wrapped("substantive report")
    state = State()
    k1, k2 = key("job-one"), key("job-two")
    state.add(1, k1, source, 10000)
    state.add(2, k2, source, 10300, job_id="job-2")
    with home() as path:
        p = Path(path)
        auto_wake_store.configure(reviewed=True)
        try:
            one = auto_wake_store.admit(p, session_id=SID, resolved=SID,
                                        keys=[k1], db=state, now=10000)
            conn = auto_wake_store.open_ledger(p)
            conn.execute("UPDATE wake_batches SET state='terminal', terminal_at=10010"
                         " WHERE batch_id=?", (one["batch_id"],))
            conn.commit()
            two = auto_wake_store.admit(p, session_id=SID, resolved=SID,
                                        keys=[k2], db=state, now=10300)
            assert two["status"] == "admitted"
        finally:
            auto_wake_store.reset()
