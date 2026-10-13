#!/usr/bin/env python3
"""SESSIONDIR B1: precompressed (.gz) static serving, in an isolated root.

    python3 web/test_serve_gzip.py           # run the suite (exit 0 = green)

serve.py must prefer a published .gz companion for Accept-Encoding: gzip
requests (Content-Encoding + original Content-Type + Vary) while the etag/
no-cache revalidation semantics stay byte-identical to the plain path, and
must behave EXACTLY as today when no companion exists. The publish side is
covered too: compress-release.sh gzips main.dart.js / canvaskit wasm / any
file over 1MiB in place (originals kept, .gz never recursed, deterministic).
Red-on-old: without the feature the gz request answers with no
Content-Encoding, and compress-release.sh does not exist.
"""
import gzip
import hashlib
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

REPO = pathlib.Path(__file__).resolve().parents[1]
DETAILS = []


def check(condition, message):
    if not condition:
        raise AssertionError(message)
    DETAILS.append(message)


def get(url, headers=()):
    req = urllib.request.Request(url, headers=dict(headers))
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, {k.lower(): v for k, v in resp.headers.items()}, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, {k.lower(): v for k, v in e.headers.items()}, e.read()


class Server:
    def __init__(self, root):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        self.port = s.getsockname()[1]
        s.close()
        self.home = pathlib.Path(tempfile.mkdtemp(prefix="gzip-home-"))
        (self.home / ".hermes").mkdir(exist_ok=True)
        env_file = self.home / ".hermes" / ".env"
        env_file.write_text("API_SERVER_KEY=\n")
        self.proc = subprocess.Popen(
            [sys.executable, str(REPO / "web" / "serve.py")],
            stderr=subprocess.PIPE, text=True, env={
                "HOME": str(self.home), "PATH": os.environ.get("PATH", ""),
                "HERMES_ENV_FILE": str(env_file),
                "HERMES_WEB_ROOT": str(root), "HERMES_WEB_PORT": str(self.port),
            })
        for _ in range(80):
            time.sleep(0.1)
            try:
                code, _, _ = get(f"http://127.0.0.1:{self.port}/healthz")
                if code == 200:
                    return
            except Exception:
                continue
        raise RuntimeError("serve.py did not boot: " + (self.proc.stderr.read()[-2000:] if self.proc.poll() else "alive"))

    def url(self, path):
        return f"http://127.0.0.1:{self.port}{path}"

    def close(self):
        self.proc.terminate()
        self.proc.wait(timeout=10)


