"""Process-local compatibility hooks for Hermes 2a327c25af.

Upstream-dependent code deliberately lives in this one file. No core files are
written. The two copied API paths are source-fingerprinted before installation.
"""
from __future__ import annotations

import asyncio
import contextvars
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from contextlib import suppress
from functools import wraps
import hashlib
import inspect
import json
import logging
from pathlib import Path
import re
import threading
import time
import urllib.parse

VERSION = "0.5.1"
BASELINE = "2a327c25af3eb146db7be627db4c2c3fc42e0494"
TARGET = "d0288be5b3330d2442e3907185b8e9d0958297bb"
CAP = 500 * 1024 * 1024
EXTRA_MIMES = frozenset({
    "application/octet-stream", "application/zip", "application/x-zip-compressed",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation",
})
UNITS = ("limits", "upload", "media", "history", "approval", "skills", "activity", "push",
         "approval_inbox", "cron_bridge", "wake", "selfwake", "steer_inbox",
         "notification_events", "messages_timing")
log = logging.getLogger("hermes-app-compat")
_STATE = "_hermes_app_compat_state_v1"
_MISSING = object()
# WAVE4 activity unit: the registry slot is filled by _install_activity and read
# by the shared _session_stream copy; None means the unit is absent so that copy
# stays a no-op for activity and the approval unit is untouched.
_ACTIVITY = None
# NTFY-PORT push unit: registry slot filled by _install_push; the registry object
# itself lives in the shared compat state so a hot reload re-binds onto it.
_PUSH = None
# The state created by the _register_session_stream_approval wrapper travels to
# the very next _prepare_sse_response call of the same request task; no other
# SSE surface (OpenAI streams, live Bot Chat handoff) ever sets it.
_PUSH_STREAM = contextvars.ContextVar("hermes_app_push_stream", default=None)
# Sync /api/sessions/{sid}/chat carries its request scope here (no run_id exists
# on that path) so the wrapped _run_agent can open a synthetic observation.
_SYNC_CHAT = contextvars.ContextVar("hermes_app_sync_chat", default=None)
# SELFWAKE S1: a wake dispatch carries its per-request launch evidence here.
# The reviewed TARGET copy stamps it (handoff / run_id / task launch) while the
# wake wrapper decides the batch's fate from it. None outside a wake dispatch,
# so every non-wake path pays nothing.
_WAKE_LAUNCH = contextvars.ContextVar("hermes_app_wake_launch", default=None)
ACTIVITY_OBJECT = "hermes.session.activity"
ACTIVITY_SCHEMA = 1
ACTIVITY_PREVIEW_CAP = 8192
ACTIVITY_ACTIVE_CAP = 8
ACTIVITY_RECENT_CAP = 32
ACTIVITY_RECENT_SHOW = 4
ACTIVITY_RECENT_TTL = 600.0
ACTIVITY_TERMINAL = frozenset({"completed", "failed", "cancelled", "interrupted"})
ACTIVITY_LIVE = frozenset({"queued", "running", "waiting_for_approval", "stopping"})
# Push unit (NTFY-PORT): viewer-gone ntfy wake-ups. Titles are fixed ASCII;
# bodies are Chinese in a byte-bounded UTF-8 payload (ntfy_notify enforces the
# hard caps). The echo tag mirrors the ntfy platform adapter's skip tag so a
# shared topic can never loop this notifier back in as a prompt.
PUSH_ECHO_TAG = "hermes-agent"
PUSH_TITLES = {"approval": "Hermes: approval needed", "reply": "Hermes: reply ready",
               "failed": "Hermes: run failed"}
PUSH_FALLBACK_REPLY = "任務完成，打開 App 看結果"
PUSH_FALLBACK_FAILED = "任務失敗，打開 App 看細節"
PUSH_FALLBACK_APPROVAL = "高風險指令"
PUSH_PREVIEW_CHARS = 400
PUSH_DETAIL_CHARS = 300
PUSH_RETENTION_SECONDS = 900.0
PUSH_MAX_STATES = 64
PUSH_DATA_URL_RE = re.compile(r"!\[[^\]]*\]\(data:[^)]*\)|data:[A-Za-z0-9+./_-]+;base64,[A-Za-z0-9+/=]+")
PUSH_TERMINAL_FRAME_RE = re.compile(rb"^(?:id: \d+\n)?event: run\.(?:completed|failed)\n")
# Filled from clean HEAD source during development, never learned at runtime.
# Two complete backends: fingerprint triples identify the running upstream; an
# unrecognized combination fails every source-gated unit closed.
BASE_FINGERPRINTS = {
    "_handle_artifact_upload": "33ee0a4e339538291eac88f0713ab838d1577ba099e2cdb5b254dbc8ac21081f",
    "_handle_session_chat_stream": "136c074ac9d0ac6a071d9223eb6f004a445d7a7802f607f4c7c1fc01cc1d4fcf",
    "_run_agent": "614a8f2a559747b306933200ebd1dc21ac4e4f9acff2f90fea6917ee2e217c68"
}
TARGET_FINGERPRINTS = {
    "_handle_artifact_upload": "0022fb5124793c1dd9705fb269b0448dc6a579ee7ce768f52f8235254b949fd4",
    "_handle_session_chat_stream": "12fc8825a0a994eb71b66f4d723fb569bf99f9b9572f1ac432e1aa924c554115",
    "_run_agent": "1a3ae2b6dd408f31d8a3c6f296739d78d26e8dbc939d0f5e585798b8b76f0840"
}
BACKENDS = {"base": BASE_FINGERPRINTS, "target": TARGET_FINGERPRINTS}
FINGERPRINTS = BASE_FINGERPRINTS  # historical alias: the BASELINE backend table
_BACKEND = None
# P5 cron bridge: the reviewed private seams this unit binds inside the cron
# scheduler and SessionDB. Same rule as the API tables — only the reviewed
# TARGET family is supported; anything else fails the unit closed.
CRON_TARGET_FINGERPRINTS = {
    "_live_route_metadata": "9625c3749a22c55d7e56b0a20029b868b89396f0cda16abd8007498d066b1952",
    "_standalone_send": "5a35947ca8401d536ddacdb06499490051caf42b9840c73cb02ab6101d01f013",
    "_target_mirror_eligible": "2a12f8b0563944a11e1beaffb642c737fbdf61c210c03419d4cffb65efd3fc55",
    "_deliver_result": "119fb16e2602ee5ecae7180cb00162bd1e7100790a2983793ab9e49e6277154a",
    "_check_transcript_write_guards": "20f61f17795e61e3df5c889aaa485bbe933bb7f7a329f8f68321ff77ca645b74",
    "_message_row_params": "de115ff45c485cef7e314664c8f4bf9c76e7775dfcf22192b9503cee467624cf",
    "_bump_session_counters": "52ee538125543d17920bfcf6ee72cfce8ff9225fcdea48f6b64a5981a157809c",
    "append_delegation_delivery": "1f3ae7c407a21ddd0ed1d4381055552a3dd3dfb06113b5c8a2e002a784971757",
    "_execute_write": "62dc49ded38b85d9ab892a6110731dee16363a4bb955820d56d2749840ecba93",
}
# APPWAKE B: the SessionDB read seams the admission ledger consults.
WAKE_TARGET_FINGERPRINTS = {
    "_read_all": "38ac6ca079f7ea8ce91fd0f0330f28de8b4d7dbd5851cfd50b05e569bfacd2ae",
    "_session_turn_lease_key": "3b82026599a02042f6fb26b65594dd59d2e98a647895f4c47cf7d07ec7e64c45",
}
# SELFWAKE S1: the reviewed agent seam that keeps a wake's canonical input from
# being absorbed (with the prior report's internal_notification display
# metadata) into the persisted merge carrier. The API-copy merge in request
# assembly still merges for the wire, so skipping the DURABLE merge here never
# breaks strict alternation.
MERGE_TARGET_FINGERPRINTS = {
    "_merge_consecutive_users": "765e822ddf502fd4b8b5a95b300b2ccc2c950c3f68d167f2a126b55b110cbd87",
}


class Transaction:
    def __init__(self):
        self.changes = []
        self.cleanups = []
        # Optional zero-arg callable consulted BEFORE every setattr; compat
        # install() arms it with the loader-abandonment guard so a timed-out
        # registration stops at the NEXT binding instead of finishing the file.
        self.check = None

    def set(self, target, name, value, *, mapping=False):
        if self.check is not None:
            self.check()
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
    table = BACKENDS.get(_BACKEND) if _BACKEND else None
    if table is None:
        raise RuntimeError("unknown source backend")
    actual = hashlib.sha256(inspect.getsource(inspect.unwrap(getattr(target, name))).encode()).hexdigest()
    if actual != table[name]:
        raise RuntimeError(f"source changed: {name}")


def _cron_fingerprint(target, name):
    if _BACKEND != "target":
        raise RuntimeError("cron bridge backend not reviewed for this source")
    actual = hashlib.sha256(inspect.getsource(inspect.unwrap(getattr(target, name))).encode()).hexdigest()
    if actual != CRON_TARGET_FINGERPRINTS[name]:
        raise RuntimeError(f"cron source changed: {name}")


def _detect_backend(cls):
    """Identify the running upstream by its complete fingerprint triple. Only a
    full table match selects a backend; anything else stays None (fail-closed)."""
    try:
        digests = {n: hashlib.sha256(
            inspect.getsource(inspect.unwrap(getattr(cls, n))).encode()).hexdigest()
            for n in BASE_FINGERPRINTS}
    except Exception:
        return None
    for name, table in BACKENDS.items():
        if all(digests.get(key) == value for key, value in table.items()):
            return name
    return None


def _abandoned(ctx):
    return bool(getattr(ctx, "_load_abandoned", False))


def install(ctx):
    """Isolate each patch group; share ownership across profile plugin managers.

    Loader-deadline discipline: a timed-out registration thread may keep
    running while the loader sweeps registries and turns ctx.on_unload into a
    silent no-op. So the group is PUBLISHED and the unload LEASE taken BEFORE
    the first raw setattr, every setattr re-checks the abandonment flag
    through Transaction.check, and a refused lease (None handle while
    abandoned) rolls the unit back. Cleanup never waits on foreign locks:
    state["lock"] is this plugin's own RLock, and an abandoned register stops
    at its next setattr, so a racing release() blocks for one guarded setattr
    at most.
    """
    global api, _BACKEND
    try:
        from gateway.platforms import api_server as api
        state = getattr(api, _STATE, None)
        if state is None:
            state = {"groups": {}, "manifest": {}, "lock": threading.RLock()}
            setattr(api, _STATE, state)
        if "backend" not in state:
            state["backend"] = _detect_backend(api.APIServerAdapter)
        _BACKEND = state["backend"]
        # PluginContext is recreated by loader calls; manager+plugin is the owner.
        owner = (id(getattr(ctx, "_manager", ctx)), "hermes-app-compat")

        def guard():
            if _abandoned(ctx):
                raise RuntimeError("load abandoned mid-commit")

        with state["lock"]:
            for unit in UNITS:
                existing = state["groups"].get(unit)
                fresh = existing is None
                if not fresh and owner in existing["owners"]:
                    continue
                if fresh:
                    # Publish the group BEFORE the first setattr so an
                    # abandonment mid-commit rolls back tracked bindings.
                    existing = {"owners": set(), "tx": Transaction()}
                    state["groups"][unit] = existing
                tx = existing["tx"]

                def release(unit=unit, owner=owner, existing=existing):
                    with state["lock"]:
                        existing["owners"].discard(owner)
                        if not existing["owners"] and state["groups"].get(unit) is existing:
                            existing["tx"].restore()
                            state["groups"].pop(unit, None)
                            state["manifest"][unit] = {"status": "unloaded_restart_required"}

                try:
                    if _abandoned(ctx):
                        raise RuntimeError("load abandoned")
                    # A None return while abandoned is the loader's refusal;
                    # handle-returning success and plain None contexts (B test
                    # doubles) stay compatible.
                    if ctx.on_unload(release) is None and _abandoned(ctx):
                        raise RuntimeError("unload lease refused")
                    tx.check = guard
                    existing["owners"].add(owner)
                    if fresh:
                        status = globals()["_install_" + unit](tx)
                        state["manifest"][unit] = {"status": status or "applied"}
                    tx.check = None
                except Exception as exc:
                    tx.check = None
                    release()
                    state["manifest"][unit] = {"status": "skipped_incompatible", "reason": type(exc).__name__}
                    log.warning("%s skipped_incompatible: %s", unit, str(exc))
            # P5-1: platform registration is PER CONTEXT (profile-scoped
            # registry + unload lease). The group-ownership loop above skips
            # repeat owners, so it must not also gate registration; the lease
            # bookkeeping mirrors the global transaction split-accounting rule.
            if state["manifest"].get("cron_bridge", {}).get("status") == "applied" \
                    and not _abandoned(ctx):
                registration = "refused"
                try:
                    from . import app_platform
                    if getattr(ctx, "register_platform", None) is None:
                        registration = "unavailable"
                    elif app_platform.register(ctx):
                        registration = "scoped"
                except Exception as exc:
                    log.warning("cron_bridge platform registration failed: %s",
                                type(exc).__name__)
                state["manifest"]["cron_bridge"]["registration"] = registration
            # AIOHTTP HOT-RELOAD WIRING: connect() bound the route table once
            # and setup() froze the router, so class-attribute swaps are
            # invisible to routes the boot registered BEFORE this load (the
            # wake capabilities wrapper being the observed victim). A
            # platform-handler factory runs at every connect AND at every
            # plugin-loaded rewire — provided its qualname is new (the wiring
            # table dedupes per qualname), so each install registers a
            # sequence-numbered factory that replays the table on the live
            # router. Without the plugin API (older gateway) the fix degrades
            # to restart-required, exactly like the pre-fix behavior.
            route_sync = "refused"
            try:
                register = getattr(ctx, "register_platform_handler", None)
                if not _abandoned(ctx):
                    if register is None:
                        route_sync = "unavailable"
                    else:
                        seq = int(state.get("route_sync_seq", 0)) + 1
                        state["route_sync_seq"] = seq

                        # SELFWAKE2: factories keep the loop/adapter pairing
                        # that the install-time GC scan re-arms from.
                        swst = state.get("selfwake") or {}

                        def sync(native, adapter, _seq=seq,
                                 _loops=swst.get("loops"),
                                 _module=swst.get("module"),
                                 _gen=swst.get("generation")):
                            _sync_routes(native, adapter)
                            # SELFWAKE re-arm: this factory runs at connect
                            # AND at every loaded-driven rewire, so liveness
                            # from it stays correct wherever notifications DO
                            # arrive; the install-time live-adapter scan
                            # covers the same-name-reload gap where they do
                            # not (TASK/SELFWAKE2.md). arm_loop stays the
                            # idempotent singleton; the module+generation
                            # guard retires stale factories, so a reload can
                            # never stack workers or resurrect an old load.
                            try:
                                loop = asyncio.get_running_loop()
                                if adapter is not None and _loops is not None:
                                    try:
                                        _loops[adapter] = loop
                                    except TypeError:
                                        pass
                                if _module is not None:
                                    _selfwake_rearm(loop, _module, _gen, "factory-replay")
                            except Exception as exc:
                                # silence here once hid "reload never re-arms"
                                # for a full day (audit ticks dead 12h+)
                                log.warning("selfwake re-arm failed: %s: %s",
                                            type(exc).__name__, exc)

                        # The wiring table dedupes by qualname, so a force
                        # reload (NEW function objects, same plugin) must
                        # arrive with a NEW qualname or it is skipped forever.
                        sync.__qualname__ = f"_route_sync_factory.{seq}"
                        sync.__hermes_app_compat__ = VERSION
                        register("api_server", sync)
                        route_sync = "registered"
            except Exception as exc:
                log.warning("route sync registration failed: %s", type(exc).__name__)
            if route_sync == "registered":
                # Adapters that booted before factories existed never run the
                # factory on rewire; reach them now, in this process only.
                try:
                    _sync_live_adapters()
                except Exception as exc:
                    log.warning("live route sync failed: %s", type(exc).__name__)
            for unit_state in state["manifest"].values():
                if isinstance(unit_state, dict):
                    unit_state.setdefault("route_sync", route_sync)
            log.info("hermes-app-compat manifest %s", json.dumps({
                "version": VERSION, "baseline": BASELINE, "backend": _BACKEND or "unknown",
                "restart_required_for_unload": True, "groups": state["manifest"]}, sort_keys=True))
    except Exception as exc:
        log.warning("hermes-app-compat manifest: all skipped_incompatible (%s)", type(exc).__name__)


