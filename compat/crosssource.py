"""TASK-DIRECTINJECT: app chat into a foreign-source (Discord) session.

Core refuses an API turn aimed at a foreign-surface session
(gateway/session_api_turn.py:216 ``permission_denied``). This unit wraps the two
session chat routes. A target whose source is in ``PLATFORMS`` is delivered
through the core plugin injection seam alone (``PluginContext.inject_message``
with the session's own ``session_key``, authorized by
``plugins.entries.<plugin>.allow_gateway_injection``): the text is written into
the session as the owner's own user message and starts an agent turn, which
replies through the session's native surface. There is no Discord REST post and
no bot-forwarded copy of the user's text; a bot never speaks for the user.
Every other target, a missing session and every wake batch stay on the native
path.

Live progress (TASK-PROGRESSBRIDGE): under a session authority the injected
text is a durable automation admission of the Discord session, and its turn
publishes ``message.start`` / ``message.delta`` / ``tool.start`` /
``tool.complete`` / ``message.complete`` on that session's canonical
``SessionEvents`` stream. The stream route attaches an observer there (plus the
replay ring for frames published before the attach), finds its own admission by
the injection identity in the ``session.info`` pending list, and forwards it as
the session SSE events the app already renders (``message.started``,
``assistant.delta``, ``tool.started``, ``tool.completed`` / ``tool.failed``,
``assistant.completed``, ``run.<status>``, ``done``). The follow ends at the
admission's completion, at the gateway inactivity timeout
(``HERMES_AGENT_TIMEOUT``, the turn's own), or when the client leaves; a client
leaving never stops the turn, which belongs to the Discord session. When the
seams fail the load-time check, no authority serves the session, or the
admission is never seen, the route answers the earlier handoff shape
(``run.queued`` + ``done``) and the app reconciles from the transcript.

Resilience: the text is spooled (SQLite, plugin-owned file) before the first
attempt, and a resend of the same text to the same session folds into the
existing row instead of adding one. At most ``MAX_ATTEMPTS`` attempts per
delivery; a final failure answers HTTP 502 ``kind=bridge_unavailable`` with the
spool id and the row keeps the text with ``status='failed'``. ``drain`` retries
every ``pending`` and ``failed`` row; it runs once after each load. A row whose
message is older than ``DRAIN_MAX_AGE_SECONDS`` is marked ``stale-dropped`` and
never injected: a days-old question must not come back as a new turn.

Synthetic run ids (TASK-SYNTHRUN): the stream route names its turn with a
``run_<hex>`` id core never issued (the injection is an automation admission, not
an API run), so ``GET /v1/runs/{id}`` and the steer routes answered 404 for it and
the app dropped its steer button. ``SyntheticRuns`` remembers each id it hands out
as ``id -> (session id, session key[, admission id])``: bounded (``SYNTHETIC_RUNS_CAP``),
held while its stream is open, then kept ``SYNTHETIC_GRACE_SECONDS`` past the
stream's end so the app's closing polls read a terminal state instead of a 404,
and never longer than ``SYNTHETIC_MAX_AGE_SECONDS``. ``resolve`` answers the
session's real state in its authority: the admission the follow saw, else the
session's running (else newest pending) admission, projected in the shape core's
``run_projection`` gives an API run; nothing found reads as terminal. Ids it never
issued resolve to ``None`` and keep the native routes.

Honest injection (TASK-COLDTURN): core's ``inject_message`` answers True once the turn is
scheduled (gateway/run_plugin_injection.py:110); the authority's verdict on the admission only
reaches the gateway log. Under an authority a plugin turn borrows the route's last committed
native envelope with provenance (``session_automation.committed_route_envelope``) and is
refused ``not_found`` while the route has none (``snapshot_automation``), i.e. while no human
message was admitted there. So before each attempt the bridge asks core's own function the
same question (``route_refusal``): no envelope (or no live route entry) is a final failure
without an injection, a plain 502 ``bridge_unavailable`` with the row kept ``failed`` for a
later drain, never ``delivered``. Without an authority (core's standalone path needs no
envelope), or when the check itself cannot run, the attempt proceeds as before.

No core file is written, no admission or whitelist is bypassed.
"""
from __future__ import annotations

import asyncio
from collections import OrderedDict
from contextlib import closing
from functools import wraps
import inspect
import json
import logging
import os
from pathlib import Path
import re
import sqlite3
import threading
import time
import uuid
import weakref

log = logging.getLogger("hermes-app-compat.crosssource")

