#!/usr/bin/env bash
# Launch a per-file Flutter sweep in an isolated result directory. A successful
# launch is not a passing suite: wait for out=.../RESULT to say SWEEP-DONE.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$root/.sweep"
out="$(mktemp -d "$root/.sweep/run-XXXXXXXX")"
unit="hermes-tests-${out##*/}"

if command -v systemd-run >/dev/null; then
  if ! launch_output="$(systemd-run --user --collect \
    --property=MemoryMax=10G --property=MemorySwapMax=infinity \
    --unit="$unit" bash "$root/scripts/run-tests-worker.sh" "$out" "$@" 2>&1)"; then
    printf '%s\n' "$launch_output" >&2
    exit 1
  fi
  printf '%s\n' "$launch_output"
else
  echo "no systemd-run: running the sweep inline"
  bash "$root/scripts/run-tests-worker.sh" "$out" "$@"
fi
echo "out=$out/RESULT"
