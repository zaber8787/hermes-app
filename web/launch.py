"""Launch web/serve.py under the install's *current* dependency generation.

The systemd unit used to exec venv/bin/python3 directly. After `hermes update`
moved the install to the PM generations tree, that interpreter no longer
carries aiohttp, and the unit crash-looped. This thin launcher is the stable
trampoline: any old interpreter enters hermes_bootstrap, which execs the
runtime this install actually resolves to today (PM-selected venv), then
run_paths serve.py with both the hermes-agent source root and this repo on
sys.path so `hermes_state` and `compat` import cleanly.
"""
import os
import pathlib
import runpy
import sys

os.environ.pop("PYTHONHOME", None)
os.environ.pop("PYTHONPATH", None)

_REPO = pathlib.Path(__file__).resolve().parent.parent
_AGENT = pathlib.Path.home() / ".hermes" / "hermes-agent"
if not _AGENT.is_dir():  # profile/portable installs
    _AGENT = pathlib.Path(os.environ.get("HERMES_AGENT_ROOT", _AGENT))

for entry in (str(_AGENT), str(_REPO)):
    if entry not in sys.path:
        sys.path.insert(0, entry)

import hermes_bootstrap  # noqa: F401,E402  (activates PM dependencies; may exec)

sys.argv = [str(_REPO / "web" / "serve.py"), *sys.argv[1:]]
runpy.run_path(sys.argv[0], run_name="__main__")
