"""memguard must fail closed when available-memory evidence is unreadable."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/memguard.sh"


class MemguardTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "scripts").mkdir()
        shutil.copy2(SCRIPT, self.root / "scripts/memguard.sh")
        self.meminfo = self.root / "meminfo"

    def run_guard(self):
        return subprocess.run(
            ["bash", str(self.root / "scripts/memguard.sh"), "6000"],
            env={**os.environ, "HERMES_MEMINFO_PATH": str(self.meminfo)},
            text=True,
            capture_output=True,
            check=False,
        )

    def test_missing_meminfo_is_not_reported_as_ok(self):
        run = self.run_guard()
        self.assertNotEqual(run.returncode, 0, run.stdout)
        self.assertNotIn("MEMGUARD: ok", run.stdout)

    def test_malformed_available_memory_is_not_reported_as_ok(self):
        self.meminfo.write_text("MemAvailable: unknown kB\n")
        run = self.run_guard()
        self.assertNotEqual(run.returncode, 0, run.stdout)
        self.assertNotIn("MEMGUARD: ok", run.stdout)

    def test_valid_memory_still_passes(self):
        self.meminfo.write_text("MemAvailable: 8192000 kB\n")
        run = self.run_guard()
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("avail=8000M", run.stdout)


if __name__ == "__main__":
    unittest.main()
