#!/bin/bash
# Measure idle CPU of a running claude_watch instance.
# Idle means: app running, no Claude Code sessions, nothing animating.
APP_NAME=ClaudeWatch
SAMPLES=${1:-12}
INTERVAL=${2:-5}

pid=$(pgrep -x "$APP_NAME" | head -1)
if [ -z "$pid" ]; then
  echo "not running. build and launch first: make run"
  exit 1
fi

echo "sampling pid $pid, ${SAMPLES} samples ${INTERVAL}s apart..."
total=0; peak=0
for i in $(seq 1 "$SAMPLES"); do
  cpu=$(ps -o %cpu= -p "$pid" | tr -d ' ')
  [ -z "$cpu" ] && { echo "process exited"; exit 1; }
  total=$(echo "$total + $cpu" | bc -l)
  peak=$(echo "if ($cpu > $peak) $cpu else $peak" | bc -l)
  printf "  sample %2d: %s%%\n" "$i" "$cpu"
  sleep "$INTERVAL"
done
avg=$(echo "scale=3; $total / $SAMPLES" | bc -l)
echo "----"
echo "average: ${avg}%   peak: ${peak}%"
