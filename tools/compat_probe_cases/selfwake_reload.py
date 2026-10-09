"""SELFWAKE2 (T1): a same-name force reload must restore the WORKER, not just routes.

Root cause (TASK/SELFWAKE2.md, CONFIRMED): upstream on_plugin_loaded fires only
for NEWLY loaded plugin keys. A same-name force reload therefore re-sweeps
routes through the install-time live-adapter scan and never runs the
notification-driven factory — routes replay while the selfwake worker stays
None. This family pins the repair contract with a fixture heartbeat tick on a
real connected adapter:

  * same-name reloads (executor thread AND in-loop) must resume sweep
    progress WITHOUT any manual factory call, rewire or arm;
  * the loaded-listener here is wired exactly like the gateway's
    run_plugin_rewire (marshal to the owning loop, then rewire) — nothing
    bypasses the loader notification contract;
  * the notification control (one extra empty plugin) proves the discovery
    fixture itself is healthy and recovery is not fixture luck;
  * an explicit adapter.rewire() is the positive control only;
  * a disconnected platform stays stopped (no silent resurrection);
  * re-arm from repeated paths never stacks workers (task identity stable).

Zero model turns, zero real dispatch: the worker tick is replaced with a
heartbeat that only writes audit rows into the case's isolated home.
"""
from __future__ import annotations
import asyncio
import json
import os
import time
from pathlib import Path
from types import MethodType


def _sw():
    from gateway.platforms import api_server as api
    return getattr(api, "_hermes_app_compat_state_v1")["selfwake"]["module"]


def _fixture_tick(sw):
    """Isolated heartbeat: replaces the sweep body for THIS module load only."""
    sw.SWEEP_INTERVAL_S = 0.02
    calls = sw._probe_tick_calls = getattr(sw, "_probe_tick_calls", [])

    async def tick(self):
        home = Path(os.environ["HERMES_HOME"])
        calls.append(len(calls))
        sw.audit(home, phase="probe-heartbeat", reason="lifecycle-only")

    sw.SelfWakeWorker.tick = tick


def _beats():
    import sqlite3
    home = Path(os.environ["HERMES_HOME"])
    path = home / "wake_ledger.db"
    if not path.exists():
        return 0
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        return conn.execute(
            "SELECT count(*) FROM selfwake_audit WHERE phase='probe-heartbeat'").fetchone()[0]
    except Exception:
        return 0
    finally:
        conn.close()


