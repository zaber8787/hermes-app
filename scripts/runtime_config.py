#!/usr/bin/env python3
"""Shared stdlib-only env-file reader for hermes-app runtime, builds and tools.

Contract (ENVHYGIENE plan §3.1):

* selector: ``HERMES_ENV_FILE`` > legacy ``HERMES_WEB_ENV`` > ``$HOME/.hermes/.env``;
  two selectors resolving to DIFFERENT paths is a hard error — we never silently
  read two sources. Empty selectors count as unset. ``~`` expands; no other
  interpolation ever happens.
* resolution order for NON-SECRET names: process env > selected file > default.
  An empty string is legal for optional values and ILLEGAL for required ones
  (no silent fallback).
* ``API_SERVER_KEY`` is file-only by design (auth re-reads it per request);
  no process-env override exists for it, and this module never prints values.
* Parser: blank lines, whole-line ``#`` comments, optional ``export `` prefix,
  ``NAME=value``, trimmed ends, paired single/double quotes (quoted text is
  literal), a ``#`` comment after an UNQUOTED value. Unbalanced quotes, quoted
  multi-line values and duplicate definitions of a consumed name are errors
  naming only the variable. No shell expansion, substitution, eval or source.
* Errors name variables and kinds — they never echo values or whole lines.
"""
from __future__ import annotations

import os
import pathlib
import re

SELECTOR_VAR = "HERMES_ENV_FILE"
LEGACY_SELECTOR_VAR = "HERMES_WEB_ENV"
API_KEY_NAME = "API_SERVER_KEY"

_ASSIGN = re.compile(r"^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$")


class ConfigError(Exception):
    """Configuration problem; the message never contains values."""


def expand(path: str) -> pathlib.Path:
    return pathlib.Path(os.path.expanduser(path.strip()))


def select_env_file(environ: dict | None = None) -> pathlib.Path:
    env = os.environ if environ is None else environ
    picks = []
    for name in (SELECTOR_VAR, LEGACY_SELECTOR_VAR):
        raw = (env.get(name) or "").strip()
        if raw:
            picks.append(expand(raw).resolve())
    if len(picks) == 2 and picks[0] != picks[1]:
        raise ConfigError(
            f"{SELECTOR_VAR} and {LEGACY_SELECTOR_VAR} resolve to different "
            "files; unset one of them")
    if picks:
        return picks[0]
    home = env.get("HOME") or str(pathlib.Path.home())
    return pathlib.Path(home) / ".hermes" / ".env"


def _strip_comment(rest: str) -> str:
    # A '#' outside quotes starts an end-of-line comment; inside quotes the
    # character is literal.
    out, quote = [], None
    for ch in rest:
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
            out.append(ch)
        elif ch == "#":
            break
        else:
            out.append(ch)
    if quote:
        raise ConfigError("unbalanced quotes")
    return "".join(out)


def _unquote(value: str) -> tuple[str, bool]:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1], True
    if value and value[0] in "\"'":
        raise ConfigError("unbalanced quotes")
    return value, False


def parse_env_file(path: pathlib.Path,
                   names: set[str] | None = None) -> dict[str, str]:
    """Strictly parse one dotenv file. With ``names``, collect ONLY those keys
    (the allowlist contract: unrelated variables never reach us)."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ConfigError(
            f"env file unreadable ({exc.__class__.__name__})") from None
    found: dict[str, str] = {}
    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        # A quoted value that never closes on THIS line is a multi-line or
        # unterminated definition: _strip_comment flags it as unbalanced.
        rest = _strip_comment(line)
        match = _ASSIGN.match(rest)
        if not match:
            continue  # unrelated syntax from other services: ignored
        name, tail = match.group(1), match.group(2)
        value, quoted = _unquote(tail)
        if names is not None and name not in names:
            continue
        if name in found:
            raise ConfigError(f"variable {name!r} defined more than once")
        found[name] = value
    return found


def read_key(path: pathlib.Path, name: str = API_KEY_NAME) -> str | None:
    """Auth-side accessor: re-read on demand; unreadable file => None (fail
    closed with 401), NEVER a crash and NEVER a logged value."""
    try:
        return parse_env_file(path, {name}).get(name) or None
    except ConfigError:
        return None


class Resolver:
    """One snapshot: file parsed once (non-secret names); auth keys use
    :func:`read_key` directly so rotation stays live."""

    def __init__(self, environ: dict | None = None,
                 env_file: pathlib.Path | None = None) -> None:
        # None = LIVE os.environ lookups (a process may set HERMES_WEB_HOME
        # after import); an explicit dict is a fixed snapshot for tests.
        self._environ = environ
        env = self.environ
        self.selector_explicit = any(
            (env.get(k) or "").strip()
            for k in (SELECTOR_VAR, LEGACY_SELECTOR_VAR))
        self.path = env_file or select_env_file(env)
        self.exists = self.path.is_file()
        if self.exists:
            self._file: dict[str, str] | None = {}  # lazy below
        elif self.selector_explicit:
            raise ConfigError("selected env file is missing")
        else:
            self._file = None

    def _values(self, names: set[str]) -> dict[str, str]:
        if self._file is None:
            raise ConfigError("env file is missing")
        if not self._file and self.exists:
            self._file = parse_env_file(self.path, names)
        return self._file

    def resolve(self, name: str, *, default: str | None = None,
                required: bool = False,
                allowlist: set[str] | None = None) -> str:
        # The API key NEVER accepts a process-env override (§3.1.3): the
        # file (re-read per auth call) is its only source.
        from_env = "" if name == API_KEY_NAME else \
            (self.environ.get(name) or "").strip()
        if from_env:
            return from_env
        names = allowlist if allowlist is not None else {name}
        try:
            values = self._values(names)
        except ConfigError:
            if required or default is None:
                raise
            values = {}
        from_file = values.get(name)
        if from_file is not None:
            from_file = from_file.strip()
            if not from_file and required:
                raise ConfigError(f"{name}: empty value is invalid")
            if from_file:
                return from_file
        if default is not None and not required:
            return default
        if required:
            raise ConfigError(f"{name} is not configured")
        return default or ""

    @property
    def environ(self) -> dict:
        return os.environ if self._environ is None else self._environ

    def source(self, name: str) -> str:
        if (self.environ.get(name) or "").strip():
            return "env"
        try:
            if (self._values({name}).get(name) or "").strip():
                return "file"
        except ConfigError:
            pass
        return "default"

    def key_present(self) -> bool:
        return read_key(self.path) is not None


def validate_url(value: str, *, name: str, allow_path: bool = False) -> str:
    """http(s) URL with host, legal port, no userinfo/query/fragment; a
    trailing '/' is normalised away. ``allow_path=False`` also rejects any
    path (proxy upstream must be an origin)."""
    from urllib.parse import urlsplit
    try:
        parts = urlsplit(value)
        port = parts.port
        scheme = parts.scheme.lower()
    except ValueError:
        raise ConfigError(f"{name}: malformed URL") from None
    if scheme not in ("http", "https") or not parts.hostname:
        raise ConfigError(f"{name}: needs http(s) with a host")
    if parts.username or parts.password:
        raise ConfigError(f"{name}: userinfo is not allowed")
    if parts.query or parts.fragment:
        raise ConfigError(f"{name}: query/fragment are not allowed")
    if not allow_path and parts.path not in ("", "/"):
        raise ConfigError(f"{name}: a bare origin is required")
    if port is not None and not (1 <= port <= 65535):
        raise ConfigError(f"{name}: port out of range")
    return value[:-1] if value.endswith("/") else value
