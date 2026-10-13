#!/usr/bin/env bash
# Ensure the per-stage support watchers are alive for a worker tmux session.
#   approve-worker : presses approval prompts   (dies when the tmux session dies)
#   watch-nudge    : types "繼續" when it stalls (exits on done marker / 48h fuse)
# Both self-guard singletons, so this is cheap and idempotent. Called by the
# dispatcher (worker-task-new.sh / pipeline-next.sh) after each dispatch.
# usage: ensure-watchers.sh <tmux-session> <done-marker-abs-path>
set -euo pipefail
S="${1:?tmux session}"
DONE="${2:?done marker path}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for script in approve-worker.sh watch-nudge.sh; do
  if [[ ! -f "$root/scripts/$script" ]]; then
    echo "missing required watcher: $root/scripts/$script" >&2
    exit 1
  fi
done

ensure_one() {
  local script="$1" unit="$2" pattern="$3"
  shift 3
  if pgrep -f "$pattern" >/dev/null; then
    return 0
  fi
  if command -v systemd-run >/dev/null &&
      systemd-run --user --quiet --unit="$unit" \
        bash "$root/scripts/$script" "$@" >/dev/null 2>&1 < /dev/null; then
    :
  elif command -v setsid >/dev/null; then
    setsid bash "$root/scripts/$script" "$@" >/dev/null 2>&1 < /dev/null &
  else
    echo "cannot launch $script" >&2
    return 1
  fi
  for _ in 1 2 3 4 5; do
    sleep 0.2
    if pgrep -f "$pattern" >/dev/null; then
      return 0
    fi
  done
  echo "$script did not start for $S" >&2
  return 1
}

ensure_one approve-worker.sh "hermes-approve-$S" \
  "bash .*approve-worker.sh $S( |\$)" "$S"
ensure_one watch-nudge.sh "hermes-nudge-$S" \
  "bash .*watch-nudge.sh $S " "$S" "$DONE"
echo "both watchers ready for $S"
