#!/usr/bin/env bash
# memguard — dispatch-time memory fence for this 15G box.
# Usage: memguard.sh [min_avail_mb]   (default 6000)
# - stops idle Gradle daemons (they squat 0.6-1.7G each after APK builds)
# - warns (exit 1) when available RAM is below threshold; dispatchers must
#   wait or shed load before launching flutter full suites / gradle builds.
set -euo pipefail
THRESH="${1:-6000}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
meminfo="${HERMES_MEMINFO_PATH:-/proc/meminfo}"
if [[ ! "$THRESH" =~ ^[0-9]+$ ]]; then
  echo "MEMGUARD: invalid threshold" >&2
  exit 1
fi
if [ -x "$root/app/android/gradlew" ]; then
  ( cd "$root/app/android" && ./gradlew --stop >/dev/null 2>&1 ) || true
fi
if ! avail="$(awk '/^MemAvailable:/ {
  if ($2 ~ /^[0-9]+$/) { print int($2 / 1024); found=1 }
  exit
} END { if (!found) exit 1 }' "$meminfo")"; then
  echo "MEMGUARD: cannot read MemAvailable from $meminfo" >&2
  exit 1
fi
echo "avail=${avail}M"
if [ "$avail" -lt "$THRESH" ]; then
  echo "MEMGUARD: below ${THRESH}M — refuse heavy run; stop daemons/builds first"
  exit 1
fi
echo "MEMGUARD: ok"
