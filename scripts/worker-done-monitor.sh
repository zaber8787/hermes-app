#!/usr/bin/env bash
# Worker completion gate for Hermes cron monitor.
# Marker ~/.hermes/worker-task (written by Hermes at dispatch):
#   line1=<task file>  line2=<start sha>  line3=<done marker file>  line4=<dispatch epoch>
# Deterministic output (no timestamps in stdout): unchanged output = no agent run.
#   "waiting"  -> still running, stay silent
#   "DONE ..." -> worker committed new work AND wrote the done marker
#   "STALE"    -> marker older than 2h without completion (watchdog failure)
# The waking agent deletes the marker after verifying/releasing.
m="$HOME/.hermes/worker-task"
[ -f "$m" ] || { echo idle; exit 0; }
task=$(sed -n 1p "$m"); start=$(sed -n 2p "$m"); donef=$(sed -n 3p "$m"); epoch=$(sed -n 4p "$m")
tmuxs=$(sed -n 7p "$m")
head=$(git -C "$HOME/hermes-app" rev-parse HEAD 2>/dev/null)
pane_idle=0
if [ -z "$tmuxs" ] || ! tmux has-session -t "$tmuxs" 2>/dev/null; then
  pane_idle=1
elif ! tmux capture-pane -t "$tmuxs" -p 2>/dev/null | grep -q "esc interrupt" \
     && [ "$(tmux capture-pane -t "$tmuxs" -p 2>/dev/null | md5sum)" = "$(cat /tmp/.nwm-$tmuxs 2>/dev/null)" ]; then
  pane_idle=1
fi
# DONE = done-marker exists. Plan-only tasks legitimately have zero commits,
# so requiring a head move made survey jobs invisible (observed twice).
if [ -f "$HOME/hermes-app/$donef" ]; then
  echo "DONE $task $start $head"
elif [ -n "$start" ] && [ -n "$head" ] && [ "$head" != "$start" ] \
     && [ "$pane_idle" = 1 ]; then
  # Advisory only: another worker may have committed. Never auto-advance on
  # SHA movement without the stage's explicit done marker and evidence review.
  echo "COMMIT_WITHOUT_DONE $task $start $head"
elif [ -n "$tmuxs" ] && tmux has-session -t "$tmuxs" 2>/dev/null \
     && [ "$(date +%s)" -gt $((epoch + 3600)) ] \
     && ! tmux capture-pane -t "$tmuxs" -p 2>/dev/null | grep -q "esc interrupt" \
     && [ "$(tmux capture-pane -t "$tmuxs" -p 2>/dev/null | md5sum)" = "$(cat /tmp/.nwm-$tmuxs 2>/dev/null)" ]; then
  # worker pane unchanged across consecutive checks AND no busy spinner, 1h in: stalled
  echo "STALLED $task (pane idle; check nudge log ~/.hermes/logs/nudge-$tmuxs.log)"
else
  tmux capture-pane -t "${tmuxs:-none}" -p 2>/dev/null | md5sum > /tmp/.nwm-${tmuxs:-none} 2>/dev/null || true
  if tmux capture-pane -t "${tmuxs:-none}" -p 2>/dev/null | grep -q "esc interrupt"; then
    echo waiting
  elif [ -n "$epoch" ] && [ "$(date +%s)" -gt $((epoch + 14400)) ]; then echo STALE; else echo waiting; fi
fi
