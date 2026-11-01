"""TASK-PROGRESSBRIDGE: live progress for app chat into a Discord session.

The stream route follows the injected turn on the session's canonical event
stream (core ``SessionEvents``: an observer plus the replay ring) and forwards
it in the session SSE vocabulary the app renders: ``message.started``,
``assistant.delta``, ``tool.started``, ``tool.completed``/``tool.failed``,
``assistant.completed``, ``run.<status>``, ``done``. Anything it cannot follow
(no authority, admission never seen, idle past the turn timeout, drifted seams)
answers the earlier ``run.queued`` + ``done`` handoff. A client that leaves
only drops the observer. Fakes come from test_crosssource.
"""
import asyncio
import os
import time
from unittest import mock

from test_crosssource import (DISCORD_KEY, DISCORD_SID, CrossSourceBase, FakeAuthority, FakeCtx, FakeLive,
                              ScriptedTurn, Tx)

from compat import crosssource

QUEUED = ["run.started", "run.queued", "done"]


def names(events):
    return [name for name, _ in events]


class LiveProgress(CrossSourceBase):
    def test_red_without_authority_the_stream_is_the_queued_handoff(self):
        self.install(authority_getter=lambda adapter: None)
        self.drive(self.stream("hi"))
        self.assertEqual(QUEUED, names(self.adapter.sinks[0].events()))

    def test_deltas_and_tools_arrive_in_order_with_their_payloads(self):
        self.follow_turn([("tool", "read_file", {"path": "/tmp/x"}, "ok", False), ("delta", "第一段"),
                          ("delta", "第二段")], response="第一段第二段")
        self.drive(self.stream("看一下"))
        events = self.adapter.sinks[0].events()
        self.assertEqual(["run.started", "message.started", "tool.started", "tool.completed", "assistant.delta",
                          "assistant.delta", "assistant.completed", "run.completed", "done"], names(events))
        started = events[2][1]
        self.assertEqual(("read_file", {"path": "/tmp/x"}), (started["tool_name"], started["args"]))
        self.assertIsInstance(started["preview"], str)
        self.assertEqual(["第一段", "第二段"], [p["delta"] for n, p in events if n == "assistant.delta"])
        message_id = events[1][1]["message"]["id"]
        self.assertEqual({message_id}, {p["message_id"] for n, p in events[2:8]})
        self.assertEqual([1, 2, 3, 4, 5, 6, 7, 8, 9], [p["seq"] for _, p in events])

    def test_live_entry_created_by_the_injection_is_replayed_from_the_ring(self):
        # The whole turn is published before the follow attaches: only the replay ring has it.
        self.follow_turn([("delta", "fast")], response="fast", sync=True)
        self.drive(self.stream("x"))
        self.assertEqual(["run.started", "message.started", "assistant.delta", "assistant.completed",
                          "run.completed", "done"], names(self.adapter.sinks[0].events()))

    def test_frames_before_the_send_and_of_other_admissions_are_not_forwarded(self):
        self.follow_turn([("other", "別人的"), ("delta", "mine"), ("other", "又是別人的")], response="mine")
        live = self.authority.sessions[DISCORD_SID] = FakeLive()
        # An earlier turn on the same session, complete before this send.
        live.event_stream.publish(DISCORD_SID, {"text": "舊的"}, event_type="message.delta",
                                  execution={"admission_id": self.turn.admission_id})
        self.drive(self.stream("x"))
        deltas = [p["delta"] for n, p in self.adapter.sinks[0].events() if n == "assistant.delta"]
        self.assertEqual(["mine"], deltas)

    def test_an_older_identical_pending_row_is_not_taken_for_this_send(self):
        self.follow_turn([("delta", "new")], response="new", sequence=7)
        live = self.authority.sessions[DISCORD_SID] = FakeLive()
        older = ScriptedTurn(self.authority, DISCORD_SID, [], sequence=3)
        from gateway.session_contract import PendingAdmission, SessionRef
        from test_crosssource import plugin_identity
        from dataclasses import asdict
        stale = PendingAdmission(admission_id=older.admission_id, ref=SessionRef("default", DISCORD_SID),
                                 sequence=3, status="queued", outcome=None, authority_epoch=1,
                                 execution_generation=None, input_id=plugin_identity(DISCORD_KEY), text="x")
        original = self.turn.run

        def run(content, identity):
            live.event_stream.publish(DISCORD_SID, {"pending": [asdict(stale)]}, event_type="session.info")
            original(content, identity)
        self.turn.run = run
        self.drive(self.stream("x"))
        self.assertEqual(["new"], [p["delta"] for n, p in self.adapter.sinks[0].events() if n == "assistant.delta"])

    def test_failed_tool_and_failed_turn_keep_their_status(self):
        self.follow_turn([("tool", "terminal", {"command": "false"}, "exit 1", True)], outcome="failed")
        self.drive(self.stream("x"))
        events = self.adapter.sinks[0].events()
        self.assertEqual(["run.started", "message.started", "tool.started", "tool.failed", "assistant.completed",
                          "run.failed", "done"], names(events))
        self.assertTrue(events[5][1]["error"])

    def test_cancelled_turn_is_run_cancelled(self):
        self.follow_turn([], outcome="interrupted")
        self.drive(self.stream("x"))
        self.assertIn("run.interrupted", names(self.adapter.sinks[0].events()))

    def test_admission_never_seen_answers_the_queued_handoff(self):
        # inject_message said True but the dispatch was refused later (live log: ``not_found``).
        self.authority = FakeAuthority()
        self.authority.sessions[DISCORD_SID] = FakeLive()
        self.ctx = FakeCtx([])
        self.install(authority_getter=lambda adapter: self.authority, admission_wait=0.2, keepalive=5)
        self.drive(self.stream("x"))
        self.assertEqual(QUEUED, names(self.adapter.sinks[0].events()))
        self.assertEqual(set(), self.authority.sessions[DISCORD_SID].event_stream.observers)

    def test_no_live_entry_ever_answers_the_queued_handoff(self):
        self.authority = FakeAuthority()
        self.ctx = FakeCtx([])
        self.install(authority_getter=lambda adapter: self.authority, admission_wait=0.2, keepalive=5)
        self.drive(self.stream("x"))
        self.assertEqual(QUEUED, names(self.adapter.sinks[0].events()))

    def test_idle_past_the_turn_timeout_answers_the_queued_handoff(self):
        self.follow_turn([("delta", "a"), ("pause", 1.5), ("delta", "late")])
        with mock.patch.dict(os.environ, {"HERMES_AGENT_TIMEOUT": "0.3"}):
            self.drive(self.stream("x"))
        self.turn.thread.join(5)
        events = names(self.adapter.sinks[0].events())
        self.assertEqual(["run.started", "message.started", "assistant.delta", "run.queued", "done"], events)

    def test_keepalive_comment_while_the_turn_is_quiet(self):
        self.authority = FakeAuthority()
        self.turn = ScriptedTurn(self.authority, DISCORD_SID, [("pause", 0.4), ("delta", "x")], response="x")
        self.ctx = FakeCtx([], on_inject=self.turn)
        self.install(authority_getter=lambda adapter: self.authority, admission_wait=2, keepalive=0.1)
        self.drive(self.stream("x"))
        raw = self.adapter.sinks[0].frames
        self.assertIn(b": keepalive\n\n", raw)
        self.assertEqual("done", names(self.adapter.sinks[0].events())[-1])

    def test_resend_folded_into_a_delivered_row_does_not_wait_for_a_turn(self):
        self.follow_turn([("delta", "once")], response="once")
        self.drive(self.stream("same"))
        self.turn.thread.join(5)
        started = time.monotonic()
        self.drive(self.stream("same"))
        # No turn to wait for: answered at once, not after the 2 s admission wait.
        self.assertLess(time.monotonic() - started, 1.0)
        self.assertEqual(1, len(self.ctx.calls))
        self.assertEqual(QUEUED, names(self.adapter.sinks[1].events()))

    def test_turn_timeout_reads_the_gateway_setting(self):
        cases = {None: 1800.0, "": 1800.0, "junk": 1800.0, "0": None, "-1": None, "600": 600.0}
        for raw, expected in cases.items():
            env = {} if raw is None else {"HERMES_AGENT_TIMEOUT": raw}
            with mock.patch.dict(os.environ, env, clear=False):
                if raw is None:
                    os.environ.pop("HERMES_AGENT_TIMEOUT", None)
                self.assertEqual(expected, crosssource.turn_timeout(), raw)


