#!/usr/bin/env bash
# Called by the cron driver on a DONE tick; line 8=PENDING is retryable.
# Verifies the current stage finished, then either advances the pipeline
# (dispatch next stage) or declares FINAL-STAGE for acceptance.
set -euo pipefail
TF="${WORKER_TASK_FILE:-$HOME/.hermes/worker-task}"
exec 9>"$TF.lock"
flock -x 9
[ -f "$TF" ] || { echo "no-marker"; exit 1; }
mapfile -t M < "$TF"
TASK="${M[0]:-}"; DONEF="${M[2]:-}"; ID="${M[4]:-}"; STAGE="${M[5]:-0}"
START="${M[1]:-}"; EPOCH="${M[3]:-0}"; TMUX="${M[6]:-}"; STATE="${M[7]:-SENT}"
ROOT="$HOME/hermes-app"
[ -n "$ID" ] || { echo "legacy-marker-no-pipeline"; exit 1; }
LIST="$HOME/.hermes/pipelines/$ID.list"
[ -f "$LIST" ] || { echo "no-pipeline-list $LIST"; exit 1; }
atomic_marker() {
  local tmp
  tmp=$(mktemp "$TF.tmp.XXXXXX")
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$TASK" "$START" "$DONEF" "$EPOCH" "$ID" "$STAGE" "$TMUX" "$STATE" > "$tmp"
  mv -f -- "$tmp" "$TF"
}

dispatch_pending() {
  tmux has-session -t "$TMUX" 2>/dev/null || { echo "no-tmux $TMUX"; return 1; }
  tmux send-keys -t "$TMUX" \
    "請閱讀 $ROOT/$TASK 並照其執行。每批獨立 commit，證據放對應 evidence 目錄，完工 touch $ROOT/$DONEF。" Enter
  STATE=SENT
  atomic_marker
  sleep "${PIPELINE_SEND_SETTLE_SECONDS:-5}"
  if ! tmux capture-pane -t "$TMUX" -p | tail -6 | grep -qE "esc interrupt|Working|esc to interrupt"; then
    tmux send-keys -t "$TMUX" Enter || true
    sleep "${PIPELINE_SEND_SETTLE_SECONDS:-3}"
  fi
  bash "$ROOT/scripts/ensure-watchers.sh" "$TMUX" "$ROOT/$DONEF" >/dev/null \
    || echo "watcher-start-failed $TMUX" >&2
  echo "ADVANCED $ID stage $STAGE -> $TASK (tmux $TMUX)"
}

if [ "$STATE" = PENDING ]; then
  if [ -f "$ROOT/$DONEF" ]; then
    # A stage may finish despite a lost send acknowledgement.
    STATE=SENT
    atomic_marker
  else
    dispatch_pending
    exit 0
  fi
fi

# Runaway guard applies to completed stages; a pending dispatch remains retryable.
NOW=$(date +%s)
if [ $((NOW - EPOCH)) -gt 345600 ]; then echo "pipeline-too-old stop"; exit 1; fi
[ -f "$ROOT/$DONEF" ] || { echo "done-marker-missing $DONEF"; exit 1; }
TOTAL=$(wc -l < "$LIST")
NEXTLINE=$((STAGE + 2))
if [ "$NEXTLINE" -gt "$TOTAL" ]; then echo "FINAL-STAGE task=$TASK done=$DONEF"; exit 0; fi
IFS='|' read -r NTASK NTMUX NDONE < <(sed -n "${NEXTLINE}p" "$LIST")
[ -f "$ROOT/$NTASK" ] || { echo "next-task-missing $NTASK"; exit 1; }
tmux has-session -t "$NTMUX" 2>/dev/null || { echo "no-tmux $NTMUX"; exit 1; }
OLD_DONE="$DONEF"
START=$(git -C "$ROOT" rev-parse HEAD)
TASK="$NTASK"; DONEF="$NDONE"; TMUX="$NTMUX"; STAGE=$((STAGE + 1))
EPOCH="$NOW"; STATE=PENDING
atomic_marker  # rename first; the old done cannot disappear before recovery data exists
rm -f -- "$ROOT/$OLD_DONE"
dispatch_pending
