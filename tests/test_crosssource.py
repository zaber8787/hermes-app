"""TASK-CROSSSOURCE(2): app chat aimed at a foreign-source (Discord) session.

Core refuses an API turn into a foreign-surface session
(gateway/session_api_turn.py:216, ``permission_denied``). The crosssource unit
wraps both session chat routes: a Discord target is posted into its thread over
Discord REST with the bot token the Discord plugin reads; delivered means 2xx
with a message id. A turn is then requested through the core plugin injection
seam, and a refused trigger only degrades to a log and a row field. Every
message is spooled first, resends fold into their row, at most 3 attempts, a
final failure is HTTP 502 kind=bridge_unavailable, and drain retries pending and
failed rows.

Sessions live in a real SessionDB tmp file. Discord is a local aiohttp server
the real client code posts to; the gateway is a fake.
"""
import asyncio
import json
import logging
import os
import pathlib
import shutil
import sqlite3
import tempfile
import time
import unittest
from unittest import mock

from aiohttp import web
from aiohttp.test_utils import TestServer, make_mocked_request

from compat import crosssource

DISCORD_SID = "20260910_151843_94d2209a"
THREAD = "1547506583351853116"
DISCORD_KEY = f"agent:main:discord:thread:{THREAD}:{THREAD}"
API_SID = "api_native_session"
FAKE_TOKEN = "fake-test-token-0000"
LEGACY_TEXT = "test from app\n\n" + crosssource.VIA_APP_MARK


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


class FakePlatformConfig:
    def __init__(self, token):
        self.token = token


class FakePlatformAdapter:
    def __init__(self, token=FAKE_TOKEN, connected=True):
        self.config = FakePlatformConfig(token)
        self.is_connected = connected


class FakeRunner:
    def __init__(self, adapters, config=None):
        self.adapters = adapters
        self.config = config


class FakeCtx:
    """PluginContext.inject_message stand-in; scripted per-call results."""
    def __init__(self, results):
        self.results = list(results)
        self.calls = []

    def inject_message(self, content, role="user", *, session_key=None, origin=None):
        self.calls.append({"content": content, "session_key": session_key})
        result = self.results.pop(0) if self.results else True
        if isinstance(result, BaseException):
            raise result
        return result


class FakeDiscord:
    """POST /channels/{id}/messages. Script items: ``(status, body)`` or ``"hang"``;
    an exhausted script answers 200 with a fresh message id."""
    def __init__(self, script=()):
        self.script = list(script)
        self.posts = []

    def make_app(self):
        # One aiohttp app per event loop; the script and the post log carry over.
        app = web.Application()
        app.router.add_post("/api/v10/channels/{channel_id}/messages", self.handle)
        return app

    async def handle(self, request):
        self.posts.append({"channel_id": request.match_info["channel_id"],
                           "authorization": request.headers.get("Authorization"),
                           "json": await request.json()})
        item = self.script.pop(0) if self.script else (200, {"id": f"msg{len(self.posts)}"})
        if item == "hang":
            await asyncio.sleep(5)
            item = (200, {"id": "too_late"})
        status, body = item
        if isinstance(body, str):
            return web.Response(status=status, text=body)
        return web.json_response(body, status=status)


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
                               chat_id=THREAD, thread_id=THREAD)
        self.db.create_session(API_SID, "api_server")
        self.cls = make_adapter_class(self.db)
        self.cls.native_calls = []
        self.platform = FakePlatformAdapter()
        from gateway.config import Platform
        self.adapter = self.cls(FakeRunner({Platform.DISCORD: self.platform}))
        self.ctx = FakeCtx([])
        self.discord = FakeDiscord()
        self.sleeps = []
        self.bridge = None

    def tearDown(self):
        self.db.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    @property
    def spool_path(self):
        return self.tmp / "crosssource_spool.db"

    def install(self):
        async def no_sleep(seconds):
            self.sleeps.append(seconds)
        self.bridge = crosssource.install(
            FakeApi, self.cls, Tx(), ctx_getter=lambda: self.ctx, spool_path=self.spool_path,
            sleep=no_sleep)
        return self.bridge

    def drive(self, *calls):
        """Run handler coroutine factories in order against a live fake Discord."""
        async def main():
            server = TestServer(self.discord.make_app())
            await server.start_server()
            try:
                if self.bridge is not None:
                    self.bridge.api_base = str(server.make_url("/api/v10")).rstrip("/")
                return [await call() for call in calls]
            finally:
                await server.close()
        out = asyncio.run(main())
        return out[0] if len(calls) == 1 else out

    def stream(self, text, sid=DISCORD_SID, **kw):
        return lambda: self.adapter._handle_session_chat_stream(request(sid, {"input": text}, stream=True, **kw))

    def chat(self, text, sid=DISCORD_SID):
        return lambda: self.adapter._handle_session_chat(request(sid, {"input": text}))

    def spool_rows(self):
        return crosssource.Outbox(self.spool_path).rows()


