#!/usr/bin/env python3
"""NOTIF2 B1: the browser surface runs IN PARALLEL with the system channel.

Supersedes the R6 fallback-only contract: an ntfy-configured account keeps
its ntfy publish AND may alert browsers through the same claim ledger. The
channel dimension of the delivery key keeps the two surfaces independent —
each claims its own one show grant; a claim row is still never re-sent or
re-routed WITHIN its channel.
"""
import pathlib
import sys
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "compat"))
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tests"))

import asyncio  # noqa: E402
import notification_events as events  # noqa: E402
import notification_store as store  # noqa: E402

from test_notification_fix import _env, Request  # noqa: E402

NTFY = ("http://ntfy.invalid", "topic-x")


def _claim_route(home, scope, *, ntfy=True):
    ns = _env(home, scope)
    ns["reg"]["settings"] = (lambda: NTFY) if ntfy else (lambda: None)
    return ns


class RestClaimOnNtfyTests(unittest.TestCase):
    """RED-2: claim_post must stop answering 409 channel_not_browser when
    the SERVER's system channel is ntfy — the browser claim is a parallel
    surface, not a channel violation."""

    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="notif2-b1-"))
        store.reset()
        events.set_capability(True)

    def tearDown(self):
        events.set_capability(False)
        store.close_all()

    def test_claim_on_ntfy_account_wins_with_a_show_token(self):
        eid, _ = store.record_event(self.home, owner_scope="me", run_id="r",
                                    sid="s", kind="completed",
                                    source_id="terminal", payload={})
        route = _claim_route(self.home, "me")
        loop = asyncio.new_event_loop()
        try:
            first = loop.run_until_complete(route["claim_post"](
                None, Request(eid, {"device_id": "dev-A"})))
            second = loop.run_until_complete(route["claim_post"](
                None, Request(eid, {"device_id": "dev-B"})))
        finally:
            loop.close()
        self.assertNotIn("http", first,
                         f"NOTIF2 B1 red: ntfy-configured accounts must "
                         f"still be able to claim the browser surface, got {first}")
        self.assertEqual(first["verdict"], "claimed")
        self.assertTrue(first["show_token"])
        self.assertEqual(second["verdict"], "already_claimed")
        self.assertIsNone(second["show_token"],
                          "one show grant per event across all browser devices")

    def test_read_event_still_refuses_the_browser_grant(self):
        eid, _ = store.record_event(self.home, owner_scope="me", run_id="r2",
                                    sid="s", kind="completed",
                                    source_id="terminal", payload={})
        store.mark_read(self.home, "me", eid, "device")
        route = _claim_route(self.home, "me")
        loop = asyncio.new_event_loop()
        try:
            answer = loop.run_until_complete(route["claim_post"](
                None, Request(eid, {"device_id": "dev-A"})))
        finally:
            loop.close()
        self.assertEqual(answer.get("http"), 409)
        self.assertEqual(answer.get("code"), "already_read")