def _sync_routes(native, adapter):
    """Re-point the live router at the current class wrappers. aiohttp binds
    each row's handler object at connect() time and freezes the router at
    setup(); tx.set alone therefore never reaches routes registered BEFORE
    this install (boot-bound handlers keep the old bound method, and rows our
    wrappers append were never registered at all). Replaying the route table
    against the frozen router — swap handlers in place, register the missing
    rows under a temporary unfreeze — makes hot reload effective immediately.
    """
    router = getattr(native, "router", None)
    table = getattr(adapter, "_http_route_table", None)
    if router is None or table is None:
        return
    try:
        want = {}
        for method, path, handler in table():
            for candidate in (path, f"/p/{{profile}}{path}"):
                want[(method, candidate)] = getattr(handler, "__func__", handler)
        live = {}
        for resource in router.resources():
            for route in resource:
                # CatchAll routes carry no .method; "*" keeps them out of the
                # table-keyed swap below (no table row can ever name one).
                method = getattr(route, "method", None) or "*"
                live[(method, resource.canonical)] = route
    except Exception as exc:
        log.warning("route sync aborted: %s", type(exc).__name__)
        return
    swapped = 0
    for key, route in live.items():
        target = want.get(key)
        current = getattr(getattr(route, "_handler", None), "__func__",
                          getattr(route, "_handler", None))
        # Only rewrite where the table and the live binding diverge AND the
        # divergence is one of ours: either side carries our stamp (a boot
        # binding a later wrapper superseded, or a wrapper this load replaced).
        ours = (getattr(current, "__hermes_app_compat__", None) is not None
                or getattr(target, "__hermes_app_compat__", None) is not None)
        if target is None or target is current or not ours:
            continue
        try:
            route._handler = (target.__get__(adapter, type(adapter))
                              if callable(target) else target)
        except (AttributeError, TypeError):
            log.warning("route sync could not swap %s %s", *key)
            continue
        swapped += 1
    # Rows our route-table wrappers append exist only in the table: a boot
    # that predates this load never registered them, so a frozen router must
    # gain them now (temporary unfreeze; registration logic is otherwise
    # aiohttp's own).
    missing = [key for key in want
               if key not in live
               and getattr(want[key], "__hermes_app_compat__", None) is not None]
    added = 0
    if missing:
        was_frozen = getattr(router, "frozen", False)
        if was_frozen:
            router._frozen = False
        try:
            for method, path in missing:
                handler = want[(method, path)]
                router.add_route(method, path, handler.__get__(adapter, type(adapter)))
                added += 1
        except Exception as exc:
            log.warning("route sync could not register %d added route(s): %s",
                        len(missing), type(exc).__name__)
        finally:
            if was_frozen:
                router._frozen = True
    if swapped or added:
        log.info("route sync: %d handler(s) re-pointed, %d route(s) registered",
                 swapped, added)


def _selfwake_liveness(state_name, reason=None):
    """Manifest-visible worker state (never keys, URLs or bodies): the one
    field to read when asking "why didn't it wake" (T3)."""
    state = getattr(api, _STATE, None) or {}
    swst = state.get("selfwake") or {}
    unit = (state.get("manifest") or {}).get("selfwake")
    stamp = {"state": state_name, "at": round(time.time(), 3)}
    if reason:
        stamp["reason"] = reason
    if swst.get("generation") is not None:
        stamp["generation"] = swst["generation"]
    if isinstance(unit, dict):
        unit["liveness"] = stamp
    return stamp


def _selfwake_arm_guarded(loop, module, generation, source):
    """Runs ON `loop`: arm the CURRENT install's worker and nothing else.
    Stale loads, unloaded units and closed loops fail CLOSED with a reason —
    an old load's late callback can never resurrect a replaced worker."""
    state = getattr(api, _STATE, None) or {}
    swst = state.get("selfwake") or {}
    if swst.get("module") is not module or swst.get("generation") != generation:
        _selfwake_liveness("skipped", "stale-load")
        return
    status = ((state.get("manifest") or {}).get("selfwake") or {}).get("status")
    if status != "applied":
        _selfwake_liveness("skipped", f"unit-{status}")
        return
    if loop is None or loop.is_closed():
        _selfwake_liveness("skipped", "no-owning-loop")
        return
    try:
        from hermes_constants import get_hermes_home
        module.arm_loop(loop, get_hermes_home())
    except Exception as exc:
        _selfwake_liveness("dead", f"arm-failed:{type(exc).__name__}")
        log.warning("selfwake re-arm failed: %s: %s", type(exc).__name__, exc)
        return
    _selfwake_liveness("armed", source)


def _selfwake_rearm(loop, module, generation, source):
    """Schedule the guarded arm on the ADAPTER's owning loop; safe to call
    from loader/executor threads. Never creates a loop of its own."""
    if loop is None:
        _selfwake_liveness("skipped", "no-owning-loop")
        return
    try:
        running = asyncio.get_running_loop()
    except RuntimeError:
        running = None
    if running is loop:
        _selfwake_arm_guarded(loop, module, generation, source)
        return
    try:
        loop.call_soon_threadsafe(_selfwake_arm_guarded, loop, module, generation, source)
    except (RuntimeError, OSError):
        _selfwake_liveness("skipped", "loop-unreachable")


def selfwake_connect_arm(loop, home):
    """App-platform connect seam: same guarded entry as every other arm so
    liveness bookkeeping cannot diverge between paths."""
    swst = (getattr(api, _STATE, None) or {}).get("selfwake") or {}
    if swst.get("module") is None:
        return  # unit not applied (skipped/abandoned): fail CLOSED
    _selfwake_rearm(loop, swst["module"], swst.get("generation"), "connect")


def selfwake_liveness(state_name, reason):
    """Public stamp surface for lifecycle transitions (armed / skipped /
    dead / stopped, plus reason) so every state change lands on the ONE
    manifest field — including self_wake's own arm_stop/reset/task-death."""
    _selfwake_liveness(state_name, reason)


def _selfwake_scan_rearm(swst, adapters):
    """SELFWAKE2 liveness repair for the LIVE adapters of THIS install.
    Upstream on_plugin_loaded only fires for NEWLY loaded plugin keys, so a
    same-name force reload runs this scan (routes "succeed") while no
    notification-driven factory ever re-arms the worker (TASK/SELFWAKE2.md).
    The owning loop is the adapter's live gateway loop, falling back to the
    loop recorded for that very adapter when its factory last ran; with
    neither, the unit fails CLOSED with a reason instead of claiming armed.
    arm_loop stays the idempotent singleton — repeated scans+factories can
    never stack workers."""
    module, generation = swst.get("module"), swst.get("generation")
    if module is None:
        return
    loops = {}
    recorded = swst.get("loops") or {}
    for ref in adapters:
        runner = getattr(ref, "gateway_runner", None)
        loop = getattr(runner, "_gateway_loop", None)
        if loop is None:
            try:
                loop = recorded.get(ref)
            except Exception:
                loop = None
        if loop is not None:
            loops[id(loop)] = loop
    if loops:
        for loop in loops.values():
            _selfwake_rearm(loop, module, generation, "install-live-adapters")
    else:
        _selfwake_liveness("skipped", "no-owning-loop")


def _sync_live_adapters():
    """Reload-time repair for ALREADY-RUNNING adapters. The platform-handler
    factory covers connects and well-armed rewires, but an adapter whose
    factory-wiring table predates any factories stays ``None`` and its
    rewire pass returns early — so this load reaches the live api_server
    adapters directly and replays the route table on their frozen routers.
    A boot-time install finds nothing here (no adapter exists yet) and the
    connect-time wiring does the work; discovery never leaves this process.
    """
    import gc
    try:
        from gateway.platforms.api_server import APIServerAdapter
    except Exception:
        return
    found = 0
    live = []
    for ref in gc.get_objects():
        try:
            if type(ref) is not APIServerAdapter:
                continue
            app = getattr(ref, "_app", None)
            if app is not None and getattr(app, "router", None) is not None:
                _sync_routes(app, ref)
                found += 1
                live.append(ref)
        except Exception:
            continue
    if found:
        log.info("route sync replayed on %d live api_server adapter(s)", found)
        _selfwake_scan_rearm((getattr(api, _STATE, None) or {}).get("selfwake") or {}, live)


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
    if _BACKEND == "target":
        _signature(api.APIServerAdapter, "_artifact_store_for_async", "self", "profile")
        tx.set(api.APIServerAdapter, "_handle_artifact_upload", _upload_target)
    else:
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


async def _upload_target(self, request):
    # TARGET backend: same streaming read, cap+1 rejection and validations, but
    # cold store construction goes through the upstream async single-flight and
    # the disk write hops off the event loop (TARGET commit f276ff3f6fe).
    ctx, err = self._artifact_route_prelude(request, "upload")
    if err is not None:
        return err
    profile, principal = ctx
    content_type = request.headers.get("Content-Type", "")
    filename = request.headers.get("X-Artifact-Filename", "").strip()
    if not filename:
        return api._error_response("X-Artifact-Filename header is required.", 400)
    try:
        store = await self._artifact_store_for_async(profile)
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
        receipt = await asyncio.to_thread(
            store.store, data, filename=filename, content_type=content_type, scope=scope)
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
    original = descriptor.__func__

    # OPENPERF P3 (定案2): history serves MEDIA REFERENCES, never whole-file
    # base64. The old wrapper inlined every MEDIA tag — a real attachment
    # session shipped 13.8 MB of JSON for 200 rows and every byte rode the
    # list GET. Reference form is exactly the upstream projection: rows
    # carry `MEDIA:<path>` and clients fetch images one file at a time via
    # GET /v1/media/download (older clients keep the attachment-tile UX —
    # functional, just not inline). The live SSE first frame keeps its
    # data URL behaviour UNTOUCHED (contract.md pins it).
    # IMGPERF A3: inside an active messages request (sql already recorded)
    # the wrapper also accumulates the per-row projection time and the MEDIA
    # marker scan into the request's stage box — numbers only, and only
    # inside that box; every other call site runs the plain original.
    @wraps(original)
    def message(row):
        box = _MSG_BOX.get()
        if box is None or "decode_ms" not in box:
            return original(row)
        started = time.monotonic()
        projected = original(row)
        box["decode_ms"] += (time.monotonic() - started) * 1000.0
        content = projected.get("content") if isinstance(projected, dict) else None
        if isinstance(content, str) and "MEDIA:" in content:
            scanned = time.monotonic()
            box["media_count"] += content.count("MEDIA:")
            box["media_ms"] += (time.monotonic() - scanned) * 1000.0
        return projected
    message.__hermes_app_compat__ = VERSION
    tx.set(cls, "_message_response", staticmethod(message))


# ---- messages timing unit (IMGPERF A3: bounded stage diagnostics) -----------
# One ContextVar box per request, opened in TASK context where the messages
# handler first awaits _ensure_session_db_async; asyncio.to_thread copies the
# context, so the thread-side get_messages wrapper mutates the SAME dict
# object the task can see. The JSON step (end of the handler) finalizes:
# cold/warm classification of the exact (resolved session, limit, offset,
# latest) page key, manifest aggregates, and one debug line. Numbers only —
# never content, paths of conversation data, or keys. No index, no schema,
# no core change: this unit only watches, and any fault inside it degrades
# to the untouched request.

_MSG_BOX = contextvars.ContextVar("hermes_app_messages_stage", default=None)
_MSG_SEEN: "OrderedDict[tuple, bool]" = OrderedDict()
_MSG_SEEN_MAX = 4096
_MSG_LOCK = threading.Lock()
_MSG_STATS = {
    bucket: {stage: {"n": 0, "min": 0.0, "max": 0.0, "sum": 0.0}
             for stage in ("sql_ms", "decode_ms", "media_ms", "json_ms", "total_ms")}
    | {"rows": 0, "media_count": 0}
    for bucket in ("cold", "warm")
}


def _messages_stage_finalize(box, json_end):
    total_ms = (json_end - box["t0"]) * 1000.0
    session_id, limit, offset, latest = box["page"]
    page = (session_id, limit, int(offset or 0), bool(latest))
    order = "latest" if latest else "oldest"
    with _MSG_LOCK:
        cold = page not in _MSG_SEEN
        if cold:
            _MSG_SEEN[page] = True
            while len(_MSG_SEEN) > _MSG_SEEN_MAX:
                _MSG_SEEN.popitem(last=False)
        else:
            _MSG_SEEN.move_to_end(page)
        bucket = _MSG_STATS["cold" if cold else "warm"]
        for stage, value in (("sql_ms", box["sql_ms"]), ("decode_ms", box["decode_ms"]),
                             ("media_ms", box["media_ms"]), ("json_ms", box["json_ms"]),
                             ("total_ms", total_ms)):
            entry = bucket[stage]
            entry["n"] += 1
            entry["min"] = value if entry["n"] == 1 else min(entry["min"], value)
            entry["max"] = max(entry["max"], value)
            entry["sum"] += value
        bucket["rows"] += max(int(box["rows"]), 0)
        bucket["media_count"] += int(box["media_count"])
        stats = json.loads(json.dumps(_MSG_STATS))
    state = getattr(api, _STATE, None)
    if state is not None:
        try:
            with state["lock"]:
                manifest_entry = state["manifest"].setdefault("messages_timing", {})
                manifest_entry["messages_timing_stats"] = stats
                manifest_entry["seen_pages"] = len(_MSG_SEEN)
        except Exception:
            pass
    log.debug("messages-stage cold=%d sql_ms=%.3f decode_ms=%.3f media_ms=%.3f "
              "json_ms=%.3f total_ms=%.3f rows=%d media_count=%d limit=%s offset=%d "
              "order=%s sid=%s",
              1 if cold else 0, box["sql_ms"], box["decode_ms"], box["media_ms"],
              box["json_ms"], total_ms, box["rows"], box["media_count"],
              limit, offset, order, session_id)


def _install_messages_timing(tx):
    from aiohttp import web as aio_web
    from hermes_state import SessionDB

    cls = api.APIServerAdapter
    ensure = cls._ensure_session_db_async
    if not inspect.iscoroutinefunction(ensure):
        raise RuntimeError("_ensure_session_db_async is not a coroutine method")

    @wraps(ensure)
    async def ensure_timed(self):
        box = {"t0": time.monotonic()}
        _MSG_BOX.set(box)
        return await ensure(self)
    ensure_timed.__hermes_app_compat__ = VERSION
    tx.set(cls, "_ensure_session_db_async", ensure_timed)

    get_messages = SessionDB.get_messages

    @wraps(get_messages)
    def get_messages_timed(self, *args, **kwargs):
        box = _MSG_BOX.get()
        if box is None or "sql_ms" in box:
            return get_messages(self, *args, **kwargs)
        started = time.monotonic()
        rows = get_messages(self, *args, **kwargs)
        box["sql_ms"] = (time.monotonic() - started) * 1000.0
        box["rows"] = len(rows) if isinstance(rows, list) else -1
        box["page"] = (args[0] if args else kwargs.get("session_id"),
                       kwargs.get("limit"), kwargs.get("offset", 0),
                       bool(kwargs.get("latest")))
        box["decode_ms"] = 0.0
        box["media_ms"] = 0.0
        box["media_count"] = 0
        return rows
    get_messages_timed.__hermes_app_compat__ = VERSION
    tx.set(SessionDB, "get_messages", get_messages_timed)

    json_response = aio_web.json_response

    @wraps(json_response)
    def json_response_timed(*args, **kwargs):
        box = _MSG_BOX.get()
        if box is None or "sql_ms" not in box:
            return json_response(*args, **kwargs)
        started = time.monotonic()
        response = json_response(*args, **kwargs)
        finished = time.monotonic()
        box["json_ms"] = (finished - started) * 1000.0
        if not box.get("done"):
            box["done"] = True
            try:
                _messages_stage_finalize(box, finished)
            except Exception as exc:
                log.debug("messages-stage finalize failed: %s", type(exc).__name__)
        return response
    json_response_timed.__hermes_app_compat__ = VERSION
    tx.set(aio_web, "json_response", json_response_timed)




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


async def _activity_launch_entry(registry, adapter, launch):
    """Track + preview one _RunLaunch (both runs executor branches)."""
    entry = None
    try:
        entry = _activity_track(registry, adapter, run_id=launch.run_id,
                                session_id=launch.session_id,
                                scope=adapter._run_owners.get(launch.run_id),
                                source="runs_api")
        if entry is not None and entry["user"] is None:
            try:
                after = await _activity_last_id(registry, adapter, launch.session_id)
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
        entry = None
    return entry