# Sources this bridge serves. Other foreign sources keep the native refusal.
PLATFORMS = frozenset({"discord"})
MAX_ATTEMPTS = 3
# Sleeps between attempts 1->2 and 2->3.
BACKOFF_SECONDS = (0.5, 1.5)
KIND = "bridge_unavailable"
# The retired bot-forwarding tail mark. Rows spooled by the old bridge still
# carry it; a drained row is injected clean, as if the forwarding never shipped.
_LEGACY_MARK = "\n\n[經 Hermes App 代發]"
# A delivered row absorbs an identical resend this long after it was created.
DEDUP_WINDOW_SECONDS = 60
# Dedup folds a resend only into an undelivered row touched within this window; drain
# marks an undelivered row whose message (created_at) is older than this stale-dropped.
DRAIN_MAX_AGE_SECONDS = 24 * 3600
STALE = "stale-dropped"
# Load-time drain waits this long so the platform adapters can connect first.
DRAIN_DELAY_SECONDS = 10
_THREAD_KEY = re.compile(r"^agent:[^:]+:discord:thread:(\d+):(\d+)$")
# Live progress: how long the follow waits for its admission to show up on the
# session's event stream before it answers the queued handoff instead. Not a
# turn timeout (that one is HERMES_AGENT_TIMEOUT); it only bounds the case where
# the injection was accepted but never became an admission.
ADMISSION_WAIT_SECONDS = 30
# Poll step while the session's live entry does not exist yet.
ATTACH_POLL_SECONDS = 0.05
# core gateway/run_turn.py: inactivity timeout, env wins (config is exported to it), 0 = unlimited.
_TURN_TIMEOUT_ENV, _TURN_TIMEOUT_DEFAULT = "HERMES_AGENT_TIMEOUT", 1800.0
_KEEPALIVE_DEFAULT = 10.0
_KEEPALIVE_FRAME = b": keepalive\n\n"
# Synthetic run ids: at most this many remembered; a closed stream's id answers this long
# after the stream ended; no id outlives this age, open stream or not.
SYNTHETIC_RUNS_CAP = 256
SYNTHETIC_GRACE_SECONDS = 300.0
SYNTHETIC_MAX_AGE_SECONDS = 24 * 3600.0
_TERMINAL_STATUS = {"run.completed": "completed", "run.failed": "failed", "run.cancelled": "cancelled",
                    "run.interrupted": "interrupted"}

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
# Pre-injection refusals core would give asynchronously; final at once, never retried in-request.
NO_ENVELOPE = "no_route_envelope"
NO_ROUTE = "route_not_found"


def thread_id_from_key(session_key):
    """``agent:main:discord:thread:<channel>:<thread>`` -> ``<thread>``, else ``None``."""
    match = _THREAD_KEY.match(session_key or "")
    return match.group(2) if match else None


