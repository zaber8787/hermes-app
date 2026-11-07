"""TASK-RUNROUTE: a continuation row stamped with another conversation's route key.

An earlier release stamped a new API row with the session key of the conversation it
continued from, so every session chat against the new id fails at
gateway/session_api.py:238-240 forever (the app never sends X-Hermes-Session-Key, so core's
legacy adoption never fires). The runroute unit hands core the row's stamped key as caller_key
when six pure-read conditions hold, and core's own adoption rewrites the row onto its computed
route; every refusal (live owner elsewhere, foreign declared owner) stays core's.

Rows live in a real SessionDB tmp file under a throwaway HERMES_HOME (set before the gateway
import); the authority/store/adapter are the core's real objects (same shape as core's
tests/gateway/conftest.py owner/api fixtures); only the turn executor is a stub. The unit is
installed through a real compat Transaction and restored. The real ~/.hermes/state.db mtime is
asserted untouched (red-line guard).
"""
import asyncio
import contextlib
import datetime
import json
import logging
import os
import pathlib
import shutil
import sys
import tempfile
import types
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
# hermes_cli.venv_sync.prepare_launch treats a foreign HERMES_HOME as a fresh data root and
# relaunches this interpreter into the store venv (where pytest is absent). A test never updates
# the checkout, so the lazy-install path is off: os.execv must not reach this process.
os.environ.setdefault("HERMES_DISABLE_LAZY_INSTALLS", "1")

# Imported here (collection time, default home) on purpose: the first import under a foreign
# HERMES_HOME runs hermes_bootstrap's prepare_launch, which relaunches the interpreter into the
# store venv and kills pytest (no pytest there). Like tests/test_crosssource.py, setUp swaps
# HERMES_HOME afterwards; get_hermes_home() re-reads the env every call.
from gateway.config import GatewayConfig, Platform, PlatformConfig  # noqa: E402
from gateway.session import SessionEntry, SessionSource, SessionStore  # noqa: E402
from gateway.session_authority import SessionAuthority  # noqa: E402
from gateway.platforms import api_server  # noqa: E402
from hermes_state import SessionDB  # noqa: E402
from hermes_state_runtime import begin_runtime_epoch  # noqa: E402
from hermes_state_local import API_BINDING_PREFIX, API_DECLARED_PREFIX  # noqa: E402

A = "api_A"
B = "cont_B"
KEY = "agent:main:api_server:dm:api_A"
API_KEY = "runroute-test-key-long-enough"


class _Capture(logging.Handler):
    def __init__(self):
        super().__init__(level=logging.DEBUG)
        self.texts = []

    def emit(self, record):
        try:
            self.texts.append(self.format(record))
        except Exception:
            pass


