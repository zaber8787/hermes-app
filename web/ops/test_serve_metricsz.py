#!/usr/bin/env python3
"""STATION-LANE D4：/metricsz 與 inflight middleware 的回歸測試。

    cd ~/hermes-app && .venv-web/bin/python3 -m unittest discover -s web/ops -p 'test_*.py'

紅過的理由：改動之前 /metricsz 落進 serve.py 末段的 `/{path:.*}` 靜態兜底，
回 200 text/html（已實測：content_type=text/html），下面測試 1 的 JSON
斷言會失敗；middleware 與 _gauges 這些符號也還不存在。
"""
import asyncio
import contextlib
import os
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))  # web/
from aiohttp import web, ClientSession, ClientTimeout  # noqa: E402

# Import hygiene (ENVHYGIENE §7.2)：同 test_serve_activity.py， importing serve
# 绝不能讀到操作者的真實 ~/.hermes/.env。
import os as _os, tempfile as _tf  # noqa: E402
if not (_os.environ.get("HERMES_ENV_FILE") or "").strip():
    _env_probe = _tf.NamedTemporaryFile(
        mode="w", suffix=".env", delete=False, prefix="serve-import-")
    _env_probe.write("API_SERVER_KEY=\n")
    _env_probe.close()
    _os.environ["HERMES_ENV_FILE"] = _env_probe.name
import serve  # noqa: E402

FAKE_BEARER = "sk-metricsz"


async def upstream(request: web.Request) -> web.Response:
    return web.json_response({"ok": True},
                             headers={"Cache-Control": "no-store"})


class MetricszTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.saved = (serve.ROOT, serve.API, serve.ENV_FILE,
                      os.environ.get("HERMES_WEB_HEARTBEAT"))
        self.tmp = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.tmp.name)
        (root / "index.html").write_text("<html>idx</html>", encoding="utf-8")
        serve.ROOT = root
        # api_proxy 帶 bearer gate（serve.py:432 _authorized，key 每 req 從
        # ENV_FILE 重讀）：給一支只含假 key 的 env 檔，同 test_serve_memories.py
        env = root / ".env"
        env.write_text(f"API_SERVER_KEY={FAKE_BEARER}\n", encoding="utf-8")
        serve.ENV_FILE = env

        # 假上游：靜態與反代一致性比較用的固定回應端
        self.fake = web.Application()
        self.fake.router.add_get("/api/sessions/{sid}/activity", upstream)
        self.fr = web.AppRunner(self.fake)
        await self.fr.setup()
        self.fs = web.TCPSite(self.fr, "127.0.0.1", 0)
        await self.fs.start()
        serve.API = f"http://127.0.0.1:{self.fr.addresses[0][1]}"

    async def asyncTearDown(self):
        with contextlib.suppress(Exception):
            await self.fr.cleanup()
        serve.ROOT, serve.API, serve.ENV_FILE = self.saved[:3]
        if self.saved[3] is None:
            os.environ.pop("HERMES_WEB_HEARTBEAT", None)
        else:
            os.environ["HERMES_WEB_HEARTBEAT"] = self.saved[3]
        self.tmp.cleanup()

    def _app(self):
        app = serve.build_app()
        return app

    async def _serve(self, app):
        pr = web.AppRunner(app)
        await pr.setup()
        site = web.TCPSite(pr, "127.0.0.1", 0)
        await site.start()
        return pr, f"http://127.0.0.1:{pr.addresses[0][1]}"

    async def _both(self, hb):
        """依 HERMES_WEB_HEARTBEAT 建 app、起服務，回 (runner, base, app)。"""
        if hb is None:
            os.environ.pop("HERMES_WEB_HEARTBEAT", None)
        else:
            os.environ["HERMES_WEB_HEARTBEAT"] = hb
        pr, base = await self._serve(self._app())
        return pr, base

    async def test_metricsz_json_gauges(self):
        pr, base = await self._both("1")
        try:
            async with ClientSession(timeout=ClientTimeout(total=15)) as c:
                async with c.get(base + "/metricsz") as r:
                    self.assertEqual(r.status, 200)
                    self.assertTrue(
                        r.headers.get("Content-Type", "").startswith(
                            "application/json"),
                        f"舊碼會落在靜態兜底回 text/html: {r.headers}")
                    body = await r.json()
                    for key in ("lag", "inflight", "drainers", "bigslots"):
                        self.assertIn(key, body)
                    # 這個請求本身在 middleware 之內被計數
                    self.assertGreaterEqual(body["inflight"], 1)
                    # 啟動後 2 個槽全空：bigslots = 佔用量 = 0
                    self.assertEqual(body["bigslots"], 0)
                    self.assertEqual(r.headers.get("Cache-Control"),
                                     "no-store")
                # 心跳第一拍（sleep 1.0）之後 lag 從 null 變成數字
                await asyncio.sleep(1.3)
                async with c.get(base + "/metricsz") as r:
                    self.assertIsInstance((await r.json())["lag"], float)
        finally:
            await pr.cleanup()

    async def test_disabled_is_404_and_no_middleware(self):
        os.environ["HERMES_WEB_HEARTBEAT"] = "0"
        app = self._app()
        self.assertEqual(len(app.middlewares), 0)
        pr, base = await self._serve(app)
        try:
            self.assertIsNone(serve._hb_task)  # on_startup 沒起心跳 task
            async with ClientSession(timeout=ClientTimeout(total=15)) as c:
                async with c.get(base + "/metricsz") as r:
                    self.assertEqual(r.status, 404)  # 不是兜底的 200 HTML
        finally:
            await pr.cleanup()

    async def test_middleware_changes_nothing_on_static_and_proxy(self):
        async def snapshot(hb):
            pr, base = await self._both(hb)
            try:
                out = {}
                async with ClientSession(
                        timeout=ClientTimeout(total=15)) as c:
                    for name, path in (("static", "/index.html"),
                                       ("proxy", "/api/sessions/s1/activity")):
                        async with c.get(base + path, headers={
                                "Authorization": "Bearer " + FAKE_BEARER}) as r:
                            heads = {k: v for k, v in r.headers.items()
                                     if k != "Date"}
                            out[name] = (r.status, heads, await r.read())
                return out
            finally:
                await pr.cleanup()

        off = await snapshot("0")
        on = await snapshot("1")
        self.assertEqual(off, on)

    def test_bigslots_null_before_startup(self):
        saved = serve.big_streams
        try:
            serve.big_streams = None
            self.assertIsNone(serve._gauges()["bigslots"])
        finally:
            serve.big_streams = saved


if __name__ == "__main__":
    unittest.main(verbosity=2)
