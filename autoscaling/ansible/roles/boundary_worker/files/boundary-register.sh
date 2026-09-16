#!/bin/bash
# Runs once at first boot (systemd: boundary-register.service, before the
# worker). Creates this instance's worker record in HCP Boundary with the
# registrar broker, writes worker.hcl with the one-time activation token, and
# saves the worker id for the deregistration script.
#
# Idempotent: a reboot finds /etc/boundary/worker_id and exits immediately -
# the worker re-authenticates from auth_storage_path on its own.

# shellcheck disable=SC1091
source /usr/local/lib/boundary-common.sh

WORKER_ID_FILE=/etc/boundary/worker_id
if [ -s "$WORKER_ID_FILE" ]; then
  log "already registered as $(cat "$WORKER_ID_FILE"); nothing to do"
  exit 0
fi

WORKER_NAME="worker-${INSTANCE_ID}"
log "registering $WORKER_NAME"

boundary_login boundary-worker-register registrar

resp=$(boundary workers create controller-led \
  -name "$WORKER_NAME" \
  -description "ASG worker ${INSTANCE_ID}, registered by boundary-register.sh" \
  -format json)
unset BOUNDARY_TOKEN

worker_id=$(jq -r .item.id <<<"$resp")
activation=$(jq -r .item.controller_generated_activation_token <<<"$resp")
[ -n "$worker_id" ] && [ "$worker_id" != "null" ] || { log "create failed: $resp"; exit 1; }

# The activation token is single-use; once the worker has authenticated it is
# inert, so leaving it in the config is harmless.
install -o boundary -g boundary -m 0640 /dev/null /etc/boundary/worker.hcl
cat > /etc/boundary/worker.hcl <<EOF
disable_mlock = true
hcp_boundary_cluster_id = "${HCP_BOUNDARY_CLUSTER_ID}"

listener "tcp" {
  address = "0.0.0.0:9202"
  purpose = "proxy"
}

# Local-only. /health?worker_info=1 is what the Datadog check and the
# lifecycle script read active_session_count from.
listener "tcp" {
  address = "127.0.0.1:9203"
  purpose = "ops"
}

worker {
  controller_generated_activation_token = "${activation}"
  auth_storage_path = "/opt/boundary/worker"

  # type=eks is what the eks-api-* targets and the Vault credential store
  # filter on. Every worker in the pool carries it.
  tags {
    type = ["eks", "vpc", "private", "asg"]
    asg  = ["boundary-workers"]
  }
}

events {
  audit_enabled        = true
  observations_enabled = true
  sysevents_enabled    = true
  sink {
    name        = "file"
    format      = "cloudevents-json"
    event_types = ["*"]
    file {
      path      = "/var/log/boundary"
      file_name = "events.log"
    }
  }
}
EOF

echo "$worker_id" > "$WORKER_ID_FILE"
log "registered $WORKER_NAME as $worker_id"
