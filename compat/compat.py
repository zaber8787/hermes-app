"""Process-local compatibility hooks for Hermes 2a327c25af.

Upstream-dependent code deliberately lives in this one file. No core files are
written. The two copied API paths are source-fingerprinted before installation.
"""
from __future__ import annotations

import asyncio
import contextvars
from concurrent.futures import ThreadPoolExecutor
from contextlib import suppress
from functools import wraps
import hashlib
import inspect
import json
import logging
from pathlib import Path
import threading
import time
import urllib.parse

VERSION = "0.1.0"
BASELINE = "2a327c25af3eb146db7be627db4c2c3fc42e0494"
CAP = 500 * 1024 * 1024
EXTRA_MIMES = frozenset({
    "application/octet-stream", "application/zip", "application/x-zip-compressed",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation",
})
UNITS = ("limits", "upload", "media", "history", "approval", "skills", "activity")
log = logging.getLogger("hermes-app-compat")
_STATE = "_hermes_app_compat_state_v1"
_MISSING = object()
# WAVE4 activity unit: the registry slot is filled by _install_activity and read
# by the shared _session_stream copy; None means the unit is absent so that copy
# stays a no-op for activity and the approval unit is untouched.
_ACTIVITY = None
# Sync /api/sessions/{sid}/chat carries its request scope here (no run_id exists
# on that path) so the wrapped _run_agent can open a synthetic observation.
_SYNC_CHAT = contextvars.ContextVar("hermes_app_sync_chat", default=None)
ACTIVITY_OBJECT = "hermes.session.activity"
ACTIVITY_SCHEMA = 1
ACTIVITY_PREVIEW_CAP = 8192
ACTIVITY_ACTIVE_CAP = 8
ACTIVITY_RECENT_CAP = 32
ACTIVITY_RECENT_SHOW = 4
ACTIVITY_RECENT_TTL = 600.0
ACTIVITY_TERMINAL = frozenset({"completed", "failed", "cancelled", "interrupted"})
ACTIVITY_LIVE = frozenset({"queued", "running", "waiting_for_approval", "stopping"})
# Filled from clean HEAD source during development, never learned at runtime.
FINGERPRINTS = {
    "_handle_artifact_upload": "33ee0a4e339538291eac88f0713ab838d1577ba099e2cdb5b254dbc8ac21081f",
    "_handle_session_chat_stream": "136c074ac9d0ac6a071d9223eb6f004a445d7a7802f607f4c7c1fc01cc1d4fcf",
    "_run_agent": "614a8f2a559747b306933200ebd1dc21ac4e4f9acff2f90fea6917ee2e217c68"
}


class Transaction:
    def __init__(self):
        self.changes = []
        self.cleanups = []

    def set(self, target, name, value, *, mapping=False):
        old = target.get(name, _MISSING) if mapping else inspect.getattr_static(target, name, _MISSING)
        if callable(value):
            value.__hermes_app_compat__ = VERSION
        if mapping:
            target[name] = value
        else:
            setattr(target, name, value)
        self.changes.append((target, name, old, value, mapping))

    def restore(self):
        for cleanup in reversed(self.cleanups):
            try:
                cleanup()
            except Exception as exc:
                log.warning("cleanup failed: %s", type(exc).__name__)
        for target, name, old, value, mapping in reversed(self.changes):
            current = target.get(name, _MISSING) if mapping else inspect.getattr_static(target, name, _MISSING)
            if current is not value:
                log.warning("restore skipped third-party binding: %s", name)
                continue
            if old is _MISSING:
                if mapping:
                    target.pop(name, None)
                else:
                    delattr(target, name)
            elif mapping:
                target[name] = old
            else:
                setattr(target, name, old)
        self.changes.clear()
        self.cleanups.clear()


def _require(target, *names):
    for name in names:
        if not callable(getattr(target, name, None)):
            raise RuntimeError(f"missing callable {name}")


def _signature(target, name, *parameters):
    _require(target, name)
    present = inspect.signature(getattr(target, name)).parameters
    if not set(parameters) <= present.keys():
        raise RuntimeError(f"signature changed: {name}")


def _fingerprint(target, name):
    actual = hashlib.sha256(inspect.getsource(inspect.unwrap(getattr(target, name))).encode()).hexdigest()
    if actual != FINGERPRINTS[name]:
        raise RuntimeError(f"source changed: {name}")


def install(ctx):
    """Isolate each patch group; share ownership across profile plugin managers."""
    global api
    try:
        from gateway.platforms import api_server as api
        state = getattr(api, _STATE, None)
        if state is None:
            state = {"groups": {}, "manifest": {}, "lock": threading.RLock()}
            setattr(api, _STATE, state)
        # PluginContext is recreated by loader calls; manager+plugin is the owner.
        owner = (id(getattr(ctx, "_manager", ctx)), "hermes-app-compat")
        with state["lock"]:
            for unit in UNITS:
                tx = Transaction()
                try:
                    existing = state["groups"].get(unit)
                    if existing is not None:
                        if owner in existing["owners"]:
                            continue
                        existing["owners"].add(owner)
                    else:
                        status = globals()["_install_" + unit](tx)
                        existing = {"owners": {owner}, "tx": tx}
                        state["groups"][unit] = existing
                        state["manifest"][unit] = {"status": status or "applied"}

                    def release(unit=unit, owner=owner, existing=existing):
                        with state["lock"]:
                            existing["owners"].discard(owner)
                            if not existing["owners"] and state["groups"].get(unit) is existing:
                                existing["tx"].restore()
                                del state["groups"][unit]
                                state["manifest"][unit] = {"status": "unloaded_restart_required"}
                    try:
                        ctx.on_unload(release)
                    except Exception:
                        release()
                        raise
                except Exception as exc:
                    tx.restore()
                    state["manifest"][unit] = {"status": "skipped_incompatible", "reason": type(exc).__name__}
                    log.warning("%s skipped_incompatible: %s", unit, str(exc))
            log.info("hermes-app-compat manifest %s", json.dumps({
                "version": VERSION, "baseline": BASELINE, "restart_required_for_unload": True,
                "groups": state["manifest"]}, sort_keys=True))
    except Exception as exc:
        log.warning("hermes-app-compat manifest: all skipped_incompatible (%s)", type(exc).__name__)


def _install_limits(tx):
    from gateway import browser_control_artifacts as artifacts
    defaults = artifacts.ArtifactStore.__init__.__kwdefaults__
    if not defaults or not {"max_bytes", "allowed_mime_types"} <= defaults.keys():
        raise RuntimeError("ArtifactStore keyword defaults changed")
    for module in (artifacts, api):
        for name in ("DEFAULT_MAX_ARTIFACT_BYTES", "DEFAULT_ALLOWED_MIME_TYPES"):
            getattr(module, name)
    getattr(api, "MAX_REQUEST_BYTES")
    allowed = frozenset(artifacts.DEFAULT_ALLOWED_MIME_TYPES) | EXTRA_MIMES
    for module in (artifacts, api):
        tx.set(module, "DEFAULT_MAX_ARTIFACT_BYTES", CAP)
        tx.set(module, "DEFAULT_ALLOWED_MIME_TYPES", allowed)
    tx.set(api, "MAX_REQUEST_BYTES", CAP)
    tx.set(defaults, "max_bytes", CAP, mapping=True)
    tx.set(defaults, "allowed_mime_types", allowed, mapping=True)


