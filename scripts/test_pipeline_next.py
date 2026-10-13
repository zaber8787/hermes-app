#!/usr/bin/env python3
"""R2: failed tmux dispatch remains retryable under a disposable HOME."""
import os
import subprocess
import tempfile
import time
from pathlib import Path

SCRIPT = Path(__file__).with_name("pipeline-next.sh")


def main():
    with tempfile.TemporaryDirectory(prefix="pipeline-next-") as scratch:
        home = Path(scratch)
        root = home / "hermes-app"
        (root / "TASK").mkdir(parents=True)
        (root / "scripts").mkdir()
        (home / ".hermes" / "pipelines").mkdir(parents=True)
        bin_dir = home / "bin"
        bin_dir.mkdir()
        (root / "TASK" / "a.md").write_text("synthetic A")
        (root / "TASK" / "b.md").write_text("synthetic B")
        (root / ".done-a").touch()
        (root / "scripts" / "ensure-watchers.sh").write_text("#!/bin/sh\nexit 0\n")
        (home / ".hermes" / "pipelines" / "example.list").write_text(
            "TASK/a.md|worker|.done-a\nTASK/b.md|worker|.done-b\n")
        marker = home / ".hermes" / "worker-task"
        marker.write_text("\n".join(("TASK/a.md", "synthetic-sha", ".done-a",
                                     str(int(time.time())), "example", "0", "worker")) + "\n")
        tmux = bin_dir / "tmux"
        tmux.write_text("""#!/bin/sh
case "$1" in
  has-session) exit 0 ;;
  send-keys)
    n=$(cat "$HOME/.hermes/send-count" 2>/dev/null || echo 0)
    n=$((n + 1)); echo "$n" > "$HOME/.hermes/send-count"
    [ "$n" -gt 1 ]; exit $? ;;
  capture-pane) echo Working; exit 0 ;;
esac
exit 0
""")
        tmux.chmod(0o755)
        git = bin_dir / "git"
        git.write_text("#!/bin/sh\necho synthetic-sha\n")
        git.chmod(0o755)
        env = dict(os.environ, HOME=str(home),
                   PATH=str(bin_dir) + ":" + os.environ["PATH"],
                   PIPELINE_SEND_SETTLE_SECONDS="0")
        first = subprocess.run(["bash", str(SCRIPT)], env=env,
                               capture_output=True, text=True)
        after_first = marker.read_text().splitlines()
        second = subprocess.run(["bash", str(SCRIPT)], env=env,
                                capture_output=True, text=True)
        after_second = marker.read_text().splitlines()
        assert first.returncode != 0, "first send must fail in the fixture"
        assert after_first[5] == "1" and after_first[0] == "TASK/b.md", "next marker is durable"
        assert second.returncode == 0 and "ADVANCED" in second.stdout, "retry dispatches same stage"
        assert after_second[5] == "1" and after_second[0] == "TASK/b.md", "retry does not skip stages"
        assert not (root / ".done-a").exists(), "old done is removed only after new marker exists"
        assert (home / ".hermes" / "send-count").read_text().strip() == "2", "one retry was sent"
    print("PIPELINE-NEXT: PASS (6 assertions)")


if __name__ == "__main__":
    main()
