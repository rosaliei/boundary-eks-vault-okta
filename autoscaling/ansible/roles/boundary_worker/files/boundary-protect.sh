#!/bin/bash
# Every minute (systemd timer). Sets ASG scale-in protection ON while this
# worker has sessions and OFF when idle, so a scale-in always removes an idle
# worker and never one with live connections. Only calls AWS when the state
# actually changes.

# shellcheck disable=SC1091
source /usr/local/lib/boundary-common.sh

STATE_FILE=/run/boundary-protect.state
n=$(active_sessions)
want=$([ "$n" -gt 0 ] && echo on || echo off)
have=$(cat "$STATE_FILE" 2>/dev/null || echo unknown)
[ "$want" = "$have" ] && exit 0

flag=$([ "$want" = on ] && echo --protected-from-scale-in || echo --no-protected-from-scale-in)
aws autoscaling set-instance-protection \
  --instance-ids "$INSTANCE_ID" --auto-scaling-group-name "$(asg_name)" "$flag"
echo "$want" > "$STATE_FILE"
log "scale-in protection $want ($n sessions)"
