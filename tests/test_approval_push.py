#!/usr/bin/env python3
"""APPROVALPUSH B2 contract tests: immediate dispatcher, reminder lifecycle,
Unicode titles, enqueue observability (P1-P5). Fake ntfy, fake clock, fixture
entries; no network, no real hub, no config writes."""
import json
import pathlib
import sys
import threading
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "compat"))
AGENT = pathlib.Path.home() / ".hermes" / "hermes-agent"
if str(AGENT) not in sys.path:
    sys.path.insert(0, str(AGENT))

import approval_push  # noqa: E402
from approval_inbox import ApprovalInbox, entry_from_data  # noqa: E402


class FakeNtfy:
    """Records published messages; supports forced failure/full-queue modes."""

    def __init__(self, accept=True, results=None):
        self.posts = []
        self.accept = accept
        self.results = results  # optional list to pop per publish

    def publish_json(self, server, topic, title, message, *, priority="high",
                     tags=None, on_result=None):
        if not self.accept:
            return False
        safe_tags = ["hermes-agent"] + [t for t in (tags or []) if t != "hermes-agent"]
        self.posts.append({"server": server, "topic": topic, "title": title,
                           "message": message, "priority": priority, "tags": safe_tags})
        if on_result is not None:
            ok = self.results.pop(0) if self.results else True
            on_result(ok, "URLError" if not ok else None)
        return True


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t

    def advance(self, dt):
        self.t += dt


class TimerHub:
    """Stand-in for threading.Timer: collected, run manually by the test."""

    def __init__(self, clock):
        self.clock = clock
        self.timers = []
        self.cancelled = 0

    def timer(self, delay, fn):
        self.timers.append({"due": self.clock() + delay, "fn": fn, "cancelled": False})
        t = self.timers[-1]

        class T:
            def cancel(_self):
                t["cancelled"] = True
        return T()

    def fire_due(self):
        for t in self.timers:
            if not t["cancelled"] and t["due"] <= self.clock() and not t.get("fired"):
                t["fired"] = True
                t["fn"]()


def make_env(T=300):
    clock = Clock()
    ntfy = FakeNtfy()
    hub = TimerHub(clock)
    state = {"activity_epoch": "ep1", "approval_queues": {}}
    inbox = ApprovalInbox.open(state)
    queue_state = {"ids": set()}  # core-queue stand-in for fire validation
    disp = approval_push.attach(inbox, ntfy=ntfy, clock=clock, timers=hub.timer,
                                settings=lambda: {"server": "http://hub", "topic": "tp",
                                                  "locale": "zh-TW"},
                                queue_ids=lambda entry: queue_state["ids"],
                                timeout=lambda: T, status_ok=lambda e: True)
    return inbox, ntfy, hub, clock, queue_state, disp


def entry_for(inbox, rid="r1", command="rm -rf /tmp/zz", **kw):
    data = {"request_id": rid, "command": command, "description": "刪除根目錄附近檔案",
            "pattern_key": "delete in root path", "pattern_keys": ["delete in root path"]}
    return entry_from_data(data, server_epoch=inbox["epoch"], run_id="run_abc123456789",
                           session_id="s1", session_key="sk", timeout=kw.pop("timeout", 300),
                           now_mono=kw.pop("now_mono", 1000.0))


