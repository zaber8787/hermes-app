#!/usr/bin/env python3
"""01413FIX F4: crash-gap reconciliation + receipt corners (M5, m1, m3, m5).
Red at the audit HEAD (repro reconciliation_gap:scan-starvation /
:receipt-without-intent, connection_cache; spool_exhaustion), green after
F4. m4 (multi-owner quota transaction) is a SPEC-LISTED limitation and is
deliberately out of scope for this batch — see the F4 commit message."""
import json
import os
import pathlib
import sqlite3
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT_DIR = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT_DIR))

from compat import auto_wake_store as wake, cron_delivery_store as cron  # noqa: E402
from compat import self_wake  # noqa: E402


def _state_db(home, count):
    state = sqlite3.connect(pathlib.Path(home) / "state.db")
    state.row_factory = sqlite3.Row
    state.execute("CREATE TABLE messages(id INTEGER, session_id TEXT, timestamp REAL,"
                      " role TEXT, display_kind TEXT, display_metadata TEXT)")
    for i in range(count):
        key = f"{i + 1:064x}"
        state.execute("INSERT INTO messages VALUES(?,?,?,?,?,?)",
                      (i + 1, "session", i + 1, "user", "internal_notification",
                       json.dumps({"hermes_app_cron": {"schema": 1, "delivery_key": key,
                                                      "digest": "fixture"}})))
    return state


class ReconciliationScan(unittest.TestCase):
    def _fixture(self, count):
        home = pathlib.Path(tempfile.mkdtemp(prefix="fix01413-f4-"))
        wake.configure(reviewed=True)  # reconcile is gated on reviewed bindings
        c = cron.open_bridge(home)
        self_wake.generation_cutoff(c, 0)
        state = _state_db(home, count)
        self.addCleanup(state.close)
        self.addCleanup(c.close)
        return home, c, state

    def test_M5_gap_beyond_the_first_200_reports_converges(self):
        home, c, state = self._fixture(201)
        for i in range(200):  # the first 200 are already finalized
            self_wake.on_delivered(c, home=str(home), session_id="session",
                                   delivery_key=f"{i + 1:064x}", row_id=i + 1,
                                   reason="delivered-direct")
        c.commit()
        state.commit()

        class DB:
            def _read_all(self, sql, args):
                return state.execute(sql, args).fetchall()
        with patch.object(self_wake, "settings", return_value=("on", {}, None)), \
                patch.dict(sys.modules, {"hermes_state_registry": SimpleNamespace(
                    acquire=None, release_or_close=None)}):
            passes = [self_wake.reconcile(home, db=DB()) for _ in range(2)]
        intents = c.execute("SELECT COUNT(*) FROM selfwake_intents").fetchone()[0]
        self.assertEqual(intents, 201,
                         f"M5 red: 201 reports, {intents} intents, passes={passes}")
        # a THIRD pass must not re-add anything (the cursor is a seek, not a
        # re-scan; dedup stays by delivery_key)
        with patch.object(self_wake, "settings", return_value=("on", {}, None)), \
                patch.dict(sys.modules, {"hermes_state_registry": SimpleNamespace(
                    acquire=None, release_or_close=None)}):
            third = self_wake.reconcile(home, db=DB())
        self.assertEqual(third["added"], 0)
        self.assertEqual(c.execute("SELECT COUNT(*) FROM selfwake_intents").fetchone()[0], 201)

    def test_m1_delivered_receipt_with_a_failed_intent_is_compensated(self):
        home, c, state = self._fixture(1)
        key = f"{1:064x}"
        cron._receipt(c, key, str(home), "execution", "session", "delivered", row_id=1)
        with patch.object(self_wake, "on_delivered",
                          side_effect=RuntimeError("injected-intent-failure")):
            cron._self_wake_intent(c, str(home), "session", key, 1, "delivered-direct")
        c.commit()
        state.commit()

        class DB:
            def _read_all(self, sql, args):
                return state.execute(sql, args).fetchall()
        with patch.object(self_wake, "settings", return_value=("on", {}, None)), \
                patch.dict(sys.modules, {"hermes_state_registry": SimpleNamespace(
                    acquire=None, release_or_close=None)}):
            passes = [self_wake.reconcile(home, db=DB()) for _ in range(2)]
        intents = c.execute("SELECT COUNT(*) FROM selfwake_intents").fetchone()[0]
        self.assertEqual(intents, 1,
                         f"m1 red: delivered receipt with a failed intent stayed "
                         f"uncompensated, passes={passes}")

    def test_m1_plain_off_period_receipt_is_never_replayed(self):
        # a delivered receipt WITHOUT the intent-failure marker is history
        # (delivered while off/shadow): reconciliation must add NOTHING.
        home, c, state = self._fixture(1)
        cron._receipt(c, f"{1:064x}", str(home), "execution", "session",
                      "delivered", row_id=1)
        c.commit()
        state.commit()

        class DB:
            def _read_all(self, sql, args):
                return state.execute(sql, args).fetchall()
        with patch.object(self_wake, "settings", return_value=("on", {}, None)), \
                patch.dict(sys.modules, {"hermes_state_registry": SimpleNamespace(
                    acquire=None, release_or_close=None)}):
            first = self_wake.reconcile(home, db=DB())
        self.assertEqual(first["added"], 0)


