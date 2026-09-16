#!/bin/bash
# Launch-template user-data. Everything heavy is already in the AMI; this only
# drops the instance-specific facts and starts the units that wait for them.
# No -x: tracing would print the Datadog API key into cloud-init-output.log.
set -euo pipefail

# --- facts every script reads ------------------------------------------------
install -o root -g boundary -m 0640 /dev/null /etc/boundary/env
cat > /etc/boundary/env <<EOF
BOUNDARY_ADDR=${boundary_addr}
HCP_BOUNDARY_CLUSTER_ID=${hcp_boundary_cluster_id}
VAULT_ADDR=${vault_addr}
AWS_REGION=${aws_region}
ASG_NAME=${asg_name}
LIFECYCLE_HOOK_NAME=${lifecycle_hook_name}
EOF

# --- Datadog: API key from SSM (never in the image), host tags ----------------
TOKEN=$(curl -sS -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
IID=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
DD_KEY=$(aws ssm get-parameter --region ${aws_region} --name "${datadog_api_key_ssm_param}" \
  --with-decryption --query Parameter.Value --output text)

cat > /etc/datadog-agent/datadog.yaml <<EOF
api_key: $DD_KEY
site: ${datadog_site}
hostname: worker-$IID
logs_enabled: true
tags:
  - asg:${asg_name}
  - worker_name:worker-$IID
  - role:boundary-worker
EOF
chown dd-agent:dd-agent /etc/datadog-agent/datadog.yaml
chmod 0640 /etc/datadog-agent/datadog.yaml
systemctl enable --now datadog-agent

# --- register, run, watch ----------------------------------------------------
systemctl start boundary-register.service
systemctl start boundary-worker.service
systemctl start boundary-lifecycle.service
systemctl start boundary-protect.timer
