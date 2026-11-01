"""Run-scoped durable steer inbox logic (STEERWEB R2/R3).

The App's cross-device steer must not depend on the client owning the live
SSE socket, and the core's memory-only `agent.steer()` buffer carries no
run-state check, no idempotency and no durable receipt. This module keeps the
durable ledger (steer_store) plus the live bindings the compat wrappers
consult:

* admission  — after auth/owner, before the accepted:true answer (compat
  route wrapper calls admit_request);
* run guard  — one lock per (adapter, run) shared by admission and the
  terminal/stop seal, so "admitted then sealed" and "sealed then 409" are the
  only interleavings;
* tool boundary — the wrapper around AIAgent._apply_pending_steer_to_tool_results
  calls on_tool_boundary AFTER the native behavior; only a fully returned
  tool batch tail is eligible, exactly one user row per batch;
* persist confirm — the wrapped _db_flush_write promotes a staged batch only
  from the committed row's exact metadata.

agent.steer() / native _pending_steer is never touched for a run the legacy
executor owns; that buffer stays the core's own business (R10 red line: no
bypass back into it).

TASK-STEERAUTH: on a core with a session authority every app turn runs in its
durable FIFO, so _active_run_agents never holds the chat-stream run's agent.
Admission then binds through the authority first (authority_binding): the run
id resolves to its admission (core's own run_admission, including the alias a
streaming request holds), only a started admission of the current generation
is admitted, and delivery is the core's native generation-fenced steer
(check_approval_generation + steer_agent under the session's event_stream
lock; before adoption the core latches it for that generation's agent). The
ledger only records the receipt (idempotency, read surfaces); it never queues,
claims or seals such a steer. _active_run_agents stays the fallback for runs
the legacy executor owns (/v1/runs without an admission).
"""
from __future__ import annotations

import threading
import uuid
import weakref

from . import steer_store

STEER_METADATA_FIELD = "hermes_app_steer"
STEER_METADATA_SCHEMA = 1
MAX_INPUT_BYTES = 8 * 1024
_BODY_BYTE_CAP = 64 * 1024
TERMINAL = frozenset({"completed", "failed", "cancelled", "interrupted"})
STEERABLE = frozenset({"running", "waiting_for_approval"})

_capability_on = False  # config-driven; the installer decides, set_capability is the kill switch
_inbox = None  # registry slot filled by open()


def set_capability(enabled: bool) -> None:
    global _capability_on
    _capability_on = bool(enabled)


def capability_enabled() -> bool:
    return _capability_on


def open_inbox(state, home_resolver=None):
    """Registry lives in the shared compat state so hot reload re-binds."""
    global _inbox
    inbox = state.get("steer_inbox")
    if inbox is None:
        inbox = {
            "lock": threading.RLock(),
            "epoch": state.get("activity_epoch"),
            "guards": {},
            "agent_runs": weakref.WeakKeyDictionary(),
            "adapters": weakref.WeakSet(),
            "closed": False,
            "home_resolver": home_resolver,
            "ready_hook": None,       # B4: notified on accepting false->true
            "watchers": {},           # (owner_scope, run_id) -> True (opt-in)
        }
        state["steer_inbox"] = inbox
    inbox["epoch"] = state.get("activity_epoch")
    inbox["closed"] = False
    _inbox = inbox
    return inbox


def registry():
    return _inbox


def home_of(inbox):
    resolver = inbox.get("home_resolver")
    if resolver is not None:
        return resolver()
    from hermes_constants import get_hermes_home
    return get_hermes_home()


def note_adapter(inbox, adapter):
    if inbox is None or inbox.get("closed"):
        return
    try:
        inbox["adapters"].add(adapter)
    except TypeError:
        pass


def run_guard(inbox, adapter, run_id):
    key = (id(adapter), run_id)
    with inbox["lock"]:
        guard = inbox["guards"].get(key)
        if guard is None:
            guard = threading.RLock()
            inbox["guards"][key] = guard
        return guard


def bind_agent(inbox, adapter, run_id, agent):
    if inbox is None or inbox.get("closed") or agent is None:
        return
    try:
        with inbox["lock"]:
            inbox["agent_runs"][agent] = (adapter, run_id)
        inbox["adapters"].add(adapter)
    except TypeError:
        pass


def _live_owner(adapter, run_id):
    try:
        return adapter._run_owners.get(run_id)
    except Exception:
        return None


