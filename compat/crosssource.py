"""TASK-CROSSSOURCE(2): app chat into a foreign-source (Discord) session.

Core refuses an API turn aimed at a foreign-surface session
(gateway/session_api_turn.py:216 ``permission_denied``). This unit wraps the two
session chat routes. A target whose source is in ``PLATFORMS`` is delivered by
posting the text into its Discord thread over the REST front door
(``POST /channels/{thread_id}/messages``) with the bot token the Discord plugin
itself reads (``PlatformConfig.token``, then ``DISCORD_BOT_TOKEN``,
plugins/platforms/discord/adapter.py:7123). Every other target, a missing
session and every wake batch stay on the native path.

Delivered means Discord answered 2xx with a message id. The Discord adapter
drops the bot's own messages (adapter.py:1679), so the post alone never starts
an agent turn; after delivery the unit asks the core plugin injection seam
(``PluginContext.inject_message`` with the session's own ``session_key``) to run
one. A refused or failing trigger is logged and recorded on the row, never
turned into a delivery failure: the user can see the message in the thread.

Resilience: the text is spooled (SQLite, plugin-owned file) before the first
attempt, and a resend of the same text to the same session folds into the
existing row instead of adding one. At most ``MAX_ATTEMPTS`` attempts per
delivery; a final failure answers HTTP 502 ``kind=bridge_unavailable`` with the
spool id and the row keeps the text with ``status='failed'``. ``drain`` retries
every recent ``pending`` and ``failed`` row; it runs once after each load.

No core file is written, no admission or whitelist is bypassed.
"""
from __future__ import annotations

import asyncio
from contextlib import closing
from functools import wraps
import json
import logging
from pathlib import Path
import re
import sqlite3
import time
import uuid
import weakref

log = logging.getLogger("hermes-app-compat.crosssource")

# Sources this bridge serves. Other foreign sources keep the native refusal.
PLATFORMS = frozenset({"discord"})
MAX_ATTEMPTS = 3
# Sleeps between attempts 1->2 and 2->3.
BACKOFF_SECONDS = (0.5, 1.5)
VIA_APP_MARK = "[經 Hermes App 代發]"
KIND = "bridge_unavailable"
DISCORD_API = "https://discord.com/api/v10"
REST_TIMEOUT_SECONDS = 10
# Discord rejects longer message content with 400.
DISCORD_MAX_CONTENT = 2000
# A delivered row absorbs an identical resend this long after it was created.
DEDUP_WINDOW_SECONDS = 60
# Undelivered rows older than this (last touch) are left alone by drain and dedup.
DRAIN_MAX_AGE_SECONDS = 24 * 3600
# Load-time drain waits this long so the platform adapters can connect first.
DRAIN_DELAY_SECONDS = 10
_THREAD_KEY = re.compile(r"^agent:[^:]+:discord:thread:(\d+):(\d+)$")

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
# Columns added after the first schema shipped; old spool files gain them on open.
_ADDED_COLUMNS = (("message_id", "TEXT"), ("trigger", "TEXT"))
_UNDELIVERED = ("pending", "failed")


def thread_id_from_key(session_key):
    """``agent:main:discord:thread:<channel>:<thread>`` -> ``<thread>``, else ``None``."""
    match = _THREAD_KEY.match(session_key or "")
    return match.group(2) if match else None