class Outbox:
    """Durable per-message record.

    ``pending`` -> ``delivered`` | ``failed``; ``failed`` -> ``pending`` again on a
    resend or a drain. ``merged`` marks a duplicate drain folded into an older row,
    ``stale-dropped`` an undelivered row drain found past ``DRAIN_MAX_AGE_SECONDS``.
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

    def undelivered(self):
        """Every ``pending`` and ``failed`` row, oldest first."""
        with closing(self._connect()) as conn:
            return [dict(r) for r in conn.execute(
                "SELECT * FROM outbox WHERE status IN ('pending','failed') ORDER BY created_at")]

    def rows(self):
        with closing(self._connect()) as conn:
            return [dict(r) for r in conn.execute("SELECT * FROM outbox ORDER BY created_at")]


def route_refusal(authority, session_key):
    """The refusal core's authority would give a plugin turn on ``session_key``, decided before
    the injection: ``NO_ROUTE`` where the dispatch finds no live route entry
    (``_dispatch_plugin_message_injection`` / ``session_automation._owner``), ``NO_ENVELOPE``
    where ``committed_route_envelope`` finds no native human envelope, else ``None``."""
    from gateway.session_automation import committed_route_envelope
    entry = authority.runner.session_store.lookup_by_session_key(session_key)
    if entry is None or entry.origin is None or entry.suspended:
        return NO_ROUTE
    return NO_ENVELOPE if committed_route_envelope(authority, entry) is None else None


def check_envelope_seams():
    """Load-time drift check of the core refusal ``route_refusal`` mirrors. ``None`` when it
    holds, else the first broken piece; the caller logs it and injects unchecked."""
    try:
        from gateway import run_plugin_injection, session_automation
    except Exception as exc:
        return f"import:{type(exc).__name__}"
    mixin = getattr(run_plugin_injection, "GatewayPluginInjectionMixin", None)
    sources = (
        (getattr(session_automation, "committed_route_envelope", None),
         ("authority.logical_owner(entry.session_id)", "'native_text_v1' in r['payload']",
          "'provenance' in envelope else None")),
        (getattr(session_automation, "snapshot_automation", None),
         ("envelope = committed_route_envelope(authority, entry)",
          "if envelope is None:\n        raise RuntimeStoreError('not_found')")),
        (getattr(session_automation, "_owner", None), ("if entry is None or entry.suspended:",)),
        (getattr(mixin, "_dispatch_plugin_message_injection", None),
         ("lookup_by_session_key(session_key)", "if entry is None or entry.origin is None",
          "session_id=entry.session_id")),
    )
    for func, needles in sources:
        if func is None:
            return "missing:" + needles[0]
        try:
            text = inspect.getsource(func)
        except (OSError, TypeError):
            return f"source:{getattr(func, '__qualname__', func)}"
        for needle in needles:
            if needle not in text:
                return f"{func.__qualname__}:{needle}"
    return None


class Bridge:
    def __init__(self, outbox, ctx_getter, sleep=asyncio.sleep, authority_getter=None):
        self.outbox = outbox
        self.ctx_getter = ctx_getter
        self.sleep = sleep
        # ``None``: inject unchecked (no envelope check, the pre-COLDTURN behaviour).
        self.authority_getter = authority_getter
        # One delivery per row at a time: a resend or a drain waits for the one in flight.
        self._locks = weakref.WeakValueDictionary()
        self._drain_armed = False
        self.drain_task = None

    async def _attempt(self, api_adapter, platform, session_key, text):
        """One delivery attempt by plugin injection; ``(None, None)`` on success, else ``(reason, None)``."""
        outcome = self._trigger(session_key, text)
        if outcome == "injected":
            return None, None
        return outcome, None

    def _refusal(self, api_adapter, session_key):
        """``route_refusal`` under the adapter's authority; ``None`` (inject) without an authority,
        a store, or when the check raises: the check never blocks what it cannot judge."""
        if self.authority_getter is None:
            return None
        try:
            authority = self.authority_getter(api_adapter)
            if authority is None or getattr(getattr(authority, "runner", None), "session_store", None) is None:
                return None
            return route_refusal(authority, session_key)
        except Exception as exc:
            log.warning("crosssource envelope check unavailable for %s: %s", session_key, type(exc).__name__)
            return None

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
        """Up to MAX_ATTEMPTS attempts for one spooled row. Returns ``(row_id, error, injected)``;
        ``injected`` is False for a row that was already delivered (no new turn started)."""
        lock = self._locks.get(row_id)
        if lock is None:
            lock = self._locks[row_id] = asyncio.Lock()
        async with lock:
            row = await asyncio.to_thread(self.outbox.get, row_id)
            if row["status"] == "delivered":
                log.info("crosssource %s already delivered as message %s", row_id, row["message_id"])
                return row_id, None, False
            platform, session_key, text = row["platform"], row["session_key"], row["text"]
            text = text.removesuffix(_LEGACY_MARK)
            attempts, error = row["attempts"], None
            refusal = await asyncio.to_thread(self._refusal, api_adapter, session_key)
            if refusal is not None:
                # Core would refuse this admission after inject_message already said True: fail
                # here, keep the text for a drain once the route has a human envelope.
                await asyncio.to_thread(self.outbox.record, row_id, attempts=attempts + 1, status="failed",
                                        error=refusal)
                log.warning("crosssource %s not injected into %s session %s: %s",
                            row_id, platform, row["session_id"], refusal)
                return row_id, refusal, False
            for attempt in range(1, MAX_ATTEMPTS + 1):
                attempts += 1
                error = (await self._attempt(api_adapter, platform, session_key, text))[0]
                final = error is None or attempt == MAX_ATTEMPTS
                if error is None:
                    await asyncio.to_thread(self.outbox.record, row_id, attempts=attempts, status="delivered",
                                            trigger="injected")
                    log.info("crosssource %s injected into %s session %s (attempt %d)",
                             row_id, platform, row["session_id"], attempt)
                    return row_id, None, True
                await asyncio.to_thread(self.outbox.record, row_id, attempts=attempts,
                                        status="failed" if final else "pending", error=error)
                log.warning("crosssource %s attempt %d/%d failed: %s", row_id, attempt, MAX_ATTEMPTS, error)
                if not final:
                    await self.sleep(BACKOFF_SECONDS[attempt - 1])
            return row_id, error, False

    async def deliver(self, api_adapter, session, text):
        """Spool (folding a resend into its row), then deliver. Returns ``(row_id, error, injected)``."""
        row_id, merged = await asyncio.to_thread(
            self.outbox.enqueue, session_id=session["id"], session_key=session["session_key"],
            platform=session["source"], text=text)
        if merged:
            log.info("crosssource resend for session %s folded into %s", session["id"], row_id)
        return await self._run(api_adapter, row_id)

    async def drain(self, api_adapter, now=None):
        """Retry every ``pending``/``failed`` row. A row older than ``DRAIN_MAX_AGE_SECONDS``
        is marked ``stale-dropped`` instead; duplicates (same session and text) collapse into
        the oldest one first. Returns ``{row_id: error}`` for the rows it retried."""
        now = time.time() if now is None else now
        rows = await asyncio.to_thread(self.outbox.undelivered)
        heads, result, stale = {}, {}, 0
        for row in rows:
            age = now - row["created_at"]
            if age > DRAIN_MAX_AGE_SECONDS:
                stale += 1
                await asyncio.to_thread(self.outbox.record, row["id"], attempts=row["attempts"],
                                        status=STALE, error=f"age:{int(age)}s")
                continue
            head = heads.setdefault((row["session_id"], row["text"]), row["id"])
            if head != row["id"]:
                await asyncio.to_thread(self.outbox.record, row["id"], attempts=row["attempts"],
                                        status="merged", error=f"merged_into:{head}")
        for row_id in heads.values():
            result[row_id] = (await self._run(api_adapter, row_id))[1]
        if stale:
            log.warning("crosssource drain: %d row(s) older than %ds marked %s, not injected",
                        stale, DRAIN_MAX_AGE_SECONDS, STALE)
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


def turn_timeout():
    """The gateway turn's inactivity timeout in seconds (``None`` = unlimited), read as core reads it."""
    raw = os.environ.get(_TURN_TIMEOUT_ENV)
    try:
        value = float(raw) if raw not in (None, "") else _TURN_TIMEOUT_DEFAULT
    except (TypeError, ValueError):
        value = _TURN_TIMEOUT_DEFAULT
    return value if value > 0 else None