def _install_activity(tx):
    from gateway.platforms import api_server_runs as runs
    global _ACTIVITY
    cls = api.APIServerAdapter
    if _BACKEND not in BACKENDS:
        raise RuntimeError("activity backend not implemented for this source")
    state = getattr(api, _STATE, None)
    if state is None:
        raise RuntimeError("compat state missing")
    # Capability gate (backend-aware): activity needs the approval unit's
    # queue/status bridge of the CURRENT backend — the base copy, or the target
    # native integration's queue mirror. Dependency check first, route second.
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
        await _activity_launch_entry(registry, self, launch)
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

    if _BACKEND == "target":
        # Runs dispatched to a live Bot Chat owner still surface through the
        # runs API status stream, so they get the same track/preview/settle
        # wrap as the in-process executor branch.
        _require(runs, "_execute_run_via_live_owner")
        _signature(runs, "_execute_run_via_live_owner", "self", "run", "home", "record", "_api_server")
        old_live = runs._execute_run_via_live_owner

        @wraps(old_live)
        async def execute_live(self, run, home, record, **kwargs):
            await _activity_launch_entry(registry, self, run)
            try:
                return await old_live(self, run, home, record, **kwargs)
            finally:
                try:
                    _activity_settle(registry, self, run.run_id, "executor-end")
                except Exception as exc:
                    _activity_fault(registry, type(exc).__name__)
        tx.set(runs, "_execute_run_via_live_owner", execute_live)

        # A SESSION turn handed to a live owner executes outside this process;
        # no local hook can observe it. First release fails closed: once any
        # handoff happens, snapshots answer 503 (never a fabricated idle) for
        # the process; full receipt tracking is a separate batch.
        _require(cls, "_stream_through_live_bot_chat")
        old_handoff = cls._stream_through_live_bot_chat

        @wraps(old_handoff)
        async def handoff(self, request, ctx, *args, **kwargs):
            result = await old_handoff(self, request, ctx, *args, **kwargs)
            if result is not None:
                with registry["lock"]:
                    if not registry["closed"] and not registry["blind"]:
                        registry["blind"] = "session-live-owner-handoff"
            return result
        tx.set(cls, "_stream_through_live_bot_chat", handoff)


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


# ---- push unit (NTFY-PORT: viewer-gone ntfy wake-ups) -------------------------
# Registry (process-global in the compat state, shared across managers):
#   runs: (id(adapter), run_id) -> one state per session-SSE turn this unit
#     registered. state = {key, adapter, run_id, session_id, scope, loop, queue,
#     settings(server,topic), detached, closing, released, pending,
#     approval_text{}, pushed(set), approval_seq, terminal, terminal_pushed,
#     terminal_acked, discard, expires}
# The three wake-ups (approval needed / reply ready / run failed) publish at
# most once each per run, and only after the run went DETACHED (an SSE socket
# failure on the writer side). An attached viewer means zero pushes; a terminal
# frame already written to the socket is acknowledged and never re-pushed after
# a later disconnect. cancelled/interrupted never push.
# All upstream bindings are class/method wrappers installed through the
# transaction, so a hot reload swaps every binding even though the aiohttp
# router keeps serving the copy that was bound at connect() (its `self.` calls
# dispatch through this class). Registration rides the native
# _register_session_stream_approval call (after owner+queued exist, before the
# _run_and_signal task starts) and never registers a second notify producer;
# the ntfy side-channel reads the same events the native callback emits.

def _push_settings():
    """Profile-aware immutable (server, topic) snapshot, read INSIDE the
    request's scope. load_user_config_effective first (raw -> env expand ->
    managed overlay; no unknown-key allowlist strips `push`), raw push-key read
    as degradation. Unconfigured or malformed -> None -> original behavior."""
    push = None
    try:
        from hermes_cli.config_effective import load_user_config_effective
        cfg = load_user_config_effective()
        push = cfg.get("push") if isinstance(cfg, dict) else None
    except Exception:
        push = None
    if not isinstance(push, dict):
        push = _push_raw_settings()
    server = str(push.get("ntfy_server") or "").rstrip("/")
    topic = str(push.get("ntfy_topic") or "")
    if not server.startswith(("http://", "https://")) or not topic:
        return None
    return (server, topic)


def _push_raw_settings() -> dict:
    # Degraded path only: read the raw `push` mapping from the profile-aware
    # config path. Never a full load_config(), never a hardcoded ~/.hermes.
    try:
        from hermes_cli.config import get_config_path
        from utils import fast_safe_load
        with open(get_config_path(), encoding="utf-8-sig") as handle:
            raw = fast_safe_load(handle)
        push = raw.get("push") if isinstance(raw, dict) else None
        return push if isinstance(push, dict) else {}
    except Exception:
        return {}


def _push_preview(text):
    """Plain-text preview of a terminal output: data URLs and MEDIA payloads
    collapse to a placeholder (they must never ride into a push), bounded by
    characters AND by UTF-8 bytes."""
    if not isinstance(text, str) or not text.strip():
        return PUSH_FALLBACK_REPLY
    cleaned = PUSH_DATA_URL_RE.sub("[附件]", text).strip()
    if not cleaned:
        return PUSH_FALLBACK_REPLY
    from . import ntfy_notify
    return ntfy_notify.utf8_cut(cleaned[:PUSH_PREVIEW_CHARS], ntfy_notify.BODY_BYTES)


def _push_detail(text, fallback):
    from . import ntfy_notify
    cleaned = str(text).strip() if text is not None else ""
    return ntfy_notify.utf8_cut(cleaned[:PUSH_DETAIL_CHARS], ntfy_notify.BODY_BYTES) or fallback


def _push_schedule(registry, st, transition):
    """Worker/executor callbacks only POST; every state transition serializes
    on the run's own event loop under the registry lock."""
    def guarded():
        with registry["lock"]:
            if registry["closed"] or st["released"]:
                return
            transition()
    try:
        on_loop = asyncio.get_running_loop() is st["loop"]
    except RuntimeError:
        on_loop = False
    if on_loop:
        guarded()
    elif not st["loop"].is_closed():
        with suppress(RuntimeError):
            st["loop"].call_soon_threadsafe(guarded)


def _push_publish(st, kind, text=""):
    """Single publish exit; call under the registry lock on the run's loop."""
    from . import ntfy_notify
    try:
        from . import notification_events as _ne
        if _ne.capability_enabled() and kind in ("completed", "failed"):
            # R6: while the notification ledger is live IT owns terminal
            # notifications (read/notification ledger decides, never the
            # socket-ack policy); no second publish from this exit.
            return
    except Exception:
        pass
    server, topic = st["settings"]
    if kind == "approval":
        ntfy_notify.publish(
            server, topic, PUSH_TITLES["approval"],
            "等你核准：" + _push_detail(text, PUSH_FALLBACK_APPROVAL) + "\n打開 Hermes App 按按鈕",
            priority="high", tags=["warning", PUSH_ECHO_TAG])
    elif kind == "completed":
        ntfy_notify.publish(server, topic, PUSH_TITLES["reply"], text or PUSH_FALLBACK_REPLY,
                            priority="default", tags=["dart", PUSH_ECHO_TAG])
    elif kind == "failed":
        ntfy_notify.publish(server, topic, PUSH_TITLES["failed"],
                            _push_detail(text, PUSH_FALLBACK_FAILED),
                            priority="high", tags=["x", PUSH_ECHO_TAG])


def _push_start_discard(st):
    """One bounded discard consumer per detached run: token deltas and tool
    progress must not pile into a queue nobody reads. Runs as a background
    TASK (never a second active agent); ends at the worker's None sentinel."""
    if st["discard"] is not None:
        return
    queue = st["queue"]

    async def _discard():
        while True:
            if await queue.get() is None:
                return
            while True:  # drain the rest of the backlog within one wake-up
                try:
                    item = queue.get_nowait()
                except asyncio.QueueEmpty:
                    break
                if item is None:
                    return

    def _forget(task):
        if st["discard"] is task:
            st["discard"] = None
    task = st["loop"].create_task(_discard())
    with suppress(Exception):
        st["adapter"]._track_background_task(task)
    task.add_done_callback(_forget)
    st["discard"] = task


def _push_release(registry, st):
    if registry["runs"].get(st["key"]) is st:
        registry["runs"].pop(st["key"], None)
    st["released"] = True
    task = st["discard"]
    if task is not None and not task.done() and not st["loop"].is_closed():
        with suppress(RuntimeError):
            st["loop"].call_soon_threadsafe(task.cancel)


def _push_prune(registry):
    now = time.monotonic()
    for st in list(registry["runs"].values()):
        if st["expires"] < now:
            _push_release(registry, st)
    while len(registry["runs"]) > PUSH_MAX_STATES:
        _push_release(registry, min(registry["runs"].values(), key=lambda s: s["expires"]))


def _push_detach(registry, st, reason):
    if st["detached"] or st["closing"]:
        return
    st["detached"] = True
    log.info("push: viewer gone for run %s (%s); turn keeps running", st["run_id"], reason)
    _push_start_discard(st)
    rid = st["pending"]
    if rid is not None and rid not in st["pushed"]:
        st["pushed"].add(rid)
        if not _push_approval_exit_handed_off():
            _push_publish(st, "approval", st["approval_text"].get(rid, PUSH_FALLBACK_APPROVAL))
    terminal = st["terminal"]
    if terminal is not None and not st["terminal_acked"] and not st["terminal_pushed"] \
            and terminal[0] != "cancelled":
        st["terminal_pushed"] = True
        _push_publish(st, terminal[0], terminal[1])


def _push_status_transition(registry, st, status, fields):
    # Runs through _set_run_status, the ONLY push event entrance; the original
    # status write already happened before this is scheduled.
    if st["closing"]:
        return
    st["expires"] = time.monotonic() + PUSH_RETENTION_SECONDS
    if status == "waiting_for_approval" and isinstance(fields.get("approval"), dict):
        event = fields["approval"]
        rid = event.get("request_id")
        if rid is None:  # no native id on this event: per-run monotonic generation
            st["approval_seq"] += 1
            rid = "gen-" + str(st["approval_seq"])
        desc = event.get("description") or event.get("command") or PUSH_FALLBACK_APPROVAL
        with suppress(Exception):
            desc = api._redact_api_error_text(desc)
        st["approval_text"][rid] = str(desc)[:PUSH_DETAIL_CHARS]
        st["pending"] = rid
        if st["detached"] and rid not in st["pushed"]:
            st["pushed"].add(rid)
            if not _push_approval_exit_handed_off():
                _push_publish(st, "approval", st["approval_text"][rid])
        return
    if status == "running":
        if fields.get("last_event") != "approval.request":
            st["pending"] = None  # approval.responded mirror / progress moved on
        return
    if status in ("completed", "failed", "cancelled", "interrupted"):
        st["pending"] = None
        if st["terminal"] is None:
            if status == "completed":
                st["terminal"] = ("completed", _push_preview(fields.get("output")))
            elif status == "failed":
                detail = fields.get("error") or fields.get("turn_exit_reason") \
                    or PUSH_FALLBACK_FAILED
                st["terminal"] = ("failed", str(detail)[:PUSH_DETAIL_CHARS])
            else:
                st["terminal"] = ("cancelled", "")
        if st["detached"] and not st["terminal_acked"] and not st["terminal_pushed"] \
                and st["terminal"][0] != "cancelled":
            st["terminal_pushed"] = True
            _push_publish(st, st["terminal"][0], st["terminal"][1])


def _push_status_hook(registry, st, status, fields):
    _push_schedule(registry, st, lambda: _push_status_transition(registry, st, status, fields))


def _push_approval_exit_handed_off() -> bool:
    """True while the approval_inbox dispatcher owns the approval push exit
    (capability live + dispatcher attached). Bookkeeping in the push unit
    continues; only the approval PUBLISH moves to the new dispatcher, so an
    inbox-covered run is never notified twice and reply/failed policies never
    change. False keeps the legacy detached-only exit byte-for-byte."""
    try:
        from . import approval_inbox
        state = getattr(api, _STATE, None) or {}
        inbox = state.get("approval_inbox")
        return bool(inbox) and inbox.get("dispatch") is not None \
            and approval_inbox.capability_enabled(inbox)
    except Exception:
        return False


def _install_push(tx):
    from . import ntfy_notify  # noqa: F401 (the publish exits live in the helper)
    from gateway.platforms import api_server_runs as runs
    cls = api.APIServerAdapter
    if _BACKEND != "target":
        raise RuntimeError("push backend not implemented for this source")
    state = getattr(api, _STATE, None)
    if state is None:
        raise RuntimeError("compat state missing")
    # Push rides the approval unit's target integration: the native notify
    # callback is the only approval producer, and its lifecycle (worker finally
    # unregister) is what a detached phone can still resolve against.
    if state["groups"].get("approval") is None or \
            state["manifest"].get("approval", {}).get("status") != "applied":
        raise RuntimeError("approval unit not applied")
    _require(cls, "_register_session_stream_approval", "_prepare_sse_response", "_set_run_status",
             "_drain_session_stream_task_on_disconnect", "_track_background_task",
             "interrupt_active_runs", "_handle_stop_run")
    _require(runs, "_handle_stop_run")
    _require(api, "_redact_api_error_text")
    _signature(cls, "_register_session_stream_approval", "self", "run_id", "events", "message_id")
    _signature(cls, "_prepare_sse_response", "self", "request", "session_id", "gateway_session_key")
    _signature(cls, "_set_run_status", "self", "run_id", "status")
    _signature(cls, "_drain_session_stream_task_on_disconnect", "self", "run_id", "task",
               "interrupt_message", "shield_wait")
    _signature(cls, "interrupt_active_runs", "self", "reason")
    _signature(runs, "_handle_stop_run", "self", "request", "_api_server")

    registry = state.get("push")
    if registry is None:
        registry = state["push"] = {"lock": threading.RLock(), "runs": {}, "closed": False}
    registry["closed"] = False  # a fresh install re-claims publishing
    global _PUSH
    _PUSH = registry

    def close_all():
        with registry["lock"]:
            registry["closed"] = True
            entries = list(registry["runs"].values())
            registry["runs"].clear()
        for st in entries:
            st["released"] = True
            task = st["discard"]
            if task is not None and not task.done() and not st["loop"].is_closed():
                with suppress(RuntimeError):
                    st["loop"].call_soon_threadsafe(task.cancel)
    tx.cleanups.append(close_all)

    # -- admission: one state per session-SSE turn, after owner+queued exist
    # and before the _run_and_signal task starts. The native approval callback
    # stays the only producer; this adds a side-channel, never a second one.
    old_register = cls._register_session_stream_approval

    @wraps(old_register)
    def register(self, run_id, events, message_id):
        callback = old_register(self, run_id, events, message_id)
        try:
            if registry["closed"]:
                return callback
            settings = _push_settings()
            if settings is None:
                return callback  # unconfigured: original disconnect behavior
            key = (id(self), run_id)
            st = {
                "key": key, "adapter": self, "run_id": run_id,
                "session_id": events.session_id, "scope": self._run_owners.get(run_id),
                "loop": events.loop, "queue": events.queue, "settings": settings,
                "detached": False, "closing": False, "released": False,
                "pending": None, "approval_text": {}, "pushed": set(), "approval_seq": 0,
                "terminal": None, "terminal_pushed": False, "terminal_acked": False,
                "discard": None, "expires": time.monotonic() + PUSH_RETENTION_SECONDS,
            }
            with registry["lock"]:
                registry["runs"][key] = st
                _push_prune(registry)
            _PUSH_STREAM.set(st)
        except Exception as exc:
            log.warning("push registration skipped: %s", type(exc).__name__)
        return callback
    tx.set(cls, "_register_session_stream_approval", register)

    # -- SSE writer: a socket failure inside prepare() detaches through the same
    # branch as a failed write; successful writes acknowledge terminal frames.
    old_prepare = cls._prepare_sse_response

    @wraps(old_prepare)
    async def prepare(self, request, *args, **kwargs):
        st = _PUSH_STREAM.get()
        if st is not None:
            _PUSH_STREAM.set(None)  # consume: only this session stream is observed
        try:
            response = await old_prepare(self, request, *args, **kwargs)
        except OSError:
            if st is not None:
                # socket failure AFTER the turn task started: same detach branch,
                # so a background task is never left without a viewer-gone flag
                _push_schedule(registry, st, lambda: _push_detach(registry, st, "prepare socket"))
            raise  # non-socket setup errors keep the original failure cleanup
        if st is not None:
            original_write = response.write

            async def write(data, *a, **kw):
                result = await original_write(data, *a, **kw)
                try:  # acknowledged once written: a later disconnect must not re-push
                    if st["terminal"] is not None and not st["terminal_acked"] \
                            and PUSH_TERMINAL_FRAME_RE.match(bytes(data[:64])):
                        def ack():
                            st["terminal_acked"] = True
                        _push_schedule(registry, st, ack)
                except Exception:
                    pass
                return result
            response.write = write
        return response
    tx.set(cls, "_prepare_sse_response", prepare)

    # -- the single push event entrance: observe every status write AFTER the
    # original ran (the activity wrapper below stays intact; status is never
    # rewritten here and replays dedup through the per-run state)
    old_set = cls._set_run_status

    @wraps(old_set)
    def set_status(self, run_id, status, **fields):
        result = old_set(self, run_id, status, **fields)
        try:
            st = registry["runs"].get((id(self), run_id))
            if st is not None:
                _push_status_hook(registry, st, status, fields)
        except Exception as exc:
            log.debug("push status hook skipped: %s", type(exc).__name__)
        return result
    tx.set(cls, "_set_run_status", set_status)

    # -- disconnect vs cancel: ONLY the writer's socket-failure branch (the one
    # upstream labels "SSE client disconnected", never shield-waited) switches
    # to keep-running. CancelledError, explicit stop and shutdown drain natively.
    old_drain = cls._drain_session_stream_task_on_disconnect

    @wraps(old_drain)
    async def drain(self, run_id, task, **kwargs):
        st = registry["runs"].get((id(self), run_id))
        if st is not None and not kwargs.get("shield_wait") \
                and kwargs.get("interrupt_message") == "SSE client disconnected":
            _push_schedule(registry, st, lambda: _push_detach(registry, st, "write failed"))
            return  # no interrupt, no drain: _track_background_task keeps holding the turn
        if st is not None:  # cancellation/shutdown path: suppress wake-ups, drain natively
            with registry["lock"]:
                st["closing"] = True
            discard = st["discard"]
            if discard is not None and not discard.done():
                with suppress(RuntimeError):
                    st["loop"].call_soon_threadsafe(discard.cancel)
        return await old_drain(self, run_id, task, **kwargs)
    tx.set(cls, "_drain_session_stream_task_on_disconnect", drain)

    # -- explicit stop and shutdown interrupt keep their original cleanup; the
    # runs they settle never produce a fabricated wake-up.
    old_stop = runs._handle_stop_run

    @wraps(old_stop)
    async def stop(self, request, **kwargs):
        result = await old_stop(self, request, **kwargs)
        try:
            st = registry["runs"].get((id(self), request.match_info.get("run_id")))
            if st is not None and result.status < 300:
                with registry["lock"]:
                    st["closing"] = True
                discard = st["discard"]
                if discard is not None and not discard.done():
                    with suppress(RuntimeError):
                        st["loop"].call_soon_threadsafe(discard.cancel)
        except Exception:
            pass
        return result
    tx.set(runs, "_handle_stop_run", stop)

    old_interrupt = cls.interrupt_active_runs

    @wraps(old_interrupt)
    def interrupt(self, reason):
        try:
            return old_interrupt(self, reason)
        finally:
            with registry["lock"]:
                for st in list(registry["runs"].values()):
                    if st["adapter"] is self and st["terminal"] is None:
                        st["closing"] = True
                        discard = st["discard"]
                        if discard is not None and not discard.done():
                            with suppress(RuntimeError):
                                st["loop"].call_soon_threadsafe(discard.cancel)
    tx.set(cls, "interrupt_active_runs", interrupt)


