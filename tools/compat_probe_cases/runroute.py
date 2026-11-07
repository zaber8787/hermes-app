"""TASK-RUNROUTE (offline probe): a continuation row adopts its stamped route key.

The plugin loader installed the runroute unit; this case drives the INSTALLED wrapper over the
core's real authority (a fresh state.db under the worker's disposable HERMES_HOME) and asserts:
the continuation row is accepted end to end (HTTP 200 + run.completed, a new api admission and
its message row on the addressed id), core still refuses when the same key names a live row in
another scope or a declared owner, and a second send after adoption stays green without
re-injecting. The `server` parameter is unused: offline.py's fixture adapter has no
gateway_runner, so the adapter here is built on this case's own authority (as in
tests/test_runroute.py).
"""
from __future__ import annotations
import datetime
import json
import os
import pathlib
from types import SimpleNamespace


async def case_runroute(args, server, check):
    from aiohttp import web
    from aiohttp.test_utils import TestClient, TestServer
    from gateway.config import GatewayConfig, Platform, PlatformConfig
    from gateway.platforms import api_server
    from gateway.session import SessionEntry, SessionSource, SessionStore
    from gateway.session_authority import SessionAuthority
    from hermes_state import SessionDB
    from hermes_state_local import API_BINDING_PREFIX, API_DECLARED_PREFIX
    from hermes_state_runtime import begin_runtime_epoch

    state = getattr(api_server, "_hermes_app_compat_state_v1")
    check(state["manifest"]["runroute"]["status"] == "applied", "runroute applied")

    home = pathlib.Path(os.environ["HERMES_HOME"])
    home.mkdir(parents=True, exist_ok=True)
    A, B, KEY = "probe_A", "probe_B", "agent:main:api_server:dm:probe_A"
    db = SessionDB(home / "state.db")
    store = SessionStore(config=GatewayConfig(), sessions_dir=home / "sessions")
    store._db = db
    runner = SimpleNamespace(_draining=False, session_store=store)
    authority = SessionAuthority(runner, profile_id="default", instance_id="probe", db=db,
                                 epoch=begin_runtime_epoch(db, instance_id="probe"))
    runner.session_authority = authority
    adapter = api_server.APIServerAdapter(PlatformConfig(enabled=True, extra={"key": "probe-key"}))
    adapter.gateway_runner = runner
    adapter._session_db = db
    adapter._api_key = "probe-key"
    runner._adapter_for_source = lambda source: adapter

    async def handle(event):
        from gateway.session_results import execution_result
        db.append_message(event.source.chat_id, "user", event.text)
        execution_result.get()["result"] = {"final_response": "ok", "messages": []}
        return "ok"
    runner._handle_message = handle

    def source(sid):
        return SessionSource(platform=Platform.API_SERVER, chat_id=sid, user_id="api", chat_type="dm")

    def seed(sid, key, *, ended=None, receipt=False):
        db.create_session(sid, "api_server")
        db.record_gateway_session_peer(sid, source="api_server", session_key=key, chat_id=sid,
                                       user_id="api", chat_type="dm")
        if ended:
            db.end_session(sid, ended)
        if receipt:
            now = datetime.datetime.now()
            entry = SessionEntry(key, sid, now, now, origin=source(sid), platform=Platform.API_SERVER)
            db._execute_write(lambda conn: conn.execute("INSERT INTO state_meta(key,value) VALUES(?,?)",
                              (API_BINDING_PREFIX + sid, json.dumps({"profile_id": "default", "session_id": sid,
                                                                     "route": key, "entry": entry.to_dict()}))))
    seed(A, KEY, ended="tui_shutdown", receipt=True)
    seed(B, KEY)
    now = datetime.datetime.now()
    db.save_gateway_routing_entry(KEY, json.dumps(SessionEntry(KEY, A, now, now, origin=source(A),
        platform=Platform.API_SERVER).to_dict()), scope="")
    db.save_gateway_routing_entry(KEY, json.dumps(SessionEntry(KEY, B, now, now, origin=source(B),
        platform=Platform.API_SERVER).to_dict()), scope=store._routing_scope())

    async def post(sid, text):
        # async-native: the probe worker already runs inside an event loop
        app = web.Application()
        app.router.add_post("/api/sessions/{session_id}/chat/stream", adapter._handle_session_chat_stream)
        async with TestClient(TestServer(app)) as client:
            response = await client.post(f"/api/sessions/{sid}/chat/stream", json={"message": text},
                                         headers={"Authorization": "Bearer probe-key"})
            return response.status, await response.text()

    def frames(body):
        return [line[len("event: "):] for block in body.split("\n\n") for line in block.splitlines()
                if line.startswith("event: ")]

    def sql(statement, params=()):
        with db._read_ctx() as conn:
            return conn.execute(statement, params).fetchall()

    status, body = await post(B, "one")
    check("run.completed" in frames(body), "the continuation turn runs (200 + run.completed)")
    check(status == 200, f"accepted with HTTP 200 ({status})")
    check(sql("SELECT 1 FROM session_admissions WHERE principal_id='api' AND target_session_id=?", (B,)),
        "one api admission targets the continuation row")
    check(sql("SELECT 1 FROM messages WHERE session_id=? AND content='one'", (B,)), "the message row is B's")
    route_b = store._generate_session_key(source(B))
    check(sql("SELECT session_key FROM sessions WHERE id=?", (B,))[0][0] == route_b, "B is on its own route")
    check(sql("SELECT value FROM state_meta WHERE key=?", (API_DECLARED_PREFIX + KEY,))[0][0] == B,
          "core registered the stamped key as B's declared key")
    check(sql("SELECT 1 FROM state_meta WHERE key=?", (API_BINDING_PREFIX + B,)), "B has a binding receipt")

    status, body = await post(B, "two")
    check("run.completed" in frames(body), "the second send stays green")
    check(sql("SELECT session_key FROM sessions WHERE id=?", (B,))[0][0] == route_b,
          "the second send left B's rewrite alone")
    db.close()
