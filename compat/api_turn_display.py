"""TASK-DISPLAYKIND: a person's HTTP turn persists as a user row, not an internal notification.

Under the session authority every API admission runs with ``event.internal = True``
(gateway/session_ingress.py, ``execute_admission``): "trust comes from the private
binding", so the turn passes the gateway's authorization. ``display_kind_for_event``
reads that same flag as "self-injected" and the owner's own chat/stream text lands as
``display_kind='internal_notification'``. The app then draws an internal-notice chip,
and because ``Message.isUserTurn`` requires ``display_kind == null`` the row is no turn
boundary either.

The flag itself must stay (clearing it would send the turn through authorization), so
this unit overrides only the kind, at the two points core already resolves late:

``prepare_api_execution`` sees the durable payload, the one place an API door's turn is
told apart from an automation row in the same session. It stamps the admission id on the
execution binding when the payload is a client's ``api_turn_v1`` turn.

``display_kind_for_event`` drops ``internal_notification`` only for that admission's own
event (``message_id`` is the admission id, the identity ``admission_display`` binds by).
A durable payload rather than request state, so a turn recovered after a restart decides
the same way.

Peer bot turns and hosted room dispatches stay as they are: both are ``api_turn_v1`` too,
but nobody typed them, and the kind also decides whether a bare silence marker may stay
silent (``silence_allowed``). Automation rows, heartbeats and hidden admissions never get
the stamp from here. Rows already written are not rewritten.

Drift: ``check`` reads the core functions at load and raises when a needle moved (the unit
is skipped, a loud ERROR names the seam, rows keep core's stamp). No core file is written.
"""
from __future__ import annotations

from functools import wraps
import inspect
import logging

log = logging.getLogger("hermes-app-compat.api_turn_display")

SOURCE_KIND = "internal_notification"
BINDING_KEY = "hermes_app_person_admission"

# (module, function path, needles) the decision above depends on.
SEAMS = (
    ("gateway.session_ingress", "execute_admission", (
        "from gateway.session_api_turn import api_execution, prepare_api_execution",
        "message_id=row['admission_id']",
        "prepared = prepare_api_execution(authority, ref, row['payload'])",
        "api_execution.set(prepared)",
        "event.internal = True",
    )),
    ("gateway.run_turn_prepare", "GatewayTurnPrepareMixin._hmwa_prepare_turn", (
        "from gateway.response_filters import display_kind_for_event",
        "persist_user_display_kind = display_kind_for_event(event)",
    )),
    ("gateway.response_filters", "display_kind_for_event", (
        'getattr(event, "internal", False) or getattr(event, "_heartbeat_session_id", None)',
        "return INTERNAL_NOTIFICATION_DISPLAY_KIND",
    )),
    ("gateway.session_api_turn", "_api_observers", (
        "authority.sessions[session_id].event_stream.execution",
        "execution.get('admission_id')",
    )),
    ("gateway.session_api_turn", "admit_api_steps", (
        "'api_turn_v1': {",
    )),
)


def check():
    """Load-time drift check; raises naming the first seam that moved."""
    import importlib
    for module_name, qualname, needles in SEAMS:
        target = importlib.import_module(module_name)
        for part in qualname.split("."):
            target = getattr(target, part, None)
            if target is None:
                raise RuntimeError(f"missing {module_name}.{qualname}")
        text = inspect.getsource(inspect.unwrap(target))
        for needle in needles:
            if needle not in text:
                raise RuntimeError(f"source changed: {module_name}.{qualname} ({needle})")


def is_person_turn(payload):
    """A client's API turn: not an automation row, not a peer bot, not a room dispatch."""
    data = payload.get("api_turn_v1") if isinstance(payload, dict) else None
    if not isinstance(data, dict):
        return False
    if (data.get("settings") or {}).get("room_dispatch") is not None:
        return False
    author = data.get("turn_author")
    return not (isinstance(author, dict) and author.get("is_bot"))


def install(tx):
    check()
    from gateway import response_filters, session_api_turn
    old_prepare = session_api_turn.prepare_api_execution
    old_kind = response_filters.display_kind_for_event
    api_execution = session_api_turn.api_execution

    @wraps(old_prepare)
    def prepare(authority, ref, payload):
        prepared = old_prepare(authority, ref, payload)
        if is_person_turn(payload):
            execution = authority.sessions[ref.session_id].event_stream.execution
            admission_id = execution.get("admission_id") if execution else None
            if admission_id:
                prepared[BINDING_KEY] = admission_id
        return prepared

    @wraps(old_kind)
    def display_kind(event):
        kind = old_kind(event)
        if kind != SOURCE_KIND or getattr(event, "_heartbeat_session_id", None):
            return kind
        current = api_execution.get()
        admission_id = current.get(BINDING_KEY) if current else None
        if admission_id and getattr(event, "message_id", None) == admission_id:
            return None
        return kind

    tx.set(session_api_turn, "prepare_api_execution", prepare)
    tx.set(response_filters, "display_kind_for_event", display_kind)
