"""SELFWAKE: server-side self-wake — durable intents, generation/cutoff,
reconciliation, chain fuse, audit, and the gateway-owned wake worker.

The worker is the SECOND CLIENT of the existing B ledger (wake_ledger.db):
it shares the delivery_key consumption records, the 6/session + 12/profile
rolling quota, and the single chat/stream + wake_batch dispatch door. It is
NOT a second consumption ledger: intent rows in cron_bridge.db are a TODO
list written in the SAME transaction as the bridge delivered receipt, and
"was this report already consumed?" is always answered by the B ledger.

Modes (profile config.yaml, read fail-closed with a reason):

    wake:
      selfwake: false          # off (default) — nothing fires, no new intents
      # selfwake: shadow       # S2 evidence mode: intents recorded, never fired,
      #                        #   NOTHING is admitted (no quota, no consumption)
      # selfwake: true         # on: idle reports wake a reading turn by self
      selfwake_chain_limit: 3  # max self wakes without a human checkpoint
      selfwake_cooldown_seconds: 60

Rollback stops new admits/intents and leaves accepted runs + consumed keys
untouched; reports are never deleted and the ledger is never rebuilt.
"""
from __future__ import annotations

import asyncio
import json
import logging
import random
import sqlite3
import time
from contextlib import suppress
from pathlib import Path

log = logging.getLogger("hermes-app-compat.selfwake")

INTENT_STATES = ("shadow", "pending", "watching", "done", "void")
BATCH_MAX_DELIVERY_IDS = 10
RETRY_BUSY_S = 5.0
RETRY_JITTER_S = 2.0
RECONCILE_INTERVAL_S = 60.0
SWEEP_INTERVAL_S = 15.0
MODES = ("off", "shadow", "on")

_module_state = {"loop": None, "worker": None, "generation_guard": {}}


def reset():
    """Plugin unload: stop new work, then drop the loop reference. Dispatches
    already in flight settle through the ledger, never through this module."""
    worker = _module_state.get("worker")
    if worker is not None:
        worker.stop()
    tlp = _module_state.get("thread_loop")
    if tlp is not None:
        try:
            tlp.call_soon_threadsafe(tlp.stop)
        except Exception:
            pass
    _module_state["loop"] = None
    _module_state["worker"] = None
    _module_state["generation_guard"] = {}
    _module_state["thread"] = None
    _module_state["thread_loop"] = None


# --------------------------------------------------------------------------
# config (profile scope; unknown keys or wrong types fail CLOSED)


def _config(home: Path):
    """Profile-scoped config load; a home that is not THIS process's profile
    never gets a verdict (fail closed — cross-profile reads are forbidden)."""
    try:
        from hermes_constants import get_hermes_home
        if Path(home).resolve() != Path(get_hermes_home()).resolve():
            return None
    except Exception:
        pass
    try:
        from hermes_cli.config_effective import load_user_config_effective
        return load_user_config_effective() or {}
    except Exception:
        try:
            import yaml as _yaml
            from hermes_cli.config import get_config_path
            return _yaml.safe_load(open(get_config_path())) or {}
        except Exception:
            return None


def settings(home: Path):
    """Return ``(mode, params, unavailable_reason)``. mode is off whenever
    anything is doubtful — self-wake never runs on a guessed config."""
    params = {"chain_limit": 3, "cooldown_seconds": 60.0}
    cfg = _config(Path(home))
    if cfg is None:
        return "off", params, "config unreadable or cross-profile"
    block = cfg.get("wake")
    if block is None:
        return "off", params, None
    if not isinstance(block, dict):
        return "off", params, "wake block malformed"
    flag = block.get("selfwake", False)
    if isinstance(flag, bool):
        mode = "on" if flag else "off"
    elif isinstance(flag, str) and flag.strip().lower() in ("shadow",):
        mode = "shadow"
    else:
        return "off", params, "wake.selfwake malformed"
    try:
        limit = block.get("selfwake_chain_limit", 3)
        cool = block.get("selfwake_cooldown_seconds", 60)
        if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 12:
            return "off", params, "wake.selfwake_chain_limit malformed"
        if isinstance(cool, bool) or not isinstance(cool, (int, float)) or not 0 <= cool <= 3600:
            return "off", params, "wake.selfwake_cooldown_seconds malformed"
    except Exception:
        return "off", params, "wake selfwake params malformed"
    params["chain_limit"], params["cooldown_seconds"] = int(limit), float(cool)
    return mode, params, None


# --------------------------------------------------------------------------
# schema (lives in cron_bridge.db so receipt+intent share ONE transaction)


def ensure_bridge_schema(conn):
    conn.execute("""CREATE TABLE IF NOT EXISTS selfwake_intents(
        delivery_key TEXT PRIMARY KEY, home TEXT NOT NULL, session_id TEXT NOT NULL,
        row_id INTEGER, generation INTEGER NOT NULL, cutoff REAL NOT NULL,
        reason TEXT NOT NULL, batch_id TEXT, owner TEXT, state TEXT NOT NULL,
        detail TEXT, attempts INTEGER NOT NULL DEFAULT 0,
        next_attempt_at REAL NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL)""")
    conn.execute("CREATE INDEX IF NOT EXISTS si_due ON selfwake_intents(state, next_attempt_at)")
    conn.execute("INSERT OR IGNORE INTO meta(key, value) VALUES('selfwake_version', '1')")


