#!/usr/bin/env python3
"""01412FIX F3 (M4): a reminder is a NEW phase of the SAME channel, not a
re-route. Different phases of one event may ride the configured channel; a
DIFFERENT channel is still refused (claims survive reconfiguration)."""
import pathlib
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "compat"))

import notification_events as events  # noqa: E402
import notification_store as store  # noqa: E402


class ReminderPhaseTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="fix01412-f3-"))
        store.reset()
        self.reg = events.open_ledger({}, home_resolver=lambda: self.home,
                                      settings=lambda: None)
        events.set_capability(True)

    def tearDown(self):
        events.set_capability(False)
        store.close_all()

    def test_initial_then_reminder_publishes_twice_on_the_same_channel(self):
        """M4 red: the reminder must ACTUALLY be delivered (two publish
        calls), not swallowed by 'already_claimed_other_channel'."""
        calls = []
        eid, first = events.deliver(self.reg, owner_scope="me", run_id="r", sid="s",
                                    kind="approval_request", source_id="req-1",
                                    payload={"summary": "approval"}, phase="initial",
                                    channel="ntfy",
                                    publish=lambda: calls.append("initial") or True)
        eid2, second = events.deliver(self.reg, owner_scope="me", run_id="r", sid="s",
                                      kind="approval_request", source_id="req-1",
                                      payload={"summary": "reminder"},
                                      phase="reminder", channel="ntfy",
                                      publish=lambda: calls.append("reminder") or True)
        self.assertEqual(eid2, eid, "same semantic event")
        self.assertEqual(second, "enqueued",
                         f"the reminder must publish, got {second}")
        self.assertEqual(calls, ["initial", "reminder"],
                         "initial then reminder = TWO real deliveries")
        phases = {p: (c, st) for p, c, st in store.sent_phases(self.home, eid)}
        self.assertEqual(phases["reminder"], ("ntfy", "enqueued"))

    def test_reminder_allowed_gate_still_gates_on_read_and_pending(self):
        self.assertFalse(events.reminder_allowed(self.reg, owner_scope="me",
                                                 run_id="r9", request_id="q",
                                                 pending=False))
        eid, _ = store.record_event(self.home, owner_scope="me", run_id="r9",
                                    sid="s", kind="approval_request",
                                    source_id="q", payload={})
        self.assertTrue(events.reminder_allowed(self.reg, owner_scope="me",
                                                run_id="r9", request_id="q",
                                                pending=True))
        store.mark_read(self.home, "me", eid, "device")
        self.assertFalse(events.reminder_allowed(self.reg, owner_scope="me",
                                                 run_id="r9", request_id="q",
                                                 pending=True))

    def test_other_channel_is_still_refused_for_a_new_phase(self):
        calls = []
        eid, _ = events.deliver(self.reg, owner_scope="me", run_id="r7", sid="s",
                                kind="approval_request", source_id="req-7",
                                payload={}, phase="initial", channel="ntfy",
                                publish=lambda: calls.append(1) or True)
        _eid, verdict = events.deliver(self.reg, owner_scope="me", run_id="r7",
                                       sid="s", kind="approval_request",
                                       source_id="req-7", payload={},
                                       phase="reminder", channel="browser",
                                       publish=lambda: calls.append(2) or True)
        self.assertEqual(verdict, "already_claimed_other_channel")
        self.assertEqual(calls, [1], "a config change never re-routes to another channel")

    def test_gate_reports_the_reminder_as_delivered(self):
        gate = events.approval_initial_hook(self.reg)
        entry = {"owner_scope": "me", "run_id": "r8", "session_id": "s",
                 "request_id": "req-8"}
        published = []
        handled, ok = gate("initial", {"entry": entry, "pending": True,
                                       "publish": lambda: published.append("i") or True})
        self.assertTrue(handled and ok)
        handled, ok = gate("reminder", {"entry": entry, "pending": True,
                                        "publish": lambda: published.append("r") or True})
        self.assertTrue(handled, "the ledger owns the reminder decision")
        self.assertTrue(ok, f"M4 red: the reminder must be answered delivered "
                            f"(published={published})")
        self.assertEqual(published, ["i", "r"])


if __name__ == "__main__":
    unittest.main()