def resolve_agent_run(inbox, agent):
    """agent -> (adapter, run_id, owner_scope) via the WeakKeyDictionary,
    falling back to an exact identity scan of the live adapters'
    _active_run_agents (the only bindings this inbox may ever serve)."""
    if inbox is None or inbox.get("closed"):
        return None
    with inbox["lock"]:
        hit = inbox["agent_runs"].get(agent)
        if hit is not None:
            adapter, run_id = hit
            return adapter, run_id, _live_owner(adapter, run_id)
        adapters = list(inbox["adapters"])
    for adapter in adapters:
        try:
            agents = getattr(adapter, "_active_run_agents", {}) or {}
        except Exception:
            continue
        for run_id, candidate in list(agents.items()):
            if candidate is agent:
                owner = _live_owner(adapter, run_id)
                with inbox["lock"]:
                    try:
                        inbox["agent_runs"][agent] = (adapter, run_id)
                    except TypeError:
                        pass
                return adapter, run_id, owner
    return None


# --------------------------------------------------------------------------
# admission (R2)
# --------------------------------------------------------------------------

def _verdict(status: str, *, agent, epoch_ok: bool):
    """Decision table WITHOUT side effects: (kind, code)."""
    if not epoch_ok:
        return "stale", "server_epoch"
    if status in TERMINAL:
        return "closed", "run_terminal"
    if status == "stopping":
        return "closed", "run_stopping"
    if status in ("queued",) or agent is None:
        return "not_ready", "run_not_bound"
    if status in STEERABLE:
        return "admit", status
    return "closed", "run_state_unknown"


_synthetic_resolver = None  # crosssource SyntheticRuns.resolve, set by its installer


def set_synthetic_resolver(resolver) -> None:
    global _synthetic_resolver
    _synthetic_resolver = resolver


def synthetic_run(adapter, run_id):
    """TASK-SYNTHRUN: the crosssource stream route's own run id (core never
    issued it) resolved to its Discord session's authority state, else None
    (every other id, or no resolver installed)."""
    resolver = _synthetic_resolver
    if resolver is None or not isinstance(run_id, str):
        return None
    return resolver(adapter, run_id)


def authority_binding(adapter, run_id):
    """(authority, admission row) when the core's session authority owns
    *run_id*: a /v1/runs admission by request id, or a streaming run through
    the alias its request holds while it observes the turn
    (session_api_turn.run_api_turn). None without an authority or for a run
    the legacy executor owns. RuntimeStoreError (duplicate admissions for one
    run) propagates: that ownership question has no answer.

    TASK-SYNTHRUN: a crosssource synthetic id binds to its session's
    admission, re-resolved here under the run guard."""
    synthetic = synthetic_run(adapter, run_id)
    if synthetic is not None:
        return synthetic.binding
    runner = getattr(adapter, "gateway_runner", None)
    if getattr(runner, "session_authority", None) is None:
        return None
    from gateway.platforms.api_server_authority_runs import run_admission
    return run_admission(adapter, run_id)


def _authority_verdict(adapter, run_id, row, status, *, epoch_ok):
    """Decision table for an authority-owned run: only a started admission
    (the session's running generation) admits; the generation itself is
    re-fenced at delivery under the session's stream lock."""
    if not epoch_ok:
        return "stale", "server_epoch"
    live = str((status or {}).get("status") or "")
    if live in TERMINAL:
        return "closed", "run_terminal"
    if live == "stopping" or run_id in (getattr(adapter, "_stopping_run_ids", None) or ()):
        return "closed", "run_stopping"
    state = row.get("status")
    if state == "started":
        return "admit", "running"
    if state == "queued":
        return "not_ready", "run_queued"
    if state == "terminal":
        return "closed", "run_terminal"
    return "closed", "run_state_unknown"


def steer_through_authority(authority, row, text) -> bool:
    """The core's native steer for this exact claim (the same sequence as
    api_server_runs._handle_steer_run): fence the generation and ask
    steer_agent under the session's event_stream lock, which adopt_agent also
    takes, so a steer racing adoption is either latched for the adopting agent
    or reaches the adopted one. Nothing here looks an agent up itself."""
    from gateway.session_contract import SessionRef
    from hermes_state_runtime import RuntimeStoreError
    sid, generation = row["target_session_id"], row["generation"]
    try:
        with authority.sessions[sid].event_stream.lock:
            authority.check_approval_generation(sid, generation)
            agent, latched = authority.steer_agent(
                SessionRef(authority.profile_id, sid), generation, text)
    except (KeyError, RuntimeStoreError):
        return False
    if latched:
        return True
    steer = getattr(agent, "steer", None)
    if not callable(steer):
        return False
    return bool(steer(text))