def _meta(conn, key, value=None):
    if value is None:
        row = conn.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        return row["value"] if row is not None else None
    conn.execute("INSERT INTO meta(key, value) VALUES(?, ?)"
                 " ON CONFLICT(key) DO UPDATE SET value = excluded.value", (key, value))
    return value


def generation_cutoff(conn, now: float):
    """One enable generation; restarts KEEP it (never re-baseline the cutoff)."""
    gen = _meta(conn, "selfwake_generation")
    if gen is None:
        _meta(conn, "selfwake_generation", "1")
        _meta(conn, "selfwake_cutoff", repr(now))
        gen = "1"
    return int(gen), float(_meta(conn, "selfwake_cutoff"))


def bump_generation(conn, now: float):
    gen, _ = generation_cutoff(conn, now)
    _meta(conn, "selfwake_generation", str(gen + 1))
    _meta(conn, "selfwake_cutoff", repr(now))
    return gen + 1, now


def bump_generation_standalone(home, now: float):
    """Worker-side bump on its OWN connection: must commit or the shared
    bridge handle stays inside a write transaction and starves everything
    else that touches it."""
    conn = _bridge(Path(home))
    with _bridge_lock():
        result = bump_generation(conn, now)
        conn.commit()
    return result


# --------------------------------------------------------------------------
# delivery hooks (called INSIDE the bridge transaction; never fire a model)


def on_delivered(conn, *, home: str, session_id: str, delivery_key: str, row_id,
                 reason: str):
    """Fresh bridge-delivered report: register the self-wake intent in the
    CALLER's transaction (same commit as the receipt). dedup/queued/failed
    never reach this. Off mode registers nothing; shadow records but never
    admits. Returns the state written (or None)."""
    mode, _params, _why = settings(Path(home))
    if mode == "off":
        return None
    now = time.time()
    gen, cutoff = generation_cutoff(conn, now)
    existing = conn.execute("SELECT state FROM selfwake_intents WHERE delivery_key = ?",
                            (delivery_key,)).fetchone()
    if existing is not None:
        return existing["state"]  # dedup never adds a second wake task
    state = "shadow" if mode == "shadow" else "pending"
    conn.execute(
        "INSERT INTO selfwake_intents(delivery_key, home, session_id, row_id, generation,"
        " cutoff, reason, state, next_attempt_at, created_at, updated_at)"
        " VALUES(?,?,?,?,?,?,?,?,?,?,?)",
        (delivery_key, home, session_id, row_id, gen, cutoff, reason,
         state, now, now, now))
    return state


def delivered_event(home: Path):
    """deliver-delivered hook: low-latency nudge only; periodic sweeps keep
    liveness even when no hook ever fires (plan: hooks accelerate, never own
    correctness). Fail-open by design."""
    with suppress(Exception):
        loop = _module_state.get("loop")
        worker = _module_state.get("worker")
        if loop is not None and worker is not None:
            loop.call_soon_threadsafe(worker.kick)


def drainer_drained(home: Path, summary: dict):
    """drainer-drained hook. Only FRESH delivered counts matter; dedup is a
    receipt echo, never a wake trigger (counts are separated upstream)."""
    if summary.get("delivered"):
        delivered_event(home)


# --------------------------------------------------------------------------
# crash-gap reconciliation (SessionDB committed, receipt/intent uncommitted)


def reconcile(home: Path, *, db=None, limit=200):
    """Add intents for reports committed after the cutoff that the bridge
    never finalized (crash between SessionDB commit and receipt commit).
    Dedup is by delivery_key (compression copies share the key)."""
    from . import auto_wake_store
    if not auto_wake_store.bindings_ready():
        return {"skipped": "unbound"}
    mode, _params, _why = settings(home)
    if mode == "off":
        return {"skipped": "off"}
    from hermes_state_registry import acquire, release_or_close
    from contextlib import closing
    own = db is None
    if own:
        try:
            db = acquire(Path(home) / "state.db")
        except Exception as exc:
            return {"skipped": f"db:{type(exc).__name__}"}
    added = consumed_free = 0
    try:
        conn = _bridge(home)
        gen, cutoff = generation_cutoff(conn, time.time())
        rows = db._read_all(
            "SELECT m.id AS id, m.session_id AS session_id, m.timestamp AS timestamp,"
            " json_extract(m.display_metadata, '$.hermes_app_cron.delivery_key') AS key,"
            " json_extract(m.display_metadata, '$.hermes_app_cron.digest') AS digest"
            " FROM messages m WHERE m.role = 'user'"
            " AND m.display_kind = 'internal_notification'"
            " AND json_extract(m.display_metadata, '$.hermes_app_cron.schema') = 1"
            " AND m.timestamp > ? ORDER BY m.timestamp, m.id LIMIT ?", (cutoff, limit))
        with _bridge_lock():
            for row in rows:
                key = row["key"]
                if not key:
                    continue
                have = conn.execute(
                    "SELECT 1 FROM selfwake_intents WHERE delivery_key = ?", (key,)).fetchone()
                if have is not None:
                    continue
                # The crash gap has NO receipt; a delivered receipt means the
                # report arrived while self-wake was off (or shadow recorded
                # it): history, never woken retroactively.
                recv = conn.execute(
                    "SELECT status FROM receipts WHERE delivery_key = ?", (key,)).fetchone()
                if recv is not None:
                    continue
                state = "shadow" if mode == "shadow" else "pending"
                now = time.time()
                conn.execute(
                    "INSERT OR IGNORE INTO selfwake_intents(delivery_key, home,"
                    " session_id, row_id, generation, cutoff, reason, state,"
                    " next_attempt_at, created_at, updated_at) VALUES(?,?,?,?,?,?, ?,?,?,?,?)",
                    (key, str(home), row["session_id"], row["id"], gen, cutoff,
                     "reconciled", state, now, now, now))
                if not conn.execute("SELECT 1 FROM receipts WHERE delivery_key = ? AND"
                                    " status = 'delivered'", (key,)).fetchone():
                    conn.execute("INSERT OR IGNORE INTO receipts(delivery_key, home,"
                                 " execution_id, status, row_id, error, digest, session_id,"
                                 " created_at, updated_at) VALUES(?,?, 'reconciled','delivered',?,"
                                 " NULL,?, ?, ?,?)",
                                 (key, str(home), row["id"], row["digest"],
                                  row["session_id"], now, now))
                    added += 1
                else:
                    consumed_free += 1
            conn.commit()
    finally:
        if own:
            with suppress(Exception):
                release_or_close(db)
    return {"added": added, "backfilled_receipts_only": consumed_free}


