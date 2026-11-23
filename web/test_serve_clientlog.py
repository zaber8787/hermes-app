#!/usr/bin/env python3
"""TASK-WEBUX3-01 POST /clientlog suite (plain asyncio, like test_upstream).

    .venv-web/bin/python3 web/test_serve_clientlog.py

Auth first, then the 64 KiB self-gate (declared AND chunked read -> 413);
record-level 4 KiB drops stay 2xx; field/value whitelists keep tokens off
the file; byte-wise head-truncating rotation at 2 MiB down to 1 MiB. HOME
via HERMES_WEB_HOME into a tmp dir, one app per test, strictly sequential
(serve module globals would collide under asyncio.gather).
"""
import asyncio
import contextlib
import json
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

FAKE_BEARER = "cl-test-key"
AUTH = {"Authorization": f"Bearer {FAKE_BEARER}"}
# publish.sh:29 STAMP shape — an underlined marker would fail the value
# regex server-side and make the tests green for the wrong reason.
STAMP = "20261123T000000Z"


def rec(ts, kind="boot-timeout", build=STAMP):
    return {"ts": ts, "kind": kind, "build": build}


class Harness:
    """proxy on an ephemeral port; HOME + env file point at a tmp dir."""

    def __init__(self, tmp: pathlib.Path):
        (tmp / ".env").write_text(f"API_SERVER_KEY={FAKE_BEARER}\n", encoding="utf-8")
        self.saved = (serve.ENV_FILE, serve.API,
                      os.environ.get("HERMES_WEB_HOME"))
        serve.ENV_FILE = tmp / ".env"
        serve.API = "http://127.0.0.1:9"
        os.environ["HERMES_WEB_HOME"] = str(tmp)
        self.tmp = tmp
        self.path = tmp / "logs" / "web-client-log.jsonl"

    async def __aenter__(self):
        # Guard (USER.md-incident): the jsonl MUST resolve inside this
        # harness tmp. A resolution-order regression that writes the
        # operator's real ~/.hermes/logs must fail HERE, before anything
        # is appended outside the sandbox.
        assert pathlib.Path(serve._clientlog_path()).resolve().is_relative_to(
            self.tmp.resolve()), "clientlog path escaped the harness tmp"
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

    def u(self, query=""):
        return f"http://127.0.0.1:{self.port}/clientlog{query}"

    def lines(self):
        return self.path.read_bytes().decode("utf-8").splitlines()


async def test_append_ok():
    with tempfile.TemporaryDirectory() as td:
        tmp = pathlib.Path(td)
        async with Harness(tmp) as h:
            async with h.client.post(h.u(), json={"records": [rec(1), rec(2)]},
                                     headers=AUTH) as r:
                assert r.status == 200, r.status
                j = await r.json()
                assert j["accepted"] == 2 and j["dropped"] == 0, j
            assert h.path.resolve().is_relative_to(tmp.resolve())
            got = [json.loads(line) for line in h.lines()]
            assert [g["ts"] for g in got] == [1, 2], got
            assert all(g["kind"] == "boot-timeout" for g in got)


async def test_declared_413():
    with tempfile.TemporaryDirectory() as td:
        async with Harness(pathlib.Path(td)) as h:
            big = json.dumps({"records": [rec(1)], "pad": "x" * (70 * 1024)})
            async with h.client.post(h.u(), data=big, headers=AUTH) as r:
                assert r.status == 413, r.status


async def test_chunked_413():
    with tempfile.TemporaryDirectory() as td:
        async with Harness(pathlib.Path(td)) as h:
            async def gen():  # no Content-Length -> the counting gate reads
                yield b'{"records":["' + b"x" * (70 * 1024) + b'"]}'
            async with h.client.post(h.u(), data=gen(), headers=AUTH) as r:
                assert r.status == 413, r.status
            assert not h.path.exists()


