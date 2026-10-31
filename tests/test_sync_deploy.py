"""TASK-PLUGINSYNC R3: compat/scripts/sync-deploy.sh against a throwaway deploy
dir. --check must see content drift, a sync must back up before writing and
clear __pycache__, and a deploy-only file must stop the sync unless --prune."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

COMPAT = pathlib.Path(__file__).resolve().parent.parent / "compat"
SCRIPT = COMPAT / "scripts" / "sync-deploy.sh"


class SyncDeploy(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.target = self.tmp / "hermes-app-compat"
        self.backups = self.tmp / "backups"
        shutil.copytree(COMPAT, self.target,
                        ignore=shutil.ignore_patterns("__pycache__", ".pytest_cache"))
        shutil.rmtree(self.target / "docs", ignore_errors=True)
        shutil.rmtree(self.target / "scripts", ignore_errors=True)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_script(self, *args):
        env = dict(os.environ, SYNC_DEPLOY_TARGET=str(self.target),
                   SYNC_DEPLOY_BACKUP_DIR=str(self.backups))
        return subprocess.run(["/bin/bash", str(SCRIPT), *args], env=env,
                              capture_output=True, text=True)

    def test_check_passes_on_identical_tree_ignoring_pycache(self):
        (self.target / "__pycache__").mkdir(exist_ok=True)
        (self.target / "__pycache__" / "x.pyc").write_bytes(b"\0")
        result = self.run_script("--check")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("IN SYNC", result.stdout)

    def test_sync_restores_drift_with_backup_and_clears_pycache(self):
        (self.target / "patch_dupguard.py").write_text("# hand edit\n")
        (self.target / "__pycache__").mkdir(exist_ok=True)
        self.assertEqual(1, self.run_script("--check").returncode)
        result = self.run_script()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual((COMPAT / "patch_dupguard.py").read_bytes(),
                         (self.target / "patch_dupguard.py").read_bytes())
        self.assertFalse((self.target / "__pycache__").exists())
        self.assertEqual(1, len(list(self.backups.glob("*.tar.gz"))))

    def test_deploy_only_file_blocks_sync_until_prune(self):
        stray = self.target / "patch_stray.py"
        stray.write_text("# drift\n")
        self.assertEqual(1, self.run_script("--check").returncode)
        blocked = self.run_script()
        self.assertEqual(3, blocked.returncode, blocked.stdout + blocked.stderr)
        self.assertTrue(stray.exists())
        self.assertFalse(self.backups.exists())
        pruned = self.run_script("--prune")
        self.assertEqual(0, pruned.returncode, pruned.stdout + pruned.stderr)
        self.assertFalse(stray.exists())


if __name__ == "__main__":
    unittest.main()
