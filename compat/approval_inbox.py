"""APPROVALPUSH R1-R3: approval request registry and native double bridge.

One registry entry per NATIVE pending approval inside an api_server run this
process owns. The core queue (``tools.approval._gateway_queues``) is the only
truth about what is still pending; this registry only enriches it with a
desensitized display payload, a monotonic deadline and notification flags, and
bridges the two API admission surfaces (session-stream callback and the runs
``_make_approval_notify`` factory) into ONE inbox — never a second producer.

Keying follows R2: ``(adapter identity, run_id, native request_id)`` plus the
server epoch for cross-restart freshness. Nothing is ever keyed on command
text; two different operations never merge. Raw commands and secrets never
land in a stored payload (the core's Tirith-grade redactor runs first, a
generic key=value credential mask second).

Threading: capture runs on the guarded worker thread; it takes the core
``_approval._lock`` (non-reentrant) only for the brief entry lookup + settle
chain, and the inbox lock only for bookkeeping. Emits and enrichments hop onto
the run's event loop; nothing network- or await-shaped ever runs under a lock.
"""
from __future__ import annotations

import math
import re
import threading
import time

VERSION = "1"
INBOX_MAX_PENDING = 32        # per-run display cap; overflow reports degraded
INBOX_MAX_RUNS = 64           # total runs tracked; oldest pruned (observable)
RESOLVED_TTL = 900.0          # resolved entries linger this long for UI settle
CHOICES_BASE = ("once", "session", "deny")
CHOICES_ALWAYS = ("once", "session", "always", "deny")
CHOICES_DENY_ONLY = ("once", "deny")
# /deny <reason> style aliases the native POST accepts before validation.
CHOICE_ALIASES = {"approve": "once", "approved": "once", "allow": "once"}
_REDACTION_RE = re.compile(
    r"(?i)\b[\w.-]*(secret|token|password|passwd|api[_-]?key|access[_-]?key)[\w.-]*[=:]\S+")
_REDACTION = "***"

_capability_on = True  # B4: shipped enabled; set_capability(False) is the kill switch (R1 rollback)


def set_capability(enabled: bool) -> None:
    global _capability_on
    _capability_on = bool(enabled)


def capability_enabled(inbox) -> bool:
    return _capability_on and inbox is not None and not inbox.get("closed")


def DEFAULT_TIMEOUT() -> int:
    """Core ``approvals.timeout`` (default 300), read fresh; never hardcoded."""
    try:
        from tools.approval_context import _get_approval_timeout
        return max(int(_get_approval_timeout()), 0)
    except Exception:
        return 300


def _redact_command(command):
    """Desensitize for DISPLAY, never for execution. Prefer the loaded core
    redactor (a server process always has gateway.run); fall back to the
    generic credential mask in bare unit processes so importing core machinery
    is never a registry side effect."""
    text = str(command or "")
    core = __import__("sys").modules.get("gateway.run")
    if core is not None and callable(getattr(core, "_redact_approval_command", None)):
        try:
            text = core._redact_approval_command(text)
        except Exception:
            pass
    return _REDACTION_RE.sub(_REDACTION, text)


def _redact_text(text, cap=300):
    raw = str(text or "").strip()
    api = __import__("sys").modules.get("gateway.platforms.api_server")
    redact = getattr(api, "_redact_api_error_text", None) if api is not None else None
    if callable(redact):
        try:
            raw = redact(raw)
        except Exception:
            pass
    return raw[:cap]


def choices_from_data(data: dict) -> list:
    """Same rule as the native ``_approval_event_choices`` (policy truth):
    smart-denied or session-less offers once/deny; a request without any
    non-Tirith pattern (allow_permanent False) never offers always."""
    if bool(data.get("smart_denied")) or data.get("allow_session") is False:
        return list(CHOICES_DENY_ONLY)
    return list(CHOICES_ALWAYS if data.get("allow_permanent") is not False
                else CHOICES_BASE)


