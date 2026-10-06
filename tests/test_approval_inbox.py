#!/usr/bin/env python3
"""APPROVALPUSH B1 contract tests: approval request registry (compat/approval_inbox).

Fake clock, fake queue entries and fake adapters only; no real commands, no
network, no config writes. The real tools.approval module is imported so the
registry binds against the true queue/lock contract (R2)."""
import pathlib
import sys
import threading
import time
import types
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "compat"))
AGENT = pathlib.Path.home() / ".hermes" / "hermes-agent"
if str(AGENT) not in sys.path:
    sys.path.insert(0, str(AGENT))

from tools import approval as core_approval  # noqa: E402
from approval_inbox import (ApprovalInbox, capture, classify_answer,  # noqa: E402
                            DEFAULT_TIMEOUT, entry_from_data, payload_for, settle,
                            snapshot, INBOX_MAX_PENDING)


class FakeEntry:
    """Duck-typed core _ApprovalEntry (data/settle only, like the core reads)."""

    def __init__(self, data):
        self.data = dict(data)
        self.settle = None
        self.result = None


class FakeAdapter:
    def __init__(self, session_key):
        self._run_approval_sessions = {"run_x": session_key}
        self._run_statuses = {}
        self._run_streams = {}


def new_inbox():
    state = {"activity_epoch": "epoch-abc", "approval_queues": {}}
    return ApprovalInbox.open(state)


def core_queue(session_key, entries):
    with core_approval._lock:
        core_approval._gateway_queues[session_key] = list(entries)


def clear_core(session_key):
    with core_approval._lock:
        core_approval._gateway_queues.pop(session_key, None)


def data(request_id, command="rm -rf /tmp/zz-never", keys=("rm -rf",), **extra):
    entry = {"request_id": request_id, "command": command,
             "description": "dangerous delete", "pattern_key": keys[0],
             "pattern_keys": list(keys), "allow_session": True,
             "allow_permanent": True}
    entry.update(extra)
    return entry


