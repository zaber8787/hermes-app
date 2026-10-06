"""P5-1 app platform registration + delivery identity.

The `app` platform addresses an ACTIVE-PROFILE HTTP session directly:
``deliver="app:<exact_session_id>"``. Registration is per-plugin-context (each
profile-scoped manager owns its lease); sending runs through the reviewed
bridge store only — never a model turn, never a Discord fallback.
"""
from __future__ import annotations

import asyncio
import contextvars
import dataclasses
from contextlib import suppress
import logging
import re
from typing import Any, Optional

log = logging.getLogger("hermes-app-compat.app")

PLATFORM_NAME = "app"
CRON_DELIVER_ENV_VAR = "HERMES_APP_HOME_SESSION"
# Exact session ids only: no empty value, no thread suffix, no path/URL/profile
# syntax, no control characters. Hermes session ids are opaque tokens, not just
# UUIDs, so this is the real SessionDB character contract.
SID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,255}\Z")

# Set by compat's _standalone_send wrapper (fingerprint-gated) around the
# upstream call; the standalone sender reads it. Process-global "current job"
# is never consulted.
DELIVERY_IDENTITY: contextvars.ContextVar[Optional[dict]] = contextvars.ContextVar(
    "hermes_app_cron_delivery_identity", default=None)


def parse_app_session_ref(ref: str):
    """``(session_id, None)`` for an exact id, else None (never guess)."""
    if not isinstance(ref, str) or not SID_RE.fullmatch(ref):
        return None
    return ref, None


def validate_app_session_ref(ref: str):
    parsed = parse_app_session_ref(ref)
    if parsed is not None:
        return True
    if not isinstance(ref, str) or not ref:
        return "app targets need an exact session id"
    if ":" in ref:
        return "app targets take no channel/thread suffix"
    if "://" in ref or "/" in ref or "\\" in ref:
        return "app targets take a bare session id, not a path or URL"
    if any(ord(ch) < 0x21 or ord(ch) == 0x7f for ch in ref):
        return "app targets take no whitespace or control characters"
    return "app targets need an exact session id"


def check_app_dependencies() -> bool:
    """PASSIVE probe (status displays call it freely): stdlib + SessionDB only."""
    import importlib.util
    return importlib.util.find_spec("hermes_state") is not None


def validate_app_config(config) -> bool:
    extra = getattr(config, "extra", None)
    return extra is None or isinstance(extra, dict)


def app_delivery_configured(config) -> bool:
    """Configured/local-service availability — NOT human presence."""
    from . import cron_delivery_store
    return cron_delivery_store.bindings_ready()


@dataclasses.dataclass(frozen=True)
class DeliveryEnvelope:
    """One execution's delivery identity; the same execution retrying yields the
    same key, a NEW execution of identical text is a distinct valid report."""
    home: str
    job_id: str
    execution_id: str
    session_id: str
    content_digest: str

    @property
    def key(self) -> str:
        from . import cron_delivery_store
        return cron_delivery_store.delivery_key(home=self.home, job_id=self.job_id,
                                                execution_id=self.execution_id,
                                                session_id=self.session_id)

    @classmethod
    def from_send(cls, *, session_id: str, content: str) -> "DeliveryEnvelope":
        from hermes_constants import get_hermes_home
        identity = DELIVERY_IDENTITY.get()
        if not identity:
            raise ValueError("missing_execution_identity")
        return cls(home=str(get_hermes_home().resolve()), job_id=identity["job_id"],
                   execution_id=identity["execution_id"], session_id=session_id,
                   content_digest=cron_digest(content))


def cron_digest(content: str) -> str:
    from . import cron_delivery_store
    return cron_delivery_store.report_digest(content)