def check_progress_seams():
    """Load-time drift check of every core seam the live follow reads. Returns ``None`` when they
    all hold, else the first broken one; the caller logs it loudly and keeps the queued handoff."""
    try:
        from gateway import session_authorities, session_automation, session_settlement_recovery
        from gateway.session_authority import LiveSession, SessionAuthority
        from gateway.session_events import SessionEvents
        from gateway import run_plugin_injection
    except Exception as exc:
        return f"import:{type(exc).__name__}"
    events = SessionEvents()
    checks = (
        ("active_authority", callable(getattr(session_authorities, "active_authority", None))),
        ("SessionAuthority.logical_owner", callable(getattr(SessionAuthority, "logical_owner", None))),
        ("LiveSession.event_stream", "event_stream" in getattr(LiveSession, "__dataclass_fields__", {})),
        ("SessionEvents.observers", isinstance(getattr(events, "observers", None), set)),
        ("SessionEvents.lock", hasattr(getattr(events, "lock", None), "__enter__")),
        ("SessionEvents.watermark", callable(getattr(events, "watermark", None))),
        ("SessionEvents.since", callable(getattr(events, "since", None))),
    )
    for name, ok in checks:
        if not ok:
            return name
    # Frame contracts the follow decodes, checked in the producers' own source.
    sources = (
        (SessionAuthority._stamp_claim, ("'admission_id': row['admission_id']", "event_type='message.start'")),
        (SessionAuthority._pending_receipt, ("input_id=row['request_id']",)),
        (SessionAuthority.publish_execution, ("live.event_stream.publish(session_id, payload, event_type=event_type)",)),
        (session_settlement_recovery.completion_payload, ("'admission_id': row['admission_id']", "'status'")),
        (session_automation.admit_automation, ("request_id=identity",)),
        (run_plugin_injection.GatewayPluginInjectionMixin._admit_plugin_injection
         if hasattr(run_plugin_injection, "GatewayPluginInjectionMixin") else None,
         ('json.dumps(["plugin", plugin_id, session_key,',)),
    )
    for func, needles in sources:
        if func is None:
            return "run_plugin_injection._admit_plugin_injection"
        try:
            text = inspect.getsource(func)
        except (OSError, TypeError):
            return f"source:{getattr(func, '__qualname__', func)}"
        for needle in needles:
            if needle not in text:
                return f"{func.__qualname__}:{needle}"
    return None


def _ours(pending, session_key, text):
    """A ``session.info`` pending entry is this route's injection: plugin identity on this key, same text."""
    try:
        identity = json.loads(pending.get("input_id") or "")
    except (TypeError, ValueError):
        return False
    if not (isinstance(identity, list) and len(identity) >= 3 and identity[0] == "plugin"
            and identity[2] == session_key):
        return False
    seen = pending.get("text")
    return not isinstance(seen, str) or not seen or seen == text