async def test_401_no_or_wrong_token():
    with tempfile.TemporaryDirectory() as td:
        async with Harness(pathlib.Path(td)) as h:
            async with h.client.post(h.u(), json={"records": [rec(1)]}) as r:
                assert r.status == 401, r.status
            async with h.client.post(
                    h.u(), json={"records": [rec(1)]},
                    headers={"Authorization": "Bearer wrong"}
            ) as r:
                assert r.status == 401, r.status
            # auth runs BEFORE the body read: an unauthenticated oversized
            # POST is a 401, not a 413 (order is the spec)
            big = json.dumps({"records": [rec(1)], "pad": "x" * (70 * 1024)})
            async with h.client.post(h.u(), data=big) as r:
                assert r.status == 401, r.status
            assert not h.path.exists()


async def test_oversize_record_dropped_2xx():
    fat = dict(rec(2), build=STAMP + "-" + "z" * 5000)
    with tempfile.TemporaryDirectory() as td:
        async with Harness(pathlib.Path(td)) as h:
            async with h.client.post(
                    h.u(), json={"records": [rec(1), fat, rec(3)]},
                    headers=AUTH) as r:
                assert r.status == 200, r.status
                j = await r.json()
                assert j == {"accepted": 2, "dropped": 1}, j
            assert [json.loads(x)["ts"] for x in h.lines()] == [1, 3]


async def test_dirty_fields_stripped():
    dirty = {"ts": 5, "kind": "token=LEAK", "url": "https://x/#token=LEAK",
             "build": STAMP}
    with tempfile.TemporaryDirectory() as td:
        async with Harness(pathlib.Path(td)) as h:
            async with h.client.post(
                    h.u(), json={"records": [dirty, rec(6)]},
                    headers=AUTH) as r:
                assert r.status == 200, r.status
            blob = h.path.read_bytes().decode("utf-8")
            assert "token=" not in blob and "LEAK" not in blob, blob
            assert len([json.loads(x) for x in h.lines()]) == 2


async def test_query_ignored():
    with tempfile.TemporaryDirectory() as td:
        async with Harness(pathlib.Path(td)) as h:
            async with h.client.post(h.u("?token=LEAK"),
                                     json={"records": [rec(7)]},
                                     headers=AUTH) as r:
                assert r.status == 200, r.status
            blob = h.path.read_bytes().decode("utf-8")
            assert "LEAK" not in blob, blob


async def test_bad_shape_400():
    with tempfile.TemporaryDirectory() as td:
        async with Harness(pathlib.Path(td)) as h:
            async with h.client.post(h.u(), json={"records": "nope"},
                                     headers=AUTH) as r:
                assert r.status == 400, r.status
            async with h.client.post(h.u(), json={"nope": []},
                                     headers=AUTH) as r:
                assert r.status == 400, r.status
            assert not h.path.exists()


async def test_rotation_readable():
    with tempfile.TemporaryDirectory() as td:
        tmp = pathlib.Path(td)
        (tmp / "logs").mkdir()
        filler = tmp / "logs" / "web-client-log.jsonl"
        with open(filler, "w", encoding="utf-8") as fh:
            for i in range(40000):  # ~2.3 MiB: past the 2 MiB rotation gate
                fh.write(json.dumps(rec(i)) + "\n")
        assert filler.stat().st_size > 2 * 1024 * 1024
        async with Harness(tmp) as h:
            async with h.client.post(
                    h.u(), json={"records": [rec(987654321)]},
                    headers=AUTH) as r:
                assert r.status == 200, r.status
        data = filler.read_bytes()
        assert len(data) <= 1024 * 1024, len(data)
        rows = [json.loads(line) for line in
                data.decode("utf-8").splitlines()]
        assert rows[-1]["ts"] == 987654321, rows[-1]
        # rotation is tmp+os.replace: no tmp residue in the logs dir
        assert sorted(p.name for p in (tmp / "logs").iterdir()) == \
            ["web-client-log.jsonl"]


TESTS = [
    test_append_ok,
    test_declared_413,
    test_chunked_413,
    test_401_no_or_wrong_token,
    test_oversize_record_dropped_2xx,
    test_dirty_fields_stripped,
    test_query_ignored,
    test_bad_shape_400,
    test_rotation_readable,
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