class Outbox:
    """Durable per-message record.

    ``pending`` -> ``delivered`` | ``failed``; ``failed`` -> ``pending`` again on a
    resend or a drain. ``merged`` marks a duplicate drain folded into an older row.
    """

    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with closing(self._connect()) as conn, conn:
            conn.execute(_SCHEMA)
            have = {r["name"] for r in conn.execute("PRAGMA table_info(outbox)")}
            for name, kind in _ADDED_COLUMNS:
                if name not in have:
                    conn.execute(f"ALTER TABLE outbox ADD COLUMN {name} {kind}")

    def _connect(self):
        conn = sqlite3.connect(self.path, timeout=5)
        conn.row_factory = sqlite3.Row
        return conn

    def enqueue(self, *, session_id, session_key, platform, text, now=None):
        """Spool ``text``; returns ``(row_id, merged)``.

        Same session and same text folds into the oldest undelivered row touched
        within ``DRAIN_MAX_AGE_SECONDS`` (a retry must not leave one row per press),
        else into a row delivered within ``DEDUP_WINDOW_SECONDS`` (a double send
        is not posted twice); otherwise a new ``pending`` row.
        """
        now = time.time() if now is None else now
        with closing(self._connect()) as conn, conn:
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute(
                "SELECT id FROM outbox WHERE session_id=? AND text=? AND status IN ('pending','failed') "
                "AND updated_at>=? ORDER BY created_at LIMIT 1",
                (session_id, text, now - DRAIN_MAX_AGE_SECONDS)).fetchone()
            if row is None:
                row = conn.execute(
                    "SELECT id FROM outbox WHERE session_id=? AND text=? AND status='delivered' "
                    "AND created_at>=? ORDER BY created_at LIMIT 1",
                    (session_id, text, now - DEDUP_WINDOW_SECONDS)).fetchone()
            if row is not None:
                return row["id"], True
            row_id = f"xsrc_{uuid.uuid4().hex}"
            conn.execute(
                "INSERT INTO outbox(id, session_id, session_key, platform, text, status, attempts, "
                "created_at, updated_at) VALUES (?,?,?,?,?,'pending',0,?,?)",
                (row_id, session_id, session_key, platform, text, now, now))
        return row_id, False

    def record(self, row_id, *, attempts, status, error=None, message_id=None, trigger=None):
        with closing(self._connect()) as conn, conn:
            conn.execute("UPDATE outbox SET attempts=?, status=?, last_error=?, message_id=?, trigger=?, "
                         "updated_at=? WHERE id=?",
                         (attempts, status, error, message_id, trigger, time.time(), row_id))

    def get(self, row_id):
        with closing(self._connect()) as conn:
            row = conn.execute("SELECT * FROM outbox WHERE id=?", (row_id,)).fetchone()
        return dict(row) if row is not None else None

    def undelivered(self, now=None):
        """``pending`` and ``failed`` rows touched within ``DRAIN_MAX_AGE_SECONDS``, oldest first."""
        now = time.time() if now is None else now
        with closing(self._connect()) as conn:
            return [dict(r) for r in conn.execute(
                "SELECT * FROM outbox WHERE status IN ('pending','failed') AND updated_at>=? "
                "ORDER BY created_at", (now - DRAIN_MAX_AGE_SECONDS,))]

    def rows(self):
        with closing(self._connect()) as conn:
            return [dict(r) for r in conn.execute("SELECT * FROM outbox ORDER BY created_at")]


