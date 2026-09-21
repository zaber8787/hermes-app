#!/usr/bin/env bash
# Per-file flutter test sweep OUTSIDE the interactive session's cgroup: some
# sandboxes cap memory low enough that the Dart VM is killed mid-suite.
# Repo-relative paths — works from any checkout location.
# Usage: run-tests-detached.sh [test/file_test.dart ...]  -> prints unit name;
# default = full per-file sweep; with args only those files run. Results land
# in <repo>/.sweep/RESULT (SWEEP-DONE fails=N) and per-file logs.
# Portable fallback: without systemd-run the sweep runs inline (same per-file
# loop), so any checkout can verify itself.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/.sweep"
rm -rf "$out"; mkdir -p "$out"
files="$*"
sweep='
    source "'"$root"'/scripts/env.sh"
    out="'"$out"'"
    files="'"$files"'"
    fails=0; cd "'"$root"'/app"
    for f in ${files:-test/*.dart}; do
      if ! timeout 300 flutter test "$f" >"$out/$(basename "$f").log" 2>&1; then
        echo "FAIL $f" >>"$out/RESULT"; fails=$((fails+1))
      fi
    done
    echo "SWEEP-DONE fails=$fails files=$(for f in ${files:-test/*.dart}; do echo x; done | wc -l)" >>"$out/RESULT"
'
if command -v systemd-run >/dev/null; then
  unit="hermes-tests-$(date +%s)"
  systemd-run --user --collect --property=MemoryMax=10G \
    --property=MemorySwapMax=infinity --unit="$unit" bash -c "$sweep" 2>&1 | head -1
else
  echo "no systemd-run: running the sweep inline"
  bash -c "$sweep"
fi
echo "out=$out/RESULT"
