#!/usr/bin/env bash
# memguard — dispatch-time memory fence for this 15G box.
# Usage: memguard.sh [min_avail_mb]   (default 6000)
# - stops idle Gradle daemons (they squat 0.6-1.7G each after APK builds)
# - warns (exit 1) when available RAM is below threshold; dispatchers must
#   wait or shed load before launching flutter full suites / gradle builds.
set -u
THRESH="${1:-6000}"
if [ -x "$HOME/hermes-app/app/android/gradlew" ]; then
  ( cd "$HOME/hermes-app/app/android" && ./gradlew --stop >/dev/null 2>&1 ) || true
fi
avail=$(awk '/^MemAvailable/ {print int($2/1024)}' /proc/meminfo)
swapused=$(awk '/^SwapTotal/ {t=$2} /^SwapFree/ {print int(($2*0)+0)}' /proc/meminfo)
swap_mb=$(free -m | awk 'NR==2 {print $3}')
echo "avail=${avail}M swap_used=${swap_mb}M"
if [ "$avail" -lt "$THRESH" ]; then
  echo "MEMGUARD: below ${THRESH}M — refuse heavy run; stop daemons/builds first"
  exit 1
fi
echo "MEMGUARD: ok"