def _terminal(payload):
    """``message.complete`` -> the session SSE terminal event name (api_server ``run.<status>``)."""
    status = payload.get("status")
    if status == "complete":
        return "run.completed"
    if status == "interrupted":
        return "run.interrupted"
    if status == "error":
        return "run.failed"
    return "run.cancelled" if payload.get("outcome") == "cancelled" else "run.completed"


class Follow:
    """One injected turn's live projection from the session's canonical event stream.

    ``prepare`` runs before the injection (watermark of a live entry that already exists);
    ``frames`` attaches, replays what it missed and yields ``(event, payload)`` pairs in the
    session SSE vocabulary until the admission completes. ``None`` from ``frames`` means
    it never saw its admission (or went idle past the turn timeout): answer the queued handoff.
    """

    def __init__(self, authority, owner, session_key, text, *, admission_wait=ADMISSION_WAIT_SECONDS,
                 idle_timeout=None, keepalive=_KEEPALIVE_DEFAULT):
        self.authority, self.owner = authority, owner
        self.session_key, self.text = session_key, text
        self.admission_wait, self.idle_timeout, self.keepalive = admission_wait, idle_timeout, keepalive
        self.message_id = f"msg_{uuid.uuid4().hex}"
        self.mark = None
        self.events = None
        self.ended = None
        self.target = None  # the admission id this send became, once session.info names it
        self._queue = asyncio.Queue()
        self._loop = asyncio.get_running_loop()

    def prepare(self):
        live = self.authority.sessions.get(self.owner)
        if live is not None:
            self.mark = (live.event_stream, live.event_stream.watermark())

    def _observe(self, frame):
        # Runs inside SessionEvents.publish, under its lock, often on the agent's worker thread.
        params = frame.get("params") if isinstance(frame, dict) else None
        if isinstance(params, dict):
            try:
                self._loop.call_soon_threadsafe(self._queue.put_nowait, params)
            except RuntimeError:
                pass  # the request's loop is gone; the turn itself never depends on this observer

    async def _attach(self, deadline):
        while True:
            live = self.authority.sessions.get(self.owner)
            if live is not None:
                break
            if self._loop.time() >= deadline:
                return False
            await asyncio.sleep(ATTACH_POLL_SECONDS)
        events = live.event_stream
        with events.lock:
            events.observers.add(self._observe)
            self.events = events
            if self.mark is not None and self.mark[0] is events:
                epoch, sequence = self.mark[1]
            else:
                epoch, sequence = events.watermark()[0], 0
            replay = events.since(epoch, sequence)
        for params in replay.get("events") or ():
            self._queue.put_nowait(params)
        return True

    def close(self):
        events, self.events = self.events, None
        if events is not None:
            with events.lock:
                events.observers.discard(self._observe)

    async def _next(self, timeout):
        """The next frame's params, ``None`` on a keepalive tick, ``False`` past ``timeout``."""
        tick = self.keepalive if timeout is None else min(self.keepalive, max(timeout, 0))
        try:
            return await asyncio.wait_for(self._queue.get(), timeout=tick)
        except asyncio.TimeoutError:
            return False if timeout is not None and timeout <= tick else None

    async def frames(self):
        """Async generator of ``(event, payload)``; ``(None, None)`` is a keepalive tick."""
        loop = self._loop
        deadline = loop.time() + self.admission_wait
        if not await self._attach(deadline):
            self.ended = "no_live_session"
            return
        target, candidates, started = None, {}, False
        last = loop.time()
        while True:
            if target is None:
                left = deadline - loop.time()
            else:
                left = None if self.idle_timeout is None else last + self.idle_timeout - loop.time()
            params = await self._next(left)
            if params is False:
                self.ended = "admission_not_seen" if target is None else "idle_timeout"
                return
            if params is None:
                yield None, None
                continue
            kind, payload = params.get("type"), params.get("payload") or {}
            if kind == "session.info" and not started:
                for pending in payload.get("pending") or ():
                    if isinstance(pending, dict) and _ours(pending, self.session_key, self.text):
                        candidates[pending.get("admission_id")] = pending.get("sequence") or 0
                if candidates:
                    # The newest matching row is this send; an older identical one queued earlier is not.
                    target = self.target = max(candidates, key=candidates.get)
                continue
            admission = params.get("admission_id") or payload.get("admission_id")
            if target is None or admission != target:
                continue
            last = loop.time()
            mid = self.message_id
            if kind == "message.start" and not started:
                started = True
                yield "message.started", {"message": {"id": mid, "role": "assistant"}}
            elif kind == "message.delta":
                if isinstance(payload.get("text"), str) and payload["text"]:
                    yield "assistant.delta", {"message_id": mid, "delta": payload["text"]}
            elif kind == "tool.start":
                yield "tool.started", {"message_id": mid, "tool_name": payload.get("tool_name") or payload.get("name"),
                                       "preview": payload.get("context"), "args": payload.get("args")}
            elif kind == "tool.complete":
                yield ("tool.failed" if payload.get("is_error") else "tool.completed"), {
                    "message_id": mid, "tool_name": payload.get("tool_name") or payload.get("name"),
                    "preview": None, "args": payload.get("args")}
            elif kind == "message.complete":
                content = payload.get("text") if isinstance(payload.get("text"), str) else ""
                terminal = _terminal(payload)
                yield "assistant.completed", {"message_id": mid, "content": content}
                closing_payload = {"message_id": mid, "messages": [], "usage": {}, "runtime": {}}
                if terminal == "run.failed":
                    surface = payload.get("error_surface") if isinstance(payload.get("error_surface"), dict) else {}
                    closing_payload["error"] = (payload.get("failure_reason") or payload.get("warning")
                                                or surface.get("message") or "turn failed")
                yield terminal, closing_payload
                self.ended = terminal
                return


