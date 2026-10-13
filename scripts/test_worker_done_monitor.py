#!/usr/bin/env python3
"""R3: committed but missing done raises a distinct, nonadvancing alert."""
import os
import subprocess
import tempfile
import time
from pathlib import Path

SCRIPT = Path(__file__).with_name("worker-done-monitor.sh")


def main():
    with tempfile.TemporaryDirectory(prefix="done-monitor-") as scratch:
        home = Path(scratch)
        (home / ".hermes").mkdir()
        root = home / "hermes-app"
        root.mkdir()
        bin_dir = home / "bin"
        bin_dir.mkdir()
        pane = f"gone-worker-{os.getpid()}"
        (home / ".hermes" / "worker-task").write_text("\n".join((
            "TASK/synthetic.md", "old-head", ".done-synthetic",
            str(int(time.time()) - 5 * 3600), "synthetic", "0", pane)) + "\n")
        git = bin_dir / "git"
        git.write_text("#!/bin/sh\necho new-head-after-commit\n")
        git.chmod(0o755)
        tmux = bin_dir / "tmux"
        tmux.write_text("#!/bin/sh\nexit 1\n")
        tmux.chmod(0o755)
        env = dict(os.environ, HOME=str(home), PATH=str(bin_dir) + ":" + os.environ["PATH"])

        def status():
            result = subprocess.run(["bash", str(SCRIPT)], env=env,
                                    capture_output=True, text=True, check=True)
            return result.stdout.strip()

        try:
            assert status().startswith("COMMIT_WITHOUT_DONE "), \
                "missing done after HEAD advance and dead pane needs its own alert"
            git.write_text("#!/bin/sh\necho old-head\n")
            assert status() == "STALE", "unchanged HEAD retains stale diagnosis"
            (root / ".done-synthetic").touch()
            assert status().startswith("DONE "), "explicit done remains authoritative"
        finally:
            Path("/tmp/.nwm-" + pane).unlink(missing_ok=True)
    print("WORKER-DONE-MONITOR: PASS (3 assertions)")


if __name__ == "__main__":
    main()
