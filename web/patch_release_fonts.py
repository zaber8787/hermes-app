#!/usr/bin/env python3
"""SESSIONDIR B3 release post-processor (publish-time only, never at
request time).

The engine's CJK readability path is its web-font fallback table: relative
gstatic paths compiled into main.dart.js. We mirror exactly those files into
the release under cjk-mirror/ (make-cjk-mirror.py, warm cache = offline) and
point window.flutterConfiguration.fontFallbackBaseUrl at the local copy.
The engine then lazily fetches the SAME official woff2 range chunks from our
origin — zero boot cost, readable Chinese without fonts.gstatic.com.

B2 (deferring the declared-font preload) measured UNSUPPORTED on this
toolchain: the compiled engine contains no bootstrapFonts nor
fontFallbackFamily switch (grep: 0 hits), and the window.flutterConfiguration
channel proves it — every declared font still fetched at boot. Deferral
therefore needs an engine/app change (out of this batch's web-only scope);
the font wave is instead made cheap via B1b's font companions.

    python3 web/patch_release_fonts.py <release-dir> [--mirror DIR]

Exits non-zero unless every table path is mirrored; a half-mirror would turn
Chinese into tofu, worse than the gstatic default it replaces.
"""
import argparse
import pathlib
import re
import shutil
import subprocess
import sys

ANCHOR = "_flutter.loader.load({"
# The compiled engine joins fallback paths onto the gstatic base itself and
# ignores window.flutterConfiguration.fontFallbackBaseUrl for these fetches
# (measured: config set+read, chunks still fetched from gstatic). Every chunk
# download does go through window.fetch with the absolute gstatic URL, so a
# tiny fetch shim reroutes exactly those URLs into the release.
TABLE_RE = re.compile(r'A\.f\("Noto Sans [A-Z]{2} \d+","(notosans[a-z]{2}/v\d+/[^"]+)"\)')
# B2 (as prefetch): the engine preloads every declared font only AFTER JS
# boot (serial tail; per-font deferral needs an engine switch this build
# lacks). A low-priority prefetch starts the instant the entry script's
# DOWNLOAD finishes (ResourceTiming poll: js is the one stream the first
# frame waits on; fonts must never slow it further), so the end-of-boot
# manifest fetch finds warm cache -> cheap 304 rounds, no half-second tail.
PREFETCH = (
    "(function(){/*cjk-prefetch*/var p=function(){setTimeout(function(){"
    "fetch('assets/FontManifest.json',{fetchpriority:'low'})"
    ".then(function(r){return r.json()}).then(function(m){m.forEach(function(f){"
    "(f.fonts||[]).forEach(function(x){fetch('assets/'+x.asset,"
    "{mode:'cors',fetchpriority:'low'})})})}).catch(function(){})},50)};"
    "var U=new URL('main.dart.js',location.href).href;"
    "var t=setInterval(function(){try{"
    "var e=performance.getEntriesByName(U);"
    "if(e.length&&e[0].responseEnd>0){clearInterval(t);p();return}"
    "}catch(x){clearInterval(t);return}"
    "if(performance.now()>12000)clearInterval(t)},150);})();"
    "\n")
SHIM = (
    "(function(){var B=new URL('cjk-mirror/',document.baseURI).href,"
    "_f=window.fetch;window.fetch=function(u){try{var s=String(u),"
    "i=s.indexOf('fonts.gstatic.com/s/');"
    "if(i>=0)return _f.call(this,B+s.slice(i+20),arguments[1])}catch(e){}"
    "return _f.apply(this,arguments)}})();\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("release", type=pathlib.Path)
    ap.add_argument("--mirror", type=pathlib.Path, default=None)
    ap.add_argument("--base", default=None)
    args = ap.parse_args()
    repo = pathlib.Path(__file__).resolve().parents[1]
    release = args.release
    if not (release / "main.dart.js").is_file():
        sys.exit(f"patch_release_fonts: not a release dir: {release}")
    mirror = args.mirror or (repo / "web" / "cjk-mirror")
    cmd = [sys.executable, str(repo / "web" / "make-cjk-mirror.py"),
           "--main-js", str(release / "main.dart.js"), "--mirror", str(mirror)]
    if args.base:
        cmd += ["--base", args.base]
    r = subprocess.run(cmd, check=False)
    if r.returncode != 0:
        sys.exit("patch_release_fonts: mirror incomplete — refusing to "
                 "redirect the fallback base into 404 tofu (keep gstatic)")
    wanted = sorted(set(TABLE_RE.findall(
        (release / "main.dart.js").read_text(encoding="utf-8", errors="replace"))))
    dest = release / "cjk-mirror"
    dest.mkdir(exist_ok=True)
    for rel in wanted:
        src = mirror / rel
        out = dest / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        if not out.is_file() or out.stat().st_size != src.stat().st_size:
            shutil.copyfile(src, out)
    path = release / "flutter_bootstrap.js"
    text = path.read_text(encoding="utf-8")
    if "cjk-mirror/" not in text and text.count(ANCHOR) != 1:
        sys.exit(f"patch_release_fonts: loader anchor x{text.count(ANCHOR)} "
                 f"in {path}; refusing to guess")
    if "cjk-mirror/" not in text:
        text = text.replace(ANCHOR, SHIM + ANCHOR, 1)
        print("bootstrap: gstatic fetches rerouted to cjk-mirror/")
    if "cjk-prefetch" not in text:
        text = text.replace(ANCHOR, PREFETCH + ANCHOR, 1)
        print("bootstrap: font prefetch gated on entry-script download")
    path.write_text(text, encoding="utf-8")
    patch_preloads(release)


PRELOAD_MARK = "<!-- cjk-preload -->"


def patch_preloads(release: pathlib.Path):
    """The entry script is the stream the first frame waits on: preload it
    in <head> so its download starts before the flutter_bootstrap round
    trip. Font preload LINKS are deliberately not emitted — Chrome defers
    them past first paint on throttled networks (measured: zero early font
    fetches under 10Mbps emulation); the PREFETCH snippet covers those."""
    index = release / "index.html"
    html = index.read_text(encoding="utf-8")
    if PRELOAD_MARK in html:
        print("index: unchanged (preload present)")
        return
    html = html.replace(
        "</head>",
        '<link rel="preload" as="script" href="main.dart.js">' + PRELOAD_MARK
        + "</head>", 1)
    index.write_text(html, encoding="utf-8")
    print("index: entry script preload added")


if __name__ == "__main__":
    main()
