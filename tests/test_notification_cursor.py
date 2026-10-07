#!/usr/bin/env python3
"""01412FIX F2: reads are OBSERVABLE by the incremental cursor (M2) and an
overflow page resumes from the actual last delivered seq (M3)."""
import pathlib
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "compat"))

import notification_store as store  # noqa: E402


class CursorConvergenceTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="fix01412-f2-"))
        store.reset()

    def tearDown(self):
        store.close_all()

    def test_read_converges_on_the_incremental_cursor(self):
        """M2 red: device B at cursor=c must SEE device A's read."""
        eid, _ = store.record_event(self.home, owner_scope="me", run_id="r",
                                    sid="s", kind="completed",
                                    source_id="terminal", payload={})
        items, overflow, cursor = store.events_after(self.home, "me", 0)
        self.assertEqual([e["event_id"] for e in items], [eid])
        self.assertFalse(overflow)
        store.mark_read(self.home, "me", eid, "device")  # device A acks
        items2, _, cursor2 = store.events_after(self.home, "me", cursor)
        self.assertEqual([e["event_id"] for e in items2], [eid],
                         "a converged read must reappear on the delta, "
                         "not stay a phantom unread forever")
        self.assertGreater(cursor2, cursor, "the read advanced a change seq")
        self.assertTrue(items2[0]["read_at"] and items2[0]["read_by"] >= 1)
        # idempotent: a second ack by the same reader never re-stamps
        store.mark_read(self.home, "me", eid, "device")
        items3, _, cursor3 = store.events_after(self.home, "me", cursor2)
        self.assertEqual(items3, [], "an ack the ledger already has changes nothing")
        self.assertEqual(cursor3, cursor2)

    def test_overflow_pages_never_skip_the_tail(self):
        """M3 red: 101 events, page size 100 — page 2 resumes from the last
        DELIVERED seq; the 101st is never skipped by a head jump."""
        for i in range(101):
            store.record_event(self.home, owner_scope="me", run_id=f"r{i}",
                               sid="s", kind="completed",
                               source_id=f"terminal-{i}", payload={})
        page1, overflow1, cursor1 = store.events_after(self.home, "me", 0)
        self.assertEqual(len(page1), 100)
        self.assertTrue(overflow1)
        self.assertEqual(cursor1, 100,
                         "next cursor must be the last delivered seq, not the head")
        self.assertLess(cursor1, store.head_seq(self.home))
        page2, overflow2, cursor2 = store.events_after(self.home, "me", cursor1)
        self.assertEqual(len(page2), 1, "the 101st event is delivered, not skipped")
        self.assertFalse(overflow2)
        self.assertEqual(cursor2, 101)
        seen = {e["event_id"] for e in page1} | {e["event_id"] for e in page2}
        self.assertEqual(len(seen), 101)

    def test_created_events_stay_on_the_same_observable_stream(self):
        for i in range(3):
            store.record_event(self.home, owner_scope="me", run_id=f"r{i}",
                               sid="s", kind="completed",
                               source_id=f"t{i}", payload={})
        store.mark_read(self.home, "me",
                        store.event_id_for("me", "r1", "completed", "t1"), "device")
        items, _, cursor = store.events_after(self.home, "me", 0)
        self.assertEqual(len(items), 3)  # three events; the read one re-stamps
        self.assertEqual(cursor, 4)      # its change_seq moved to the new slot
        ids = [e["event_id"] for e in items]
        self.assertEqual(ids.count(store.event_id_for("me", "r1", "completed", "t1")), 1)


if __name__ == "__main__":
    unittest.main()
