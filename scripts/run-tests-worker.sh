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
fails=0
for f in "${files[@]}"; do
  if ! timeout 300 flutter test "$f" >"$out/$(basename "$f").log" 2>&1; then
    printf 'FAIL %s\n' "$f" >>"$out/RESULT"
    fails=$((fails + 1))
  fi
done
printf 'SWEEP-DONE fails=%d files=%d\n' "$fails" "${#files[@]}" >>"$out/RESULT"
((fails == 0))