_BRIDGE = None


def _bridge(home: Path):
    from . import cron_delivery_store
    return cron_delivery_store.open_bridge(home)


def _bridge_lock():
    from . import cron_delivery_store
    return cron_delivery_store._bridge_lock


# --------------------------------------------------------------------------
# S4 chain fuse + audit (wake_ledger.db; durable: survives restart/hour)


def _ledger(home: Path):
    from . import auto_wake_store
    return auto_wake_store.open_ledger(home)


def chain_gate(home: Path, lineage: str, now=None):
    """(allowed, reason, chain_count, retry_after). Reset requires a
    RELIABLE human checkpoint or an explicit admin reset; restarts, hour
    windows and compression never reset the count."""
    now = time.time() if now is None else now
    mode, params, why = settings(home)
    if mode == "off":
        return False, f"selfwake off ({why or 'disabled'})", 0, None
    conn = _ledger(home)
    row = conn.execute("SELECT fires, last_fire_at, fused FROM selfwake_chain"
                       " WHERE session_id = ?", (lineage,)).fetchone()
    fires, last, fused = ((row["fires"], row["last_fire_at"], row["fused"])
                          if row is not None else (0, None, 0))
    if fused:
        return False, "fault-fused (explicit reset required)", fires, None
    if fires >= params["chain_limit"]:
        return False, "chain-limit reached (needs human checkpoint)", fires, None
    if last is not None and now - float(last) < params["cooldown_seconds"]:
        return False, "cooldown", fires, params["cooldown_seconds"] - (now - float(last))
    return True, None, fires, None


def chain_note(home: Path, lineage: str, now=None):
    now = time.time() if now is None else now
    conn = _ledger(home)
    conn.execute("INSERT INTO selfwake_chain(session_id, fires, last_fire_at, fails,"
                 " updated_at) VALUES(?,?,?,0,?) ON CONFLICT(session_id) DO UPDATE SET"
                 " fires = selfwake_chain.fires + 1, last_fire_at = excluded.last_fire_at,"
                 " fails = 0, updated_at = excluded.updated_at", (lineage, 1, now, now))
    conn.commit()


def chain_fail(home: Path, lineage: str, reason: str):
    """A batch that settled failed/uncertain counts toward the fault fuse;
    any clean completion resets the streak (chain_note)."""
    conn = _ledger(home)
    conn.execute("INSERT INTO selfwake_chain(session_id, fires, fails, updated_at)"
                 " VALUES(?,0,?,?) ON CONFLICT(session_id) DO UPDATE SET"
                 " fails = selfwake_chain.fails + 1, updated_at = excluded.updated_at",
                 (lineage, 1, time.time()))
    conn.commit()
    row = conn.execute("SELECT fails FROM selfwake_chain WHERE session_id = ?",
                       (lineage,)).fetchone()
    if row is not None and row["fails"] >= 3:
        fault_fuse(home, lineage, f"3 consecutive failures ({reason})")
        return True
    return False


def chain_human_checkpoint(home: Path, db, resolved: str, since: float):
    """A human message (NOT a bridge report, NOT the canonical wake input,
    NOT a role=user report) after the last fire reopens the chain."""
    from . import auto_wake
    try:
        rows = db._read_all(
            "SELECT m.content AS content, m.display_kind AS dk, m.role AS role"
            " FROM messages m WHERE m.session_id = ? AND m.role = 'user'"
            " AND m.timestamp > ? AND m.display_kind IS NULL"
            " AND m.content != ? LIMIT 1", (resolved, since, auto_wake.CANONICAL_INPUT))
    except Exception:
        return False  # unprovable: stays fused/limited (fail closed)
    return bool(rows)