class ClientLeaves(CrossSourceBase):
    """The SSE client leaving ends only the projection; the observer is dropped and the turn,
    which belongs to the Discord session, is never touched."""

    def test_write_failure_mid_follow_detaches_quietly(self):
        self.follow_turn([("delta", "a"), ("pause", 0.2), ("delta", "b"), ("delta", "c")], response="abc")
        sinks = []
        original = self.cls._prepare_sse_response

        async def prepare(adapter, request, session_id, key):
            sink = await original(adapter, request, session_id, key)
            writes = {"n": 0}
            real = sink.write

            async def write(data):
                writes["n"] += 1
                if writes["n"] == 3:
                    raise ConnectionResetError("client gone")
                await real(data)
            sink.write = write
            sinks.append(sink)
            return sink
        self.cls._prepare_sse_response = prepare
        response = self.drive(self.stream("x"))
        self.assertIs(sinks[0], response)
        self.assertEqual(["run.started", "message.started"], names(sinks[0].events()))
        self.assertEqual(set(), self.authority.sessions[DISCORD_SID].event_stream.observers)
        self.turn.thread.join(5)
        self.assertFalse(self.turn.thread.is_alive())

    def test_cancelled_request_task_detaches_and_reraises(self):
        self.follow_turn([("delta", "a"), ("pause", 5), ("delta", "never")])

        async def go():
            task = asyncio.ensure_future(self.stream("x")())
            for _ in range(200):
                await asyncio.sleep(0.01)
                if b"assistant.delta" in (self.adapter.sinks[0].frames if self.adapter.sinks else b""):
                    break
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
        self.drive(go)
        self.assertEqual(set(), self.authority.sessions[DISCORD_SID].event_stream.observers)
        self.assertEqual(["run.started", "message.started", "assistant.delta"],
                         names(self.adapter.sinks[0].events()))