def _foreign(session):
    return (session.get("source") in PLATFORMS and isinstance(session.get("session_key"), str)
            and session["session_key"].strip() != "")


def _core_authority(api_adapter):
    from gateway.session_authorities import active_authority
    return active_authority(getattr(api_adapter, "gateway_runner", None))


def _owner(authority, session):
    """The admission owner core computes for this key (``session_automation._owner``): the
    logical root of the route's current session, else of the app's own session id."""
    sid = session["id"]
    store = getattr(getattr(authority, "runner", None), "session_store", None)
    try:
        entry = store.lookup_by_session_key(session["session_key"]) if store is not None else None
    except Exception:
        entry = None
    if entry is not None and getattr(entry, "session_id", None):
        sid = entry.session_id
    return authority.logical_owner(sid)


def check_synthetic_seams():
    """Load-time drift check of the core pieces ``SyntheticRuns.resolve`` reads and the run
    projection it mirrors. ``None`` when they hold, else the first broken one; the caller logs
    it and leaves synthetic ids unresolved (the native 404)."""
    try:
        import hermes_state_runtime
        from gateway.platforms import api_server_authority_runs
        from gateway.platforms.api_server_runs import terminal_run_status  # noqa: F401
        from gateway.session_results import admission_result  # noqa: F401
    except Exception as exc:
        return f"import:{type(exc).__name__}"
    for name in ("_row", "list_session_admissions"):
        if not callable(getattr(hermes_state_runtime, name, None)):
            return f"hermes_state_runtime.{name}"
    try:
        text = inspect.getsource(api_server_authority_runs.run_projection)
    except (AttributeError, OSError, TypeError):
        return "source:run_projection"
    for needle in ("{'queued': 'queued', 'started': 'running', 'unknown': 'unknown', 'terminal': row['outcome']}",
                   "live.controls.snapshot(row['target_session_id'], row['generation'])",
                   "status = terminal_run_status(result)[0]",
                   "'admission_id': row['admission_id'], 'execution_generation': row['generation'],"):
        if needle not in text:
            return f"run_projection:{needle}"
    return None


def _projection(authority, row, run_id, session_id):
    """Core's ``run_projection`` for an admission it would not look up by run id (a plugin
    injection is not an ``api`` principal row): same status mapping, same fields. ``session_id``
    is the session the app addressed, as on this run's SSE frames."""
    from gateway.session_results import admission_result
    status = {"queued": "queued", "started": "running", "unknown": "unknown",
              "terminal": row["outcome"]}.get(row["status"])
    saved = admission_result(authority.db, row["admission_id"]) if row["status"] == "terminal" else None
    result = saved.get("result", {}) if saved else {}
    if row["status"] == "terminal":
        if result.get("interrupted") or row["outcome"] == "interrupted":
            status = "cancelled"
        elif result.get("failed") or result.get("error"):
            status = "failed"
        elif row["outcome"] == "completed" and saved:
            from gateway.platforms.api_server_runs import terminal_run_status
            status = terminal_run_status(result)[0]
    pending = []
    live = authority.sessions.get(row["target_session_id"])
    controls = getattr(live, "controls", None)
    if controls is not None and row["status"] == "started":
        pending = list(controls.snapshot(row["target_session_id"], row["generation"]))
        if any(prompt.get("kind") == "approval" for prompt in pending):
            status = "waiting_for_approval"
    return {"object": "hermes.run", "pending_controls": pending, "run_id": run_id, "status": status,
            "session_id": session_id, "admission_id": row["admission_id"],
            "execution_generation": row["generation"], "output": result.get("final_response", ""),
            "usage": saved.get("usage", {}) if saved else {}}


