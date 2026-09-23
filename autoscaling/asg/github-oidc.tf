# -----------------------------------------------------------------------------
# The role GitHub Actions assumes (secrets.AWS_GHA_ROLE_ARN). No static keys.
# Trust is limited to this repo's main branch. Permissions are exactly what
# scale.yml and ami-build.yml call; infra.yml needs more and is commented on
# in the README (it needs an S3 backend first anyway).
# -----------------------------------------------------------------------------

variable "github_repo" {
  description = "owner/name. Empty string skips creating the GitHub OIDC role."
  type        = string
  default     = ""
}

variable "github_repo_sub" {
  description = <<-DESC
    The `sub` claim GitHub actually puts in the OIDC token, WITHOUT the trailing
    ':*'. It is NOT "owner/repo" - GitHub embeds immutable numeric ids:

      repo:owner@40911856/repo@1358281041

    A trust policy written as "repo:owner/repo:*" never matches and fails with
    "Not authorized to perform sts:AssumeRoleWithWebIdentity" while looking
    completely correct. Cost hours on 2026-09-23; see item 15 in notes/Issues.md.

    Find yours by printing the claims from a throwaway workflow:
      TOKEN=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
        "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" | jq -r .value)
      echo "$TOKEN" | cut -d. -f2 | base64 -d | jq .sub
  DESC
  type        = string
  default     = ""
}

data "tls_certificate" "github" {
  count = var.github_repo == "" ? 0 : 1
  url   = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  count           = var.github_repo == "" ? 0 : 1
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github[0].certificates[0].sha1_fingerprint]
}

resource "aws_iam_role" "github_actions" {
  count = var.github_repo == "" ? 0 : 1
  name  = "boundary-workers-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github[0].arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        # Uses github_repo_sub when set, because GitHub's real sub carries
        # numeric ids and "repo:owner/repo:*" silently never matches.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo_sub != "" ? var.github_repo_sub : var.github_repo}:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions" {
  count = var.github_repo == "" ? 0 : 1
  name  = "scale-and-bake"
  role  = aws_iam_role.github_actions[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Scale"
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:SetDesiredCapacity",
          "autoscaling:StartInstanceRefresh",
        ]
        Resource = "*"
      },
      {
        Sid      = "PublishAmi"
        Effect   = "Allow"
        Action   = ["ssm:PutParameter"]
        Resource = "arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter${var.ami_ssm_parameter}"
      },
      {
        # Packer: temporary instance, key pair, SG, snapshot, AMI.
        Sid    = "Packer"
        Effect = "Allow"
        Action = [
          "ec2:Describe*", "ec2:RunInstances", "ec2:TerminateInstances", "ec2:StopInstances",
          "ec2:CreateTags", "ec2:CreateKeyPair", "ec2:DeleteKeyPair",
          "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup", "ec2:AuthorizeSecurityGroupIngress",
          "ec2:CreateImage", "ec2:RegisterImage", "ec2:DeregisterImage", "ec2:ModifyImageAttribute",
          "ec2:CreateSnapshot", "ec2:DeleteSnapshot", "ec2:CopyImage",
          "ec2:AttachVolume", "ec2:DetachVolume", "ec2:DeleteVolume", "ec2:CreateVolume",
          "ec2:ModifyInstanceAttribute", "ec2:GetPasswordData",
        ]
        Resource = "*"
      },
    ]
  })
}

output "github_actions_role_arn" {
  description = "Put this in the repo secret AWS_GHA_ROLE_ARN"
  value       = var.github_repo == "" ? null : aws_iam_role.github_actions[0].arn
}