def entry_from_data(data, *, server_epoch, run_id, session_id, session_key,
                    timeout, now_mono, loop=None):
    request_id = str(data.get("request_id") or "")
    pattern_keys = [str(k) for k in (data.get("pattern_keys") or ([data.get("pattern_key")]
                    if data.get("pattern_key") else [])) if k]
    payload = {
        "request_id": request_id,
        "run_id": run_id,
        "session_id": session_id,
        "server_epoch": server_epoch,
        "choices": choices_from_data(data),
        "command": _redact_command(data.get("command")),
        "description": _redact_text(data.get("description")),
        "pattern_key": str(data.get("pattern_key") or (pattern_keys[0] if pattern_keys else "")),
        "pattern_keys": pattern_keys,
        "smart_denied": bool(data.get("smart_denied")),
    }
    now = time.time()
    return {
        "request_id": request_id, "run_id": run_id, "session_id": session_id,
        "session_key": session_key, "server_epoch": server_epoch,
        "payload": payload, "event": None, "loop": loop, "adapter": None,
        "flags": {"allow_session": data.get("allow_session") is not False,
                  "allow_permanent": data.get("allow_permanent") is not False},
        "created_at": now, "created_mono": now_mono, "timeout": int(timeout),
        "phase": "pending", "outcome": None,
        "pushed": {"initial": False, "reminder": False},
        "timer": None,
    }


class ApprovalInbox:
    """Registry container shared through the compat state across reloads."""

    @staticmethod
    def open(state):
        inbox = state.get("approval_inbox")
        if inbox is None:
            inbox = state["approval_inbox"] = {
                "lock": threading.RLock(), "state": state, "by_run": {},
                "closed": False, "dispatch": None, "epoch": state.get("activity_epoch"),
                "metrics": {"registry_accepted": 0, "registry_dropped": 0,
                            "push_enqueued": 0, "push_dropped": 0,
                            "send_success": 0, "send_fail": 0},
            }
        inbox["closed"] = False       # a fresh install re-claims the registry
        inbox["epoch"] = state.get("activity_epoch")
        return inbox


def _bucket(inbox, adapter, run_id, *, create=False, session_id=None, loop=None):
    key = (id(adapter), run_id)
    bucket = inbox["by_run"].get(key)
    if bucket is None and create:
        bucket = inbox["by_run"][key] = {
            "entries": {}, "revision": 0, "degraded": False,
            "session_id": session_id, "loop": loop, "last_seen": time.monotonic(),
        }
        while len(inbox["by_run"]) > INBOX_MAX_RUNS:  # observable degrade, never silent
            oldest = min(inbox["by_run"].items(), key=lambda kv: kv[1]["last_seen"])
            if oldest[1]["entries"] and any(e["phase"] == "pending"
                                            for e in oldest[1]["entries"].values()):
                oldest[1]["degraded"] = True
            inbox["by_run"].pop(oldest[0], None)
            inbox["metrics"]["enqueue_dropped"] += 1
    if bucket is not None:
        bucket["last_seen"] = time.monotonic()
        if loop is not None:
            bucket["loop"] = loop
        if session_id is not None and not bucket["session_id"]:
            bucket["session_id"] = session_id
    return bucket


def _live(session_key):
    """Exact queue truth: snapshot dicts in FIFO (oldest-first) core order."""
    from tools import approval as core
    return core.list_gateway_approvals(session_key)


def _session_key(adapter, run_id):
    try:
        return adapter._run_approval_sessions.get(run_id) or run_id
    except Exception:
        return run_id


def settle(inbox, adapter, run_id, request_id, outcome, *, emit=True):
    """Mark one exact request resolved; idempotent (first outcome wins)."""
    key = (id(adapter), run_id)
    with inbox["lock"]:
        bucket = inbox["by_run"].get(key)
        entry = bucket["entries"].get(request_id) if bucket else None
        if entry is None or entry["phase"] != "pending":
            return False
        entry["phase"] = "resolved"
        entry["outcome"] = outcome
        entry["resolved_mono"] = time.monotonic()
        bucket["revision"] += 1
        timer = entry.get("timer")
        entry["timer"] = None
        loop = bucket.get("loop")
    if timer is not None:
        timer.cancel()
    if emit:
        emit_resolved(inbox, adapter, loop, run_id, request_id, outcome)
    return True


_SETTLE_REASONS = {"resolved": "answered", "timeout": "timeout",
                   "session_closed": "withdrawn", "interrupted": "withdrawn",
                   "notify_failed": "notify_failed"}


