#!/bin/bash
# Long-running (systemd: boundary-lifecycle.service). Watches instance
# metadata for two signals that mean "you are being removed":
#   - ASG lifecycle hook:  target-lifecycle-state == Terminated
#   - Spot interruption:   /latest/meta-data/spot/instance-action exists
# Then: drain (wait for 0 sessions, bounded), delete the worker from Boundary
# with the deregistrar broker, and release the lifecycle hook so the ASG can
# terminate the instance. No stale worker is left in Boundary.

# shellcheck disable=SC1091
source /usr/local/lib/boundary-common.sh

DRAIN_TIMEOUT=${DRAIN_TIMEOUT:-240}   # seconds; hook heartbeat is 300
POLL=5

removal_signalled() {
  local state
  state=$(imds /latest/meta-data/autoscaling/target-lifecycle-state 2>/dev/null || echo InService)
  [ "$state" = "Terminated" ] && return 0
  imds /latest/meta-data/spot/instance-action >/dev/null 2>&1 && return 0
  return 1
}

heartbeat() {
  aws autoscaling record-lifecycle-action-heartbeat \
    --lifecycle-hook-name "$LIFECYCLE_HOOK_NAME" \
    --auto-scaling-group-name "$ASG" --instance-id "$INSTANCE_ID" >/dev/null 2>&1 || true
}

drain() {
  local waited=0 n
  while [ "$waited" -lt "$DRAIN_TIMEOUT" ]; do
    n=$(active_sessions)
    if [ "$n" = "0" ]; then log "drained"; return 0; fi
    log "draining: $n active session(s), ${waited}s elapsed"
    heartbeat
    sleep "$POLL"; waited=$((waited + POLL))
  done
  log "drain timeout after ${DRAIN_TIMEOUT}s; proceeding - Boundary will cancel remaining sessions"
}

deregister() {
  local wid
  wid=$(cat /etc/boundary/worker_id 2>/dev/null || true)
  if [ -z "$wid" ]; then log "no worker_id on disk; nothing to deregister"; return 0; fi
  boundary_login boundary-worker-deregister deregistrar
  if boundary workers delete -id "$wid" -format json >/dev/null; then
    log "deregistered $wid"
  else
    log "delete of $wid failed (already gone?) - continuing"
  fi
  unset BOUNDARY_TOKEN
  systemctl stop boundary-worker.service || true
}

log "watching for termination (instance $INSTANCE_ID)"
until removal_signalled; do sleep "$POLL"; done

ASG=$(asg_name)
log "removal signalled by ASG=$ASG"
drain
deregister
aws autoscaling complete-lifecycle-action \
  --lifecycle-hook-name "$LIFECYCLE_HOOK_NAME" \
  --auto-scaling-group-name "$ASG" --instance-id "$INSTANCE_ID" \
  --lifecycle-action-result CONTINUE >/dev/null 2>&1 \
  && log "lifecycle action completed" || log "complete-lifecycle-action failed (spot or hook already expired)"