def _install_cron_bridge(tx):
    """P5 cron-delivery bridge: app platform + app-only scheduler shims.

    Every upstream-dependent piece lives here: the reviewed fingerprints, the
    app-only execution-identity seams (live metadata / standalone ContextVar),
    the mirror/seed suppression, the single-target preflight, the queued
    outcome, and the atomic SessionDB writer bindings. Registration itself is
    per profile context and runs in install(), not in this process-global
    first-owner branch.
    """
    from . import app_platform, cron_delivery_store
    from cron import scheduler as sched
    from cron import scheduler_delivery as sd
    from gateway.platform_registry import PlatformEntry, platform_registry
    from hermes_state import SessionDB
    from hermes_state_messages import _INSERT_MESSAGE_SQL
    import hermes_state_errors as serr
    from hermes_state_messages import SessionMessagesMixin
    if _BACKEND != "target":
        raise RuntimeError("cron_bridge backend not implemented for this source")
    state = getattr(api, _STATE, None)
    if state is None:
        raise RuntimeError("compat state missing")
    state["cron_bridge"] = {"store": cron_delivery_store, "app": app_platform}
    # Ownership gate FIRST: registry.register is last-writer-wins, so a name
    # already held by anyone else (builtin or another plugin) fails this unit
    # closed rather than clobbering them. Re-claiming our own name is fine.
    entry = platform_registry.get(app_platform.PLATFORM_NAME)
    if entry is not None and (entry.source != "plugin"
                              or entry.plugin_name != "hermes-app-compat"):
        raise RuntimeError("app platform name occupied")
    for field in app_platform._entry_fields():  # PlatformEntry capability gate
        if field not in PlatformEntry.__dataclass_fields__:
            raise RuntimeError(f"PlatformEntry field missing: {field}")
    for name in ("_live_route_metadata", "_standalone_send", "_target_mirror_eligible",
                 "_deliver_result"):
        _cron_fingerprint(sd, name)
    _require(sd, "_resolve_delivery_targets")
    _signature(sd, "_deliver_result", "job", "content")
    _signature(sd, "_target_mirror_eligible", "job", "target", "global_mirror")
    _cron_fingerprint(SessionMessagesMixin, "append_delegation_delivery")  # writer reference
    for name in ("_check_transcript_write_guards", "_message_row_params",
                 "_bump_session_counters"):
        _cron_fingerprint(SessionMessagesMixin, name)
    _cron_fingerprint(SessionDB, "_execute_write")
    _signature(SessionMessagesMixin, "_check_transcript_write_guards", "self", "conn",
               "session_id", "compression_lock_holder", "reject_active_turn_lease")
    cron_delivery_store.configure(
        insert_sql=_INSERT_MESSAGE_SQL,
        errors={"SessionTurnLeaseLostError": serr.SessionTurnLeaseLostError,
                "CompressionSessionClosedError": serr.CompressionSessionClosedError})
    tx.cleanups.append(cron_delivery_store.reset)

    def identity_from_job(job):
        return {"job_id": str(job.get("id") or ""),
                "execution_id": str(job.get("execution_id") or ""),
                "name": str(job.get("name") or job.get("id") or "")}

    def _is_app_target(t):
        return str(getattr(t, "platform_name", "")).lower() == app_platform.PLATFORM_NAME

    # -- live lane: namespaced delivery identity in the app branch ONLY. Other
    # platforms keep their original metadata byte-for-byte.
    old_metadata = sd._live_route_metadata

    def route_metadata(t):
        thread_id, route, media = old_metadata(t)
        if _is_app_target(t):
            route = dict(route)
            route["hermes_app_cron_identity"] = identity_from_job(t.job)
        return thread_id, route, media
    tx.set(sd, "_live_route_metadata", route_metadata)

    # -- standalone lane: an immutable identity scope around the ORIGINAL call
    # (asyncio.run in-thread and contextvars.copy_context() in a fresh thread
    # both carry it to standalone_app_send; no process-global job lookup).
    old_standalone = sd._standalone_send

    def standalone_send(t, content, media_files):
        if not _is_app_target(t):
            return old_standalone(t, content, media_files)
        token = app_platform.DELIVERY_IDENTITY.set(identity_from_job(t.job))
        try:
            return old_standalone(t, content, media_files)
        finally:
            app_platform.DELIVERY_IDENTITY.reset(token)
    tx.set(sd, "_standalone_send", standalone_send)

    # -- anti-double-delivery: the bridge writer already lands the report in the
    # target timeline, so the app branch takes NO generic mirror and NO
    # thread/in-channel seeding. Non-app decisions are untouched.
    old_eligible = sd._target_mirror_eligible

    def target_mirror_eligible(job, target, **kwargs):
        if str(target.get("platform", "")).lower() == app_platform.PLATFORM_NAME:
            return False
        return old_eligible(job, target, **kwargs)
    tx.set(sd, "_target_mirror_eligible", target_mirror_eligible)

    # -- outcome adapter + single-target preflight, on BOTH the defining module
    # and the cron.scheduler facade re-export (drain/tick read the facade).
    old_deliver = sd._deliver_result

    def deliver_result(job, content, adapters=None, loop=None, *, for_failure=False):
        try:
            targets = sd._resolve_delivery_targets(job, for_failure=for_failure)
            app_targets = [t for t in targets
                           if str(t.get("platform", "")).lower() == app_platform.PLATFORM_NAME]
        except Exception:
            app_targets = []
        if not app_targets:
            return old_deliver(job, content, adapters, loop, for_failure=for_failure)
        if len(targets) != len(app_targets):
            others = sorted({str(t.get("platform")) for t in targets if t not in app_targets})
            return (f"app delivery must be the job's only target; refusing before any "
                    f"platform send (mixed with {', '.join(others)})")
        if len({str(t.get("chat_id")) for t in app_targets}) != 1:
            return "app delivery supports exactly one session target per job"
        if "MEDIA:" in content or (job.get("deliver") or "").strip().lower() == "all":
            return ("app delivery is text-only, single-target; refusing the job before any "
                    "platform send (MEDIA token or broadcast deliver)")
        job.pop("last_delivery_queued", None)
        error = old_deliver(job, content, adapters, loop, for_failure=for_failure)
        execution_id = str(job.get("execution_id") or "")
        if error is None and execution_id:
            try:
                from hermes_constants import get_hermes_home
                receipt = cron_delivery_store.receipt_for(get_hermes_home(), execution_id)
            except Exception:
                receipt = None
            if receipt and receipt["status"] == "queued":
                # Queued, not delivered: the observable bridge receipt is what
                # the scheduler's queued branch (last_delivery_queued) shows.
                job["last_delivery_queued"] = {
                    "platform": app_platform.PLATFORM_NAME,
                    "target": f"app:{receipt['session_id']}",
                    "receipt": receipt["delivery_key"]}
        return error
    tx.set(sd, "_deliver_result", deliver_result)
    if getattr(sched, "_deliver_result", None) is not None:
        # The facade re-export must ride the SAME wrapper or drain/tick lanes
        # silently bypass the bridge (reviewed re-export line, plan section 4).
        tx.set(sched, "_deliver_result", deliver_result)
    else:
        raise RuntimeError("scheduler facade re-export missing")


def _wake_fingerprint(target, name):
    if _BACKEND != "target":
        raise RuntimeError("wake backend not reviewed for this source")
    actual = hashlib.sha256(inspect.getsource(inspect.unwrap(getattr(target, name))).encode()).hexdigest()
    if actual != WAKE_TARGET_FINGERPRINTS[name]:
        raise RuntimeError(f"wake source changed: {name}")


