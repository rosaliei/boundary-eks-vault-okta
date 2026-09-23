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

# public_addr is what the worker ADVERTISES to clients. Without it the worker
# announces 0.0.0.0:9202, which no client can dial - so a client can never be
# routed to it directly and every session takes the multi-hop reverse-connection
# path instead. That path is not instrumented: active_session_count stays 0
# however much traffic flows (measured 2026-09-23, 1815 ProxyChain events
# against a counter reading zero). Direct ingress is what makes the metric work.
#
# It MUST be resolved at boot: every replacement instance gets a new public IP,
# and a stale value means clients dial an address that is no longer there.
PUBLIC_IP=$(imds /latest/meta-data/public-ipv4 2>/dev/null || true)
if [ -n "$PUBLIC_IP" ]; then
  PUBLIC_ADDR_LINE="  public_addr = \"$PUBLIC_IP\""
  log "advertising public_addr $PUBLIC_IP"
else
  PUBLIC_ADDR_LINE=""
  log "no public IPv4 on this instance - worker will be egress-only"
fi

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

# Local-only. Serves BOTH /health?worker_info=1 (worker state) and /metrics
# (the session gauge). The Datadog check and the lifecycle scripts read the
# gauge from /metrics - active_session_count on /health is always 0 here.
# tls_disable is REQUIRED: Boundary refuses to start an ops listener that has
# neither a certificate nor TLS explicitly disabled ("tls not disabled for
# listener ... but no certificate file supplied", exit 3). Both readers use
# plain http:// on the loopback, so disabling is correct here, not a shortcut.
listener "tcp" {
  address     = "127.0.0.1:9203"
  purpose     = "ops"
  tls_disable = true
}

worker {
  controller_generated_activation_token = "${activation}"
  auth_storage_path = "/opt/boundary/worker"
${PUBLIC_ADDR_LINE}

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
