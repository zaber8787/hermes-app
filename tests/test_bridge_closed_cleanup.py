"""A closed owner loop must not keep a bridge strongly registered."""

import ast
import asyncio
from pathlib import Path
import threading
from types import SimpleNamespace
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "compat/compat.py"


def bridge_class():
    tree = ast.parse(SOURCE.read_text())
    node = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == "_Bridge")
    module = ast.Module(body=[node], type_ignores=[])
    namespace = {"asyncio": asyncio}
    exec(compile(ast.fix_missing_locations(module), str(SOURCE), "exec"), namespace)
    return namespace["_Bridge"]


class ClosedBridgeCleanupTest(unittest.TestCase):
    def test_close_after_owner_loop_shutdown_forgets_registrations(self):
        class Adapter:
            def __init__(self):
                self._run_approval_sessions = {"r": "r"}
                self.releases = 0

            def _release_run_owner_if_forgotten(self, run_id):
                self.releases += 1

        loop = asyncio.new_event_loop()
        loop.close()
        adapter = Adapter()
        Bridge = bridge_class()
        bridge = Bridge.__new__(Bridge)
        bridge.loop = loop
        bridge.adapter = adapter
        bridge.run_id = "r"
        bridge.bridges = {(id(adapter), "r"): bridge}
        bridge.lock = threading.RLock()
        bridge.closed = False
        bridge.approval = SimpleNamespace(unregister_gateway_notify=lambda _: None)

        bridge.close()
        self.assertTrue(bridge.closed)
        self.assertEqual(bridge.bridges, {})
        self.assertEqual(adapter._run_approval_sessions, {})
        self.assertEqual(adapter.releases, 1)
        bridge.close()
        self.assertEqual(adapter.releases, 1)


if __name__ == "__main__":
    unittest.main()
