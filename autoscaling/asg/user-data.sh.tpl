#!/bin/bash
# Runs once at boot. Everything heavy is already in the AMI; this only writes
# the facts that differ per instance, then starts the units that wait for them.
# No -x: tracing would print the Datadog API key into cloud-init-output.log.
set -euo pipefail

# --- facts every script reads -----------------------------------------------
# `export` on each line, and a QUOTED heredoc, both matter:
#   - the vault and boundary CLIs are child processes and read these from the
#     ENVIRONMENT, so a plain KEY=value that gets sourced never reaches them
#   - quoted, an unrendered template lands here as text instead of killing this
#     script on line 1 with "unbound variable"
install -o root -g boundary -m 0640 /dev/null /etc/boundary/env
cat > /etc/boundary/env <<'EOF'
export BOUNDARY_ADDR=${boundary_addr}
export HCP_BOUNDARY_CLUSTER_ID=${hcp_boundary_cluster_id}
export VAULT_ADDR=${vault_addr}
export AWS_REGION=${aws_region}
export ASG_NAME=${asg_name}
export LIFECYCLE_HOOK_NAME=${lifecycle_hook_name}
EOF

if grep -q '[$]{' /etc/boundary/env; then
  echo "FATAL: user-data was not rendered - these are still placeholders:" >&2
  grep -n '[$]{' /etc/boundary/env >&2
  exit 1
fi

# --- Datadog ----------------------------------------------------------------
# Non-fatal on purpose: the AMI ships the agent with a dummy key, so a failure
# here means metrics go nowhere - it must not also stop the worker registering.
setup_datadog() {
  local token iid key
  token=$(curl -sS -X PUT http://169.254.169.254/latest/api/token \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
  iid=$(curl -sS -H "X-aws-ec2-metadata-token: $token" \
    http://169.254.169.254/latest/meta-data/instance-id)
  key=$(aws ssm get-parameter --region ${aws_region} --name "${datadog_api_key_ssm_param}" \
    --with-decryption --query Parameter.Value --output text)
  [ -n "$key" ] && [ "$key" != "None" ] || return 1

  cat > /etc/datadog-agent/datadog.yaml <<EOF
api_key: $key
site: ${datadog_site}
hostname: worker-$iid
logs_enabled: true
tags:
  - asg:${asg_name}
  - worker_name:worker-$iid
  - role:boundary-worker
EOF
  chown dd-agent:dd-agent /etc/datadog-agent/datadog.yaml
  chmod 0640 /etc/datadog-agent/datadog.yaml

  # restart, not `enable --now`: the RPM already enabled the unit, so systemd
  # started the agent before this script ran and `--now` would be a no-op,
  # leaving it on the AMI's dummy key with logs disabled.
  systemctl enable datadog-agent
  systemctl restart datadog-agent
}

setup_datadog || echo "WARNING: Datadog not configured - check the SSM parameter" >&2

# --- register, run, watch ----------------------------------------------------
systemctl start boundary-register.service
systemctl start boundary-worker.service
systemctl start boundary-lifecycle.service
systemctl start boundary-protect.timer
systemctl start boundary-logperm.timer
