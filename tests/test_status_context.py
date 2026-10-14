"""STATUSCTX: session facts are read-only and distinguish occupancy from totals."""

import pathlib
import sys
import types
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "web"))

from compat.status_context import read_status_context
import serve
from aiohttp.test_utils import TestClient, TestServer


class FakeDB:
    def __init__(self, path, read_only=False):
        assert read_only
        self.closed = False

    def get_session(self, sid):
        return {
            "id": sid, "model": "test-model", "input_tokens": 900000,
            "output_tokens": 200000, "billing_provider": "test",
        } if sid == "s" else None

    def get_recent_session_model_route(self, sid):
        return None

    def gateway_routing_entry_for_session(self, sid):
        return {"session_id": sid, "last_prompt_tokens": 32000}

    def get_compression_lineage(self, sid):
        return [sid]

    def close(self):
        self.closed = True


class StatusContextTest(unittest.TestCase):
    def test_reads_prompt_not_cumulative_usage(self):
        state = types.ModuleType("hermes_state")
        state.SessionDB = FakeDB
        run = types.ModuleType("gateway.run")
        run._resolve_gateway_model_context = lambda model, route: types.SimpleNamespace(
            context_length=128000, context_source="detected")
        with patch.dict(sys.modules, {"hermes_state": state, "gateway.run": run}):
            facts = read_status_context("s", pathlib.Path("/unused"))
            self.assertEqual(facts["context_used_tokens"], 32000)
            self.assertEqual(facts["context_limit_tokens"], 128000)
            self.assertIsNone(facts["compression_threshold_tokens"])
            self.assertIsNone(read_status_context("missing", pathlib.Path("/unused")))


class StatusContextEndpointTest(unittest.IsolatedAsyncioTestCase):
    async def test_auth_and_read_only_payload(self):
        saved = serve._authorized
        serve._authorized = lambda request: request.headers.get("Authorization") == "Bearer test"
        self.client = TestClient(TestServer(serve.build_app()))
        await self.client.start_server()
        try:
            response = await self.client.get("/api/sessions/s/context")
            self.assertEqual(response.status, 401)
            with patch("compat.status_context.read_status_context", return_value={"model": "m"}):
                response = await self.client.get(
                    "/api/sessions/s/context", headers={"Authorization": "Bearer test"})
                self.assertEqual(response.status, 200)
                self.assertEqual((await response.json())["context"]["model"], "m")
            with patch("compat.status_context.read_status_context", return_value=None):
                response = await self.client.get(
                    "/api/sessions/missing/context",
                    headers={"Authorization": "Bearer test"})
                self.assertEqual(response.status, 404)
        finally:
            await self.client.close()
            serve._authorized = saved


if __name__ == "__main__":
    unittest.main()