class DualSurfaceDeliverTests(unittest.TestCase):
    """RED-3: the sent_phases cross-channel gate must NOT make browser and
    ntfy swallow each other — in either arrival order."""

    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="notif2-b1d-"))
        store.reset()
        self.reg = events.open_ledger({}, home_resolver=lambda: self.home,
                                      settings=lambda: NTFY)
        events.set_capability(True)

    def tearDown(self):
        events.set_capability(False)
        store.close_all()

    def test_browser_first_then_ntfy_still_publishes_once(self):
        eid, _ = store.record_event(self.home, owner_scope="me", run_id="r1",
                                    sid="s", kind="completed",
                                    source_id="terminal", payload={})
        verdict, _did = store.claim_delivery(self.home, event_id=eid,
                                             phase="initial", channel="browser",
                                             delivery_id="d-b", device_id="dev")
        self.assertEqual(verdict, "claimed")
        posts = []
        _eid, outcome = events.deliver(self.reg, owner_scope="me", run_id="r1",
                                       sid="s", kind="completed",
                                       source_id="terminal", payload={},
                                       publish=lambda: posts.append(1) or True)
        self.assertEqual(outcome, "enqueued",
                         f"B1 red: a browser claim must not swallow the "
                         f"ntfy delivery ({outcome})")
        self.assertEqual(posts, [1])
        _eid, replay = events.deliver(self.reg, owner_scope="me", run_id="r1",
                                      sid="s", kind="completed",
                                      source_id="terminal", payload={},
                                      publish=lambda: posts.append(1) or True)
        self.assertTrue(replay.startswith("already"))
        self.assertEqual(posts, [1], "one ntfy publish per semantic event")

    def test_ntfy_first_then_browser_claim_is_untouched(self):
        posts = []
        eid, outcome = events.deliver(self.reg, owner_scope="me", run_id="r2",
                                      sid="s", kind="completed",
                                      source_id="terminal", payload={},
                                      publish=lambda: posts.append(1) or True)
        self.assertEqual(outcome, "enqueued")
        verdict, _did = store.claim_delivery(self.home, event_id=eid,
                                             phase="initial", channel="browser",
                                             delivery_id="d-b", device_id="dev")
        self.assertEqual(verdict, "claimed",
                         "an ntfy claim must not swallow the browser surface")
        self.assertEqual(store.delivery_state(self.home, eid, "initial", "ntfy"),
                         "enqueued")
        self.assertEqual(store.delivery_state(self.home, eid, "initial", "browser"),
                         "claimed")

    def test_a_claimed_row_never_changes_channel(self):
        """Parallel surfaces do NOT license re-routing: the (ntfy, initial)
        row stays ntfy-owned; a later reminder phase on the SAME channel is
        legitimate, a settled phase never re-sends."""
        calls = []
        eid, _ = events.deliver(self.reg, owner_scope="me", run_id="r3", sid="s",
                                kind="approval_request", source_id="req",
                                payload={}, phase="initial", channel="ntfy",
                                publish=lambda: calls.append("initial") or True)
        _eid, again = events.deliver(self.reg, owner_scope="me", run_id="r3",
                                     sid="s", kind="approval_request",
                                     source_id="req", payload={},
                                     phase="initial", channel="ntfy",
                                     publish=lambda: calls.append("dup") or True)
        self.assertTrue(again.startswith("already"))
        self.assertEqual(calls, ["initial"])

    def test_foreign_channel_pair_still_refuses_re_route(self):
        """Only browser/ntfy run in parallel; an unrelated channel may never
        take over a claimed delivery."""
        calls = []
        eid, _ = events.deliver(self.reg, owner_scope="me", run_id="r4", sid="s",
                                kind="approval_request", source_id="req4",
                                payload={}, phase="initial", channel="carrier-pigeon",
                                publish=lambda: calls.append(1) or True)
        _eid, verdict = events.deliver(self.reg, owner_scope="me", run_id="r4",
                                       sid="s", kind="approval_request",
                                       source_id="req4", payload={},
                                       phase="reminder", channel="ntfy",
                                       publish=lambda: calls.append(2) or True)
        self.assertEqual(verdict, "already_claimed_other_channel")
        self.assertEqual(calls, [1])

    def test_reports_never_cross_channels(self):
        posts = []
        eid, _ = events.deliver(self.reg, owner_scope="me", run_id="r5", sid="s",
                                kind="completed", source_id="terminal", payload={},
                                publish=lambda: posts.append(1) or True)
        verdict, did = store.claim_delivery(self.home, event_id=eid, phase="initial",
                                            channel="browser", delivery_id="d-b",
                                            device_id="dev", show_token="tok")
        self.assertEqual(verdict, "claimed")
        self.assertEqual(store.note_delivery(self.home, delivery_id=did,
                                             outcome="shown", channel="browser",
                                             event_id=eid, owner_scope="me",
                                             device_id="dev", show_token="tok"),
                         "claimed")
        self.assertEqual(store.delivery_state(self.home, eid, "initial", "ntfy"),
                         "enqueued",
                         "a browser show never rewrites the ntfy row")
        self.assertIsNone(store.note_delivery(self.home, delivery_id=did,
                                              outcome="shown", channel="ntfy"))


class ConcurrentClaimRaceTests(unittest.TestCase):
    """Exact-one show grant under a real barrier race — both across browser
    devices and against the ntfy producer."""

    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="notif2-b1r-"))
        store.reset()
        events.set_capability(True)

    def tearDown(self):
        events.set_capability(False)
        store.close_all()

    def test_eight_browser_devices_one_grant(self):
        eid, _ = store.record_event(self.home, owner_scope="me", run_id="r",
                                    sid="s", kind="completed",
                                    source_id="terminal", payload={})
        n = 8
        gate = threading.Barrier(n)
        won = []

        def claim(i):
            gate.wait()
            verdict, _ = store.claim_delivery(self.home, event_id=eid,
                                              phase="initial", channel="browser",
                                              delivery_id=f"d{i}", device_id=f"dev{i}")
            if verdict == "claimed":
                won.append(i)

        threads = [threading.Thread(target=claim, args=(i,)) for i in range(n)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(len(won), 1, "exactly ONE device alerts")

    def test_browser_and_ntfy_races_each_other_both_deliver(self):
        reg = events.open_ledger({}, home_resolver=lambda: self.home,
                                 settings=lambda: NTFY)
        events.set_capability(True)
        eid, _ = store.record_event(self.home, owner_scope="me", run_id="r9",
                                    sid="s", kind="completed",
                                    source_id="terminal", payload={})
        gate = threading.Barrier(2)
        results = {}

        def browser():
            gate.wait()
            verdict, _ = store.claim_delivery(self.home, event_id=eid,
                                              phase="initial", channel="browser",
                                              delivery_id="d-b", device_id="dev")
            results["browser"] = verdict

        def ntfy():
            gate.wait()
            verdict, _ = store.claim_delivery(self.home, event_id=eid,
                                              phase="initial", channel="ntfy",
                                              delivery_id="d-n", device_id="server")
            results["ntfy"] = verdict

        threads = [threading.Thread(target=browser), threading.Thread(target=ntfy)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(results, {"browser": "claimed", "ntfy": "claimed"},
                         "the two surfaces are independent claims")
        store.close_all()


if __name__ == "__main__":
    unittest.main()
