"""TASK-CROSSSOURCE: app chat aimed at a foreign-source (Discord) session.

Core refuses an API turn into a foreign-surface session
(gateway/session_api_turn.py:216, ``permission_denied``). The crosssource unit
wraps both session chat routes: a Discord target goes through the core plugin
injection seam (``PluginContext.inject_message``) so the session's own Discord
adapter runs the turn and replies in the thread. api_server sessions keep the
native path untouched. Every message is spooled before the first attempt; at
most 3 attempts; a final failure is HTTP 502 kind=bridge_unavailable and the
text stays in the spool.

Sessions live in a real SessionDB tmp file; the gateway and Discord are fakes.
"""
import asyncio
import json
import os
import pathlib
import shutil
import tempfile
import unittest

from aiohttp import web
from aiohttp.test_utils import make_mocked_request

from compat import crosssource

DISCORD_SID = "20260910_151843_94d2209a"
DISCORD_KEY = "agent:main:discord:thread:1547506583351853116:1547506583351853116"
API_SID = "api_native_session"


class FakeApi:
    """The slice of gateway.platforms.api_server the unit binds."""
    web = web

    @staticmethod
    def _error_response(message, status, *, err_type="invalid_request_error", param=None, code=None,
                        headers=None):
        return web.json_response({"error": {"message": message, "type": err_type, "param": param,
                                            "code": code}}, status=status, headers=headers)

    @staticmethod
    def _sse_frame(data, *, event=None, ensure_ascii=True, id=None):
        prefix = f"event: {event}\n" if event else ""
        return f"{prefix}data: {json.dumps(data, ensure_ascii=ensure_ascii)}\n\n".encode()


class FakePlatformAdapter:
    def __init__(self, connected=True):
        self.is_connected = connected


class FakeRunner:
    def __init__(self, adapters):
        self.adapters = adapters


class FakeCtx:
    """PluginContext.inject_message stand-in; scripted per-attempt results."""
    def __init__(self, results):
        self.results = list(results)
        self.calls = []

    def inject_message(self, content, role="user", *, session_key=None, origin=None):
        self.calls.append({"content": content, "session_key": session_key})
        result = self.results.pop(0) if self.results else True
        if isinstance(result, BaseException):
            raise result
        return result


class SSESink:
    def __init__(self):
        self.frames = b""

    async def write(self, data):
        self.frames += data

    def events(self):
        out = []
        for block in self.frames.decode().split("\n\n"):
            if not block.strip():
                continue
            lines = dict(line.split(": ", 1) for line in block.splitlines())
            out.append((lines.get("event"), json.loads(lines["data"])))
        return out


def make_adapter_class(db):
    """A stand-in APIServerAdapter whose native chat handlers record calls."""
    class Adapter:
        native_calls = []

        def __init__(self, runner):
            self.gateway_runner = runner
            self.sinks = []

        def _check_auth(self, request):
            if request.headers.get("authorization") != "Bearer ok":
                return web.json_response({"error": {"message": "unauthorized"}}, status=401)
            return None

        def _draining_response(self):
            return None

        async def _get_existing_session_or_404(self, session_id):
            session = await asyncio.to_thread(db.get_session, session_id)
            if not session:
                return None, web.json_response({"error": {"code": "session_not_found"}}, status=404)
            return session, None

        async def _read_json_body(self, request):
            try:
                return await request.json(), None
            except Exception:
                return None, web.json_response({"error": {"code": "invalid_json"}}, status=400)

        async def _prepare_sse_response(self, request, session_id, gateway_session_key):
            sink = SSESink()
            self.sinks.append(sink)
            return sink

        async def _handle_session_chat(self, request):
            Adapter.native_calls.append(("chat", request.match_info["session_id"]))
            return web.json_response({"native": True})

        async def _handle_session_chat_stream(self, request):
            Adapter.native_calls.append(("stream", request.match_info["session_id"]))
            return web.json_response({"native": True})
    return Adapter


