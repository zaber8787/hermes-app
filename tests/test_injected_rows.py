"""TASK-RENDERPARITY: app text injected into a Discord session projects as a user turn.

crosssource.py injects app chat into a Discord session; core persists that row
with ``display_kind='internal_notification'`` and the thread's sender prefix,
so the app drew an "internal notice" chip and the reply as run narration. The
injected_rows unit fixes the row on the ``_message_response`` projection.

Rows live in a real SessionDB tmp file. The base projection is a stand-in with
core's ``_message_response`` field whitelist (``SAFE_KEYS``, pinned against
core's source below): core's own function lazily imports
``agent.conversation_loop`` for a user row, which imports ``hermes_bootstrap``,
and that module re-execs the interpreter (``os.execv``) outside a gateway
process. The real class is still wired and restored in ``Wiring``. Admissions
are written into the tmp file's own ``session_admissions`` table in the shape
core commits for a plugin turn; the owner core stamps on the turn's user row is
computed by executing the owner lines of core's ``_hmwa_prepare_turn`` itself
(``core_owner``), never by this unit's own formula.
"""
import inspect
import json
import logging
import os
import pathlib
import shutil
import sqlite3
import tempfile
import textwrap
import time
import unittest
import uuid
from unittest import mock

from compat import injected_rows

DISCORD_SID = "20260101_000000_disc0001"
API_SID = "api_1700000000_api00001"
THREAD = "1500000000000000001"
GUILD = "1400000000000000001"
DISCORD_KEY = f"agent:main:discord:thread:{THREAD}:{THREAD}"


class Tx:
    def __init__(self):
        self.changes = []

    def set(self, target, name, value):
        self.changes.append((target, name, target.__dict__[name]))
        setattr(target, name, value)

    def restore(self):
        for target, name, value in reversed(self.changes):
            setattr(target, name, value)
        self.changes = []


def discord_source(**over):
    from gateway.config import Platform
    from gateway.session import SessionSource
    fields = dict(platform=Platform.DISCORD, chat_id=THREAD, chat_type="thread", user_id="7000",
                  user_name="zaber", thread_id=THREAD, scope_id=GUILD)
    fields.update(over)
    return SessionSource(**fields)


def core_owner(source, message_id):
    """The owner core's ``_hmwa_prepare_turn`` mints, run from its own source lines."""
    from gateway.run_turn_prepare import GatewayTurnPrepareMixin
    text = inspect.getsource(GatewayTurnPrepareMixin._hmwa_prepare_turn)
    start = text.rindex("\n", 0, text.index("namespace = [source.platform.value")) + 1
    end = text.index("if event.message_id else str(uuid.uuid4()))") + len("if event.message_id else str(uuid.uuid4()))")
    scope = {"source": source, "event": type("E", (), {"message_id": message_id})(), "uuid": uuid, "json": json}
    exec(textwrap.dedent(text[start:end]), scope)
    return scope["owner"]


# core gateway/platforms/api_server.py ``_message_response`` safe_keys.
SAFE_KEYS = ("id", "session_id", "role", "content", "tool_call_id", "tool_calls", "tool_name",
             "timestamp", "token_count", "finish_reason", "reasoning", "reasoning_content", "display_kind")


def make_adapter_class():
    def message(row):
        return {key: row.get(key) for key in SAFE_KEYS if key in row}
    return type("Adapter", (), {"_message_response": staticmethod(message)})


def plugin_identity(plugin=injected_rows.PLUGIN_ID, key=DISCORD_KEY):
    return json.dumps(["plugin", plugin, key, uuid.uuid4().hex], separators=(",", ":"))


