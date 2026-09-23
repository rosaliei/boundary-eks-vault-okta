# Automation walkthrough — Terraform and GitHub Actions

Build the autoscaling pool with code. Do
[Build by hand](01-Build-By-Hand.md) first if you have never built it
by hand — this file assumes you know what each piece is for.

Read [README.md](README.md) for **why** it is shaped this way.

---

## What you need before starting

> **Dependency — the base platform.** Build it first with
> [Build by hand](../01-Build-By-Hand.md) or
> [Build with Terraform](../02-Build-With-Terraform.md). This layer
> creates none of it.

| | |
|---|---|
| VPC with public and private subnets | `../aws/` — the pool needs the **public** ones |
| Private EKS cluster | the target every session proxies to |
| Vault with the Kubernetes secrets engine | brokers the per-session credential |
| Boundary target + credential store | `../boundary/` |
| One worker already registered and working | proves the chain before you automate it |
| A Datadog account | API key and application key |
| A GitHub repo | this one, pushed |
| AWS CLI, Terraform, Packer | on your laptop |

---

## Step 1 — The two broker accounts

Creates two Boundary users (one may only create workers, one may only delete
them), their Vault roles, and puts both passwords into Vault. You never see the
passwords.

```bash
cd autoscaling/brokers
cp terraform.tfvars.example terraform.tfvars   # fill in Boundary + Vault addresses
terraform init && terraform apply
```

**Check it worked.** A role existing is not enough — the grant reaches a login
through role → user → account → auth method, and a break anywhere gives a
successful login with no permissions:

```bash
for R in $(boundary roles list -scope-id global -format json \
           | jq -r '.items[]|select(.name|startswith("worker-"))|.id'); do
  U=$(boundary roles read -id $R -format json | jq -r '.item.principals[0].id')
  A=$(boundary users read -id $U -format json | jq -r '.item.account_ids[0] // "NO-ACCOUNT"')
  echo "$R -> $U -> $A"
done
```

`NO-ACCOUNT` means the accounts were never attached to the users. Registration
will fail at boot with `403 PermissionDenied` while the role looks perfect.

---

## Step 2 — One-off AWS parameters

```bash
# Datadog API key, read by each worker at boot. Never baked into the image.
aws ssm put-parameter --name /boundary-worker/datadog_api_key \
  --type SecureString --value '<your key>'

# Placeholder so Terraform can plan before the first AMI exists.
aws ssm put-parameter --name /boundary-worker/ami_id --type String --value ami-placeholder
```

Use the **default** KMS key for the SecureString. A customer-managed key needs
an extra `kms:Decrypt` grant on the worker role.

---

## Step 3 — Bake the AMI

Packer starts a temporary instance in a public subnet, runs the Ansible role,
snapshots it, and deletes the instance.

```bash
cd autoscaling/packer
packer init .
packer build -var vpc_id=<vpc-id> -var subnet_id=<public-subnet-id> .

AMI=$(jq -r '.builds[-1].artifact_id | split(":")[1]' manifest.json)
aws ssm put-parameter --name /boundary-worker/ami_id --type String --value $AMI --overwrite
```

Takes about 9 minutes.

---

## Step 4 — The pool

```bash
cd autoscaling/asg
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply -var github_repo=<owner>/<repo>
```

Creates the IAM role Vault trusts, the security group, the launch template, the
ASG with its lifecycle hook, and the GitHub OIDC role.

**Set `client_cidrs` to your own public IP.** Workers must be reachable on 9202
from wherever you run `boundary connect`, or sessions take the uninstrumented
path and the metric stays at zero. See the README for why.

**Check registration.** About two minutes after apply:

```bash
boundary workers list -format json \
  | jq -r '.items[] | "\(.name)\t\(.address)\t\(.last_status_time)"'
```

You want a `worker-i-…` row with a **public address** and a recent status.

| What you see | Means |
|---|---|
| no row | registration failed → `journalctl -u boundary-register` |
| row, `last_status_time` null | registered but the worker never started → `journalctl -u boundary-worker` |
| address is `0.0.0.0:9202` | no public IP, so no direct ingress and no metric |

---

## Step 5 — Tell the target to use your workers

Do this for **every** target, not just the one you test with:

```bash
for T in <viewer-id> <operator-id> <admin-id>; do
  boundary targets update tcp -id $T \
    -ingress-worker-filter '"eks" in "/tags/type"' \
    -egress-worker-filter  '"eks" in "/tags/type"'
done
```

