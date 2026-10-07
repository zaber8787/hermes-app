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
root="$HOME/hermes-app"
pgrep -f "bash .*approve-worker.sh $S( |\$)" >/dev/null \
  || systemd-run --user --quiet --unit="hermes-approve-$S" \
       bash "$root/scripts/approve-worker.sh" "$S" >/dev/null 2>&1 < /dev/null \
  || setsid bash "$root/scripts/approve-worker.sh" "$S" >/dev/null 2>&1 < /dev/null &
pgrep -f "bash .*watch-nudge.sh $S " >/dev/null \
  || systemd-run --user --quiet --unit="hermes-nudge-$S" \
       bash "$root/scripts/watch-nudge.sh" "$S" "$DONE" >/dev/null 2>&1 < /dev/null \
  || setsid bash "$root/scripts/watch-nudge.sh" "$S" "$DONE" >/dev/null 2>&1 < /dev/null &
sleep 1
pgrep -af "approve-worker.sh $S|watch-nudge.sh $S" | sed 's/^[0-9]* //' | sort -u
