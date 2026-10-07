#!/usr/bin/env python3
"""01412FIX F6: the steer lifecycle contract (M7-M10), asserted in the
audit's own shapes — AST-extracted UNMODIFIED route handlers, real SQLite
sidecar, fixture adapters. Red at the audit HEAD (spec/repro-output.txt),
green after F6."""
import ast
import asyncio
import json
import pathlib
import sys
import tempfile
import types
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "compat"))
sys.path.insert(0, str(ROOT))
AGENT = pathlib.Path.home() / ".hermes" / "hermes-agent"

from compat import steer_inbox, steer_store  # noqa: E402


async def _inline(fn, *a, **kw):
    return fn(*a, **kw)


class Adapter:
    def __init__(self):
        self._run_statuses = {"race": {"status": "running", "session_id": "sid"}}
        self._active_run_agents = {"race": object()}
        self._active_run_tasks = {}
        self._run_owners = {"race": "audit-owner"}

    def _check_auth(self, request):
        return None

    def _request_owns_run(self, request, rid):
        return True

    def _durable_run_status(self, request, rid):
        return self._run_statuses.get(rid)

    def _run_idempotency_scope(self, request):
        return "audit-owner"


class Request:
    headers = {}
    query = {}

    def __init__(self, adapter, rid, body=None, unregister=False):
        self.match_info = {"run_id": rid}
        self.adapter = adapter
        self.body = body
        self.unregister = unregister

    async def read(self):
        if self.unregister:
            self.adapter._active_run_agents.pop("race")
        return json.dumps(self.body).encode()


class SteerLifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not (AGENT / "gateway" / "platforms" / "api_server_runs.py").exists():
            raise unittest.SkipTest("CORE checkout not available")

    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="fix01412-f6-"))
        steer_store.reset()
        steer_inbox.set_capability(True)
        state = {"activity_epoch": "audit-epoch"}
        self.inbox = steer_inbox.open_inbox(state, home_resolver=lambda: self.home)
        api = types.SimpleNamespace(uuid=uuid, _openai_error=None,
                                    _error_response=lambda message, status, **kw: {
                                        "http": status, "error": {"code": kw.get("code")}},
                                    web=types.SimpleNamespace(
                                        json_response=lambda body, **kw: {"http": 200, **body}))
        native_ns = {"Optional": object,
                     "_run_not_found": lambda err, rid: {"http": 404, "run_id": rid}}
        tree = ast.parse((AGENT / "gateway" / "platforms" /
                          "api_server_runs.py").read_text())
        node = next(n for n in tree.body if isinstance(n, ast.FunctionDef)
                    and n.name == "_load_owned_run")
        for arg in node.args.args + node.args.kwonlyargs:
            arg.annotation = None
        exec(compile(ast.Module(body=[node], type_ignores=[]), "<native-owned>", "exec"),
             native_ns)
        runs = types.SimpleNamespace(_load_owned_run=native_ns["_load_owned_run"])
        compat_tree = ast.parse((ROOT / "compat" / "compat.py").read_text())
        installer = next(n for n in compat_tree.body if isinstance(n, ast.FunctionDef)
                         and n.name == "_install_steer_inbox")
        self.ns = dict(sys=sys, asyncio=types.SimpleNamespace(to_thread=_inline),
                       api=api, runs=runs, json=json, enabled=lambda: True,
                       inbox=self.inbox, steer_inbox=steer_inbox,
                       STEER_BODY_CAP=65536, STEER_INPUT_CAP=8192)
        for name in ("steer", "_owned", "receipt_get", "steers_get"):
            node = next(n for n in installer.body
                        if isinstance(n, ast.AsyncFunctionDef) and n.name == name)
            exec(compile(ast.Module(body=[node], type_ignores=[]), "compat/compat.py",
                         "exec"), self.ns)
        self.api = api
        self._patcher = patch.dict(sys.modules, {"gateway.platforms.api_server": api})
        self._patcher.start()
        self.addCleanup(self._patcher.stop)

    def tearDown(self):
        steer_inbox.set_capability(False)
        steer_store.close_all()

    def test_M9_unregister_during_body_cannot_be_admitted(self):
        adapter = Adapter()
        request = Request(adapter, "race",
                          {"input": "audit text",
                           "client_request_id": uuid.uuid4().hex}, True)
        result = asyncio.run(self.ns["steer"](adapter, request, _api_server=self.api))
        self.assertEqual(len(adapter._active_run_agents), 0)
        self.assertNotEqual(result.get("http"), 200,
                            f"M9 red: unbound agent must not accept: {result}")
        self.assertEqual(result["error"]["code"], "run_not_ready")

    def test_M9_stale_snapshot_fallback_is_gone(self):
        """Even WITHOUT the read-time unregister, the guard re-verifies the
        LIVE binding: an adapter whose agent map lost the run refuses."""
        adapter = Adapter()
        agent_before = adapter._active_run_agents["race"]

        class LateUnbind(dict):
            """Goes stale AFTER steer() snapshots it: _load_owned_run and the
            post-await re-read see the agent; the guard's own re-read must
            not trust that snapshot."""
            def __init__(self, *a):
                super().__init__(*a)
                self.hits = 0

            def get(self, key, *default):
                value = super().get(key, *default)
                if key == "race" and value is not None:
                    self.hits += 1
                    if self.hits > 2:
                        return None
                return value
        adapter._active_run_agents = LateUnbind(adapter._active_run_agents)
        request = Request(adapter, "race",
                          {"input": "x", "client_request_id": uuid.uuid4().hex})
        result = asyncio.run(self.ns["steer"](adapter, request,
                                              _api_server=self.api))
        self.assertIsNotNone(agent_before)
        self.assertEqual(result.get("http"), 409,
                         f"guard-time liveness must veto the stale snapshot: {result}")
        self.assertEqual(result["error"]["code"], "run_not_ready")

    def test_M7_expired_native_status_still_answers_from_the_sidecar(self):
        adapter = Adapter()
        request = Request(adapter, "race",
                          {"input": "durable", "client_request_id": uuid.uuid4().hex})
        result = asyncio.run(self.ns["steer"](adapter, request, _api_server=self.api))
        self.assertEqual(result.get("http"), 200)
        # native TTL expiry: status AND the in-process binding are both gone
        adapter._run_statuses.clear()
        adapter._active_run_agents.clear()
        request.match_info["steer_id"] = result["steer_id"]
        receipt = asyncio.run(self.ns["receipt_get"](adapter, request))
        self.assertEqual(receipt.get("http"), 200,
                         f"M7 red: durable receipt must answer: {receipt}")
        listing = asyncio.run(self.ns["steers_get"](adapter, request))
        self.assertEqual(listing.get("http"), 200)
        self.assertFalse(listing["accepting"])
        self.assertEqual(listing["accepting_reason"], "run_expired")

    def test_M7_foreign_or_absent_durable_stays_404(self):
        adapter = Adapter()
        adapter._run_statuses.clear()
        adapter._active_run_agents.clear()
        request = Request(adapter, "race", None)
        listing = asyncio.run(self.ns["steers_get"](adapter, request))
        self.assertEqual(listing.get("http"), 404,
                         "no durable row for this owner -> native 404 stands")

    def test_M10_runtime_disabled_refuses_without_native_bypass(self):
        native_calls = []

        async def old_post(*args, **kwargs):
            native_calls.append(1)
            return {"http": 200, "accepted": True, "native_called": True}
        self.ns["enabled"] = lambda: False
        self.ns["old_post"] = old_post
        adapter = Adapter()
        request = Request(adapter, "race", {"input": "off", "client_request_id": "k"})
        result = asyncio.run(self.ns["steer"](adapter, request, _api_server=self.api))
        self.assertEqual(result.get("http"), 503)
        self.assertEqual(result["error"]["code"], "steer_disabled")
        self.assertEqual(native_calls, [],
                         "M10 red: runtime-off must NEVER post to native")
        # existing receipts stay readable with the switch off
        self.ns["enabled"] = lambda: True
        request = Request(adapter, "race",
                          {"input": "one", "client_request_id": "k-on"})
        accepted = asyncio.run(self.ns["steer"](adapter, request, _api_server=self.api))
        self.ns["enabled"] = lambda: False
        request.match_info["steer_id"] = accepted["steer_id"]
        receipt = asyncio.run(self.ns["receipt_get"](adapter, request))
        self.assertEqual(receipt.get("http"), 200,
                         "kill switch never hides the durable ledger")

    def test_M8_start_recovery_retires_dead_accepted(self):
        """An accepted row whose run has NO live binding in this process is
        sealed to not_delivered — never replayed, never left fake-queued."""
        store = steer_store.open_store(self.home)
        steer_store.register_run(store, "o1", "old-run", owner_epoch="epoch-before")
        verdict, row = steer_store.admit(store, "o1", "old-run", key="k1",
                                         input_text="queued forever?")
        self.assertEqual(verdict, "admitted")
        repaired = steer_inbox.recover(self.inbox)
        after = steer_store.get_steer(store, "o1", "old-run", row["steer_id"])
        self.assertEqual(after["state"], "not_delivered",
                         f"M8 red: {after['state']} — accepted of a dead process "
                         f"must be retired at startup")
        self.assertGreaterEqual(repaired["retired"], 1)
        run = steer_store.get_run(store, "o1", "old-run")
        self.assertIsNotNone(run["closed_reason"], "the stale run gets sealed")
        # and a LATER identical retry answers as the durable duplicate...
        verdict2, _ = steer_store.admit(store, "o1", "old-run", key="k1",
                                        input_text="queued forever?")
        self.assertEqual(verdict2, "duplicate")
        # ...while NEW admission to the sealed run is refused (no replay)
        verdict3, _ = steer_store.admit(store, "o1", "old-run", key="k2",
                                        input_text="anything else")
        self.assertEqual(verdict3, "closed")


if __name__ == "__main__":
    unittest.main()