def _duplicate(store, inbox, owner_scope, run_id, client_request_id, input_text):
    # R2: the success-repeat lookup and authorization precede every
    # admission-state check, including retries after a terminal state.
    hit = _find_key(store, owner_scope, run_id, client_request_id)
    if hit is None:
        return None
    if hit["digest"] != steer_store.digest_of(input_text):
        return "conflict", {"code": "steer_identity_conflict"}
    return "duplicate", steer_store.receipt_of(hit, epoch=inbox["epoch"])


def _accepted_receipt(inbox, row, session_id):
    receipt = steer_store.receipt_of(row, epoch=inbox["epoch"])
    receipt["accepted"] = True
    receipt["state"] = "accepted"
    receipt["object"] = "hermes.run.steer"
    receipt["session_id"] = session_id
    return receipt


def _admit_via_authority(inbox, adapter, bound, *, run_id, owner_scope, status,
                         session_id, input_text, client_request_id, server_epoch):
    authority, row = bound
    status_map = getattr(adapter, "_run_statuses", None)
    live_status = status if status_map is None else status_map.get(run_id, status)
    kind, code = _authority_verdict(adapter, run_id, row, live_status,
                                    epoch_ok=(server_epoch in (None, inbox["epoch"])))
    store = steer_store.open_store(home_of(inbox))
    if owner_scope:
        dup = _duplicate(store, inbox, owner_scope, run_id, client_request_id, input_text)
        if dup is not None:
            return dup
    if kind != "admit":
        return kind, {"code": code}
    if owner_scope is None:
        return "closed", {"code": "run_not_bound"}
    gate = steer_store.handoff_gate(store, owner_scope, run_id, client_request_id)
    if gate == "expired":
        return "expired", {"steer_id": steer_store.derive_steer_id(
            owner_scope, run_id, client_request_id)}
    if gate == "closed":
        return "closed", {"code": "run_sealed"}
    sid = session_id or row.get("target_session_id")
    if not steer_through_authority(authority, row, input_text):
        return "closed", {"code": "run_not_accepting_steer"}
    receipt_row = steer_store.record_handoff(
        store, owner_scope, run_id, key=client_request_id, input_text=input_text,
        original_sid=sid, resolved_sid=row.get("target_session_id") or sid,
        owner_epoch=inbox["epoch"])
    return "accepted", _accepted_receipt(inbox, receipt_row, sid)


def admit_request(inbox, adapter, *, run_id, owner_scope, status, agent,
                  session_id, input_text, client_request_id, server_epoch):
    """Serialize admission with the run's seal under the exact run guard.

    01412 M9: the LIVE identity is re-read INSIDE the guard — a status/agent
    that vanished during the body await (unregister, terminal, stop) is
    caught here, and a stale pre-await snapshot can never vouch for it.

    TASK-STEERAUTH: an authority-owned run binds through the authority first;
    the _active_run_agents path below is the fallback for legacy runs."""
    guard = run_guard(inbox, adapter, run_id)
    with guard:
        try:
            bound = authority_binding(adapter, run_id)
        except Exception:
            return "closed", {"code": "run_state_unknown"}
        if bound is not None:
            return _admit_via_authority(
                inbox, adapter, bound, run_id=run_id, owner_scope=owner_scope,
                status=status, session_id=session_id, input_text=input_text,
                client_request_id=client_request_id, server_epoch=server_epoch)
        live_map = getattr(adapter, "_active_run_agents", None)
        live_agent = agent if live_map is None else live_map.get(run_id)
        status_map = getattr(adapter, "_run_statuses", None)
        live_status = status if status_map is None else status_map.get(run_id, status)
        if live_status is None and live_agent is not None:
            live_status = {"status": "running"}
        kind, code = _verdict(str((live_status or {}).get("status") or ""),
                              agent=live_agent,
                              epoch_ok=(server_epoch in (None, inbox["epoch"])))
        store = steer_store.open_store(home_of(inbox))
        if owner_scope:
            # Duplicate lookup FIRST (see _duplicate).
            dup = _duplicate(store, inbox, owner_scope, run_id, client_request_id, input_text)
            if dup is not None:
                return dup
        if kind != "admit":
            return kind, {"code": code}
        if owner_scope is None:
            return "closed", {"code": "run_not_bound"}
        steer_store.register_run(
            store, owner_scope, run_id, original_sid=session_id,
            resolved_sid=session_id, owner_epoch=inbox["epoch"])
        verdict, row = steer_store.admit(
            store, owner_scope, run_id, key=client_request_id,
            input_text=input_text, original_sid=session_id,
            resolved_sid=session_id, owner_epoch=inbox["epoch"])
        if verdict in ("duplicate", "conflict", "expired"):
            payload = steer_store.receipt_of(row, epoch=inbox["epoch"]) \
                if verdict != "conflict" else {"code": "steer_identity_conflict"}
            return verdict, payload
        if verdict == "queue_full":
            return "queue_full", {"code": "steer_queue_full"}
        if verdict == "closed":
            return "closed", {"code": "run_sealed"}
        return "accepted", _accepted_receipt(inbox, row, session_id)