def fault_fuse(home: Path, lineage: str, reason: str):
    now = time.time()
    conn = _ledger(home)
    conn.execute("INSERT INTO selfwake_chain(session_id, fires, last_fire_at, fused, updated_at)"
                 " VALUES(?,0,NULL,1,?) ON CONFLICT(session_id) DO UPDATE SET fused = 1,"
                 " updated_at = excluded.updated_at", (lineage, now))
    conn.commit()
    audit(home, phase="fuse", resolved=lineage, reason=reason, trigger="self")


def chain_release(home: Path, lineage: str):
    """Admin reset (documented in the deploy note); never automatic."""
    conn = _ledger(home)
    conn.execute("UPDATE selfwake_chain SET fires = 0, fused = 0, updated_at = ?"
                 " WHERE session_id = ?", (time.time(), lineage))
    conn.commit()
    audit(home, phase="chain-reset", resolved=lineage, reason="admin", trigger="self")


def audit(home: Path, *, phase: str, resolved: str = None, original: str = None,
          keys=None, row_ids=None, batch_id=None, run_id=None, from_state=None,
          to_state=None, reason=None, quota_used=None, chain_count=None,
          latency=None, trigger="self"):
    """One durable audit row per dispatch decision and one per terminal/
    uncertain close. NEVER auth, report bodies, or system prompts."""
    conn = _ledger(home)
    conn.execute(
        "INSERT INTO selfwake_audit(at, session_original, session_resolved, trigger,"
        " key_prefixes, row_ids, batch_id, run_id, phase, from_state, to_state, reason,"
        " quota_used, chain_count, latency) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (time.time(), original, resolved, trigger,
         json.dumps([k[:12] for k in (keys or [])]), json.dumps(list(row_ids or [])),
         batch_id, run_id, phase, from_state, to_state, reason,
         quota_used, chain_count, latency))
    conn.commit()


# --------------------------------------------------------------------------
# S3: readiness + loopback dispatch endpoint (never hardcoded, never proxied)


