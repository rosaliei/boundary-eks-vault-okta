#!/bin/bash
# Hold enough Boundary sessions to grow the worker pool to N, then keep it there.
#
#   ./scale-to-workers.sh [workers] [target-id] [minutes]
#   ./scale-to-workers.sh 2 ttcp_d9cw5TgQOO 25
#
# The monitor fires on AVERAGE sessions per worker, so the bar rises as the pool
# grows: >10 to get a 2nd worker, >20 for a 3rd, >30 for a 4th. This tops the
# session count up as that happens.
#
# Ctrl-C closes everything. The pool scales back in on its own after ~15 min.
set -euo pipefail

WORKERS=${1:-2}
TARGET=${2:-ttcp_d9cw5TgQOO}
MINUTES=${3:-25}

export AWS_PROFILE=${AWS_PROFILE:-pegb}
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-ap-southeast-1}
export BOUNDARY_ADDR=${BOUNDARY_ADDR:-https://95390bdc-e040-47df-8638-7c996c0f98f7.boundary.hashicorp.cloud}

ASG=boundary-workers
THRESHOLD=10          # must match scale_out_sessions_per_worker in datadog/
NAMESPACE=demo-app    # the only namespace the brokered viewer role can read
FIRST_PORT=20100
RECYCLE=700           # brokered tokens live 900s, so restart sessions before that

# ---------------------------------------------------------------- helpers ---

pool_size() {
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
    --query 'length(AutoScalingGroups[0].Instances[?LifecycleState==`InService`])' --output text
}

# One session: open the tunnel, then hold a Kubernetes watch through it.
# The watch must be authenticated and long-lived, or the connection closes and
# the worker's gauge (which counts OPEN connections) never moves.
session() {
  local port=$1 creds token
  creds=$(mktemp)
  boundary connect -target-id "$TARGET" -listen-port "$port" -format json >"$creds" 2>/dev/null &
  sleep 5
  token=$(jq -r '.credentials[0].secret.decoded.service_account_token // empty' "$creds" 2>/dev/null)
  rm -f "$creds"
  while :; do
    curl -sk --no-buffer --max-time 310 -H "Authorization: Bearer $token" \
      "https://127.0.0.1:${port}/api/v1/namespaces/${NAMESPACE}/pods?watch=1&timeoutSeconds=300" \
      >/dev/null 2>&1 || true
  done
}

stop_sessions() {
  local pids
  pids=$(jobs -p) || true
  [ -n "$pids" ] && kill $pids 2>/dev/null
  pkill -f "boundary connect -target-id $TARGET" 2>/dev/null || true
  wait 2>/dev/null || true
}

start_sessions() {
  local count=$1 i
  for i in $(seq 1 "$count"); do
    session $((FIRST_PORT + i)) &
    sleep 0.3
  done
}

trap 'echo; echo "closing sessions..."; stop_sessions; echo "done - pool scales back in after ~15 min of quiet"; exit 0' INT TERM EXIT

# -------------------------------------------------------------- preflight ---

command -v boundary >/dev/null || { echo "boundary CLI not found"; exit 1; }
command -v aws      >/dev/null || { echo "aws CLI not found"; exit 1; }

boundary targets read -id "$TARGET" >/dev/null 2>&1 || {
  echo "Cannot read target $TARGET at $BOUNDARY_ADDR."
  echo "Authenticate first:  boundary authenticate oidc -auth-method-id <amoidc_...>"
  exit 1
}

MAX=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
        --query 'AutoScalingGroups[0].MaxSize' --output text) || {
  echo "Cannot read ASG $ASG as profile $AWS_PROFILE. Check: aws sts get-caller-identity"
  exit 1
}
[ "$MAX" -ge "$WORKERS" ] || {
  echo "ASG max_size is $MAX, below the requested $WORKERS - scale-out would clamp."
  echo "  aws autoscaling update-auto-scaling-group --auto-scaling-group-name $ASG --max-size $WORKERS"
  exit 1
}

echo "target : $WORKERS workers (max $MAX), via $TARGET"
echo "bar    : more than $THRESHOLD sessions per worker, held for 5 minutes"
echo "budget : $MINUTES minutes. Ctrl-C to stop."
echo

# ------------------------------------------------------------------- run ---

deadline=$(( $(date +%s) + MINUTES * 60 ))
running=0
started=0

while [ "$(date +%s)" -lt "$deadline" ]; do
  now=$(date +%s)
  have=$(pool_size)
  want=$(( THRESHOLD * have + 3 ))

  # Restart when the pool grew (need more sessions) or the credentials are old.
  if [ "$want" -ne "$running" ] || [ $(( now - started )) -ge "$RECYCLE" ]; then
    stop_sessions
    start_sessions "$want"
    running=$want
    started=$now
  fi

  printf '[%3dm] workers %d/%d   sessions %d\n' \
    $(( (now - (deadline - MINUTES * 60)) / 60 )) "$have" "$WORKERS" "$running"

  [ "$have" -ge "$WORKERS" ] && echo "       reached $WORKERS - holding"
  sleep 30
done

echo "budget spent"