class SyntheticRun:
    """One resolved synthetic id: ``status`` is the GET /v1/runs/{id} body, ``binding`` the
    ``(authority, admission row)`` the steer admission binds through (``None``: nothing to bind)."""

    def __init__(self, status, binding=None):
        self.status, self.binding = status, binding

    @property
    def steerable(self):
        # core _handle_steer_run: only a running run takes a steer.
        return self.binding is not None and self.status.get("status") == "running"


class SyntheticRuns:
    """The run ids the stream route minted, ``id -> session``; see the module docstring for
    the expiry policy. Thread-safe: steer admission resolves off the loop."""

    def __init__(self, authority_getter, *, cap=SYNTHETIC_RUNS_CAP, grace=SYNTHETIC_GRACE_SECONDS,
                 max_age=SYNTHETIC_MAX_AGE_SECONDS, clock=time.time):
        self.authority_getter = authority_getter
        self.cap, self.grace, self.max_age, self.clock = cap, grace, max_age, clock
        self._entries = OrderedDict()
        self._lock = threading.Lock()

    def __len__(self):
        with self._lock:
            self._prune(self.clock())
            return len(self._entries)

    def _prune(self, now):
        for run_id, entry in list(self._entries.items()):
            if now - entry["issued_at"] >= self.max_age or (
                    entry["expires_at"] is not None and now >= entry["expires_at"]):
                del self._entries[run_id]

    def issue(self, session):
        """A new id for one stream of ``session``, held until ``release``."""
        run_id = f"run_{uuid.uuid4().hex}"
        with self._lock:
            now = self.clock()
            self._prune(now)
            while len(self._entries) >= self.cap:
                # Released ids go first; only then the oldest open stream's.
                released = next((k for k, e in self._entries.items() if e["expires_at"] is not None), None)
                self._entries.pop(released if released is not None else next(iter(self._entries)))
            self._entries[run_id] = {"session_id": session["id"], "session_key": session["session_key"],
                                     "admission_id": None, "terminal": None, "issued_at": now,
                                     "expires_at": None}
        return run_id

    def bind(self, run_id, admission_id):
        with self._lock:
            entry = self._entries.get(run_id)
            if entry is not None and admission_id:
                entry["admission_id"] = admission_id

    def release(self, run_id, ended=None):
        """The stream ended (``ended``: the follow's end, ``run.<status>`` when it saw one)."""
        with self._lock:
            entry = self._entries.get(run_id)
            if entry is not None:
                entry["terminal"] = _TERMINAL_STATUS.get(ended)
                entry["expires_at"] = self.clock() + self.grace

    def entry(self, run_id):
        if not isinstance(run_id, str):
            return None
        with self._lock:
            self._prune(self.clock())
            entry = self._entries.get(run_id)
            return dict(entry) if entry is not None else None

    def _admission(self, authority, entry):
        from hermes_state_runtime import _row, list_session_admissions
        if entry["admission_id"]:
            with authority.db._read_ctx() as conn:
                found = conn.execute("SELECT * FROM session_admissions WHERE admission_id=?",
                                     (entry["admission_id"],)).fetchone()
            return _row(found)
        # Before the follow names its admission (or with no follow): the session's turn.
        owner = _owner(authority, {"id": entry["session_id"], "session_key": entry["session_key"]})
        pending = list_session_admissions(authority.db, session_id=owner)
        started = [row for row in pending if row["status"] == "started"]
        return started[0] if started else (pending[-1] if pending else None)

    def resolve(self, adapter, run_id):
        """``None`` for an id this registry never issued (or forgot), else a ``SyntheticRun``."""
        entry = self.entry(run_id)
        if entry is None:
            return None
        try:
            authority = self.authority_getter(adapter)
            row = self._admission(authority, entry) if authority is not None else None
            if row is not None:
                return SyntheticRun(_projection(authority, row, run_id, entry["session_id"]), (authority, row))
        except Exception as exc:
            log.warning("crosssource synthetic run %s unresolved: %s", run_id, type(exc).__name__)
        # No admission to report: the turn is over (or never became one) as far as the
        # authority knows, so the run reads terminal, never as a live run nothing backs.
        return SyntheticRun({"object": "hermes.run", "pending_controls": [], "run_id": run_id,
                             "status": entry["terminal"] or "completed",
                             "session_id": entry["session_id"], "admission_id": entry["admission_id"],
                             "execution_generation": None, "output": "", "usage": {}})


