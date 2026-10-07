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

CASES = ("upload", "limits", "media", "history", "approval", "skills", "activity", "push",
         "approval_inbox", "approval_push", "approval_central", "cron_bridge", "wake",
         "wakecap", "selfwake", "steer_inbox", "notification_events")
REPO = Path(__file__).resolve().parents[1]


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--mode", choices=("offline", "live"), default="offline")
    p.add_argument("--agent-root", type=Path, default=Path.home()/".hermes/hermes-agent")
    p.add_argument("--plugin-root", type=Path, default=REPO/"compat")
    # UPD-COMPAT P0: fixed-SHA + isolated-interpreter injection. --revision
    # names a git object readable from --agent-root (READ-ONLY there: only
    # cat-file/archive run); --python selects the probe interpreter so the
    # gate never silently uses the production checkout's venv.
    p.add_argument("--revision", help="fixed full or abbreviated commit SHA to probe")
    p.add_argument("--python", type=Path, help="interpreter (isolated staging venv) for workers")
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


def plugin_version(root: Path) -> str:
    try:
        for line in (root/"plugin.yaml").read_text().splitlines():
            if line.startswith("version:"):
                return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return "unknown"


def plugin_digest(root: Path) -> str:
    """Content digest of the plugin under test (sorted relpaths, pycache-free)."""
    import hashlib
    files = sorted(p for p in root.rglob("*") if p.is_file() and "__pycache__" not in p.parts
                   and not p.name.endswith(".pyc"))
    h = hashlib.sha256()
    for f in files:
        h.update(str(f.relative_to(root)).encode())
        h.update(f.read_bytes())
    return h.hexdigest()


def venv_identity(python: Path) -> dict:
    probe = ("import hashlib,json,os,sys;"
             "cfg=os.path.join(sys.prefix,'pyvenv.cfg');"
             "print(json.dumps({'executable':sys.executable,'prefix':sys.prefix,"
             "'base_prefix':sys.base_prefix,'version':sys.version.splitlines()[0],"
             "'pyvenv_cfg_sha256':hashlib.sha256(open(cfg,'rb').read()).hexdigest() if os.path.exists(cfg) else None}))")
    ident = json.loads(subprocess.check_output([str(python), "-B", "-c", probe], text=True))
    if ident["prefix"] == ident["base_prefix"]:
        raise RuntimeError(f"probe interpreter is not a virtualenv: {python}")
    return ident


def offline(args):
    root = args.agent_root.resolve()
    # Gate rule: a fixed-revision probe must declare its interpreter (P0 spec);
    # silently borrowing the checkout venv would import new code into production.
    if args.revision and not args.python:
        raise RuntimeError("--revision requires --python (isolated staging venv)")
    # Read-only object access only: rev-parse --verify + archive. Never checkout.
    if args.revision:
        revision = subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "--verify", f"{args.revision}^{{commit}}"],
            text=True).strip()
        source = "fixed-revision"
    else:
        revision = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
        source = "clean-head"
    if args.python:
        # NOTE: never Path.resolve() here — uv venvs symlink bin/python to the base
        # interpreter, and resolving would silently drop the venv's site-packages.
        python = Path(args.python)
        if not python.exists():
            raise RuntimeError(f"probe python not found: {python}")
    else:
        python = next((root/p for p in ("venv/bin/python", ".venv/bin/python") if (root/p).exists()), None)
        if python is None:
            raise RuntimeError("Hermes venv python not found")
    identity = venv_identity(python)
    digest = plugin_digest(args.plugin_root.resolve())
    results = []
    with tempfile.TemporaryDirectory(prefix="compat-probe-") as scratch:
        scratch = Path(scratch)
        clean = scratch/"agent"
        clean.mkdir()
        archive = subprocess.Popen(["git", "-C", str(root), "archive", revision], stdout=subprocess.PIPE)
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
                    "NO_PROXY": "127.0.0.1,localhost", "TERM": "dumb",
                    # Workers must inherit the disk scratch (01412 audit: the
                    # original env dropped TMPDIR and fell back to /tmp).
                    **({"TMPDIR": os.environ["TMPDIR"]} if os.environ.get("TMPDIR") else {})}
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
                "push": "session-stream approval/prepare/write/drain/status wrappers / ntfy publisher",
                "approval_inbox": "central _set_run_status capture cut / pending GET / exact POST / settle bridge",
                "approval_push": "immediate dispatcher / reminder timer / Unicode JSON title / exit hand-off and rollback",
                "approval_central": "API producers (session/runs/no-SSE/detach/OpenAI stream) / escalation / dedup-replay / error isolation / rollback on the single status cut",
                "cron_bridge": "app platform registration + cron scheduler identity/mirror/outcome shims / atomic bridge writer",
                "wake": "messages provenance / auto-wake admission ledger, quota, receipts, dispatch CAS",
                "wakecap": "hot-reload route sync: live/frozen routers resolve compat route rows to the current handlers",
                "selfwake": "server self-wake: durable intents in the receipt transaction, generation/cutoff, reconciliation, shadow/off gates, chain fuse, audit",
                "steer_inbox": "durable run-scoped steer inbox: auth/epoch gates, idempotent admission, receipts, seal, capability fail-closed",
                "notification_events": "notification ledger: stable event ids, single publish, read-gated reminders, browser claim, terminals never replayed",
                "control": "clean HEAD without plugin", "lifecycle": "register/on_unload transactions",
            }[case]
            result["expected"] = "all selected behavior assertions pass"
            result["actual"] = result.get("detail", "")
            results.append(result)
            print(f'{result["status"]:7} {case}: {result.get("detail", "")}', flush=True)
            if result.get("diagnostic"):
                print(result["diagnostic"], file=sys.stderr)
    return {"schema_version": 2, "mode": "offline", "source": source,
            "source_sha": revision, "agent_revision": revision, "python": str(python),
            "venv_identity": identity, "plugin_version": plugin_version(args.plugin_root),
            "plugin_digest": digest, "results": results}


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
