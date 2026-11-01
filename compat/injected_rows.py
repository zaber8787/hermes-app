"""TASK-RENDERPARITY: app text injected into a Discord session reads as the owner's own turn.

crosssource.py delivers app chat aimed at a Discord session through
``PluginContext.inject_message``. Under the session authority core admits it as
an automation turn and persists the user row like every internal event:
``display_kind='internal_notification'`` (gateway/run_turn_prepare.py,
``display_kind_for_event``), the text decorated with the thread's sender prefix
(``[zaber] ...``). The app renders such a row as a collapsed "internal notice"
chip, and because ``Message.isUserTurn`` requires ``display_kind == null`` the
row is no turn boundary either: the reply never becomes that turn's final and
renders as run narration. An api_server conversation shows the same exchange
as a user bubble and a HERMES reply.

This unit wraps the static ``_message_response`` projection (the messages page
and every other reader of it) and fixes the row on the way out, storage
untouched: a user row whose ``display_metadata.gateway_input_owner`` is the
owner core minted for one of THIS plugin's admissions gets ``display_kind``
null, the admitted text as ``content`` (what the user typed in the app, as an
api_server row carries it), and a whitelisted ``crosssource_provenance`` block
naming the admission and the original display kind.

Identity, not text: core derives the owner as
``uuid5(NAMESPACE_URL, json.dumps([platform, profile, scope_id, chat_id,
thread_id, message_id]))`` (``_hmwa_prepare_turn``) and a plugin admission's
``message_id`` is its request identity ``["plugin", <plugin>, <key>, <uuid4>]``
(``_admit_plugin_injection``). The unit recomputes the owner from each such
row of ``session_admissions`` (read-only). A Discord user's own message, a
cron report, a background-process notice or a wake row never matches and stays
byte-identical.

Drift: ``check`` reads those core functions' source at load and raises when a
needle moved (the unit is skipped, a loud ERROR names the seam, rows keep the
native projection). A runtime read failure is logged at ERROR once per reason
and the row keeps the native projection. No core file is written.
"""
from __future__ import annotations

from collections import OrderedDict
from functools import wraps
import inspect
import json
import logging
from pathlib import Path
import sqlite3
import threading
import uuid

log = logging.getLogger("hermes-app-compat.injected_rows")

PLUGIN_ID = "hermes-app-compat"
# Compact JSON, exactly as core writes the identity (separators=(",", ":")).
IDENTITY_PREFIX = json.dumps(["plugin", PLUGIN_ID], separators=(",", ":"))[:-1] + ","
SOURCE_KIND = "internal_notification"
PROVENANCE_KEY = "crosssource_provenance"
# Owners already proven not ours. A row is read after its admission committed, so a
# miss is final; the cap only bounds memory.
MISS_CAP = 4096
_COLUMNS = {"seq", "admission_id", "request_id", "payload_json"}

# (function path, needles) the owner derivation above depends on.
SEAMS = (
    ("gateway.run_turn_prepare", "GatewayTurnPrepareMixin._hmwa_prepare_turn", (
        "namespace = [source.platform.value, source.profile, source.scope_id,",
        "source.chat_id, source.thread_id, str(event.message_id)]",
        "str(uuid.uuid5(uuid.NAMESPACE_URL, json.dumps(namespace)))",
        "persist_user_display_kind = display_kind_for_event(event)",
    )),
    ("gateway.run_turn", None, (
        '"gateway_input_owner": prepared.persistence_owner',
    )),
    ("gateway.run_plugin_injection", "GatewayPluginInjectionMixin._admit_plugin_injection", (
        'json.dumps(["plugin", plugin_id, session_key, uuid.uuid4().hex], separators=(",", ":"))',
        "message_id=identity",
    )),
    ("gateway.session_envelope", "_snapshot_native", (
        "envelope = {'source': encoded_source,",
        "'event': deepcopy({name: getattr(event, name) for name in _EVENT_FIELDS})",
        "payload = {'text': event.text, 'native_text_v1': envelope}",
    )),
)


def owner_of(payload):
    """The ``gateway_input_owner`` core mints for the turn of this admission payload, else ``None``."""
    native = payload.get("native_text_v1") if isinstance(payload, dict) else None
    source = native.get("source") if isinstance(native, dict) else None
    event = native.get("event") if isinstance(native, dict) else None
    if not isinstance(source, dict) or not isinstance(event, dict) or not event.get("message_id"):
        return None
    namespace = [source.get("platform"), source.get("profile"), source.get("scope_id"),
                 source.get("chat_id"), source.get("thread_id"), str(event["message_id"])]
    return str(uuid.uuid5(uuid.NAMESPACE_URL, json.dumps(namespace)))