def _find_key(store, owner_scope, run_id, key):
    with steer_store._LOCK, store:
        row = store.execute(
            "SELECT * FROM steers WHERE owner_scope=? AND run_id=? AND key=?",
            (owner_scope, run_id, key)).fetchone()
    return dict(row) if row else None


def listing(inbox, adapter, *, run_id, owner_scope, status, after_seq=0,
            limit=steer_store.PAGE_LIMIT):
    store = steer_store.open_store(home_of(inbox))
    rows, overflow = steer_store.list_steers(store, owner_scope, run_id,
                                             after_seq=after_seq, limit=limit) \
        if owner_scope else ([], False)
    run = steer_store.get_run(store, owner_scope, run_id) if owner_scope else None
    live = str((status or {}).get("status") or "")
    if run is not None and run["closed_reason"] is not None:
        accepting, reason = False, "closed"
    elif live in STEERABLE:
        accepting, reason = True, live
    elif not live:
        accepting, reason = False, "run_expired"
    elif live == "stopping":
        accepting, reason = False, "run_stopping"
    else:
        accepting, reason = False, "run_not_ready"
    revision = max([int(r["seq"]) for r in rows], default=0)
    if run is not None:
        revision = max(revision, int(run["next_seq"]) - 1)
    return {
        "object": "hermes.run.steer.list", "schema_version": 1,
        "run_id": run_id, "server_epoch": inbox["epoch"],
        "accepting": accepting, "accepting_reason": reason,
        "revision": revision, "overflow": bool(overflow),
        "steers": [steer_store.receipt_of(r, epoch=inbox["epoch"]) for r in rows],
    }


def receipt(inbox, *, owner_scope, run_id, steer_id):
    if not owner_scope:
        return None
    store = steer_store.open_store(home_of(inbox))
    row = steer_store.get_steer(store, owner_scope, run_id, steer_id)
    if row is None:
        return None
    return steer_store.receipt_of(row, epoch=inbox["epoch"])


# --------------------------------------------------------------------------
# seal + status observation
# --------------------------------------------------------------------------

def seal(inbox, adapter, run_id, reason):
    """Stop admission and new batch claims; retire UNCLAIMED accepted items.
    Staged batches stay staged so the persist-confirmation path (or restart
    recovery) can still reconcile them against committed history."""
    if inbox is None:
        return
    owner_scope = _live_owner(adapter, run_id)
    if owner_scope is None:
        with inbox["lock"]:
            for agent, (ad, rid) in list(inbox["agent_runs"].items()):
                if ad is adapter and rid == run_id:
                    owner_scope = _live_owner(ad, rid)
                    break
    if owner_scope is None:
        return  # nothing was ever admitted for this scope in this process
    guard = run_guard(inbox, adapter, run_id)
    with guard:
        store = steer_store.open_store(home_of(inbox))
        steer_store.seal_run(store, owner_scope, run_id, reason)


