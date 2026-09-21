#!/usr/bin/env python3
r"""Tracked-tree hygiene gate (ENVHYGIENE §6.1).

Scans tracked files (`--tracked`, default) or a staging directory
(`--export <dir>`) for personal-footprint patterns and exits non-zero with a
`path:line rule-id` list — matched TEXT IS NEVER PRINTED.

Rules live in hygiene_patterns.json next to this script: generic regex rules
(CGNAT IPv4 as a RANGE CLASS, tailnet domains, session-slug shapes, email
and international-phone forms, labelled 17-19 digit platform IDs) plus a
set of SHA-256 hashes of exact known-private strings. The real values appear
nowhere in this file or the pattern file — candidates are extracted
structurally and compared by hash. localhost/::1/example.com and synthetic
test data pass by construction.

Shape checks added after PUBLIC-AUDIT §3: concrete home-user and
C:\Users\<name> components (path text is scanned for EVERY relative-path
component, not just the basename; staging directories themselves are
scanned), and credential assignments whose value is nonempty — empty
values (.env.example style) never hit, exactly documented synthetic test
values pass via the allow_values digests, everything else fails closed.

exit 0 = clean, 1 = hits or unreadable files, 2 = usage error.
"""
import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
PATTERNS = HERE / "hygiene_patterns.json"
# generic, documentable usernames are fine; every OTHER concrete user
# component is a hit (specific operator paths also stay hash-checked)
GENERIC_HOME_USERS = {"user", "users", "example", "root", "ubuntu",
                      "runner", "me", "name", "demo", "sample", "test",
                      "public"}


def load_patterns():
    spec = json.loads(PATTERNS.read_text(encoding="utf-8"))
    spec["regex"] = [(r["id"], re.compile(r["pattern"])) for r in spec["regex"]]
    spec["extract"] = [
        (e["id"], re.compile(e["pattern"]), int(e.get("group", 0)))
        for e in spec["extract"]]
    spec["hashes"] = set(spec["hashes"])
    spec["allow_values"] = {e["value_sha256"] for e in spec.get("allow_values", [])}
    return spec


def h(text: str) -> str:
    return hashlib.sha256(text.lower().encode("utf-8")).hexdigest()


def decode(raw: bytes):
    """utf-8, then utf-16 variants (NUL-rich blobs), else latin-1 so no
    binary content is ever skipped. UTF-16 text decodes CLEANLY as utf-8
    with embedded NULs, which would split every token — NULs must trigger
    the utf-16 retries."""
    cands = []
    try:
        t = raw.decode("utf-8")
        if "\x00" not in t:
            return t
        cands.append(t.count("\x00"))
    except UnicodeDecodeError:
        pass
    for enc in ("utf-16le", "utf-16be"):
        try:
            t = raw.decode(enc)
            if "\x00" not in t[: min(64, len(t))]:
                return t
        except UnicodeDecodeError:
            continue
    return raw.decode("latin-1")


def scan_text(text: str, spec, path_label: str, hits):
    for rule_id, rx in spec["regex"]:
        for m in rx.finditer(text):
            hits.append(f"{path_label}:{text[:m.start()].count(chr(10)) + 1} {rule_id}")
    for rule_id, rx, group in spec["extract"]:
        for m in rx.finditer(text):
            line_no = text[:m.start()].count(chr(10)) + 1
            if rule_id == "credential-value":
                raw = m.group(1)
                if raw is None:
                    continue  # empty value: .env.example-style, never a hit
                value = raw[1:-1] if raw[0] in "\"'" else raw
                if not value:
                    continue
                hv = h(value)
                if hv in spec["allow_values"]:
                    continue  # exactly documented synthetic test value
                if hv in spec["hashes"]:
                    hits.append(f"{path_label}:{line_no} literal-hash:secret")
                else:
                    hits.append(f"{path_label}:{line_no} credential-assignment")
                continue
            token = m.group(group)
            if rule_id in ("home-user", "windows-user-path"):
                if token.lower() in GENERIC_HOME_USERS:
                    continue  # generic, documentable example
                if h(token) in spec["hashes"]:
                    hits.append(f"{path_label}:{line_no} literal-hash:{rule_id}")
                else:
                    hits.append(f"{path_label}:{line_no} concrete-{rule_id}")
                continue
            if h(token) in spec["hashes"]:
                hits.append(f"{path_label}:{line_no} literal-hash:{rule_id}")


def scan_file(path: pathlib.Path, root: pathlib.Path, spec, hits,
              *, allow_symlink=False):
    label = str(path.relative_to(root)) if path.is_relative_to(root) else str(path)
    if path.is_symlink():
        target = os_readlink(path)
        if not allow_symlink:
            hits.append(f"{label}:0 symlink")
        scan_text(target, spec, label, hits)
        scan_text("/" + label.replace(os.sep, "/"), spec, label, hits)
        return
    try:
        raw = path.read_bytes()
    except OSError as exc:
        hits.append(f"{label}:0 unreadable ({exc.__class__.__name__})")
        return
    scan_text(decode(raw), spec, label, hits)
    # the FULL relative path is scanned component-wise (leading "/" makes
    # a staged "home/<user>/…" directory match the same rules as an
    # absolute one); FILENAMES and directory components are scanned too
    scan_text("/" + label.replace(os.sep, "/"), spec, label, hits)


def os_readlink(path: pathlib.Path) -> str:
    try:
        return str(path.readlink())
    except OSError:
        return ""


def tracked_files(root: pathlib.Path):
    out = subprocess.run(["git", "-C", str(root), "ls-files", "-z"],
                         capture_output=True, text=True, check=True)
    return out.stdout.split("\0")[:-1]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tracked", action="store_true")
    ap.add_argument("--export", type=pathlib.Path)
    args = ap.parse_args()
    root = pathlib.Path(__file__).resolve().parent.parent
    spec = load_patterns()
    hits: list[str] = []

    if args.export:
        stage = args.export.resolve()
        if not stage.is_dir():
            print(f"usage error: {stage} is not a directory", file=sys.stderr)
            return 2
        for path in sorted(stage.rglob("*")):
            if any(part == ".git" for part in path.relative_to(stage).parts):
                hits.append(f"{path.relative_to(stage)}:0 git-metadata")
                continue
            if path.is_dir():
                # directories are scanned too: a private-shaped directory
                # cannot hide behind contentless children
                scan_text("/" + str(path.relative_to(stage)).replace(os.sep, "/"),
                          spec, str(path.relative_to(stage)), hits)
                continue
            scan_file(path, stage, spec, hits)  # symlinks hit by design
    else:
        for rel in tracked_files(root):
            path = root / rel
            if not path.exists() and not path.is_symlink():
                hits.append(f"{rel}:0 missing-tracked-file")
                continue
            scan_file(path, root, spec, hits,
                      allow_symlink=not path.is_symlink())
            # a tracked SYMLINK's target is checked (above) and flagged

    if hits:
        for hit in hits:
            print(hit)
        print(f"HYGIENE-GATE: FAIL ({len(hits)} hits)", file=sys.stderr)
        return 1
    mode = "export" if args.export else "tracked"
    print(f"HYGIENE-GATE: CLEAN ({mode})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
