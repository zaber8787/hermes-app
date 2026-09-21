#!/usr/bin/env python3
"""Fail if any CJK string literal appears outside the catalog (I18N-PLAN §8).

The catalog (app/lib/l10n/catalog.dart) is the single home for translated
text. Protocol literals that must stay byte-identical in both locales are
whitelisted via an `i18n-exempt` marker comment on the literal's line or up
to two lines above (I18N-PLAN §5). Comments and code are never flagged;
only string-literal content is.
"""
import re
import sys
from pathlib import Path

CJK = re.compile(r"[\u3400-\u9fff\uf900-\ufaff\U00020000-\U0002ffff]")
UNESCAPE = re.compile(r"\\u(?:\{([0-9a-fA-F]+)\}|([0-9a-fA-F]{4}))")
EXEMPT = "i18n-exempt"
DEFAULT_APP_ROOT = Path(__file__).resolve().parent.parent / "app"
ALLOWLIST = {Path("lib") / "l10n" / "catalog.dart"}


def _decode_escapes(s):
    return UNESCAPE.sub(
        lambda m: chr(int(m.group(1) or m.group(2), 16)), s
    )


def scan_text(text):
    """(line, snippet) hits for CJK inside Dart string literals, escapes decoded."""
    """Return (line, snippet) hits for CJK inside Dart string literals."""
    hits = []
    i, n = 0, len(text)
    line = 1
    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        if c == "/" and i + 1 < n:
            nxt = text[i + 1]
            if nxt == "/":
                j = text.find("\n", i)
                line += text.count("\n", i, n if j < 0 else j)
                i = n if j < 0 else j
                continue
            if nxt == "*":
                j = text.find("*/", i + 2)
                j = n if j < 0 else j + 2
                line += text.count("\n", i, j)
                i = j
                continue
        if c in "\"'":
            delim = c
            raw = i > 0 and text[i - 1] == "r"
            if text[i : i + 3] in (delim * 3,):
                delim = c * 3
            i += len(delim)
            start_line = line
            content = []
            depth = 0  # inside ${...}
            while i < n:
                ch = text[i]
                if ch == "\\":
                    content.append(text[i : i + 2])
                    if text[i] == "\n":
                        line += 1
                    i += 2
                    continue
                if ch == "\n":
                    if len(delim) == 3:
                        line += 1
                        content.append(ch)
                        i += 1
                        continue
                    break  # unterminated single-line string
                if ch == delim[:1]:
                    if len(delim) == 3:
                        if text[i : i + 3] == delim:
                            i += 3
                            break
                        content.append(ch)
                        i += 1
                        continue
                    if depth == 0:
                        i += 1
                        break
                    content.append(ch)
                    i += 1
                    continue
                if not raw and ch == "$" and i + 1 < n and text[i + 1] == "{":
                    depth += 1
                    content.append("${")
                    i += 2
                    continue
                if not raw and depth > 0 and ch == "{":
                    depth += 1
                if not raw and depth > 0 and ch == "}":
                    depth -= 1
                content.append(ch)
                i += 1
            s = "".join(content)
            probe = s if raw else _decode_escapes(s)
            if CJK.search(probe):
                hits.append((start_line, s[:60]))
            continue
        i += 1
    return hits


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ["--root"]:
        if len(argv) != 2:
            print("usage: i18n_scan.py [--root <app-dir>]", file=sys.stderr)
            return 2
        root = Path(argv[1])
    else:
        if argv:
            print("usage: i18n_scan.py [--root <app-dir>]", file=sys.stderr)
            return 2
        root = DEFAULT_APP_ROOT
    if not root.is_dir():
        print(f"i18n_scan: no app root at {root}", file=sys.stderr)
        return 2
    violations = []
    for path in sorted((root / "lib").rglob("*.dart")):
        rel = path.relative_to(root)
        if rel in ALLOWLIST:
            continue
        if path.is_symlink():
            violations.append(f"{path}: symlink source file (policy: fail)")
            continue
        text = path.read_text(encoding="utf-8")
        lines = text.splitlines()
        for lineno, snippet in scan_text(text):
            window = "\n".join(lines[max(0, lineno - 3) : lineno])
            if EXEMPT in window:
                continue
            violations.append(f"{path}:{lineno}: {snippet}")
    if violations:
        print(f"i18n_scan: {len(violations)} CJK literal(s) outside catalog:")
        for v in violations:
            print(f"  {v}")
        return 1
    print("i18n_scan: clean (catalog-only CJK)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
