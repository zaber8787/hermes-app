#!/usr/bin/env python3
"""01413FIX F2: the upload stopwatch starts at hand-over (M3).
`prog["last"] or loop.time()` re-armed a fresh full window on every wake
while no byte had ever arrived, so a never-started upload could not expire.
Red at the audit HEAD (repro initial_upload_stall), green after F2."""
import asyncio
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


class UploadIdle(unittest.IsolatedAsyncioTestCase):
    async def test_M3_fully_stalled_upload_is_cut_near_the_idle_limit(self):
        saved = serve.UPLOAD_IDLE_TIMEOUT
        serve.UPLOAD_IDLE_TIMEOUT = 0.03
        try:
            async def never():
                await asyncio.Event().wait()
            task = asyncio.ensure_future(serve._request_upload_then_headers(
                never(), {"last": None, "over": False},
                asyncio.Event(), asyncio.Event()))
            await asyncio.sleep(0.15)  # 5x the idle window, zero bytes seen
            self.assertTrue(task.done(),
                            "M3 red: zero-byte waiting never armed the clock "
                            "and the request stays alive past the limit")
            self.assertRaises(asyncio.TimeoutError, task.result)
        finally:
            if not task.done():
                task.cancel()
                with self.assertRaises(asyncio.CancelledError):
                    await task
            serve.UPLOAD_IDLE_TIMEOUT = saved

    async def test_bytes_in_flight_keep_the_clock_moving(self):
        saved = serve.UPLOAD_IDLE_TIMEOUT
        serve.UPLOAD_IDLE_TIMEOUT = 0.05
        try:
            loop = asyncio.get_running_loop()
            prog = {"last": loop.time(), "over": False}

            async def slow():
                for _ in range(8):
                    await asyncio.sleep(0.03)  # alive slower than idle
                    prog["last"] = loop.time()
                return "response"
            task = asyncio.ensure_future(serve._request_upload_then_headers(
                slow(), prog, asyncio.Event(), asyncio.Event()))
            self.assertEqual(await asyncio.wait_for(task, 2), "response")
        finally:
            serve.UPLOAD_IDLE_TIMEOUT = saved


if __name__ == "__main__":
    unittest.main()
