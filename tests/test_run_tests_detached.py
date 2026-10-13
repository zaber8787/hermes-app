"""CLI contract for the detached Flutter sweep launcher."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/run-tests-detached.sh"


class DetachedRunnerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "scripts").mkdir()
        (self.root / "app").mkdir()
        (self.root / "bin").mkdir()
        shutil.copy2(SCRIPT, self.root / "scripts/run-tests-detached.sh")
        shutil.copy2(SCRIPT.with_name("run-tests-worker.sh"), self.root / "scripts/run-tests-worker.sh")
        (self.root / "scripts/env.sh").write_text("true\n")
        self.env = {**os.environ, "PATH": f"{self.root / 'bin'}:{os.environ['PATH']}"}

    def stub_systemd(self, body):
        path = self.root / "bin/systemd-run"
        path.write_text(f"#!/bin/sh\n{body}\n")
        path.chmod(0o755)

    def launch(self):
        return subprocess.run(
            ["bash", str(self.root / "scripts/run-tests-detached.sh"), "test/example.dart"],
            env=self.env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_launch_failure_is_nonzero(self):
        self.stub_systemd('echo "Failed to connect to bus" >&2; exit 7')
        run = self.launch()
        self.assertNotEqual(run.returncode, 0, run.stdout)
        self.assertIn("Failed to connect to bus", run.stderr)

    def test_concurrent_launches_keep_separate_result_directories(self):
        self.stub_systemd('echo "Running as unit: fake.service"')
        first, second = self.launch(), self.launch()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        paths = [re.search(r"^out=(.+/RESULT)$", r.stdout, re.M) for r in (first, second)]
        self.assertTrue(all(paths))
        first_result, second_result = (Path(m.group(1)) for m in paths)
        self.assertNotEqual(first_result, second_result)
        self.assertTrue(first_result.parent.is_dir())
        self.assertTrue(second_result.parent.is_dir())

    def test_worker_records_failure_and_exits_nonzero(self):
        flutter = self.root / "bin/flutter"
        flutter.write_text('#!/bin/sh\necho "test failed"; exit 2\n')
        flutter.chmod(0o755)
        out = self.root / "result"
        out.mkdir()
        run = subprocess.run(
            ["bash", str(self.root / "scripts/run-tests-worker.sh"), str(out), "test/example.dart"],
            env=self.env,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("FAIL test/example.dart", (out / "RESULT").read_text())
        self.assertIn("SWEEP-DONE fails=1 files=1", (out / "RESULT").read_text())


if __name__ == "__main__":
    unittest.main()
