#!/usr/bin/env bash
# SESSIONDIR B1/B1b: precompress a freshly built release directory
# (publish.sh calls this BEFORE the symlink flip, so compression never rides
# a request path). Rules:
#   * every regular file over 1MiB gets .gz (gzip -9 -n -k) and, when the
#     brotli CLI exists, .br (-q 11) — brotli is what pulls the 10Mbps boot
#     under the 5s budget (measured: gzip-only floor 6.9s);
#   * .otf/.ttf font assets get companions regardless of size — the startup
#     font wave is the second-largest boot cost and each file is <1MiB
#     (.woff2 files are already brotli-compressed and are skipped);
#   * originals stay byte-for-byte untouched, .gz/.br inputs are never
#     re-wrapped, rerunning is idempotent.
# serve.py answers companions by Accept-Encoding consent; without them the
# release behaves exactly like before. SSE/API paths are untouched by design.
set -euo pipefail
dir="${1:?usage: compress-release.sh <release-dir>}"
[ -d "$dir" ] || { echo "not a directory: $dir" >&2; exit 2; }
if find "$dir" -type l \( -name '*.gz' -o -name '*.br' \) -print -quit | grep -q .; then
  echo "refusing symlinked compressed companion in release: $dir" >&2
  exit 2
fi
have_brotli=0
command -v brotli >/dev/null 2>&1 && have_brotli=1

find "$dir" -type f -size +1M ! -name '*.gz' ! -name '*.br' -print0 \
  | xargs -0 --no-run-if-empty gzip -9 -n -k -f --
find "$dir" -type f \( -name '*.otf' -o -name '*.ttf' \) ! -name '*.gz' ! -name '*.br' -print0 \
  | xargs -0 --no-run-if-empty gzip -9 -n -k -f --
if [ "$have_brotli" = 1 ]; then
  find "$dir" -type f -size +1M ! -name '*.gz' ! -name '*.br' -print0 \
    | xargs -0 --no-run-if-empty brotli -q 11 -k -f --
  find "$dir" -type f \( -name '*.otf' -o -name '*.ttf' \) ! -name '*.gz' ! -name '*.br' -print0 \
    | xargs -0 --no-run-if-empty brotli -q 11 -k -f --
fi