def make_settle_hook(inbox, adapter, run_id, request_id, previous):
    """Chain (never replace) the settle hook: run the prior surface first, each
    side isolated from the other's exceptions, then settle our entry."""

    def _settle(reason):
        if previous is not None:
            try:
                previous(reason)
            except Exception:
                pass  # a foreign surface's failure never hides our bookkeeping
        settle(inbox, adapter, run_id, request_id,
               _SETTLE_REASONS.get(str(reason), "withdrawn"))

    return _settle


def capture(inbox, *, adapter, run_id, session_id=None, loop=None, data):
    """Called from inside the NATIVE notify callback, before the original runs.
    The core entry exists by now (enqueued before notify); if it already
    settled (raced answer/withdraw) we publish no phantom pending and bind no
    hook. Returns the entry, or None when the request is not (or no longer)
    ours to track."""
    request_id = str((data or {}).get("request_id") or "")
    if not request_id:
        return None
    session_key = _session_key(adapter, run_id)
    from tools import approval as core
    try:
        with core._lock:  # brief, never re-entered: locate + chain under the SAME lock
            entry = next((e for e in core._gateway_queues.get(session_key, [])
                          if e.data.get("request_id") == request_id), None)
            if entry is None:
                return None
            previous = entry.settle
            entry.settle = make_settle_hook(inbox, adapter, run_id, request_id, previous)
    except Exception:
        return None
    timeout = DEFAULT_TIMEOUT()
    now_mono = time.monotonic()
    new_entry = entry_from_data(data, server_epoch=inbox["epoch"], run_id=run_id,
                                session_id=session_id, session_key=session_key,
                                timeout=timeout, now_mono=now_mono, loop=loop)
    new_entry["adapter"] = adapter
    key = (id(adapter), run_id)
    with inbox["lock"]:
        bucket = _bucket(inbox, adapter, run_id, create=True, session_id=session_id, loop=loop)
        prior = bucket["entries"].get(request_id)
        if prior is not None and prior["phase"] == "pending":
            return prior  # duplicate producer path / status replay: same entry, no reset
        if prior is not None and prior.get("timer") is not None:
            prior["timer"].cancel()  # a re-captured ID is a NEW request; old timer dies
        if len(bucket["entries"]) >= INBOX_MAX_PENDING:
            bucket["degraded"] = True
            inbox["metrics"]["registry_dropped"] += 1
            return None
        bucket["entries"][request_id] = new_entry
        bucket["revision"] += 1
        inbox["metrics"]["registry_accepted"] += 1
        dispatch = inbox.get("dispatch")
    if dispatch is not None:
        try:
            dispatch(new_entry)  # immediate notification hook (B2; never blocks)
        except Exception:
            pass
    return new_entry


def enrich_event(inbox, adapter, run_id, request_id):
    """Loop-thread additive enrichment of the native approval.request payload
    (the very dict parked in run status / enqueued to SSE). Additive only:
    existing fields keep their native values (R2 'old fields preserved')."""
    key = (id(adapter), run_id)
    with inbox["lock"]:
        bucket = inbox["by_run"].get(key)
        entry = bucket["entries"].get(request_id) if bucket else None
    if entry is None:
        return
    status = (getattr(adapter, "_run_statuses", {}) or {}).get(run_id) or {}
    event = status.get("approval")
    if not isinstance(event, dict) or event.get("request_id") != request_id:
        return
    filled = payload_for(entry)
    for field in ("session_id", "server_epoch", "created_at", "expires_at",
                  "remaining_seconds", "deadline_estimated", "pattern_keys"):
        event.setdefault(field, filled[field])
    event.setdefault("run_id", run_id)
    entry["event"] = event


def payload_for(entry, now_mono=None):
    """Fresh display payload; remaining time always recomputed from the ONE
    monotonic stamp so wall-clock jumps/reconnects never reset a deadline."""
    now_mono = time.monotonic() if now_mono is None else now_mono
    remaining = entry["created_mono"] + entry["timeout"] - now_mono
    payload = dict(entry["payload"])
    payload["created_at"] = entry["created_at"]
    payload["expires_at"] = entry["created_at"] + entry["timeout"]
    payload["remaining_seconds"] = max(0, math.ceil(remaining))
    payload["deadline_estimated"] = True
    return payload


