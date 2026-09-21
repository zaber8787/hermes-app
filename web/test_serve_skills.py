#!/usr/bin/env python3
"""R3b skills-toggle reverse-proxy suite (plain asyncio, like test_upstream.py).

    ~/.hermes/hermes-agent/venv/bin/python web/test_serve_skills.py

The PATCH handler imports hermes lazily; tests stub those modules through
sys.modules (tmp config, fake scans) so the real ~/.hermes/config.yaml is
never touched. Cases: toggle round-trip, essential 400, unknown 404,
no key 401, import failure 503, bad body 400. (GET is NOT tested here —
the app reads /v1/skills through the plain proxy; see R3b patch note.)
"""
import asyncio
import contextlib
import json
import os
import pathlib
import sys
import tempfile
import types

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from aiohttp import web, ClientSession  # noqa: E402

# Import hygiene (ENVHYGIENE §7.2): a temp selector so importing serve can
# NEVER read the operator's real ~/.hermes/.env — non-secret defaults come
# from safe fallbacks, keys come from each harness's own tmp file.
import os as _os, tempfile as _tf
if not (_os.environ.get("HERMES_ENV_FILE") or "").strip():
    _env_probe = _tf.NamedTemporaryFile(
        mode="w", suffix=".env", delete=False, prefix="serve-import-")
    _env_probe.write("API_SERVER_KEY=\n")
    _env_probe.close()
    _os.environ["HERMES_ENV_FILE"] = _env_probe.name
import serve  # noqa: E402

SKILLS = [
    {"name": "alpha", "description": "A skill", "category": "tools"},
    {"name": "zeta", "description": "Z skill", "category": None},
    {"name": "hermes-agent", "description": "core", "category": None},
]
KEY = "sk-test-key"


class Stubs:
    """tmp config + fake scan + real module names, restored on exit."""

    def __init__(self, *, disabled=None, essential=("hermes-agent",),
                 fail_import=None):
        self.disabled = set(disabled or ())
        self.essential = set(essential)
        self.fail_import = fail_import  # module name whose import breaks
        self.saved = {}

    def __enter__(self):
        for name in ("hermes_cli.config", "hermes_cli.skills_config",
                     "agent.skill_utils", "tools.skills_tool"):
            self.saved[name] = sys.modules.get(name)
        cfg = self

        config_mod = types.ModuleType("hermes_cli.config")
        config_mod.load_config = lambda: {"skills": {}}
        skills_mod = types.ModuleType("hermes_cli.skills_config")

        def get_disabled_skills(config, platform=None):
            return set(cfg.disabled)

        def save_disabled_skills(config, disabled, platform=None):
            cfg.disabled = set(disabled) - cfg.essential
        skills_mod.get_disabled_skills = get_disabled_skills
        skills_mod.save_disabled_skills = save_disabled_skills
        utils_mod = types.ModuleType("agent.skill_utils")
        utils_mod.ESSENTIAL_SKILLS = frozenset(cfg.essential)
        tool_mod = types.ModuleType("tools.skills_tool")

        def _find_all_skills(*, skip_disabled=False):
            return [dict(s) for s in SKILLS]
        tool_mod._find_all_skills = _find_all_skills
        sys.modules["hermes_cli.config"] = config_mod
        sys.modules["hermes_cli.skills_config"] = skills_mod
        sys.modules["agent.skill_utils"] = utils_mod
        sys.modules["tools.skills_tool"] = tool_mod
        if self.fail_import is not None:
            sys.modules[self.fail_import] = None  # import -> ImportError
        return self

    def __exit__(self, *exc):
        for name, mod in self.saved.items():
            if mod is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = mod


class Harness:
    def __init__(self, tmp):
        self.tmp = tmp
        self.saved = (serve.ENV_FILE, serve.API, serve.HERMES_WEB_HOME
                      if hasattr(serve, "HERMES_WEB_HOME") else None)
        env = tmp / ".env"
        env.write_text(f"API_SERVER_KEY={KEY}\n", encoding="utf-8")
        serve.ENV_FILE = env
        serve.API = "http://127.0.0.1:9"  # nothing legitimate proxies here

    async def __aenter__(self):
        app = serve.build_app()
        self.runner = web.AppRunner(app)
        await self.runner.setup()
        await web.TCPSite(self.runner, "127.0.0.1", 0).start()
        self.port = self.runner.addresses[0][1]
        self.client = ClientSession()
        return self

    async def __aexit__(self, *exc):
        await self.client.close()
        with contextlib.suppress(Exception):
            await asyncio.wait_for(self.runner.cleanup(), 10)
        serve.ENV_FILE = self.saved[0]
        serve.API = self.saved[1]


