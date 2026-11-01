"""STREAMHONEST: the chat door must refuse a foreign-surface session BEFORE a
run exists, so no run-failed event (and no operator notification) is produced.
"""
import asyncio
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT / "compat") not in sys.path:
    sys.path.insert(0, str(ROOT / "compat"))


class _Tx:
    def __init__(self):
        self.edits = []

    def set(self, target, name, value):
        self.edits.append((target, name, value))


class _Req:
    def __init__(self, body, sid="sess-1"):
        self._body = body
        self.match_info = {"session_id": sid} if sid else {}

    async def json(self):
        if self._body is None:
            raise ValueError("no body")
        return self._body


class _DB:
    def __init__(self, source):
        self.source = source

    def resolve_resume_session_id(self, sid):
        return sid

    def get_session(self, sid):
        return None if self.source is None else {"source": self.source}


def _install(source, *, body={"message": "hi"}, db_source="unset", sid="sess-1"):
    """Install the guard over a stub adapter; return (guarded_handler, calls)."""
    from compat import compat as compat_mod
    from gateway.platforms import api_server as api

    calls = []

    class Adapter:
        async def _handle_session_chat_stream(self, request, *a, **k):
            calls.append(request)
            return "NATIVE"

        async def _ensure_session_db_async(self):
            if db_source is None:
                return None
            return _DB(db_source if db_source != "unset" else source)

    adapter = Adapter()
    real = api.APIServerAdapter
    api.APIServerAdapter = Adapter
    try:
        tx = _Tx()
        compat_mod._foreign_stream_guard(tx)
        (_, _, guarded), = tx.edits
    finally:
        api.APIServerAdapter = real
    return asyncio.run(guarded(adapter, _Req(body, sid=sid))), calls


class ForeignStreamGuard(unittest.TestCase):
    def test_foreign_source_refused_without_touching_native(self):
        response, calls = _install("discord")
        self.assertEqual(getattr(response, "status", None), 502)
        self.assertIn(b"foreign_surface", response.body)
        self.assertEqual(calls, [])

    def test_api_server_session_passes_through(self):
        result, calls = _install("api_server")
        self.assertEqual(result, "NATIVE")
        self.assertEqual(len(calls), 1)

    def test_bot_room_session_passes_through(self):
        result, calls = _install("bot_room")
        self.assertEqual(result, "NATIVE")

    def test_wake_batch_lane_untouched(self):
        result, calls = _install("discord", body={"wake_batch": "b1", "message": "x"})
        self.assertEqual(result, "NATIVE")  # core's own lane keeps flowing
        self.assertEqual(len(calls), 1)

    def test_unknown_session_passes_through(self):
        result, calls = _install("discord", db_source=None)  # get_session → None
        self.assertEqual(result, "NATIVE")

    def test_no_session_id_passes_through(self):
        result, calls = _install("discord", sid=None)
        self.assertEqual(result, "NATIVE")  # not a session route: nothing to guard

    def test_unparsable_body_passes_through(self):
        result, calls = _install("discord", body=None)
        self.assertEqual(result, "NATIVE")

    def test_cron_source_refused_too(self):
        # core refuses the same set at the chat door; the guard mirrors it exactly.
        response, calls = _install("cron")
        self.assertEqual(getattr(response, "status", None), 502)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