def snapshot(inbox, *, adapter, run_id, live=None):
    """Reconcile registry entries against the EXACT core queue ids for this
    run. Returns (pending payloads oldest-first, available, overflow, revision).
    A queue id the registry cannot map is reported through available=False —
    never folded into an empty list, never merged by text hash (R3)."""
    session_key = _session_key(adapter, run_id)
    if live is None:
        live = _live(session_key)
    key = (id(adapter), run_id)
    pending, available, overflow = [], True, False
    with inbox["lock"]:
        bucket = inbox["by_run"].get(key)
        now_mono = time.monotonic()
        if bucket is not None:
            live_ids = [str(e.get("request_id")) for e in live]
            for rid, entry in bucket["entries"].items():
                if entry["phase"] == "pending" and rid not in live_ids:
                    entry["phase"], entry["outcome"] = "resolved", "settled"
                    bucket["revision"] += 1
            unknown = [rid for rid in live_ids if rid not in bucket["entries"]]
            if unknown:
                available = False
            pending = [payload_for(bucket["entries"][rid], now_mono)
                       for rid in live_ids
                       if rid in bucket["entries"]
                       and bucket["entries"][rid]["phase"] == "pending"]
            overflow = len(live) > INBOX_MAX_PENDING or bucket["degraded"]
            revision = bucket["revision"]
            stale = [rid for rid, e in bucket["entries"].items()
                     if e["phase"] != "pending"
                     and now_mono - (e.get("resolved_mono") or e["created_mono"]) > RESOLVED_TTL]
            for rid in stale:
                bucket["entries"].pop(rid, None)
        else:
            pending = []
            revision = 0
            overflow = len(live) > INBOX_MAX_PENDING
            if live:
                available = False  # queue pending with no captured payload: unmappable
    return pending, available, overflow, revision


def after_responded(inbox, adapter, run_id, request_id, choice, live=None):
    """approval.responded settled ONE exact request (or FIFO for a legacy
    answer): settle it and reconcile the queue. Returns the earliest still
    pending entry so the caller can restore waiting state, else None."""
    live = _live(_session_key(adapter, run_id)) if live is None else live
    if request_id:
        settle(inbox, adapter, run_id, str(request_id), choice or "answered")
    key = (id(adapter), run_id)
    with inbox["lock"]:
        bucket = inbox["by_run"].get(key)
        if bucket is None:
            return None
        live_ids = [str(e.get("request_id")) for e in live]
        for rid, entry in bucket["entries"].items():
            if entry["phase"] == "pending" and rid not in live_ids:
                entry["phase"], entry["outcome"] = "resolved", "settled"
                bucket["revision"] += 1
        bucket["revision"] += 1
        for rid in live_ids:  # queue order: earliest pending first
            entry = bucket["entries"].get(rid)
            if entry is not None and entry["phase"] == "pending":
                return entry
    return None


def settle_run(inbox, adapter, run_id, outcome, live=None):
    """Terminal/stop/unload path: settle every still-pending entry of a run."""
    key = (id(adapter), run_id)
    with inbox["lock"]:
        bucket = inbox["by_run"].get(key)
        if bucket is None:
            return []
        ids = [rid for rid, e in bucket["entries"].items() if e["phase"] == "pending"]
        bucket["revision"] += 1 if ids else 0
    for rid in ids:
        settle(inbox, adapter, run_id, rid, outcome)
    return ids