class RoutingRedGreen(CrossSourceBase):
    """Red without the unit (Discord session goes native, where core says
    permission_denied); green with it (Discord gets a REST post into the thread)."""

    def test_red_without_unit_discord_target_reaches_native_admission(self):
        response = self.drive(self.stream("hi"))
        self.assertEqual([("stream", DISCORD_SID)], self.cls.native_calls)
        self.assertEqual([], self.discord.posts)
        self.assertEqual(200, response.status)

    def test_green_discord_stream_posts_into_the_thread_then_triggers_a_turn(self):
        self.install()
        response = self.drive(self.stream("從 app 發的"))
        self.assertEqual([], self.cls.native_calls)
        self.assertEqual(1, len(self.discord.posts))
        post = self.discord.posts[0]
        self.assertEqual(THREAD, post["channel_id"])
        self.assertEqual(f"Bot {FAKE_TOKEN}", post["authorization"])
        self.assertTrue(post["json"]["content"].startswith("從 app 發的"))
        self.assertIn(crosssource.VIA_APP_MARK, post["json"]["content"])
        self.assertEqual({"parse": []}, post["json"]["allowed_mentions"])
        self.assertEqual([{"content": post["json"]["content"], "session_key": DISCORD_KEY}], self.ctx.calls)
        events = response.events()
        self.assertEqual(["run.started", "run.queued", "done"], [name for name, _ in events])
        queued = events[1][1]
        self.assertEqual(("queued", "discord", DISCORD_SID), (queued["status"], queued["via"], queued["session_id"]))
        rows = self.spool_rows()
        self.assertEqual(1, len(rows))
        self.assertEqual(queued["delivery_id"], rows[0]["id"])
        self.assertEqual(("delivered", 1, "msg1", "injected"),
                         (rows[0]["status"], rows[0]["attempts"], rows[0]["message_id"], rows[0]["trigger"]))

    def test_green_inject_refused_no_longer_fails_delivery(self):
        # The live failure (TASK-CROSSSOURCE2): inject_message answered False on
        # every attempt and the app got 502. Now REST delivers; the refused
        # trigger is one call, recorded, not retried and not a 502.
        self.ctx = FakeCtx([False, False, False])
        self.install()
        response = self.drive(self.stream("test from app"))
        self.assertEqual(["run.started", "run.queued", "done"], [n for n, _ in response.events()])
        self.assertEqual(1, len(self.discord.posts))
        self.assertEqual(1, len(self.ctx.calls))
        row = self.spool_rows()[0]
        self.assertEqual(("delivered", "inject_refused", None), (row["status"], row["trigger"], row["last_error"]))

    def test_trigger_raising_or_missing_context_degrades_to_a_recorded_reason(self):
        self.ctx = FakeCtx([RuntimeError("scheduling failed")])
        self.install()
        first = self.drive(self.chat("a"))
        self.ctx = None
        second = self.drive(self.chat("b"))
        self.assertEqual((202, 202), (first.status, second.status))
        self.assertEqual(["inject_error", "plugin_context_missing"], [r["trigger"] for r in self.spool_rows()])
        self.assertEqual(2, len(self.discord.posts))

    def test_green_discord_sync_chat_answers_202_queued(self):
        self.install()
        response = self.drive(self.chat("hi"))
        self.assertEqual(202, response.status)
        body = json.loads(response.body)
        self.assertEqual("hermes.session.chat.queued", body["object"])
        self.assertEqual("discord", body["via"])
        self.assertEqual([], self.cls.native_calls)

    def test_api_server_session_keeps_native_path(self):
        self.install()
        self.drive(self.stream("hi", sid=API_SID), self.chat("hi", sid=API_SID))
        self.assertEqual([("stream", API_SID), ("chat", API_SID)], self.cls.native_calls)
        self.assertEqual(([], []), (self.ctx.calls, self.discord.posts))
        self.assertEqual([], self.spool_rows())

    def test_unknown_session_and_wake_batch_stay_native(self):
        self.install()
        self.drive(self.stream("hi", sid="nope"),
                 lambda: self.adapter._handle_session_chat_stream(
                     request(DISCORD_SID, {"input": "hi", "wake_batch": "b1"}, stream=True)))
        self.assertEqual([("stream", "nope"), ("stream", DISCORD_SID)], self.cls.native_calls)
        self.assertEqual([], self.discord.posts)

    def test_unauthenticated_request_never_reaches_the_bridge(self):
        self.install()
        response = self.drive(self.stream("hi", auth="Bearer bad"))
        self.assertEqual(401, response.status)
        self.assertEqual([], self.discord.posts)
        self.assertEqual([], self.spool_rows())

    def test_multimodal_input_is_refused_before_spooling(self):
        self.install()
        response = self.drive(lambda: self.adapter._handle_session_chat_stream(request(
            DISCORD_SID, {"input": [{"type": "input_image", "image_url": "data:image/png;base64,AA=="}]},
            stream=True)))
        self.assertEqual(415, response.status)
        self.assertEqual("crosssource_text_only", json.loads(response.body)["error"]["code"])
        self.assertEqual([], self.discord.posts)

    def test_text_over_the_discord_limit_is_refused_before_spooling(self):
        self.install()
        response = self.drive(self.chat("x" * crosssource.DISCORD_MAX_CONTENT))
        self.assertEqual(413, response.status)
        self.assertEqual("crosssource_too_long", json.loads(response.body)["error"]["code"])
        self.assertEqual(([], []), (self.discord.posts, self.spool_rows()))


