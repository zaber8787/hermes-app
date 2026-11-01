"""TASK-DIRECTINJECT: app chat aimed at a foreign-source (Discord) session.

Core refuses an API turn into a foreign-surface session
(gateway/session_api_turn.py:216, ``permission_denied``). The crosssource unit
wraps both session chat routes: a Discord target is delivered through the core
plugin injection seam alone (``PluginContext.inject_message`` with the
session's own ``session_key``). There is no Discord REST post and no bot mark
on the text: a bot never speaks for the user. Every message is spooled first,
resends fold into their row, at most 3 attempts, a final failure is HTTP 502
kind=bridge_unavailable, and drain retries pending and failed rows. Rows
spooled by the retired bot-forwarding bridge drain with the mark stripped.

Sessions live in a real SessionDB tmp file; the gateway is a fake and the
plugin context is a scripted ``inject_message`` stand-in. TASK-PROGRESSBRIDGE:
where a stream follows the injected turn, the session authority is a fake whose
live entries hold core's real ``SessionEvents``, and ``ScriptedTurn`` publishes
the frames core publishes for an admitted plugin turn, built by core's own
payload functions.
"""
import asyncio
import json
import os
import pathlib
import shutil
import sqlite3
import tempfile
import threading
import time
import unittest
import uuid
from dataclasses import asdict
from unittest import mock

from aiohttp import web
from aiohttp.test_utils import make_mocked_request

from compat import crosssource

DISCORD_SID = "20260910_151843_94d2209a"
THREAD = "1547506583351853116"
DISCORD_KEY = f"agent:main:discord:thread:{THREAD}:{THREAD}"
CHANNEL_KEY = "agent:main:discord:channel:12320260910151843"
API_SID = "api_native_session"
LEGACY_TEXT = "test from app" + crosssource._LEGACY_MARK


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


class FakeRunner:
    adapters = {}
    config = None


class FakeCtx:
    """PluginContext.inject_message stand-in; scripted per-call results. ``on_inject`` runs for
    an accepted call, as core's dispatch runs after ``inject_message`` returned True."""
    def __init__(self, results, on_inject=None):
        self.results = list(results)
        self.calls = []
        self.on_inject = on_inject

    def inject_message(self, content, role="user", *, session_key=None, origin=None):
        self.calls.append({"content": content, "session_key": session_key})
        result = self.results.pop(0) if self.results else True
        if isinstance(result, BaseException):
            raise result
        if result and self.on_inject is not None:
            self.on_inject(content, session_key)
        return result


class FakeLive:
    def __init__(self):
        from gateway.session_events import SessionEvents
        self.event_stream = SessionEvents()


class FakeAuthority:
    """The slice of SessionAuthority the follow reads: live entries and logical_owner."""
    runner = None

    def __init__(self):
        self.sessions = {}

    def logical_owner(self, session_id):
        return session_id


def plugin_identity(session_key):
    """The request_id core gives a plugin injection (run_plugin_injection._admit_plugin_injection)."""
    return json.dumps(["plugin", "hermes-app-compat", session_key, uuid.uuid4().hex], separators=(",", ":"))