def check():
    """Load-time drift check; raises naming the first seam that moved."""
    import importlib
    for module_name, qualname, needles in SEAMS:
        module = importlib.import_module(module_name)
        target = module
        for part in (qualname.split(".") if qualname else ()):
            target = getattr(target, part, None)
            if target is None:
                raise RuntimeError(f"missing {module_name}.{qualname}")
        text = inspect.getsource(inspect.unwrap(target))
        for needle in needles:
            if needle not in text:
                raise RuntimeError(f"source changed: {module_name}.{qualname or ''} ({needle})")
    from gateway.session import SessionSource
    if "profile" not in getattr(SessionSource, "_OPTIONAL_POST_SCOPE", ()):
        raise RuntimeError("source changed: SessionSource._OPTIONAL_POST_SCOPE (profile)")


class Admissions:
    """Owner -> ``(admission_id, text)`` for this plugin's admissions, read from ``state.db``."""

    def __init__(self, db_path):
        self.db_path = Path(db_path)
        self.lock = threading.Lock()
        self.owners = {}
        self.misses = OrderedDict()
        self.seq = 0
        self.columns_ok = False
        self.reported = set()

    def _report(self, reason):
        if reason not in self.reported:
            self.reported.add(reason)
            log.error("RENDERPARITY DEGRADED: %s; app-injected Discord rows keep the native "
                      "internal_notification projection", reason)

    def _refresh(self):
        if not self.db_path.is_file():
            return
        conn = sqlite3.connect(f"file:{self.db_path}?mode=ro", uri=True, timeout=2)
        try:
            if not self.columns_ok:
                have = {r[1] for r in conn.execute("PRAGMA table_info(session_admissions)")}
                if not _COLUMNS <= have:
                    raise RuntimeError(f"session_admissions columns drifted ({sorted(_COLUMNS - have)})")
                self.columns_ok = True
            rows = conn.execute(
                "SELECT seq, admission_id, CASE WHEN substr(request_id, 1, ?) = ? THEN payload_json END "
                "FROM session_admissions WHERE seq > ? ORDER BY seq",
                (len(IDENTITY_PREFIX), IDENTITY_PREFIX, self.seq)).fetchall()
        finally:
            conn.close()
        for seq, admission_id, raw in rows:
            self.seq = max(self.seq, seq)
            if raw is None:
                continue
            try:
                payload = json.loads(raw)
            except ValueError:
                continue
            owner = owner_of(payload)
            if owner is not None:
                text = payload.get("text")
                self.owners[owner] = (admission_id, text if isinstance(text, str) else None)

    def lookup(self, owner):
        with self.lock:
            hit = self.owners.get(owner)
            if hit is not None or owner in self.misses:
                return hit
            try:
                self._refresh()
            except Exception as exc:
                self._report(f"admission read failed ({type(exc).__name__}: {exc})")
                return None
            hit = self.owners.get(owner)
            if hit is None:
                self.misses[owner] = True
                while len(self.misses) > MISS_CAP:
                    self.misses.popitem(last=False)
            return hit


def _owner_of_row(row):
    meta = row.get("display_metadata")
    if isinstance(meta, str):
        try:
            meta = json.loads(meta)
        except ValueError:
            return None
    owner = meta.get("gateway_input_owner") if isinstance(meta, dict) else None
    return owner if isinstance(owner, str) and owner else None


def project(result, row, admissions):
    """The normalized projection of an app-injected user row; any other row is returned as is."""
    if not isinstance(row, dict) or row.get("role") != "user" or row.get("display_kind") != SOURCE_KIND:
        return result
    if result.get("display_kind") != SOURCE_KIND:
        return result  # an earlier projection already decided what this row is
    owner = _owner_of_row(row)
    hit = admissions.lookup(owner) if owner else None
    if hit is None:
        return result
    admission_id, text = hit
    out = {**result, "display_kind": None,
           PROVENANCE_KEY: {"schema": 1, "admission_id": admission_id, "display_kind": SOURCE_KIND}}
    content = result.get("content")
    # The persisted text carries the thread's sender prefix; the admitted text is what was typed.
    if text and isinstance(content, str) and content.endswith(text):
        out["content"] = text
    return out


def install(cls, tx, db_path):
    check()
    descriptor = inspect.getattr_static(cls, "_message_response")
    if not isinstance(descriptor, staticmethod):
        raise RuntimeError("_message_response is no longer static")
    old_message = descriptor.__func__
    admissions = Admissions(db_path)

    @wraps(old_message)
    def message(row):
        result = old_message(row)
        try:
            return project(result, row, admissions)
        except Exception as exc:
            admissions._report(f"projection failed ({type(exc).__name__})")
            return result
    tx.set(cls, "_message_response", staticmethod(message))
    return admissions
