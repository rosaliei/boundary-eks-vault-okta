# -----------------------------------------------------------------------------
# Bakes the Boundary worker AMI with Ansible. Builds in a PUBLIC subnet of the
# existing VPC (needs package downloads; the temporary instance is deleted at
# the end). Output AMI id lands in manifest.json; the ami-build workflow copies
# it into SSM /boundary-worker/ami_id, which the launch template reads.
#
#   packer init  .
#   packer build -var vpc_id=vpc-... -var subnet_id=subnet-... .
# -----------------------------------------------------------------------------

packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.3.0"
    }
    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = ">= 1.1.0"
    }
  }
}

variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type        = string
  description = "A public subnet in vpc_id (builder needs outbound internet)"
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

locals {
  timestamp = regex_replace(timestamp(), "[- TZ:]", "")
}

data "amazon-ami" "al2023" {
  region      = var.region
  owners      = ["amazon"]
  most_recent = true
  filters = {
    name                = "al2023-ami-2023*-kernel-*-x86_64"
    root-device-type    = "ebs"
    virtualization-type = "hvm"
  }
}

source "amazon-ebs" "worker" {
  region        = var.region
  ami_name      = "boundary-worker-${local.timestamp}"
  instance_type = var.instance_type
  source_ami    = data.amazon-ami.al2023.id
  vpc_id        = var.vpc_id
  subnet_id     = var.subnet_id

  associate_public_ip_address = true
  ssh_username                = "ec2-user"
  ssh_interface               = "public_ip"

  # Temporary SG + key pair are created and destroyed by Packer.
  temporary_security_group_source_cidrs = ["0.0.0.0/0"]

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = {
    Name      = "boundary-worker"
    Role      = "boundary-worker"
    ManagedBy = "packer"
  }
}

build {
  sources = ["source.amazon-ebs.worker"]

  provisioner "ansible" {
    playbook_file = "../ansible/playbook.yml"
    user          = "ec2-user"
    use_proxy     = false
    extra_arguments = [
      "--scp-extra-args", "'-O'",
    ]
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