class ImmediateCase(unittest.TestCase):
    def test_initial_is_published_once_per_request(self):
        inbox, ntfy, hub, clock, q, disp = make_env()
        e = entry_for(inbox)
        disp(e)
        disp(e)  # duplicate capture/status replay must not re-push
        self.assertEqual(len(ntfy.posts), 1)
        self.assertEqual(e["pushed"]["initial"], True)

    def test_new_request_id_is_not_deduped_by_the_old_one(self):
        inbox, ntfy, hub, clock, q, disp = make_env()
        a, b = entry_for(inbox, rid="rA"), entry_for(inbox, rid="rB")
        disp(a)
        disp(b)
        self.assertEqual(len(ntfy.posts), 2)

    def test_priority_high_and_echo_tag(self):
        inbox, ntfy, hub, clock, q, disp = make_env()
        disp(entry_for(inbox))
        post = ntfy.posts[0]
        self.assertEqual(post["priority"], "high")
        self.assertIn("hermes-agent", post["tags"])

    def test_unicode_title_survives(self):
        inbox, ntfy, hub, clock, q, disp = make_env()
        e = entry_for(inbox, command="rm -rf /tmp/深層🔥目錄")
        disp(e)
        title = ntfy.posts[0]["title"]
        self.assertIn("Hermes", title)
        self.assertIn("待核准", title)  # zh-TW template rides the JSON Unicode title
        self.assertTrue(any(ord(c) > 127 for c in title),
                        f"Unicode summary must ride the JSON title: {title!r}")

    def test_body_has_summary_choices_seconds_and_no_secret(self):
        inbox, ntfy, hub, clock, q, disp = make_env()
        e = entry_for(inbox, command="aws s3 rm --profile token=abc123 /tmp/x")
        disp(e)
        body = ntfy.posts[0]["message"]
        self.assertIn("刪除根目錄附近檔案", body)
        self.assertIn("約剩", body)
        self.assertIn("允許一次", body)
        self.assertIn("拒絕", body)
        self.assertNotIn("abc123", body)
        self.assertNotIn("tp", ntfy.posts[0]["message"] + title_of(ntfy.posts[0]))

    def test_unconfigured_push_counts_drop_not_crash(self):
        clock = Clock()
        ntfy = FakeNtfy()
        state = {"activity_epoch": "ep1", "approval_queues": {}}
        inbox = ApprovalInbox.open(state)
        disp = approval_push.attach(inbox, ntfy=ntfy, clock=clock,
                                    timers=lambda d, f: None,
                                    settings=lambda: None,
                                    queue_ids=lambda e: set(),
                                    timeout=lambda: 300, status_ok=lambda e: True)
        e = entry_for(inbox)
        disp(e)  # must not raise
        self.assertEqual(ntfy.posts, [])
        self.assertEqual(inbox["metrics"]["push_dropped"], 1)

    def test_queue_full_marks_drop_and_keeps_approval_alive(self):
        inbox, ntfy, hub, clock, q, disp = make_env()
        ntfy.accept = False  # bounded queue full
        e = entry_for(inbox)
        disp(e)
        self.assertEqual(inbox["metrics"]["push_dropped"], 1)
        self.assertEqual(inbox["metrics"].get("push_enqueued", 0), 0)

    def test_send_failure_recorded_sanitized(self):
        inbox, ntfy, hub, clock, q, disp = make_env()
        ntfy.results = [False]
        e = entry_for(inbox)
        disp(e)
        self.assertEqual(inbox["metrics"]["send_fail"], 1)
        self.assertEqual(inbox["metrics"].get("send_fail_last"), "URLError")
        self.assertTrue(all("tp" not in str(v) for v in inbox["metrics"].values()))