class CaptureCase(unittest.TestCase):
    def setUp(self):
        self.inbox = new_inbox()
        self.adapter = FakeAdapter("sk_cap")
        self.key = "sk_cap"
        clear_core(self.key)

    def tearDown(self):
        clear_core(self.key)

    def test_captures_native_request_id(self):
        # Root cause: without a registry the only cross-device truth is the
        # one-slot status.approval, which cannot represent a multi-entry queue.
        e1, e2 = FakeEntry(data("req-a")), FakeEntry(data("req-b"))
        core_queue(self.key, [e1, e2])
        cap1 = capture(self.inbox, adapter=self.adapter, run_id="run_x",
                       session_id="s1", loop=None, data=dict(e1.data))
        cap2 = capture(self.inbox, adapter=self.adapter, run_id="run_x",
                       session_id="s1", loop=None, data=dict(e2.data))
        self.assertIsNotNone(cap1)
        self.assertIsNotNone(cap2)
        pending, available, overflow, _rev = snapshot(
            self.inbox, adapter=self.adapter, run_id="run_x")
        self.assertTrue(available)
        self.assertEqual([p["request_id"] for p in pending], ["req-a", "req-b"])
        self.assertFalse(overflow)

    def test_settled_entry_produces_no_phantom_pending(self):
        # R2: queue already settled before publish must not publish fake pending.
        e1 = FakeEntry(data("req-gone"))
        capture(self.inbox, adapter=self.adapter, run_id="run_x",
                session_id="s1", loop=None, data=dict(e1.data))
        pending, _a, _o, _r = snapshot(self.inbox, adapter=self.adapter, run_id="run_x")
        self.assertEqual(pending, [])  # queue empty: reconcile drops the entry

    def test_settle_callback_is_chained_not_replaced(self):
        seen = []
        e1 = FakeEntry(data("req-chain"))
        e1.settle = lambda reason: seen.append(("native", reason))
        core_queue(self.key, [e1])
        capture(self.inbox, adapter=self.adapter, run_id="run_x",
                session_id="s1", loop=None, data=dict(e1.data))
        self.assertIsNotNone(e1.settle)
        e1.settle("timeout")
        self.assertIn(("native", "timeout"), seen)  # original surface preserved
        pending, _a, _o, _r = snapshot(self.inbox, adapter=self.adapter, run_id="run_x")
        self.assertEqual(pending, [])  # inbox settled with the wait

    def test_settle_reason_map_to_honest_outcomes(self):
        e1 = FakeEntry(data("req-out"))
        core_queue(self.key, [e1])
        capture(self.inbox, adapter=self.adapter, run_id="run_x",
                session_id="s1", loop=None, data=dict(e1.data))
        e1.settle("session_closed")
        entry = self.inbox["by_run"][(id(self.adapter), "run_x")]["entries"]["req-out"]
        self.assertEqual(entry["phase"], "resolved")
        self.assertEqual(entry["outcome"], "withdrawn")

    def test_payload_is_additive_and_never_carries_raw_command(self):
        raw = "aws s3 ls --profile secret-token=hunter2"
        e1 = FakeEntry(data("req-p", command=raw))
        core_queue(self.key, [e1])
        capture(self.inbox, adapter=self.adapter, run_id="run_x",
                session_id="s1", loop=None, data=dict(e1.data))
        pending, _a, _o, _r = snapshot(self.inbox, adapter=self.adapter, run_id="run_x")
        payload = pending[0]
        for field in ("request_id", "run_id", "session_id", "server_epoch", "choices",
                      "created_at", "expires_at", "remaining_seconds", "deadline_estimated",
                      "pattern_key", "pattern_keys"):
            self.assertIn(field, payload)
        self.assertTrue(payload["deadline_estimated"])
        self.assertEqual(payload["server_epoch"], "epoch-abc")
        self.assertNotIn("hunter2", payload["command"])

    def test_remaining_seconds_uses_monotonic_not_wall_clock(self):
        e1 = FakeEntry(data("req-m"))
        core_queue(self.key, [e1])
        entry = capture(self.inbox, adapter=self.adapter, run_id="run_x",
                        session_id="s1", loop=None, data=dict(e1.data))
        before = payload_for(entry, now_mono=time.monotonic())["remaining_seconds"]
        after = payload_for(entry, now_mono=time.monotonic() + 10)["remaining_seconds"]
        self.assertLessEqual(after, before)
        self.assertGreaterEqual(after, before - 11)

    def test_duplicate_capture_same_id_updates_never_duplicates(self):
        e1 = FakeEntry(data("req-d"))
        core_queue(self.key, [e1])
        for _ in range(3):  # duplicate status replay / reconnect producers
            capture(self.inbox, adapter=self.adapter, run_id="run_x",
                    session_id="s1", loop=None, data=dict(e1.data))
        pending, _a, _o, _r = snapshot(self.inbox, adapter=self.adapter, run_id="run_x")
        self.assertEqual(len(pending), 1)

    def test_overflow_reports_degraded_not_empty(self):
        entries = [FakeEntry(data(f"req-{i}")) for i in range(INBOX_MAX_PENDING + 4)]
        core_queue(self.key, entries)
        for entry in entries:
            capture(self.inbox, adapter=self.adapter, run_id="run_x",
                    session_id="s1", loop=None, data=dict(entry.data))
        pending, _a, overflow, _r = snapshot(self.inbox, adapter=self.adapter, run_id="run_x")
        self.assertTrue(overflow)
        self.assertLessEqual(len(pending), INBOX_MAX_PENDING)
        self.assertGreater(len(pending), 0)


