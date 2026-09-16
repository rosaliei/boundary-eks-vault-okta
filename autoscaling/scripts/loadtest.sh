#!/bin/bash
# Opens N real Boundary sessions to a target and drives HTTP through each.
# Sessions - not requests - are what the pool scales on, so each `boundary
# connect` is one unit of load.
#
#   ./loadtest.sh <N> [target-id] [duration]
#   ./loadtest.sh 25 ttcp_d9cw5TgQOO 10m
#
# Requires: boundary (authenticated), hey  (brew install hey)
set -euo pipefail

N=${1:?sessions}
TARGET=${2:-${BOUNDARY_TARGET_ID:?set BOUNDARY_TARGET_ID or pass target-id}}
DURATION=${3:-10m}
BASE_PORT=20000
pids=()

cleanup() { echo "stopping ${#pids[@]} sessions"; kill "${pids[@]}" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

for i in $(seq 1 "$N"); do
  port=$((BASE_PORT + i))
  boundary connect -target-id "$TARGET" -listen-port "$port" >/dev/null 2>&1 &
  pids+=($!)
  sleep 0.5
  # -c 2 keeps two connections alive through the session for the whole run.
  hey -z "$DURATION" -c 2 -q 5 -disable-keepalive=false \
      "https://127.0.0.1:${port}/version" >/dev/null 2>&1 &
  pids+=($!)
  echo "session $i on :$port"
done

echo "$N sessions open for $DURATION - watch the dashboard. Ctrl-C to stop early."
wait
