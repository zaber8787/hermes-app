#!/usr/bin/env python3
"""01412FIX F1: the delivery report transaction verifies EVERYTHING (M1),
one honest outcome enum with enqueue != sent (m1), and summaries cross the
approval redaction seam under a byte cap (m2).

The route bodies are AST-extracted UNMODIFIED from compat/compat.py (the
01412 audit's route_repro shape) and executed against a real SQLite ledger;
only auth/HTTP shells are fixtures. Red at 01412 audit HEAD, green after F1.
"""
import ast
import asyncio
import json
import pathlib
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from types import SimpleNamespace

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "compat"))
sys.path.insert(0, str(ROOT))

import notification_events as events  # noqa: E402
import notification_store as store  # noqa: E402


def _routes(*names):
    """AST-extract the real handler bodies (no product edits, no monkeypatch)."""
    tree = ast.parse((ROOT / "compat" / "compat.py").read_text())
    installer = next(n for n in tree.body if isinstance(n, ast.FunctionDef)
                     and n.name == "_install_notification_events")
    wanted = {"delivery_post": "_handle_notification_delivery",
              "claim_post": "_handle_notification_claim"}.items()
    out = {}
    for func, attr in wanted:
        if func in names or attr in names:
            node = next(n for n in installer.body
                        if isinstance(n, ast.AsyncFunctionDef) and n.name == func)
            out[func] = compile(ast.Module(body=[node], type_ignores=[]),
                                "compat/compat.py", "exec")
    return out


def _env(home, scope):
    reg = events.open_ledger({}, home_resolver=lambda: home, settings=lambda: None)

    async def synchronous_to_thread(func, *a, **kw):
        return func(*a, **kw)

    ns = dict(enabled=lambda: True,
              _owner=lambda adapter, request: scope,
              api=SimpleNamespace(
                  uuid=uuid,
                  web=SimpleNamespace(json_response=lambda data, **kw: data),
                  _error_response=lambda message, status, **kw: {"http": status, **kw}),
              notification_store=store, notification_events=events, reg=reg,
              asyncio=SimpleNamespace(to_thread=synchronous_to_thread))
    for name, code in _routes("delivery_post", "claim_post").items():
        exec(code, ns)
    return ns


class Request:
    def __init__(self, event_id, body):
        self.match_info = {"event_id": event_id}
        self._body = body

    async def json(self):
        return self._body


class DeliveryTransactionTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="fix01412-f1-"))
        store.reset()

    def tearDown(self):
        store.close_all()

    def _victim_claimed(self, home):
        eid, _ = store.record_event(home, owner_scope="victim", run_id="r", sid="s",
                                    kind="completed", source_id="terminal", payload={})
        verdict, did = store.claim_delivery(home, event_id=eid, phase="initial",
                                            channel="browser",
                                            delivery_id="victim-delivery",
                                            device_id="victim-device",
                                            show_token="durable-token-1")
        self.assertEqual(verdict, "claimed")
        return eid

    def test_foreign_owner_cannot_flip_a_delivery(self):
        """M1 red: the attacker route must NOT touch the victim's row."""
        eid = self._victim_claimed(self.home)
        attacker = _env(self.home, "attacker")
        response = asyncio.run(attacker["delivery_post"](
            None, Request("unrelated-or-nonexistent-event",
                          {"delivery_id": "victim-delivery", "outcome": "failed",
                           "device_id": "attacker-device",
                           "show_token": "invalid-token"})))
        self.assertEqual(response.get("http"), 404,
                         f"cross-owner delivery report must 404, got {response}")
        self.assertEqual(store.delivery_state(self.home, eid, "initial", "browser"),
                         "claimed", "victim delivery state must be untouched")

    def test_event_mismatch_is_rejected_even_for_the_owner(self):
        eid = self._victim_claimed(self.home)
        victim = _env(self.home, "victim")
        response = asyncio.run(victim["delivery_post"](
            None, Request("some-other-event",
                          {"delivery_id": "victim-delivery", "outcome": "shown",
                           "device_id": "victim-device", "show_token": "whatever"})))
        self.assertEqual(response.get("http"), 404)
        self.assertEqual(store.delivery_state(self.home, eid, "initial", "browser"),
                         "claimed")

    def test_show_token_is_durable_and_required(self):
        """The claim grants a PERSISTENT token; a report without the exact
        token is rejected, the report with it is accepted (claim-owner proof)."""
        eid = self._victim_claimed(self.home)
        store.reset()  # reopen: the token must survive from the durable row
        victim = _env(self.home, "victim")
        wrong = asyncio.run(victim["delivery_post"](
            None, Request(eid, {"delivery_id": "victim-delivery", "outcome": "shown",
                                "device_id": "victim-device",
                                "show_token": "guessed"})))
        self.assertEqual(wrong.get("http"), 404,
                         "a guessed token must never finalize a delivery")
        token = store.show_token_for(self.home, "victim-delivery")
        self.assertEqual(token, "durable-token-1",
                         "claim must persist the durable show_token")
        ok = asyncio.run(victim["delivery_post"](
            None, Request(eid, {"delivery_id": "victim-delivery", "outcome": "shown",
                                "device_id": "victim-device", "show_token": token})))
        self.assertNotIn("http", ok, f"valid report must succeed, got {ok}")
        self.assertEqual(store.delivery_state(self.home, eid, "initial", "browser"),
                         "shown")

    def test_claim_post_grants_one_durable_token(self):
        eid, _ = store.record_event(self.home, owner_scope="victim", run_id="r2",
                                    sid="s", kind="failed", source_id="terminal",
                                    payload={})
        victim = _env(self.home, "victim")
        first = asyncio.run(victim["claim_post"](
            None, Request(eid, {"device_id": "dev-A", "delivery_id": "d-1"})))
        self.assertEqual(first["verdict"], "claimed")
        self.assertTrue(first["show_token"])
        second = asyncio.run(victim["claim_post"](
            None, Request(eid, {"device_id": "dev-B", "delivery_id": "d-2"})))
        self.assertEqual(second["verdict"], "already_claimed")
        self.assertIsNone(second["show_token"])
        self.assertEqual(store.show_token_for(self.home, first["delivery_id"]),
                         first["show_token"],
                         "the token the claim returned is the durable one")
        late = asyncio.run(victim["delivery_post"](
            None, Request(eid, {"delivery_id": first["delivery_id"],
                                "outcome": "shown", "device_id": "dev-A",
                                "show_token": "stolen"})))
        self.assertEqual(late.get("http"), 404)

    def test_outcome_enum_is_unified_and_enqueue_is_not_sent(self):
        """m1: an enqueue records 'enqueued'; the store accepts the ONE enum,
        so a proven send finally leaves 'claimed'."""
        self.assertTrue({"enqueued", "sent", "shown", "failed", "unknown"}
                        <= set(store.OUTCOME_STATES))
        reg = events.open_ledger({}, home_resolver=lambda: self.home,
                                 settings=lambda: None)
        events.set_capability(True)
        try:
            published = []
            eid, outcome = events.deliver(
                reg, owner_scope="o", run_id="enqueue-run", sid="s",
                kind="completed", source_id="terminal", payload={},
                channel="ntfy", publish=lambda: published.append(1) or True)
            self.assertEqual(published, [1], "publish is called exactly once")
            states = {phase: (chan, st) for phase, chan, st
                      in store.sent_phases(self.home, eid)}
            self.assertEqual(states["initial"], ("ntfy", "enqueued"),
                             f"an enqueue is never a send: {states}")
            self.assertIn(outcome, ("enqueued", "already_enqueued"))
        finally:
            events.set_capability(False)
        # the store no longer silently drops 'sent'/'enqueued' reports
        store.new_delivery(self.home, event_id="e-x", phase="initial",
                           channel="ntfy", delivery_id="d-x")
        store.note_delivery(self.home, delivery_id="d-x", outcome="enqueued",
                            channel="ntfy")
        self.assertEqual(store.delivery_state(self.home, "e-x", "initial", "ntfy"),
                         "enqueued")
        store.note_delivery(self.home, delivery_id="d-x", outcome="nonsense",
                            channel="ntfy")
        self.assertEqual(store.delivery_state(self.home, "e-x", "initial", "ntfy"),
                         "enqueued", "an unknown outcome never rewrites state")

    def test_terminal_summary_crosses_the_redaction_seam(self):
        """m2: the stored summary is whitelist-redacted like approvals and
        byte-capped (UTF-8, no split code point)."""
        reg = events.open_ledger({}, home_resolver=lambda: self.home,
                                 settings=lambda: None)
        events.set_capability(True)
        try:
            secret = "exit 1; api_key=SU5zZWNyZXQ= password=p@ss token=tok_42"
            events.terminal_event(reg, owner_scope="o", run_id="redact-1", sid="s",
                                  status="completed", summary=secret)
            eid = store.event_id_for("o", "redact-1", "completed", "terminal")
            stored = store.get_event(self.home, "o", eid)["payload"]["summary"]
            for marker in ("SU5zZWNyZXQ=", "p@ss", "tok_42"):
                self.assertNotIn(marker, stored, f"secret leaked: {marker}")
            long = "漢" * 400  # 3 bytes each
            events.terminal_event(reg, owner_scope="o", run_id="redact-2", sid="s",
                                  status="failed", summary=long)
            eid2 = store.event_id_for("o", "redact-2", "failed", "terminal")
            stored2 = store.get_event(self.home, "o", eid2)["payload"]["summary"]
            self.assertLessEqual(len(stored2.encode("utf-8")), 240)
            stored2.encode("utf-8").decode("utf-8")  # never splits a code point
        finally:
            events.set_capability(False)


if __name__ == "__main__":
    unittest.main()