class SnapshotTruthCase(unittest.TestCase):
    def setUp(self):
        self.inbox = new_inbox()
        self.adapter = FakeAdapter("sk_snap")
        self.key = "sk_snap"
        clear_core(self.key)

    def tearDown(self):
        clear_core(self.key)

    def test_queue_id_missing_from_registry_is_unavailable_not_empty(self):
        # R2/R3: an ID in the core queue the registry cannot uniquely map is
        # reported unavailable — never folded into pending=[] or a text hash.
        e1 = FakeEntry(data("req-known"))
        core_queue(self.key, [e1, FakeEntry(data("req-stranger"))])
        capture(self.inbox, adapter=self.adapter, run_id="run_x",
                session_id="s1", loop=None, data=dict(e1.data))
        pending, available, _o, _r = snapshot(self.inbox, adapter=self.adapter, run_id="run_x")
        self.assertFalse(available)
        self.assertEqual([p["request_id"] for p in pending], ["req-known"])

    def test_after_answer_one_other_pending_survives(self):
        e1, e2 = FakeEntry(data("req-1")), FakeEntry(data("req-2"))
        core_queue(self.key, [e1, e2])
        capture(self.inbox, adapter=self.adapter, run_id="run_x", session_id="s1",
                loop=None, data=dict(e1.data))
        capture(self.inbox, adapter=self.adapter, run_id="run_x", session_id="s1",
                loop=None, data=dict(e2.data))
        settle(self.inbox, self.adapter, "run_x", "req-1", "once")
        pending, available, _o, _r = snapshot(self.inbox, adapter=self.adapter, run_id="run_x")
        self.assertTrue(available)
        self.assertEqual([p["request_id"] for p in pending], ["req-2"])

    def test_settle_is_idempotent(self):
        e1 = FakeEntry(data("req-i"))
        core_queue(self.key, [e1])
        capture(self.inbox, adapter=self.adapter, run_id="run_x", session_id="s1",
                loop=None, data=dict(e1.data))
        settle(self.inbox, self.adapter, "run_x", "req-i", "once")
        settle(self.inbox, self.adapter, "run_x", "req-i", "deny")
        entry = self.inbox["by_run"][(id(self.adapter), "run_x")]["entries"]["req-i"]
        self.assertEqual(entry["outcome"], "once")  # first settlement wins

    def test_revision_monotonic_per_run(self):
        e1 = FakeEntry(data("req-r"))
        core_queue(self.key, [e1])
        capture(self.inbox, adapter=self.adapter, run_id="run_x", session_id="s1",
                loop=None, data=dict(e1.data))
        _p, _a, _o, rev1 = snapshot(self.inbox, adapter=self.adapter, run_id="run_x")
        settle(self.inbox, self.adapter, "run_x", "req-r", "deny")
        _p, _a, _o, rev2 = snapshot(self.inbox, adapter=self.adapter, run_id="run_x")
        self.assertGreater(rev2, rev1)