class RestDelivery(CrossSourceBase):
    def test_transient_5xx_retries_and_succeeds_on_third_attempt(self):
        self.discord = FakeDiscord([(500, {}), (502, "bad gateway")])
        self.install()
        response = self.drive(self.stream("retry me"))
        self.assertEqual(["run.started", "run.queued", "done"], [n for n, _ in response.events()])
        self.assertEqual(3, len(self.discord.posts))
        self.assertEqual(list(crosssource.BACKOFF_SECONDS), self.sleeps)
        self.assertEqual(1, len(self.ctx.calls))
        row = self.spool_rows()[0]
        self.assertEqual(("delivered", 3, "msg3"), (row["status"], row["attempts"], row["message_id"]))

    def test_three_failures_answer_502_bridge_unavailable_and_keep_the_text(self):
        self.discord = FakeDiscord([(401, {"message": "401: Unauthorized", "code": 0})] * 3)
        self.install()
        response = self.drive(self.stream("不能丟"))
        self.assertEqual(502, response.status)
        body = json.loads(response.body)
        self.assertEqual(("bridge_unavailable", "bridge_unavailable", "rest_http_401"),
                         (body["kind"], body["error"]["code"], body["reason"]))
        self.assertEqual(crosssource.MAX_ATTEMPTS, len(self.discord.posts))
        self.assertEqual([], self.ctx.calls)
        row = self.spool_rows()[0]
        self.assertEqual(body["delivery_id"], row["id"])
        self.assertEqual(("failed", 3, "rest_http_401", None), (row["status"], row["attempts"], row["last_error"],
                                                                row["message_id"]))
        self.assertTrue(row["text"].startswith("不能丟"))
        self.assertEqual(DISCORD_KEY, row["session_key"])

    def test_2xx_without_a_message_id_is_not_delivered(self):
        self.discord = FakeDiscord([(200, {}), (204, ""), (200, "not json")])
        self.install()
        response = self.drive(self.chat("x"))
        self.assertEqual(502, response.status)
        self.assertEqual("rest_no_message_id", self.spool_rows()[0]["last_error"])

    def test_timeout_is_a_failed_attempt(self):
        self.discord = FakeDiscord(["hang", (200, {"id": "m2"})])
        self.install()
        with mock.patch.object(crosssource, "REST_TIMEOUT_SECONDS", 0.2):
            response = self.drive(self.chat("slow"))
        self.assertEqual(202, response.status)
        row = self.spool_rows()[0]
        self.assertEqual(("delivered", 2, "m2"), (row["status"], row["attempts"], row["message_id"]))

    def test_unreachable_discord_is_rest_error(self):
        self.install()

        async def go():
            self.bridge.api_base = "http://127.0.0.1:9/api/v10"
            return await self.chat("x")()
        response = asyncio.run(go())
        self.assertEqual(502, response.status)
        self.assertEqual("rest_error", self.spool_rows()[0]["last_error"])

    def test_token_falls_back_to_runner_config_then_the_secret(self):
        from gateway.config import Platform
        self.platform.config.token = None
        self.adapter.gateway_runner.config = mock.Mock(platforms={Platform.DISCORD: FakePlatformConfig("cfg-tok")})
        self.install()
        self.drive(self.chat("a"))
        self.adapter.gateway_runner.config = None
        with mock.patch("agent.secret_scope.get_secret", return_value="env-tok") as secret:
            self.drive(self.chat("b"))
        secret.assert_called_with("DISCORD_BOT_TOKEN", "")
        self.assertEqual(["Bot cfg-tok", "Bot env-tok"], [p["authorization"] for p in self.discord.posts])

    def test_missing_token_fails_without_posting(self):
        self.platform.config.token = ""
        self.install()
        with mock.patch("agent.secret_scope.get_secret", return_value=""):
            response = self.drive(self.chat("x"))
        self.assertEqual(502, response.status)
        self.assertEqual([], self.discord.posts)
        self.assertEqual("token_missing", self.spool_rows()[0]["last_error"])

    def test_non_thread_session_key_fails_without_posting(self):
        self.db.create_session("dm_session", "discord", session_key="agent:main:discord:dm:42")
        self.install()
        response = self.drive(self.chat("x", sid="dm_session"))
        self.assertEqual(502, response.status)
        self.assertEqual([], self.discord.posts)
        self.assertEqual("session_key_unparsed", self.spool_rows()[0]["last_error"])

    def test_thread_id_is_the_key_tail(self):
        self.assertEqual("22", crosssource.thread_id_from_key("agent:main:discord:thread:11:22"))
        self.assertIsNone(crosssource.thread_id_from_key("agent:main:discord:thread:11:"))
        self.assertIsNone(crosssource.thread_id_from_key("agent:main:telegram:thread:11:22"))

    def test_token_never_reaches_the_log(self):
        self.discord = FakeDiscord([(401, {}), (500, {})])
        self.install()
        with self.assertLogs("hermes-app-compat.crosssource", level=logging.DEBUG) as logs:
            self.drive(self.chat("x"))
        joined = "\n".join(logs.output)
        self.assertIn("as message msg3", joined)
        self.assertNotIn(FAKE_TOKEN, joined)

    def test_spool_survives_a_new_bridge_instance(self):
        self.discord = FakeDiscord([(500, {})] * 3)
        self.install()
        self.drive(self.chat("durable"))
        rows = crosssource.Outbox(self.spool_path).rows()
        self.assertEqual(1, len(rows))
        self.assertTrue(rows[0]["text"].startswith("durable"))


