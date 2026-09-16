#!/bin/bash
# Shared helpers for the worker scripts. Sourced, not executed.
# /etc/boundary/env is written by the launch template's user-data and holds:
#   BOUNDARY_ADDR, HCP_BOUNDARY_CLUSTER_ID, VAULT_ADDR, AWS_REGION,
#   ASG_NAME, LIFECYCLE_HOOK_NAME

set -euo pipefail
# shellcheck disable=SC1091
source /etc/boundary/env

imds() {
  # IMDSv2 only. A fresh token per call - the lifecycle service polls for days,
  # so a cached token would expire and every later read would fail silently,
  # which would mean never seeing the termination signal.
  local tok
  tok=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60") || return 1
  # Returns non-zero (and prints nothing) when the path is absent.
  curl -sf -H "X-aws-ec2-metadata-token: $tok" "http://169.254.169.254$1"
}

INSTANCE_ID=$(imds /latest/meta-data/instance-id)
export AWS_DEFAULT_REGION="$AWS_REGION"

# The ASG name is written into /etc/boundary/env by user-data; no API call.
asg_name() { echo "$ASG_NAME"; }

active_sessions() {
  # Worker ops listener. Missing/unreachable counts as 0 so a dead worker
  # never blocks termination.
  curl -sf --max-time 2 "http://127.0.0.1:9203/health?worker_info=1" \
    | jq -r '(.worker_process_info // .) | .active_session_count // 0' 2>/dev/null || echo 0
}

# boundary_login <vault-aws-role> <kv-name>
# Logs in to Vault as the instance, reads the broker login for <kv-name>,
# authenticates to Boundary, and exports BOUNDARY_TOKEN. Nothing is written
# to disk.
boundary_login() {
  local vault_role="$1" kv_name="$2"
  local vtoken secret login pass amid

  vtoken=$(vault login -method=aws -field=token role="$vault_role")
  secret=$(VAULT_TOKEN="$vtoken" vault kv get -format=json "secret/boundary/$kv_name")
  login=$(jq -r .data.data.login_name <<<"$secret")
  pass=$(jq -r .data.data.password <<<"$secret")
  amid=$(jq -r .data.data.auth_method_id <<<"$secret")
  unset vtoken secret

  BROKER_PASS="$pass"
  export BROKER_PASS
  BOUNDARY_TOKEN=$(boundary authenticate password \
      -auth-method-id "$amid" -login-name "$login" -password env://BROKER_PASS \
      -keyring-type none -format json | jq -r .item.attributes.token)
  unset BROKER_PASS pass
  export BOUNDARY_TOKEN
}

log() { echo "[$(date -u +%FT%TZ)] $*"; }