class Base(unittest.TestCase):
    def setUp(self):
        from hermes_state import SessionDB
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.db_path = self.tmp / "state.db"
        self.db = SessionDB(self.db_path)
        self.db.create_session(DISCORD_SID, "discord", session_key=DISCORD_KEY, chat_id=THREAD, thread_id=THREAD)
        self.db.create_session(API_SID, "api_server")
        self.cls = make_adapter_class()
        self.native = self.cls.__dict__["_message_response"]
        self.tx = Tx()

    def tearDown(self):
        self.tx.restore()
        self.assertIs(self.native, self.cls.__dict__["_message_response"])
        self.db.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def install(self):
        return injected_rows.install(self.cls, self.tx, self.db_path)

    def admit(self, text, *, plugin=injected_rows.PLUGIN_ID, source=None):
        """One committed plugin admission (core's payload shape); returns the turn's owner."""
        source = source or discord_source()
        identity = plugin_identity(plugin)
        payload = {"text": text, "native_text_v1": {
            "source": source.to_dict(), "route": DISCORD_KEY,
            "event": {"message_id": identity}, "timestamp": "1970-01-01T00:00:00+00:00",
            "automation": {"identity": identity, "owner": DISCORD_SID}}}
        with sqlite3.connect(self.db_path) as conn:
            conn.execute(
                "INSERT INTO session_admissions(admission_id, request_id, principal_id, target_session_id, "
                "lineage_json, payload_json, payload_digest, intent, status, outcome) "
                "VALUES (?,?,?,?,?,?,?,?,?,?)",
                (uuid.uuid4().hex, identity, f"automation:{DISCORD_KEY}", DISCORD_SID, "[]",
                 json.dumps(payload), "0" * 64, "queue", "terminal", "completed"))
        return core_owner(source, identity)

    def turn(self, sid, user_text, *, display_kind=None, metadata=None, reply="done: https://example.org"):
        """The same exchange in any session: user, a tool call, its result, the final reply.

        Plain SQL: ``SessionDB.append_message`` on a user row reaches the same bootstrap import."""
        call = {"id": f"call_{uuid.uuid4().hex[:8]}", "type": "function",
                "function": {"name": "terminal", "arguments": "{\"command\": \"date\"}"}}
        rows = [("user", user_text, None, None, None, display_kind, json.dumps(metadata) if metadata else None, None),
                ("assistant", "", json.dumps([call]), None, None, None, None, None),
                ("tool", "{\"output\": \"Sun\"}", None, call["id"], "terminal", None, None, None),
                ("assistant", reply, None, None, None, None, None, "stop")]
        with sqlite3.connect(self.db_path) as conn:
            for role, content, calls, call_id, tool, kind, meta, finish in rows:
                conn.execute(
                    "INSERT INTO messages(session_id, role, content, tool_calls, tool_call_id, tool_name, "
                    "display_kind, display_metadata, finish_reason, timestamp) VALUES (?,?,?,?,?,?,?,?,?,?)",
                    (sid, role, content, calls, call_id, tool, kind, meta, finish, time.time()))

    def project(self, sid):
        return [self.cls._message_response(m) for m in self.db.get_messages(sid)]

    def injected_turn(self, text="test from app"):
        owner = self.admit(text)
        self.turn(DISCORD_SID, f"[zaber] {text}", display_kind="internal_notification",
                  metadata={"gateway_input_owner": owner})
        return owner


def shape(rows):
    """What the app's projection reads off a row (ids and timestamps aside)."""
    return [(r.get("role"), r.get("display_kind"), r.get("content"),
             [c["function"]["name"] for c in r.get("tool_calls") or ()], r.get("tool_name"))
            for r in rows]


class ParityRedGreen(Base):
    """Same exchange fed to a Discord session (via injection) and to an api_server session."""

    def test_red_without_unit_injected_turn_diverges(self):
        self.injected_turn()
        self.turn(API_SID, "test from app")
        disc, api = self.project(DISCORD_SID), self.project(API_SID)
        self.assertNotEqual(shape(api), shape(disc))
        self.assertEqual(("user", "internal_notification", "[zaber] test from app"), shape(disc)[0][:3])

    def test_green_with_unit_injected_turn_matches_api_server(self):
        self.install()
        self.injected_turn()
        self.turn(API_SID, "test from app")
        disc, api = self.project(DISCORD_SID), self.project(API_SID)
        self.assertEqual(shape(api), shape(disc))
        self.assertEqual(("user", None, "test from app"), shape(disc)[0][:3])
        self.assertEqual(set(api[0]) | {injected_rows.PROVENANCE_KEY}, set(disc[0]))
        prov = disc[0][injected_rows.PROVENANCE_KEY]
        self.assertEqual((1, "internal_notification"), (prov["schema"], prov["display_kind"]))
        with sqlite3.connect(self.db_path) as conn:
            stored = conn.execute("SELECT display_kind, content FROM messages WHERE session_id=? AND role='user'",
                                  (DISCORD_SID,)).fetchone()
        self.assertEqual(("internal_notification", "[zaber] test from app"), stored)  # storage untouched

    def test_no_internal_notice_on_the_injection_path_across_turns(self):
        self.install()
        for text in ("first", "second", "third"):
            self.injected_turn(text)
        rows = self.project(DISCORD_SID)
        self.assertEqual([], [r for r in rows if r.get("display_kind") == "internal_notification"])
        self.assertEqual(["first", "second", "third"], [r["content"] for r in rows if r["role"] == "user"])

    def test_owner_from_profiled_source_matches(self):
        self.install()
        owner = self.admit("hi", source=discord_source(profile="work"))
        self.turn(DISCORD_SID, "[zaber] hi", display_kind="internal_notification",
                  metadata={"gateway_input_owner": owner})
        self.assertEqual(("user", None, "hi"), shape(self.project(DISCORD_SID))[0][:3])

    def test_admission_after_first_read_is_found(self):
        self.install()
        self.injected_turn("one")
        self.project(DISCORD_SID)
        self.injected_turn("two")
        self.assertEqual(["one", "two"], [r["content"] for r in self.project(DISCORD_SID) if r["role"] == "user"])