class RunRouteBase(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="runroute-"))
        self.real_home = pathlib.Path.home() / ".hermes"
        # R8 red line: a SessionDB must never open the real ~/.hermes/state.db from this test.
        # (An mtime snapshot is not usable here: the live gateway owns that WAL and writes it
        # independently, so the assertion would fire on background traffic, not on our opens.)
        real_db = str((self.real_home / "state.db").resolve())
        self._touched_real = []
        self._patches = []
        orig_init = SessionDB.__init__

        def checked_init(self_db, path, *a, **kw):
            if str(pathlib.Path(path).resolve()) == real_db:
                self._touched_real.append(pathlib.Path(path))
            orig_init(self_db, path, *a, **kw)
        p = mock.patch.object(SessionDB, "__init__", checked_init)
        p.start()
        self._patches.append(p)
        os.environ["HERMES_HOME"] = str(self.tmp)
        from compat import compat as c
        self.GatewayConfig, self.begin_runtime_epoch = GatewayConfig, begin_runtime_epoch
        self.Platform, self.SessionSource = Platform, SessionSource
        self.SessionEntry, self.API_BINDING_PREFIX = SessionEntry, API_BINDING_PREFIX
        self.api_server, self.c = api_server, c

        self.db = SessionDB(self.tmp / "state.db")
        self.store = SessionStore(config=GatewayConfig(), sessions_dir=self.tmp / "sessions")
        self.store._db = self.db
        self.runner = types.SimpleNamespace(_draining=False, session_store=self.store)
        self.authority = SessionAuthority(self.runner, profile_id="default", instance_id="first",
                                          db=self.db, epoch=begin_runtime_epoch(self.db, instance_id="first"))
        self.runner.session_authority = self.authority
        self.adapter = api_server.APIServerAdapter(PlatformConfig(enabled=True))
        self.adapter.gateway_runner = self.runner
        self.adapter._session_db = self.db
        self.adapter._api_key = API_KEY
        self.runner._adapter_for_source = lambda source: self.adapter
        self._calls = []

        async def handle(event):
            from gateway.session_results import execution_result
            self._calls.append((event.source.chat_id, event.text))
            self.db.append_message(event.source.chat_id, "user", event.text)
            execution_result.get()["result"] = {"final_response": "ok", "messages": []}
            return "ok"
        self.runner._handle_message = handle

        self._seed(A, KEY, receipt=True, ended="tui_shutdown")
        self._seed(B, KEY)
        import datetime
        now = datetime.datetime.now()
        self.db.save_gateway_routing_entry(KEY, self._entry_json(A, KEY, now), scope="")
        self.db.save_gateway_routing_entry(KEY, self._entry_json(B, KEY, now),
                                           scope=self.store._routing_scope())
        self.tx = None

    def tearDown(self):
        for p in reversed(self._patches):
            p.stop()
        if self.tx is not None:
            self.tx.restore()
        self.db.close()
        shutil.rmtree(self.tmp, ignore_errors=True)
        self.assertEqual([], self._touched_real, "a SessionDB opened the real state.db")

    def _source(self, sid):
        return self.SessionSource(platform=self.Platform.API_SERVER, chat_id=sid, user_id="api", chat_type="dm")

    def _route(self, sid):
        return self.store._generate_session_key(self._source(sid))

    def _entry_json(self, sid, key, now=None):
        import datetime
        now = now or datetime.datetime.now()
        return json.dumps(self.SessionEntry(key, sid, now, now, origin=self._source(sid),
                                            platform=self.Platform.API_SERVER).to_dict())

    def _seed(self, sid, key, *, receipt=False, ended=None, source="api_server"):
        self.db.create_session(sid, source)
        self.db.record_gateway_session_peer(sid, source=source, session_key=key,
                                            chat_id=sid, user_id="api", chat_type="dm")
        if ended:
            self.db.end_session(sid, ended)
        if receipt:
            now = datetime.datetime.now()
            entry = self.SessionEntry(key, sid, now, now, origin=self._source(sid),
                                      platform=self.Platform.API_SERVER)
            payload = json.dumps({"profile_id": "default", "session_id": sid, "route": key,
                                  "entry": entry.to_dict()})
            self.db._execute_write(lambda conn: conn.execute(
                "INSERT INTO state_meta(key,value) VALUES(?,?)",
                (self.API_BINDING_PREFIX + sid, payload)))

    def install_unit(self):
        run_agent = types.ModuleType("run_agent")

        class AIAgent:
            pass
        run_agent.AIAgent = AIAgent
        backend = self.c._detect_backend(self.api_server.APIServerAdapter)
        self.assertIn(backend, self.c.TARGET_LIKE, "core must be a TARGET-family backend")
        for p in (mock.patch.dict("sys.modules", {"run_agent": run_agent}),
                  mock.patch.object(self.c, "_BACKEND", backend),
                  mock.patch.object(self.c, "api", self.api_server, create=True)):
            p.start()
            self._patches.append(p)
        self.tx = self.c.Transaction()
        self.c._install_runroute(self.tx)

    @contextlib.contextmanager
    def capture_logs(self):
        cap, root = _Capture(), logging.getLogger()
        old = root.level
        root.setLevel(logging.DEBUG)
        root.addHandler(cap)
        try:
            yield cap
        finally:
            root.removeHandler(cap)
            root.setLevel(old)

    def stream(self, sid, text="hi"):
        from aiohttp import web
        from aiohttp.test_utils import TestClient, TestServer
        from aiohttp import ClientSession

        app = web.Application()
        app.router.add_post("/api/sessions/{session_id}/chat/stream", self.adapter._handle_session_chat_stream)

        async def main():
            async with TestClient(TestServer(app)) as client:
                response = await client.post(f"/api/sessions/{sid}/chat/stream", json={"message": text},
                                             headers={"Authorization": "Bearer " + API_KEY})
                return response.status, await response.text(), dict(response.headers)
        status, body, headers = asyncio.run(main())
        names = [line[len("event: "):] for block in body.split("\n\n") for line in block.splitlines()
                 if line.startswith("event: ")]
        return status, body, names, headers

    def rows(self, sql, args=()):
        with self.db._read_ctx() as conn:
            return conn.execute(sql, args).fetchall()

    def b_state(self):
        declared = self.rows("SELECT value FROM state_meta WHERE key=?", (self.c_declared_key(),))
        return {"key": self.rows("SELECT session_key FROM sessions WHERE id=?", (B,))[0][0],
                "declared": declared[0][0] if declared else None,
                "routing_self": [(r[0],) for r in self.rows(
                    "SELECT json_extract(entry_json,'$.session_id') FROM gateway_routing "
                    "WHERE scope='' AND session_key=?", (self._route(B),))],
                "receipt": bool(self.rows("SELECT 1 FROM state_meta WHERE key=?",
                                          (self.API_BINDING_PREFIX + B,)))}

    def c_declared_key(self):
        from hermes_state_local import API_DECLARED_PREFIX
        return API_DECLARED_PREFIX + KEY