class AppDeliveryAdapter:
    """Send-only methods; composed onto the base adapter at factory time.

    ``supports_async_delivery`` is declared so the cron origin-eligibility table
    sees a push-capable surface, while the api server's own False stays
    untouched. The heavy base import happens at factory time, never at plugin
    import.
    """

    supports_async_delivery = True

    async def connect(self, *, is_reconnect: bool = False) -> bool:
        from . import cron_delivery_store, self_wake
        from hermes_constants import get_hermes_home
        self._stopping = asyncio.Event()
        home = get_hermes_home()
        cron_delivery_store.drain_home(home)  # resume what a restart left queued
        self._drainer = asyncio.create_task(self._drain_loop(),
                                           name="hermes-app-cron-drainer")
        # SELFWAKE: the gateway owns the worker; arming is mode-agnostic and
        # cheap — wake.selfwake decides inside every tick (fail closed off).
        self_wake.arm_loop(asyncio.get_running_loop(), home)
        log.info("app platform connected; cron drainer armed for %s", home)
        return True

    async def disconnect(self) -> None:
        from . import self_wake
        if getattr(self, "_stopping", None) is not None:
            self._stopping.set()
        self_wake.arm_stop()
        drainer = getattr(self, "_drainer", None)
        if drainer is not None:
            self._drainer = None
            drainer.cancel()
            with suppress(asyncio.CancelledError, Exception):
                await drainer

    async def _drain_loop(self) -> None:
        from . import cron_delivery_store, self_wake
        from hermes_constants import get_hermes_home
        while not self._stopping.is_set():
            try:
                await asyncio.wait_for(self._stopping.wait(),
                                       timeout=cron_delivery_store.DRAIN_INTERVAL)
                return
            except asyncio.TimeoutError:
                pass
            try:
                home = get_hermes_home()
                summary = await asyncio.to_thread(cron_delivery_store.drain_home, home)
                if summary.get("delivered") or summary.get("failed"):
                    log.info("cron bridge drain: %s", summary)
                # SELFWAKE drainer-drained hook: fresh-delivered batches only
                # (dedup is counted separately and never wakes anything).
                self_wake.drainer_drained(home, summary)
            except Exception as exc:
                log.warning("cron bridge drain failed: %s", type(exc).__name__)

    async def send(self, chat_id: str, content: str, reply_to: Any = None,
                   metadata: Any = None):
        from . import cron_delivery_store
        from gateway.platforms.base import SendResult
        identity = self._identity_from(metadata, chat_id)
        outcome = await asyncio.to_thread(cron_delivery_store.deliver,
                                          session_id=str(chat_id), content=content,
                                          identity=identity)
        return self._to_send_result(outcome, str(chat_id))

    async def get_chat_info(self, chat_id: str) -> dict:
        return {"name": f"App session {chat_id}", "type": "session"}

    @staticmethod
    def _identity_from(metadata: Any, chat_id: str) -> Optional[dict]:
        # Live lane: compat's _live_route_metadata wrapper stamped the app
        # branch. Standalone lane: the ContextVar set around _standalone_send.
        if isinstance(metadata, dict):
            identity = metadata.get("hermes_app_cron_identity")
            if isinstance(identity, dict):
                return identity
        return DELIVERY_IDENTITY.get()

    @staticmethod
    def _to_send_result(outcome: dict, chat_id: str):
        from gateway.platforms.base import SendResult
        if outcome["status"] in ("delivered", "dedup"):
            return SendResult(success=True, message_id=str(outcome["row_id"]))
        if outcome["status"] == "queued":
            # Queued is NOT delivered: no fake message_id. raw_response carries
            # the positive receipt evidence; the durable receipt + the cron
            # queued outcome tell the ledger truth.
            return SendResult(success=True, message_id=None,
                              raw_response={"queued": True, "receipt": outcome["receipt"]})
        error = outcome.get("error", "unknown")
        if outcome.get("permanent"):
            return SendResult(success=False, error=f"app target refused ({error})")
        return SendResult(success=False, error=f"app delivery not delivered ({error})")