def install(api, cls, tx, *, ctx_getter, spool_path, sleep=asyncio.sleep, authority_getter=_core_authority,
            progress=True, admission_wait=ADMISSION_WAIT_SECONDS, keepalive=None, runs=None,
            synthetic=True, envelope=True):
    """Wrap ``cls._handle_session_chat`` and ``cls._handle_session_chat_stream``. ``progress``
    False (a failed seam check) keeps the queued handoff on the stream route. With ``runs``
    (``gateway.platforms.api_server_runs``) and ``synthetic``, ``GET /v1/runs/{id}`` answers
    the stream route's synthetic ids (``bridge.runs``); every other id stays native. ``envelope``
    False (a failed ``check_envelope_seams``) injects without the route envelope check."""
    bridge = Bridge(Outbox(spool_path), ctx_getter, sleep, authority_getter if envelope else None)
    bridge.runs = SyntheticRuns(authority_getter)
    if keepalive is None:
        keepalive = float(getattr(api, "CHAT_COMPLETIONS_SSE_KEEPALIVE_SECONDS", _KEEPALIVE_DEFAULT))
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

    @wraps(old_chat)
    async def chat(self, request, *args, **kwargs):
        routed = await route(self, request)
        if routed is None:
            return await old_chat(self, request, *args, **kwargs)
        if not isinstance(routed, tuple):
            return routed
        session, raw = routed
        row_id, error, _ = await bridge.deliver(self, session, raw)
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
        follow = None
        if progress:
            try:
                authority = authority_getter(self)
                if authority is not None:
                    follow = Follow(authority, _owner(authority, session), session["session_key"], raw,
                                    admission_wait=admission_wait, idle_timeout=turn_timeout(),
                                    keepalive=keepalive)
                    follow.prepare()
            except Exception as exc:
                log.warning("crosssource progress follow unavailable for %s: %s", session["id"], type(exc).__name__)
                follow = None
        # Deliver before the SSE head: a final failure is still a plain 502 the client reads.
        row_id, error, injected = await bridge.deliver(self, session, raw)
        if error is not None:
            return unavailable(session, row_id, error)
        if not injected:
            follow = None  # a resend folded into a delivered row started no turn to follow
        sid, run_id, seq = session["id"], bridge.runs.issue(session), 0
        try:
            response = await self._prepare_sse_response(request, sid, None)
        except BaseException:
            bridge.runs.release(run_id)
            raise

        async def write(name, payload):
            nonlocal seq
            seq += 1
            if follow is not None and follow.target is not None:
                bridge.runs.bind(run_id, follow.target)
            payload = {"session_id": sid, "run_id": run_id, "seq": seq, "ts": time.time(), **payload}
            await response.write(api._sse_frame(payload, event=name, ensure_ascii=False))

        try:
            await write("run.started", {"user_message": {"role": "user", "content": raw}, "runtime": {}})
            if follow is not None:
                async for name, payload in follow.frames():
                    if name is None:
                        await response.write(_KEEPALIVE_FRAME)
                    else:
                        await write(name, payload)
                if (follow.ended or "").startswith("run."):
                    await write("done", {})
                    return response
                log.info("crosssource %s progress follow ended without a terminal frame (%s)", row_id, follow.ended)
            # The live-owner handoff shape: the app ends the stream on purpose and reconciles
            # read-only; the reply arrives through the session transcript and the thread.
            await write("run.queued", {"status": "queued", "delivery_id": row_id, "via": session["source"]})
            await write("done", {})
        except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError, OSError):
            log.info("crosssource SSE client left after %s was delivered", row_id)
        finally:
            # A client that leaves (or a cancelled request task) only drops this observer; the
            # turn belongs to the Discord session and keeps running there.
            if follow is not None:
                follow.close()
                bridge.runs.bind(run_id, follow.target)
            bridge.runs.release(run_id, follow.ended if follow is not None else None)
        return response

    tx.set(cls, "_handle_session_chat", chat)
    tx.set(cls, "_handle_session_chat_stream", stream)
    if runs is not None and synthetic:
        old_get_run = runs._handle_get_run

        @wraps(old_get_run)
        async def get_run(self, request, *args, **kwargs):
            found = bridge.runs.resolve(self, request.match_info.get("run_id"))
            if found is None:
                return await old_get_run(self, request, *args, **kwargs)
            auth_err = self._check_auth(request)
            if auth_err is not None:
                return auth_err
            return api.web.json_response(found.status)

        tx.set(runs, "_handle_get_run", get_run)
    return bridge
