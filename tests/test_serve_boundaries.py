#!/usr/bin/env python3
"""01413FIX F1: static containment + management-body boundaries (M1, M2,
m2, m6). Red at the audit HEAD (repro.py static_escape / management_cap /
management_nonobject / sse_upload_cap), green after F1. The audit's own
repro scripts stay the primary evidence; these are the repo-side regressions
following the web/test_serve_* harness style."""
import asyncio
import contextlib
import os
import pathlib
import sys
import tempfile
import unittest

ROOT_DIR = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT_DIR / "web"))

if not (os.environ.get("HERMES_ENV_FILE") or "").strip():
    _probe = tempfile.NamedTemporaryFile(mode="w", suffix=".env",
                                         delete=False, prefix="serve-import-")
    _probe.write("API_SERVER_KEY=\n")
    _probe.close()
    os.environ["HERMES_ENV_FILE"] = _probe.name

import serve  # noqa: E402
from aiohttp import web  # noqa: E402
from aiohttp.test_utils import TestServer, TestClient  # noqa: E402


class ServeFixture(unittest.IsolatedAsyncioTestCase):
    """serve with a public/ root, a NON-prefixed sibling private dir, and a
    fake echo upstream — the audit's shapes."""

    async def asyncSetUp(self):
        self.base = pathlib.Path(tempfile.mkdtemp(prefix="fix01413-f1-"))
        (self.base / "public").mkdir()
        (self.base / "public" / "index.html").write_text("SPA")
        (self.base / "public-private").mkdir()
        (self.base / "public-private" / "canary.txt").write_text("OUTSIDE_ROOT_CANARY")
        self.saved = (serve.ROOT, serve.API, serve.MAX_BODY_BYTES,
                      serve._authorized)
        serve.ROOT = self.base / "public"
        serve._authorized = lambda request: True
        serve._memories_dir = lambda: self.base / "memories"
        seen = []

        async def echo(req):
            body = await req.read()
            seen.append(len(body))
            return web.json_response({"seen": seen[-1]})
        fake = web.Application()
        fake.router.add_route("*", "/{rest:.*}", echo)
        self.upstream = TestServer(fake)
        await self.upstream.start_server()
        serve.API = str(self.upstream.make_url("")).rstrip("/")
        self.seen = seen
        self.client = TestClient(TestServer(serve.build_app()))
        await self.client.start_server()

    async def asyncTearDown(self):
        await self.client.close()
        await self.upstream.close()
        serve.ROOT, serve.API, serve.MAX_BODY_BYTES, auth = self.saved
        serve._authorized = auth

    async def test_M1_sibling_prefix_escape_is_not_served(self):
        # ".../public-private" style bug: containment is by PATH COMPONENT,
        # not string prefix; both encodings and the honest fallback.
        for path in ("/..%2Fpublic-private%2Fcanary.txt",
                     "/%2e%2e%2fpublic-private%2fcanary.txt"):
            resp = await self.client.get(path)
            body = await resp.text()
            self.assertNotEqual(body, "OUTSIDE_ROOT_CANARY",
                                f"M1 red: escaped read via {path}")
        # a non-prefixed escape keeps answering with the SPA
        resp = await self.client.get("/..%2Felsewhere%2Fcanary.txt")
        self.assertEqual(await resp.text(), "SPA")

    async def test_M2_management_PUT_over_the_cap_is_413_not_stored(self):
        serve.MAX_BODY_BYTES = 1024
        resp = await self.client.put("/api/memories/MEMORY.md",
                                     json={"content": "x" * (2 * 1024 * 1024)})
        self.assertEqual(resp.status, 413,
                         f"M2 red: 2 MiB under a 1024 cap answered {resp.status}")
        target = self.base / "memories" / "MEMORY.md"
        self.assertFalse(target.exists(), "oversize body must never be stored")

    async def test_M2_skills_PATCH_over_the_cap_is_413(self):
        serve.MAX_BODY_BYTES = 1024
        resp = await self.client.patch("/api/skills/whatever",
                                       json={"enabled": True, "pad": "y" * (2 * 1024 * 1024)})
        self.assertEqual(resp.status, 413)

    async def test_m6_non_object_JSON_bodies_are_400_not_500(self):
        for method, path in (("put", "/api/memories/USER.md"),):
            resp = await getattr(self.client, method)(path, json=[])
            self.assertEqual(resp.status, 400,
                             f"m6 red: {method} {path} answered {resp.status}")
        # skills PATCH parses first: an array must 400 before .get("enabled")
        resp = await self.client.patch("/api/skills/whatever", json=[])
        self.assertEqual(resp.status, 400)
        resp = await self.client.patch("/api/skills/whatever", json="str")
        self.assertEqual(resp.status, 400)

    async def test_m2_SSE_Accept_does_not_bypass_the_upload_cap(self):
        serve.MAX_BODY_BYTES = 1024

        async def chunks():
            yield b"a" * 512
            yield b"b" * 2048
        resp = await self.client.post("/api/echo", data=chunks(),
                                      headers={"Accept": "text/event-stream"})
        self.assertEqual(resp.status, 413,
                         f"m2 red: SSE Accept answered {resp.status}")

    async def test_small_SSE_POST_still_reaches_the_upstream(self):
        # the cap fix must not break honest SSE requests that carry a body
        serve.MAX_BODY_BYTES = 1024 * 1024
        resp = await self.client.post("/api/echo", data=b"hello",
                                      headers={"Accept": "text/event-stream"})
        self.assertEqual(resp.status, 200)


if __name__ == "__main__":
    unittest.main()