class SpoolDedup(CrossSourceBase):
    def test_three_failed_retries_and_a_rescue_leave_one_row(self):
        # The user pressed retry after each 502; the fourth press finds Discord healthy.
        self.discord = FakeDiscord([(503, {})] * 9)
        self.install()
        responses = self.drive(*[self.chat("test from app") for _ in range(4)])
        self.assertEqual([502, 502, 502, 202], [r.status for r in responses])
        ids = {json.loads(r.body)["delivery_id"] for r in responses}
        rows = self.spool_rows()
        self.assertEqual(1, len(rows))
        self.assertEqual({rows[0]["id"]}, ids)
        self.assertEqual(("delivered", 10, None), (rows[0]["status"], rows[0]["attempts"], rows[0]["last_error"]))
        self.assertEqual(10, len(self.discord.posts))

    def test_double_send_of_a_delivered_message_is_not_posted_twice(self):
        self.install()
        first, second = self.drive(self.chat("hi"), self.chat("hi"))
        self.assertEqual(json.loads(first.body)["delivery_id"], json.loads(second.body)["delivery_id"])
        self.assertEqual((1, 1), (len(self.discord.posts), len(self.ctx.calls)))
        self.assertEqual(1, len(self.spool_rows()))

    def test_different_text_or_session_is_a_new_row(self):
        self.db.create_session("other", "discord", session_key="agent:main:discord:thread:1:2")
        self.install()
        self.drive(self.chat("a"), self.chat("b"), self.chat("a", sid="other"))
        self.assertEqual(3, len(self.spool_rows()))

    def test_window_boundaries(self):
        box = crosssource.Outbox(self.spool_path)
        kw = dict(session_id="s", session_key=DISCORD_KEY, platform="discord", text="t")
        t0 = 1_000_000.0
        first, merged = box.enqueue(now=t0, **kw)
        self.assertFalse(merged)
        box.record(first, attempts=1, status="delivered", message_id="m")
        with sqlite3.connect(self.spool_path) as conn:
            conn.execute("UPDATE outbox SET created_at=? WHERE id=?", (t0, first))
        self.assertEqual((first, True), box.enqueue(now=t0 + 59, **kw))
        later, merged = box.enqueue(now=t0 + 61, **kw)
        self.assertNotEqual(first, later)
        self.assertFalse(merged)

    def test_concurrent_identical_sends_post_once(self):
        self.install()

        async def both():
            return await asyncio.gather(self.chat("same")(), self.chat("same")())
        first, second = self.drive(both)
        self.assertEqual((202, 202), (first.status, second.status))
        self.assertEqual(1, len(self.discord.posts))


