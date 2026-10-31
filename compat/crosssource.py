"""TASK-CROSSSOURCE: app chat into a foreign-source (Discord) session.

Core refuses an API turn aimed at a foreign-surface session
(gateway/session_api_turn.py:216 ``permission_denied``). This unit wraps the two
session chat routes. A target whose source is in ``PLATFORMS`` is handed to the
core plugin injection seam (``PluginContext.inject_message`` with the session's
own ``session_key``, gateway/run_plugin_injection.py): the session's live
platform adapter admits it into the durable FIFO and runs it, so the reply goes
back to the original thread through the normal platform send path. Every other
target, a missing session and every wake batch stay on the native path.

Resilience: the text is spooled (SQLite, plugin-owned file) before the first
attempt. An attempt fails when the plugin context is missing, the platform
adapter is not connected (rejected bot token, Discord API down), or the host
refuses or raises. At most ``MAX_ATTEMPTS`` attempts; a final failure answers
HTTP 502 ``kind=bridge_unavailable`` with the spool id, and the row keeps the
text with ``status='failed'``.

No core file is written, no admission or whitelist is bypassed: the injection
seam keeps its own gates (``allow_gateway_injection`` in the plugin's profile
config, profile ownership, current chat authorization).
"""
from __future__ import annotations

import asyncio
from contextlib import closing
from functools import wraps
import json
import logging
from pathlib import Path
import sqlite3
import time
import uuid

log = logging.getLogger("hermes-app-compat.crosssource")

# Sources this bridge serves. Other foreign sources keep the native refusal.
PLATFORMS = frozenset({"discord"})
MAX_ATTEMPTS = 3
# Sleeps between attempts 1->2 and 2->3.
BACKOFF_SECONDS = (0.5, 1.5)
VIA_APP_MARK = "[經 Hermes App 代發]"
KIND = "bridge_unavailable"

_SCHEMA = """
CREATE TABLE IF NOT EXISTS outbox (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    session_key TEXT NOT NULL,
    platform TEXT NOT NULL,
    text TEXT NOT NULL,
    status TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
)
"""


class Outbox:
    """Durable per-message record. ``pending`` -> ``accepted`` | ``failed``."""

    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with closing(self._connect()) as conn, conn:
            conn.execute(_SCHEMA)

    def _connect(self):
        conn = sqlite3.connect(self.path, timeout=5)
        conn.row_factory = sqlite3.Row
        return conn

    def enqueue(self, *, session_id, session_key, platform, text):
        row_id = f"xsrc_{uuid.uuid4().hex}"
        now = time.time()
        with closing(self._connect()) as conn, conn:
            conn.execute(
                "INSERT INTO outbox(id, session_id, session_key, platform, text, status, attempts, "
                "created_at, updated_at) VALUES (?,?,?,?,?,'pending',0,?,?)",
                (row_id, session_id, session_key, platform, text, now, now))
        return row_id

    def record(self, row_id, *, attempts, status, error=None):
        with closing(self._connect()) as conn, conn:
            conn.execute("UPDATE outbox SET attempts=?, status=?, last_error=?, updated_at=? WHERE id=?",
                         (attempts, status, error, time.time(), row_id))

    def rows(self):
        with closing(self._connect()) as conn:
            return [dict(r) for r in conn.execute("SELECT * FROM outbox ORDER BY created_at")]


class Bridge:
    def __init__(self, outbox, ctx_getter, sleep=asyncio.sleep):
        self.outbox = outbox
        self.ctx_getter = ctx_getter
        self.sleep = sleep

    @staticmethod
    def platform_adapter(api_adapter, platform):
        from gateway.config import Platform
        runner = getattr(api_adapter, "gateway_runner", None)
        adapters = getattr(runner, "adapters", None) or {}
        try:
            return adapters.get(Platform(platform))
        except ValueError:
            return None

    def _attempt(self, api_adapter, platform, session_key, text):
        """One delivery attempt; ``None`` on success, else the failure reason."""
        ctx = self.ctx_getter()
        if ctx is None or not callable(getattr(ctx, "inject_message", None)):
            return "plugin_context_missing"
        target = self.platform_adapter(api_adapter, platform)
        if target is None or not getattr(target, "is_connected", False):
            return "platform_disconnected"
        try:
            accepted = ctx.inject_message(text, session_key=session_key)
        except Exception as exc:
            log.warning("crosssource inject raised: %s", type(exc).__name__)
            return "inject_error"
        return None if accepted else "inject_refused"

    async def deliver(self, api_adapter, session, text):
        """Spool, then up to MAX_ATTEMPTS attempts. Returns ``(row_id, error)``."""
        platform, session_key = session["source"], session["session_key"]
        row_id = await asyncio.to_thread(self.outbox.enqueue, session_id=session["id"],
                                         session_key=session_key, platform=platform, text=text)
        error = None
        for attempt in range(1, MAX_ATTEMPTS + 1):
            error = self._attempt(api_adapter, platform, session_key, text)
            final = error is None or attempt == MAX_ATTEMPTS
            status = "accepted" if error is None else ("failed" if final else "pending")
            await asyncio.to_thread(self.outbox.record, row_id, attempts=attempt, status=status, error=error)
            if error is None:
                log.info("crosssource %s accepted for %s session %s (attempt %d)",
                         row_id, platform, session["id"], attempt)
                return row_id, None
            log.warning("crosssource %s attempt %d/%d failed: %s", row_id, attempt, MAX_ATTEMPTS, error)
            if not final:
                await self.sleep(BACKOFF_SECONDS[attempt - 1])
        return row_id, error