def main():
    root = pathlib.Path(tempfile.mkdtemp(prefix="gzip-root-"))
    (root / "index.html").write_text("<html>dir</html>")
    js = (b"var hermes=function(){};\n" * 8192)          # ~180 KiB
    (root / "main.dart.js").write_bytes(js)
    wasm = hashlib.sha256(b"wasm").digest() * 20480      # 640 KiB pseudo-binary
    (root / "canvaskit").mkdir()
    (root / "canvaskit" / "canvaskit.wasm").write_bytes(wasm)
    (root / "main.dart.js.gz").write_bytes(gzip.compress(js, 9, mtime=0))
    (root / "canvaskit" / "canvaskit.wasm.gz").write_bytes(gzip.compress(wasm, 9, mtime=0))
    (root / "manifest.json").write_bytes(b'{"a":1}')     # no .gz companion

    # 1. gz companion + Accept-Encoding -> Content-Encoding gzip, correct
    #    inner Content-Type/Length, Vary, and bytes that gunzip to the original.
    srv = Server(root)
    try:
        code, headers, body = get(srv.url("/main.dart.js"),
                                  [("Accept-Encoding", "gzip, deflate, br")])
        check(code == 200, "gz request HTTP200")
        check(headers.get("content-encoding") == "gzip",
              f"gz companion served with Content-Encoding (red-on-old: {headers.get('Content-Encoding')})")
        check("javascript" in headers.get("content-type", ""),
              f"Content-Type stays the JS type, not octet-stream: {headers.get('Content-Type')}")
        check(int(headers.get("content-length", -1)) == len(body) == (root / "main.dart.js.gz").stat().st_size,
              "Content-Length equals the compressed transfer size")
        check(gzip.decompress(body) == js, "gunzipped body byte-equals the original")
        check("Accept-Encoding" in headers.get("vary", ""),
              "variant is advertised through Vary (cache correctness)")
        check(headers.get("cache-control") == "no-cache", "no-cache revalidation semantics unchanged")
        gz_etag = headers.get("etag")
        check(bool(gz_etag), "a validator is present on the gz path")

        # 2. same URL WITHOUT Accept-Encoding -> plain bytes, same ETag.
        code, headers, body = get(srv.url("/main.dart.js"))
        check(code == 200 and "Content-Encoding" not in headers and body == js,
              "no Accept-Encoding keeps today's plain behavior")
        plain_etag = headers.get("etag")
        check(bool(plain_etag), "plain path keeps its validator")

        # 3. wasm keeps its type through the encoding.
        code, headers, body = get(srv.url("/canvaskit/canvaskit.wasm"),
                                 [("Accept-Encoding", "gzip")])
        check(code == 200 and headers.get("content-encoding") == "gzip",
              "wasm companion served encoded")
        check(headers.get("content-type") == "application/wasm",
              f"wasm Content-Type preserved: {headers.get('Content-Type')}")
        check(gzip.decompress(body) == wasm, "wasm bytes roundtrip")

        # 3b. q-value negotiation: an explicit refusal (gzip;q=0) is NOT
        #     consent — red-on-old: aiohttp's sibling auto-discovery matches
        #     "gzip" as a SUBSTRING of the header and would encode anyway.
        code, headers, body = get(srv.url("/main.dart.js"),
                                  [("Accept-Encoding", "gzip;q=0, identity")])
        check(code == 200 and "content-encoding" not in headers and body == js,
              "gzip;q=0 must receive the plain body (refusal is not acceptance)")

        # 4. NO companion -> behavior identical to today (plain, no encoding).
        code, headers, body = get(srv.url("/manifest.json"),
                                  [("Accept-Encoding", "gzip")])
        check(code == 200 and "Content-Encoding" not in headers
              and body == (root / "manifest.json").read_bytes(),
              "missing companion falls back to the plain file")

        # 5. If-None-Match answers 304 on both variants (revalidation stays cheap).
        code, headers, _ = get(srv.url("/main.dart.js"),
                               [("If-None-Match", gz_etag), ("Accept-Encoding", "gzip")])
        check(code == 304, "gz variant revalidates with 304")
        code, headers, _ = get(srv.url("/main.dart.js"),
                               [("If-None-Match", plain_etag)])
        check(code == 304, "plain variant revalidates with 304")

        # 5b. a publish swap (new bytes => new stat) invalidates BOTH variants
        #     so an in-place-updated root can never be answered 304 stale
        #     (WEBSYNC F6 semantics carried onto the encoded variant).
        swapped = gzip.compress(js + b"//v2\n", 9, mtime=0)
        (root / "main.dart.js").write_bytes(js + b"//v2\n")
        (root / "main.dart.js.gz").write_bytes(swapped)
        code, headers, _ = get(srv.url("/main.dart.js"),
                               [("If-None-Match", gz_etag), ("Accept-Encoding", "gzip")])
        check(code == 200 and gzip.decompress(_ ) == js + b"//v2\n",
              "swapped release beats the stale validator")

        # 5c. SESSIONDIR B1b: brotli beats gzip when both are consented (the
        #     10Mbps boot budget needs the ~35% extra; report-sanctioned).
        #     red-on-old: only .gz exists, so AE:gzip,br still gets gzip.
        br = gzip.compress(js)  # placeholder bytes, role is pure transfer
        (root / "main.dart.js.br").write_bytes(br)
        try:
            code, headers, body = get(srv.url("/main.dart.js"),
                                     [("Accept-Encoding", "gzip, deflate, br")])
            check(code == 200 and headers.get("content-encoding") == "br"
                  and body == br,
                  "br companion preferred when both encodings are consented")
            code, headers, body = get(srv.url("/main.dart.js"),
                                      [("Accept-Encoding", "gzip")])
            check(code == 200 and headers.get("content-encoding") == "gzip",
                  "gzip still served without br consent")
        finally:
            (root / "main.dart.js.br").unlink()

        # S2: a companion symlink outside the public root must not be served.
        private = pathlib.Path(tempfile.mkdtemp(prefix="gz-private-"))
        for ext, encoding in ((".gz", "gzip"), (".br", "br")):
            companion = root / ("main.dart.js" + ext)
            saved = companion.read_bytes() if companion.exists() else None
            if companion.exists():
                companion.unlink()
            canary = private / ("canary" + ext)
            canary.write_bytes(b"private-companion-canary")
            companion.symlink_to(canary)
            try:
                code, headers, body = get(srv.url("/main.dart.js"),
                                          [("Accept-Encoding", encoding)])
                check(code == 200 and body == js + b"//v2\n"
                      and "content-encoding" not in headers,
                      f"{encoding} companion outside root falls back to public plain file")
            finally:
                companion.unlink()
                if saved is not None:
                    companion.write_bytes(saved)
    finally:
        srv.close()


    # 6. publish-side compressor: >1MiB files and the named boot assets get a
    #    deterministic .gz; small files and .gz inputs never get recursed.
    comp = REPO / "web" / "compress-release.sh"
    check(comp.is_file(), "web/compress-release.sh exists (red-on-old: missing)")
    if comp.is_file():
        rel = pathlib.Path(tempfile.mkdtemp(prefix="gz-release-"))
        big = rel / "main.dart.js"
        big.write_bytes(hashlib.sha256(b"js").digest() * 65536)     # 2 MiB
        small = rel / "index.html"
        small.write_bytes(b"<html></html>")
        (rel / "canvaskit").mkdir()
        (rel / "canvaskit" / "canvaskit.wasm").write_bytes(bytes(1 << 10) * 1200)  # ~1.2 MiB
        tiny_wasm = rel / "canvaskit" / "tiny.wasm"
        tiny_wasm.write_bytes(b"x" * 512)
        font = rel / "assets" / "fonts"
        font.mkdir(parents=True)
        (font / "small.ttf").write_bytes(hashlib.sha256(b"f").digest() * 4096)  # 128KiB
        (rel / "version.json").write_bytes(b'{"version":"x"}')
        before = hashlib.sha256(big.read_bytes()).hexdigest()
        subprocess.run(["bash", str(comp), str(rel)], check=True)
        check(big.with_suffix(".js.gz").is_file(), "main.dart.js gets a gz companion")
        check((rel / "canvaskit" / "canvaskit.wasm.gz").is_file(),
              "canvaskit wasm over the threshold gets a gz companion")
        check(not small.with_name("index.html.gz").exists(),
              "sub-1MiB files are left alone")
        check(not tiny_wasm.with_name("tiny.wasm.gz").exists(),
              "tiny wasm is left alone")
        check(not (rel / "version.json.gz").exists(), "version.json is not gzipped")
        check(font.joinpath("small.ttf.gz").is_file(),
              "sub-MiB startup font assets get companions too (boot wave #2)")
        check(hashlib.sha256(big.read_bytes()).hexdigest() == before,
              "originals stay byte-identical (only companions are added)")
        listing = sorted(p.name for p in rel.rglob("*.gz"))
        subprocess.run(["bash", str(comp), str(rel)], check=True)
        check(sorted(p.name for p in rel.rglob("*.gz")) == listing,
              "rerun is idempotent and never gzips a .gz")
        check(gzip.decompress(big.with_suffix(".js.gz").read_bytes()) == big.read_bytes(),
              "published companion gunzips to the served original")
        private = pathlib.Path(tempfile.mkdtemp(prefix="gz-publish-private-"))
        (private / "canary.gz").write_bytes(b"private")
        (rel / "main.dart.js.gz").unlink()
        (rel / "main.dart.js.gz").symlink_to(private / "canary.gz")
        refused = subprocess.run(["bash", str(comp), str(rel)], capture_output=True)
        check(refused.returncode != 0,
              "publisher rejects a symlinked compressed companion")

    print(f"WEB-GZIP: PASS ({len(DETAILS)} assertions)")


if __name__ == "__main__":
    try:
        main()
    except AssertionError as exc:
        print(f"WEB-GZIP: FAIL: {exc}")
        sys.exit(1)