class AnswerRoutingCase(unittest.TestCase):
    """R3 exact-submit contract: legacy backfill, multi-pending 409, epoch."""

    def setUp(self):
        self.inbox = new_inbox()
        self.adapter = FakeAdapter("sk_post")
        self.key = "sk_post"
        clear_core(self.key)

    def tearDown(self):
        clear_core(self.key)

    def test_legacy_single_pending_backfills_exact_id(self):
        e1 = FakeEntry(data("req-only"))
        core_queue(self.key, [e1])
        capture(self.inbox, adapter=self.adapter, run_id="run_x", session_id="s1",
                loop=None, data=dict(e1.data))
        verdict = classify_answer(self.inbox, adapter=self.adapter, run_id="run_x",
                                  body={"choice": "once"}, epoch="epoch-abc")
        self.assertEqual(verdict["action"], "submit")
        self.assertEqual(verdict["request_id"], "req-only")  # never FIFO

    def test_legacy_two_pending_refuses_fifo(self):
        # Root cause: UI card B with queue oldest A used to answer A (FIFO).
        e1, e2 = FakeEntry(data("req-A")), FakeEntry(data("req-B"))
        core_queue(self.key, [e1, e2])
        verdict = classify_answer(self.inbox, adapter=self.adapter, run_id="run_x",
                                  body={"choice": "once"}, epoch="epoch-abc")
        self.assertEqual(verdict["action"], "error")
        self.assertEqual(verdict["status"], 409)
        self.assertEqual(verdict["code"], "approval_request_required")

    def test_exact_id_passthrough(self):
        e1, e2 = FakeEntry(data("req-A")), FakeEntry(data("req-B"))
        core_queue(self.key, [e1, e2])
        for entry in (e1, e2):
            capture(self.inbox, adapter=self.adapter, run_id="run_x", session_id="s1",
                    loop=None, data=dict(entry.data))
        verdict = classify_answer(self.inbox, adapter=self.adapter, run_id="run_x",
                                  body={"choice": "deny", "request_id": "req-B"},
                                  epoch="epoch-abc")
        self.assertEqual(verdict["action"], "submit")
        self.assertEqual(verdict["request_id"], "req-B")

    def test_exact_id_not_in_queue_lets_core_409(self):
        core_queue(self.key, [FakeEntry(data("req-live"))])
        verdict = classify_answer(self.inbox, adapter=self.adapter, run_id="run_x",
                                  body={"choice": "once", "request_id": "req-dead"},
                                  epoch="epoch-abc")
        self.assertEqual(verdict["action"], "passthrough")  # core answers 409

    def test_stale_epoch_is_409(self):
        e1 = FakeEntry(data("req-e"))
        core_queue(self.key, [e1])
        verdict = classify_answer(self.inbox, adapter=self.adapter, run_id="run_x",
                                  body={"choice": "once", "request_id": "req-e"},
                                  epoch="epoch-old")
        self.assertEqual(verdict["action"], "error")
        self.assertEqual(verdict["status"], 409)
        self.assertEqual(verdict["code"], "approval_epoch_stale")

    def test_choice_outside_snapshot_choices_rejected(self):
        e1 = FakeEntry(data("req-t", pattern_keys=["tirith:secret-leak"],
                           pattern_key="tirith:secret-leak", allow_permanent=False))
        core_queue(self.key, [e1])
        capture(self.inbox, adapter=self.adapter, run_id="run_x", session_id="s1",
                loop=None, data=dict(e1.data))
        verdict = classify_answer(self.inbox, adapter=self.adapter, run_id="run_x",
                                  body={"choice": "always", "request_id": "req-t"},
                                  epoch="epoch-abc")
        self.assertEqual(verdict["action"], "error")
        self.assertEqual(verdict["status"], 400)
        self.assertEqual(verdict["code"], "invalid_approval_choice")

    def test_smart_denied_snapshot_drops_session_and_always(self):
        e1 = FakeEntry(data("req-s", smart_denied=True))
        core_queue(self.key, [e1])
        capture(self.inbox, adapter=self.adapter, run_id="run_x", session_id="s1",
                loop=None, data=dict(e1.data))
        pending, _a, _o, _r = snapshot(self.inbox, adapter=self.adapter, run_id="run_x")
        self.assertEqual(pending[0]["choices"], ["once", "deny"])

    def test_tirith_only_snapshot_has_no_always(self):
        # §1.3 policy truth: a pure Tirith request never offers permanent.
        e1 = FakeEntry(data("req-x", allow_permanent=False))
        core_queue(self.key, [e1])
        capture(self.inbox, adapter=self.adapter, run_id="run_x", session_id="s1",
                loop=None, data=dict(e1.data))
        pending, _a, _o, _r = snapshot(self.inbox, adapter=self.adapter, run_id="run_x")
        self.assertNotIn("always", pending[0]["choices"])
        self.assertIn("session", pending[0]["choices"])

    def test_alias_choices_normalise_before_choice_check(self):
        e1 = FakeEntry(data("req-al", allow_permanent=False,
                            pattern_keys=["tirith:x"], pattern_key="tirith:x"))
        core_queue(self.key, [e1])
        capture(self.inbox, adapter=self.adapter, run_id="run_x", session_id="s1",
                loop=None, data=dict(e1.data))
        verdict = classify_answer(self.inbox, adapter=self.adapter, run_id="run_x",
                                  body={"choice": "approve", "request_id": "req-al"},
                                  epoch="epoch-abc")
        self.assertEqual(verdict["action"], "submit")
        self.assertEqual(verdict["choice"], "once")


class CapabilityCase(unittest.TestCase):
    def test_capability_default_on(self):
        # B4 shipped the capability ON; the kill switch stays available.
        import approval_inbox
        self.assertTrue(approval_inbox.capability_enabled(new_inbox()))

    def test_capability_requires_open_inbox(self):
        import approval_inbox
        inbox = new_inbox()
        approval_inbox.set_capability(True)
        try:
            self.assertTrue(approval_inbox.capability_enabled(inbox))
            inbox["closed"] = True
            self.assertFalse(approval_inbox.capability_enabled(inbox))
        finally:
            approval_inbox.set_capability(True)  # restore the shipped default
            inbox["closed"] = False


class DefaultsCase(unittest.TestCase):
    def test_timeout_read_from_core_config_not_hardcoded(self):
        self.assertEqual(DEFAULT_TIMEOUT(), 300)  # core default (approvals.timeout)

    def test_entry_from_data_never_keeps_raw_command(self):
        entry = entry_from_data(data("req-q", command="token=abc123 password=x"),
                                server_epoch="e", run_id="r", session_id="s",
                                session_key="k", timeout=300, now_mono=1000.0)
        self.assertNotIn("abc123", entry["payload"]["command"])
        self.assertNotIn("password", entry["payload"]["command"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
