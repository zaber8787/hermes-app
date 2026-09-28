"""P5 cron bridge: app platform, identity seams, atomic writer, queued outcomes.

Real components only: plugin-loaded registry entry, cron resolver wrappers, the
reviewed SessionDB writer transaction, the HTTP messages handler, and a real
subprocess for the external-worker identity leg. Nothing talks to Discord or
any non-loopback endpoint (guard_network stays active).
"""
from __future__ import annotations
import asyncio
import concurrent.futures
import contextvars
import dataclasses
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time
from unittest.mock import patch

from .offline import AUTH


def bridge_ref():
    from gateway.platforms import api_server as api
    return getattr(api, "_hermes_app_compat_state_v1")["cron_bridge"]


def profile_db():
    from hermes_state import SessionDB
    return SessionDB(Path(os.environ["HERMES_HOME"]) / "state.db")


def set_lease(db, sid, holder, ttl=300.0):
    from gateway.config import Platform
    key = db._session_turn_lease_key(sid)
    with db._lock:
        db._conn.execute("DELETE FROM session_turn_leases")
        if holder is not None:
            db._conn.execute(
                "INSERT INTO session_turn_leases(conversation_id,holder,acquired_at,expires_at)"
                " VALUES(?,?,?,?)", (key, holder, time.time(), time.time() + ttl))
        db._conn.commit()


def spool_due(home):
    conn = sqlite3.connect(str(Path(home) / "cron_bridge.db"))
    conn.execute("UPDATE pending SET next_retry_at = 0")
    conn.commit()
    conn.close()


def make_target(sd, job, sid, **extra):
    from gateway.config import Platform, PlatformConfig
    return sd._TargetDelivery(
        job=job, platform=Platform("app"), platform_name="app", chat_id=sid, thread_id=None,
        transport=None, pconfig=PlatformConfig(enabled=True), runtime_adapter=None,
        target_adapters=None, config=None, loop=None, notify_delivery=True, origin={},
        origin_target=False, origin_user_id=None, is_dm_target=False, mirror_text="",
        mirror_this_target=False, in_channel_surface=False, inchannel_continuable=False,
        opened_thread_id=None, **extra)


