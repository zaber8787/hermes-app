"""The watcher launcher must report both workers, or fail truthfully."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/ensure-watchers.sh"


class EnsureWatchersTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "scripts").mkdir()
        (self.root / "bin").mkdir()
        (self.root / "status").mkdir()
        shutil.copy2(SCRIPT, self.root / "scripts/ensure-watchers.sh")
        (self.root / "scripts/approve-worker.sh").write_text("#!/bin/sh\nexit 0\n")
        status = self.root / "status"
        pgrep = self.root / "bin/pgrep"
        pgrep.write_text(
            '#!/bin/sh\ncase "$*" in\n'
            f'  *approve-worker*) test -f "{status}/approve";;\n'
            f'  *watch-nudge*) test -f "{status}/nudge";;\n'
            '  *) exit 1;;\nesac\n'
        )
        pgrep.chmod(0o755)
        systemd = self.root / "bin/systemd-run"
        systemd.write_text(
            '#!/bin/sh\ncase "$*" in\n'
            f'  *approve-worker*) touch "{status}/approve";;\n'
            f'  *watch-nudge*) touch "{status}/nudge";;\n'
            '  *) exit 1;;\nesac\n'
        )
        systemd.chmod(0o755)
        self.env = {**os.environ, "PATH": f"{self.root / 'bin'}:{os.environ['PATH']}"}

    def launch(self):
        return subprocess.run(
            ["bash", str(self.root / "scripts/ensure-watchers.sh"), "worker-1", str(self.root / "done")],
            env=self.env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_missing_one_required_script_fails(self):
        run = self.launch()
        self.assertNotEqual(run.returncode, 0, run.stdout)
        self.assertIn("watch-nudge.sh", run.stderr)

    def test_both_live_watchers_are_required_for_success(self):
        (self.root / "scripts/watch-nudge.sh").write_text("#!/bin/sh\nexit 0\n")
        run = self.launch()
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertTrue((self.root / "status/approve").exists())
        self.assertTrue((self.root / "status/nudge").exists())


if __name__ == "__main__":
    unittest.main()