class ScriptedTurn:
    """Core's frames for one admitted plugin turn on ``owner``: the commit's session.info, the
    claim's message.start, the agent's deltas and tools, the settlement's message.complete.
    Published on a worker thread (the agent's callbacks run there). ``steps``: ("delta", text),
    ("tool", name, args, result, is_error), ("other", text) (another admission's delta),
    ("pause", seconds); ``outcome`` is the settled outcome."""

    def __init__(self, authority, owner, steps, *, outcome="completed", response="", create_live=True,
                 sync=False, sequence=5):
        self.authority, self.owner, self.steps = authority, owner, steps
        self.outcome, self.response, self.create_live, self.sync = outcome, response, create_live, sync
        self.sequence = sequence
        self.admission_id = f"adm_{uuid.uuid4().hex[:8]}"
        self.thread = None

    def __call__(self, content, session_key):
        if self.create_live:
            self.authority.sessions.setdefault(self.owner, FakeLive())
        identity = plugin_identity(session_key)
        if self.sync:
            self.run(content, identity)
        else:
            self.thread = threading.Thread(target=self.run, args=(content, identity), daemon=True)
            self.thread.start()

    def run(self, content, identity):
        from gateway.run_turn_progress import _tool_complete_payload, _tool_lifecycle_payload
        from gateway.session_contract import PendingAdmission, SessionRef
        from gateway.session_settlement_recovery import completion_payload
        events = self.authority.sessions[self.owner].event_stream
        pending = PendingAdmission(admission_id=self.admission_id, ref=SessionRef("default", self.owner),
                                   sequence=self.sequence, status="queued", outcome=None, authority_epoch=1,
                                   execution_generation=None, input_id=identity, text=content)
        events.publish(self.owner, {"stored_session_id": self.owner, "pending": [asdict(pending)]},
                       event_type="session.info")
        stamp = {"authority_epoch": 1, "execution_generation": 1, "admission_id": self.admission_id}
        with events.lock:
            events.execution = stamp
            events.publish(self.owner, {}, event_type="message.start")
        for n, step in enumerate(self.steps):
            if step[0] == "delta":
                events.publish(self.owner, {"text": step[1]}, event_type="message.delta")
            elif step[0] == "other":
                other = {"authority_epoch": 1, "execution_generation": 9, "admission_id": "adm_other"}
                events.publish(self.owner, {"text": step[1]}, event_type="message.delta", execution=other)
            elif step[0] == "tool":
                _, name, args, result, is_error = step
                events.publish(self.owner, _tool_lifecycle_payload(f"call_{n}", name, args), event_type="tool.start")
                events.publish(self.owner, _tool_complete_payload(f"call_{n}", name, args, result, is_error=is_error),
                               event_type="tool.complete")
            elif step[0] == "pause":
                time.sleep(step[1])
        row = {"admission_id": self.admission_id, "request_id": identity}
        events.publish(self.owner, completion_payload(row, {"outcome": self.outcome}, self.response, None))
        with events.lock:
            events.execution = {}


class NoInjectCtx:
    def noop(self):
        return None