class Bridge:
    def __init__(self, outbox, ctx_getter, sleep=asyncio.sleep, api_base=DISCORD_API):
        self.outbox = outbox
        self.ctx_getter = ctx_getter
        self.sleep = sleep
        self.api_base = api_base
        # One delivery per row at a time: a resend or a drain waits for the one in flight.
        self._locks = weakref.WeakValueDictionary()
        self._drain_armed = False
        self.drain_task = None

    @staticmethod
    def platform_adapter(api_adapter, platform):
        from gateway.config import Platform
        runner = getattr(api_adapter, "gateway_runner", None)
        adapters = getattr(runner, "adapters", None) or {}
        try:
            return adapters.get(Platform(platform))
        except ValueError:
            return None

    @classmethod
    def bot_token(cls, api_adapter, platform):
        """The Discord plugin's own read: ``PlatformConfig.token``, then ``DISCORD_BOT_TOKEN``."""
        from gateway.config import Platform
        target = cls.platform_adapter(api_adapter, platform)
        token = getattr(getattr(target, "config", None), "token", None)
        if not token:
            runner_config = getattr(getattr(api_adapter, "gateway_runner", None), "config", None)
            platforms = getattr(runner_config, "platforms", None) or {}
            token = getattr(platforms.get(Platform(platform)), "token", None)
        if not token:
            try:
                from agent.secret_scope import get_secret
                token = get_secret("DISCORD_BOT_TOKEN", "")
            except Exception as exc:
                log.warning("crosssource token lookup raised: %s", type(exc).__name__)
                token = None
        return (token or "").strip() or None

    def _proxy_kwargs(self):
        if self.api_base != DISCORD_API:
            return {}, {}
        try:
            from gateway.platforms.base import resolve_proxy_url, proxy_kwargs_for_aiohttp
            return proxy_kwargs_for_aiohttp(resolve_proxy_url(platform_env_var="DISCORD_PROXY"))
        except Exception as exc:
            log.warning("crosssource proxy lookup raised: %s", type(exc).__name__)
            return {}, {}

    async def _post(self, token, thread_id, text):
        """One REST post; ``(None, message_id)`` on success, else ``(reason, None)``."""
        import aiohttp
        url = f"{self.api_base}/channels/{thread_id}/messages"
        headers = {"Authorization": f"Bot {token}", "Content-Type": "application/json"}
        # App text never pings anyone in the thread.
        payload = {"content": text, "allowed_mentions": {"parse": []}}
        sess_kw, req_kw = self._proxy_kwargs()
        try:
            async with aiohttp.ClientSession(
                    timeout=aiohttp.ClientTimeout(total=REST_TIMEOUT_SECONDS), **sess_kw) as session:
                async with session.post(url, headers=headers, json=payload, **req_kw) as resp:
                    if not 200 <= resp.status < 300:
                        return f"rest_http_{resp.status}", None
                    try:
                        data = await resp.json(content_type=None)
                    except (ValueError, aiohttp.ContentTypeError):
                        data = None
        except asyncio.TimeoutError:
            return "rest_timeout", None
        except aiohttp.ClientError as exc:
            log.warning("crosssource REST post raised: %s", type(exc).__name__)
            return "rest_error", None
        message_id = data.get("id") if isinstance(data, dict) else None
        if not isinstance(message_id, str) or not message_id:
            return "rest_no_message_id", None
        return None, message_id

    async def _attempt(self, api_adapter, platform, session_key, text):
        """One delivery attempt; ``(None, message_id)`` on success, else ``(reason, None)``."""
        thread_id = thread_id_from_key(session_key)
        if thread_id is None:
            return "session_key_unparsed", None
        token = self.bot_token(api_adapter, platform)
        if token is None:
            return "token_missing", None
        return await self._post(token, thread_id, text)

    def _trigger(self, session_key, text):
        """Ask core to run a turn for the delivered text; the outcome is only recorded."""
        ctx = self.ctx_getter()
        if ctx is None or not callable(getattr(ctx, "inject_message", None)):
            return "plugin_context_missing"
        try:
            accepted = ctx.inject_message(text, session_key=session_key)
        except Exception as exc:
            log.warning("crosssource trigger inject raised: %s", type(exc).__name__)
            return "inject_error"
        return "injected" if accepted else "inject_refused"

    async def _run(self, api_adapter, row_id):
        """Up to MAX_ATTEMPTS attempts for one spooled row. Returns ``(row_id, error)``."""
        lock = self._locks.get(row_id)
        if lock is None:
            lock = self._locks[row_id] = asyncio.Lock()
        async with lock:
            row = await asyncio.to_thread(self.outbox.get, row_id)
            if row["status"] == "delivered":
                log.info("crosssource %s already delivered as message %s", row_id, row["message_id"])
                return row_id, None
            platform, session_key, text = row["platform"], row["session_key"], row["text"]
            attempts, error = row["attempts"], None
            for attempt in range(1, MAX_ATTEMPTS + 1):
                attempts += 1
                error, message_id = await self._attempt(api_adapter, platform, session_key, text)
                final = error is None or attempt == MAX_ATTEMPTS
                if error is None:
                    trigger = self._trigger(session_key, text)
                    await asyncio.to_thread(self.outbox.record, row_id, attempts=attempts, status="delivered",
                                            message_id=message_id, trigger=trigger)
                    log.info("crosssource %s delivered to %s session %s as message %s (attempt %d)",
                             row_id, platform, row["session_id"], message_id, attempt)
                    if trigger != "injected":
                        log.warning("crosssource %s delivered but no agent turn was started: %s",
                                    row_id, trigger)
                    return row_id, None
                await asyncio.to_thread(self.outbox.record, row_id, attempts=attempts,
                                        status="failed" if final else "pending", error=error)
                log.warning("crosssource %s attempt %d/%d failed: %s", row_id, attempt, MAX_ATTEMPTS, error)
                if not final:
                    await self.sleep(BACKOFF_SECONDS[attempt - 1])
            return row_id, error

    async def deliver(self, api_adapter, session, text):
        """Spool (folding a resend into its row), then deliver. Returns ``(row_id, error)``."""
        row_id, merged = await asyncio.to_thread(
            self.outbox.enqueue, session_id=session["id"], session_key=session["session_key"],
            platform=session["source"], text=text)
        if merged:
            log.info("crosssource resend for session %s folded into %s", session["id"], row_id)
        return await self._run(api_adapter, row_id)

    async def drain(self, api_adapter):
        """Retry every recent ``pending``/``failed`` row. Duplicates (same session and
        text) collapse into the oldest one first. Returns ``{row_id: error}``."""
        rows = await asyncio.to_thread(self.outbox.undelivered)
        heads, result = {}, {}
        for row in rows:
            head = heads.setdefault((row["session_id"], row["text"]), row["id"])
            if head != row["id"]:
                await asyncio.to_thread(self.outbox.record, row["id"], attempts=row["attempts"],
                                        status="merged", error=f"merged_into:{head}")
        for row_id in heads.values():
            result[row_id] = (await self._run(api_adapter, row_id))[1]
        if result:
            log.info("crosssource drain: %d delivered, %d still failed",
                     sum(e is None for e in result.values()), sum(e is not None for e in result.values()))
        return result

    def schedule_drain(self, api_adapter, loop, delay=DRAIN_DELAY_SECONDS):
        """Run ``drain`` once per bridge (one bridge per load) on ``loop``."""
        if self._drain_armed:
            return False
        self._drain_armed = True

        async def run():
            await self.sleep(delay)
            try:
                await self.drain(api_adapter)
            except Exception as exc:
                log.warning("crosssource drain failed: %s", type(exc).__name__)
        try:
            on_loop = asyncio.get_running_loop() is loop
        except RuntimeError:
            on_loop = False
        if on_loop:
            self.drain_task = loop.create_task(run(), name="hermes-app-crosssource-drain")
        else:
            self.drain_task = asyncio.run_coroutine_threadsafe(run(), loop)
        return True


def _foreign(session):
    return (session.get("source") in PLATFORMS and isinstance(session.get("session_key"), str)
            and session["session_key"].strip() != "")


def install(api, cls, tx, *, ctx_getter, spool_path, sleep=asyncio.sleep, api_base=DISCORD_API):
    """Wrap ``cls._handle_session_chat`` and ``cls._handle_session_chat_stream``."""
    bridge = Bridge(Outbox(spool_path), ctx_getter, sleep, api_base)
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
        if len(content(raw)) > DISCORD_MAX_CONTENT:
            return api._error_response(
                "A %s message holds at most %d characters including the app mark."
                % (session["source"], DISCORD_MAX_CONTENT), 413, code="crosssource_too_long")
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
            log.info("crosssource SSE client left after %s was delivered", row_id)
        return response

    tx.set(cls, "_handle_session_chat", chat)
    tx.set(cls, "_handle_session_chat_stream", stream)
    return bridge