class Tx:
    def __init__(self):
        self.changes = []

    def set(self, target, name, value):
        self.changes.append((target, name, getattr(target, name)))
        setattr(target, name, value)


def request(sid, body, *, stream=False, auth="Bearer ok"):
    path = f"/api/sessions/{sid}/chat" + ("/stream" if stream else "")
    raw = json.dumps(body).encode()
    req = make_mocked_request("POST", path, headers={"authorization": auth, "content-type": "application/json"},
                              match_info={"session_id": sid})

    async def _json():
        return json.loads(raw)
    req.json = _json
    return req


class CrossSourceBase(unittest.TestCase):
    def setUp(self):
        from hermes_state import SessionDB
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.db = SessionDB(self.tmp / "state.db")
        self.db.create_session(DISCORD_SID, "discord", session_key=DISCORD_KEY,
                               chat_id="1547506583351853116", thread_id="1547506583351853116")
        self.db.create_session(API_SID, "api_server")
        self.cls = make_adapter_class(self.db)
        self.cls.native_calls = []
        self.platform = FakePlatformAdapter(connected=True)
        from gateway.config import Platform
        self.adapter = self.cls(FakeRunner({Platform.DISCORD: self.platform}))
        self.ctx = FakeCtx([])
        self.sleeps = []

    def tearDown(self):
        self.db.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def install(self):
        async def no_sleep(seconds):
            self.sleeps.append(seconds)
        self.bridge = crosssource.install(
            FakeApi, self.cls, Tx(), ctx_getter=lambda: self.ctx,
            spool_path=self.tmp / "crosssource_spool.db", sleep=no_sleep)
        return self.bridge

    def run_async(self, coro):
        return asyncio.run(coro)

    def spool_rows(self):
        return self.bridge.outbox.rows()


class RoutingRedGreen(CrossSourceBase):
    """Red without the unit (Discord session goes native, where core says
    permission_denied); green with it (Discord goes through the injection seam)."""

    def test_red_without_unit_discord_target_reaches_native_admission(self):
        response = self.run_async(self.adapter._handle_session_chat_stream(
            request(DISCORD_SID, {"input": "hi"}, stream=True)))
        self.assertEqual([("stream", DISCORD_SID)], self.cls.native_calls)
        self.assertEqual([], self.ctx.calls)
        self.assertEqual(200, response.status)

    def test_green_discord_stream_goes_through_injection_and_answers_queued(self):
        self.install()
        response = self.run_async(self.adapter._handle_session_chat_stream(
            request(DISCORD_SID, {"input": "從 app 發的"}, stream=True)))
        self.assertEqual([], self.cls.native_calls)
        self.assertEqual(1, len(self.ctx.calls))
        call = self.ctx.calls[0]
        self.assertEqual(DISCORD_KEY, call["session_key"])
        self.assertTrue(call["content"].startswith("從 app 發的"))
        self.assertIn(crosssource.VIA_APP_MARK, call["content"])
        events = response.events()
        self.assertEqual(["run.started", "run.queued", "done"], [name for name, _ in events])
        queued = events[1][1]
        self.assertEqual("queued", queued["status"])
        self.assertEqual("discord", queued["via"])
        self.assertEqual(DISCORD_SID, queued["session_id"])
        rows = self.spool_rows()
        self.assertEqual(1, len(rows))
        self.assertEqual(queued["delivery_id"], rows[0]["id"])
        self.assertEqual("accepted", rows[0]["status"])
        self.assertEqual(1, rows[0]["attempts"])

    def test_green_discord_sync_chat_answers_202_queued(self):
        self.install()
        response = self.run_async(self.adapter._handle_session_chat(request(DISCORD_SID, {"message": "hi"})))
        self.assertEqual(202, response.status)
        body = json.loads(response.body)
        self.assertEqual("hermes.session.chat.queued", body["object"])
        self.assertEqual("discord", body["via"])
        self.assertEqual([], self.cls.native_calls)

    def test_api_server_session_keeps_native_path(self):
        self.install()
        self.run_async(self.adapter._handle_session_chat_stream(request(API_SID, {"input": "hi"}, stream=True)))
        self.run_async(self.adapter._handle_session_chat(request(API_SID, {"input": "hi"})))
        self.assertEqual([("stream", API_SID), ("chat", API_SID)], self.cls.native_calls)
        self.assertEqual([], self.ctx.calls)
        self.assertEqual([], self.spool_rows())

    def test_unknown_session_and_wake_batch_stay_native(self):
        self.install()
        self.run_async(self.adapter._handle_session_chat_stream(request("nope", {"input": "hi"}, stream=True)))
        self.run_async(self.adapter._handle_session_chat_stream(
            request(DISCORD_SID, {"input": "hi", "wake_batch": "b1"}, stream=True)))
        self.assertEqual([("stream", "nope"), ("stream", DISCORD_SID)], self.cls.native_calls)
        self.assertEqual([], self.ctx.calls)

    def test_unauthenticated_request_never_reaches_the_bridge(self):
        self.install()
        response = self.run_async(self.adapter._handle_session_chat_stream(
            request(DISCORD_SID, {"input": "hi"}, stream=True, auth="Bearer bad")))
        self.assertEqual(401, response.status)
        self.assertEqual([], self.ctx.calls)
        self.assertEqual([], self.spool_rows())

    def test_multimodal_input_is_refused_before_spooling(self):
        self.install()
        response = self.run_async(self.adapter._handle_session_chat_stream(request(
            DISCORD_SID, {"input": [{"type": "input_image", "image_url": "data:image/png;base64,AA=="}]},
            stream=True)))
        self.assertEqual(415, response.status)
        self.assertEqual("crosssource_text_only", json.loads(response.body)["error"]["code"])
        self.assertEqual([], self.ctx.calls)