def _install_wake(tx):
    """APPWAKE: server authority for foreground auto-wake.

    A: the messages projection exposes the minimal server-verified cron
    identity (never raw metadata). B: the durable consumption ledger +
    capability-gated admission/receipt contract + the chat/stream dispatch
    seam. No scheduler, no cron delivery, no core files — this unit cannot
    start a turn by itself; only an authenticated foreground client holding
    a reserved batch can, and the ledger says whether a report was consumed
    at most once.
    """
    from . import auto_wake, auto_wake_store
    from hermes_state import SessionDB
    if _BACKEND != "target":
        raise RuntimeError("wake backend not reviewed for this source")
    state = getattr(api, _STATE, None)
    if state is None:
        raise RuntimeError("compat state missing")
    cls = api.APIServerAdapter
    _require(cls, "_http_route_table", "_handle_capabilities", "_ensure_session_db_async",
             "_session_db_unavailable", "_read_json_body", "_handle_session_chat_stream",
             "_handle_session_chat", "_check_auth", "_room_grant_token", "_run_agent")
    _require(api, "_error_response")
    _require(api.web, "json_response")
    _signature(cls, "_handle_session_chat_stream", "self", "request")
    _wake_fingerprint(SessionDB, "_read_all")
    _wake_fingerprint(SessionDB, "_session_turn_lease_key")
    # The chat/stream seam itself is fingerprinted + wrapped by the approval
    # unit earlier in UNITS order (it admits the agent request); wake rides
    # that reviewed chain rather than re-fingerprinting a wrapped function.
    auto_wake_store.configure(reviewed=True)
    tx.cleanups.append(auto_wake_store.reset)
    state["wake"] = {"module": auto_wake, "store": auto_wake_store, "backend": _BACKEND}

    def wake_home():
        from hermes_constants import get_hermes_home
        return get_hermes_home()

    # -- A: minimal provenance on the messages projection ---------------------
    descriptor = inspect.getattr_static(cls, "_message_response")
    if not isinstance(descriptor, staticmethod):
        raise RuntimeError("_message_response is no longer static")
    original = descriptor.__func__

    @wraps(original)
    def message(row):
        result = original(row)
        provenance = auto_wake.provenance_of(row)
        if provenance is not None:
            # Only rows the bridge WROTE (verified block) gain the field;
            # every other row's response stays byte-identical.
            result = {**result, "cron_provenance": provenance}
        return result
    message.__hermes_app_compat__ = VERSION
    tx.set(cls, "_message_response", staticmethod(message))



    # -- B: routes (admit / receipt GET+report / release) ----------------------
    old_table = cls._http_route_table
    endpoints = (
        ("auto_wake_admit", ("POST", "/api/sessions/{session_id}/auto-wake/admit")),
        ("auto_wake_receipt", ("GET", "/api/sessions/{session_id}/auto-wake/receipt")),
        ("auto_wake_report", ("POST", "/api/sessions/{session_id}/auto-wake/receipt")),
        ("auto_wake_release", ("POST", "/api/sessions/{session_id}/auto-wake/release")),
    )
    for name, route in api._CAPABILITY_ENDPOINTS:
        for ours_name, ours_route in endpoints:
            if (name == ours_name or route == ours_route) and (name, route) != (ours_name, ours_route):
                raise RuntimeError("wake capability collision")
    if any(hasattr(cls, "_handle_" + name) for name, _ in endpoints):
        return "native_candidate"

    def guarded(handler):
        async def wrapper(self, request):
            # Room grants are NOT a session permission (activity rule).
            if self._room_grant_token(request):
                return api._error_response("Room grants may not use auto-wake.",
                                           403, code="room_grant_not_allowed")
            auth_err = self._check_auth(request)
            if auth_err:
                return auth_err
            return await handler(self, request)
        return wrapper

    async def _resolved(self, request):
        sid = request.match_info["session_id"]
        db = await self._ensure_session_db_async()
        if db is None:
            return None, None, cls._session_db_unavailable()
        session = await asyncio.to_thread(db.get_session, sid)
        if session is None:
            return None, None, api._error_response(
                f"Session not found: {sid}", 404, code="session_not_found")
        try:
            resolved = await asyncio.to_thread(db.resolve_resume_session_id, sid)
        except Exception:
            resolved = sid
        return db, resolved, None

    def _json(payload, status=200):
        return api.web.json_response(payload, status=status,
                                     headers={"Cache-Control": "no-store"})

    @guarded
    async def admit(self, request):
        db, resolved, err = await _resolved(self, request)
        if err is not None:
            return err
        body, err = await self._read_json_body(request)
        if err is not None:
            return err
        keys = body.get("delivery_keys")
        if not isinstance(keys, list):
            return api._error_response("delivery_keys must be a list", 400,
                                       code="wake_bad_request")
        try:
            outcome = await asyncio.to_thread(
                auto_wake_store.admit, wake_home(),
                session_id=resolved, resolved=resolved, keys=keys, db=db)
        except auto_wake_store.LedgerUnavailable:
            return api._error_response("Auto-wake ledger unavailable.", 503,
                                       code="wake_ledger_unavailable")
        return _json({"object": "hermes_app.wake_admission", **outcome})

    @guarded
    async def receipt_get(self, request):
        db, resolved, err = await _resolved(self, request)
        if err is not None:
            return err
        batch_id = (request.query.get("batch_id") or "").strip()
        if not batch_id:
            return api._error_response("batch_id is required", 400, code="wake_bad_request")
        view = await asyncio.to_thread(auto_wake_store.receipt, wake_home(),
                                       batch_id=batch_id, resolved=resolved)
        if view.get("error"):
            return api._error_response("Wake batch not found.", 404, code="wake_batch_unknown")
        return _json(view)

    @guarded
    async def receipt_report(self, request):
        db, resolved, err = await _resolved(self, request)
        if err is not None:
            return err
        body, err = await self._read_json_body(request)
        if err is not None:
            return err
        batch_id = str(body.get("batch_id") or "").strip()
        state = str(body.get("state") or "").strip()
        if not batch_id or state not in ("accepted", "terminal", "uncertain"):
            return api._error_response("batch_id and a valid state are required", 400,
                                       code="wake_bad_request")
        outcome = await asyncio.to_thread(
            auto_wake_store.report, wake_home(), batch_id=batch_id, resolved=resolved,
            state=state, run_id=body.get("run_id"))
        if outcome.get("status") == "conflict":
            return api._error_response(
                f"Wake batch is {outcome['state']}; transition refused.", 409,
                code="wake_transition_conflict")
        if outcome.get("error"):
            return api._error_response(outcome["error"], 400, code="wake_bad_request")
        return _json(outcome)

    @guarded
    async def release(self, request):
        db, resolved, err = await _resolved(self, request)
        if err is not None:
            return err
        body, err = await self._read_json_body(request)
        if err is not None:
            return err
        batch_id = str(body.get("batch_id") or "").strip()
        if not batch_id:
            return api._error_response("batch_id is required", 400, code="wake_bad_request")
        outcome = await asyncio.to_thread(auto_wake_store.release, wake_home(),
                                          batch_id=batch_id, resolved=resolved)
        if outcome.get("status") == "conflict":
            return api._error_response(
                f"Release refused from state {outcome['state']}.", 409,
                code="wake_transition_conflict")
        if outcome.get("error"):
            return api._error_response("Wake batch not found.", 404, code="wake_batch_unknown")
        return _json(outcome)

    @wraps(old_table)
    def routes(self):
        rows = list(old_table(self))
        for name, (method, path) in endpoints:
            if not any((m, p) == (method, path) for m, p, _ in rows):
                rows.append((method, path, getattr(self, "_handle_" + name)))
        return rows

    tx.set(cls, "_handle_auto_wake_admit", admit)
    tx.set(cls, "_handle_auto_wake_receipt", receipt_get)
    tx.set(cls, "_handle_auto_wake_report", receipt_report)
    tx.set(cls, "_handle_auto_wake_release", release)
    tx.set(cls, "_http_route_table", routes)
    tx.set(api, "_CAPABILITY_ENDPOINTS", (*api._CAPABILITY_ENDPOINTS, *endpoints))

    # -- capabilities advertisement (auto enable REQUIRES this block) ----------
    old_caps = cls._handle_capabilities

    @wraps(old_caps)
    async def capabilities(self, request, **kwargs):
        response = await old_caps(self, request, **kwargs)
        try:
            payload = json.loads(response.body)
            payload["features"]["auto_wake"] = {
                "enabled": auto_wake_store.bindings_ready(),
                "contract_version": 1,
                "canonical_input": auto_wake.CANONICAL_INPUT,
                "batch_max": auto_wake.BATCH_MAX,
                "limits": {"session_per_hour": auto_wake.SESSION_WAKE_LIMIT,
                           "profile_per_hour": auto_wake.PROFILE_WAKE_LIMIT,
                           "window_seconds": int(auto_wake.QUOTA_WINDOW_SECONDS)},
                "ledger": "durable-delivery-key",
                "selfwake": {key: ((getattr(api, _STATE, {}) or {}).get('manifest', {})
                                   .get('selfwake', {})).get(key)
                             for key in ('status', 'liveness')},
            }
            return api.web.json_response(payload, status=response.status)
        except Exception as exc:
            # A silent fallback here hides wiring bugs as a permanently
            # missing advertisement (App then never offers auto-wake).
            log.warning("capabilities auto_wake advertisement failed: %s: %s",
                        type(exc).__name__, exc)
            return response
    tx.set(cls, "_handle_capabilities", capabilities)

    # -- the ONLY dispatch door: chat/stream carrying a reserved wake_batch ----
    old_stream = cls._handle_session_chat_stream

    async def _settle(self, home, batch_id, resolved, evidence, failure):
        """SELFWAKE S1 double-run blocker: an exception (or a late HTTP error)
        NEVER reverts the batch to reserved on assumption. Only evidence that
        nothing launched — no handoff, no started task — proves the run never
        began; anything else keeps the batch consumed (uncertain) or reports
        the run this process demonstrably started."""
        view = await asyncio.to_thread(auto_wake_store.receipt, home,
                                       batch_id=batch_id, resolved=resolved)
        if view.get("error") or view["receipt"]["state"] != "dispatching":
            return  # someone else already advanced the state machine
        launched = bool(evidence and (evidence.get("launched")
                                      or evidence.get("handoff")
                                      or evidence.get("run_id")))
        if not launched:
            # Pre-launch rejection (auth/drain/concurrency/body parse): the
            # claim and the quota reservation go back.
            await asyncio.to_thread(auto_wake_store.dispatch_failed, home, batch_id)
            return
        run_id = (evidence or {}).get("run_id")
        status = self._run_statuses.get(run_id, {}).get("status") if run_id else None
        if run_id and status is not None:
            # This process knows the run: a terminal one closes the batch, a
            # live/unknown-outcome one stays accepted and observed (never a
            # second POST).
            if status in {"completed", "failed", "cancelled"}:
                await asyncio.to_thread(auto_wake_store.report, home, batch_id=batch_id,
                                        resolved=resolved, state="terminal")
            else:
                await asyncio.to_thread(auto_wake_store.report, home, batch_id=batch_id,
                                        resolved=resolved, state="accepted", run_id=run_id)
            return
        await asyncio.to_thread(auto_wake_store.report, home, batch_id=batch_id,
                                resolved=resolved, state="uncertain")
        log.warning("wake batch %s: %s after launch evidence; consumed without "
                    "re-send (double-run blocker)", batch_id, failure)

    @wraps(old_stream)
    async def stream(self, request, *args, **kwargs):
        try:
            body = await request.json()
        except Exception:
            body = None
        batch_id = None
        if isinstance(body, dict) and isinstance(body.get("wake_batch"), str):
            batch_id = body["wake_batch"].strip()
        if not batch_id:
            return await old_stream(self, request, *args, **kwargs)
        db = await self._ensure_session_db_async()
        if db is None:
            return cls._session_db_unavailable()
        sid = request.match_info["session_id"]
        try:
            resolved = await asyncio.to_thread(db.resolve_resume_session_id, sid)
        except Exception:
            resolved = sid
        home = wake_home()
        raw_input = body.get("message") or body.get("input")
        input_text = raw_input if isinstance(raw_input, str) else None
        gate = await asyncio.to_thread(auto_wake_store.gate_dispatch, home,
                                       batch_id=batch_id, resolved=resolved,
                                       input_text=input_text)
        if gate is not None:
            response = api._error_response(gate["code"], gate["status"], code=gate["code"])
            receipt = gate.get("receipt")
            if isinstance(receipt, dict):
                payload = json.loads(response.body)
                payload["wake_receipt"] = receipt
                return api.web.json_response(payload, status=gate["status"])
            return response
        launch = {"handoff": False, "run_id": None, "launched": False}
        token = _WAKE_LAUNCH.set(launch)
        try:
            try:
                result = await old_stream(self, request, *args, **kwargs)
            except Exception as exc:
                await _settle(self, home, batch_id, resolved, launch, type(exc).__name__)
                raise
            except asyncio.CancelledError:
                # Shutdown cancel is NOT evidence the run never started.
                with suppress(Exception):
                    await asyncio.shield(asyncio.ensure_future(
                        _settle(self, home, batch_id, resolved, launch, "cancelled")))
                raise
            if getattr(result, "status", 200) >= 400:
                await _settle(self, home, batch_id, resolved, launch,
                              f"HTTP {getattr(result, 'status', 0)}")
            return result
        finally:
            _WAKE_LAUNCH.reset(token)
    tx.set(cls, "_handle_session_chat_stream", stream)

    # -- the synchronous chat lane never consumes a wake batch -----------------
    old_chat = cls._handle_session_chat

    @wraps(old_chat)
    async def chat(self, request, *args, **kwargs):
        try:
            body, err = await self._read_json_body(request)
            if err is None and isinstance(body, dict) and body.get("wake_batch"):
                return api._error_response(
                    "wake batches dispatch on chat/stream only.", 400,
                    code="wake_transport_unsupported")
        except Exception:
            pass
        return await old_chat(self, request, *args, **kwargs)
    tx.set(cls, "_handle_session_chat", chat)

    # -- SELFWAKE S1: durable projection identity seam --------------------------
    # The agent's sequence-repair pass 3 merges an adjacent plain-text user
    # pair INTO THE EARLIER dict — a persisted cron report row would swallow
    # the wake's canonical input and flush with the report's
    # internal_notification display metadata. This reviewed pass swap skips
    # EXACTLY that pair (bridge-proven report carrier + canonical wake text);
    # every other merge behaves verbatim. Wire alternation is unaffected:
    # request assembly merges the API copy regardless.
    from agent import agent_runtime_helpers as arh
    _merge_src = inspect.getsource(arh._merge_consecutive_users)
    if (hashlib.sha256(_merge_src.encode()).hexdigest()
            != MERGE_TARGET_FINGERPRINTS["_merge_consecutive_users"]):
        raise RuntimeError("wake source changed: _merge_consecutive_users")

    def _merge_consecutive_users_wake(pass3_messages):
        from agent.context_compressor import _DB_PERSISTED_MARKER, split_user_originated_turn
        repairs = 0
        merged = []
        for msg in pass3_messages:
            prev = merged[-1] if merged and isinstance(merged[-1], dict) else None
            if (
                prev is not None and prev.get("role") == "user"
                and isinstance(msg, dict) and msg.get("role") == "user"
                and split_user_originated_turn(prev)[0] is None
                and prev.get("display_kind") != arh.STEER_DISPLAY_KIND
                and isinstance(prev.get("content", ""), str)
                and isinstance(msg.get("content", ""), str)
                # SELFWAKE S1 delta: a bridge-proven report followed by the
                # canonical wake input keeps TWO durable rows.
                and not (auto_wake.provenance_of(prev) is not None
                         and msg.get("content") == auto_wake.CANONICAL_INPUT)
            ):
                prev_content, new_content = prev.get("content", ""), msg.get("content", "")
                merged_content = (
                    (prev_content + "\n\n" + new_content)
                    if prev_content and new_content else (prev_content or new_content)
                )
                had_api_sidecar = "api_content" in prev
                prev["content"] = merged_content
                arh.drop_stale_api_content(prev)
                if merged_content != prev_content or had_api_sidecar:
                    prev.pop(_DB_PERSISTED_MARKER, None)
                arh._remember_absorbed_row(prev, msg)
                repairs += 1
                continue
            merged.append(msg)
        return merged, repairs
    merge_passes = list(arh._SEQUENCE_REPAIR_PASSES)
    if merge_passes[3] is not arh._merge_consecutive_users:
        raise RuntimeError("wake source changed: _SEQUENCE_REPAIR_PASSES")
    merge_passes[3] = _merge_consecutive_users_wake
    tx.set(arh, "_SEQUENCE_REPAIR_PASSES", tuple(merge_passes))
    state["wake"]["merge_pass"] = _merge_consecutive_users_wake


def _install_selfwake(tx):
    """SELFWAKE: server-side wake support. The unit binds NOTHING in core:
    every touchpoint is compat-internal (bridge-store hooks + the app
    platform drainer + the wake ledger), so the unit is inert by default —
    `wake.selfwake` in profile config decides, fail-closed, at use time.

    Reviewed compat seams (manifest):
      * cron_delivery_store deliver/drain: intent+receipt ONE transaction;
        delivered vs deduped counted apart (drainer summary).
      * app_platform._drain_loop: drainer-drained notification (accelerator;
        the periodic sweep owns liveness).
      * wake wrapper launch evidence + TARGET-copy stamps (S1, that unit).
      * agent_runtime_helpers._SEQUENCE_REPAIR_PASSES swap (S1, wake unit).
    """
    from . import self_wake
    state = getattr(api, _STATE, None)
    if state is None:
        raise RuntimeError("compat state missing")
    # SELFWAKE2 lifecycle state lives on the SHARED compat state (not the
    # module) so it survives the very reload that swaps the module: the
    # generation invalidates queued arms from older loads, and the adapter→
    # loop registry lets the install-time scan find each adapter's owning
    # loop even where no loaded notification ever arrives.
    prev = state.get("selfwake") or {}
    loops = prev.get("loops")
    if loops is None:
        import weakref
        loops = weakref.WeakKeyDictionary()
    state["selfwake"] = {"module": self_wake, "backend": _BACKEND,
                         "generation": int(prev.get("generation", 0)) + 1,
                         "loops": loops}
    if "wake" in state:
        state["wake"]["selfwake"] = self_wake

    def _unload_liveness(_mod=self_wake, _gen=state["selfwake"]["generation"]):
        # Bump the generation BEFORE reset so this load's already-queued
        # callbacks fail their identity guard; other loads carry their own
        # (module, generation) pair and are equally retired by their reset.
        cur = (getattr(api, _STATE, None) or {}).get("selfwake") or {}
        if cur.get("module") is _mod:
            cur["generation"] = int(cur.get("generation", _gen)) + 1
        _selfwake_liveness("stopped", "unload-reset")
        _mod.reset()

    tx.cleanups.append(_unload_liveness)


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
    if _BACKEND == "target":
        return _install_approval_target(tx)
    if _BACKEND != "base":
        raise RuntimeError("approval backend not implemented for this source")
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


# ---- TARGET approval backend (d0288be5b33) ------------------------------------
# The target upstream owns the executor body, worker counter, memory check-in,
# metrics and the native approval notify lifecycle. This backend therefore does
# NOT replace _run_agent, does not run the _session_agent copy, and creates no
# second notify producer: the native _register_session_stream_approval callback
# is the only producer. What remains is the thin bridge the plan keeps on
# purpose: the listener-aware unattended predicate, and a (adapter, run_id)
# queue mirror so approval.responded from POST /v1/runs/{id}/approval also
# reaches the session SSE queue (native only forwards it for /v1/runs streams).

def _install_approval_target(tx):
    from tools import approval, approval_context
    from gateway.platforms import api_server_runs as runs
    cls = api.APIServerAdapter
    for name in ("_handle_session_chat_stream", "_run_agent"):
        _fingerprint(cls, name)
    _require(cls, "_drain_session_stream_task_on_disconnect", "_release_run_owner_if_forgotten",
             "_register_session_stream_approval", "_stream_through_live_bot_chat",
             "_prepare_sse_response", "_concurrency_limited_response", "_track_background_task",
             "_sanitize_runtime_metadata", "_effective_turn_runtime", "_turn_transcript_messages",
             "_conversation_history_for_session", "_run_idempotency_scope", "_set_run_status")
    _require(runs, "_mark_run_event", "_handle_stop_run", "_handle_run_approval", "terminal_run_status",
             "_unregister_approval_notify")
    _require(approval, "_gateway_notify_cb", "register_gateway_notify", "unregister_gateway_notify",
             "_is_unattended_platform_approval_context")
    _require(approval_context, "_is_unattended_platform_approval_context", "get_current_session_key",
             "set_current_session_key", "reset_current_session_key", "_get_session_platform")
    _signature(cls, "interrupt_active_runs", "self", "reason")
    _signature(cls, "_drain_session_stream_task_on_disconnect", "self", "run_id", "task", "interrupt_message", "shield_wait")
    _signature(runs, "_handle_stop_run", "self", "request", "_api_server")
    _signature(runs, "_handle_run_approval", "self", "request", "_api_server")
    _signature(runs, "_mark_run_event", "self", "run_id", "name")

    original_predicate = approval_context._is_unattended_platform_approval_context
    old_event, old_stop = runs._mark_run_event, runs._handle_stop_run
    old_drain = cls._drain_session_stream_task_on_disconnect
    old_interrupt = cls.interrupt_active_runs
    # One mirror entry per live session SSE turn; native owns the notify listener
    # lifecycle entirely (worker finally unregisters), so removal here is pure
    # bookkeeping: stream finally, and the unload cleanup below.
    queues = {}
    # APPROVALPUSH R2: the approval_inbox unit emits its additive approval.resolved
    # onto the SAME session mirror; publishing the live mapping (same dict object)
    # through the compat state is pure observability wiring, no behavior change.
    _state = getattr(api, _STATE, None)
    if _state is not None:
        _state["approval_queues"] = queues

    def predicate():
        if approval_context._get_session_platform() == "api_server":
            try:
                key = approval_context.get_current_session_key(default="")
                if key and callable(approval._gateway_notify_cb(key)):
                    return False
            except Exception:
                log.warning("approval listener lookup failed; original policy retained")
        return original_predicate()

    @wraps(old_event)
    def event(self, run_id, name, **fields):
        result = old_event(self, run_id, name, **fields)
        events = queues.get((id(self), run_id))
        if events is not None:
            try:
                events.enqueue(name, fields)
            except Exception:
                pass  # observability only; the native response already stands
        return result

    async def stream(self, request):
        return await _session_stream_target(self, request, _queues=queues)

    def retire(adapter, run_id):
        _retire((id(adapter), run_id))

    def _retire(key):
        # Mirror removal is idempotent; the native worker finally unregisters the
        # notify callback. Where a blocked guard must wake NOW (stop/shutdown/
        # unload), the same documented primitive upstream uses is the cleanup act.
        if queues.pop(key, None) is not None:
            runs._unregister_approval_notify(key[1])

    @wraps(old_stop)
    async def stop(self, request, **kwargs):
        result = await old_stop(self, request, **kwargs)
        run_id = request.match_info.get("run_id")
        status = self._run_statuses.get(run_id, {}).get("status")
        if result.status < 300 and status in {"stopping", "completed", "failed", "cancelled"}:
            retire(self, run_id)
        return result

    @wraps(old_drain)
    async def drain(self, run_id, task, **kwargs):
        # Disconnect/cancel: mirror removal only. The native drain interrupts the
        # agent, and the executor's own finally releases the listener.
        queues.pop((id(self), run_id), None)
        return await old_drain(self, run_id, task, **kwargs)

    @wraps(old_interrupt)
    def interrupt(self, reason):
        try:
            return old_interrupt(self, reason)
        finally:
            # Shutdown has no request/SSE disconnect to wake a blocked guard.
            for key in [k for k in queues if k[0] == id(self)]:
                retire(self, key[1])

    def close_all():
        for key in list(queues):
            _retire(key)
    tx.cleanups.append(close_all)
    tx.set(approval_context, "_is_unattended_platform_approval_context", predicate)
    tx.set(approval, "_is_unattended_platform_approval_context", predicate)
    tx.set(cls, "_handle_session_chat_stream", api._admit_api_agent_request(stream))
    tx.set(runs, "_mark_run_event", event)
    tx.set(runs, "_handle_stop_run", stop)
    tx.set(cls, "_drain_session_stream_task_on_disconnect", drain)
    tx.set(cls, "interrupt_active_runs", interrupt)