def url(h, name="alpha"):
    return f"http://127.0.0.1:{h.port}/api/skills/{name}"


AUTH = {"Authorization": f"Bearer {KEY}"}


async def test_round_trip_disable_enable():
    with tempfile.TemporaryDirectory() as td, Stubs() as st:
        async with Harness(pathlib.Path(td)) as h:
            async with h.client.patch(url(h), json={"enabled": False},
                                      headers=AUTH) as r:
                body = await r.json()
                assert r.status == 200, f"{r.status} {body}"
                assert body["name"] == "alpha" and body["enabled"] is False
                assert body["essential"] is False
                assert st.disabled == {"alpha"}, st.disabled
            # re-enable must NOT 404: existence is checked against the FULL
            # (skip_disabled=True) scan, otherwise turning a skill off would
            # lock it out of ever being turned on again.
            async with h.client.patch(url(h), json={"enabled": True},
                                      headers=AUTH) as r:
                body = await r.json()
                assert r.status == 200 and body["enabled"] is True, body
                assert st.disabled == set(), st.disabled


async def test_essential_400():
    with tempfile.TemporaryDirectory() as td, Stubs() as st:
        async with Harness(pathlib.Path(td)) as h:
            async with h.client.patch(url(h, "hermes-agent"),
                                      json={"enabled": False},
                                      headers=AUTH) as r:
                body = await r.json()
                assert r.status == 400, f"{r.status} {body}"
                assert body["error"]["message"] == \
                    "essential skills cannot be disabled", body
                assert st.disabled == set(), "essential must not be saved"


async def test_unknown_404():
    with tempfile.TemporaryDirectory() as td, Stubs():
        async with Harness(pathlib.Path(td)) as h:
            async with h.client.patch(url(h, "no-such-skill"),
                                      json={"enabled": True},
                                      headers=AUTH) as r:
                assert r.status == 404, r.status
                body = await r.json()
                assert "unknown skill" in body["error"]["message"]


async def test_no_key_401():
    with tempfile.TemporaryDirectory() as td, Stubs():
        async with Harness(pathlib.Path(td)) as h:
            async with h.client.patch(url(h), json={"enabled": True}) as r:
                assert r.status == 401, r.status
            async with h.client.patch(
                    url(h), json={"enabled": True},
                    headers={"Authorization": "Bearer wrong"}) as r:
                assert r.status == 401, r.status


async def test_import_failure_503():
    with tempfile.TemporaryDirectory() as td, Stubs(
            fail_import="hermes_cli.skills_config"):
        async with Harness(pathlib.Path(td)) as h:
            async with h.client.patch(url(h), json={"enabled": False},
                                      headers=AUTH) as r:
                body = await r.json()
                assert r.status == 503, f"{r.status} {body}"
                assert "unavailable" in body["error"]["message"]


async def test_bad_body_400():
    with tempfile.TemporaryDirectory() as td, Stubs():
        async with Harness(pathlib.Path(td)) as h:
            async with h.client.patch(url(h), json={"enabled": "yes"},
                                      headers=AUTH) as r:
                assert r.status == 400, r.status


async def test_proxy_path_untouched():
    """Non-PATCH methods on /api/skills* still go through the proxy (the
    special case must not shadow the generic route)."""
    async def fake(request):
        return web.json_response({"via": "fake"})

    fake_app = web.Application()
    fake_app.router.add_get("/api/skills", fake)
    runner = web.AppRunner(fake_app)
    await runner.setup()
    await web.TCPSite(runner, "127.0.0.1", 0).start()
    fake_port = runner.addresses[0][1]
    with tempfile.TemporaryDirectory() as td, Stubs():
        async with Harness(pathlib.Path(td)) as h:
            serve.API = f"http://127.0.0.1:{fake_port}"
            async with h.client.get(
                    f"http://127.0.0.1:{h.port}/api/skills") as r:
                assert r.status == 200
                assert (await r.json())["via"] == "fake"
    await runner.cleanup()


TESTS = [
    test_round_trip_disable_enable,
    test_essential_400,
    test_unknown_404,
    test_no_key_401,
    test_import_failure_503,
    test_bad_body_400,
    test_proxy_path_untouched,
]


async def run_suite():
    failed = []
    for t in TESTS:
        try:
            await asyncio.wait_for(t(), 60)
            print(f"PASS {t.__name__}")
        except BaseException:
            import traceback
            traceback.print_exc()
            failed.append(t.__name__)
    print(f"\n{len(TESTS) - len(failed)}/{len(TESTS)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(run_suite()))