async def case_selfwake_reload(args, server, check):
    import logging
    from gateway.config import PlatformConfig
    from gateway.platforms import api_server as api
    from gateway.platforms.api_server import APIServerAdapter
    from hermes_cli.plugins import discover_plugins, get_plugin_manager

    logs = []

    class _Capture(logging.Handler):
        def emit(self, record):
            if record.name.startswith("hermes-app-compat"):
                logs.append(record.getMessage())

    handler = _Capture()
    logging.getLogger("hermes-app-compat").addHandler(handler)
    logging.getLogger("hermes-app-compat").setLevel(logging.INFO)
    home = Path(os.environ["HERMES_HOME"])
    manager = get_plugin_manager()
    sw = _sw()
    _fixture_tick(sw)
    state = getattr(api, "_hermes_app_compat_state_v1")
    stale_module, stale_generation = sw, state["selfwake"]["generation"]

    adapter = APIServerAdapter(PlatformConfig(enabled=True, extra={
        "key": "compat-probe-only-0123456789abcdef0123456789",
        "host": "127.0.0.1", "port": 0, "model_name": "compat-fixture"}))
    check(await adapter.connect(), "reload fixture: real adapter.connect succeeds")
    loaded_events = []
    owning_loop = asyncio.get_running_loop()

    def on_loaded(rows):  # gateway-faithful: record, then marshal the rewire
        loaded_events.append([r["key"] for r in rows])
        owning_loop.call_soon_threadsafe(adapter.rewire_plugin_handlers)

    unsubscribe = manager.on_plugin_loaded(on_loaded)
    try:
        await asyncio.sleep(0.1)
        units = {u: sorted(state["manifest"][u]) for u in ("cron_bridge", "selfwake")}
        worker = sw._module_state.get("worker")
        check(worker is not None and not worker._task.done(),
              f"cold connect armed the sweep worker (loop={sw._module_state.get('loop')} "
              f"lv={state['manifest']['selfwake'].get('liveness')} "
              f"route_sync={state['manifest']['selfwake'].get('route_sync')} "
              f"units={units} groups={sorted(state['groups'])} "
              f"wired={getattr(adapter, '_plugin_handlers_wired', 'n/a')} "
              f"factories={len(getattr(manager, '_platform_handler_factories', {}) or {})} "
              f"tail={logs[-3:]})")
        live0 = sw.liveness()
        check(live0["worker"] and live0["task_done"] is False and live0["loop"],
              f"module liveness reader agrees ({live0})")
        check(_beats() > 0, "initial sweep heartbeats flow before any reload")

        async def reload(variant):
            if variant == "executor":
                await asyncio.to_thread(discover_plugins, True)
            else:
                discover_plugins(force=True)

        async def same_name_reload(variant, note):
            nonlocal sw
            old = sw
            old_worker = old._module_state.get("worker")
            old_task = old_worker._task if old_worker is not None else None
            before = _beats()
            await reload(variant)
            await asyncio.sleep(0.03)  # let cancellation of the old task land
            sw = _sw()
            _fixture_tick(sw)
            check(sw is not old, f"{note}: force discovery swapped the compat module")
            check(old._module_state["worker"] is None,
                  f"{note}: unload cleared the old module worker")
            check(old_task is None or old_task.done(), f"{note}: the old sweep task terminated")
            await asyncio.sleep(0.12)
            mid = _beats()
            live = sw._module_state.get("worker")
            if live is not None and live._task is not None and not live._task.done():
                live.kick()
            await asyncio.sleep(0.05)
            after = _beats()
            check(live is not None and live._task is not None and not live._task.done(),
                  f"{note}: NEW module has a live sweep worker "
                  f"(after={after}, during={mid - before}, loaded={loaded_events})")
            check(after > mid,
                  f"{note}: sweep RESUMED without manual factory/rewire/arm "
                  f"(before={before}, during={mid - before}, after={after - mid})")
            lv = state["manifest"]["selfwake"].get("liveness", {})
            check(lv.get("state") == "armed" and lv.get("reason") in (
                    "install-live-adapters", "factory-replay"),
                  f"{note}: manifest liveness armed via install path ({lv})")
            return live

        # S1/S3: repeated same-name reloads across both discovery variants —
        # each must land a live worker with progress, purely from install.
        for variant, note in (("executor", "same-name executor reload #1"),
                              ("loop", "same-name in-loop reload #2"),
                              ("executor", "same-name executor reload #3")):
            await same_name_reload(variant, note)

        # Notification control: one extra empty plugin makes upstream fire a
        # loaded event; the rewire-driven factory path must ALSO keep the
        # sweep alive — and must not stack a second worker on top of the
        # install-scan re-arm.
        newcomer = home / "plugins" / "sw2-notification-control"
        newcomer.mkdir()
        (newcomer / "plugin.yaml").write_text("name: sw2-notification-control\nversion: 0.0.1\n")
        (newcomer / "__init__.py").write_text("def register(ctx): pass\n")
        cfg = json.loads((home / "config.yaml").read_text())
        cfg["plugins"]["enabled"].append("sw2-notification-control")
        (home / "config.yaml").write_text(json.dumps(cfg))
        before = _beats()
        await asyncio.to_thread(discover_plugins, True)
        sw = _sw()
        _fixture_tick(sw)
        await asyncio.sleep(0.12)
        check(any("sw2-notification-control" in keys for keys in loaded_events),
              "notification control: loaded event fired for the new plugin key")
        worker = sw._module_state.get("worker")
        check(worker is not None and worker._task is not None and not worker._task.done(),
              "notification path keeps a live sweep worker")
        task1 = worker._task
        sw.arm_loop(owning_loop, home)  # the S2 idempotency contract
        check(worker._task is task1 and not task1.done(),
              "arm_loop is idempotent: repeated scans+factories never stack workers")
        worker.kick()  # fixture wake: the reloaded module's first interval is
        # still the UNPATCHED 15s default (the arm beat our class patch)
        await asyncio.sleep(0.05)
        check(_beats() > before,
              "notification control path keeps the sweep alive: "
              f"beats={_beats()}-{before} worker_done={worker._task.done()} "
              f"tick_calls={len(getattr(sw, '_probe_tick_calls', []))} "
              f"liveness={getattr(api, '_hermes_app_compat_state_v1')['manifest']['selfwake'].get('liveness')} "
              f"tail={logs[-2:]}")

        # Positive control: the wiring can always recover when the rewire
        # actually runs — the gap is notification arrival, not the factory.
        adapter.rewire_plugin_handlers()
        await asyncio.sleep(0.08)
        check(_beats() > before, "explicit rewire control recovers (fixture is healthy)")

        # S3: an OLD generation's late-arriving callback must neither touch
        # the live worker nor restamp liveness (resurrection guard).
        import importlib
        compat_mod = importlib.import_module("hermes_plugins.hermes_app_compat.compat")
        current_worker = sw._module_state["worker"]
        compat_mod._selfwake_rearm(owning_loop, stale_module, stale_generation,
                                   "probe-stale-callback")
        await asyncio.sleep(0.05)
        lv = state["manifest"]["selfwake"]["liveness"]
        check(lv.get("state") == "skipped" and lv.get("reason") == "stale-load",
              f"stale-generation callback cannot restamp liveness ({lv})")
        check(sw._module_state["worker"] is current_worker and not current_worker._task.done(),
              "stale-generation callback cannot touch the live worker")
        # The truthful re-arm still reads armed afterwards:
        compat_mod._selfwake_rearm(owning_loop, sw, state["selfwake"]["generation"],
                                   "probe-resync")
        await asyncio.sleep(0.02)
        check(state["manifest"]["selfwake"]["liveness"].get("state") == "armed",
              "current-generation re-arm restamps armed after the stale one")

        # Explicit stop must STAY stopped: no heartbeat after arm_stop
        # (the platform-disconnect seam — the api adapter alone never arms
        # nor stops; the app platform owns that edge in production).
        stop_task = sw._module_state["worker"]._task
        sw.arm_stop()
        await asyncio.sleep(0.05)
        check(stop_task is not None and stop_task.done(),
              "platform disconnect stopped the sweep task")
        lv = state["manifest"]["selfwake"]["liveness"]
        check(lv.get("state") == "stopped" and sw.liveness()["loop"] is False,
              f"explicit stop is visible as liveness stopped ({lv})")
        mark = _beats()
        await asyncio.sleep(0.15)
        check(_beats() == mark, "explicitly stopped sweep does not resurrect")
    finally:
        logging.getLogger("hermes-app-compat").removeHandler(handler)
        try:
            unsubscribe()
        except Exception:
            pass
        try:
            current = _sw()
            task = (current._module_state.get("worker") or None)
            task = task._task if task is not None else None
            current.reset()
            if task is not None:
                await asyncio.gather(task, return_exceptions=True)
        except Exception:
            pass
        if getattr(adapter, "_site", None) is not None:
            try:
                await adapter.disconnect()
            except Exception:
                pass
        manager.unload()