# Reviewed TARGET copy at Hermes revision d0288be5b3330d2442e3907185b8e9d0958297bb.
# Deltas from the upstream method (everything else is verbatim):
#   1. queue-mirror register/pop keyed by (id(self), run_id) around the turn;
#   2. activity registration hook (activity batch; no-op while _ACTIVITY is None);
#   3. module references prefixed with `api.` because this lives outside upstream;
#   4. SELFWAKE S1 launch-evidence stamps for a wake dispatch in flight
#      (_WAKE_LAUNCH; no-op while that contextvar is unset).
async def _session_stream_target(self, request, *, _queues) -> "web.StreamResponse":
    """POST /api/sessions/{session_id}/chat/stream — SSE wrapper over _run_agent."""
    launch = _WAKE_LAUNCH.get()
    limited = self._concurrency_limited_response()
    if limited is not None:
        return limited
    ctx, err = await self._prepare_session_chat(request)
    if err is not None:
        return err
    handed_off = await self._stream_through_live_bot_chat(request, ctx)
    if handed_off is not None:
        if launch is not None:
            # The live Bot Chat lane executed the turn; this lane never will.
            launch["handoff"] = True
        return handed_off
    gateway_session_key, session_id = ctx["gateway_session_key"], ctx["session_id"]
    user_message, runtime_request = ctx["user_message"], ctx["runtime_request"]
    runtime_meta = self._sanitize_runtime_metadata(
        requested_runtime=runtime_request.get("requested"),
        route_source=runtime_request.get("route_source") or "global",
        model_lock=("accepted" if ctx["lock_active"] else ""))
    message_id = f"msg_{api.uuid.uuid4().hex}"
    run_id = f"run_{api.uuid.uuid4().hex}"
    if launch is not None:
        launch["run_id"] = run_id
    events = api._SessionEventQueue(session_id, run_id)
    queue, _event_payload = events.queue, events.payload
    # Claim ownership inside the request's profile scope before any run-keyed state
    # exists, so /v1/runs/{id}* control is confined to the starting profile.
    # See #93689.
    self._run_owners[run_id] = self._run_idempotency_scope(request)
    self._set_run_status(
        run_id, "queued", session_id=session_id, model=ctx["body"].get("model", self._model_name))
    _queues[(id(self), run_id)] = events
    if globals().get("_ACTIVITY") is not None:
        # activity batch hook: owner + queued exist, the task has not started,
        # and registration must not wait for the turn. Never fail the real turn.
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
            event_name = (
                "tool.failed"
                if event_type == "tool.completed" and kwargs.get("is_error")
                else event_type
            )
            events.enqueue(event_name, {"message_id": message_id, "tool_name": tool_name, "preview": preview, "args": args})

    def _commentary(text: str, *, already_streamed: bool = False) -> None:
        # Mid-turn assistant commentary (Codex ``phase="commentary"``, text beside tool calls)
        # as its own typed event — never folded into ``assistant.completed`` (#67580).
        if isinstance(text, str) and text.strip():
            events.enqueue("assistant.commentary", {
                "message_id": message_id, "text": text, "already_streamed": bool(already_streamed)})

    approval_notify = self._register_session_stream_approval(run_id, events, message_id)

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
                active_run_id=run_id, approval_notify_callback=approval_notify,
                approval_session_key=run_id, **ctx["run_kwargs"])
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
            if _queues.get((id(self), run_id)) is events:
                _queues.pop((id(self), run_id), None)
            self._active_run_agents.pop(run_id, None)
            self._run_approval_sessions.pop(run_id, None)
            self._release_run_owner_if_forgotten(run_id)
            await queue.put(_event_payload("done", {}))
            await queue.put(None)

    # NOT in _active_run_tasks: _run_agent already counts this turn for the shutdown drain.
    task = asyncio.create_task(_run_and_signal())
    self._track_background_task(task)
    if launch is not None:
        # Past this line the run exists as a scheduled task; nothing that
        # happens to the SSE plumbing can "unstart" it.
        launch["launched"] = True
    response = await self._prepare_sse_response(request, session_id, gateway_session_key)
    try:
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
        api.logger.debug("[api_server] session SSE stream error: %s", exc)
    return response


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


# ---- approval_inbox unit (APPROVALPUSH R1-R3 + APPROVALSCAN central cut) -----
# Target backend only. The core queue stays the single settlement authority.
# APPROVALSCAN §建議修復: capture lives at the ONE entrance every API approval
# producer ends in — APIServerAdapter._set_run_status("waiting_for_approval",
# approval=…) is written by the session-stream factory (api_server.py), the
# /v1/runs factory (api_server_runs.py) AND the OpenAI chat-streaming factory
# (api_server_openai_routes.py), so no per-factory wrapper is installed. The
# push admission wrapper, native notify, answer handler and settlement
# authority are untouched. Boundary (by design, not an oversight): generic
# gateway TurnRunner cards/plain text, real cron and the no-callback `_pending`
# fallback never write an API status and are NOT covered by this unit — the
# no-listener gap is an admission/lifecycle problem owned elsewhere. The
# release step (B4) ships it ENABLED; set_capability(False) is the kill switch
# and is re-checked on EVERY status invocation (rollback contract: a callback
# created before the switch stops capturing the moment it flips).

INBOX_LOOPS_CAP = 1024        # admission loop bindings; oldest evicted, observable


def _install_approval_inbox(tx):
    import sys
    from . import approval_inbox
    from tools import approval
    from gateway.platforms import api_server_runs as runs
    cls = api.APIServerAdapter
    if _BACKEND != "target":
        raise RuntimeError("approval_inbox backend not implemented for this source")
    state = getattr(api, _STATE, None)
    if state is None:
        raise RuntimeError("compat state missing")
    # Needs the approval unit's native producer/mirror AND the activity epoch.
    for unit in ("approval", "activity"):
        if state["groups"].get(unit) is None or \
                state["manifest"].get(unit, {}).get("status") != "applied":
            raise RuntimeError(unit + " unit not applied")
    if not state.get("activity_epoch"):
        raise RuntimeError("activity epoch missing")
    # The capture cut is the class method itself; the admission seams below only
    # record the owner loop (they never touch approval semantics).
    _require(cls, "_set_run_status", "_run_agent", "_http_route_table",
             "_handle_capabilities")
    _require(runs, "_execute_run", "_handle_run_approval", "_mark_run_event",
             "_load_owned_run", "_run_event")
    _require(approval, "list_gateway_approvals", "resolve_gateway_approval")
    _require(api, "_approval_request_event", "_error_response", "_coerce_request_bool")
    _signature(cls, "_set_run_status", "self", "run_id", "status")
    _signature(runs, "_execute_run", "self", "run")
    _signature(runs, "_handle_run_approval", "self", "request", "_api_server")
    _signature(runs, "_mark_run_event", "self", "run_id", "name")
    _signature(runs, "_load_owned_run", "self", "request", "_api_server", "permission",
               "active_fallback")

    inbox = approval_inbox.ApprovalInbox.open(state)
    loops = inbox.setdefault("loops", {})  # (id(adapter), run_id) -> admission loop

    # -- approval push dispatcher (B2): ONE approval exit while enabled -------
    # Immediate initial notification + one near-timeout reminder replace the
    # detached-only approval publish; reply/failed policies are untouched.
    # push.approval_dispatcher=legacy restores the old exit as a unit (the
    # push-side publish is then skipped ONLY when the dispatcher is live).
    from . import approval_push
    legacy_exit = str(_push_raw_settings().get("approval_dispatcher") or "immediate") \
        .strip().lower() == "legacy"
    if not legacy_exit:
        def reminder_ok(entry, _attach=approval_push):
            # Kill switch covers in-flight reminders: a disabled unit never
            # publishes, on top of the run-not-terminal check.
            return (approval_inbox.capability_enabled(inbox)
                    and _attach._production_status_ok(entry))
        approval_push.attach(inbox, status_ok=reminder_ok)
    tx.cleanups.append(lambda: inbox.__setitem__("dispatch", None))

    def close_all():
        with inbox["lock"]:
            inbox["closed"] = True
            loops.clear()
            timers = [entry.get("timer") for bucket in inbox["by_run"].values()
                      for entry in bucket["entries"].values()]
        for timer in timers:
            if timer is not None:
                timer.cancel()
        approval_inbox.set_capability(False)  # an unloaded unit never advertises
    tx.cleanups.append(close_all)

    enabled = approval_inbox.capability_enabled

    # -- loop metadata at the EXISTING admission seams (APPROVALSCAN §loop) ----
    # The admission coroutine that owns a run records its event loop BEFORE the
    # worker starts. Capture (worker thread) never calls get_running_loop and
    # never captures with loop=None: session turns already have their loop in
    # the approval_queues mirror; runs/OpenAI turns bind here.
    def bind_loop(adapter, run_id):
        with inbox["lock"]:
            loops[(id(adapter), run_id)] = asyncio.get_running_loop()
            while len(loops) > INBOX_LOOPS_CAP:
                dead = [k for k, lp in loops.items() if lp.is_closed()]
                for k in dead:
                    loops.pop(k, None)
                while len(loops) > INBOX_LOOPS_CAP:
                    loops.pop(next(iter(loops)))  # oldest admission first

    def unbind_loop(adapter, run_id):
        with inbox["lock"]:
            loops.pop((id(adapter), run_id), None)

    old_agent = cls._run_agent

    @wraps(old_agent)
    async def agent(self, *args, **kwargs):
        try:
            # Session stream and OpenAI chat streaming both hand their approval
            # callback through this admission; sync/unattended callers pass no
            # callback and bind nothing (there is no answerable run).
            if kwargs.get("approval_notify_callback") is not None:
                owned = kwargs.get("approval_session_key") or kwargs.get("active_run_id")
                if owned:
                    bind_loop(self, owned)
        except Exception as exc:
            log.info("approval loop bind skipped: stage=run-agent error=%s",
                     type(exc).__name__)
        return await old_agent(self, *args, **kwargs)
    tx.set(cls, "_run_agent", agent)

    old_exec = runs._execute_run

    @wraps(old_exec)
    async def execute(self, launch, **kwargs):
        try:
            bind_loop(self, launch.run_id)
        except Exception as exc:
            log.info("approval loop bind skipped: stage=run-executor error=%s",
                     type(exc).__name__)
        return await old_exec(self, launch, **kwargs)
    tx.set(runs, "_execute_run", execute)

    # -- THE capture cut: native waiting_for_approval writes (APPROVALSCAN) ----
    def capture_status(self, run_id, event):
        # The status event is only the API envelope: it supplies the exact
        # request_id; capture() reads the native flags/pattern keys from the
        # core entry's own data and verifies the entry is STILL pending there.
        # The native status write above already happened and is never altered.
        request_id = event.get("request_id") if isinstance(event, dict) else None
        if not isinstance(request_id, str) or not request_id:
            return
        if not self._run_approval_sessions.get(run_id):
            # No exact _run_approval_sessions key: no answering authority, so
            # this is not ours to track (turn already retired its mapping).
            approval_inbox._metric(inbox, "capture_key_unbound")
            return
        mirror = state.get("approval_queues", {}).get((id(self), run_id))
        loop = getattr(mirror, "loop", None) if mirror is not None else None
        if loop is None:
            loop = loops.get((id(self), run_id))
        if loop is None:
            # Fail closed and LOUD, never loop=None: a worker-thread capture
            # without an owner loop would write loop-owned queues directly.
            approval_inbox._metric(inbox, "loop_unbound")
            log.info("approval capture skipped: stage=loop run_id=%s request_id=%s",
                     run_id, request_id)
            return
        session_id = (getattr(mirror, "session_id", None) if mirror is not None
                      else (self._run_statuses.get(run_id) or {}).get("session_id"))
        entry = approval_inbox.capture(inbox, adapter=self, run_id=run_id,
                                       session_id=session_id, loop=loop,
                                       request_id=request_id)
        if entry is not None:
            try:  # additive enrichment belongs on the loop that serialises
                loop.call_soon_threadsafe(
                    approval_inbox.enrich_event, inbox, self, run_id, request_id)
            except RuntimeError:
                pass

    # -- GET /v1/runs/{run_id}/approvals (read-only, owner/approve scoped) -----
    endpoint = ("run_approvals", ("GET", "/v1/runs/{run_id}/approvals"))
    for name, route in api._CAPABILITY_ENDPOINTS:
        if (name == endpoint[0] or route == endpoint[1]) and (name, route) != endpoint:
            raise RuntimeError("approval_inbox capability collision")
    old_table = cls._http_route_table

    @wraps(old_table)
    def routes(self):
        rows = list(old_table(self))
        if not any((m, p) == endpoint[1] for m, p, _ in rows):
            rows.append(endpoint[1] + (self._handle_run_approvals,))
        return rows

    async def approvals(self, request):
        if not enabled(inbox):
            return api._error_response("Cross-device approval inbox is disabled.", 404,
                                       code="approval_inbox_disabled")
        _run_id, status, _agent, _task, err = runs._load_owned_run(
            self, request, _api_server=sys.modules["gateway.platforms.api_server"],
            permission="approve", active_fallback=True)
        if err is not None:
            return err
        run_id = request.match_info["run_id"]
        session_key = self._run_approval_sessions.get(run_id) or run_id
        try:
            live = await asyncio.to_thread(approval.list_gateway_approvals, session_key)
        except Exception:
            return api._error_response("Approval queue unavailable.", 503,
                                       code="approval_queue_unavailable")
        pending, available, overflow, revision = approval_inbox.snapshot(
            inbox, adapter=self, run_id=run_id, live=live)
        bucket = inbox["by_run"].get((id(self), run_id))
        return api.web.json_response({
            "object": "hermes.run.approvals", "schema_version": 1,
            "run_id": run_id, "session_id": (status or {}).get("session_id")
            or (bucket or {}).get("session_id"),
            "server_epoch": inbox["epoch"], "observed_at": time.time(),
            "revision": revision, "pending": pending, "available": available,
            "overflow": overflow}, headers={"Cache-Control": "no-store"})

    # -- POST /v1/runs/{id}/approval: exact-submit contract -------------------
    old_post = runs._handle_run_approval

    async def post(self, request, **kwargs):
        _api = kwargs.get("_api_server") or sys.modules["gateway.platforms.api_server"]
        if not enabled(inbox):
            return await old_post(self, request, _api_server=_api)
        run_id = request.match_info["run_id"]
        _r, _s, _a, _t, err = runs._load_owned_run(
            self, request, _api_server=_api, permission="approve", active_fallback=False)
        if err is not None:
            return err
        try:
            body = json.loads(await request.text())
            if not isinstance(body, dict):
                raise ValueError("body is not an object")
        except Exception:
            return await old_post(self, request, _api_server=_api)  # original 400
        verdict = approval_inbox.classify_answer(inbox, adapter=self, run_id=run_id,
                                                 body=body, epoch=None)
        if verdict["action"] == "error":
            return api._error_response(verdict["message"], verdict["status"],
                                       code=verdict["code"])
        if verdict["action"] == "submit" and verdict.get("backfilled"):
            patched = json.dumps({**body, "request_id": verdict["request_id"]}).encode()
            try:  # legacy single-pending: EXACT id into the original request
                request._read_bytes = patched
                request._read_text = None
            except Exception:
                return api._error_response(  # never fall back to FIFO after the lock
                    "Submit the exact request_id.", 409, code="approval_request_required")
        return await old_post(self, request, _api_server=_api)

    # -- approval.responded settles the exact entry; restore remaining waiting --
    old_event = runs._mark_run_event

    @wraps(old_event)
    def event(self, run_id, name, **fields):
        result = old_event(self, run_id, name, **fields)
        try:
            if enabled(inbox) and name == "approval.responded":
                earliest = approval_inbox.after_responded(
                    inbox, self, run_id, fields.get("request_id"), fields.get("choice"))
                if earliest is not None:
                    # Still pending: the single status.approval slot shows the
                    # EARLIEST live request again (never a stale/other entry).
                    restored = approval_inbox.rebuild_event(inbox, self, earliest)
                    self._set_run_status(run_id, "waiting_for_approval",
                                         last_event="approval.request", approval=restored)
                    mirror = state.get("approval_queues", {}).get((id(self), run_id))
                    if mirror is not None:
                        mirror.enqueue("approval.request", dict(restored))
                    queue = getattr(self, "_run_streams", {}).get(run_id)
                    if queue is not None:
                        with suppress(Exception):
                            queue.put_nowait(restored)
        except Exception as exc:
            log.debug("inbox respond reconcile skipped: %s", type(exc).__name__)
        return result

    # -- the single entrance: pending capture + terminal settle -----------------
    # The capability is re-checked on EVERY invocation (never captured into a
    # closure at callback-creation time): flipping the kill switch silences in
    # flight callbacks immediately, while the native status write above always
    # keeps its original meaning and ordering.
    old_set = cls._set_run_status

    @wraps(old_set)
    def set_status(self, run_id, status, **fields):
        result = old_set(self, run_id, status, **fields)
        if not enabled(inbox):
            return result
        if status == "waiting_for_approval":
            try:
                capture_status(self, run_id, fields.get("approval"))
            except Exception as exc:
                approval_inbox._metric(inbox, "capture_error")
                log.info("approval capture failed: stage=status run_id=%s error=%s",
                         run_id, type(exc).__name__)
        elif status in ACTIVITY_TERMINAL:
            try:
                unbind_loop(self, run_id)
                approval_inbox.settle_run(inbox, self, run_id, "run-" + status)
            except Exception as exc:
                log.info("approval terminal settle skipped: stage=settle run_id=%s error=%s",
                         run_id, type(exc).__name__)
        return result

    tx.set(cls, "_handle_run_approvals", approvals)
    tx.set(cls, "_http_route_table", routes)
    tx.set(runs, "_handle_run_approval", post)
    tx.set(runs, "_mark_run_event", event)
    tx.set(cls, "_set_run_status", set_status)
    tx.set(api, "_CAPABILITY_ENDPOINTS", (*api._CAPABILITY_ENDPOINTS, endpoint))

    # -- capabilities advertisement: the App only offers cross-device approval
    # when this contract is actually live (R1 capability gate) ---------------
    old_caps = cls._handle_capabilities

    @wraps(old_caps)
    async def capabilities(self, request, **kwargs):
        response = await old_caps(self, request, **kwargs)
        try:
            payload = json.loads(response.body)
            payload["features"]["approval_inbox"] = {
                "enabled": enabled(inbox), "contract_version": 1,
                "pending_endpoint": "/v1/runs/{run_id}/approvals",
                "precise_responses": True,
                "server_epoch": inbox["epoch"],
            }
            return api.web.json_response(payload, status=response.status)
        except Exception as exc:
            log.warning("capabilities approval_inbox advertisement failed: %s",
                        type(exc).__name__)
            return response
    tx.set(cls, "_handle_capabilities", capabilities)