class RedLines(Base):
    """Rows the unit must leave byte-identical."""

    def both(self, sid):
        before = self.project(sid)
        self.install()
        return before, self.project(sid)

    def test_pure_discord_turn_unchanged(self):
        source = discord_source()
        self.turn(DISCORD_SID, "[zaber] typed in discord",
                  metadata={"gateway_input_owner": core_owner(source, "1500000000000000999")})
        before, after = self.both(DISCORD_SID)
        self.assertEqual(before, after)
        self.assertIsNone(after[0]["display_kind"])

    def test_api_server_turn_unchanged(self):
        self.turn(API_SID, "hello")
        before, after = self.both(API_SID)
        self.assertEqual(before, after)

    def test_cron_and_wake_rows_keep_internal_notification(self):
        cron_meta = {"hermes_app_cron": {"schema": 1, "job_id": "j"}, "gateway_input_owner": str(uuid.uuid4())}
        self.turn(DISCORD_SID, "[Cron report: watch]\nCronjob Response:", display_kind="internal_notification",
                  metadata=cron_meta)
        self.turn(DISCORD_SID, "[zaber] [IMPORTANT: Background process done]",
                  display_kind="internal_notification", metadata={"gateway_input_owner": str(uuid.uuid4())})
        self.admit("unrelated")  # an admission exists, it is just not theirs
        before, after = self.both(DISCORD_SID)
        self.assertEqual(before, after)
        self.assertEqual(2, sum(r.get("display_kind") == "internal_notification" for r in after))

    def test_other_plugin_admission_is_not_ours(self):
        owner = self.admit("from another plugin", plugin="some-other-plugin")
        self.turn(DISCORD_SID, "[zaber] from another plugin", display_kind="internal_notification",
                  metadata={"gateway_input_owner": owner})
        before, after = self.both(DISCORD_SID)
        self.assertEqual(before, after)


class DriftSelfCheck(Base):
    def test_check_passes_on_this_core(self):
        injected_rows.check()

    def test_owner_formula_equals_core(self):
        source = discord_source(profile="p1")
        identity = plugin_identity()
        payload = {"native_text_v1": {"source": source.to_dict(), "event": {"message_id": identity}}}
        self.assertEqual(core_owner(source, identity), injected_rows.owner_of(payload))

    def test_drifted_seam_skips_loudly_and_keeps_native(self):
        from compat import compat as c
        real = inspect.getsource

        def drifted(obj):
            text = real(obj)
            return text.replace("message_id=identity", "message_id=other")
        holder = type("api", (), {"APIServerAdapter": self.cls})()
        with mock.patch.object(c, "api", holder, create=True), \
                mock.patch.object(injected_rows.inspect, "getsource", drifted), \
                self.assertLogs("hermes-app-compat", logging.ERROR) as logs, \
                self.assertRaises(RuntimeError):
            c._install_injected_rows(self.tx)
        self.assertIn("RENDERPARITY DISABLED", logs.output[0])
        self.assertIn("message_id=identity", logs.output[0])
        self.assertEqual([], self.tx.changes)
        self.assertIs(self.native, self.cls.__dict__["_message_response"])

    def test_admissions_schema_drift_logs_once_and_keeps_native(self):
        self.install()
        owner = self.injected_turn()
        with sqlite3.connect(self.db_path) as conn:
            conn.execute("ALTER TABLE session_admissions RENAME COLUMN payload_json TO payload_v2")
        with self.assertLogs("hermes-app-compat.injected_rows", logging.ERROR) as logs:
            rows = self.project(DISCORD_SID)
            self.project(DISCORD_SID)
        self.assertEqual("internal_notification", rows[0]["display_kind"])
        self.assertEqual(1, len(logs.output))
        self.assertIn("RENDERPARITY DEGRADED", logs.output[0])
        self.assertTrue(owner)


class Wiring(unittest.TestCase):
    def test_stand_in_keeps_core_safe_keys(self):
        from gateway.platforms import api_server
        text = inspect.getsource(api_server.APIServerAdapter._message_response)
        body = text[text.index("safe_keys = ("):text.index(")", text.index("safe_keys = ("))]
        self.assertEqual(set(SAFE_KEYS), set(json.loads("[" + body.split("(", 1)[1].replace("\n", " ") + "]")))

    def test_unit_registered_and_shipped(self):
        from compat import compat as c
        self.assertIn("injected_rows", c.UNITS)
        self.assertLess(c.UNITS.index("injected_rows"), c.UNITS.index("crosssource"))
        script = (pathlib.Path(injected_rows.__file__).parent / "install.sh").read_text()
        self.assertIn("injected_rows.py", script)

    def test_install_and_restore_on_real_api_server(self):
        from compat import compat as c
        from gateway.platforms import api_server
        cls = api_server.APIServerAdapter
        before = cls.__dict__["_message_response"]
        home = tempfile.mkdtemp()
        saved = (getattr(c, "api", None), os.environ.get("HERMES_HOME"))
        os.environ["HERMES_HOME"] = home
        c.api = api_server
        tx = c.Transaction()
        try:
            c._install_injected_rows(tx)
            self.assertIsNot(before, cls.__dict__["_message_response"])
        finally:
            tx.restore()
            c.api = saved[0]
            if saved[1] is None:
                os.environ.pop("HERMES_HOME", None)
            else:
                os.environ["HERMES_HOME"] = saved[1]
            shutil.rmtree(home, ignore_errors=True)
        self.assertIs(before, cls.__dict__["_message_response"])


if __name__ == "__main__":
    unittest.main()
