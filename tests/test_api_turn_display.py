"""TASK-DISPLAYKIND: a person's HTTP turn persists as a user row, not an internal notification.

Core marks every API admission ``event.internal = True`` for trust
(gateway/session_ingress.py, ``execute_admission``), and ``display_kind_for_event``
reads the same flag as "self-injected", so the owner's own chat/stream text lands
as ``display_kind='internal_notification'``. The api_turn_display unit overrides
the kind only; the trust flag and every machinery row keep core's behaviour.

``EndToEnd`` is the real thing: ``python -m gateway.run`` in a tmp HERMES_HOME with
this plugin copied in, a loopback stub model, and the routes the app calls.
"""
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest import mock
import urllib.error
import urllib.request

from compat import api_turn_display

ROOT = Path(__file__).resolve().parent.parent
CORE = Path.home() / ".hermes" / "hermes-agent"
# Appended, not prepended: core's own ``tests`` package must not shadow this one.
if str(CORE) not in sys.path:
    sys.path.append(str(CORE))
KEY = "loopback-probe-only-key-0123456789abcdef"
KIND = "internal_notification"


class Tx:
    def __init__(self):
        self.changes = []

    def set(self, target, name, value):
        self.changes.append((target, name, getattr(target, name)))
        setattr(target, name, value)

    def restore(self):
        for target, name, value in reversed(self.changes):
            setattr(target, name, value)


def api_payload(**over):
    data = {"history": None, "settings": {"room_dispatch": None}}
    data.update(over)
    return {"text": "hi", "api_turn_v1": data}


class Unit(unittest.TestCase):
    """The decision table, on core's real ``display_kind_for_event``."""

    def setUp(self):
        import gateway.response_filters as filters
        import gateway.session_api_turn as turn
        self.filters, self.turn = filters, turn
        self.tx = Tx()
        self.addCleanup(self.tx.restore)
        # core's preparation needs a live adapter; the unit only decorates its result.
        patcher = mock.patch.object(turn, "prepare_api_execution", lambda authority, ref, payload: {"settings": {}})
        patcher.start()
        self.addCleanup(patcher.stop)
        api_turn_display.install(self.tx)
        self.authority = SimpleNamespace(sessions={"s": SimpleNamespace(
            event_stream=SimpleNamespace(execution={"admission_id": "adm-1"}))})

    def kind(self, payload, event=None):
        event = event or SimpleNamespace(internal=True, message_id="adm-1", metadata={})
        prepared = self.turn.prepare_api_execution(self.authority, SimpleNamespace(session_id="s"), payload)
        token = self.turn.api_execution.set(prepared)
        try:
            return self.filters.display_kind_for_event(event)
        finally:
            self.turn.api_execution.reset(token)

    def test_http_turn_has_no_kind(self):
        self.assertIsNone(self.kind(api_payload()))

    def test_trust_flag_is_left_alone(self):
        event = SimpleNamespace(internal=True, message_id="adm-1", metadata={})
        self.kind(api_payload(), event)
        self.assertIs(event.internal, True)

    def test_person_authored_turn_has_no_kind(self):
        self.assertIsNone(self.kind(api_payload(turn_author={"id": "u", "name": "U", "is_bot": False})))

    def test_automation_row_in_an_api_session_keeps_the_stamp(self):
        for payload in ({"text": "t", "local_automation_v1": {}}, {"text": "t", "native_text_v1": {"automation": {}}}):
            self.assertEqual(KIND, self.kind(payload))

    def test_peer_bot_and_room_lanes_keep_the_stamp(self):
        self.assertEqual(KIND, self.kind(api_payload(turn_author={"id": "b", "name": "B", "is_bot": True})))
        self.assertEqual(KIND, self.kind(api_payload(settings={"room_dispatch": {"task_id": "t"}})))

    def test_another_event_on_the_same_task_keeps_the_stamp(self):
        stray = SimpleNamespace(internal=True, message_id="other", metadata={})
        self.assertEqual(KIND, self.kind(api_payload(), stray))

    def test_heartbeat_keeps_the_stamp(self):
        event = SimpleNamespace(internal=False, message_id="adm-1", metadata={}, _heartbeat_session_id="s")
        self.assertEqual(KIND, self.kind(api_payload(), event))

    def test_outside_an_api_execution_nothing_changes(self):
        self.assertEqual(KIND, self.filters.display_kind_for_event(
            SimpleNamespace(internal=True, message_id="adm-1", metadata={})))
        self.assertIsNone(self.filters.display_kind_for_event(
            SimpleNamespace(internal=False, message_id="adm-1", metadata={})))

    def test_unbound_execution_fails_back_to_core(self):
        self.authority.sessions["s"].event_stream.execution = {}
        self.assertEqual(KIND, self.kind(api_payload()))