class SSESink:
    def __init__(self):
        self.frames = b""

    async def write(self, data):
        self.frames += data

    def events(self):
        out = []
        for block in self.frames.decode().split("\n\n"):
            if not block.strip() or block.startswith(":"):
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
        self.adapter = self.cls(FakeRunner())
        self.ctx = FakeCtx([])
        self.sleeps = []
        self.bridge = None

    def tearDown(self):
        self.db.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    @property
    def spool_path(self):
        return self.tmp / "crosssource_spool.db"

    def install(self, **kw):
        async def no_sleep(seconds):
            self.sleeps.append(seconds)
        self.bridge = crosssource.install(
            FakeApi, self.cls, Tx(), ctx_getter=lambda: self.ctx, spool_path=self.spool_path,
            sleep=no_sleep, **kw)
        return self.bridge

    def follow_turn(self, steps, **kw):
        """Install with a session authority and script the turn core runs for the injection."""
        self.authority = FakeAuthority()
        self.turn = ScriptedTurn(self.authority, DISCORD_SID, steps, **kw)
        self.ctx = FakeCtx([], on_inject=self.turn)
        return self.install(authority_getter=lambda adapter: self.authority, admission_wait=2, keepalive=5)

    def drive(self, *calls):
        async def main():
            return [await call() for call in calls]
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
    permission_denied); green with it (the text reaches inject_message)."""

    def test_red_without_unit_discord_target_reaches_native_admission(self):
        response = self.drive(self.stream("hi"))
        self.assertEqual([("stream", DISCORD_SID)], self.cls.native_calls)
        self.assertEqual([], self.ctx.calls)
        self.assertEqual(200, response.status)

    def test_green_discord_stream_injects_the_plain_text_once(self):
        self.follow_turn([("delta", "好"), ("tool", "terminal", {"command": "ls"}, "a\nb", False),
                          ("delta", "了")], response="好了")
        response = self.drive(self.stream("從 app 發的"))
        self.assertEqual([], self.cls.native_calls)
        self.assertEqual([{"content": "從 app 發的", "session_key": DISCORD_KEY}], self.ctx.calls)
        events = self.adapter.sinks[0].events()
        self.assertEqual(["run.started", "message.started", "assistant.delta", "tool.started", "tool.completed",
                          "assistant.delta", "assistant.completed", "run.completed", "done"],
                         [name for name, _ in events])
        self.assertEqual({DISCORD_SID}, {payload["session_id"] for _, payload in events})
        self.assertEqual("好了", events[6][1]["content"])
        rows = self.spool_rows()
        self.assertEqual(1, len(rows))
        self.assertEqual(("delivered", 1, "injected"), (rows[0]["status"], rows[0]["attempts"], rows[0]["trigger"]))

    def test_injected_text_carries_no_bot_mark(self):
        self.install()
        self.drive(self.stream("plain line"))
        content = self.ctx.calls[0]["content"]
        self.assertEqual("plain line", content)
        self.assertNotIn("代發", content)

    def test_no_rest_delivery_code_remains(self):
        for gone in ("bot_token", "platform_adapter", "_post", "_proxy_kwargs"):
            self.assertFalse(hasattr(crosssource.Bridge, gone), gone)
        for gone in ("VIA_APP_MARK", "DISCORD_API", "REST_TIMEOUT_SECONDS", "DISCORD_MAX_CONTENT"):
            self.assertFalse(hasattr(crosssource, gone), gone)

    def test_green_discord_sync_chat_answers_202_queued(self):
        self.install()
        response = self.drive(self.chat("hi"))
        self.assertEqual(202, response.status)
        body = json.loads(response.body)
        self.assertEqual("hermes.session.chat.queued", body["object"])
        self.assertEqual("discord", body["via"])
        self.assertEqual([], self.cls.native_calls)
        self.assertEqual(1, len(self.ctx.calls))

    def test_non_thread_discord_key_is_injected_too(self):
        self.db.create_session("dm_session", "discord", session_key="agent:main:discord:dm:42")
        self.install()
        response = self.drive(self.chat("x", sid="dm_session"))
        self.assertEqual(202, response.status)
        self.assertEqual([{"content": "x", "session_key": "agent:main:discord:dm:42"}], self.ctx.calls)

    def test_api_server_session_keeps_native_path(self):
        self.install()
        self.drive(self.stream("hi", sid=API_SID), self.chat("hi", sid=API_SID))
        self.assertEqual([("stream", API_SID), ("chat", API_SID)], self.cls.native_calls)
        self.assertEqual([], self.ctx.calls)
        self.assertEqual([], self.spool_rows())

    def test_unknown_session_and_wake_batch_stay_native(self):
        self.install()
        self.drive(self.stream("hi", sid="nope"),
                 lambda: self.adapter._handle_session_chat_stream(
                     request(DISCORD_SID, {"input": "hi", "wake_batch": "b1"}, stream=True)))
        self.assertEqual([("stream", "nope"), ("stream", DISCORD_SID)], self.cls.native_calls)
        self.assertEqual([], self.ctx.calls)

    def test_unauthenticated_request_never_reaches_the_bridge(self):
        self.install()
        response = self.drive(self.stream("hi", auth="Bearer bad"))
        self.assertEqual(401, response.status)
        self.assertEqual([], self.ctx.calls)
        self.assertEqual([], self.spool_rows())

    def test_multimodal_input_is_refused_before_spooling(self):
        self.install()
        response = self.drive(lambda: self.adapter._handle_session_chat_stream(request(
            DISCORD_SID, {"input": [{"type": "input_image", "image_url": "data:image/png;base64,AA=="}]},
            stream=True)))
        self.assertEqual(415, response.status)
        self.assertEqual("crosssource_text_only", json.loads(response.body)["error"]["code"])
        self.assertEqual([], self.ctx.calls)
        self.assertEqual([], self.spool_rows())

    def test_empty_message_is_refused(self):
        self.install()
        response = self.drive(self.chat("   "))
        self.assertEqual(400, response.status)
        self.assertEqual([], self.spool_rows())


class DeliveryOutcomes(CrossSourceBase):
    """A refused or raising inject is a failed attempt; a final failure is a
    plain 502 bridge_unavailable with the text kept in the spool."""

    def test_inject_refused_three_times_answers_502_and_keeps_the_text(self):
        self.install()
        self.ctx = FakeCtx([False, False, False])
        response = self.drive(self.stream("不能丟"))
        self.assertEqual(502, response.status)
        body = json.loads(response.body)
        self.assertEqual(("bridge_unavailable", "bridge_unavailable", "inject_refused"),
                         (body["kind"], body["error"]["code"], body["reason"]))
        self.assertEqual(3, len(self.ctx.calls))
        row = self.spool_rows()[0]
        self.assertEqual(body["delivery_id"], row["id"])
        self.assertEqual(("failed", 3, "inject_refused"), (row["status"], row["attempts"], row["last_error"]))
        self.assertEqual("不能丟", row["text"])
        self.assertEqual(DISCORD_KEY, row["session_key"])
        self.assertEqual(list(crosssource.BACKOFF_SECONDS), self.sleeps)

    def test_inject_raising_is_a_failed_attempt_not_a_crash(self):
        self.install()
        self.ctx = FakeCtx([RuntimeError("scheduling failed")] * 3)
        response = self.drive(self.stream("x"))
        self.assertEqual(502, response.status)
        self.assertEqual("inject_error", json.loads(response.body)["reason"])

    def test_missing_plugin_context_answers_502(self):
        self.install()
        self.ctx = None
        response = self.drive(self.chat("x"))
        self.assertEqual(502, response.status)
        self.assertEqual("plugin_context_missing", json.loads(response.body)["reason"])

    def test_context_without_inject_answers_502(self):
        self.install()
        self.ctx = NoInjectCtx()
        response = self.drive(self.chat("x"))
        self.assertEqual(502, response.status)
        self.assertEqual("plugin_context_missing", json.loads(response.body)["reason"])

    def test_transient_refusal_succeeds_on_the_second_attempt(self):
        self.install()
        self.ctx = FakeCtx([False, True])
        response = self.drive(self.chat("x"))
        self.assertEqual(202, response.status)
        self.assertEqual(2, len(self.ctx.calls))
        row, = self.spool_rows()
        self.assertEqual(("delivered", 2, "injected"), (row["status"], row["attempts"], row["trigger"]))

    def test_resend_after_failure_retries_the_same_row(self):
        self.install()
        self.ctx = FakeCtx([False, False, False])
        first = json.loads(self.drive(self.stream("x")).body)
        self.ctx = FakeCtx([True])
        self.drive(self.stream("x"))
        rows = self.spool_rows()
        self.assertEqual(1, len(rows))
        self.assertEqual(first["delivery_id"], rows[0]["id"])
        self.assertEqual("delivered", rows[0]["status"])


class SpoolDedup(CrossSourceBase):
    def test_spool_survives_a_new_bridge_instance(self):
        self.install()
        self.ctx = FakeCtx([False, False, False])
        self.drive(self.chat("durable"))
        rows = crosssource.Outbox(self.spool_path).rows()
        self.assertEqual(1, len(rows))
        self.assertEqual("durable", rows[0]["text"])

    def test_three_failed_retries_and_a_rescue_leave_one_row(self):
        # The user pressed retry after each 502; the fourth press finds the seam healthy.
        self.install()
        self.ctx = FakeCtx([False] * 9 + [True])
        responses = self.drive(*[self.chat("test from app") for _ in range(4)])
        self.assertEqual([502, 502, 502, 202], [r.status for r in responses])
        ids = {json.loads(r.body)["delivery_id"] for r in responses}
        rows = self.spool_rows()
        self.assertEqual(1, len(rows))
        self.assertEqual({rows[0]["id"]}, ids)
        self.assertEqual(10, len(self.ctx.calls))

    def test_double_send_of_a_delivered_message_is_not_injected_twice(self):
        self.install()
        first, second = self.drive(self.chat("hi"), self.chat("hi"))
        self.assertEqual(json.loads(first.body)["delivery_id"], json.loads(second.body)["delivery_id"])
        self.assertEqual(1, len(self.ctx.calls))
        self.assertEqual(1, len(self.spool_rows()))

    def test_different_text_or_session_is_a_new_row(self):
        self.db.create_session("other", "discord", session_key="agent:main:discord:thread:1:2")
        self.install()
        self.drive(self.chat("a"), self.chat("b"), self.chat("a", sid="other"))
        self.assertEqual(3, len(self.spool_rows()))
        self.assertEqual(3, len(self.ctx.calls))

    def test_window_boundaries(self):
        box = crosssource.Outbox(self.spool_path)
        kw = dict(session_id="s", session_key=DISCORD_KEY, platform="discord", text="t")
        t0 = 1_000_000.0
        first, merged = box.enqueue(now=t0, **kw)
        self.assertFalse(merged)
        box.record(first, attempts=1, status="delivered")
        with sqlite3.connect(self.spool_path) as conn:
            conn.execute("UPDATE outbox SET created_at=? WHERE id=?", (t0, first))
        self.assertEqual((first, True), box.enqueue(now=t0 + 59, **kw))
        later, merged = box.enqueue(now=t0 + 61, **kw)
        self.assertNotEqual(first, later)
        self.assertFalse(merged)

    def test_concurrent_identical_sends_inject_once(self):
        self.install()

        async def both():
            return await asyncio.gather(self.chat("same")(), self.chat("same")())
        first, second = self.drive(both)
        self.assertEqual((202, 202), (first.status, second.status))
        self.assertEqual(1, len(self.ctx.calls))


class Drain(CrossSourceBase):
    def legacy_spool(self, created_ats):
        """The rows the live bot-forwarding spool holds (failed, mark on the text)."""
        with sqlite3.connect(self.spool_path) as conn:
            conn.execute(crosssource._SCHEMA)
            for name, kind in crosssource._ADDED_COLUMNS:
                try:
                    conn.execute(f"ALTER TABLE outbox ADD COLUMN {name} {kind}")
                except sqlite3.OperationalError:
                    pass
            for n, created in enumerate(created_ats):
                conn.execute("INSERT INTO outbox VALUES (?,?,?,?,?,'failed',3,'rest_http_401',?,?,?,?)",
                             (f"xsrc_legacy{n}", DISCORD_SID, DISCORD_KEY, "discord", LEGACY_TEXT,
                              created, created, None, None))

    def test_drain_injects_legacy_rows_mark_free_and_collapses_duplicates(self):
        now = time.time()
        self.legacy_spool([now - 80, now - 75, now - 70, now - 3])
        self.install()
        result = self.drive(lambda: self.bridge.drain(self.adapter))
        self.assertEqual({"xsrc_legacy0": None}, result)
        self.assertEqual([{"content": "test from app", "session_key": DISCORD_KEY}], self.ctx.calls)
        rows = {r["id"]: r for r in self.spool_rows()}
        self.assertEqual("delivered", rows["xsrc_legacy0"]["status"])
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
        box.record(ids["failed"], attempts=3, status="failed", error="inject_refused")
        box.record(ids["delivered"], attempts=1, status="delivered")
        with sqlite3.connect(self.spool_path) as conn:
            conn.execute("UPDATE outbox SET status='failed', created_at=?, updated_at=? WHERE id=?",
                         (now - crosssource.DRAIN_MAX_AGE_SECONDS - 5, now - crosssource.DRAIN_MAX_AGE_SECONDS - 5,
                          ids["stale"]))
        self.install()
        result = self.drive(lambda: self.bridge.drain(self.adapter))
        self.assertEqual({ids["pending"]: None, ids["failed"]: None}, result)
        self.assertEqual(["pending", "failed"], [c["content"] for c in self.ctx.calls])
        statuses = {r["id"]: r["status"] for r in self.spool_rows()}
        self.assertEqual("stale-dropped", statuses[ids["stale"]])

    def test_drain_drops_rows_older_than_max_age_even_when_recently_retried(self):
        """10-30 text still failing at every reload: each retry refreshed updated_at, so an
        updated_at window never aged it out. Age is the message's (created_at)."""
        now = time.time()
        old = now - 3 * 86400
        box = crosssource.Outbox(self.spool_path)
        ids = {}
        for name in ("retried", "untouched", "fresh"):
            ids[name], _ = box.enqueue(session_id=DISCORD_SID, session_key=DISCORD_KEY, platform="discord",
                                       text=name, now=now if name == "fresh" else old)
        with sqlite3.connect(self.spool_path) as conn:
            conn.execute("UPDATE outbox SET status='failed', attempts=3, updated_at=? WHERE id=?",
                         (now - 3600, ids["retried"]))
        self.install()
        result = self.drive(lambda: self.bridge.drain(self.adapter))
        self.assertEqual({ids["fresh"]: None}, result)
        self.assertEqual(["fresh"], [c["content"] for c in self.ctx.calls])
        rows = {r["id"]: r for r in self.spool_rows()}
        for name in ("retried", "untouched"):
            self.assertEqual("stale-dropped", rows[ids[name]]["status"], name)
            self.assertTrue(rows[ids[name]]["last_error"].startswith("age:"), name)
        self.assertEqual(3, rows[ids["retried"]]["attempts"])  # marked, not attempted
        # A second load finds nothing left to drain.
        self.ctx.calls.clear()
        self.assertEqual({}, self.drive(lambda: self.bridge.drain(self.adapter)))
        self.assertEqual([], self.ctx.calls)

    def test_drain_failure_keeps_rows_failed(self):
        self.legacy_spool([time.time() - 5])
        self.ctx = FakeCtx([False] * 3)
        self.install()
        result = self.drive(lambda: self.bridge.drain(self.adapter))
        self.assertEqual({"xsrc_legacy0": "inject_refused"}, result)
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