def _install_upload(tx):
    _fingerprint(api.APIServerAdapter, "_handle_artifact_upload")
    tx.set(api.APIServerAdapter, "_handle_artifact_upload", _upload)


async def _upload(self, request):
    ctx, err = self._artifact_route_prelude(request, "upload")
    if err is not None:
        return err
    profile, principal = ctx
    content_type = request.headers.get("Content-Type", "")
    filename = request.headers.get("X-Artifact-Filename", "").strip()
    if not filename:
        return api._error_response("X-Artifact-Filename header is required.", 400)
    try:
        store = self._artifact_store_for(profile)
    except api.ArtifactError as exc:
        return api._error_response(str(exc), 500, code="artifact_rejected")
    cap = store.max_bytes
    chunks, total = [], 0
    try:
        while total <= cap:
            chunk = await request.content.read(min(1 << 20, cap + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
    except Exception:
        return api._error_response("Failed to read request body.", 400)
    if total > cap:
        return api._error_response(f"Artifact exceeds the {cap}-byte cap.", 413, code="artifact_too_large")
    if not total:
        return api._error_response("Empty artifact body.", 400)
    data = b"".join(chunks)
    chunks.clear()
    scope = api._ArtifactScopeFacade(principal, transport_family=self._browser_control_transport_family(request))
    try:
        receipt = store.store(data, filename=filename, content_type=content_type, scope=scope)
    except api.ArtifactTooLarge as exc:
        return api._error_response(str(exc), 413, code="artifact_too_large")
    except api.ArtifactError as exc:
        if "allowlist" in str(exc):
            return api._error_response(str(exc), 415, code="artifact_mime_rejected")
        return api._error_response(str(exc), 400, code="artifact_rejected")
    return api.web.json_response(
        receipt.to_dict(download_path=f"/v1/artifacts/download/{receipt.artifact_id}"), status=201)


def _install_media(tx):
    from gateway.platforms import base
    cls = api.APIServerAdapter
    _require(cls, "_http_route_table")
    _require(api, "_require_auth")
    _require(base, "validate_media_delivery_path")
    old_table = cls._http_route_table
    endpoint = ("media_download", ("GET", "/v1/media/download"))
    for name, route in api._CAPABILITY_ENDPOINTS:
        if (name == endpoint[0] or route == endpoint[1]) and (name, route) != endpoint:
            raise RuntimeError("media capability collision")
    if hasattr(cls, "_handle_media_download"):
        return "native_candidate"

    async def media(self, request):
        if not self._expected_api_key():
            return api._error_response("API_SERVER_KEY is required for media downloads", 403)
        safe = base.validate_media_delivery_path((request.query.get("path") or "").strip(), session_key="")
        if not safe:
            return api._error_response("Path is not an allowed media file", 400)
        path = Path(safe)
        try:
            size = path.stat().st_size
        except OSError:
            return api._error_response("File not found", 404)
        if size > CAP:
            return api._error_response(f"File too large ({size} bytes; cap {CAP})", 413)
        return api.web.FileResponse(path, headers={
            "Content-Disposition": "attachment; filename*=UTF-8''" + urllib.parse.quote(path.name, safe="")})

    @wraps(old_table)
    def routes(self):
        rows = list(old_table(self))
        if not any((method, path) == endpoint[1] for method, path, _ in rows):
            rows.append((*endpoint[1], self._handle_media_download))
        return rows
    tx.set(cls, "_handle_media_download", api._require_auth(media))
    tx.set(cls, "_http_route_table", routes)
    if endpoint not in api._CAPABILITY_ENDPOINTS:
        tx.set(api, "_CAPABILITY_ENDPOINTS", (*api._CAPABILITY_ENDPOINTS, endpoint))


def _install_history(tx):
    cls = api.APIServerAdapter
    descriptor = inspect.getattr_static(cls, "_message_response")
    if not isinstance(descriptor, staticmethod):
        raise RuntimeError("_message_response is no longer static")
    _require(api, "_resolve_media_to_data_urls")
    original = descriptor.__func__
    warned = False

    @wraps(original)
    def message(row):
        nonlocal warned
        result = original(row)
        if not isinstance(result.get("content"), str):
            return result
        try:
            return {**result, "content": api._resolve_media_to_data_urls(result["content"])}
        except Exception:
            if not warned:
                log.warning("history resolver failed; preserving projected content")
                warned = True
            return result
    message.__hermes_app_compat__ = VERSION
    tx.set(cls, "_message_response", staticmethod(message))


def _install_skills(tx):
    from tools import skills_tool
    original = skills_tool._find_all_skills
    params = inspect.signature(original).parameters
    if "skip_disabled" not in params:
        raise RuntimeError("skills signature changed")
    accepts_all = any(p.kind == p.VAR_KEYWORD for p in params.values())
    warned = set()

    @wraps(original)
    def skills(*, skip_disabled=False, **kwargs):
        if not accepts_all:
            for name in kwargs.keys() - params.keys():
                if name != "include_editorial" and name not in warned:
                    log.warning("skills ignoring unsupported keyword: %s", name)
                    warned.add(name)
            kwargs = {k: v for k, v in kwargs.items() if k in params}
        return original(skip_disabled=skip_disabled, **kwargs)
    tx.set(skills_tool, "_find_all_skills", skills)


# ---- activity unit (WAVE4: cross-device live run snapshot) -------------------
# Registry shape (process-global in the compat state, shared across managers):
#   runs/obs: run_id / obs_id -> entry; entry = {key, run_id, observation_id,
#     sessions(set), scope, source, status, started_at, ended_at, user, after_id,
#     reason, ended}  — ended is the active/terminal switch, status "unknown"
#     means "no confirmable terminal fact" (the app must NOT read it as idle).
#   by_session: (id(adapter), sid) -> set(keys) — index, never a history scan.
#   recent: (id(adapter), sid) -> [entry] — terminal memory, TTL/LRU-pruned.
#   revision: one monotonic process counter (activity_revision).
#   blind: reason string once an unregistered live run or a hook fault proves the
#     snapshot cannot claim coverage -> every snapshot answers 503, never a
#     fabricated idle / empty active_runs.

def _activity_preview(message):
    """Client-facing text preview only: displayable text plus an attachment
    placeholder, <=8KiB UTF-8 without cutting a code point. Never the raw POST
    (instructions / inline media may be huge)."""
    if isinstance(message, str):
        text, attached = message, False
    elif isinstance(message, list):
        parts, attached = [], False
        for part in message:
            if isinstance(part, dict) and isinstance(part.get("text"), str):
                parts.append(part["text"])
            else:
                attached = True
        text, attached = "\n".join(parts), attached
    else:
        return None
    if attached:
        text = (text + "\n" if text else "") + "[附件]"
    raw = text.encode("utf-8")
    if len(raw) <= ACTIVITY_PREVIEW_CAP:
        return {"text": text, "truncated": False}
    cut = raw[:ACTIVITY_PREVIEW_CAP]
    while True:
        try:
            return {"text": cut.decode("utf-8"), "truncated": True}
        except UnicodeDecodeError:
            cut = cut[:-1]


def _activity_new_entry(run_id=None, obs_id=None):
    return {
        "key": ("r", run_id) if run_id is not None else ("o", obs_id),
        "run_id": run_id,
        "observation_id": run_id if run_id is not None else obs_id,
        "sessions": set(), "scope": None, "source": None,
        "status": "queued", "started_at": time.time(), "ended_at": None,
        "user": None, "after_id": None, "reason": None, "ended": False,
    }


def _activity_fault(registry, reason):
    # Observation faults are logged WITHOUT content; the snapshot then answers
    # 503 instead of pretending idle (spec: 禁回偽 idle/空 active_runs).
    registry["blind"] = "fault:" + reason
    log.warning("activity snapshot coverage fault: %s", reason)


def _activity_index(registry, adapter, entry, sid):
    if sid is None or sid in entry["sessions"]:
        return
    entry["sessions"].add(sid)
    registry["by_session"].setdefault((id(adapter), sid), set()).add(entry["key"])


def _activity_prune_recent(registry):
    deadline = time.time() - ACTIVITY_RECENT_TTL
    for bucket in registry["recent"].values():
        while bucket and (bucket[-1]["ended_at"] < deadline
                          or len(bucket) > ACTIVITY_RECENT_CAP):
            bucket.pop()


def _activity_finish(registry, adapter, entry, status, reason=None):
    with registry["lock"]:
        if registry["closed"] or entry["ended"]:
            return
        entry["ended"] = True
        entry["status"] = status
        entry["ended_at"] = time.time()
        entry["reason"] = reason
        if entry["run_id"] is not None:
            registry["runs"].pop(entry["run_id"], None)
        else:
            registry["obs"].pop(entry["observation_id"], None)
        for sid in entry["sessions"]:
            registry["by_session"].get((id(adapter), sid), set()).discard(entry["key"])
            registry["recent"].setdefault((id(adapter), sid), []).insert(0, entry)
        _activity_prune_recent(registry)
        registry["revision"] += 1


def _activity_track(registry, adapter, *, run_id=None, obs_id=None, session_id=None,
                    scope=None, source=None, status=None):
    """Create-or-fetch one entry under the lock; never waits, never reads DB."""
    with registry["lock"]:
        if registry["closed"]:
            return None
        if run_id is not None:
            entry = registry["runs"].get(run_id)
            if entry is None:
                entry = _activity_new_entry(run_id=run_id)
                if status is not None:
                    entry["status"] = status
                registry["runs"][run_id] = entry
                registry["seen_runs"].add(run_id)
                registry["revision"] += 1
        else:
            entry = registry["obs"].get(obs_id)
            if entry is None:
                entry = _activity_new_entry(obs_id=obs_id)
                entry["status"] = "running"
                registry["obs"][obs_id] = entry
                registry["revision"] += 1
        if scope is not None:
            entry["scope"] = scope
        if source is not None and entry["user"] is None:
            entry["source"] = source
        _activity_index(registry, adapter, entry, session_id)
        return entry


async def _activity_thread(registry, fn, *args):
    # Activity's own DB reads must never queue behind held agent turns on the
    # default executor (that would stall snapshots exactly when they matter).
    executor = registry.get("io")
    if executor is None:
        executor = registry["io"] = ThreadPoolExecutor(
            max_workers=2, thread_name_prefix="hermes-app-activity")
    return await asyncio.get_running_loop().run_in_executor(executor, fn, *args)


async def _activity_last_id(registry, adapter, session_id):
    """Read-only index tail (id only) for after_id / history_revision."""
    db = await adapter._ensure_session_db_async()
    if db is None:
        raise RuntimeError("session db unavailable")
    clause = db._active_clause(False, False)

    def read():
        row = db._read_one(
            "SELECT id FROM messages WHERE session_id = ?" + clause
            + " ORDER BY id DESC LIMIT 1", (session_id,))
        return int(row["id"]) if row else 0
    return await _activity_thread(registry, read)


async def _activity_stream_register(adapter, run_id, session_id, user_message):
    """compat._session_stream hook: after owner+queued, before create_task."""
    registry = globals().get("_ACTIVITY")
    if registry is None or registry["closed"]:
        return
    entry = _activity_track(registry, adapter, run_id=run_id, session_id=session_id,
                            scope=adapter._run_owners.get(run_id),
                            source="session_stream")
    if entry is None:
        return
    try:
        after = await _activity_last_id(registry, adapter, session_id)
    except Exception:
        after = None  # preview stays usable; the app keeps the projection until history
    with registry["lock"]:
        if entry["ended"]:
            return
        entry["source"] = "session_stream"
        entry["user"] = _activity_preview(user_message)
        if after is not None and entry["after_id"] is None:
            entry["after_id"] = after
        registry["revision"] += 1


def _activity_status_hook(registry, adapter, run_id, status):
    with registry["lock"]:
        if registry["closed"]:
            return
        current = adapter._run_statuses.get(run_id) or {}
        sid = current.get("session_id")
        entry = registry["runs"].get(run_id)
        if entry is None:
            if status in ACTIVITY_TERMINAL:
                registry["seen_runs"].add(run_id)  # known-settled outside HTTP paths: not a gap
                return
            entry = _activity_new_entry(run_id=run_id)
            entry["status"] = status
            entry["started_at"] = current.get("created_at") or entry["started_at"]
            if sid is None:
                # An unregistered, unattributable LIVE run proves a coverage gap.
                registry["runs"][run_id] = entry
                registry["seen_runs"].add(run_id)
                registry["blind"] = "unattributed-run"
                return
            entry["scope"] = adapter._run_owners.get(run_id)
            entry["source"] = "run_status"
            registry["runs"][run_id] = entry
            registry["seen_runs"].add(run_id)
            _activity_index(registry, adapter, entry, sid)
            registry["revision"] += 1
            return
        entry["status"] = status
        _activity_index(registry, adapter, entry, sid)
        registry["revision"] += 1
        if status in ACTIVITY_TERMINAL:
            _activity_finish(registry, adapter, entry, status)


def _activity_coverage(registry, adapter):
    """Runs the hooks never saw (created before install, or a missed path) mean
    the snapshot cannot claim coverage -> 503. The scan is over the ACTIVE run
    dicts only (bounded), never over history."""
    with registry["lock"]:
        if registry["closed"] or registry["blind"]:
            return
        live = set(adapter._active_run_tasks) | set(adapter._active_run_agents)
        for run_id in live:
            if run_id not in registry["runs"] and run_id not in registry["seen_runs"]:
                registry["blind"] = "unregistered-live-run"
                return


def _activity_settle(registry, adapter, run_id, reason):
    """Executor/task ended with no confirmable terminal status: land honestly in
    recent as unknown+reason, never a fake running/queued ghost."""
    entry = registry["runs"].get(run_id)
    if entry is None:
        return
    if not entry["ended"]:
        _activity_finish(registry, adapter, entry, "unknown", reason)


def _install_activity(tx):
    from gateway.platforms import api_server_runs as runs
    global _ACTIVITY
    cls = api.APIServerAdapter
    state = getattr(api, _STATE, None)
    if state is None:
        raise RuntimeError("compat state missing")
    # The session-SSE preview rides on the approval unit's _session_stream copy.
    if state["groups"].get("approval") is None or \
            state["manifest"].get("approval", {}).get("status") != "applied":
        raise RuntimeError("approval unit not applied")
    _require(cls, "_set_run_status", "_prepare_session_chat", "_handle_session_chat",
             "_run_agent", "_handle_runs", "_get_existing_session_or_404",
             "_request_owns_run", "_run_idempotency_scope", "_room_grant_token",
             "_ensure_session_db_async", "_session_db_unavailable", "_http_route_table")
    _require(runs, "_execute_run", "_set_run_status")
    _require(api, "_error_response")
    _signature(cls, "_set_run_status", "self", "run_id", "status", "fields")
    _signature(cls, "_prepare_session_chat", "self", "request")
    _signature(cls, "_handle_session_chat", "self", "request")
    _signature(runs, "_execute_run", "self", "run")

    registry = state.get("activity")
    if registry is None:
        registry = state["activity"] = {
            "lock": threading.RLock(), "runs": {}, "obs": {}, "seen_runs": set(),
            "by_session": {}, "recent": {}, "revision": 0, "blind": None,
            "closed": False,
        }
        state["activity_epoch"] = api.uuid.uuid4().hex[:12]
    registry["blind"] = None  # a fresh install re-claims coverage (restart semantics)
    _ACTIVITY = registry

    def deactivate():
        # The mounted route outlives the hooks until restart (manifest already
        # declares unload restart-required): after that the snapshot answers 503
        # instead of serving a registry nobody updates anymore.
        registry["blind"] = "unit-unloaded"
    tx.cleanups.append(deactivate)

    # -- endpoint: GET /api/sessions/{session_id}/activity ----------------------
    old_table = cls._http_route_table
    endpoint = ("session_activity", ("GET", "/api/sessions/{session_id}/activity"))
    for name, route in api._CAPABILITY_ENDPOINTS:
        if (name == endpoint[0] or route == endpoint[1]) and (name, route) != endpoint:
            raise RuntimeError("activity capability collision")
    if hasattr(cls, "_handle_session_activity"):
        return "native_candidate"

    async def snapshot(self, request):
        try:
            return await _activity_snapshot(registry, state, self, request)
        except Exception as exc:
            # A snapshot error must never degrade into idle.
            log.warning("activity snapshot failed: %s", type(exc).__name__)
            return api._error_response("Session activity snapshot unavailable.", 503,
                                       code="activity_unavailable")

    async def guarded(self, request, *args, **kwargs):
        # Room-grant-only tokens are explicitly refused here (403): run control's
        # room permission must not read as a session-read permission.
        if self._room_grant_token(request):
            return api._error_response("Room grants may not read session activity.",
                                       403, code="room_grant_not_allowed")
        auth_err = self._check_auth(request)
        if auth_err:
            return auth_err
        return await snapshot(self, request, *args, **kwargs)

    @wraps(old_table)
    def routes(self):
        rows = list(old_table(self))
        if not any((m, p) == endpoint[1] for m, p, _ in rows):
            rows.append((*endpoint[1], self._handle_session_activity))
        return rows
    tx.set(cls, "_handle_session_activity", guarded)
    tx.set(cls, "_http_route_table", routes)
    if endpoint not in api._CAPABILITY_ENDPOINTS:
        tx.set(api, "_CAPABILITY_ENDPOINTS", (*api._CAPABILITY_ENDPOINTS, endpoint))

    # -- status hook: wrap the adapter method every path funnels through -------
    old_set = cls._set_run_status

    @wraps(old_set)
    def set_status(self, run_id, status, **fields):
        result = old_set(self, run_id, status, **fields)
        try:
            _activity_status_hook(registry, self, run_id, status)
        except Exception as exc:
            _activity_fault(registry, type(exc).__name__)
        return result
    tx.set(cls, "_set_run_status", set_status)

    # -- /v1/runs: fill the preview before the turn starts; final safety net ---
    old_exec = runs._execute_run

    @wraps(old_exec)
    async def execute(self, launch, **kwargs):
        try:
            entry = _activity_track(registry, self, run_id=launch.run_id,
                                    session_id=launch.session_id,
                                    scope=self._run_owners.get(launch.run_id),
                                    source="runs_api")
            if entry is not None and entry["user"] is None:
                try:
                    after = await _activity_last_id(registry, self, launch.session_id)
                except Exception:
                    after = None
                with registry["lock"]:
                    if not entry["ended"]:
                        entry["source"] = "runs_api"
                        entry["user"] = _activity_preview(launch.user_message)
                        if after is not None and entry["after_id"] is None:
                            entry["after_id"] = after
                        registry["revision"] += 1
        except Exception as exc:
            _activity_fault(registry, type(exc).__name__)
        try:
            return await old_exec(self, launch, **kwargs)
        finally:
            try:
                _activity_settle(registry, self, launch.run_id, "executor-end")
            except Exception as exc:
                _activity_fault(registry, type(exc).__name__)
    tx.set(runs, "_execute_run", execute)

    # -- POST /v1/runs: a task cancelled BEFORE first execution never enters
    # the coroutine above; its done-callback is the only cleanup point.
    old_runs = runs._handle_runs

    @wraps(old_runs)
    async def handle_runs(self, request, **kwargs):
        result = await old_runs(self, request, **kwargs)
        try:
            import json as _json
            body = getattr(result, "body", None)
            payload = _json.loads(body) if isinstance(body, (bytes, str)) else {}
            run_id = payload.get("run_id") if isinstance(payload, dict) else None
            task = self._active_run_tasks.get(run_id) if run_id else None
            if task is not None:
                def done(task, self=self, run_id=run_id):
                    try:
                        _activity_settle(registry, self, run_id, "task-ended")
                    except Exception:
                        pass
                task.add_done_callback(done)
        except Exception:
            pass  # observability only; the accepted response stands
        return result
    tx.set(runs, "_handle_runs", handle_runs)

    # -- synchronous /api/sessions/{sid}/chat: no run_id exists, so the request
    # scope captured at prepare time + the ContextVar mark a synthetic obs.
    old_prep = cls._prepare_session_chat

    @wraps(old_prep)
    async def prep(self, request, *args, **kwargs):
        ctx, err = await old_prep(self, request, *args, **kwargs)
        if err is None and request.path.rstrip("/").endswith("/chat"):
            try:
                _SYNC_CHAT.set({
                    "scope": self._run_idempotency_scope(request),
                    "session_id": ctx.get("session_id"),
                })
            except Exception as exc:
                _activity_fault(registry, type(exc).__name__)
        return ctx, err
    tx.set(cls, "_prepare_session_chat", prep)

    old_chat = cls._handle_session_chat

    @wraps(old_chat)
    async def chat(self, request, *args, **kwargs):
        token = _SYNC_CHAT.set(None)
        try:
            return await old_chat(self, request, *args, **kwargs)
        finally:
            _SYNC_CHAT.reset(token)
    tx.set(cls, "_handle_session_chat", chat)

    # -- the installed _run_agent (approval wrapper underneath): open/close the
    # synthetic obs ONLY for a marked sync-chat call without active_run_id; the
    # SSE path always carries active_run_id and must not double-register.
    old_agent = cls._run_agent

    @wraps(old_agent)
    async def agent(self, *args, **kwargs):
        ctx = _SYNC_CHAT.get()
        entry = None
        if ctx is not None and kwargs.get("active_run_id") is None:
            try:
                obs_id = "obs_" + api.uuid.uuid4().hex
                entry = _activity_track(registry, self, obs_id=obs_id,
                                        session_id=ctx.get("session_id"),
                                        scope=ctx.get("scope"), source="session_sync")
                if entry is not None:
                    try:
                        after = await _activity_last_id(
                            registry, self, kwargs.get("session_id") or ctx.get("session_id"))
                    except Exception:
                        after = None
                    with registry["lock"]:
                        if not entry["ended"]:
                            entry["user"] = _activity_preview(kwargs.get("user_message"))
                            if after is not None and entry["after_id"] is None:
                                entry["after_id"] = after
                            registry["revision"] += 1
            except Exception as exc:
                entry = None
                _activity_fault(registry, type(exc).__name__)
        try:
            result = await old_agent(self, *args, **kwargs)
        except asyncio.CancelledError:
            if entry is not None:
                _activity_finish(registry, self, entry, "cancelled", "sync-chat")
            raise
        except Exception:
            if entry is not None:
                _activity_finish(registry, self, entry, "failed", "sync-chat")
            raise
        if entry is not None:
            _activity_finish(registry, self, entry, "completed", "sync-chat")
        return result
    tx.set(cls, "_run_agent", agent)


async def _activity_snapshot(registry, state, self, request):
    if registry["closed"] or registry["blind"]:
        return api._error_response("Session activity snapshot unavailable.", 503,
                                   code="activity_unavailable")
    sid = request.match_info["session_id"]
    session, err = await self._get_existing_session_or_404(sid)
    if err is not None:
        return err
    db = await self._ensure_session_db_async()
    if db is None:
        return self._session_db_unavailable()
    resolved = sid
    try:
        resolver = getattr(db, "resolve_resume_session_id", None)
        if callable(resolver):
            resolved = str(await _activity_thread(registry, resolver, sid)) or sid
    except Exception:
        resolved = sid  # fail open to the declared id; revision fields still honest
    count = session.get("message_count")
    latest_id = await _activity_last_id(registry, self, resolved)
    if resolved != sid:
        meta = await _activity_thread(registry, db.get_session, resolved)
        if meta is None:
            return api._error_response(f"Session not found: {sid}", 404,
                                       code="session_not_found")
        count = meta.get("message_count")
    if not isinstance(count, int):
        raise RuntimeError("session count unreadable")
    _activity_coverage(registry, self)
    if registry["blind"]:
        return api._error_response("Session activity snapshot unavailable.", 503,
                                   code="activity_unavailable")
    scope = self._run_idempotency_scope(request)
    with registry["lock"]:
        keys = set(registry["by_session"].get((id(self), sid), set()))
        keys |= registry["by_session"].get((id(self), resolved), set())
        candidates = []
        for key in keys:
            entry = (registry["runs"].get(key[1])
                     if key[0] == "r" else registry["obs"].get(key[1]))
            if entry is not None and not entry["ended"]:
                candidates.append(entry)
        # agent.session_id carries a mid-turn compression rotation: read that ONE
        # scalar (never the transcript) so a run whose live tip moved is still
        # found under the requested/resolved ids, and deduped by observation_id.
        wanted = {sid, resolved}
        for entry in list(registry["runs"].values()):
            if entry["ended"] or entry["run_id"] is None or any(e is entry for e in candidates):
                continue
            agent = self._active_run_agents.get(entry["run_id"])
            if getattr(agent, "session_id", None) in wanted:
                candidates.append(entry)
                _activity_index(registry, self, entry,
                                getattr(agent, "session_id", None))
        buckets = []
        for skey in {sid, resolved} | {s for e in candidates for s in e["sessions"]}:
            buckets.extend(registry["recent"].get((id(self), skey), ()))
    seen, active = set(), []
    for entry in sorted(candidates, key=lambda e: e["started_at"]):
        if entry["observation_id"] in seen:
            continue
        seen.add(entry["observation_id"])
        active.append(entry)
    overflow = len(active) > ACTIVITY_ACTIVE_CAP
    recent = []
    for entry in sorted(buckets, key=lambda e: e["ended_at"] or 0.0, reverse=True):
        if entry["observation_id"] in seen or (entry["ended_at"] or 0) < \
                time.time() - ACTIVITY_RECENT_TTL:
            continue
        seen.add(entry["observation_id"])
        recent.append(entry)
    recent = recent[:ACTIVITY_RECENT_SHOW]

    def project(entry, terminal):
        owned = (self._request_owns_run(request, entry["run_id"])
                 if entry["run_id"] is not None else entry["scope"] == scope)
        row = {"observation_id": entry["observation_id"], "run_id": entry["run_id"],
               "status": entry["status"], "started_at": entry["started_at"],
               "source": entry["source"] or "run_status"}
        if terminal:
            row["ended_at"] = entry["ended_at"]
            if entry["reason"]:
                row["reason"] = entry["reason"]
        if owned and entry["user"] is not None:
            row["user"] = {**entry["user"], "after_id": entry["after_id"]}
        return row
    payload = {
        "object": ACTIVITY_OBJECT, "schema_version": ACTIVITY_SCHEMA,
        "session_id": sid, "resolved_session_id": resolved,
        "server_epoch": state["activity_epoch"], "observed_at": time.time(),
        "coverage": "api_process",
        "history_revision": {"session_id": resolved, "count": count,
                             "latest_id": latest_id},
        "activity_revision": registry["revision"],
        "active_runs": [project(e, False) for e in active[:ACTIVITY_ACTIVE_CAP]],
        "recent_terminal": [project(e, True) for e in recent],
        "overflow": overflow,
    }
    return api.web.json_response(payload, headers={"Cache-Control": "no-store"})


class _Bridge:
    def __init__(self, adapter, run_id, events, bridges):
        from tools import approval, approval_context
        self.approval, self.context = approval, approval_context
        self.adapter, self.run_id, self.events = adapter, run_id, events
        self.loop = asyncio.get_running_loop()
        self.lock, self.closed = threading.RLock(), False
        self.bridges = bridges
        bridges[(id(adapter), run_id)] = self
        adapter._run_approval_sessions[run_id] = run_id

    def enter(self):
        token = self.context.set_current_session_key(self.run_id)
        try:
            with self.lock:
                if self.closed:
                    raise asyncio.CancelledError()
                self.approval.register_gateway_notify(self.run_id, self.notify)
            return token
        except BaseException:
            self.context.reset_current_session_key(token)
            raise

    def notify(self, data):
        with self.lock:
            if self.closed:
                raise RuntimeError("approval bridge is closed")
        from gateway.run import _redact_approval_command
        event = dict(data)
        if "command" in event:
            event["command"] = _redact_approval_command(event["command"])
        event["choices"] = api._approval_event_choices(
            smart_denied=bool(event.get("smart_denied")),
            allow_session=event.get("allow_session") is not False,
            allow_permanent=event.get("allow_permanent") is not False)
        self.loop.call_soon_threadsafe(self.publish, event)

    def publish(self, event):
        if self.closed or self.adapter._run_statuses.get(self.run_id, {}).get("status") in {
                "completed", "failed", "cancelled", "stopping"}:
            return
        event.update(run_id=self.run_id, session_id=self.events.session_id)
        self.adapter._set_run_status(self.run_id, "waiting_for_approval",
                                     last_event="approval.request", approval=event)
        self.events.enqueue("approval.request", event)

    def forget(self):
        key = (id(self.adapter), self.run_id)
        if self.bridges.get(key) is self:
            self.bridges.pop(key)
            if self.adapter._run_approval_sessions.get(self.run_id) == self.run_id:
                self.adapter._run_approval_sessions.pop(self.run_id, None)
            self.adapter._release_run_owner_if_forgotten(self.run_id)

    def close(self):
        with self.lock:
            if not self.closed:
                self.closed = True
                self.approval.unregister_gateway_notify(self.run_id)
        try:
            on_loop = asyncio.get_running_loop() is self.loop
        except RuntimeError:
            on_loop = False
        if on_loop:
            self.forget()
        elif not self.loop.is_closed():
            self.loop.call_soon_threadsafe(self.forget)


def _install_approval(tx):
    from tools import approval, approval_context
    from gateway.platforms import api_server_runs as runs
    cls = api.APIServerAdapter
    for name in ("_handle_session_chat_stream", "_run_agent"):
        _fingerprint(cls, name)
    _require(cls, "_drain_session_stream_task_on_disconnect", "_release_run_owner_if_forgotten")
    _require(runs, "_mark_run_event", "_handle_stop_run", "_handle_run_approval")
    _require(approval, "_gateway_notify_cb", "register_gateway_notify", "unregister_gateway_notify",
             "_is_unattended_platform_approval_context")
    _require(approval_context, "_is_unattended_platform_approval_context", "get_current_session_key",
             "set_current_session_key", "reset_current_session_key", "_get_session_platform")
    original_predicate = approval_context._is_unattended_platform_approval_context
    old_agent, old_event, old_stop = cls._run_agent, runs._mark_run_event, runs._handle_stop_run
    old_drain = cls._drain_session_stream_task_on_disconnect
    _signature(cls, "interrupt_active_runs", "self", "reason")
    _signature(cls, "_drain_session_stream_task_on_disconnect", "self", "run_id", "task", "interrupt_message", "shield_wait")
    _signature(runs, "_handle_stop_run", "self", "request", "_api_server")
    _signature(runs, "_handle_run_approval", "self", "request", "_api_server")
    _signature(runs, "_mark_run_event", "self", "run_id", "name")
    _signature(approval, "register_gateway_notify", "session_key", "cb")
    _signature(approval, "unregister_gateway_notify", "session_key")
    old_interrupt = cls.interrupt_active_runs
    bridges = {}

    def predicate():
        if approval_context._get_session_platform() == "api_server":
            try:
                key = approval_context.get_current_session_key(default="")
                if key and callable(approval._gateway_notify_cb(key)):
                    return False
            except Exception:
                log.warning("approval listener lookup failed; original policy retained")
        return original_predicate()

    @wraps(old_agent)
    async def agent(self, *args, _compat_approval=None, **kwargs):
        if _compat_approval is None:
            return await old_agent(self, *args, **kwargs)
        return await _session_agent(self, *args, _compat_approval=_compat_approval, **kwargs)

    def make_bridge(adapter, run_id, events):
        return _Bridge(adapter, run_id, events, bridges)

    async def stream(self, request):
        return await _session_stream(self, request, _make_bridge=make_bridge)

    @wraps(old_event)
    def event(self, run_id, name, **fields):
        result = old_event(self, run_id, name, **fields)
        bridge = bridges.get((id(self), run_id))
        if bridge is not None and not bridge.closed:
            bridge.events.enqueue(name, fields)
        return result

    @wraps(old_stop)
    async def stop(self, request, **kwargs):
        result = await old_stop(self, request, **kwargs)
        run_id = request.match_info.get("run_id")
        bridge = bridges.get((id(self), run_id))
        status = self._run_statuses.get(run_id, {}).get("status")
        if result.status < 300 and status in {"stopping", "completed", "failed", "cancelled"} and bridge:
            bridge.close()
        return result

    @wraps(old_drain)
    async def drain(self, run_id, task, **kwargs):
        bridge = bridges.get((id(self), run_id))
        if bridge:
            bridge.close()
        return await old_drain(self, run_id, task, **kwargs)

    @wraps(old_interrupt)
    def interrupt(self, reason):
        try:
            return old_interrupt(self, reason)
        finally:
            # Shutdown has no request/SSE disconnect to wake a blocked guard.
            for bridge in list(bridges.values()):
                if bridge.adapter is self:
                    bridge.close()

    def close_all():
        for bridge in list(bridges.values()):
            bridge.close()
    tx.cleanups.append(close_all)
    tx.set(approval_context, "_is_unattended_platform_approval_context", predicate)
    tx.set(approval, "_is_unattended_platform_approval_context", predicate)
    tx.set(cls, "_run_agent", agent)
    tx.set(cls, "_handle_session_chat_stream", api._admit_api_agent_request(stream))
    tx.set(runs, "_mark_run_event", event)
    tx.set(runs, "_handle_stop_run", stop)
    tx.set(cls, "_drain_session_stream_task_on_disconnect", drain)
    tx.set(cls, "interrupt_active_runs", interrupt)


# Reviewed upstream copies at Hermes revision 2a327c25af3eb146db7be627db4c2c3fc42e0494.
async def _session_stream(self, request: "web.Request", *, _make_bridge) -> "web.StreamResponse":
    """POST /api/sessions/{session_id}/chat/stream — SSE wrapper over _run_agent."""
    limited = self._concurrency_limited_response()
    if limited is not None:
        return limited
    ctx, err = await self._prepare_session_chat(request)
    if err is not None:
        return err
    gateway_session_key, session_id = ctx["gateway_session_key"], ctx["session_id"]
    user_message, runtime_request = ctx["user_message"], ctx["runtime_request"]
    runtime_meta = self._sanitize_runtime_metadata(
        requested_runtime=runtime_request.get("requested"),
        route_source=runtime_request.get("route_source") or "global",
        model_lock=("accepted" if ctx["lock_active"] else ""))
    message_id = f"msg_{api.uuid.uuid4().hex}"
    run_id = f"run_{api.uuid.uuid4().hex}"
    events = api._SessionEventQueue(session_id, run_id)
    queue, _event_payload = events.queue, events.payload
    # Claim ownership inside the request's profile scope before any run-keyed state
    # exists, so /v1/runs/{id}* control is confined to the starting profile.
    # See #93689.
    self._run_owners[run_id] = self._run_idempotency_scope(request)
    self._set_run_status(
        run_id, "queued", session_id=session_id, model=ctx["body"].get("model", self._model_name))

    bridge = _make_bridge(self, run_id, events)
    if globals().get("_ACTIVITY") is not None:
        # WAVE4 activity: owner + queued exist, the task has not started, and
        # registration must not wait for the turn. Errors here never fail the
        # real turn; the activity unit reports the gap itself.
        try:
            await _activity_stream_register(self, run_id, session_id, user_message)
        except Exception as exc:
            log.warning("activity registration skipped: %s", type(exc).__name__)

    def _delta(delta: str) -> None:
        if delta:
            events.enqueue("assistant.delta", {"message_id": message_id, "delta": delta})

    def _tool_progress(event_type: str, tool_name: str = None, preview: str = None, args=None, **kwargs) -> None:
        if event_type == "reasoning.available":
            events.enqueue("tool.progress", {"message_id": message_id, "tool_name": tool_name or "_thinking", "delta": preview or ""})
        elif event_type in {"tool.started", "tool.completed", "tool.failed"}:
            events.enqueue(event_type, {"message_id": message_id, "tool_name": tool_name, "preview": preview, "args": args})

    def _commentary(text: str, *, already_streamed: bool = False) -> None:
        # Mid-turn assistant commentary (Codex ``phase="commentary"``, text beside tool calls)
        # as its own typed event — never folded into ``assistant.completed`` (#67580).
        if isinstance(text, str) and text.strip():
            events.enqueue("assistant.commentary", {
                "message_id": message_id, "text": text, "already_streamed": bool(already_streamed)})

    async def _run_and_signal() -> None:
        try:
            await queue.put(_event_payload("run.started", {
                "user_message": {"role": "user", "content": user_message},
                "runtime": runtime_meta}))
            self._set_run_status(run_id, "running", last_event="run.started")
            await queue.put(_event_payload("message.started", {"message": {"id": message_id, "role": "assistant"}}))
            history = await self._conversation_history_for_session(session_id)
            result, usage = await self._run_agent(
                conversation_history=history, stream_delta_callback=_delta,
                tool_progress_callback=_tool_progress, interim_assistant_callback=_commentary,
                active_run_id=run_id, _compat_approval=bridge, **ctx["run_kwargs"])
            is_dict = isinstance(result, dict)
            final_response = api._resolve_media_to_data_urls(result.get("final_response", "") if is_dict else "")
            effective_session_id = result.get("session_id", session_id) if is_dict else session_id
            turn_messages = self._turn_transcript_messages(history, user_message, result) if is_dict else []
            effective_runtime = self._effective_turn_runtime(runtime_request, result, usage)
            # Terminal status and flags come from the result (interrupted -> cancelled,
            # unfinished -> failed); a late steer rides along as ``pending_steer`` for replay.
            status, fields = api._api_runs.terminal_run_status(result if is_dict else {})
            await queue.put(_event_payload("assistant.completed", {
                "session_id": effective_session_id, "message_id": message_id,
                "content": final_response, **fields, "runtime": effective_runtime}))
            await queue.put(_event_payload(f"run.{status}", {
                "session_id": effective_session_id, "message_id": message_id, **fields,
                "messages": turn_messages, "usage": usage, "runtime": effective_runtime}))
            self._set_run_status(
                run_id, status, session_id=effective_session_id,
                # The reply text, so a caller whose stream died can still read it from
                # GET /v1/runs/{run_id}; POST /v1/runs already records output in `_finish`.
                output=final_response, usage=usage,
                last_event=f"run.{status}", **fields)
        except asyncio.CancelledError:
            self._set_run_status(run_id, "cancelled", last_event="run.cancelled")
            raise
        except Exception as exc:
            api.logger.exception("[api_server] session chat stream failed")
            self._set_run_status(
                run_id, "failed", error=api._redact_api_error_text(exc), last_event="run.failed")
            await queue.put(_event_payload("error", {"message": api._redact_api_error_text(exc)}))
        finally:
            bridge.close()
            self._active_run_agents.pop(run_id, None)
            self._release_run_owner_if_forgotten(run_id)
            await queue.put(_event_payload("done", {}))
            await queue.put(None)

    # NOT in _active_run_tasks: _run_agent already counts this turn for the shutdown drain.
    task = asyncio.create_task(_run_and_signal())
    self._track_background_task(task)
    headers = {
        "Content-Type": "text/event-stream", "Cache-Control": "no-cache",
        "X-Accel-Buffering": "no", **self._session_headers(session_id, gateway_session_key)}
    response = api.web.StreamResponse(status=200, headers=headers)
    try:
        await response.prepare(request)
        while True:
            try:
                item = await asyncio.wait_for(queue.get(), timeout=api.CHAT_COMPLETIONS_SSE_KEEPALIVE_SECONDS)
            except asyncio.TimeoutError:
                await response.write(b": keepalive\n\n")
                continue
            if item is None:
                break
            name, payload = item
            await response.write(api._sse_frame(payload, event=name, ensure_ascii=False))
    except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError, OSError):
        await self._drain_session_stream_task_on_disconnect(
            run_id, task, interrupt_message="SSE client disconnected", shield_wait=False)
        api.logger.info("Session SSE client disconnected; interrupted live run %s", run_id)
    except asyncio.CancelledError:
        await self._drain_session_stream_task_on_disconnect(
            run_id, task, interrupt_message="SSE task cancelled", shield_wait=True)
        api.logger.info("Session SSE task cancelled; drained live run %s", run_id)
        raise
    except Exception as exc:
        await self._drain_session_stream_task_on_disconnect(
            run_id, task, interrupt_message="SSE write failed", shield_wait=False)
        api.logger.debug("[api_server] session SSE stream error: %s", exc)
    finally:
        bridge.close()
    return response


async def _session_agent(
    self, user_message: str, conversation_history: api.List[api.Dict[str, str]],
    ephemeral_system_prompt: api.Optional[str] = None, session_id: api.Optional[str] = None,
    stream_delta_callback=None, tool_progress_callback=None, tool_start_callback=None,
    tool_complete_callback=None, interim_assistant_callback=None, reasoning_callback=None,
    status_callback=None, agent_ref: api.Optional[list] = None, active_run_id: api.Optional[str] = None,
    gateway_session_key: api.Optional[str] = None, requested_model: api.Optional[str] = None,
    requested_provider: api.Optional[str] = None, model_options: api.Optional[api.Dict[str, api.Any]] = None,
    route: api.Optional[api.Dict[str, api.Any]] = None, session_model: api.Optional[str] = None,
    requested_runtime: api.Optional[api.Dict[str, api.Any]] = None, route_source: str = "global",
    confirmed_runtime_lock: bool = False, bind_declared_conversation: bool = False,
    session_history_delivery: str = "", turn_author: api.Optional[api.Dict[str, api.Any]] = None,
    relay_metadata: api.Optional[api.Dict[str, api.Any]] = None, notification_category: str = "result", *, _compat_approval) -> tuple:
    """Create an agent and run one turn in a thread executor -> ``(result, usage)``.
    ``agent_ref[0]`` receives the agent so SSE writers can interrupt it; ``active_run_id``
    registers it in ``_active_run_agents``. Under a confirmed model lock the actual
    provider/model must match or the turn fails; ``runtime`` metadata is attached.
    ``session_history_delivery`` declares #98619 session-id provenance and default-denies: only audited
    producers whose client can address the id again pass "1" (see
    ``_bind_api_server_session``).
    ``turn_author`` only labels the turn for memory attribution. It grants nothing."""
    loop = asyncio.get_running_loop()
    # ContextVars do not follow run_in_executor threads: capture here, re-enter in _run().
    request_profile = api._api_request_profile.get()
    request_browser_control_principal = api._api_request_browser_control_principal.get()
    request_browser_control_transport_family = api._api_request_browser_control_transport_family.get()

    def _run():
        from gateway.session_context import clear_session_vars
        with self._profile_scope(request_profile):
            tokens = self._bind_api_server_session(
                chat_id=session_id or "", session_key=gateway_session_key or session_id or "",
                session_id=session_id or "", profile=request_profile or "",
                browser_control_principal=request_browser_control_principal,
                browser_control_transport_family=request_browser_control_transport_family,
                session_history_delivery=session_history_delivery)
            agent = None
            approval_token = None
            from agent.notification_presentation import notification_turn
            from gateway.warning_notifications import diagnostic_turn_muted
            muted = diagnostic_turn_muted({"notification_category": notification_category}, "api_server")
            try:
                approval_token = _compat_approval.enter()
                agent = self._create_agent(
                    ephemeral_system_prompt=ephemeral_system_prompt, session_id=session_id,
                    stream_delta_callback=stream_delta_callback, tool_progress_callback=tool_progress_callback,
                    tool_start_callback=tool_start_callback, tool_complete_callback=tool_complete_callback,
                    interim_assistant_callback=interim_assistant_callback,
                    reasoning_callback=reasoning_callback, status_callback=status_callback,
                    gateway_session_key=gateway_session_key, requested_model=requested_model,
                    requested_provider=requested_provider, model_options=model_options, route=route,
                    session_model=session_model, confirmed_runtime_lock=confirmed_runtime_lock)
                if agent_ref is not None:
                    agent_ref[0] = agent
                if active_run_id:
                    self._active_run_agents[active_run_id] = agent
                effective_task_id = session_id or str(api.uuid.uuid4())
                # Process baseline for disconnect reaping (this surface bypasses TurnRunner)
                # + shutdown-interrupt registration, once for every caller.
                # Baseline for selective background-process reaping on SSE client disconnect — mirrors
                # gateway/run.py's gateway-turn cleanup (#76115); this API-server surface runs its own
                # agent lifecycle and doesn't go through TurnRunner, so it needs its own baseline.
                # /v1/runs runs its own agent lifecycle (no TurnRunner, no _run_agent) — record turn
                # process ownership so stop/cancel can reap only the background processes this run
                # created (#76115).
                api._publish_turn_process_ownership(agent, effective_task_id)
                # Registering here, once, covers every _run_agent() caller — the same reason the
                # _ProviderAuthResolutionError handler below lives here rather than in each route. Only
                # two callers pass ``agent_ref``, and only /v1/runs has a run_id, so neither is a usable
                # hook for the rest. See #63529.
                self._shutdown_interruptible_agents[id(agent)] = agent
                # Passed only when set: a human turn keeps today's call shape.
                author_kwargs = {"turn_author": turn_author} if turn_author is not None else {}
                conversation_kwargs = dict(
                    user_message=user_message,
                    conversation_history=conversation_history,
                    task_id=effective_task_id,
                    **author_kwargs,
                )
                if relay_metadata:
                    conversation_kwargs["relay_metadata"] = relay_metadata
                with notification_turn(agent, muted=muted, session_id=session_id or ""):
                    result = agent.run_conversation(**conversation_kwargs)
                result, usage = self._finish_turn_result(
                    agent, result, session_id, route=route, requested_runtime=requested_runtime,
                    route_source=route_source, confirmed_runtime_lock=confirmed_runtime_lock)
                if muted and isinstance(result, dict):
                    # Project presentation only after finishing the source outcome. Keep
                    # the agent's result, transcript, failure flags and usage intact.
                    result = {**result, "_notification_presentation_suppressed": True}
                return result, usage
            except api._ProviderAuthResolutionError as exc:
                # Typed provider-auth failure only, handled once for every caller in
                # run.py's response shape (text, no HTTP error).
                api.logger.warning("Provider resolution failed for session=%s: %s",
                               session_id or "", exc)
                return (
                    {"final_response": exc.user_text(), "messages": [],
                     "api_calls": 0, "tools": [],
                     **({"_notification_presentation_suppressed": True} if muted else {})},
                    {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0})
            except Exception as exc:
                if muted:
                    # Keep the original exception/traceback for logs and failure
                    # handling; the HTTP/SSE boundary suppresses its presentation.
                    setattr(exc, "_notification_presentation_suppressed", True)
                raise
            finally:
                _compat_approval.close()
                if approval_token is not None:
                    _compat_approval.context.reset_current_session_key(approval_token)
                # Turn over (any outcome): clear ownership so a late disconnect can't reap
                # background work this turn deliberately left running.
                if active_run_id:
                    self._active_run_agents.pop(active_run_id, None)
                if agent is not None:
                    api._clear_turn_process_ownership(agent)
                    self._shutdown_interruptible_agents.pop(id(agent), None)
                    # Bind the declared key to the row the turn actually ended on
                    # (agent.session_id carries a mid-turn rotation). Opt-in per route.
                    # Record the declared conversation on the row the turn actually ended on —
                    # ``agent.session_id`` already carries a mid-turn compression rotation (#16938), so
                    # the next reply resolves the live transcript rather than its retired parent.
                    # Opt-in: only the routes that resolve their session id from the declared key
                    # (/v1/responses, /v1/runs) record one, so no other caller's rows change shape.
                    if bind_declared_conversation:
                        self._bind_declared_conversation(
                            getattr(agent, "session_id", None) or session_id, gateway_session_key)
                clear_session_vars(tokens)
    self._activate_admitted_request()
    self._inflight_agent_runs += 1
    try:
        return await loop.run_in_executor(None, _run)
    finally:
        self._inflight_agent_runs -= 1