class Seams(unittest.TestCase):
    def test_core_seams_are_where_the_unit_expects(self):
        api_turn_display.check()

    def test_drift_refuses_install(self):
        tx = Tx()
        self.addCleanup(tx.restore)
        with mock.patch.object(api_turn_display.inspect, "getsource", lambda _: "drifted"):
            with self.assertRaises(RuntimeError):
                api_turn_display.install(tx)
        self.assertEqual([], tx.changes)

    def test_unit_is_wired_and_shipped(self):
        source = (ROOT / "compat" / "compat.py").read_text()
        self.assertIn('"api_turn_display"', source)
        self.assertIn("def _install_api_turn_display(tx):", source)
        self.assertIn('"$source_dir/api_turn_display.py"', (ROOT / "compat" / "install.sh").read_text())


class StubModel(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        message = {"role": "assistant", "content": "ack"}
        if body.get("stream"):
            kind = "text/event-stream"
            payload = ("data: " + json.dumps({"id": "l", "choices": [
                {"index": 0, "delta": message, "finish_reason": "stop"}]}) + "\n\ndata: [DONE]\n\n").encode()
        else:
            kind = "application/json"
            payload = json.dumps({"id": "l", "choices": [{"index": 0, "message": message, "finish_reason": "stop"}],
                                  "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


class EndToEnd(unittest.TestCase):
    def test_chat_stream_user_row_has_null_display_kind(self):
        tmp = Path(tempfile.mkdtemp(prefix="dkkind", dir="/tmp"))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        home, user = tmp / "state", tmp / "user"
        home.mkdir(mode=0o700)
        user.mkdir()
        model = http.server.ThreadingHTTPServer(("127.0.0.1", 0), StubModel)
        threading.Thread(target=model.serve_forever, daemon=True).start()
        self.addCleanup(model.server_close)
        self.addCleanup(model.shutdown)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        base = f"http://127.0.0.1:{model.server_port}/v1"
        shutil.copytree(ROOT / "compat", home / "plugins" / "hermes-app-compat",
                        ignore=shutil.ignore_patterns("__pycache__", "tests"))
        (home / "config.yaml").write_text(json.dumps({
            "model": {"provider": "custom", "default": "stub", "base_url": base},
            "gateway": {"platforms": {"api_server": {"enabled": True, "port": port, "host": "127.0.0.1"}},
                        "multiplex_profiles": False},
            "auxiliary": {"title_generation": {"enabled": False}}, "terminal": {"cwd": str(home)},
            "platform_toolsets": {"api_server": []}, "approvals": {"mode": "manual"},
            "plugins": {"enabled": ["hermes-app-compat"]}}))
        env = {k: os.environ[k] for k in ("PATH", "LANG", "TZ") if k in os.environ}
        env.update(HOME=str(user), HERMES_HOME=str(home), PYTHONPATH=str(CORE), OPENAI_API_KEY="loopback-only",
                   OPENAI_BASE_URL=base, API_SERVER_KEY=KEY, API_SERVER_ENABLED="true",
                   API_SERVER_PORT=str(port), PYTHONUNBUFFERED="1")
        with (home / "daemon.log").open("w+") as out:
            proc = subprocess.Popen([sys.executable, "-m", "gateway.run"], cwd=CORE, env=env,
                                    stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT)
            self.addCleanup(proc.wait, 10)
            self.addCleanup(proc.kill)
            url = f"http://127.0.0.1:{port}"

            def call(path, body):
                request = urllib.request.Request(url + path, json.dumps(body).encode(), {
                    "Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
                with urllib.request.urlopen(request, timeout=60) as response:
                    return response.status, response.read().decode()
            deadline = time.monotonic() + 120
            while True:
                self.assertIsNone(proc.poll(), "daemon exited")
                try:
                    status, created = call("/api/sessions", {})
                    break
                except (urllib.error.URLError, ConnectionError):
                    self.assertLess(time.monotonic(), deadline, "daemon never served HTTP")
                    time.sleep(.2)
            self.assertEqual(201, status)
            created = json.loads(created)
            sid = created.get("session", created)["id"]
            status, stream = call(f"/api/sessions/{sid}/chat/stream", {"input": "HUMAN_TURN"})
            self.assertEqual(200, status)
            self.assertIn("event: run.completed", stream)
            db = sqlite3.connect(f"file:{home / 'state.db'}?mode=ro", uri=True)
            self.addCleanup(db.close)
            rows = db.execute("SELECT content, display_kind FROM messages WHERE session_id=? AND role='user'",
                              (sid,)).fetchall()
        self.assertEqual([("HUMAN_TURN", None)], rows)


if __name__ == "__main__":
    unittest.main()