class FailureQueue(CrossSourceBase):
    def test_transient_refusal_retries_and_succeeds_on_third_attempt(self):
        self.ctx = FakeCtx([False, RuntimeError("scheduling failed"), True])
        self.install()
        response = self.run_async(self.adapter._handle_session_chat_stream(
            request(DISCORD_SID, {"input": "retry me"}, stream=True)))
        self.assertEqual(["run.started", "run.queued", "done"], [n for n, _ in response.events()])
        self.assertEqual(3, len(self.ctx.calls))
        self.assertEqual(len(crosssource.BACKOFF_SECONDS[:2]), len(self.sleeps))
        row = self.spool_rows()[0]
        self.assertEqual(("accepted", 3), (row["status"], row["attempts"]))

    def test_three_failures_answer_502_bridge_unavailable_and_keep_the_text(self):
        self.ctx = FakeCtx([False, False, False, True])
        self.install()
        response = self.run_async(self.adapter._handle_session_chat_stream(
            request(DISCORD_SID, {"input": "不能丟"}, stream=True)))
        self.assertEqual(502, response.status)
        body = json.loads(response.body)
        self.assertEqual("bridge_unavailable", body["kind"])
        self.assertEqual("bridge_unavailable", body["error"]["code"])
        self.assertEqual(crosssource.MAX_ATTEMPTS, len(self.ctx.calls))
        row = self.spool_rows()[0]
        self.assertEqual(body["delivery_id"], row["id"])
        self.assertEqual(("failed", 3), (row["status"], row["attempts"]))
        self.assertEqual("inject_refused", row["last_error"])
        self.assertTrue(row["text"].startswith("不能丟"))
        self.assertEqual(DISCORD_KEY, row["session_key"])

    def test_disconnected_discord_adapter_fails_without_injecting(self):
        # Bot token rejected / Discord API down: the adapter is not connected.
        self.platform.is_connected = False
        self.install()
        response = self.run_async(self.adapter._handle_session_chat(request(DISCORD_SID, {"input": "x"})))
        self.assertEqual(502, response.status)
        self.assertEqual("bridge_unavailable", json.loads(response.body)["kind"])
        self.assertEqual([], self.ctx.calls)
        row = self.spool_rows()[0]
        self.assertEqual(("failed", 3, "platform_disconnected"),
                         (row["status"], row["attempts"], row["last_error"]))

    def test_adapter_recovering_mid_retry_delivers(self):
        self.platform.is_connected = False
        self.install()
        platform = self.platform

        async def reconnect(seconds):
            self.sleeps.append(seconds)
            platform.is_connected = True
        self.bridge.sleep = reconnect
        response = self.run_async(self.adapter._handle_session_chat(request(DISCORD_SID, {"input": "x"})))
        self.assertEqual(202, response.status)
        self.assertEqual(1, len(self.ctx.calls))
        self.assertEqual(("accepted", 2), (self.spool_rows()[0]["status"], self.spool_rows()[0]["attempts"]))

    def test_missing_plugin_context_is_bridge_unavailable(self):
        self.ctx = None
        self.install()
        response = self.run_async(self.adapter._handle_session_chat(request(DISCORD_SID, {"input": "x"})))
        self.assertEqual(502, response.status)
        self.assertEqual("plugin_context_missing", self.spool_rows()[0]["last_error"])

    def test_spool_survives_a_new_bridge_instance(self):
        self.ctx = FakeCtx([False, False, False])
        self.install()
        self.run_async(self.adapter._handle_session_chat(request(DISCORD_SID, {"input": "durable"})))
        reopened = crosssource.Outbox(self.tmp / "crosssource_spool.db")
        rows = reopened.rows()
        self.assertEqual(1, len(rows))
        self.assertTrue(rows[0]["text"].startswith("durable"))