# STEERWEB (B1+): the run-scoped durable steer inbox. Five hooks must ALL be
# live before the capability may claim enabled: admission (POST steer route),
# agent/run binding (live adapters' _active_run_agents + _run_owners guarded
# identity), the tool-boundary injection wrapper, the persist-confirmation
# wrapper around _db_flush_write, and the terminal/stop seal on the single
# _set_run_status entrance. Anything failing raises: the transaction rolls
# back atomically and the manifest shows skipped_incompatible — never a
# half-installed route set (R1).
STEER_TARGET_FINGERPRINTS = {
    "_finalize_tool_batch": "1ff9e103f00368bdf9022f1838af036a19bb0db6684867cfe91b3cd27c779590",
    "_db_flush_write": "54b346ff56fc7c950e0a74af0fcf3181c178d2b234a694601fa3f9b5d765728c",
    "apply_pending_steer_to_tool_results":
        "082070fe6d4056f3d1d69becfec796fbd4aeaf309769cfa32592ed7cc4457f29",
}
STEER_BODY_CAP = 64 * 1024
STEER_INPUT_CAP = 8 * 1024


def _steer_fingerprint(module, name):
    if _BACKEND != "target":
        raise RuntimeError("steer_inbox backend not reviewed for this source")
    actual = hashlib.sha256(
        inspect.getsource(inspect.unwrap(getattr(module, name))).encode()).hexdigest()
    if actual != STEER_TARGET_FINGERPRINTS[name]:
        raise RuntimeError(f"steer source changed: {name}")


def _steer_config_enabled() -> bool:
    # Profile-aware config.yaml read (degraded raw path, same discipline as
    # _push_raw_settings): app_compat.steer_inbox.enabled, default FALSE.
    try:
        from hermes_cli.config import get_config_path
        from utils import fast_safe_load
        with open(get_config_path(), encoding="utf-8-sig") as handle:
            raw = fast_safe_load(handle)
        compat_block = raw.get("app_compat") if isinstance(raw, dict) else None
        block = compat_block.get("steer_inbox") if isinstance(compat_block, dict) else None
        return bool(block.get("enabled")) if isinstance(block, dict) else False
    except Exception:
        return False


def _install_steer_inbox(tx):
    import sys
    from . import steer_inbox, steer_store
    from gateway.platforms import api_server_runs as runs
    cls = api.APIServerAdapter
    if _BACKEND != "target":
        raise RuntimeError("steer_inbox backend not implemented for this source")
    state = getattr(api, _STATE, None)
    if state is None:
        raise RuntimeError("compat state missing")
    if state["groups"].get("activity") is None or \
            state["manifest"].get("activity", {}).get("status") != "applied":
        raise RuntimeError("activity unit not applied")
    if not state.get("activity_epoch"):
        raise RuntimeError("activity epoch missing")
    _require(cls, "_set_run_status", "_http_route_table", "_handle_capabilities",
             "_run_idempotency_scope")
    _require(runs, "_handle_steer_run", "_load_owned_run")
    _signature(cls, "_set_run_status", "self", "run_id", "status")
    _signature(runs, "_handle_steer_run", "self", "request", "_api_server")
    _signature(runs, "_load_owned_run", "self", "request", "_api_server", "permission",
               "active_fallback")
    # -- hooks 3+4 source gates: the boundary call site, the native injector,
    # and the flush writer must be the reviewed revisions.
    from agent import agent_runtime_helpers, session_persistence, tool_executor
    _steer_fingerprint(tool_executor, "_finalize_tool_batch")
    _steer_fingerprint(session_persistence, "_db_flush_write")
    _steer_fingerprint(agent_runtime_helpers, "apply_pending_steer_to_tool_results")
    import run_agent as run_agent_module
    boundary_binding = inspect.getattr_static(
        run_agent_module.AIAgent, "_apply_pending_steer_to_tool_results")
    if not callable(boundary_binding):
        raise RuntimeError("steer boundary binding missing")

    inbox = steer_inbox.open_inbox(state)
    steer_inbox.set_capability(_steer_config_enabled())
    tx.cleanups.append(lambda: steer_inbox.set_capability(False))

    def close_all():
        steer_inbox.set_capability(False)
        with suppress(Exception):
            steer_store.close_all()
    tx.cleanups.append(close_all)

    enabled = steer_inbox.capability_enabled

    # -- restart recovery: exact-metadata reconcile for staged batches; NEVER
    # replays anything into a new run (R3 item 7).
    try:
        steer_inbox.recover(inbox)
    except Exception as exc:
        log.warning("steer inbox recovery skipped: %s", type(exc).__name__)

    # -- hook 3: tool-boundary injection AFTER the native apply (never into
    # native _pending_steer, never before a completed tool batch).
    def boundary(self, messages, num_tool_msgs):
        result = boundary_binding(self, messages, num_tool_msgs)
        try:
            steer_inbox.on_tool_boundary(inbox, self, messages, num_tool_msgs)
        except Exception as exc:
            log.debug("steer boundary injection skipped: %s", type(exc).__name__)
        return result
    tx.set(run_agent_module.AIAgent, "_apply_pending_steer_to_tool_results", boundary)

    # -- hook 4: persist confirmation from the committed rows' exact metadata.
    old_flush = session_persistence._db_flush_write

    @wraps(old_flush)
    def flush(agent, batch_rows, batch_msgs, messages):
        old_flush(agent, batch_rows, batch_msgs, messages)
        try:
            steer_inbox.confirm_flushed_rows(inbox, batch_rows)
        except Exception as exc:
            log.debug("steer persist confirmation skipped: %s", type(exc).__name__)
    tx.set(session_persistence, "_db_flush_write", flush)

    # -- hook 5 + adapter discovery + accepting transition on the single
    # status entrance: stop/terminal seal the same run guard admission uses.
    old_set = cls._set_run_status

    @wraps(old_set)
    def set_status(self, run_id, status, **fields):
        result = old_set(self, run_id, status, **fields)
        try:
            steer_inbox.note_adapter(inbox, self)
            if status == "stopping" or status in ACTIVITY_TERMINAL:
                steer_inbox.seal(inbox, self, run_id, "run_" + str(status))
            steer_inbox.observe_status(inbox, self, run_id, status)
        except Exception as exc:
            log.debug("steer status seal skipped: %s", type(exc).__name__)
        return result
    tx.set(cls, "_set_run_status", set_status)

    # -- hook 1: admission replaces the legacy POST steer while enabled.
    old_post = runs._handle_steer_run

    async def steer(self, request, **kwargs):
        _api = kwargs.get("_api_server") or sys.modules["gateway.platforms.api_server"]
        if not enabled():
            # 01412 M10 / PLAN:49: the runtime kill switch REFUSES new
            # admission — it never reopens the native memory-only buffer
            # (that would silently break durability, ordering and identity).
            # Existing receipts stay readable; only a full uninstall puts
            # the native POST back.
            return api._error_response(
                "Cross-device steer is disabled on this server; existing "
                "receipts remain readable.", 503, code="steer_disabled")
        run_id = request.match_info["run_id"]
        _r, status, agent, _task, err = runs._load_owned_run(
            self, request, _api_server=_api, permission=None, active_fallback=False)
        if err is not None:
            return err
        # Body limits BEFORE parsing; auth/owner already answered above.
        try:
            declared = int(request.headers.get("Content-Length") or 0)
        except ValueError:
            declared = STEER_BODY_CAP + 1
        if declared > STEER_BODY_CAP:
            return api._error_response("Steer body too large.", 413, code="steer_body_too_large")
        raw = await request.read()
        if len(raw) > STEER_BODY_CAP:
            return api._error_response("Steer body too large.", 413, code="steer_body_too_large")
        if not raw:
            return await old_post(self, request, _api_server=_api)  # original empty-body 400
        try:
            body = json.loads(raw)
        except Exception:
            return await old_post(self, request, _api_server=_api)
        if not isinstance(body, dict):
            return await old_post(self, request, _api_server=_api)
        text = next((body.get(k) for k in ("input", "message", "text")
                     if isinstance(body.get(k), str)), None)
        if text is None or not text.strip() or len(text.strip().encode("utf-8")) > STEER_INPUT_CAP:
            return api._error_response("Steer input must be a non-empty string of at most "
                                       "8 KiB UTF-8.", 400, code="invalid_steer_input")
        client_request_id = body.get("client_request_id")
        if client_request_id is not None:
            client_request_id = str(client_request_id)
            if len(client_request_id) > 64:
                return api._error_response("client_request_id must be a UUID.", 400,
                                           code="invalid_client_request_id")
        else:
            # Legacy body: the server mints the id (retry idempotency is then
            # explicitly NOT promised to old clients). Still the SAME inbox —
            # never the native _pending_steer bypass while enabled.
            client_request_id = api.uuid.uuid4().hex
        session_id = body.get("session_id")
        server_epoch = body.get("server_epoch")
        # Re-read the live identity AFTER the body race (terminal/stop may
        # have happened during JSON read; the guard serializes with the
        # seal). 01412 M9: NO stale-agent fallback — an agent that unbound
        # during the body await is gone, and admit_request re-verifies the
        # live binding inside the guard anyway.
        live_status = getattr(self, "_run_statuses", {}).get(run_id) or status
        live_agent = getattr(self, "_active_run_agents", {}).get(run_id)
        if live_status is None and live_agent is not None:
            live_status = {"status": "running"}
        run_sid = str((live_status or {}).get("session_id") or "")
        if isinstance(session_id, str) and session_id and run_sid and \
                session_id != run_sid:
            return api._error_response("The steer targeted a different session.", 409,
                                       code="steer_stale_target")
        if isinstance(server_epoch, str) and server_epoch and server_epoch != inbox["epoch"]:
            return api._error_response("Server epoch changed; re-resolve the run.", 409,
                                       code="steer_epoch_stale")
        try:
            owner_scope = self._run_idempotency_scope(request)
        except Exception:
            return api._error_response("Run ownership unresolved.", 403,
                                       code="gateway_auth_failed")
        steer_inbox.bind_agent(inbox, self, run_id, live_agent)
        verdict, payload = await asyncio.to_thread(
            steer_inbox.admit_request, inbox, self, run_id=run_id,
            owner_scope=owner_scope, status=live_status, agent=live_agent,
            session_id=session_id or run_sid or None,
            input_text=text.strip(), client_request_id=client_request_id,
            server_epoch=server_epoch if isinstance(server_epoch, str) else None)
        if verdict == "accepted" or verdict == "duplicate":
            payload.setdefault("accepted", True)
            payload.setdefault("run_id", run_id)
            return api.web.json_response(payload, headers={"Cache-Control": "no-store"})
        codes = {"conflict": (409, "steer_identity_conflict",
                              "This steer id was used for different content."),
                 "not_ready": (409, "run_not_ready",
                               "The run is not ready to accept a steer yet."),
                 "closed": (409, "run_closed", "The run no longer accepts steers."),
                 "stale": (409, "steer_stale_target", "Re-resolve the run before steering."),
                 "queue_full": (429, "steer_queue_full", "Too many steers are pending."),
                 "expired": (410, "steer_expired", "The steer receipt has expired.")}
        status_code, code, message = codes.get(verdict, (409, "run_closed", "Refused."))
        return api._error_response(message, status_code, code=code)

    # -- R2 read surfaces: the receipt ledger answers even after run/status
    # TTL expiry (still owner-checked), which is what lets a rollback stay
    # read-only.
    list_endpoint = ("run_steers", ("GET", "/v1/runs/{run_id}/steers"))
    receipt_endpoint = ("run_steer_receipt", ("GET", "/v1/runs/{run_id}/steers/{steer_id}"))
    for name, route in api._CAPABILITY_ENDPOINTS:
        if (name, route) not in (list_endpoint, receipt_endpoint) and \
                (name in ("run_steers", "run_steer_receipt") or
                 route in (list_endpoint[1], receipt_endpoint[1])):
            raise RuntimeError("steer_inbox capability collision")
    old_table = cls._http_route_table

    @wraps(old_table)
    def routes(self):
        rows = list(old_table(self))
        for method, path, handler in ((list_endpoint[1] + (self._handle_run_steers,),
                                       receipt_endpoint[1] + (self._handle_run_steer_receipt,))):
            if not any((m, p) == (method, path) for m, p, _ in rows):
                rows.append((method, path, handler))
        return rows

    async def _owned(self, request):
        # 01412 M7: NO active_fallback here — an expired pollable status is
        # answered from the durable sidecar as expired, never resurrected to
        # "running" on the read surfaces.
        _api = sys.modules["gateway.platforms.api_server"]
        _r, status, _agent, _task, err = runs._load_owned_run(
            self, request, _api_server=_api, permission=None,
            active_fallback=False)
        return status, err

    async def steers_get(self, request):
        try:
            owner_scope = self._run_idempotency_scope(request)
        except Exception:
            return api._error_response("Run ownership unresolved.", 403,
                                       code="gateway_auth_failed")
        if owner_scope is None:
            return api._error_response("Run ownership unresolved.", 403,
                                       code="gateway_auth_failed")
        run_id = request.match_info["run_id"]
        status, err = await _owned(self, request)
        if err is not None:
            # 01412 M7: a native 404 (run transport/TTL expiry) falls back to
            # the DURABLE sidecar owner — receipts answer after the run is
            # gone, still owner-checked. Auth refusals never fall back.
            gone = getattr(err, "status", None) == 404 or (
                isinstance(err, dict) and err.get("http") == 404)
            if not (gone and steer_inbox.durable_run(
                    inbox, owner_scope=owner_scope, run_id=run_id)):
                return err
            status = None
        after = request.query.get("after_seq", "0")
        try:
            after = int(after)
        except ValueError:
            return api._error_response("after_seq must be an integer.", 400,
                                       code="invalid_cursor")
        if after < 0:
            return api._error_response("after_seq must not be negative.", 400,
                                       code="invalid_cursor")
        payload = await asyncio.to_thread(
            steer_inbox.listing, inbox, self, run_id=run_id,
            owner_scope=owner_scope, status=status, after_seq=after)
        return api.web.json_response(payload, headers={"Cache-Control": "no-store"})

    async def receipt_get(self, request):
        try:
            owner_scope = self._run_idempotency_scope(request)
        except Exception:
            return api._error_response("Run ownership unresolved.", 403,
                                       code="gateway_auth_failed")
        if owner_scope is None:
            return api._error_response("Run ownership unresolved.", 403,
                                       code="gateway_auth_failed")
        run_id = request.match_info["run_id"]
        status, err = await _owned(self, request)
        if err is not None:
            gone = getattr(err, "status", None) == 404 or (
                isinstance(err, dict) and err.get("http") == 404)
            if not (gone and steer_inbox.durable_run(
                    inbox, owner_scope=owner_scope, run_id=run_id)):
                return err
        steer_id = request.match_info["steer_id"]
        payload = await asyncio.to_thread(
            steer_inbox.receipt, inbox, owner_scope=owner_scope, run_id=run_id,
            steer_id=steer_id)
        if payload is None:
            return api._error_response("Steer receipt not found.", 404,
                                       code="steer_receipt_not_found")
        return api.web.json_response(payload, headers={"Cache-Control": "no-store"})

    tx.set(cls, "_handle_run_steers", steers_get)
    tx.set(cls, "_handle_run_steer_receipt", receipt_get)
    tx.set(cls, "_http_route_table", routes)
    tx.set(runs, "_handle_steer_run", steer)
    tx.set(api, "_CAPABILITY_ENDPOINTS",
           (*api._CAPABILITY_ENDPOINTS, list_endpoint, receipt_endpoint))

    # -- R1 advertisement: the App only offers cross-device steer when the
    # WHOLE contract is live (fail-closed; enabled follows the kill switch).
    old_caps = cls._handle_capabilities

    @wraps(old_caps)
    async def capabilities(self, request, **kwargs):
        response = await old_caps(self, request, **kwargs)
        try:
            payload = json.loads(response.body)
            payload["features"]["steer_inbox"] = {
                "enabled": enabled(), "contract_version": 1,
                "server_epoch": inbox["epoch"], "run_bound": True,
                "idempotent": True, "receipt_endpoint": "/v1/runs/{run_id}/steers",
            }
            return api.web.json_response(payload, status=response.status)
        except Exception as exc:
            log.warning("capabilities steer_inbox advertisement failed: %s",
                        type(exc).__name__)
            return response
    tx.set(cls, "_handle_capabilities", capabilities)

    # -- R6 projection: ONLY server-written steer blocks become a typed
    # steer_provenance on the messages projection; the rest of display_metadata
    # never leaves the process (same whitelist discipline as cron_provenance).
    descriptor = inspect.getattr_static(cls, "_message_response")
    if not isinstance(descriptor, staticmethod):
        raise RuntimeError("steer projection needs the static _message_response")
    old_message = descriptor.__func__

    @wraps(old_message)
    def message(row):
        result = old_message(row)
        try:
            meta = (row or {}).get("display_metadata")
            if isinstance(meta, str):
                meta = json.loads(meta)
            block = (meta.get("hermes_app_steer") if isinstance(meta, dict) else None)
            if (isinstance(block, dict)
                    and int(block.get("schema") or 0) == 1
                    and (row or {}).get("role") == "user"
                    and (row or {}).get("display_kind") == "steer"
                    and isinstance(block.get("batch_id"), str)):
                items = []
                for item in list(block.get("items") or ())[:64]:
                    if (isinstance(item, dict) and isinstance(item.get("steer_id"), str)
                            and isinstance(item.get("input"), str)
                            and isinstance(item.get("sequence"), int)):
                        items.append({"steer_id": item["steer_id"][:64],
                                      "sequence": int(item["sequence"]),
                                      "input": item["input"][:8192]})
                if items:
                    result = {**result, "steer_provenance": {
                        "schema": 1,
                        "run_id": str(block.get("run_id") or "")[:64],
                        "batch_id": block["batch_id"][:64], "items": items}}
        except Exception:
            pass
        return result
    tx.set(cls, "_message_response", staticmethod(message))


