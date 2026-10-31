"""TASK-PLUGINSYNC R4: the patches that used to live only in the deployed
plugin directory (patch_clarify, patch_dupguard, the media_persist unit inside
compat.py) are now repo source. These smoke tests pin that the repo alone can
rebuild the deployed wiring: each module imports, each hook point compat.py
calls exists, and install.sh ships the files."""
import inspect
import pathlib
import sqlite3
import tempfile
import unittest

from compat import compat as c
from compat import patch_clarify, patch_dupguard

COMPAT = pathlib.Path(__file__).resolve().parent.parent / "compat"


class _Log:
    def __init__(self):
        self.lines = []

    def info(self, *args):
        self.lines.append(args)


class UnitWiring(unittest.TestCase):
    def test_every_unit_has_an_installer(self):
        for unit in c.UNITS:
            self.assertTrue(callable(getattr(c, "_install_" + unit, None)), unit)

    def test_media_persist_and_clarify_are_units(self):
        self.assertIn("media_persist", c.UNITS)
        self.assertIn("clarify", c.UNITS)
        for name in ("_media_persist_enabled", "_media_mirror", "_media_restore"):
            self.assertTrue(callable(getattr(c, name, None)), name)

    def test_install_calls_dupguard_hook(self):
        self.assertIn("patch_dupguard", inspect.getsource(c.install))

    def test_install_sh_ships_patch_modules(self):
        script = (COMPAT / "install.sh").read_text()
        for name in ("patch_clarify.py", "patch_dupguard.py"):
            self.assertIn(name, script)


class ClarifySmoke(unittest.TestCase):
    def test_hook_points(self):
        self.assertTrue(callable(patch_clarify.install))
        for name in ("callback", "pending", "handle"):
            self.assertTrue(callable(getattr(patch_clarify.Bridge, name, None)), name)


class DupguardSmoke(unittest.TestCase):
    def test_install_is_idempotent_and_drops_replayed_tool_row(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = pathlib.Path(tmp) / "state.db"
            con = sqlite3.connect(db)
            con.execute("CREATE TABLE messages (session_id TEXT, role TEXT, content TEXT,"
                        " tool_call_id TEXT, tool_calls TEXT)")
            con.commit()
            con.close()
            log = _Log()
            patch_dupguard.install(db, log)
            patch_dupguard.install(db, log)
            self.assertEqual(2, len(log.lines))
            con = sqlite3.connect(db)
            try:
                for _ in range(2):
                    con.execute("INSERT INTO messages VALUES ('s', 'tool', 'x', 'call-1', NULL)")
                rows = con.execute("SELECT count(*) FROM messages").fetchone()[0]
            finally:
                con.close()
            self.assertEqual(1, rows)


if __name__ == "__main__":
    unittest.main()
