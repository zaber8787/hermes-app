#!/usr/bin/env python3
"""Compatibility gate: clean-HEAD isolated HTTP tests or explicit live probes.

No installation/restart/config changes. Offline workers use a git archive, a
fresh HOME/HERMES_HOME and -B, and never import from the working agent tree.
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

CASES = ("upload", "limits", "media", "history", "approval", "skills", "activity")
REPO = Path(__file__).resolve().parents[1]


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--mode", choices=("offline", "live"), default="offline")
    p.add_argument("--agent-root", type=Path, default=Path.home()/".hermes/hermes-agent")
    p.add_argument("--plugin-root", type=Path, default=REPO/"compat")
    p.add_argument("--only", choices=CASES)
    p.add_argument("--full-size", action="store_true")
    p.add_argument("--json-output", type=Path)
    p.add_argument("--base-url")
    p.add_argument("--token-file", type=Path)
    p.add_argument("--fixture-dir", type=Path)
    p.add_argument("--allow-test-agent-turns", action="store_true")
    p.add_argument("--worker", help=argparse.SUPPRESS)
    p.add_argument("--worker-output", type=Path, help=argparse.SUPPRESS)
    return p


def run_worker(args):
    # Remove tools/ as an import root: upstream's tools is a different package.
    sys.path[:] = [str(args.agent_root.resolve()), *[p for p in sys.path if p != str(REPO/"tools")]]
    sys.path.append(str(REPO/"tools"))
    from compat_probe_cases.offline import run
    import asyncio
    result = asyncio.run(run(args))
    args.worker_output.write_text(json.dumps(result, indent=2))
    return 0 if result["status"] == "PASS" else 1


def offline(args):
    root = args.agent_root.resolve()
    revision = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    python = next((root/p for p in ("venv/bin/python", ".venv/bin/python") if (root/p).exists()), None)
    if python is None:
        raise RuntimeError("Hermes venv python not found")
    results = []
    with tempfile.TemporaryDirectory(prefix="compat-probe-") as scratch:
        scratch = Path(scratch)
        clean = scratch/"agent"
        clean.mkdir()
        archive = subprocess.Popen(["git", "-C", str(root), "archive", "HEAD"], stdout=subprocess.PIPE)
        with tarfile.open(fileobj=archive.stdout, mode="r|") as tar:
            tar.extractall(clean, filter="data")
        if archive.wait() != 0:
            raise RuntimeError("clean HEAD archive failed")
        selected = [args.only] if args.only else list(CASES)
        if not args.only:
            selected += ["control", "lifecycle"]
        for case in selected:
            home = scratch/case
            hermes = home/".hermes"
            hermes.mkdir(parents=True)
            plugin = hermes/"plugins/hermes-app-compat"
            shutil.copytree(args.plugin_root, plugin, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
            enabled = [] if case == "control" else ["hermes-app-compat"]
            config = {"plugins": {"enabled": enabled}, "model": "compat-fixture",
                      "browser": {"extension_control": {"enabled": True}},
                      "approvals": {"mode": "manual", "unattended_mode": "deny", "cron_mode": "deny",
                                    "single_query_mode": "deny", "timeout": 3},
                      "security": {"tirith_enabled": False},
                      "terminal": {"backend": "local"}}
            (hermes/"config.yaml").write_text(json.dumps(config))
            # Preserve only non-secret execution essentials. Never read the real .env.
            env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(home),
                   "HERMES_HOME": str(hermes), "PYTHONDONTWRITEBYTECODE": "1",
                   "PYTHONPATH": str(clean), "LANG": "C.UTF-8", "HERMES_EXEC_ASK": "1",
                   "NO_PROXY": "127.0.0.1,localhost", "TERM": "dumb"}
            output = home/"result.json"
            cmd = [str(python), "-B", str(Path(__file__).resolve()), "--worker", case,
                   "--agent-root", str(clean), "--worker-output", str(output)]
            if args.full_size:
                cmd.append("--full-size")
            start = time.monotonic()
            try:
                proc = subprocess.run(cmd, cwd=home, env=env, capture_output=True, text=True, timeout=900)
                if output.exists():
                    result = json.loads(output.read_text())
                else:
                    result = {"id": case, "status": "ERROR", "detail": "worker failed before report",
                              "diagnostic": proc.stderr[-3500:]}
            except subprocess.TimeoutExpired:
                result = {"id": case, "status": "ERROR", "detail": "worker timeout (900s)"}
            result["seconds"] = round(time.monotonic()-start, 2)
            result["repair_file"] = "compat/compat.py"
            result["target"] = {
                "upload": "APIServerAdapter._handle_artifact_upload",
                "limits": "api_server/ArtifactStore constants and keyword defaults",
                "media": "APIServerAdapter._http_route_table / _CAPABILITY_ENDPOINTS",
                "history": "APIServerAdapter._message_response (staticmethod)",
                "approval": "approval_context + approval aliases / session SSE worker / run controls",
                "skills": "tools.skills_tool._find_all_skills",
                "activity": "APIServerAdapter activity snapshot / run-status & chat hooks / registry",
                "control": "clean HEAD without plugin", "lifecycle": "register/on_unload transactions",
            }[case]
            result["expected"] = "all selected behavior assertions pass"
            result["actual"] = result.get("detail", "")
            results.append(result)
            print(f'{result["status"]:7} {case}: {result.get("detail", "")}', flush=True)
            if result.get("diagnostic"):
                print(result["diagnostic"], file=sys.stderr)
    return {"schema_version": 1, "mode": "offline", "source": "clean-head",
            "agent_revision": revision, "plugin_version": "0.1.0", "results": results}


def main():
    args = parser().parse_args()
    if args.worker:
        return run_worker(args)
    try:
        if args.mode == "offline":
            report = offline(args)
        else:
            from compat_probe_cases.live import run
            import asyncio
            report = asyncio.run(run(args))
        statuses = [r["status"] for r in report["results"]]
        code = 1 if "FAIL" in statuses else 2 if any(s != "PASS" for s in statuses) else 0
        report["summary"] = "PARTIAL" if args.only else "ALL GREEN" if code == 0 else "RED / NOT RUN"
        if args.json_output:
            args.json_output.parent.mkdir(parents=True, exist_ok=True)
            args.json_output.write_text(json.dumps(report, indent=2, ensure_ascii=False)+"\n")
        print(report["summary"])
        return code
    except Exception as exc:
        print(f"ERROR environment: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