def observe_status(inbox, adapter, run_id, status):
    """Feed the accepting-transition hook (R5 steer.ready) without ever
    blocking or failing the status path itself."""
    hook = inbox.get("ready_hook") if inbox else None
    if hook is None:
        return
    try:
        key = (id(adapter), run_id)
        was = inbox.setdefault("accepting_last", {})
        now_accepting = str(status) in STEERABLE
        previous = was.get(key, False)
        was[key] = now_accepting
        if now_accepting and not previous:
            hook(adapter, run_id)
    except Exception:
        pass


# --------------------------------------------------------------------------
# tool-boundary injection (R3)
# --------------------------------------------------------------------------

def _persisted_marker():
    from agent.context_compressor import _DB_PERSISTED_MARKER
    return _DB_PERSISTED_MARKER


def _marker_shape():
    from agent import prompt_builder as pb
    return pb, pb.STEER_MARKER_OPEN + "\n", "\n" + pb.STEER_MARKER_CLOSE


def _tail_assistant_tools_complete(messages):
    """True when the tail is the completion of the newest assistant's tool
    batch: every tool_call id already has a role=tool result behind it."""
    last_assistant = None
    for i in range(len(messages) - 1, -1, -1):
        row = messages[i]
        if isinstance(row, dict) and row.get("role") == "assistant" and row.get("tool_calls"):
            last_assistant = i
            break
    if last_assistant is None:
        return False
    tail = messages[last_assistant + 1:]
    if not tail or not all(isinstance(r, dict) and r.get("role") == "tool" for r in tail):
        return False
    wanted = {c.get("id") for c in (messages[last_assistant].get("tool_calls") or [])
              if isinstance(c, dict) and c.get("id")}
    have = {r.get("tool_call_id") for r in tail}
    return bool(wanted) and wanted <= have


def on_tool_boundary(inbox, agent, messages, num_tool_msgs):
    """Called AFTER the native apply_pending_steer_to_tool_results, once per
    finished tool batch. Injects at most one standalone steer user row."""
    if inbox is None or not _capability_on or inbox.get("closed"):
        return
    resolved = resolve_agent_run(inbox, agent)
    if resolved is None:
        return
    adapter, run_id, owner_scope = resolved
    if owner_scope is None:
        owner_scope = _live_owner(adapter, run_id)
    guard = run_guard(inbox, adapter, run_id)
    from agent import prompt_builder as pb
    with guard:
        store = steer_store.open_store(home_of(inbox))
        run = steer_store.get_run(store, owner_scope, run_id) if owner_scope else None
        if run is None or run["closed_reason"] is not None:
            return
        if num_tool_msgs <= 0 or not messages:
            return
        tail = messages[-1]
        merge_row = None
        if isinstance(tail, dict) and tail.get("role") == "tool":
            if not _tail_assistant_tools_complete(messages):
                return
        elif (isinstance(tail, dict) and tail.get("role") == "user"
              and tail.get("display_kind") == pb.STEER_DISPLAY_KIND
              and not tail.get(_persisted_marker())):
            # The native gateway steer already appended THIS batch's row and it
            # is not persisted yet: merge into it (never into a persisted row).
            inner = _native_inner(tail.get("content") or "")
            if inner is None:
                return
            merge_row = (tail, inner)
        else:
            return  # plain user tail or unknown scaffolding: wait for the next safe batch
        batch_id = uuid.uuid4().hex
        items = steer_store.claim_batch(store, owner_scope, run_id, batch_id)
        if not items:
            return
        lines = [f"#{int(i['seq'])}: {i['input']}" for i in items]
        meta = {"schema": STEER_METADATA_SCHEMA, "run_id": run_id, "batch_id": batch_id,
                "items": [{"steer_id": i["steer_id"], "sequence": int(i["seq"]),
                           "input": i["input"]} for i in items]}
        if merge_row is not None:
            row, inner = merge_row
            row["content"] = pb.format_steer_marker(inner + "\n" + "\n".join(lines)).lstrip()
            merged = dict(row.get("display_metadata") or {})
            merged[STEER_METADATA_FIELD] = meta
            row["display_metadata"] = merged
            return
        row = pb.steer_user_row("\n".join(lines))
        row["display_metadata"] = {STEER_METADATA_FIELD: meta}
        messages.append(row)


def _native_inner(content):
    pb, opener, closer = _marker_shape()
    if not content.startswith(opener) or not content.endswith(closer):
        return None
    return content[len(opener):-len(closer)]


# --------------------------------------------------------------------------
# persist confirmation (R3 item 4)
# --------------------------------------------------------------------------