def _foreign(session):
    return (session.get("source") in PLATFORMS and isinstance(session.get("session_key"), str)
            and session["session_key"].strip() != "")


def install(api, cls, tx, *, ctx_getter, spool_path, sleep=asyncio.sleep):
    """Wrap ``cls._handle_session_chat`` and ``cls._handle_session_chat_stream``."""
    bridge = Bridge(Outbox(spool_path), ctx_getter, sleep)
    old_chat = cls._handle_session_chat
    old_stream = cls._handle_session_chat_stream

    async def route(self, request):
        """``(session, text)`` for a bridged target, ``None`` to stay native, or a Response."""
        auth_err = self._check_auth(request)
        if auth_err is not None:
            return auth_err
        session, err = await self._get_existing_session_or_404(request.match_info["session_id"])
        if err is not None or not _foreign(session):
            return None
        body, err = await self._read_json_body(request)
        if err is not None or not isinstance(body, dict) or body.get("wake_batch"):
            return None
        draining = self._draining_response()
        if draining is not None:
            return draining
        raw = body.get("message") or body.get("input")
        if not isinstance(raw, str):
            return api._error_response(
                "Only text can be sent to a %s session from the app." % session["source"], 415,
                code="crosssource_text_only")
        if not raw.strip():
            return api._error_response("Missing 'message' field", 400, code="missing_message")
        return session, raw

    def unavailable(session, row_id, error):
        response = api._error_response(
            "%s bridge unavailable (%s); the message is kept as %s." % (session["source"], error, row_id),
            502, err_type=KIND, code=KIND)
        payload = json.loads(response.body)
        payload.update(kind=KIND, reason=error, delivery_id=row_id, via=session["source"])
        return api.web.json_response(payload, status=502)

    def content(raw):
        return f"{raw}\n\n{VIA_APP_MARK}"

    @wraps(old_chat)
    async def chat(self, request, *args, **kwargs):
        routed = await route(self, request)
        if routed is None:
            return await old_chat(self, request, *args, **kwargs)
        if not isinstance(routed, tuple):
            return routed
        session, raw = routed
        row_id, error = await bridge.deliver(self, session, content(raw))
        if error is not None:
            return unavailable(session, row_id, error)
        return api.web.json_response(
            {"object": "hermes.session.chat.queued", "session_id": session["id"], "status": "queued",
             "delivery_id": row_id, "via": session["source"]},
            status=202, headers={"X-Hermes-Session-Id": session["id"]})

    @wraps(old_stream)
    async def stream(self, request, *args, **kwargs):
        routed = await route(self, request)
        if routed is None:
            return await old_stream(self, request, *args, **kwargs)
        if not isinstance(routed, tuple):
            return routed
        session, raw = routed
        # Deliver before the SSE head: a final failure is still a plain 502 the client reads.
        row_id, error = await bridge.deliver(self, session, content(raw))
        if error is not None:
            return unavailable(session, row_id, error)
        sid, run_id, seq = session["id"], f"run_{uuid.uuid4().hex}", 0
        response = await self._prepare_sse_response(request, sid, None)

        async def write(name, payload):
            nonlocal seq
            seq += 1
            payload = {"session_id": sid, "run_id": run_id, "seq": seq, "ts": time.time(), **payload}
            await response.write(api._sse_frame(payload, event=name, ensure_ascii=False))

        try:
            await write("run.started", {"user_message": {"role": "user", "content": raw}, "runtime": {}})
            # The live-owner handoff shape: the app ends the stream on purpose and reconciles
            # read-only; the reply arrives through the session transcript and the thread.
            await write("run.queued", {"status": "queued", "delivery_id": row_id, "via": session["source"]})
            await write("done", {})
        except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError, OSError):
            log.info("crosssource SSE client left after %s was accepted", row_id)
        return response

    tx.set(cls, "_handle_session_chat", chat)
    tx.set(cls, "_handle_session_chat_stream", stream)
    return bridge