class RealSeamWiring(unittest.TestCase):
    """The unit binds onto the real APIServerAdapter and Transaction restores it."""

    def test_install_and_restore_on_real_api_server(self):
        from compat import compat as c
        from gateway.platforms import api_server
        self.assertEqual("crosssource", c.UNITS[-1])
        cls = api_server.APIServerAdapter
        before = (cls.__dict__["_handle_session_chat"], cls.__dict__["_handle_session_chat_stream"])
        home = tempfile.mkdtemp()
        saved = (getattr(c, "api", None), os.environ.get("HERMES_HOME"))
        state_existed = hasattr(api_server, c._STATE)
        os.environ["HERMES_HOME"] = home
        c.api = api_server
        if not state_existed:
            setattr(api_server, c._STATE, {"groups": {}, "manifest": {}})
        tx = c.Transaction()
        try:
            c._install_crosssource(tx)
            self.assertIsNot(before[0], cls.__dict__["_handle_session_chat"])
            self.assertIsNot(before[1], cls.__dict__["_handle_session_chat_stream"])
            self.assertTrue(pathlib.Path(home, "crosssource_spool.db").exists())
        finally:
            tx.restore()
            if not state_existed:
                delattr(api_server, c._STATE)
            c.api = saved[0]
            if saved[1] is None:
                os.environ.pop("HERMES_HOME", None)
            else:
                os.environ["HERMES_HOME"] = saved[1]
            shutil.rmtree(home, ignore_errors=True)
        self.assertEqual(before, (cls.__dict__["_handle_session_chat"], cls.__dict__["_handle_session_chat_stream"]))

    def test_install_sh_ships_the_module(self):
        script = (pathlib.Path(crosssource.__file__).parent / "install.sh").read_text()
        self.assertIn("crosssource.py", script)

    def test_core_guard_this_unit_routes_around_is_still_there(self):
        # If core ever opens API turns to foreign sources, this bridge should be revisited.
        from gateway import session_api_turn
        import inspect
        src = inspect.getsource(session_api_turn.admit_api_steps)
        self.assertIn("existing['source'] not in ('api_server', 'bot_room')", src)


if __name__ == "__main__":
    unittest.main()