def confirm_flushed_rows(inbox, batch_rows):
    if inbox is None:
        return
    store = None
    for row in batch_rows or ():
        if not isinstance(row, dict):
            continue
        block = (row.get("display_metadata") or {}).get(STEER_METADATA_FIELD) \
            if isinstance(row.get("display_metadata"), dict) else None
        if not isinstance(block, dict) or int(block.get("schema") or 0) != STEER_METADATA_SCHEMA:
            continue
        batch_id = block.get("batch_id")
        if not isinstance(batch_id, str) or not batch_id:
            continue
        if store is None:
            store = steer_store.open_store(home_of(inbox))
        if row.get("_row_id") is None:
            # Committed but identity unconfirmed: leave the batch staged so
            # recovery reconciles by exact metadata instead of lying.
            continue
        steer_store.confirm_batch(store, batch_id, row["_row_id"])


# --------------------------------------------------------------------------
# restart recovery (R3 item 7) — never replays into a new run
# --------------------------------------------------------------------------

def _live_run_ids(inbox):
    """run_ids THIS process still has a live agent binding for. After a real
    restart nothing qualifies (empty registry); a hot reload keeps exactly
    the runs whose agents are still bound."""
    live = set()
    try:
        with inbox["lock"]:
            adapters = list(inbox["adapters"])
            bound = [rid for _agent, (_ad, rid) in inbox["agent_runs"].items()]
    except Exception:
        return live
    live.update(bound)
    for adapter in adapters:
        try:
            live.update((getattr(adapter, "_active_run_agents", {}) or {}).keys())
        except Exception:
            continue
    return live


def durable_run(inbox, *, owner_scope, run_id) -> bool:
    """Does the durable sidecar hold a run for THIS owner (01412 M7)? A
    TTL-expired native status never erases the receipts' right to answer."""
    if not owner_scope:
        return False
    store = steer_store.open_store(home_of(inbox))
    return steer_store.get_run(store, owner_scope, run_id) is not None


def recover(inbox):
    store = steer_store.open_store(home_of(inbox))
    repaired = {"delivered": 0, "outcome_unknown": 0, "retired": 0}
    # 01412 M8 / PLAN:91: an ACCEPTED item of a run with no live binding in
    # THIS process can never be injected again (its process died). Seal the
    # run so the item honestly ends as not_delivered — never replayed into a
    # new run, never left pretending to be queued forever.
    live = _live_run_ids(inbox)
    for owner_scope, run_id in steer_store.accepted_runs(store):
        if run_id in live:
            continue
        run = steer_store.get_run(store, owner_scope, run_id)
        if run is not None and run["closed_reason"] is not None:
            continue  # already sealed; the seal retired its accepted items
        steer_store.seal_run(store, owner_scope, run_id, "restart_stale_epoch")
        repaired["retired"] += 1
    for batch in steer_store.staged_batches(store):
        evidence = _find_committed_batch(store, batch["owner_scope"],
                                         batch["run_id"], batch["batch_id"])
        if evidence is not None:
            steer_store.confirm_batch(store, batch["batch_id"], evidence)
            repaired["delivered"] += 1
        else:
            steer_store.mark_outcome_unknown(store, batch["batch_id"], "restart_unconfirmed")
            repaired["outcome_unknown"] += 1
    steer_store.prune_expired(store)
    return repaired


def _find_committed_batch(store, owner_scope, run_id, batch_id):
    """Exact batch_id scan over the run's registered session lineage through the
    PUBLIC SessionDB read API; conservative: anything unclear reports None."""
    run = steer_store.get_run(store, owner_scope, run_id)
    sid = (run or {}).get("resolved_sid") or (run or {}).get("original_sid")
    if not sid:
        return None
    try:
        from hermes_state import SessionDB
        db = SessionDB(read_only=True)
        try:
            for row in db.get_messages(sid, include_inactive=True, include_compacted=True):
                meta = row.get("display_metadata")
                block = meta.get(STEER_METADATA_FIELD) if isinstance(meta, dict) else None
                if (isinstance(block, dict) and block.get("batch_id") == batch_id
                        and int(block.get("schema") or 0) == STEER_METADATA_SCHEMA
                        and row.get("id") is not None):
                    return row["id"]
        finally:
            close = getattr(db, "close", None)
            if callable(close):
                close()
    except Exception:
        return None
    return None
