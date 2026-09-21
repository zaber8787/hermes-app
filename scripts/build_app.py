#!/usr/bin/env python3
"""hermes-app build entry (ENVHYGIENE §4.2). argv-array only — never eval.

  --target apk|web  --mode debug|release  --profile personal|public

* --profile is REQUIRED with no default: "forgot the config" must never
  masquerade as a successful personal build.
* personal APK: reads ONLY HERMES_APP_DEFAULT_URL/HERMES_APP_LEGACY_URL from
  the canonical env file (fail-fast when the default is missing/invalid),
  passes them as two single --dart-define argv entries.
* public: opens NO env file, ignores same-named process env, passes both
  URL defines empty. Web builds are always the public shape (the browser
  learns its own origin at runtime; nothing personal is compiled in).
* API_SERVER_KEY (or any unknown define) is NEVER passed or inherited: the
  build child gets a scrubbed environment and the command line is logged
  without values.
"""
import argparse
import os
import pathlib
import shutil
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import runtime_config  # noqa: E402

URL_DEFINE = "HERMES_APP_DEFAULT_URL"
LEGACY_DEFINE = "HERMES_APP_LEGACY_URL"


def flutter_exe() -> str:
    exe = REPO / "toolchain" / "flutter" / "bin" / "flutter"
    return str(exe) if exe.exists() else shutil.which("flutter") or "flutter"


def pubspec_version() -> str:
    for line in (REPO / "app" / "pubspec.yaml").read_text().splitlines():
        if line.startswith("version:"):
            return line.split(":", 1)[1].strip().split("+")[0]
    raise SystemExit("pubspec version missing")


def personal_defines() -> list[str]:
    try:
        resolver = runtime_config.Resolver()
    except runtime_config.ConfigError as exc:
        raise SystemExit(f"config error: {exc}")
    try:
        default = resolver.resolve(URL_DEFINE, required=True)
        runtime_config.validate_url(default, name=URL_DEFINE, allow_path=True)
    except runtime_config.ConfigError as exc:
        raise SystemExit(
            f"personal builds need {URL_DEFINE} in the env file: {exc}")
    legacy = ""
    try:
        legacy = resolver.resolve(LEGACY_DEFINE, default="")
        if legacy:
            runtime_config.validate_url(legacy, name=LEGACY_DEFINE,
                                        allow_path=True)
    except runtime_config.ConfigError as exc:
        raise SystemExit(f"{LEGACY_DEFINE}: {exc}")
    if legacy == default:
        raise SystemExit(f"{LEGACY_DEFINE} must differ from {URL_DEFINE}")
    return [f"--dart-define={URL_DEFINE}={default}",
            f"--dart-define={LEGACY_DEFINE}={legacy}"]


def clean_if_switched(app: pathlib.Path, marker_name: str) -> None:
    """Controlled intermediates hygiene (§4.2): when the define shape changed
    in this checkout, drop the cached web/app intermediates first."""
    stamp = app / ".build-profile"
    try:
        previous = stamp.read_text() if stamp.exists() else None
    except OSError:
        previous = None
    if previous is not None and previous != marker_name:
        for cache in (app / "build"):
            if cache.exists():
                print(f"profile changed -> cleaning {cache.relative_to(REPO)}")
                shutil.rmtree(cache)
    stamp.write_text(marker_name)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", choices=["apk", "web"], required=True)
    ap.add_argument("--mode", choices=["debug", "release"], required=True)
    ap.add_argument("--profile", choices=["personal", "public"], required=True)
    args = ap.parse_args()

    if args.target == "web" and args.profile == "personal":
        raise SystemExit("web builds are always public (origin comes from the "
                         "browser at runtime)")

    app = REPO / "app"
    version = pubspec_version()
    if args.profile == "public":
        defines = [f"--dart-define={URL_DEFINE}=",
                   f"--dart-define={LEGACY_DEFINE}="]
        source = "empty defines, env file NOT opened"
    else:
        defines = personal_defines()
        source = "personal defines from the canonical env file"

    clean_if_switched(app, f"{args.target}-{args.mode}-{args.profile}")

    cmd = [flutter_exe(), "build", args.target]
    cmd += ["--debug" if args.mode == "debug" else "--release"]
    if args.target == "web":
        cmd += ["--no-web-resources-cdn",
                f"--dart-define=APP_VERSION={version}-web"]
    # (apk: APP_VERSION keeps its existing source — the web bundle is the
    #  version-stamped artifact; do not introduce a new apk define here.)
    cmd += defines
    # Values may be deployment addresses; never echo defines with values,
    # never forward the API key to the child.
    print("build:", " ".join(
        c if not c.startswith("--dart-define=")
        else c.split("=", 1)[0] + "=<set>"
        for c in cmd[1:]), f"({source})")
    child_env = dict(os.environ)
    child_env.pop("API_SERVER_KEY", None)
    for name in (URL_DEFINE, LEGACY_DEFINE):
        child_env.pop(name, None)  # defines come from the file, not ambient env
    subprocess.run(cmd, cwd=app, env=child_env, check=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
