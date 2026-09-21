#!/usr/bin/env python3
"""serve.py runtime-config tests (ENVHYGIENE §4.3/§7.2).

Run: "$HOME/.hermes/hermes-agent/venv/bin/python" web/test_serve_config.py
Never touches the operator's ~/.hermes: every case drives a fresh serve.py
import with HERMES_ENV_FILE pointing at a tmp file (or no file at all).
"""
import contextlib
import os
import pathlib
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent
PASS = 0
FAIL = 0


def check(name, cond):
    global PASS, FAIL
    if cond:
        PASS += 1
    else:
        FAIL += 1
        print(f"FAIL {name}")


def run_serve(args, env):
    base = {"PATH": os.environ.get("PATH", ""), "HOME": env.get("HOME", "/tmp")}
    base.update(env)
    return subprocess.run(
        [sys.executable, str(REPO / "web" / "serve.py"), *args],
        capture_output=True, text=True, env=base, timeout=30)


def tmp_home():
    d = pathlib.Path(tempfile.mkdtemp())
    (d / ".hermes").mkdir()
    return d


def with_root(home):
    root = home / "current"
    root.mkdir(exist_ok=True)
    (root / "index.html").write_text("<html></html>", encoding="utf-8")
    return root


def main():
    # 1. No env at all: safe loopback defaults, no crash.
    home = tmp_home()
    # default selector ($HOME/.hermes/.env) simply absent = fine (§3.1.5)
    r = run_serve(["--check-config"], {"HOME": str(home)})
    check("missing default file still boots config", "index.html not found" in r.stderr
          or "CONFIG OK" in r.stdout)  # root missing in fresh HOME = the only error
    check("no selector file is not fatal", "env file is missing" not in r.stderr)

    # 2. Full file: values + sources printed; key only as bool.
    home = tmp_home()
    root = with_root(home)
    (home / ".hermes" / ".env").write_text(
        "API_SERVER_KEY=\"kv\"\nHERMES_WEB_API=http://127.0.0.1:9999\n"
        "HERMES_WEB_HOST=127.0.0.1\nHERMES_WEB_PORT=9911\n"
        f"HERMES_WEB_ROOT={root}\n", encoding="utf-8")
    r = run_serve(["--check-config"], {"HOME": str(home),
                                       "HERMES_ENV_FILE": str(home / ".hermes" / ".env")})
    check("file values applied", "http://127.0.0.1:9999 (file)" in r.stdout
          and "HERMES_WEB_PORT=9911 (file)" in r.stdout)
    check("key reported as bool only", "key_present=True" in r.stdout
          and "kv" not in r.stdout and "kv" not in r.stderr)
    check("config OK", "CONFIG OK" in r.stdout)

    # 3. Process env beats the file.
    r = run_serve(["--check-config"], {
        "HOME": str(home), "HERMES_ENV_FILE": str(home / ".hermes" / ".env"),
        "HERMES_WEB_PORT": "9922"})
    check("process env precedence", "HERMES_WEB_PORT=9922 (env)" in r.stdout)

    # 4. Invalid explicit values preflight-fail before any bind.
    r = run_serve(["--check-config"], {
        "HOME": str(home), "HERMES_ENV_FILE": str(home / ".hermes" / ".env"),
        "HERMES_WEB_PORT": "0"})
    check("bad port rejected", r.returncode == 1 and "HERMES_WEB_PORT" in r.stderr)
    r = run_serve(["--check-config"], {
        "HOME": str(home), "HERMES_ENV_FILE": str(home / ".hermes" / ".env"),
        "HERMES_WEB_API": "http://upstream.example/sneaky"})
    check("upstream path rejected", r.returncode == 1 and "HERMES_WEB_API" in r.stderr)

    # 5. --require-auth-key: missing key fails only with the flag.
    (home / ".hermes" / ".env").write_text("API_SERVER_KEY=\n", encoding="utf-8")
    r = run_serve(["--check-config"], {"HOME": str(home),
                                       "HERMES_ENV_FILE": str(home / ".hermes" / ".env")})
    check("absent key ok without --require-auth-key", "CONFIG OK" in r.stdout
          and "key_present=False" in r.stdout)
    r = run_serve(["--check-config", "--require-auth-key"],
                  {"HOME": str(home),
                   "HERMES_ENV_FILE": str(home / ".hermes" / ".env")})
    check("absent key fails with --require-auth-key",
          r.returncode == 1 and "API_SERVER_KEY" in r.stderr)

    # 6. Explicit selector to a NONEXISTENT file is a hard fail (no silent
    #    defaults behind an operator's back).
    r = run_serve(["--check-config"], {
        "HOME": str(home), "HERMES_ENV_FILE": str(home / "nope.env")})
    check("explicit missing selector hard-fails", r.returncode != 0
          and "missing" in r.stderr + r.stdout)

    # 7. Default bind (no HERMES_WEB_*, real env file absent): loopback only,
    #    ephemeral port via process env — nothing binds a public interface.
    home = tmp_home()
    root = with_root(home)
    r = subprocess.Popen  # placeholder type for lint
    import socket
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    proc = subprocess.Popen(
        [sys.executable, str(REPO / "web" / "serve.py")],
        stderr=subprocess.PIPE, text=True, env={
            "HOME": str(home), "PATH": os.environ.get("PATH", ""),
            "HERMES_WEB_ROOT": str(root), "HERMES_WEB_PORT": str(port),
        })
    try:
        import time
        ok = False
        for _ in range(60):
            time.sleep(0.1)
            try:
                import urllib.request
                with urllib.request.urlopen(
                        f"http://127.0.0.1:{port}/healthz", timeout=1) as resp:
                    ok = resp.status == 200
                    break
            except Exception:
                continue
        check("default env boots loopback-only", ok)
        err = ""
        with contextlib.suppress(Exception):
            proc.terminate()
            _, err = proc.communicate(timeout=5)
        text = err if isinstance(err, str) else err.decode()
        check("startup prints sources, never the key",
              "HERMES_WEB_HOST=127.0.0.1" in text
              and "API_SERVER_KEY" not in text)
    finally:
        with contextlib.suppress(Exception):
            proc.kill()


if __name__ == "__main__":
    main()
    print(f"{PASS}/{PASS + FAIL} passed")
    sys.exit(0 if FAIL == 0 else 1)