class ReminderCase(unittest.TestCase):
    def test_formula_T300_fires_at_240(self):
        self.assertAlmostEqual(approval_push.reminder_delay(300), 240.0)

    def test_formula_T30_fires_at_15(self):
        self.assertAlmostEqual(approval_push.reminder_delay(270), 210.0)
        self.assertAlmostEqual(approval_push.reminder_delay(30), 15.0)

    def test_nonpositive_timeout_never_notifies_still_approvable(self):
        self.assertIsNone(approval_push.reminder_delay(0))
        self.assertIsNone(approval_push.reminder_delay(-5))

    def test_short_T_reminder_requires_one_second_left(self):
        inbox, ntfy, hub, clock, q, disp = make_env(T=1)
        e = entry_for(inbox, timeout=1)
        q["ids"] = {"r1"}
        disp(e)
        hub.fire_due()  # reminder due ~0.5s
        clock.advance(0.6)
        hub.fire_due()
        n_before = len(ntfy.posts)
        clock.advance(0.6)  # now beyond the deadline: never "still approvable"
        hub.fire_due()
        self.assertEqual(len(ntfy.posts), n_before)

    def test_reminder_once_and_title_switches(self):
        inbox, ntfy, hub, clock, q, disp = make_env()
        e = entry_for(inbox)
        q["ids"] = {"r1"}
        disp(e)
        clock.advance(240)
        hub.fire_due()
        hub.fire_due()  # timer already consumed
        reminders = [p for p in ntfy.posts if "expiring" in p["title"] or "即將逾時" in p["title"]]
        self.assertEqual(len(reminders), 1)
        self.assertEqual(e["pushed"]["reminder"], True)

    def test_settled_before_reminder_kills_the_timer(self):
        inbox, ntfy, hub, clock, q, disp = make_env()
        e = entry_for(inbox)
        q["ids"] = {"r1"}
        disp(e)
        e["phase"] = "resolved"
        clock.advance(240)
        hub.fire_due()
        self.assertEqual(len(ntfy.posts), 1)  # no reminder for a settled card

    def test_fire_revalidates_queue_membership(self):
        inbox, ntfy, hub, clock, q, disp = make_env()
        e = entry_for(inbox)
        q["ids"] = {"r1"}
        disp(e)
        q["ids"] = set()  # core settled without our hook seeing it yet
        clock.advance(240)
        hub.fire_due()
        self.assertEqual(len(ntfy.posts), 1)

    def test_fire_skips_when_run_terminal(self):
        inbox, ntfy, hub, clock, q, disp = make_env()
        e = entry_for(inbox)
        q["ids"] = {"r1"}
        disp(e)
        inbox["_test_terminal"] = True
        disp_status = approval_push.attach(inbox, ntfy=ntfy, clock=clock,
                                           timers=hub.timer,
                                           settings=lambda: {"server": "http://hub",
                                                             "topic": "tp", "locale": "en"},
                                           queue_ids=lambda entry: q["ids"],
                                           timeout=lambda: 300,
                                           status_ok=lambda ent: not inbox.get("_test_terminal"))
        e2 = entry_for(inbox, rid="r2")
        disp_status(e2)
        q["ids"] = {"r2"}
        clock.advance(1)
        hub.timers[-1]["fn"]()
        self.assertEqual([p for p in ntfy.posts if "expiring" in p["title"]], [])


class ContentCase(unittest.TestCase):
    def test_long_body_capped_at_1900_bytes_keeping_seconds_and_choices(self):
        inbox, ntfy, hub, clock, q, disp = make_env()
        e = entry_for(inbox)
        e["payload"]["description"] = "長" * 3000
        disp(e)
        body = ntfy.posts[0]["message"]
        self.assertLessEqual(len(body.encode("utf-8")), 1900)
        self.assertIn("約剩", body)
        self.assertIn("拒絕", body)

    def test_en_locale_labels(self):
        clock = Clock()
        ntfy = FakeNtfy()
        state = {"activity_epoch": "ep1", "approval_queues": {}}
        inbox = ApprovalInbox.open(state)
        disp = approval_push.attach(inbox, ntfy=ntfy, clock=clock,
                                    timers=lambda d, f: None,
                                    settings=lambda: {"server": "s", "topic": "t",
                                                      "locale": "en"},
                                    queue_ids=lambda e: set(), timeout=lambda: 300,
                                    status_ok=lambda e: True)
        e = entry_for(inbox)
        e["payload"]["choices"] = ["once", "session", "deny"]
        disp(e)
        body = ntfy.posts[0]["message"]
        self.assertIn("Allow once", body)
        self.assertIn("Deny", body)

    def test_newlines_never_split_the_ntfy_body_lines(self):
        inbox, ntfy, hub, clock, q, disp = make_env()
        e = entry_for(inbox)
        e["payload"]["description"] = "第一行\n第二行\r第三行"
        disp(e)
        body = ntfy.posts[0]["message"]
        self.assertNotIn("\r", body)
        self.assertLessEqual(body.count("\n"), 6)

    def test_unknown_locale_falls_back_to_default(self):
        self.assertEqual(approval_push.normalize_locale("klingon"), "zh-TW")
        self.assertEqual(approval_push.normalize_locale("en"), "en")


def title_of(post):
    return post["title"]


if __name__ == "__main__":
    unittest.main(verbosity=2)