class SeamDrift(CrossSourceBase):
    def test_seams_hold_on_this_core(self):
        self.assertIsNone(crosssource.check_progress_seams())

    def test_drifted_frame_contract_is_named(self):
        from gateway.session_authority import SessionAuthority
        real = crosssource.inspect.getsource

        def fake(func):
            text = real(func)
            return text.replace("input_id=row['request_id']", "input_id=row['id']") \
                if func is SessionAuthority._pending_receipt else text
        with mock.patch.object(crosssource.inspect, "getsource", fake):
            reason = crosssource.check_progress_seams()
        self.assertIn("_pending_receipt", reason)

    def test_missing_observer_set_is_named(self):
        from gateway import session_events
        original = session_events.SessionEvents.__init__

        def init(self):
            original(self)
            del self.observers
        with mock.patch.object(session_events.SessionEvents, "__init__", init):
            self.assertEqual("SessionEvents.observers", crosssource.check_progress_seams())

    def test_compat_logs_drift_loudly_and_keeps_the_queued_handoff(self):
        from compat import compat as c
        from gateway.platforms import api_server
        state = {"groups": {}, "manifest": {}}
        installed = {}

        def fake_install(api, cls, tx, **kw):
            installed.update(kw)
            return "bridge"
        holder = type("api", (), {"APIServerAdapter": api_server.APIServerAdapter,
                                  "_error_response": staticmethod(lambda *a, **k: None),
                                  "_sse_frame": staticmethod(lambda *a, **k: b"")})()
        setattr(holder, c._STATE, state)
        with mock.patch.object(c, "api", holder, create=True), \
                mock.patch.object(crosssource, "check_progress_seams", return_value="SessionEvents.since"), \
                mock.patch.object(crosssource, "install", fake_install), \
                self.assertLogs("hermes-app-compat", level="ERROR") as logs:
            c._install_crosssource(Tx())
        self.assertFalse(installed["progress"])
        self.assertEqual({"status": "disabled", "reason": "SessionEvents.since"}, state["crosssource_progress"])
        self.assertIn("CROSSSOURCE PROGRESS DISABLED", logs.output[0])

    def test_progress_off_streams_the_queued_handoff_even_with_an_authority(self):
        self.authority = FakeAuthority()
        self.turn = ScriptedTurn(self.authority, DISCORD_SID, [("delta", "x")], response="x")
        self.ctx = FakeCtx([], on_inject=self.turn)
        self.install(authority_getter=lambda adapter: self.authority, progress=False)
        self.drive(self.stream("x"))
        self.turn.thread.join(5)
        self.assertEqual(QUEUED, names(self.adapter.sinks[0].events()))