async def case_cron_bridge(args, server, check):
    import cron.scheduler_delivery as sd
    import cron.scheduler as sched
    from gateway.platform_registry import platform_registry, PlatformEntry
    from gateway.config import PlatformConfig
    from gateway.platforms.base import BasePlatformAdapter
    from tools.send_message_targets import resolve_send_target
    from hermes_cli.plugins import get_plugin_manager, PluginContext
    home = Path(os.environ["HERMES_HOME"])
    refs = bridge_ref()
    store, app_platform = refs["store"], refs["app"]
    check(store.bindings_ready(), "atomic writer bindings installed")
    config = json.loads((home / "config.yaml").read_text())
    config["platforms"] = {"app": {"enabled": True}}
    (home / "config.yaml").write_text(json.dumps(config))

    # ---- A. registration + entry contract -------------------------------------
    entry = platform_registry.get("app")
    check(entry is not None and entry.source == "plugin"
          and entry.plugin_name == "hermes-app-compat", "app platform registered by this plugin")
    names = {f.name for f in dataclasses.fields(PlatformEntry)}
    check(len(names) >= 26 and {"cron_deliver_env_var", "parse_target_ref_fn",
          "validate_target_ref_fn", "standalone_sender_fn"} <= names,
          f"PlatformEntry contract ({len(names)} fields) carries our seams")
    check(entry.cron_deliver_env_var == "HERMES_APP_HOME_SESSION"
          and entry.max_message_length == 0 and entry.allow_update_command is False
          and entry.platform_hint == "" and entry.standalone_sender_fn is not None
          and entry.send_message_handler is None,
          "entry kwargs match the plan (env alias, no chunking, send-only, no hint)")
    manager = get_plugin_manager()
    manifest = next(p.manifest for p in manager._plugins.values()
                    if p.manifest.name == "hermes-app-compat")
    try:
        PluginContext(manifest, manager).register_platform(
            name="compat-probe-bogus", label="x", adapter_factory=lambda c: c,
            check_fn=lambda: True, totally_unknown_field=True)
        check(False, "unknown PlatformEntry kwarg must TypeError")
    except TypeError:
        check(True, "unknown PlatformEntry kwarg refused with TypeError")
    from cron.scheduler_delivery import _is_known_delivery_platform
    check(_is_known_delivery_platform("app"), "cron treats app as a known delivery platform")
    for good in ("api_1790450193_5fb8a6f5", "7c9e6679-7425-40de-944b-e07fc1f90ae7", "s1"):
        check(app_platform.parse_app_session_ref(good) == (good, None),
              f"parser accepts exact id {good}")
    for bad in ("", "a:b", "../etc", "http://h/x", "prof:sid", "sid x", "sid\n1",
                "sid/x", str(Path.cwd()), "x" * 300, "..", " sid", "sid%2F"):
        check(app_platform.parse_app_session_ref(bad) is None, f"parser rejects {bad!r}")
        check(isinstance(app_platform.validate_app_session_ref(bad), str),
              f"validator explains {bad!r}")
    sid_probe = "api_1790450193_5fb8a6f5"
    check(resolve_send_target("app", sid_probe) == (sid_probe, None, None),
          "resolver maps app:<sid> to (sid, no thread)")
    check(resolve_send_target("app", "bad:fmt")[2] is not None,
          "resolver refuses malformed app refs")

    # ---- B. resolver -> adapter -> DB -> HTTP -----------------------------------
    db = profile_db()
    sid = "api_cron_http1"
    db.create_session(sid, model="compat-fixture", source="api_server")
    job = {"id": "jobB", "name": "Alpha", "deliver": f"app:{sid}", "execution_id": "execB1",
           "attach_to_session": True}
    async with server() as (api_adapter, client):
        adapter = entry.adapter_factory(PlatformConfig(enabled=True))
        check(isinstance(adapter, BasePlatformAdapter) and adapter.supports_async_delivery,
              "factory returns a base-platform adapter declaring async delivery")
        check(await adapter.connect(), "app adapter connects (drainer armed)")
        before = db.get_session(sid)["message_count"]
        thread_id, route, media = sd._live_route_metadata(make_target(sd, job, sid))
        check(route.get("hermes_app_cron_identity") == {"job_id": "jobB",
              "execution_id": "execB1", "name": "Alpha"},
              "live app branch carries the namespaced delivery identity")
        other = make_target(sd, job, sid)
        other.platform_name = "discord"
        _, route2, _ = sd._live_route_metadata(other)
        check("hermes_app_cron_identity" not in route2, "non-app metadata untouched")
        result = await adapter.send(chat_id=sid, content="report B", metadata=route)
        check(result.success and result.message_id is not None, "adapter.send committed row")
        async with client.get(f"/api/sessions/{sid}/messages", headers=AUTH) as r:
            payload = await r.json()
            row = payload["data"][-1]
            check(r.status == 200 and row["role"] == "user"
                  and row.get("display_kind") == "internal_notification"
                  and row["content"] == "[Cron report: Alpha]\nreport B",
                  "messages HTTP reads the report with kind/id immediately after commit")
        check(db.get_session(sid)["message_count"] == before + 1, "message_count +1 exactly")
        again = await adapter.send(chat_id=sid, content="report B", metadata=route)
        check(again.success and again.message_id == result.message_id,
              "same execution retry returns the same row id (no second row, no recount)")
        check(db.get_session(sid)["message_count"] == before + 1, "retry did not re-count")
        job2 = dict(job, execution_id="execB2")
        _, route_b2, _ = sd._live_route_metadata(make_target(sd, job2, sid))
        second = await adapter.send(chat_id=sid, content="report B", metadata=route_b2)
        check(second.success and second.message_id != result.message_id,
              "new execution same text = distinct legitimate report")
        await adapter.disconnect()

    # ---- C. standalone lane identity across lanes ------------------------------
    sid_s = "api_cron_standalone1"
    db.create_session(sid_s, model="compat-fixture", source="api_server")
    job_s = {"id": "jobC", "name": "Cron", "deliver": f"app:{sid_s}", "execution_id": "execC1"}
    # Called from a RUNNING loop, so upstream's own copy_context->fresh-thread
    # fallback executes and must still carry the wrapper-set identity.
    sent, err = sd._standalone_send(make_target(sd, job_s, sid_s), "standalone report", [])
    check(err is None and sent.get("success") and sent.get("message_id"),
          f"standalone send committed via reviewed writer ({sent}, {err})")
    row_c = int(sent["message_id"])
    check(store.receipt_for(home, "execC1")["row_id"] == row_c, "receipt records row id")
    again, _ = sd._standalone_send(make_target(sd, job_s, sid_s), "standalone report", [])
    check(int(again["message_id"]) == row_c, "standalone retry same execution same row")
    bare = await app_platform.standalone_app_send(PlatformConfig(enabled=True), sid_s, "bare",
                                                  media_files=[])
    check(bare.get("error"), "bare standalone call without identity fails closed")
    # subprocess external worker: wrapper-carried execution id reaches the same key
    worker = home / "worker_probe.py"
    worker.write_text(f"""
import os, sys
import cron.scheduler_delivery as sd
from cron.scheduler_delivery import _TargetDelivery
from hermes_cli.plugins import discover_plugins
discover_plugins()
from gateway.config import Platform
job = {{"id": "jobC", "name": "Cron", "deliver": "app:{sid_s}", "execution_id": "execC1"}}
t = _TargetDelivery(job=job, platform=Platform("app"), platform_name="app",
    chat_id="{sid_s}", thread_id=None, transport=None, pconfig=None, runtime_adapter=None,
    target_adapters=None, config=None, loop=None, notify_delivery=True, origin={{}},
    origin_target=False, origin_user_id=None, is_dm_target=False, mirror_text="",
    mirror_this_target=False, in_channel_surface=False, inchannel_continuable=False,
    opened_thread_id=None)
result, error = sd._standalone_send(t, "standalone report", [])
print("WORKER", result, error)
""")
    env = {k: os.environ[k] for k in ("PATH", "HOME", "HERMES_HOME", "PYTHONPATH", "LANG")}
    env["HERMES_DISABLE_LAZY_INSTALLS"] = "1"
    out = subprocess.run([sys.executable, "-B", str(worker)], cwd=str(home), env=env,
                         capture_output=True, text=True, timeout=180)
    check("WORKER {'success': True, 'message_id': '" in out.stdout,
          f"subprocess worker send works: {out.stdout.strip()[-160:]} {out.stderr[-200:]}")
    check(len(db.get_messages(sid_s)) == 1
          and store.receipt_for(home, "execC1")["row_id"] == row_c,
          "worker retry same key same row id (no duplicate across processes)")
    # commit-then-lost-receipt: spool replay must dedup, not duplicate
    conn = sqlite3.connect(str(store.bridge_file(home)))
    conn.execute("""INSERT INTO pending(delivery_key, home, session_id, identity, content,
                    next_retry_at, created_at, updated_at)
                    SELECT delivery_key, home, session_id, ?, 'standalone report', ?, ?, ?
                    FROM receipts WHERE execution_id='execC1' AND status='delivered'""",
                 (json.dumps({"job_id": "jobC", "execution_id": "execC1", "name": "Cron"}),
                  time.time(), time.time(), time.time()))
    conn.commit()
    conn.close()
    check(store.drain_home(home)["delivered"] == 1, "spool replay after ack-crash dedups")
    check(len(db.get_messages(sid_s)) == 1, "ack-crash replay created no second row")
    # explicit fresh-thread propagation (mirrors upstream copy_context fallback)
    token = app_platform.DELIVERY_IDENTITY.set({"job_id": "jobCT", "execution_id": "execCT2",
                                                "name": "Cron"})
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        out = pool.submit(contextvars.copy_context().run, asyncio.run,
                          app_platform.standalone_app_send(PlatformConfig(enabled=True), sid_s,
                                                           "thread report",
                                                           media_files=[])).result(timeout=60)
    app_platform.DELIVERY_IDENTITY.reset(token)
    check(out.get("success") and len(db.get_messages(sid_s)) == 2,
          "identity survives copy_context into a fresh thread")

    # ---- D. conflicts / payload safety -----------------------------------------
    conflict = store.deliver(session_id=sid_s, content="MUTATED payload",
                             identity={"job_id": "jobC", "execution_id": "execC1", "name": "C"})
    check(conflict["status"] == "error" and conflict["error"] == "delivery_conflict"
          and conflict.get("permanent"), "same key different digest = conflict, no overwrite")
    check(len(db.get_messages(sid_s)) == 2, "conflict did not rewrite the committed rows")
    oversize = store.deliver(session_id=sid_s, content="x" * 40000,
                             identity={"job_id": "jobC", "execution_id": "execX", "name": "C"})
    media = store.deliver(session_id=sid_s, content="ok MEDIA:/etc/passwd",
                          identity={"job_id": "jobC", "execution_id": "execX2", "name": "C"})
    check(oversize["error"] == "report_too_large" and media["error"] == "media_unsupported"
          and len(db.get_messages(sid_s)) == 2,
          "oversize and MEDIA are preflighted before any write")

    # ---- E. attach=true/false, mirror and seeding off ---------------------------
    sid_e = "api_cron_mirror1"
    db.create_session(sid_e, model="compat-fixture", source="api_server")
    calls = []
    for attach in (True, False):
        job_e = {"id": f"jobE{attach}", "name": "E", "deliver": f"app:{sid_e}",
                 "execution_id": f"execE{attach}", "attach_to_session": attach}
        with patch("gateway.mirror.mirror_to_session",
                   side_effect=lambda *a, **k: calls.append(("mirror",)) or True), \
             patch.object(sd, "_open_continuable_cron_thread",
                          side_effect=lambda *a, **k: calls.append(("thread",)) or None), \
             patch.object(sd, "_send_media_via_adapter",
                          side_effect=lambda *a, **k: calls.append(("media",)) or []), \
             patch.object(sched, "load_config", return_value={"cron": {}}):
            error = sd._deliver_result(job_e, f"payload {attach}", adapters=None, loop=None)
        check(error is None and calls == [],
              f"attach_to_session={attach}: one write, zero mirror/thread-seed/media calls ({calls})")
    check(len(db.get_messages(sid_e)) == 2, "both attach variants wrote exactly once each")
    check(sd._target_mirror_eligible({"attach_to_session": True},
          {"platform": "discord", "chat_id": "9", "_resolved_from": "explicit"},
          global_mirror=True) is True, "non-app mirror eligibility unchanged")

    # ---- F. queued outcome ------------------------------------------------------
    sid_f = "api_cron_busy1"
    db.create_session(sid_f, model="compat-fixture", source="api_server")
    set_lease(db, sid_f, f"probe:pid={os.getpid()}")
    job_f = {"id": "jobF", "name": "F", "deliver": f"app:{sid_f}", "execution_id": "execF1"}
    with patch.object(sched, "load_config", return_value={"cron": {}}):
        error = sd._deliver_result(job_f, "busy payload", adapters=None, loop=None)
    receipt = store.receipt_for(home, "execF1")
    check(error is None and job_f.get("last_delivery_queued")
          and job_f["last_delivery_queued"]["platform"] == "app",
          "busy session reports observable queued (never fake-delivered)")
    check(receipt["status"] == "queued" and len(db.get_messages(sid_f)) == 0,
          "queued means NO committed row (spooled durably instead)")
    set_lease(db, sid_f, None)
    spool_due(home)
    check(store.drain_home(home)["delivered"] == 1
          and store.receipt_for(home, "execF1")["status"] == "delivered",
          "release + bounded drain lands exactly one row")
    check(len(db.get_messages(sid_f)) == 1, "drained delivery committed once")
    set_lease(db, sid_f, "pid=999999")  # dead holder: upstream guard reclaims
    job_f2 = dict(job_f, execution_id="execF2")
    with patch.object(sched, "load_config", return_value={"cron": {}}):
        error = sd._deliver_result(job_f2, "busy payload", adapters=None, loop=None)
    check(error is None and store.receipt_for(home, "execF2")["status"] == "delivered",
          "dead-holder lease is reclaimed by the upstream guard, not bypassed")
    set_lease(db, sid_f, None)

    # ---- G. compression / lineage / locks ---------------------------------------
    parent, kid = "api_cron_parent", "api_cron_kid"
    db.create_session(parent, model="compat-fixture", source="api_server")
    db.create_session(kid, model="compat-fixture", source="api_server",
                      parent_session_id=parent)
    with db._lock:
        db._conn.execute("UPDATE sessions SET ended_at=?, end_reason='compression' WHERE id=?",
                         (time.time(), parent))
        db._conn.commit()
    job_g = {"id": "jobG", "name": "G", "deliver": f"app:{parent}", "execution_id": "execG1"}
    with patch.object(sched, "load_config", return_value={"cron": {}}):
        error = sd._deliver_result(job_g, "lineage payload", adapters=None, loop=None)
    check(error is None and len(db.get_messages(kid)) == 1 and len(db.get_messages(parent)) == 0,
          "rotation raced: report follows the compression continuation, not the closed parent")
    job_g2 = dict(job_g, execution_id="execG2")
    with patch.object(sched, "load_config", return_value={"cron": {}}):
        sd._deliver_result(job_g2, "lineage payload", adapters=None, loop=None)
    with db._lock:
        db._conn.execute("INSERT INTO compression_locks(session_id, holder, acquired_at,"
                         " expires_at) VALUES(?,?,?,?)",
                         (kid, f"probe:pid={os.getpid()}", time.time(), time.time() + 300))
        db._conn.commit()
    job_g3 = dict(job_g, execution_id="execG3")
    with patch.object(sched, "load_config", return_value={"cron": {}}):
        error = sd._deliver_result(job_g3, "lock-time payload", adapters=None, loop=None)
    check(error is None and len(db.get_messages(kid)) == 3,
          "an active COMPRESSION lock does not block cron appends (watermark design intact)")
    with db._lock:
        db._conn.execute("DELETE FROM compression_locks")
        db._conn.commit()

    # ---- H. hidden / archived / ended / deleted / wrong-source -------------------
    for name, verdict in (("hidden", "target_hidden"), ("archived", "target_archived"),
                          ("ended", "target_ended"), ("gone", "target_missing"),
                          ("foreign", "target_wrong_source")):
        s = f"api_cron_{name}"
        if name != "gone":
            db.create_session(s, model="compat-fixture",
                              source="cron" if name == "foreign" else "api_server")
        if name == "hidden":
            db.set_session_hidden(s, True)
        if name == "archived":
            db.set_session_archived(s, True)
        if name == "ended":
            with db._lock:
                db._conn.execute("UPDATE sessions SET ended_at=?, end_reason='reset' WHERE id=?",
                                 (time.time(), s))
                db._conn.commit()
        outcome = store.deliver(session_id=s, content="x",
                                identity={"job_id": "jobH", "execution_id": f"execH{name}",
                                          "name": "H"})
        check(outcome["status"] == "error" and outcome["error"].startswith(verdict)
              and outcome.get("permanent"), f"{name} target refused as {verdict}")
        check(len(db.get_messages(s)) == 0,
              f"{name} target was not unhidden/recreated/written")
    committed = "api_cron_committed"
    db.create_session(committed, model="compat-fixture", source="api_server")
    first = store.deliver(session_id=committed, content="kept",
                          identity={"job_id": "jobH", "execution_id": "execHK", "name": "H"})
    db.set_session_hidden(committed, True)
    retry = store.deliver(session_id=committed, content="kept",
                          identity={"job_id": "jobH", "execution_id": "execHK", "name": "H"})
    check(first["status"] == "delivered" and retry["status"] == "dedup"
          and retry["row_id"] == first["row_id"]
          and db.get_session(committed)["hidden"] == 1
          and len(db.get_messages(committed)) == 1,
          "retry of a committed execution keeps the receipt without unhiding or rewriting")

    # ---- I. multi-target preflight + missing execution id ------------------------
    sends = []
    sid_i = "api_cron_multi1"
    db.create_session(sid_i, model="compat-fixture", source="api_server")
    job_i = {"id": "jobI", "name": "I", "deliver": f"app:{sid_i},discord:1234",
             "execution_id": "execI1", "attach_to_session": True}
    with patch.object(sd, "_deliver_standalone",
                      side_effect=lambda *a, **k: sends.append(a)), \
         patch.object(sched, "load_config", return_value={"cron": {}}):
        error = sd._deliver_result(job_i, "mixed payload", adapters=None, loop=None)
    check(error and "only target" in error and sends == [],
          "mixed app+discord is refused BEFORE any platform send")
    check(len(db.get_messages(sid_i)) == 0 and store.receipt_for(home, "execI1") is None,
          "refused preflight wrote nothing anywhere")
    sid_n = "api_cron_noexec"
    db.create_session(sid_n, model="compat-fixture", source="api_server")
    with patch.object(sched, "load_config", return_value={"cron": {}}):
        error = sd._deliver_result({"id": "jobN", "name": "N", "deliver": f"app:{sid_n}"},
                                   "no exec id", adapters=None, loop=None)
    check(error and "missing_execution_id" in error and len(db.get_messages(sid_n)) == 0,
          "missing execution_id fails closed; nothing is guessed")
    with patch.object(sched, "load_config", return_value={"cron": {}}):
        error = sd._deliver_result({"id": "jobL", "name": "L", "deliver": f"app:{sid_i}",
                                    "execution_id": "execL1"}, "MEDIA:/tmp/any.png",
                                   adapters=None, loop=None)
    check(error and "text-only" in error and len(db.get_messages(sid_i)) == 0,
          "MEDIA payload rejected preflight before any lane ran")

    # ---- K. binding hygiene -------------------------------------------------------
    check(sd._deliver_result.__name__ == "deliver_result"
          and sched._deliver_result is sd._deliver_result,
          "defining module and scheduler facade share the ONE wrapper")
    check(app_platform.parse_app_session_ref is entry.parse_target_ref_fn,
          "registry parser is the plugin's exact function")
    db.close()
    return "PASS", "cron bridge families A-K passed"
