# -----------------------------------------------------------------------------
# Self-managed Boundary Worker (EC2, private subnet)
#
# Why this exists: the EKS API endpoint is private, so HCP Boundary's own
# cloud-hosted workers have no line of sight to it. This worker sits inside the
# VPC and dials OUT to the HCP cluster, giving Boundary a reverse tunnel into
# the private network. The `eks-api` target in ../boundary pins its
# egress_worker_filter to this worker by name.
#
# Registration is worker-led: the instance boots, generates an auth request
# token, and an operator activates it with one CLI call. No Boundary
# credentials are stored in AWS state.
# -----------------------------------------------------------------------------

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# -----------------------------------------------------------------------------
# IAM - SSM Session Manager only (no SSH key, no inbound access)
# -----------------------------------------------------------------------------

resource "aws_iam_role" "boundary_worker" {
  name = "${var.cluster_name}-boundary-worker"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Session Manager is the only way onto this box - it lives in a private subnet
# with no inbound rules and no key pair.
resource "aws_iam_role_policy_attachment" "boundary_worker_ssm" {
  role       = aws_iam_role.boundary_worker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "boundary_worker" {
  name = "${var.cluster_name}-boundary-worker"
  role = aws_iam_role.boundary_worker.name
}

# -----------------------------------------------------------------------------
# Security group
#
# Inbound: nothing from the internet. The worker initiates every connection it
# needs, including the tunnel to HCP. Port 9202 is opened to the VPC only so a
# second worker can be chained (multi-hop) later without a rebuild.
# -----------------------------------------------------------------------------

resource "aws_security_group" "boundary_worker" {
  name        = "${var.cluster_name}-boundary-worker"
  description = "Boundary self-managed worker - egress only, no public ingress"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Boundary proxy from within the VPC (multi-hop workers)"
    from_port   = 9202
    to_port     = 9202
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Outbound covers three things: 443 to the HCP Boundary cluster, 443 to the
  # EKS private endpoint, and package installs over the NAT gateway at boot.
  egress {
    description = "All outbound (HCP cluster, EKS API, package repos, SSM)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-boundary-worker"
  }
}

# -----------------------------------------------------------------------------
# The worker instance
# -----------------------------------------------------------------------------

resource "aws_instance" "boundary_worker" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.boundary_worker_instance_type
  subnet_id              = module.vpc.private_subnets[0]
  vpc_security_group_ids = [aws_security_group.boundary_worker.id]
  iam_instance_profile   = aws_iam_instance_profile.boundary_worker.name

  # Private subnet - reachable only via SSM
  associate_public_ip_address = false

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  user_data_replace_on_change = true
  user_data                   = <<-USERDATA
    #!/bin/bash
    set -euxo pipefail

    # HCP Boundary self-managed workers require the Enterprise binary.
    dnf install -y dnf-plugins-core
    dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
    dnf install -y boundary-enterprise

    id -u boundary >/dev/null 2>&1 || useradd --system --shell /sbin/nologin boundary

    install -d -o boundary -g boundary -m 0750 /etc/boundary
    install -d -o boundary -g boundary -m 0750 /opt/boundary/worker

    cat > /etc/boundary/worker.hcl <<'EOF'
    disable_mlock = true

    # Pointing at the HCP cluster ID is enough - the worker discovers the
    # upstream address itself, so no initial_upstreams block is needed.
    hcp_boundary_cluster_id = "${var.boundary_cluster_id}"

    listener "tcp" {
      address = "0.0.0.0:9202"
      purpose = "proxy"
    }

    worker {
      # No name/description here on purpose: with activation-token-based
      # (worker-led) auth, Boundary rejects a config that sets them and
      # requires they come from the API at registration time. The name is
      # passed to `boundary workers create worker-led -name=...` instead.

      # Where the worker persists its identity after activation. Wiping this
      # directory de-registers the worker and forces a fresh auth request.
      auth_storage_path = "/opt/boundary/worker"

      tags {
        type = ["eks", "vpc", "private"]
      }
    }
    EOF
    chown boundary:boundary /etc/boundary/worker.hcl
    chmod 0640 /etc/boundary/worker.hcl

    cat > /etc/systemd/system/boundary-worker.service <<'EOF'
    [Unit]
    Description=Boundary Worker
    Requires=network-online.target
    After=network-online.target

    [Service]
    User=boundary
    Group=boundary
    ExecStart=/usr/bin/boundary server -config=/etc/boundary/worker.hcl
    Restart=on-failure
    RestartSec=5
    LimitMEMLOCK=infinity
    AmbientCapabilities=CAP_IPC_LOCK

    [Install]
    WantedBy=multi-user.target
    EOF

    # Convenience: prints the worker-led auth request token needed to activate
    # this worker. Reads the file the worker writes, falling back to the log.
    cat > /usr/local/bin/worker-auth-token <<'EOF'
    #!/bin/bash
    if [ -s /opt/boundary/worker/auth_request_token ]; then
      cat /opt/boundary/worker/auth_request_token
      exit 0
    fi
    # Otherwise pull it out of the startup log line the worker emits:
    #   "Worker Auth Registration Request: <token>"
    journalctl -u boundary-worker --no-pager \
      | sed -n 's/.*Worker Auth Registration Request: *\([A-Za-z0-9]*\).*/\1/p' \
      | tail -1
    EOF
    chmod 0755 /usr/local/bin/worker-auth-token

    systemctl daemon-reload
    systemctl enable --now boundary-worker
  USERDATA

  tags = {
    Name = "${var.cluster_name}-boundary-worker"
    Role = "boundary-worker"
  }

  depends_on = [aws_iam_role_policy_attachment.boundary_worker_ssm]
}