def classify_answer(inbox, *, adapter, run_id, body, epoch):
    """R3 submit contract, computed under a BRIEF core-lock read then released
    (the original handler/resolver keeps the final race decision):
      submit        -> forward to the native handler, with request_id exact
      passthrough   -> unknown id / nothing pending: let the core answer 409
      error         -> 409 epoch stale / 409 approval_request_required /
                       400 invalid choice for the immutable snapshot"""
    session_key = _session_key(adapter, run_id)
    raw_choice = str(body.get("choice", "")).strip().lower()
    choice = CHOICE_ALIASES.get(raw_choice, raw_choice)
    raw_id = body.get("request_id")
    request_id = raw_id.strip() if isinstance(raw_id, str) else ""
    claimed = body.get("server_epoch")
    if claimed is None:
        claimed = epoch
    if claimed is not None and inbox["epoch"] and str(claimed) != inbox["epoch"]:
        return {"action": "error", "status": 409, "code": "approval_epoch_stale",
                "message": "Approval epoch is stale; re-read the pending list."}
    api = __import__("sys").modules.get("gateway.platforms.api_server")
    _bool = getattr(api, "_coerce_request_bool", None) if api is not None else None
    if _bool is None:
        _bool = lambda value, default=False: bool(value)  # noqa: E731
    if any(_bool(body.get(key), default=False) for key in ("all", "resolve_all")):
        return {"action": "error", "status": 400, "code": "approval_scope_not_supported",
                "message": "Resolve-all is not supported; answer exact request ids."}
    from tools import approval as core
    with core._lock:  # brief snapshot: ids + immutable entry data, no await, no emit
        queue = core._gateway_queues.get(session_key, [])
        live = [e for e in queue]
        if request_id:
            entry = next((e for e in live if e.data.get("request_id") == request_id), None)
            if entry is None:
                return {"action": "passthrough"}  # core: 409 no-pending (id already answered)
            allowed = choices_from_data(entry.data)
            if choice not in allowed:
                return {"action": "error", "status": 400, "code": "invalid_approval_choice",
                        "message": "Invalid approval choice; expected one of: "
                                   + ", ".join(allowed)}
            return {"action": "submit", "request_id": request_id, "choice": choice}
        if len(live) == 1:
            return {"action": "submit",  # legacy single pending: exact backfill
                    "request_id": str(live[0].data.get("request_id")), "choice": choice,
                    "backfilled": True}
        if len(live) > 1:
            return {"action": "error", "status": 409, "code": "approval_request_required",
                    "message": "Several approvals are pending; submit the exact request_id."}
    return {"action": "passthrough"}  # nothing pending: the native 409 stands


def emit_resolved(inbox, adapter, loop, run_id, request_id, outcome):
    """Additive approval.resolved on both API surfaces (R2). Loop hop: callers
    may be worker threads; the run-stream queue is loop-owned."""
    def _emit():
        try:
            runs = __import__("sys").modules.get("gateway.platforms.api_server_runs")
            state = inbox["state"]
            if runs is None:
                return
            payload = runs._run_event(run_id, "approval.resolved",
                                      request_id=request_id, outcome=outcome,
                                      server_epoch=inbox["epoch"])
            queue = getattr(adapter, "_run_streams", {}).get(run_id)
            if queue is not None:
                queue.put_nowait(payload)
            mirror = state.get("approval_queues", {}).get((id(adapter), run_id))
            if mirror is not None:
                mirror.enqueue("approval.resolved", {
                    "request_id": request_id, "outcome": outcome,
                    "server_epoch": inbox["epoch"]})
        except Exception:
            pass  # observability only; the queue settlement already stands on its own
    if loop is None:
        _emit()
        return
    try:
        if loop.is_closed():
            return
        loop.call_soon_threadsafe(_emit)
    except RuntimeError:
        pass


def rebuild_event(inbox, adapter, entry):
    """A fresh approval.request payload for one still-pending entry (used to
    restore waiting state after another request was answered). Re-redaction of
    an already-redacted payload is idempotent; the core builder re-stamps."""
    api = __import__("sys").modules.get("gateway.platforms.api_server")
    if api is not None and callable(getattr(api, "_approval_request_event", None)):
        try:
            data = dict(entry["payload"])
            data.pop("choices", None)  # core builder re-derives from these captured flags
            data["allow_session"] = entry.get("flags", {}).get("allow_session", True)
            data["allow_permanent"] = entry.get("flags", {}).get("allow_permanent", True)
            for envelope in ("run_id", "session_id", "server_epoch", "created_at",
                             "expires_at", "remaining_seconds", "deadline_estimated"):
                data.pop(envelope, None)  # builder stamps its own envelope (never raw data)
            return api._approval_request_event(entry["run_id"], data)
        except Exception:
            pass
    event = dict(entry["payload"])
    event.pop("created_at", None)
    event.pop("expires_at", None)
    return event


def prune(inbox):
    now = time.monotonic()
    with inbox["lock"]:
        for key, bucket in list(inbox["by_run"].items()):
            stale = [rid for rid, e in bucket["entries"].items()
                     if e["phase"] != "pending"
                     and now - (e.get("resolved_mono") or e["created_mono"]) > RESOLVED_TTL]
            for rid in stale:
                bucket["entries"].pop(rid, None)
            if not bucket["entries"] and now - bucket["last_seen"] > RESOLVED_TTL:
                inbox["by_run"].pop(key, None)
