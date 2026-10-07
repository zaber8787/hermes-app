#!/usr/bin/env python3
"""01412FIX F4 (M5): the browser channel is a CLIENT claim of a server
PENDING INTENT — the server never owns the browser delivery, and the
deliver -> claim -> show -> report cycle actually works end to end."""
import pathlib
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "compat"))
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tests"))

import notification_events as events  # noqa: E402
import notification_store as store  # noqa: E402

from test_notification_fix import _env, Request  # noqa: E402
import asyncio  # noqa: E402


class BrowserClaimTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="fix01412-f4-"))
        store.reset()
        self.reg = events.open_ledger({}, home_resolver=lambda: self.home,
                                      settings=lambda: None)  # -> browser
        events.set_capability(True)

    def tearDown(self):
        events.set_capability(False)
        store.close_all()

    def test_real_deliver_then_device_claim_shows_and_reports(self):
        """M5 red: the audit repro 'browser enqueue: queued / client claim:
        (already_claimed, ...)' must become claimed + a working show."""
        eid, verdict = events.deliver(self.reg, owner_scope="me", run_id="rb",
                                      sid="s", kind="failed", source_id="terminal",
                                      payload={})
        self.assertEqual(verdict, "queued")
        route = _env(self.home, "me")
        claim = asyncio.run(route["claim_post"](
            None, Request(eid, {"device_id": "dev-A"})))
        self.assertEqual(claim["verdict"], "claimed",
                         f"M5 red: device claim must win the pending intent, "
                         f"got {claim}")
        self.assertTrue(claim["show_token"])
        report = asyncio.run(route["delivery_post"](
            None, Request(eid, {"delivery_id": claim["delivery_id"],
                                "outcome": "shown", "device_id": "dev-A",
                                "show_token": claim["show_token"]})))
        self.assertNotIn("http", report, f"show report must land: {report}")
        self.assertEqual(store.delivery_state(self.home, eid, "initial", "browser"),
                         "shown")

    def test_second_device_converges_immediately(self):
        eid, verdict = events.deliver(self.reg, owner_scope="me", run_id="rc",
                                      sid="s", kind="completed",
                                      source_id="terminal", payload={})
        self.assertEqual(verdict, "queued")
        route = _env(self.home, "me")
        first = asyncio.run(route["claim_post"](None, Request(eid, {"device_id": "a"})))
        second = asyncio.run(route["claim_post"](None, Request(eid, {"device_id": "b"})))
        self.assertEqual(first["verdict"], "claimed")
        self.assertEqual(second["verdict"], "already_claimed")
        self.assertIsNone(second["show_token"],
                          "the loser gets NO show grant: exactly one device alerts")

    def test_replay_of_the_semantic_event_queues_nothing_new(self):
        eid1, v1 = events.deliver(self.reg, owner_scope="me", run_id="rd", sid="s",
                                  kind="completed", source_id="terminal", payload={})
        eid2, v2 = events.deliver(self.reg, owner_scope="me", run_id="rd", sid="s",
                                  kind="completed", source_id="terminal", payload={})
        self.assertEqual((eid1, v1), (eid2, v2))


if __name__ == "__main__":
    unittest.main()
