locals {
  vpc_id          = data.terraform_remote_state.base.outputs.vpc_id
  vpc_cidr        = data.terraform_remote_state.base.outputs.vpc_cidr_block
  private_subnets = data.terraform_remote_state.base.outputs.private_subnet_ids

  # Workers run in PUBLIC subnets so clients reach them directly on 9202.
  # A worker that only dials out is reached over the multi-hop reverse
  # connection, and that path is not instrumented: active_session_count stays 0
  # however much traffic flows (measured 2026-09-23 — 1815 ProxyChain events
  # against a counter reading zero), so the autoscaling metric never moves.
  # Direct ingress is what makes the signal exist at all. See notes/Issues.md.
  public_subnets = data.terraform_remote_state.base.outputs.public_subnet_ids
  account_id     = data.aws_caller_identity.current.account_id
}

# =============================================================================
# IAM - the identity Vault trusts. Name must match ../brokers.
# =============================================================================

resource "aws_iam_role" "worker" {
  name = var.worker_iam_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.worker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Exactly what the three scripts call, nothing more. sts:GetCallerIdentity
# (what Vault's AWS auth needs) requires no policy.
resource "aws_iam_role_policy" "worker" {
  name = "boundary-worker-lifecycle"
  role = aws_iam_role.worker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "OwnAsgLifecycle"
        Effect = "Allow"
        Action = [
          "autoscaling:CompleteLifecycleAction",
          "autoscaling:RecordLifecycleActionHeartbeat",
          "autoscaling:SetInstanceProtection",
        ]
        Resource = "arn:aws:autoscaling:${var.aws_region}:${local.account_id}:autoScalingGroup:*:autoScalingGroupName/${var.asg_name}"
      },
      {
        Sid      = "DatadogKey"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter${var.datadog_api_key_ssm_parameter}"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "worker" {
  name = var.worker_iam_role_name
  role = aws_iam_role.worker.name
}

# =============================================================================
# Security group - same shape as the single worker: no inbound from anywhere
# except 9202 inside the VPC (multi-hop), all outbound.
# =============================================================================

resource "aws_security_group" "worker" {
  name        = "${var.asg_name}-sg"
  description = "Boundary ASG workers - egress only, 9202 from VPC"
  vpc_id      = local.vpc_id

  ingress {
    description = "Boundary proxy from within the VPC (multi-hop workers)"
    from_port   = 9202
    to_port     = 9202
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  # Direct client ingress. Without this the client cannot reach the worker and
  # every session falls back to the uninstrumented multi-hop path, which is
  # what kept active_session_count at 0. Keep this list tight - it is the only
  # thing between the internet and the worker's proxy port.
  ingress {
    description = "Boundary clients connecting directly to this worker"
    from_port   = 9202
    to_port     = 9202
    protocol    = "tcp"
    cidr_blocks = var.client_cidrs
  }

  egress {
    description = "HCP Boundary, HCP/in-VPC Vault, EKS API, Datadog, SSM, STS"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.asg_name}-sg" }
}

# =============================================================================
# Launch template. AMI id comes from SSM so a new bake never needs a TF change.
# =============================================================================

data "aws_ssm_parameter" "ami" {
  name = var.ami_ssm_parameter
}

resource "aws_launch_template" "worker" {
  name_prefix   = "${var.asg_name}-"
  image_id      = data.aws_ssm_parameter.ami.value
  instance_type = var.instance_type

  iam_instance_profile { name = aws_iam_instance_profile.worker.name }

  # The public subnets do not auto-assign addresses, so the template forces it.
  # No public IP means no dialable public_addr, which means no direct ingress
  # and therefore no session metric. Replaces vpc_security_group_ids, which
  # cannot be combined with a network_interfaces block.
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.worker.id]
    delete_on_termination       = true
  }

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
    # Needed for the lifecycle script to read target-lifecycle-state.
    instance_metadata_tags = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 20
      volume_type = "gp3"
      encrypted   = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/user-data.sh.tpl", {
    boundary_addr             = var.boundary_addr
    hcp_boundary_cluster_id   = var.hcp_boundary_cluster_id
    vault_addr                = var.vault_addr
    aws_region                = var.aws_region
    asg_name                  = var.asg_name
    lifecycle_hook_name       = var.lifecycle_hook_name
    datadog_api_key_ssm_param = var.datadog_api_key_ssm_parameter
    datadog_site              = var.datadog_site
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.asg_name}-worker", Role = "boundary-worker" }
  }

  lifecycle { create_before_destroy = true }
}

# =============================================================================
# ASG. Terraform owns min/max/template/hook; the scale.yml workflow owns
# desired_capacity - hence ignore_changes, so an apply never undoes a scale.
# =============================================================================

resource "aws_autoscaling_group" "worker" {
  name                = var.asg_name
  min_size            = var.asg_min_size
  max_size            = var.asg_max_size
  desired_capacity    = var.asg_min_size
  vpc_zone_identifier = local.public_subnets

  health_check_type         = "EC2"
  health_check_grace_period = 180
  default_cooldown          = 300

  launch_template {
    id      = aws_launch_template.worker.id
    version = "$Latest"
  }

  # Holds a terminating instance in Terminating:Wait until the lifecycle
  # script has deregistered the worker (or 300 s pass). CONTINUE on timeout
  # so a broken script can never wedge the ASG.
  initial_lifecycle_hook {
    name                 = var.lifecycle_hook_name
    lifecycle_transition = "autoscaling:EC2_INSTANCE_TERMINATING"
    heartbeat_timeout    = 300
    default_result       = "CONTINUE"
  }

  # Roll instances when the AMI changes (new SSM value -> new template version).
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100
      instance_warmup        = 120
    }
  }

  tag {
    key                 = "asg"
    value               = var.asg_name
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}
