#!/usr/bin/env bash
# Runs inside the detached service, or inline when systemd-run is unavailable.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$1"
shift
source "$root/scripts/env.sh"
cd "$root/app"

files=("$@")
if ((${#files[@]} == 0)); then
  files=(test/*.dart)
fi
# S7 (2026-10-30 PIPE-AUDIT): per-file wall-clock cap without depending on
# coreutils. Prefer gtimeout, then timeout, else a pure-bash watchdog so a
# hung test file (pending-timer deadlock) cannot freeze the whole sweep.
if command -v gtimeout >/dev/null 2>&1; then
  TMO=("$(command -v gtimeout)")
elif command -v timeout >/dev/null 2>&1; then
  TMO=("$(command -v timeout)")
else
  TMO=()
fi

run_capped() {  # run_capped <secs> <logfile> <cmd...>
  local secs="$1" log="$2"
  shift 2
  if ((${#TMO[@]})); then
    "${TMO[@]}" "$secs" "$@" >"$log" 2>&1
    return $?
  fi
  "$@" >"$log" 2>&1 &
  local pid=$! waited=0 rc=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      pkill -P "$pid" 2>/dev/null
      kill -TERM "$pid" 2>/dev/null
      sleep 2
      pkill -P "$pid" 2>/dev/null
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 5
    waited=$((waited + 5))
  done
  wait "$pid"
  rc=$?
  return "$rc"
}

fails=0
for f in "${files[@]}"; do
  if ! run_capped 300 "$out/$(basename "$f").log" flutter test "$f"; then
    printf 'FAIL %s\n' "$f" >>"$out/RESULT"
    fails=$((fails + 1))
  fi
done
printf 'SWEEP-DONE fails=%d files=%d\n' "$fails" "${#files[@]}" >>"$out/RESULT"
((fails == 0))