async def standalone_app_send(pconfig, chat_id: str, message: str, *, thread_id=None,
                              media_files=None, force_document=False) -> dict:
    """Out-of-process sender sharing the live writer/dedup path.

    Identity comes ONLY from the ContextVar set by compat's fingerprinted
    ``_standalone_send`` wrapper; a bare manual call fails closed instead of
    inventing a key or rerouting to Discord.
    """
    from . import cron_delivery_store
    if thread_id:
        return {"error": "app targets take no thread suffix"}
    identity = DELIVERY_IDENTITY.get()
    outcome = await asyncio.to_thread(cron_delivery_store.deliver,
                                      session_id=str(chat_id), content=message,
                                      identity=identity, media_files=media_files)
    if outcome["status"] in ("delivered", "dedup"):
        return {"success": True, "message_id": str(outcome["row_id"])}
    if outcome["status"] == "queued":
        # Queued is NOT delivered: no fake message_id; the durable receipt and
        # the cron queued outcome carry the truth.
        return {"success": True, "queued": True, "receipt": outcome["receipt"]}
    return {"error": f"app standalone send failed ({outcome.get('error', 'unknown')})"}


_COMPOSED = None


def adapter_class():
    """Compose the send-only methods onto BasePlatformAdapter, at factory time
    (never at plugin import): the gateway runner keeps its isinstance contract,
    the DB is opened lazily by the first send."""
    global _COMPOSED
    if _COMPOSED is None:
        from gateway.config import Platform
        from gateway.platforms.base import BasePlatformAdapter

        class _Composed(AppDeliveryAdapter, BasePlatformAdapter):
            supports_async_delivery = True

            def __init__(self, config):
                BasePlatformAdapter.__init__(self, config, Platform("app"))
                self._drainer = None
                self._stopping = None
        _COMPOSED = _Composed
    return _COMPOSED


def _entry_fields() -> dict:
    """Capability-gated entry kwargs: every field we use must exist (additive
    upstream fields are allowed; a missing used field refuses registration)."""
    from gateway.platform_registry import PlatformEntry
    available = {f.name for f in dataclasses.fields(PlatformEntry)}
    wanted = {"cron_deliver_env_var", "parse_target_ref_fn", "validate_target_ref_fn",
              "standalone_sender_fn", "is_connected", "max_message_length", "pii_safe",
              "emoji", "allow_update_command", "platform_hint"}
    missing = wanted - available
    if missing:
        raise RuntimeError(f"PlatformEntry fields missing: {sorted(missing)}")
    return {
        "cron_deliver_env_var": CRON_DELIVER_ENV_VAR,
        "parse_target_ref_fn": parse_app_session_ref,
        "validate_target_ref_fn": validate_app_session_ref,
        "standalone_sender_fn": standalone_app_send,
        "is_connected": app_delivery_configured,
        "max_message_length": 0, "pii_safe": False, "emoji": "📱",
        "allow_update_command": False, "platform_hint": "",
    }


def register(ctx) -> bool:
    """Register the app platform on THIS context's profile scope.

    Ownership gate first (registry.register is last-writer-wins — we must not
    clobber another plugin); ``source``/``plugin_name`` are filled by the API,
    so they are never passed here. Returns False (never raises) when the name
    is occupied or the platform API cannot carry our fields.
    """
    from gateway.platform_registry import platform_registry
    current = platform_registry.get(PLATFORM_NAME)
    if current is not None and (current.source != "plugin"
                                or current.plugin_name != "hermes-app-compat"):
        log.warning("app platform registration refused: name occupied by %s/%s",
                    current.source, current.plugin_name or "-")
        return False
    try:
        entry_kwargs = _entry_fields()
    except Exception as exc:
        log.warning("app platform registration refused: %s", exc)
        return False
    handle = ctx.register_platform(
        name=PLATFORM_NAME, label="Hermes App",
        adapter_factory=lambda config: adapter_class()(config),
        check_fn=check_app_dependencies,
        validate_config=validate_app_config,
        required_env=[],
        install_hint="Enable the compatible hermes-app-compat cron bridge",
        **entry_kwargs)
    if handle is None:
        log.warning("app platform registration refused: register_platform returned None")
        return False
    return True
