#!/usr/bin/env python3
"""TASK-STEERAUTH: steer admission binds through the core's session authority.

On a core with a session authority (vnew, bf0203a794) every app turn runs in
the authority's durable FIFO, so a chat-stream run never appears in
_active_run_agents and the legacy binding closed every steer as
run_not_bound. These tests drive the UNMODIFIED compat POST steer route
(AST-extracted, same discipline as test_steer_lifecycle) over the REAL core
seams: run_admission resolves the chat-stream run id through the alias its
request holds, and SessionAuthority.check_approval_generation / steer_agent /
adopt_agent run as shipped. Only the authority's store and session handle are
fixtures. The /v1/runs legacy run keeps the _active_run_agents fallback.
"""
import ast
import asyncio
import contextlib
import json
import pathlib
import sqlite3
import sys
import tempfile
import threading
import types
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
AGENT = pathlib.Path.home() / ".hermes" / "hermes-agent"

from compat import steer_inbox, steer_store  # noqa: E402

SID = "api_session"
RUN = "run_chatstream"
ADMISSION = "adm-1"
GENERATION = 7


async def _inline(fn, *a, **kw):
    return fn(*a, **kw)


class Store:
    """The authority db surface run_admission reads (``_read_ctx``)."""

    def __init__(self):
        self.conn = sqlite3.connect(":memory:", check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute(
            "CREATE TABLE session_admissions (seq INTEGER PRIMARY KEY AUTOINCREMENT,"
            " admission_id TEXT NOT NULL UNIQUE, request_id TEXT NOT NULL,"
            " principal_id TEXT NOT NULL, target_session_id TEXT NOT NULL,"
            " lineage_json TEXT NOT NULL, payload_json TEXT NOT NULL,"
            " payload_digest TEXT NOT NULL, intent TEXT NOT NULL, status TEXT NOT NULL,"
            " outcome TEXT, owner_epoch INTEGER, generation INTEGER)")

    def add(self, admission_id, request_id, status, generation=None):
        self.conn.execute(
            "INSERT INTO session_admissions(admission_id, request_id, principal_id,"
            " target_session_id, lineage_json, payload_json, payload_digest, intent,"
            " status, owner_epoch, generation) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            (admission_id, request_id, "api", SID, "[]", "{}", "d", "queue", status,
             1 if generation is not None else None, generation))

    @contextlib.contextmanager
    def _read_ctx(self):
        yield self.conn


class Agent:
    def __init__(self):
        self.steered = []

    def steer(self, text):
        self.steered.append(text)
        return True


def _authority_class():
    from gateway.session_authority import SessionAuthority

    class Authority(SessionAuthority):
        """Real steer_agent / adopt_agent / check_approval_generation; the
        session handle and resident agent are fixtures."""

        def __init__(self, db):
            self.profile_id = "default"
            self.db = db
            self.adopted, self.pending_steers = {}, {}
            self.pending_stops, self.delivered_stops = {}, {}
            self.sessions = {SID: types.SimpleNamespace(
                event_stream=types.SimpleNamespace(lock=threading.Lock()),
                superseded=False, route="api:route")}
            self.generation, self.state = GENERATION, "running"

        def _handle(self, ref):
            return types.SimpleNamespace(execution_generation=self.generation,
                                         execution_state=self.state)

        def agent(self, ref):
            return None  # the previous turn's cached agent never counts here

        def _runs_own_agent(self, ref):
            return False
    return Authority


class Adapter:
    def __init__(self, authority):
        self.gateway_runner = types.SimpleNamespace(session_authority=authority)
        # What the vnew chat-stream leaves behind: status + owner, no agent.
        self._run_statuses = {RUN: {"status": "running", "session_id": SID}}
        self._active_run_agents = {}
        self._active_run_tasks = {}
        self._run_owners = {RUN: "owner"}
        self._stopping_run_ids = set()
        # run_api_turn binds the streaming run id to its admission.
        self._run_admission_aliases = {RUN: ADMISSION}

    def _check_auth(self, request):
        return None

    def _request_owns_run(self, request, rid):
        return True

    def _durable_run_status(self, request, rid):
        return self._run_statuses.get(rid)

    def _run_idempotency_scope(self, request):
        return "owner"


class Request:
    headers = {}
    query = {}

    def __init__(self, rid, body=None):
        self.match_info = {"run_id": rid}
        self.body = body

    async def read(self):
        return json.dumps(self.body).encode()


class AuthoritySteerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not (AGENT / "gateway" / "session_authority.py").exists():
            raise unittest.SkipTest("CORE checkout not available")

    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="steerauth-"))
        steer_store.reset()
        steer_inbox.set_capability(True)
        self.inbox = steer_inbox.open_inbox({"activity_epoch": "epoch"},
                                            home_resolver=lambda: self.home)
        api = types.SimpleNamespace(uuid=uuid, _openai_error=None,
                                    _error_response=lambda message, status, **kw: {
                                        "http": status, "error": {"code": kw.get("code")}},
                                    web=types.SimpleNamespace(
                                        json_response=lambda body, **kw: {"http": 200, **body}))
        native_ns = {"Optional": object,
                     "_run_not_found": lambda err, rid: {"http": 404, "run_id": rid}}
        tree = ast.parse((AGENT / "gateway" / "platforms" / "api_server_runs.py").read_text())
        node = next(n for n in tree.body if isinstance(n, ast.FunctionDef)
                    and n.name == "_load_owned_run")
        for arg in node.args.args + node.args.kwonlyargs:
            arg.annotation = None
        exec(compile(ast.Module(body=[node], type_ignores=[]), "<native-owned>", "exec"),
             native_ns)
        runs = types.SimpleNamespace(_load_owned_run=native_ns["_load_owned_run"])
        installer = next(n for n in ast.parse((ROOT / "compat" / "compat.py").read_text()).body
                         if isinstance(n, ast.FunctionDef) and n.name == "_install_steer_inbox")
        self.ns = dict(sys=sys, asyncio=types.SimpleNamespace(to_thread=_inline),
                       api=api, runs=runs, json=json, enabled=lambda: True,
                       inbox=self.inbox, steer_inbox=steer_inbox,
                       STEER_BODY_CAP=65536, STEER_INPUT_CAP=8192)
        for name in ("steer", "_owned", "receipt_get", "steers_get"):
            node = next(n for n in installer.body
                        if isinstance(n, ast.AsyncFunctionDef) and n.name == name)
            exec(compile(ast.Module(body=[node], type_ignores=[]), "compat/compat.py", "exec"),
                 self.ns)
        self.api = api
        for target in (patch.dict(sys.modules, {"gateway.platforms.api_server": api}),
                       patch("gateway.session_busy_controls.adopts_owner_agent",
                             lambda authority, ref: True)):
            target.start()
            self.addCleanup(target.stop)
        self.db = Store()
        self.authority = _authority_class()(self.db)
        authority_patch = patch("gateway.platforms.api_server_authority_runs._authority",
                                lambda adapter: self.authority)
        authority_patch.start()
        self.addCleanup(authority_patch.stop)
        self.adapter = Adapter(self.authority)

    def tearDown(self):
        steer_inbox.set_capability(False)
        steer_store.close_all()

    def _post(self, text, key=None, rid=RUN):
        body = {"input": text, "client_request_id": key or uuid.uuid4().hex}
        return asyncio.run(self.ns["steer"](self.adapter, Request(rid, body),
                                            _api_server=self.api))

    def _receipt(self, steer_id, rid=RUN):
        request = Request(rid)
        request.match_info["steer_id"] = steer_id
        return asyncio.run(self.ns["receipt_get"](self.adapter, request))

    # -- integration: the chat-stream run is steerable ----------------------

    def test_chat_stream_run_steer_before_adoption_reaches_the_adopted_agent(self):
        # Red before TASK-STEERAUTH: 409 run_not_ready (run_not_bound) because
        # the chat-stream run never enters _active_run_agents.
        self.db.add(ADMISSION, "req-1", "started", GENERATION)
        result = self._post("use the staging db")
        self.assertEqual(result.get("http"), 200, result)
        self.assertTrue(result["accepted"])
        self.assertEqual(result["run_id"], RUN)
        self.assertEqual(result["session_id"], SID)
        # Not adopted yet: the core latched it for this generation's agent.
        self.assertEqual(self.authority.pending_steers[SID], (GENERATION, ["use the staging db"]))
        agent = Agent()
        self.authority.adopt_agent(SID, GENERATION, agent)
        self.assertEqual(agent.steered, ["use the staging db"])
        self.assertEqual(self.authority.pending_steers, {})
        receipt = self._receipt(result["steer_id"])
        self.assertEqual(receipt.get("http"), 200, receipt)
        self.assertEqual(receipt["state"], "outcome_unknown")
        self.assertEqual(receipt["error"], steer_store.HANDOFF_ERROR)

    def test_chat_stream_run_steer_after_adoption_reaches_that_agent(self):
        self.db.add(ADMISSION, "req-1", "started", GENERATION)
        agent = Agent()
        self.authority.adopt_agent(SID, GENERATION, agent)
        result = self._post("and skip tests")
        self.assertEqual(result.get("http"), 200, result)
        self.assertEqual(agent.steered, ["and skip tests"])
        self.assertEqual(self.authority.pending_steers, {})

    def test_duplicate_retry_answers_from_the_ledger_without_steering_twice(self):
        self.db.add(ADMISSION, "req-1", "started", GENERATION)
        agent = Agent()
        self.authority.adopt_agent(SID, GENERATION, agent)
        first = self._post("once", key="k-1")
        again = self._post("once", key="k-1")
        self.assertEqual(again.get("http"), 200, again)
        self.assertEqual(again["steer_id"], first["steer_id"])
        self.assertEqual(agent.steered, ["once"])
        conflict = self._post("other text", key="k-1")
        self.assertEqual(conflict["error"]["code"], "steer_identity_conflict")

    # -- admission semantics -------------------------------------------------

    def test_queued_admission_is_not_ready_and_latches_nothing(self):
        self.db.add(ADMISSION, "req-1", "queued")
        result = self._post("too early")
        self.assertEqual(result.get("http"), 409, result)
        self.assertEqual(result["error"]["code"], "run_not_ready")
        self.assertEqual(self.authority.pending_steers, {})

    def test_stale_generation_is_refused_by_the_core_fence(self):
        self.db.add(ADMISSION, "req-1", "started", GENERATION)
        self.authority.generation = GENERATION + 1  # a later turn holds the session
        result = self._post("late")
        self.assertEqual(result.get("http"), 409, result)
        self.assertEqual(result["error"]["code"], "run_closed")
        self.assertEqual(self.authority.pending_steers, {})
        store = steer_store.open_store(self.home)
        self.assertEqual(steer_store.list_steers(store, "owner", RUN)[0], [])

    def test_stopping_run_is_closed(self):
        self.db.add(ADMISSION, "req-1", "started", GENERATION)
        self.adapter._run_statuses[RUN]["status"] = "stopping"
        result = self._post("stop then steer")
        self.assertEqual(result["error"]["code"], "run_closed")
        self.assertEqual(self.authority.pending_steers, {})

    def test_handed_off_steer_is_never_queued_or_sealed_by_compat(self):
        self.db.add(ADMISSION, "req-1", "started", GENERATION)
        agent = Agent()
        self.authority.adopt_agent(SID, GENERATION, agent)
        result = self._post("core owns it")
        # The tool-boundary hook finds no compat binding for an authority agent.
        messages = [{"role": "assistant", "tool_calls": [{"id": "c1"}]},
                    {"role": "tool", "tool_call_id": "c1", "content": "ok"}]
        steer_inbox.on_tool_boundary(self.inbox, agent, messages, 1)
        self.assertEqual(len(messages), 2)
        # The terminal seal retires only accepted items; this receipt stays.
        steer_inbox.seal(self.inbox, self.adapter, RUN, "run_completed")
        self.assertEqual(self._receipt(result["steer_id"])["state"], "outcome_unknown")
        self.assertEqual(steer_inbox.recover(self.inbox)["retired"], 0)

    # -- /v1/runs fallback ---------------------------------------------------

    def test_legacy_run_without_admission_keeps_the_active_run_agents_path(self):
        legacy = "run_legacy"
        agent = Agent()
        self.adapter._run_statuses[legacy] = {"status": "running", "session_id": SID}
        self.adapter._run_owners[legacy] = "owner"
        self.adapter._active_run_agents[legacy] = agent
        result = self._post("legacy", rid=legacy)
        self.assertEqual(result.get("http"), 200, result)
        self.assertEqual(self._receipt(result["steer_id"], rid=legacy)["state"], "accepted")
        self.assertEqual(agent.steered, [], "legacy runs keep the durable ledger path")
        self.assertEqual(self.authority.pending_steers, {})

    def test_no_authority_means_no_authority_binding(self):
        adapter = types.SimpleNamespace(gateway_runner=types.SimpleNamespace())
        self.assertIsNone(steer_inbox.authority_binding(adapter, RUN))
        self.assertIsNone(steer_inbox.authority_binding(types.SimpleNamespace(), RUN))


if __name__ == "__main__":
    unittest.main()