> **Pass both filters in the same command, then read the target back.**
> `targets update` **replaces** unspecified fields — setting ingress alone
> silently clears egress ("any worker" → uninstrumented path), and the response
> still prints both; only a fresh read shows the truth:
>
> ```bash
> boundary targets read -id $T -format json \
>   | jq '{ingress:.item.ingress_worker_filter, egress:.item.egress_worker_filter}'
> ```
>
> On 2026-09-23 two of three tiers still filtered on an abandoned `k8s_vault`
> tag no worker carries — zero workers selectable, every session failing.
> Findings 2 and 17 in [../notes/Issues.md](../notes/Issues.md).

> **Retire the bootstrap worker before you finish.** The single hand-built
> worker carries the same `eks` tag, but advertises `0.0.0.0:9202` from a
> private subnet — so the ingress filter selects it and the client cannot reach
> it. Stopping the instance is not enough; the registry entry outlives it:
>
> ```bash
> boundary workers delete -id <its-worker-id>
> ```
>
> A worker may carry `eks` only if it is directly reachable. Note
> `aws/boundary-worker.tf` still declares that instance, so an apply in `aws/`
> brings it back.

---

## Step 6 — GitHub secrets

**Settings → Secrets and variables → Actions**

| Secret | Value |
|---|---|
| `AWS_GHA_ROLE_ARN` | `terraform output github_actions_role_arn` |
| `DATADOG_API_KEY`, `DATADOG_APP_KEY` | Datadog → Organization Settings |
| `GH_DISPATCH_TOKEN` | fine-grained PAT, this repo only, *Contents: read and write* |

> **The OIDC trust policy needs GitHub's numeric IDs, not the repo path** — the
> `sub` claim looks like
> `repo:owner@40911856/repo@1358281041:ref:refs/heads/main`, so a policy written
> as `repo:owner/repo:*` never matches and OIDC fails with
> `Not authorized to perform sts:AssumeRoleWithWebIdentity` while looking
> entirely correct. Item 15 in [notes/Issues.md](../notes/Issues.md).

---

## Step 7 — Monitors, webhooks, dashboard

```bash
cd autoscaling/datadog
cp terraform.tfvars.example terraform.tfvars   # keys, github_repo, dispatch token
terraform init && terraform apply
```

Creates two webhooks, the scale-out and scale-in monitors, a stale-worker check,
and the dashboard.

**Prove the chain before trusting it.** Edit the scale-out monitor, change its
condition to *below 1* and save. It fires within a minute on an idle pool, the
webhook posts to GitHub, and a `scale-workers` run appears with
`desired: 1 -> 2`. Change it back.

| What you see | Means |
|---|---|
| monitor red, no workflow run | webhook — bad token or wrong repo |
| run appears, desired unchanged | `max_size` clamp, or already at the bound |
| run fails on OIDC | trust policy `sub` mismatch (see Step 6) |

---

## Step 8 — Load test

```bash
boundary authenticate oidc -auth-method-id <your-oidc-method>
cd autoscaling/scripts
./scale-to-workers.sh 2 <target-id> 25
```

Start with **2 workers**, not 6 — one rung takes about 8 minutes instead of 70.

The script holds enough sessions to keep the average above the threshold, and
tops them up as the pool grows, because the bar rises with pool size:

| workers | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|
| sessions needed for one more | >10 | >20 | >30 | >40 | >50 |

Watch: Datadog dashboard, GitHub Actions, and

```bash
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names boundary-workers \
  --query 'AutoScalingGroups[0].[DesiredCapacity,length(Instances)]' --output text
```

Ctrl-C when you have seen enough. Fifteen minutes of quiet scales it back in.

---

## Step 9 — Hand the AMI build to CI

Push. Any change under `autoscaling/ansible/` or `autoscaling/packer/` on `main`
runs `ami-build.yml`: bake, publish the AMI id to SSM, start an instance refresh.

> The refresh needs headroom. `MinHealthyPercentage=100` launches a replacement
> before removing the old instance, so `max_size` must exceed `desired`. With
> `max_size = 1` the refresh cannot start and `scale.yml` is silently a no-op.

`infra.yml` plans on PRs and applies on `main`. **Before letting it apply the
ASG module**, move `aws/` and `autoscaling/asg/` to an S3 backend — the state is
local today and a runner cannot see it.

---

## Tuning

| Knob | Where | Default |
|---|---|---|
| Scale-out threshold / window | `datadog/variables.tf` | 10 / 5m |
| Scale-in threshold / window | `datadog/variables.tf` | 3 / 15m |
| Pool bounds | `asg/variables.tf` | 1 to 6 |
| Instance type | `asg/variables.tf` | `t3.small` |
| Drain timeout | `boundary-lifecycle.sh` | 240s, inside a 300s hook |
| Client CIDRs | `asg/variables.tf` | your IP |

Raising the scale-out threshold makes the pool cheaper and slower to react.
Lowering the scale-in threshold makes it slower to shrink. Keep them far apart.