class Drain(CrossSourceBase):
    def legacy_spool(self, created_ats):
        """The pre-CROSSSOURCE2 schema and rows the live spool holds (inject_refused x4)."""
        with sqlite3.connect(self.spool_path) as conn:
            conn.execute(crosssource._SCHEMA)
            for n, created in enumerate(created_ats):
                conn.execute("INSERT INTO outbox VALUES (?,?,?,?,?,'failed',3,'inject_refused',?,?)",
                             (f"xsrc_legacy{n}", DISCORD_SID, DISCORD_KEY, "discord", LEGACY_TEXT,
                              created, created))

    def test_drain_retries_failed_rows_and_collapses_duplicates(self):
        now = time.time()
        self.legacy_spool([now - 80, now - 75, now - 70, now - 3])
        self.install()
        result = self.drive(lambda: self.bridge.drain(self.adapter))
        self.assertEqual({"xsrc_legacy0": None}, result)
        self.assertEqual(1, len(self.discord.posts))
        self.assertEqual(LEGACY_TEXT, self.discord.posts[0]["json"]["content"])
        rows = {r["id"]: r for r in self.spool_rows()}
        self.assertEqual(("delivered", 4, "msg1", "injected"),
                         tuple(rows["xsrc_legacy0"][k] for k in ("status", "attempts", "message_id", "trigger")))
        for n in (1, 2, 3):
            self.assertEqual(("merged", "merged_into:xsrc_legacy0"),
                             (rows[f"xsrc_legacy{n}"]["status"], rows[f"xsrc_legacy{n}"]["last_error"]))

    def test_drain_takes_pending_and_failed_but_not_stale_or_delivered(self):
        now = time.time()
        box = crosssource.Outbox(self.spool_path)
        ids = {}
        for name in ("pending", "failed", "delivered", "stale"):
            ids[name], _ = box.enqueue(session_id=DISCORD_SID, session_key=DISCORD_KEY, platform="discord",
                                       text=name)
        box.record(ids["failed"], attempts=3, status="failed", error="rest_http_503")
        box.record(ids["delivered"], attempts=1, status="delivered", message_id="m0")
        with sqlite3.connect(self.spool_path) as conn:
            conn.execute("UPDATE outbox SET status='failed', updated_at=? WHERE id=?",
                         (now - crosssource.DRAIN_MAX_AGE_SECONDS - 5, ids["stale"]))
        self.install()
        result = self.drive(lambda: self.bridge.drain(self.adapter))
        self.assertEqual({ids["pending"]: None, ids["failed"]: None}, result)
        self.assertEqual(["pending", "failed"], [p["json"]["content"] for p in self.discord.posts])
        statuses = {r["id"]: r["status"] for r in self.spool_rows()}
        self.assertEqual("failed", statuses[ids["stale"]])

    def test_drain_failure_keeps_rows_failed(self):
        self.legacy_spool([time.time() - 5])
        self.discord = FakeDiscord([(500, {})] * 3)
        self.install()
        result = self.drive(lambda: self.bridge.drain(self.adapter))
        self.assertEqual({"xsrc_legacy0": "rest_http_500"}, result)
        row = self.spool_rows()[0]
        self.assertEqual(("failed", 6), (row["status"], row["attempts"]))

    def test_schedule_drain_runs_once_per_bridge(self):
        self.legacy_spool([time.time() - 5])
        self.install()

        async def go():
            loop = asyncio.get_running_loop()
            self.assertTrue(self.bridge.schedule_drain(self.adapter, loop, delay=0))
            self.assertFalse(self.bridge.schedule_drain(self.adapter, loop, delay=0))
            await self.bridge.drain_task
        self.drive(go)
        self.assertEqual([0], self.sleeps)
        self.assertEqual("delivered", self.spool_rows()[0]["status"])

    def test_compat_arms_the_current_bridge(self):
        from compat import compat as c
        bridge = mock.Mock()
        bridge.schedule_drain.return_value = True
        holder = type("api", (), {})()
        setattr(holder, c._STATE, {"crosssource": bridge})
        loop = object()
        with mock.patch.object(c, "api", holder, create=True):
            c._crosssource_drain_arm("adapter", "test", loop)
            c._crosssource_drain_arm(None, "test", loop)
        bridge.schedule_drain.assert_called_once_with("adapter", loop)


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
