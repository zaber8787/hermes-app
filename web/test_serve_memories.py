#!/usr/bin/env python3
"""R3c memory endpoints reverse-proxy suite (plain asyncio, like test_upstream).

    ~/.hermes/hermes-agent/venv/bin/python web/test_serve_memories.py

GET /api/memories + PUT /api/memories/{name}, tmp HOME via HERMES_WEB_HOME:
GET both files, PUT round-trip (Chinese + newlines + empty), whitelist
400/404, no key 401, atomic write leaves NO tmp file behind. MEMORY.md is
never touched on the real HOME by these tests.
"""
import asyncio
import contextlib
import os
import pathlib
import sys
import tempfile

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

KEY = "mm-test-key"
AUTH = {"Authorization": f"Bearer {KEY}"}


class Harness:
    """proxy on an ephemeral port; HOME + env file point at a tmp dir."""

    def __init__(self, tmp: pathlib.Path):
        (tmp / ".env").write_text(f"API_SERVER_KEY={KEY}\n", encoding="utf-8")
        (tmp / "memories").mkdir(exist_ok=True)
        self.saved = (serve.ENV_FILE, serve.API,
                      os.environ.get("HERMES_WEB_HOME"))
        serve.ENV_FILE = tmp / ".env"
        serve.API = "http://127.0.0.1:9"
        os.environ["HERMES_WEB_HOME"] = str(tmp)
        self.tmp = tmp

    async def __aenter__(self):
        # Guard (USER.md-incident): the memories dir MUST resolve inside this
        # harness tmp. A resolution-order regression that reads the operator's
        # real ~/.hermes/.env (or defaults to the real home) must fail HERE,
        # before any PUT can overwrite a real memory file.
        assert pathlib.Path(serve._memories_dir()).resolve().is_relative_to(
            self.tmp.resolve()), "memories dir escaped the harness tmp"
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
        serve.ENV_FILE, serve.API, saved_home = self.saved
        if saved_home is None:
            os.environ.pop("HERMES_WEB_HOME", None)
        else:
            os.environ["HERMES_WEB_HOME"] = saved_home

    def u(self, path=""):
        return f"http://127.0.0.1:{self.port}/api/memories{path}"


async def test_get_lists_both_files():
    with tempfile.TemporaryDirectory() as td:
        tmp = pathlib.Path(td)
        (tmp / "memories").mkdir()
        (tmp / "memories" / "MEMORY.md").write_text("記憶", encoding="utf-8")
        async with Harness(tmp) as h:
            async with h.client.get(h.u(), headers=AUTH) as r:
                assert r.status == 200
                j = await r.json()
            files = {f["name"]: f for f in j["files"]}
            assert set(files) == {"MEMORY.md", "USER.md"}
            assert files["MEMORY.md"]["content"] == "記憶"
            assert files["MEMORY.md"]["chars"] == 2
            assert files["MEMORY.md"]["limit"] == 2200
            assert files["MEMORY.md"]["mtime"]
            # missing USER.md: content null, chars 0 (contract)
            assert files["USER.md"]["content"] is None
            assert files["USER.md"]["chars"] == 0


async def test_put_round_trip_chinese_newlines_and_empty():
    body = "第一行\n第二行 with 中文 and emoji 🤖\n尾行\n"
    with tempfile.TemporaryDirectory() as td:
        tmp = pathlib.Path(td)
        async with Harness(tmp) as h:
            async with h.client.put(h.u("/USER.md"), json={"content": body},
                                    headers=AUTH) as r:
                assert r.status == 200
                j = await r.json()
                assert j["content"] == body and j["chars"] == len(body)
            assert (tmp / "memories" / "USER.md").read_text(
                encoding="utf-8") == body
            # GET agrees with disk (spec)
            async with h.client.get(h.u(), headers=AUTH) as r:
                files = {f["name"]: f for f in (await r.json())["files"]}
                assert files["USER.md"]["content"] == body
            # empty string = clear, allowed
            async with h.client.put(h.u("/USER.md"), json={"content": ""},
                                    headers=AUTH) as r:
                assert r.status == 200
                assert (await r.json())["chars"] == 0
            # no tmp residue from either write
            assert sorted(p.name for p in (tmp / "memories").iterdir()) == \
                ["USER.md"]


async def test_whitelist_and_paths():
    with tempfile.TemporaryDirectory() as td:
        tmp = pathlib.Path(td)
        async with Harness(tmp) as h:
            async with h.client.put(h.u("/OTHER.md"), json={"content": "x"},
                                    headers=AUTH) as r:
                assert r.status == 404, r.status  # valid name, not ours
            async with h.client.put(h.u("/..sneaky"), json={"content": "x"},
                                    headers=AUTH) as r:
                assert r.status == 400, r.status  # '..' anywhere: 400
            async with h.client.put(h.u("/a%5Cb.md"), json={"content": "x"},
                                    headers=AUTH) as r:
                assert r.status == 400, r.status  # backslash separator
            # encoded slash cannot match the {name} segment at all ->
            # falls through to the proxy (dead API here), never written.
            assert not any(p.name != ".env" and p.parent != tmp / "memories"
                           for p in tmp.rglob("*") if p.is_file())


async def test_no_key_401():
    with tempfile.TemporaryDirectory() as td:
        async with Harness(pathlib.Path(td)) as h:
            async with h.client.get(h.u()) as r:
                assert r.status == 401, r.status
            async with h.client.put(h.u("/USER.md"), json={"content": "x"}) as r:
                assert r.status == 401, r.status


async def test_bad_body_400():
    with tempfile.TemporaryDirectory() as td:
        async with Harness(pathlib.Path(td)) as h:
            async with h.client.put(h.u("/USER.md"), json={"content": 7},
                                    headers=AUTH) as r:
                assert r.status == 400, r.status


TESTS = [
    test_get_lists_both_files,
    test_put_round_trip_chinese_newlines_and_empty,
    test_whitelist_and_paths,
    test_no_key_401,
    test_bad_body_400,
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