class RunRouteStream(RunRouteBase):
    def test_red_without_unit_b_is_refused(self):
        status, body, names, _headers = self.stream(B)
        self.assertNotIn("run.completed", names)
        self.assertIn("admission_conflict", body)
        self.assertEqual([], self.rows("SELECT 1 FROM session_admissions WHERE target_session_id=?", (B,)))

    def test_green_b_is_accepted(self):
        self.install_unit()
        with self.capture_logs() as cap:
            status, body, names, headers = self.stream(B)
        self.assertEqual(200, status, body)
        self.assertIn("run.completed", names)
        self.assertNotIn("error", names)
        self.assertEqual("done", names[-1])
        self.assertIsNone(headers.get("X-Hermes-Session-Key"))
        admissions = self.rows("SELECT principal_id, target_session_id FROM session_admissions "
                               "WHERE target_session_id=?", (B,))
        self.assertEqual([("api", B)], [(r[0], r[1]) for r in admissions])
        self.assertTrue(self.rows("SELECT 1 FROM messages WHERE session_id=? AND content='hi'", (B,)))
        text = "\n".join(cap.texts)
        self.assertIn("runroute: session cont_B adopts its stamped route key", text)
        self.assertNotIn("admission_conflict", text)
        self.assertNotIn("runroute: lookup failed", text)

    def test_live_third_row_blocks_injection(self):
        self.install_unit()
        self._seed("live_C", KEY)
        import datetime
        self.db.save_gateway_routing_entry(KEY, self._entry_json("live_C", KEY, datetime.datetime.now()),
                                           scope="x")
        with self.capture_logs() as cap:
            status, body, names, _h = self.stream(B)
        self.assertNotIn("run.completed", names)
        self.assertIn("admission_conflict", body)
        text = "\n".join(cap.texts)
        self.assertNotIn("adopts its stamped route key", text)
        self.assertEqual(KEY, self.rows("SELECT session_key FROM sessions WHERE id=?", (B,))[0][0])

    def test_foreign_declared_owner_is_refused_by_core(self):
        from hermes_state_local import API_DECLARED_PREFIX
        self.install_unit()
        self.db._execute_write(lambda conn: conn.execute(
            "INSERT INTO state_meta(key,value) VALUES(?,?)", (API_DECLARED_PREFIX + KEY, "other")))
        with self.capture_logs() as cap:
            status, body, names, _h = self.stream(B)
        self.assertNotIn("run.completed", names)
        self.assertIn("admission_conflict", body)
        # the wrapper injected: the refusal came from the declared-owner check, not :239
        self.assertIn("adopts its stamped route key", "\n".join(cap.texts))
        self.assertEqual("other", self.rows("SELECT value FROM state_meta WHERE key=?",
                                            (API_DECLARED_PREFIX + KEY,))[0][0])
        self.assertEqual(KEY, self.rows("SELECT session_key FROM sessions WHERE id=?", (B,))[0][0])

    def test_idempotent_second_send(self):
        self.install_unit()
        with self.capture_logs() as cap:
            status, body, names, _h = self.stream(B)
        self.assertIn("run.completed", names, body)
        self.assertIn("adopts its stamped route key", "\n".join(cap.texts))
        snap1 = self.b_state()
        self.assertEqual(self._route(B), snap1["key"])
        self.assertEqual(B, snap1["declared"])
        self.assertEqual([(B,)], snap1["routing_self"])
        self.assertTrue(snap1["receipt"])
        with self.capture_logs() as cap:
            status, body, names, _h = self.stream(B, text="again")
        self.assertIn("run.completed", names, body)
        self.assertNotIn("adopts its stamped route key", "\n".join(cap.texts))
        self.assertEqual(snap1, self.b_state())

    def test_post_a_unchanged_by_adoption(self):
        self.install_unit()
        before = self.stream(A)[2]
        self.stream(B)
        after = self.stream(A)[2]
        self.assertEqual(before, after)


class RunRoutePredicate(RunRouteBase):
    def _key(self, sid):
        return self.c._runroute_adoption_key(self.authority, sid)

    def test_happy_path_returns_the_stamped_key(self):
        self.assertEqual(KEY, self._key(B))

    def test_foreign_source_row(self):
        self._seed("t_X", "agent:main:telegram:dm:x", source="telegram")
        self.assertIsNone(self._key("t_X"))

    def test_bound_receipt_row(self):
        self.assertIsNone(self._key(A))

    def test_key_already_own_route(self):
        self.db.record_gateway_session_peer(B, source="api_server", session_key=self._route(B))
        self.assertIsNone(self._key(B))

    def test_no_routing_points_at_this_row(self):
        with self.db._read_ctx() as conn:
            pass
        self.db._execute_write(lambda conn: conn.execute(
            "DELETE FROM gateway_routing WHERE scope=?", (self.store._routing_scope(),)))
        self.assertIsNone(self._key(B))

    def test_unaddressable_other_owner(self):
        self.db._execute_write(lambda conn: conn.execute("DELETE FROM sessions WHERE id=?", (A,)))
        self.assertIsNone(self._key(B))


if __name__ == "__main__":
    unittest.main()