# STEERWEB (B4): the notification events ledger. One more entrance on the SAME
# single _set_run_status cut (terminal kinds), plus the approval dispatcher's
# gate and the steer.ready hook. Capability is read from profile config at
# install and re-checked on EVERY gate call; with the ledger off the old push
# policy is byte-for-byte intact (R6/R10).
def _notification_config_enabled() -> bool:
    try:
        from hermes_cli.config import get_config_path
        from utils import fast_safe_load
        with open(get_config_path(), encoding="utf-8-sig") as handle:
            raw = fast_safe_load(handle)
        compat_block = raw.get("app_compat") if isinstance(raw, dict) else None
        block = compat_block.get("notification_events") if isinstance(compat_block, dict) else None
        return bool(block.get("enabled")) if isinstance(block, dict) else False
    except Exception:
        return False


_NOTIFICATION_HANDLERS = {
    "notification_events": "_handle_notification_events",
    "notification_read": "_handle_notification_reads",
    "notification_claim": "_handle_notification_claim",
    "notification_delivery": "_handle_notification_delivery",
    "notification_watch": "_handle_notification_watch",
}


def _install_notification_events(tx):
    from . import notification_events, notification_store
    from gateway.platforms import api_server_runs as runs
    cls = api.APIServerAdapter
    if _BACKEND != "target":
        raise RuntimeError("notification_events backend not implemented for this source")
    state = getattr(api, _STATE, None)
    if state is None:
        raise RuntimeError("compat state missing")
    if state["manifest"].get("push", {}).get("status") != "applied":
        raise RuntimeError("push unit not applied (it is the transport being routed)")
    _require(cls, "_set_run_status", "_http_route_table", "_handle_capabilities",
             "_run_idempotency_scope")
    _require(runs, "_load_owned_run")
    _signature(cls, "_set_run_status", "self", "run_id", "status")

    reg = notification_events.open_ledger(state, settings=lambda: (_push_settings() or None))
    notification_events.set_capability(_notification_config_enabled())
    tx.cleanups.append(lambda: notification_events.set_capability(False))

    def close_all():
        notification_events.set_capability(False)
        with suppress(Exception):
            notification_store.close_all()
    tx.cleanups.append(close_all)

    enabled = notification_events.capability_enabled

    inbox = state.get("approval_inbox")
    if inbox is not None:
        inbox["notify_gate"] = notification_events.approval_initial_hook(reg)
        tx.cleanups.append(lambda: inbox.pop("notify_gate", None))
    steer_state = state.get("steer_inbox")
    if steer_state is not None:
        def ready_hook(adapter, run_id):
            if not enabled():
                return
            notification_events.steer_ready(
                reg,
                owner_scope=(getattr(adapter, "_run_owners", {}) or {}).get(run_id) or "",
                run_id=run_id,
                sid=(getattr(adapter, "_run_statuses", {}).get(run_id) or {}).get("session_id"))
        steer_state["ready_hook"] = ready_hook
        tx.cleanups.append(lambda: steer_state.__setitem__("ready_hook", None))

    old_set = cls._set_run_status

    @wraps(old_set)
    def set_status(self, run_id, status, **fields):
        result = old_set(self, run_id, status, **fields)
        if not enabled():
            return result
        try:
            if status in ACTIVITY_TERMINAL:
                status_row = getattr(self, "_run_statuses", {}).get(run_id) or {}
                notification_events.terminal_event(
                    reg,
                    owner_scope=(getattr(self, "_run_owners", {}) or {}).get(run_id) or "",
                    run_id=run_id, sid=status_row.get("session_id"), status=status,
                    summary=fields.get("output") or fields.get("error") or "")
        except Exception as exc:
            log.debug("notification terminal event skipped: %s", type(exc).__name__)
        return result
    tx.set(cls, "_set_run_status", set_status)

    endpoints = (
        ("notification_events", ("GET", "/api/notification-events")),
        ("notification_read", ("POST", "/api/notification-events/{event_id}/read")),
        ("notification_claim", ("POST", "/api/notification-events/{event_id}/claim")),
        ("notification_delivery", ("POST", "/api/notification-events/{event_id}/delivery")),
        ("notification_watch", ("POST", "/api/notification-events/steer-ready-watch")),
    )
    for name, route in api._CAPABILITY_ENDPOINTS:
        for ours_name, ours_route in endpoints:
            if (name == ours_name or route == ours_route) and (name, route) != (ours_name, ours_route):
                raise RuntimeError("notification_events capability collision")
    old_table = cls._http_route_table

    @wraps(old_table)
    def routes(self):
        rows = list(old_table(self))
        for name, (method, path) in endpoints:
            if not any((m, p) == (method, path) for m, p, _ in rows):
                rows.append((method, path, getattr(self, _NOTIFICATION_HANDLERS[name])))
        return rows

    def _owner(self, request):
        try:
            return self._run_idempotency_scope(request)
        except Exception:
            return None

    async def events_get(self, request):
        if not enabled():
            return api._error_response("Notification events are disabled.", 404,
                                       code="notification_events_disabled")
        scope = _owner(self, request)
        if scope is None:
            return api._error_response("Ownership unresolved.", 403, code="gateway_auth_failed")
        try:
            after = int(request.query.get("after", "0"))
        except ValueError:
            return api._error_response("after must be an integer.", 400, code="invalid_cursor")
        items, overflow, next_cursor = await asyncio.to_thread(
            notification_store.events_after, notification_events.home_of(reg),
            scope, max(after, 0))
        head = await asyncio.to_thread(notification_store.head_seq,
                                       notification_events.home_of(reg))
        return api.web.json_response({
            "object": "list", "schema_version": 1,
            "server_channel": notification_events.system_channel(reg),
            "head_seq": head, "next_cursor": next_cursor, "overflow": overflow, "data": [
                {k: item.get(k) for k in ("event_id", "run_id", "sid", "kind", "source_id",
                                          "created_seq", "payload", "created_at",
                                          "read_at", "read_by")} for item in items],
        }, headers={"Cache-Control": "no-store"})

    async def read_post(self, request):
        if not enabled():
            return api._error_response("Notification events are disabled.", 404,
                                       code="notification_events_disabled")
        scope = _owner(self, request)
        if scope is None:
            return api._error_response("Ownership unresolved.", 403, code="gateway_auth_failed")
        event_id = request.match_info["event_id"]
        result = await asyncio.to_thread(notification_store.mark_read,
                                         notification_events.home_of(reg), scope,
                                         event_id, "device")
        if result is None:
            return api._error_response("Event not found.", 404, code="event_not_found")
        return api.web.json_response(result)

    async def claim_post(self, request):
        if not enabled():
            return api._error_response("Notification events are disabled.", 404,
                                       code="notification_events_disabled")
        scope = _owner(self, request)
        if scope is None:
            return api._error_response("Ownership unresolved.", 403, code="gateway_auth_failed")
        try:
            body = await request.json()
        except Exception:
            body = {}
        event_id = request.match_info["event_id"]
        device_id = str(body.get("device_id") or "")[:64]
        delivery_id = str(body.get("delivery_id") or api.uuid.uuid4().hex)[:64]
        store = notification_events.home_of(reg)
        event = notification_store.get_event(store, scope, event_id)
        if event is None:
            return api._error_response("Event not found.", 404, code="event_not_found")
        # NOTIF2 B1: the browser surface is a PERMANENT parallel channel, not
        # a no-ntfy fallback — the system channel never refuses a claim.
        # This endpoint stays browser-only by construction (the channel is
        # fixed here); owner/event/read validation and the durable show
        # token are unchanged.
        if event.get("read_at"):
            return api._error_response("Event already read.", 409, code="already_read")
        token = api.uuid.uuid4().hex  # minted BEFORE the claim, persisted BY it
        verdict, assigned = notification_store.claim_delivery(
            store, event_id=event_id, phase="initial", channel="browser",
            delivery_id=delivery_id, device_id=device_id, show_token=token)
        return api.web.json_response({"verdict": verdict, "delivery_id": assigned,
                                      "show_token": token if verdict == "claimed"
                                      else None})

    async def delivery_post(self, request):
        if not enabled():
            return api._error_response("Notification events are disabled.", 404,
                                       code="notification_events_disabled")
        scope = _owner(self, request)
        if scope is None:
            return api._error_response("Ownership unresolved.", 403, code="gateway_auth_failed")
        try:
            body = await request.json()
        except Exception:
            body = {}
        outcome = str(body.get("outcome") or "")
        device_id = str(body.get("device_id") or "")[:64] or None
        show_token = str(body.get("show_token") or "")[:64] or None
        # 01412 M1: owner, event, claim owner and the durable token are ALL
        # verified in the SAME transaction that writes the outcome.
        state_now = await asyncio.to_thread(
            notification_store.note_delivery, notification_events.home_of(reg),
            delivery_id=str(body.get("delivery_id") or ""), outcome=outcome,
            channel="browser", event_id=request.match_info["event_id"],
            owner_scope=scope, device_id=device_id, show_token=show_token)
        if state_now is None:
            return api._error_response("Delivery not found.", 404, code="delivery_not_found")
        return api.web.json_response({"delivery": outcome or state_now})

    async def watch_post(self, request):
        if not enabled():
            return api._error_response("Notification events are disabled.", 404,
                                       code="notification_events_disabled")
        scope = _owner(self, request)
        if scope is None:
            return api._error_response("Ownership unresolved.", 403, code="gateway_auth_failed")
        try:
            body = await request.json()
        except Exception:
            body = {}
        run_id = str(body.get("run_id") or "")[:64]
        on = bool(body.get("watch"))
        notification_events.watch(reg, owner_scope=scope, run_id=run_id, on=on)
        return api.web.json_response({"watched": on, "run_id": run_id})

    tx.set(cls, "_handle_notification_events", events_get)
    tx.set(cls, "_handle_notification_reads", read_post)
    tx.set(cls, "_handle_notification_claim", claim_post)
    tx.set(cls, "_handle_notification_delivery", delivery_post)
    tx.set(cls, "_handle_notification_watch", watch_post)
    tx.set(cls, "_http_route_table", routes)
    tx.set(api, "_CAPABILITY_ENDPOINTS",
           (*api._CAPABILITY_ENDPOINTS, *endpoints))

    old_caps = cls._handle_capabilities

    @wraps(old_caps)
    async def capabilities(self, request, **kwargs):
        response = await old_caps(self, request, **kwargs)
        try:
            payload = json.loads(response.body)
            payload["features"]["notification_events"] = {
                "enabled": enabled(), "contract_version": 1, "exact_ids": True,
                "system_channel": notification_events.system_channel(reg),
            }
            return api.web.json_response(payload, status=response.status)
        except Exception as exc:
            log.warning("notification_events advertisement failed: %s",
                        type(exc).__name__)
            return response
    tx.set(cls, "_handle_capabilities", capabilities)