def endpoint(home: Path):
    """(base_url, headers) or (None, reason). Loopback ONLY, from THIS profile
    gateway.api_server config. No listener / no key / non-loopback host →
    explicit unavailable; the worker never falls back to another model entry
    or a default profile."""
    cfg = _config(Path(home))
    if cfg is None:
        return None, "config unavailable"
    api = ((cfg.get("gateway") or {}).get("api_server")) or {}
    if not isinstance(api, dict):
        api = {}
    # The api_server adapter itself is env-enablement first (API_SERVER_* /
    # .env); a deployment that enables it there has NO gateway.api_server
    # section in config.yaml. Mirror the adapter's own reading so an
    # env-enabled listener is not misjudged as absent (production burn of
    # "listener disabled" decisions, 2026-10).
    import os
    def _env(name: str) -> str:
        val = os.getenv(name, "")
        if val:
            return val
        # The gateway main process does NOT import .env into os.environ
        # (secrets are loaded per-adapter via secret scope). The worker
        # runs on the gateway loop, so os.getenv alone is always empty
        # for API_SERVER_*; read the file the adapter's own loader reads.
        try:
            env_path = os.path.join(str(home), ".env")
            with open(env_path, "r", encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if line.startswith(name + "="):
                        return line.split("=", 1)[1].strip().strip('"').strip("'")
        except Exception:
            pass
        return ""
    enabled = api.get("enabled")
    if not enabled:
        enabled = _env("API_SERVER_ENABLED").lower() in ("1", "true", "yes", "on")
    if not enabled:
        return None, "listener disabled"
    host = str(api.get("host") or _env("API_SERVER_HOST") or "127.0.0.1")
    if host == "0.0.0.0":
        host = "127.0.0.1"
    port = api.get("port")
    if port is None:
        raw = _env("API_SERVER_PORT")
        port = int(raw) if raw.isdigit() else 8642
    key = api.get("key")
    if not (isinstance(key, str) and key.strip()):
        try:
            from agent.secret_scope import get_secret as _scoped
            key = _scoped("API_SERVER_KEY", "") or _env("API_SERVER_KEY")
        except Exception:
            key = _env("API_SERVER_KEY")
    if not _is_own_host(host):
        return None, "listener is not loopback"
    if not isinstance(port, int) or isinstance(port, bool) or not 0 < port < 65536:
        return None, "listener port missing"
    if not isinstance(key, str) or not key.strip():
        return None, "listener auth unavailable"
    return (f"http://{host}:{port}",
            {"Authorization": "Bearer " + key.strip()})


def _is_own_host(host: str) -> bool:
    """Loopback, or an address owned by THIS machine. The redline is 'the
    worker never wakes a remote/other model entry'; a gateway bound to a
    local interface (a tailnet IP is the common case) is still this machine.
    """
    if host in ("127.0.0.1", "localhost", "::1", "0.0.0.0"):
        return True
    try:
        import socket
        if host == socket.gethostname():
            return True
    except Exception:
        pass
    try:
        import psutil
        owned = set()
        for addrs in psutil.net_if_addrs().values():
            for a in addrs:
                if a.address:
                    owned.add(str(a.address).split("%")[0])
        return host in owned
    except Exception:
        return False


# --------------------------------------------------------------------------
# S3: the gateway-owned worker. ONE instance per profile, single-flight per
# session, profile concurrency 1, fair rotation. Periodic sweep owns
# liveness; the delivered hooks only accelerate.


class SelfWakeWorker:
    def __init__(self, home):
        self.home = Path(home).resolve()
        self._task = None
        self._wake = None
        self._loop = None
        self._busy = False
        self._next_reconcile = 0.0
        self._mode_seen = None
        self._audit_throttle = {}

    # -- lifecycle ----------------------------------------------------------
    def arm(self, loop):
        self._loop = loop
        if self._task is None or self._task.done():
            self._wake = asyncio.Event()
            self._task = loop.create_task(self._run(), name="hermes-app-selfwake")

    def stop(self):
        task = self._task
        self._task = None
        if task is not None:
            task.cancel()

    def kick(self):
        try:
            if self._wake is not None:
                self._wake.set()
        except Exception:
            pass

    async def _run(self):
        while True:
            try:
                await asyncio.wait_for(self._wake.wait(), timeout=SWEEP_INTERVAL_S)
            except asyncio.TimeoutError:
                pass
            self._wake.clear()
            try:
                await self.tick()
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                log.warning("selfwake tick failed: %s", type(exc).__name__)

    # -- one pass -----------------------------------------------------------
    async def tick(self):
        if self._busy:
            return
        self._busy = True
        try:
            mode, params, _why = settings(self.home)
            prev, self._mode_seen = self._mode_seen, mode
            if mode == "off":
                if prev in ("on", "shadow"):
                    # Disable stops NEW dispatches and voids undispatched
                    # pending intents (shadow-era ones included); watching/
                    # accepted batches keep their consumed status (toggles
                    # never release claims).
                    await asyncio.to_thread(self._disable_sweep)
                return
            if prev == "off":
                await asyncio.to_thread(bump_generation_standalone, self.home, time.time())
            now = time.time()
            if mode == "shadow":
                if now >= self._next_reconcile:
                    await asyncio.to_thread(reconcile, self.home)
                    self._next_reconcile = now + RECONCILE_INTERVAL_S
                return  # shadow NEVER admits or dispatches
            if now >= self._next_reconcile:
                await asyncio.to_thread(reconcile, self.home)
                self._next_reconcile = now + RECONCILE_INTERVAL_S
            rows = await asyncio.to_thread(self._due, now)
            session = rows[0]["session_id"] if rows else None
            if session is None:
                return
            items = [r for r in rows if r["session_id"] == session][:BATCH_MAX_DELIVERY_IDS]
            await self._process(session, items, params, now)
        finally:
            self._busy = False

    def _due(self, now):
        conn = _bridge(self.home)
        with _bridge_lock():
            return [dict(r) for r in conn.execute(
                "SELECT * FROM selfwake_intents WHERE state IN ('pending','watching')"
                " AND next_attempt_at <= ? ORDER BY created_at LIMIT 32", (now,))]

    def _disable_sweep(self):
        conn = _bridge(self.home)
        with _bridge_lock():
            conn.execute("UPDATE selfwake_intents SET state='void', detail='disabled',"
                         " updated_at = ? WHERE state IN ('pending','shadow')",
                         (time.time(),))
            conn.commit()

    def _set_items(self, items, state, *, batch=None, owner=None, detail=None,
                   next_at=None):
        conn = _bridge(self.home)
        now = time.time()
        with _bridge_lock():
            for item in items:
                conn.execute(
                    "UPDATE selfwake_intents SET state=?, batch_id=COALESCE(?, batch_id),"
                    " owner=COALESCE(?, owner), detail=?, next_attempt_at=?,"
                    " attempts = attempts + 1, updated_at=? WHERE delivery_key = ?",
                    (state, batch, owner, detail,
                     next_at if next_at is not None else item["next_attempt_at"],
                     now, item["delivery_key"]))
            conn.commit()

    def _throttled_audit(self, tag, **fields):
        last = self._audit_throttle.get(tag)
        if last is not None and time.time() - last < 300.0:
            return
        self._audit_throttle[tag] = time.time()
        audit(self.home, **fields)

    # -- one session group --------------------------------------------------
    async def _process(self, session, items, params, now):
        from . import auto_wake_store
        from hermes_state_registry import acquire, release_or_close
        keys = [i["delivery_key"] for i in items]
        try:
            db = await asyncio.to_thread(acquire, self.home / "state.db")
        except Exception as exc:
            self._set_items(items, "pending", next_at=now + 30,
                            detail=f"db:{type(exc).__name__}")
            return
        try:
            try:
                resolved = await asyncio.to_thread(db.resolve_resume_session_id, session)
            except Exception:
                resolved = session
            # 1. Whose consumption is this? The B ledger answers, always.
            linked, foreign = [], []
            for item in items:
                verdict = await asyncio.to_thread(auto_wake_store.ledger_state_for,
                                                  self.home, item["delivery_key"])
                if verdict is None:
                    linked.append(item)
                    continue
                batch = await asyncio.to_thread(self._batch_of, verdict.get("batch_id"))
                if verdict["state"] == "ignored":
                    self._set_items([item], "done", detail="ignored")
                elif batch is not None and (batch.get("owner") or "").startswith("self:"):
                    linked.append(item)  # our own claim: follow the batch below
                elif batch is not None and batch["state"] == "released":
                    self._set_items([item], "pending", detail="app-released",
                                    next_at=time.time() + 5)
                else:
                    foreign.append(item)  # App claimed/handled: self yields, forever
            if foreign:
                self._set_items(foreign, "done", detail="app-consumed")
                audit(self.home, phase="yield", original=session, resolved=resolved,
                      keys=[i["delivery_key"] for i in foreign], reason="app-consumed",
                      trigger="self")
            if not linked:
                return
            keys = [i["delivery_key"] for i in linked][:BATCH_MAX_DELIVERY_IDS]
            own_batch = next((i["batch_id"] for i in linked if i["batch_id"]), None)
            # 2. OUR batch already exists (dispatch retry / crash recovery):
            # NEVER admit a second batch for these keys.
            if own_batch:
                state_now = await asyncio.to_thread(self._batch_state, own_batch)
                if state_now == "reserved":
                    await self._dispatch(linked, resolved, own_batch)
                elif state_now in ("dispatching", "accepted"):
                    # We cannot prove the run never started: settle once,
                    # observed or uncertain — never a new POST.
                    if state_now == "accepted":
                        done = await self._poll_run(own_batch, resolved)
                        if done:
                            self._set_items(linked, "done", detail=f"observed:{done}")
                            if done == "completed":
                                try:
                                    from hermes_state_registry import (acquire,
                                                                       release_or_close)
                                    d = await asyncio.to_thread(acquire,
                                                                self.home / "state.db")
                                    try:
                                        lin = await asyncio.to_thread(lineage_root,
                                                                      d, resolved)
                                    finally:
                                        await asyncio.to_thread(release_or_close, d)
                                    await asyncio.to_thread(chain_note, self.home, lin)
                                except Exception:
                                    pass
                            else:
                                await self._fail_note(resolved, f"run-{done}")
                            return
                    await asyncio.to_thread(auto_wake_store.report, self.home,
                                           batch_id=own_batch, resolved=resolved,
                                           state="uncertain")
                    self._set_items(linked, "done", detail="uncertain-consumed")
                    await self._fail_note(resolved, "crash-recovery-settled")
                    audit(self.home, phase="terminal", original=session,
                          resolved=resolved, batch_id=own_batch, to_state="uncertain",
                          reason="crash-recovery-settled", trigger="self")
                else:
                    self._set_items(linked, "done", detail=f"batch-{state_now}")
                return
            # 3. Fresh claim: fuse → admit.
            lineage = await asyncio.to_thread(lineage_root, db, resolved)
            allowed, deny, fires, retry = await asyncio.to_thread(
                chain_gate, self.home, lineage)
            if not allowed:
                self._throttled_audit(f"fuse:{lineage}", phase="decision", original=session,
                                      resolved=resolved, keys=keys, reason=deny,
                                      chain_count=fires, trigger="self")
                self._set_items(linked, "pending",
                                next_at=time.time() + (retry or 300), detail=deny)
                return
            owner = "self:" + _owner_token()
            outcome = await asyncio.to_thread(
                auto_wake_store.admit, self.home, session_id=resolved, resolved=resolved,
                keys=keys, db=db, owner=owner)
            status = outcome["status"]
            if status == "admitted":
                self._set_items(linked, "watching", batch=outcome["batch_id"], owner=owner,
                                detail="dispatching")
                audit(self.home, phase="dispatch", original=session, resolved=resolved,
                      keys=keys, row_ids=[i["row_id"] for i in linked],
                      batch_id=outcome["batch_id"], to_state="reserved",
                      reason="admitted", chain_count=fires + 1, trigger="self",
                      quota_used=outcome.get("quota", {}).get("session_used"))
                await self._dispatch(linked, resolved, outcome["batch_id"])
            elif status == "busy":
                self._throttled_audit(f"busy:{resolved}", phase="decision", original=session,
                                      resolved=resolved, keys=keys, reason="busy",
                                      trigger="self")
                self._set_items(linked, "pending",
                                next_at=time.time() + RETRY_BUSY_S + random.random() * RETRY_JITTER_S,
                                detail="busy")
            elif status == "quota_exceeded":
                self._throttled_audit(f"quota:{resolved}", phase="decision", original=session,
                                      resolved=resolved, keys=keys, reason="quota_exceeded",
                                      trigger="self")
                self._set_items(linked, "pending",
                                next_at=time.time() + float(outcome.get("retry_after_s", 300)),
                                detail="quota")
            elif status == "empty":
                reasons = {r.get("reason") for r in outcome.get("rejected", [])}
                consumed_batches = {r.get("batch_id") for r in outcome.get("rejected", [])
                                    if r.get("reason") == "already_consumed"
                                    and r.get("batch_id")}
                adopted = None
                if len(consumed_batches) == 1 and reasons <= {"already_consumed"}:
                    # Crash AFTER admit, BEFORE intent association: the owner
                    # column proves whose reservation this is — self may take
                    # over its OWN reserved batch; a foreign one stays untouched.
                    candidate = next(iter(consumed_batches))
                    batch = await asyncio.to_thread(self._batch_of, candidate)
                    if (batch is not None
                            and (batch.get("owner") or "").startswith("self:")
                            and batch["state"] == "reserved"):
                        adopted = candidate
                if adopted:
                    self._set_items(linked, "watching", batch=adopted,
                                    detail="adopted-own-reservation")
                    audit(self.home, phase="decision", original=session,
                          resolved=resolved, keys=keys, batch_id=adopted,
                          reason="adopted-own-reservation", trigger="self")
                    await self._dispatch(linked, resolved, adopted)
                elif reasons and reasons <= {"already_consumed"}:
                    self._set_items(linked, "done", detail="app-consumed")
                else:
                    nxt = 300 if "causal_suspect" in reasons else 60
                    self._throttled_audit(f"empty:{resolved}:{sorted(reasons)}",
                                          phase="decision", original=session,
                                          resolved=resolved, keys=keys,
                                          reason=",".join(sorted(reasons)) or "empty",
                                          trigger="self")
                    self._set_items(linked, "pending", next_at=time.time() + nxt,
                                    detail=",".join(sorted(reasons))[:80])
            else:
                self._set_items(linked, "void", detail=f"admit:{outcome.get('error', status)}")
                audit(self.home, phase="decision", original=session, resolved=resolved,
                      keys=keys, reason=f"admit-error:{outcome.get('error', status)}",
                      trigger="self")
        finally:
            from contextlib import suppress
            with suppress(Exception):
                await asyncio.to_thread(release_or_close, db)

    def _batch_of(self, batch_id):
        if not batch_id:
            return None
        conn = _ledger(self.home)
        row = conn.execute("SELECT state, owner FROM wake_batches WHERE batch_id = ?",
                           (batch_id,)).fetchone()
        return dict(row) if row is not None else None

    def _batch_state(self, batch_id):
        conn = _ledger(self.home)
        row = conn.execute("SELECT state FROM wake_batches WHERE batch_id = ?",
                           (batch_id,)).fetchone()
        return row["state"] if row is not None else "gone"

    # -- loopback dispatch: ONE POST per batch; SSE fully consumed -----------
    async def _fail_note(self, resolved, reason):
        from hermes_state_registry import acquire, release_or_close
        try:
            d = await asyncio.to_thread(acquire, self.home / "state.db")
            try:
                lin = await asyncio.to_thread(lineage_root, d, resolved)
            finally:
                await asyncio.to_thread(release_or_close, d)
        except Exception:
            return
        await asyncio.to_thread(chain_fail, self.home, lin, reason)

    async def _dispatch(self, items, resolved, batch_id):
        from . import auto_wake
        from .auto_wake_store import report
        result = endpoint(self.home)
        if result[0] is None:
            self._throttled_audit(f"endpoint:{result[1]}", phase="decision",
                                  resolved=resolved, to_state="unavailable",
                                  reason=result[1], batch_id=batch_id, trigger="self")
            self._set_items(items, "pending", next_at=time.time() + 30,
                            detail=f"unavailable:{result[1]}")
            return
        base, headers = result
        import aiohttp
        url = f"{base}/api/sessions/{resolved}/chat/stream"
        terminal, run_id, started = None, None, False
        t0 = time.time()
        try:
            timeout = aiohttp.ClientTimeout(total=600, sock_read=180)
            async with aiohttp.ClientSession(timeout=timeout) as sess:
                async with sess.post(url, json={"input": auto_wake.CANONICAL_INPUT,
                                                "wake_batch": batch_id},
                                     headers=headers) as resp:
                    if resp.status != 200:
                        state = await asyncio.to_thread(self._batch_state, batch_id)
                        if state == "reserved":
                            # Server proved no launch: safe to retry THIS batch.
                            self._set_items(items, "pending",
                                            next_at=time.time() + 15,
                                            detail=f"retry:{resp.status}")
                            return
                        self._set_items(items, "done", detail=f"http:{resp.status}:{state}")
                        await self._fail_note(resolved, f"http-{resp.status}")
                        audit(self.home, phase="terminal", resolved=resolved,
                              batch_id=batch_id, to_state=state,
                              reason=f"http-{resp.status}", trigger="self",
                              latency=time.time() - t0)
                        return
                    event = None
                    async for raw in resp.content:
                        line = raw.decode("utf-8", "replace").rstrip("\r\n")
                        if line.startswith("event: "):
                            event = line[7:]
                            if event == "approval.request":
                                self._throttled_audit(
                                    f"approval:{batch_id}", phase="waiting_for_approval",
                                    resolved=resolved, batch_id=batch_id, run_id=run_id,
                                    reason="manual-approval-pending", trigger="self")
                            if event in ("run.completed", "run.failed", "run.cancelled"):
                                terminal = event
                                break
                        elif event == "run.started" and line.startswith("data: "):
                            try:
                                payload = json.loads(line[6:])
                            except Exception:
                                payload = {}
                            run_id = payload.get("run_id")
                            if run_id and not started:
                                started = True
                                await asyncio.to_thread(
                                    report, self.home, batch_id=batch_id,
                                    resolved=resolved, state="accepted", run_id=run_id)
            if terminal is not None:
                await asyncio.to_thread(report, self.home, batch_id=batch_id,
                                        resolved=resolved, state="terminal")
                self._set_items(items, "done", detail=terminal)
                lineage = None
                try:
                    from hermes_state_registry import acquire, release_or_close
                    d = await asyncio.to_thread(acquire, self.home / "state.db")
                    try:
                        lineage = await asyncio.to_thread(lineage_root, d, resolved)
                    finally:
                        await asyncio.to_thread(release_or_close, d)
                except Exception:
                    pass
                if lineage:
                    if terminal == "run.completed":
                        await asyncio.to_thread(chain_note, self.home, lineage)
                    else:
                        await asyncio.to_thread(chain_fail, self.home, lineage, terminal)
                audit(self.home, phase="terminal", resolved=resolved, batch_id=batch_id,
                      run_id=run_id, to_state="terminal", reason=terminal, trigger="self",
                      latency=time.time() - t0)
                return
            # Stream ended/closed with no terminal frame: settle from the ledger.
            await self._settle_unseen(items, resolved, batch_id, run_id)
        except asyncio.CancelledError:
            # Shutdown: settle honestly, never optimistically.
            with suppress(Exception):
                await asyncio.shield(self._settle_unseen(items, resolved, batch_id, run_id))
            raise
        except Exception as exc:
            self._throttled_audit(f"dispatch-err:{type(exc).__name__}", phase="decision",
                                  resolved=resolved, batch_id=batch_id,
                                  reason=f"transport:{type(exc).__name__}", trigger="self")
            await self._settle_unseen(items, resolved, batch_id, run_id)

    async def _settle_unseen(self, items, resolved, batch_id, run_id):
        from . import auto_wake_store
        state = await asyncio.to_thread(self._batch_state, batch_id)
        if state in ("terminal", "uncertain-consumed"):
            self._set_items(items, "done", detail=state)
        elif state == "reserved":
            self._set_items(items, "pending", next_at=time.time() + 15,
                            detail="retry-after-close")
        else:
            # dispatching/accepted with an unfinished view: never re-POST.
            if state == "dispatching":
                await asyncio.to_thread(auto_wake_store.report, self.home,
                                        batch_id=batch_id, resolved=resolved,
                                        state="uncertain")
            self._set_items(items, "done", detail="uncertain-consumed")
            await self._fail_note(resolved, "stream-unseen-terminal")
            audit(self.home, phase="terminal", resolved=resolved, batch_id=batch_id,
                  run_id=run_id, to_state="uncertain", reason="stream-unseen-terminal",
                  trigger="self")

    async def _poll_run(self, batch_id, resolved):
        """Accepted batch whose SSE died: ask the run store; terminal → close
        as terminal, unknown → False (caller settles uncertain)."""
        result = endpoint(self.home)
        if result[0] is None:
            return False
        base, headers = result
        import aiohttp
        try:
            async with aiohttp.ClientSession() as sess:
                for _ in range(12):
                    async with sess.get(f"{base}/v1/runs/{batch_run(batch_id, self.home)}",
                                        headers=headers) as resp:
                        if resp.status != 200:
                            return False
                        payload = await resp.json()
                    if payload.get("status") in {"completed", "failed", "cancelled"}:
                        from . import auto_wake_store
                        await asyncio.to_thread(auto_wake_store.report, self.home,
                                                batch_id=batch_id, resolved=resolved,
                                                state="terminal")
                        return payload["status"]
                    await asyncio.sleep(5)
        except Exception:
            return False
        return False


def batch_run(batch_id, home):
    conn = _ledger(home)
    row = conn.execute("SELECT run_id FROM wake_batches WHERE batch_id = ?",
                       (batch_id,)).fetchone()
    return row["run_id"] if row is not None and row["run_id"] else ""


def _owner_token():
    import secrets
    return secrets.token_hex(8)


def arm_loop(loop, home):
    """Gateway loop capture (app platform connect). One worker per profile;
    hot reload re-arms the SAME singleton instead of stacking workers."""
    _module_state["loop"] = loop
    worker = _module_state.get("worker")
    if worker is None or Path(worker.home) != Path(home).resolve():
        if worker is not None:
            worker.stop()
        worker = SelfWakeWorker(home)
        _module_state["worker"] = worker
    worker.arm(loop)


def arm_stop():
    """Platform disconnect: cancel the loop task; the singleton survives so
    a reconnect re-arms without stacking."""
    worker = _module_state.get("worker")
    _module_state["loop"] = None
    if worker is not None:
        worker.stop()


def lineage_root(db, resolved):
    """The compression-lineage ROOT session: chain counters key on it so a
    rotation cannot launder the 3-wake budget."""
    current = resolved
    for _ in range(64):
        try:
            rows = db._read_all(
                "SELECT parent_session_id FROM sessions WHERE id = ?", (current,))
        except Exception:
            break
        if not rows or rows[0]["parent_session_id"] is None:
            break
        parent = rows[0]["parent_session_id"]
        try:
            prow = db._read_all("SELECT end_reason FROM sessions WHERE id = ?", (parent,))
        except Exception:
            break
        if not prow or (prow[0]["end_reason"] or "") != "compression":
            break
        current = parent
    return current
