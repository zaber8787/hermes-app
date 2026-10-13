"""Busy/quota intents have a durable, observable terminal retry boundary."""

import asyncio
import pathlib
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import patch

from compat import auto_wake_store, cron_delivery_store, self_wake


class RetryLifecycleTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = pathlib.Path(self.tmp.name)
        self.conn = cron_delivery_store.open_bridge(self.home)
        self_wake.ensure_bridge_schema(self.conn)
        self.db = types.SimpleNamespace(resolve_resume_session_id=lambda sid: sid)
        self.registry = types.SimpleNamespace(
            acquire=lambda _: self.db,
            release_or_close=lambda _: None,
        )
        self.addCleanup(auto_wake_store.reset)
        self.addCleanup(cron_delivery_store.reset)

    def intent(self, *, detail, attempts, created_at):
        key = detail[0] * 64
        self.conn.execute(
            "INSERT INTO selfwake_intents(delivery_key, home, session_id, generation,"
            " cutoff, reason, state, detail, attempts, next_attempt_at, created_at, updated_at)"
            " VALUES(?,?,?,1,0,'fixture','pending',?,?,0,?,?)",
            (key, str(self.home), "s", detail, attempts, created_at, created_at),
        )
        self.conn.commit()
        return dict(self.conn.execute(
            "SELECT * FROM selfwake_intents WHERE delivery_key=?", (key,)
        ).fetchone())

    def process(self, item, admit_status):
        calls = []

        def admit(*args, **kwargs):
            calls.append(1)
            return {"status": admit_status, "retry_after_s": 300}

        with patch.dict(sys.modules, {"hermes_state_registry": self.registry}), \
             patch.object(self_wake, "lineage_root", return_value="s"), \
             patch.object(self_wake, "chain_gate_checkpoint", return_value=(True, None, 0, 0)), \
             patch.object(auto_wake_store, "admit", side_effect=admit):
            asyncio.run(self_wake.SelfWakeWorker(self.home)._process(
                "s", [item], {}, time.time()
            ))
        row = dict(self.conn.execute(
            "SELECT * FROM selfwake_intents WHERE delivery_key=?", (item["delivery_key"],)
        ).fetchone())
        return row, calls

    def test_old_busy_intent_stops_before_another_admit_and_is_audited(self):
        item = self.intent(detail="busy", attempts=2, created_at=time.time() - 90000)
        row, calls = self.process(item, "busy")
        self.assertEqual(calls, [])
        self.assertEqual(row["state"], "void")
        self.assertEqual(row["detail"], "busy-age-exhausted")
        audit = auto_wake_store.open_ledger(self.home).execute(
            "SELECT reason FROM selfwake_audit ORDER BY seq DESC LIMIT 1"
        ).fetchone()
        self.assertEqual(audit["reason"], "busy-age-exhausted")

    def test_quota_attempt_limit_stops_before_another_admit(self):
        item = self.intent(detail="quota", attempts=128, created_at=time.time())
        row, calls = self.process(item, "quota_exceeded")
        self.assertEqual(calls, [])
        self.assertEqual(row["state"], "void")
        self.assertEqual(row["detail"], "quota-attempts-exhausted")

    def test_young_busy_intent_keeps_existing_retry_cadence(self):
        now = time.time()
        item = self.intent(detail="busy", attempts=1, created_at=now)
        row, calls = self.process(item, "busy")
        self.assertEqual(calls, [1])
        self.assertEqual(row["state"], "pending")
        self.assertEqual(row["detail"], "busy")
        self.assertGreaterEqual(row["next_attempt_at"], now + 5)
        self.assertLess(row["next_attempt_at"], time.time() + 8)


if __name__ == "__main__":
    unittest.main()