class ConnectionCache(unittest.TestCase):
    def test_m3_both_stores_cache_one_handle_per_home(self):
        for opener, cache, reset in ((wake.open_ledger, wake._LEDGERS, wake.reset),
                                     (cron.open_bridge, cron._bridges, cron.reset)):
            home = pathlib.Path(tempfile.mkdtemp(prefix="fix01413-cache-"))
            reset()  # this probe owns the module cache for its duration
            conns = [opener(home) for _ in range(30)]
            try:
                self.assertEqual(len({id(c) for c in conns}), 1,
                                 "open_* must return the cached managed handle")
                self.assertEqual(len(cache), 1)
                reset()
                import sqlite3
                for c in conns:
                    with self.assertRaises(sqlite3.ProgrammingError):
                        c.execute("SELECT 1")
            finally:
                reset()
                for c in conns:
                    try:
                        c.close()
                    except Exception:
                        pass


class SpoolExhaustion(unittest.TestCase):
    def test_m5_retry_exhaustion_lands_failed_not_orphaned_queued(self):
        home = pathlib.Path(tempfile.mkdtemp(prefix="fix01413-spool-"))
        cron.configure(insert_sql="unused", errors={})
        c = cron.open_bridge(home)
        c.execute("INSERT OR REPLACE INTO pending(delivery_key,home,session_id,"
                  "identity,content,attempts,next_retry_at,created_at,updated_at)"
                  " VALUES('exhausted',?,'session',?,'report',23,0,0,0)",
                  (str(home), json.dumps({"job_id": "test", "execution_id": "test"})))
        cron._receipt(c, "exhausted", str(home), "test", "session", "queued")
        c.commit()
        with patch.object(cron, "_attempt",
                          return_value={"status": "queued", "reason": "db_busy"}):
            first = cron.drain_home(home, now=10 ** 12)
            second = cron.drain_home(home, now=10 ** 12)
        row = c.execute("SELECT attempts FROM pending WHERE delivery_key='exhausted'").fetchone()
        self.assertIsNone(row, "the exhausted row must leave the spool")
        self.assertEqual(first["failed"], 1,
                         f"m5 red: 24th busy attempt reported {first}")
        self.assertEqual(second, {"delivered": 0, "deduped": 0, "queued": 0, "failed": 0})
        receipt = cron.receipt_for(home, "test")
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(receipt["error"], "retry_exhausted")
        c.close()


if __name__ == "__main__":
    unittest.main()
