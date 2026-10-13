#!/usr/bin/env python3
"""SESSIONDIR B3: local mirror of the engine's own Noto CJK web-fallback
table, so Chinese readability stops depending on fonts.gstatic.com.

The Flutter web engine embeds a (label -> gstatic path) table of unicode-range
woff2 chunks directly in main.dart.js (verified: 563 notosans{sc,tc,jp,kr,hk}
files for the 5 families — the only "webFontFallback" channel this toolchain
has; there is no bootstrapFonts or fontFallbackFamily in the compiled engine).
We parse the table from the release's own main.dart.js and mirror exactly
those files under web/cjk-mirror/, then the release redirects
window.flutterConfiguration.fontFallbackBaseUrl to the local 'cjk-mirror/'.
The engine asks for the same relative paths it would have asked gstatic;
bytes are the official woff2 chunks, fetched lazily per range exactly like
the hosted versions (zero boot cost), from our own origin, offline-capable.

    python3 web/make-cjk-mirror.py --main-js RELEASE/main.dart.js \
        [--mirror web/cjk-mirror] [--base https://fonts.gstatic.com/s/]

Already-mirrored files are kept (publish works offline once warm); exits 0
only when every table path is present locally, non-zero (with a list count)
otherwise — the publisher then keeps the gstatic default instead of
half-mirroring into tofu.
"""
import argparse
import pathlib
import re
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor

TABLE_RE = re.compile(r'A\.f\("Noto Sans [A-Z]{2} \d+","(notosans[a-z]{2}/v\d+/[^"]+)"\)')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--main-js", type=pathlib.Path, required=True)
    ap.add_argument("--mirror", type=pathlib.Path, default=None)
    ap.add_argument("--base", default="https://fonts.gstatic.com/s/")
    args = ap.parse_args()
    repo = pathlib.Path(__file__).resolve().parents[1]
    mirror = args.mirror or (repo / "web" / "cjk-mirror")
    text = args.main_js.read_text(encoding="utf-8", errors="replace")
    paths = sorted(set(TABLE_RE.findall(text)))
    if not paths:
        sys.exit("make-cjk-mirror: no web-fallback table found in "
                 f"{args.main_js} (engine changed?)")
    missing = [p for p in paths if not (mirror / p).is_file()]
    fetched = 0
    if missing:
        def one(p):
            tmp = mirror / p
            tmp.parent.mkdir(parents=True, exist_ok=True)
            with urllib.request.urlopen(args.base + p, timeout=30) as r:
                data = r.read()
            assert data[:4] == b"wOF2", p
            tmp.write_bytes(data)
        with ThreadPoolExecutor(max_workers=12) as pool:
            futures = [pool.submit(one, p) for p in missing]
            for f in futures:
                f.result()
        fetched = len(missing)
    absent = [p for p in paths if not (mirror / p).is_file()]
    total = sum((mirror / p).stat().st_size for p in paths)
    print(f"make-cjk-mirror: table={len(paths)} fetched={fetched} "
          f"absent={len(absent)} bytes={total}")
    if absent:
        sys.exit(1)


if __name__ == "__main__":
    main()
