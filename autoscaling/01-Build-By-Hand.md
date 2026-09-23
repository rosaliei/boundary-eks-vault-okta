# Manual walkthrough — build the autoscaling loop by hand once

Same result as the Terraform in this folder, done click by click so each moving
part is something you have touched. Do this once, draw it, then let
[Build with Terraform](02-Build-With-Terraform.md) own it.

[README.md](README.md) explains **why** the design is shaped this way — read it
first if any step here looks arbitrary.

> **Dependency — the base platform.** Everything here builds on the VPC, the
> private EKS cluster, Vault's Kubernetes secrets engine and the Boundary
> targets from [Build by hand](../01-Build-By-Hand.md). Have one
> worker registered and a session working before you start.

Every part ends with **See it** — the thing to look at that proves the step
worked. Those are the boxes and arrows of your drawing.

```
 A  identities      Boundary UI  +  Vault CLI
 B  AWS by hand     SSM parameter, IAM role, security group, launch template, ASG + lifecycle hook
 C  first worker    log in to the instance and run the registration by hand, line by line
 D  Datadog         metric explorer, webhook, two monitors
 E  GitHub          secrets, run the scale workflow by hand
 F  SCALE OUT       watch it happen end to end
 G  SCALE IN        watch it happen end to end
```

Constants used below:

| | |
|---|---|
| HCP Boundary | `https://95390bdc-e040-47df-8638-7c996c0f98f7.boundary.hashicorp.cloud` |
| Boundary global password auth method | `ampw_WNbi76VghW` — the *initial* one ("Generated global scope initial password auth method"). The admin account lives here, the two broker accounts get created here in A1, and the Terraform provider + rotate workflow authenticate against it. ONE method for all three. |
| Boundary Okta OIDC auth method (org scope, primary) | `amoidc_eY8ldrT0GG` — used in part F and by humans; unrelated to the workers |
| Vault (from inside the VPC) | `http://aa837cd050a9d43028df5e6987267f93-d3fb677640c1fdfb.elb.ap-southeast-1.amazonaws.com:8200` |
| AWS account / region | `173310766280` / `ap-southeast-1` |
| VPC | `10.0.0.0/16`, private subnets `10.0.1-3.0/24` |
| Worker tag the targets filter on | `type=eks` — carried by the hand-registered worker (`kst-eks-ap-southeast-1-worker-01`) and every ASG worker, so all of them are one pool |

---

## A — Identities

### A1. Boundary UI: two broker accounts on the EXISTING method, one verb each

> **Account ≠ auth method — this is the one place this walkthrough was done
> wrong once already.** The brokers are **Accounts** created *inside* the
> existing global password method `ampw_WNbi76VghW` (Auth Methods → that method
> → **Accounts** tab → New). Do **not** use *Auth Methods → New* — that creates
> a separate login realm, splits the two brokers across two realms the
> Terraform and the rotation workflow cannot address, and leaves the docs,
> the Vault secrets and `rotate-broker-creds.yml` pointing at an id you then
> have to chase. One auth method, three accounts on it: `admin`,
> `worker-registrar`, `worker-deregistrar`.
>
> **Recovery if two stray auth methods already exist** (as found live on
> 2026-09-17: `ampw_ARewCYhH63` "worker-registrar", `ampw_DYtMf796Nf`
> "worker-deregistrar"): recreate the accounts on `ampw_WNbi76VghW` per this
> section, re-point the two Vault KV secrets at it (A2 step 4 with
> `auth_method_id=ampw_WNbi76VghW`), log in once as each broker to prove the
> logins work, then empty the stray methods of accounts and delete them:
>
> ```bash
> export BOUNDARY_ADDR=https://95390bdc-e040-47df-8638-7c996c0f98f7.boundary.hashicorp.cloud
> boundary auth-methods list -scope-id global -format json | jq -r '.items[] | "\(.id)\t\(.name)"'
> boundary accounts list -scope-id global -format json | jq -r '.items[] | "\(.id)\t\(.auth_method_id)\t\(.login_name)"'
> # for each account still on the stray methods:
> boundary accounts delete -id acct_xxxx
> boundary auth-methods delete -id ampw_ARewCYhH63
> boundary auth-methods delete -id ampw_DYtMf796Nf
> ```

Log in to the Boundary admin UI as `admin` (password auth). Stay in the
**Global** scope for all of this — workers are global resources.

**Accounts**

1. Global → **Auth Methods** → the password method (`ampw_WNbi76VghW`) → **Accounts** tab → **New Account**
2. Login name `worker-registrar`, a 32-char password (generate one; you will paste it into Vault in A2). Save.
3. Repeat: `worker-deregistrar`.

**Users**

4. Global → **Users** → **New**: name `worker-registrar` → Save → **Accounts** tab → **Add Accounts** → tick `worker-registrar` → Add.
5. Repeat for `worker-deregistrar`.

**Roles**

6. Global → **Roles** → **New**: name `worker-registrar` → Save.
7. **Principals** tab → **Add Principals** → tick user `worker-registrar`.
8. **Grants** tab → **New grant** → paste `type=worker;actions=create:controller-led` → Save.
9. **Scopes** tab: leave as `This` (global) only.
10. Repeat for `worker-deregistrar` with grant `ids=*;type=worker;actions=delete`.

**See it**: Global → **Roles** → `worker-registrar` → Grants shows exactly one
line. Log out, log in as `worker-registrar` (password auth): the left nav shows
Workers only; Targets/Sessions are empty. That is the least-privilege you will
draw.

> **Step 4 is the one that gets skipped, and a correct role hides it.** A role
> grants to a *user*, and a user is reached through the *account* that was used
> to log in. If the account exists on the right auth method but was never added
> to the user, login succeeds and every action is refused — registration dies at
> boot with `403 PermissionDenied` on `create on controller-led-type worker`
> while the role reads as perfectly configured. `403` not `401` is the tell:
> a valid token proves authentication, never authorization.
>
> Verify the whole chain, not just the role:
>
> ```bash
> boundary roles read -id <role-id>                    # note its principal user id
> boundary users read -id <user-id>                    # account_ids MUST be non-empty
> boundary accounts read -id <account-id>              # auth_method_id == the one in Vault KV
> ```
>
> The account's `auth_method_id` must equal the `auth_method_id` stored in the
> Vault KV secret the worker reads. Two accounts with the same login name on two
> different methods is exactly how this goes wrong. Hit on 2026-09-22 — see
> items 1 and 9 in [`notes/Issues.md`](../notes/Issues.md).

### A2. Vault CLI: AWS auth + two roles + two secrets

```bash
kubectl -n vault port-forward svc/vault 8200:8200 &
export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=<root/admin token>

# 1. the auth method EC2 will use (skip if `vault auth list` already shows aws/)
vault auth enable aws

# 2. what each role may read
vault policy write boundary-worker-registrar   - <<'EOF'
path "secret/data/boundary/registrar"   { capabilities = ["read"] }
EOF
vault policy write boundary-worker-deregistrar - <<'EOF'
path "secret/data/boundary/deregistrar" { capabilities = ["read"] }
EOF

# 3. two roles, both bound to ONE IAM role (created in B2) - the Vault role name
#    chosen by the script decides which policy, hence which secret, it gets
ROLE_ARN=arn:aws:iam::173310766280:role/boundary-asg-worker
vault write auth/aws/role/boundary-worker-register   auth_type=iam \
  bound_iam_principal_arn=$ROLE_ARN resolve_aws_unique_ids=false \
  token_policies=boundary-worker-registrar   token_ttl=5m token_max_ttl=5m
vault write auth/aws/role/boundary-worker-deregister auth_type=iam \
  bound_iam_principal_arn=$ROLE_ARN resolve_aws_unique_ids=false \
  token_policies=boundary-worker-deregistrar token_ttl=5m token_max_ttl=5m

# 4. the two Boundary logins from A1
vault kv put secret/boundary/registrar   boundary_addr=$BOUNDARY_ADDR \
  auth_method_id=ampw_WNbi76VghW login_name=worker-registrar   password='<pw1>'
vault kv put secret/boundary/deregistrar boundary_addr=$BOUNDARY_ADDR \
  auth_method_id=ampw_WNbi76VghW login_name=worker-deregistrar password='<pw2>'
```

`resolve_aws_unique_ids=false` matters: Vault matches the ARN as a string and
never calls IAM, so the in-cluster Vault needs no AWS credentials and the IAM
role may not exist yet.

**See it**: `vault read auth/aws/role/boundary-worker-register` shows the ARN
and the policy. `vault policy read boundary-worker-registrar` shows one path.

---

## B — AWS by hand (console)

### B1. Parameter Store

**Systems Manager → Parameter Store → Create parameter**

| Name | Type | Value |
|---|---|---|
| `/boundary-worker/datadog_api_key` | SecureString | your Datadog API key |
| `/boundary-worker/ami_id` | String | fill in after B5 |

### B2. IAM role the workers run as — the ARN Vault trusts

**IAM → Roles → Create role** → Trusted entity *AWS service* → *EC2* → Next.

Attach `AmazonSSMManagedInstanceCore`. Name **`boundary-asg-worker`** (must be
exactly the name in A2). Create.

Open the role → **Add permissions → Create inline policy** → JSON:

```json
{ "Version": "2012-10-17", "Statement": [
  { "Effect": "Allow",
    "Action": ["autoscaling:CompleteLifecycleAction","autoscaling:RecordLifecycleActionHeartbeat","autoscaling:SetInstanceProtection"],
    "Resource": "arn:aws:autoscaling:ap-southeast-1:173310766280:autoScalingGroup:*:autoScalingGroupName/boundary-workers" },
  { "Effect": "Allow", "Action": ["ssm:GetParameter"],
    "Resource": "arn:aws:ssm:ap-southeast-1:173310766280:parameter/boundary-worker/datadog_api_key" }
] }
```

Name it `boundary-worker-lifecycle`. Nothing for Vault here — `sts:GetCallerIdentity` needs no permission.

**See it**: role ARN `arn:aws:iam::173310766280:role/boundary-asg-worker` — the
same string as `ROLE_ARN` in A2. Draw that arrow.

**Check the managed policy actually attached** — on the 2026-09-22 build the
inline policy was created but `AmazonSSMManagedInstanceCore` was not, so the
workers never appeared in Session Manager and every later problem had to be
diagnosed from outside the box:

```bash
aws iam list-attached-role-policies --role-name boundary-asg-worker
# expect: AmazonSSMManagedInstanceCore
aws iam attach-role-policy --role-name boundary-asg-worker \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore   # if missing
```

`kms:Decrypt` is deliberately absent: `--with-decryption` on a SecureString
under the default `alias/aws/ssm` key is authorised by the *key* policy via
`kms:ViaService`, not by this role. Create the parameter in B1 with the default
key — pick a customer-managed key and you must add `kms:Decrypt` here.

### B3. Security group

**EC2 → Security Groups → Create**: name `boundary-workers-sg`, VPC = the EKS
VPC. Inbound: one rule, TCP 9202 from `10.0.0.0/16`. Outbound: all. No SSH.

### B4. The AMI (Packer, from your laptop)

Packer is the one thing not worth doing in a console. It launches a throwaway
instance, runs the Ansible role, snapshots it.

```bash
cd autoscaling/packer
packer init .
packer build -var vpc_id=<vpc-id> -var subnet_id=<a PUBLIC subnet id> .
jq -r '.builds[-1].artifact_id' manifest.json        # region:ami-xxxx
```

Put the `ami-…` into `/boundary-worker/ami_id` (B1).

**See it**: **EC2 → AMIs** → `boundary-worker-<timestamp>` → Available.

### B5. Launch template

**EC2 → Launch Templates → Create**: name `boundary-workers`.

| Field | Value |
|---|---|
| AMI | *My AMIs* → the one from B4 |
| Instance type | `t3.small` — **not** `t3.micro`, see below |
| Key pair | *Don't include* |
| Subnet | *Don't include in launch template* (the ASG decides) |
| Security group | `boundary-workers-sg` |
| Storage | 20 GiB gp3, encrypted |
| Advanced → IAM instance profile | `boundary-asg-worker` |
| Advanced → Metadata version | **V2 only (token required)**, hop limit 1, *Allow tags in metadata: Enable* |
| Advanced → User data | the **rendered** `user-data.sh.tpl` — see below. Never paste the file as-is. |

User-data does only three things: writes `/etc/boundary/env`, writes the Datadog
API key into `datadog.yaml`, starts the units. Read it once; it is 30 lines.

> **Workers go in a PUBLIC subnet with a public IP — this is load-bearing, not
> convenience.** A worker that only dials out is reached over the multi-hop
> reverse connection, and Boundary does not instrument that path: the session
> metric reads 0 forever no matter how much traffic flows, so nothing can ever
> scale. Four things have to line up, and missing any one silently returns you
> to a flat-zero metric:
>
> | | |
> |---|---|
> | Subnet | a **public** one, with `AssociatePublicIpAddress` forced in the launch template |
> | `public_addr` | resolved from IMDS at boot by `boundary-register.sh` — it changes per instance, so it can never be hardcoded |
> | Security group | 9202 open to the **client's** IP, not just the VPC |
> | Target | an `ingress_worker_filter`, not only an egress one |
>
> The trade is real: the workers become internet-reachable on 9202 and the SG is
> the only thing in front of that port. See items 14-15 in [`notes/Issues.md`](../notes/Issues.md).
>
> ```bash
> boundary targets update tcp -id <target-id> \
>   -ingress-worker-filter '"eks" in "/tags/type"'
> ```

> **Size it `t3.small`, and set CPU credits to *unlimited*.** The Boundary
> worker is a light TCP proxy, but it is not alone on the box: it holds ~470 MiB
> RSS plus two `boundary-plugin` children, and the Datadog agent adds `agent`,
> `trace-loader`, `agent-data-plane` and `system-probe` on top. On a `t3.micro`
> (1 GiB) the kernel OOM-kills `boundary`, systemd restarts it every 5 s, that
> loop holds ~52% CPU against a 10% baseline, the burst credits reach zero, and
> the **SSM agent is starved** — so the instance also stops answering Session
> Manager and Run Command, exactly when you need it. Measured 2026-09-23; see
> items 10-11 in [`notes/Issues.md`](../notes/Issues.md).
>
> When an instance stops answering SSM, do not keep sending it commands:
>
> ```bash
> aws ec2 get-console-output --instance-id <id> --latest   # needs no agent
> ```

> **Render it first — this is the single easiest step to get wrong.**
> `user-data.sh.tpl` is a Terraform `templatefile()` template. Pasting it
> unrendered leaves literal `${boundary_addr}` in the file, and because the
> script runs under `set -euo pipefail` with an **unquoted** heredoc, bash
> expands `${boundary_addr}` as a *shell* variable, finds it unset, and kills
> user-data **on line 10** — before the SSM read, before `datadog.yaml`, before
> any `systemctl start`. Nothing reports the failure: the ASG calls the instance
> healthy, the Datadog agent runs (it is baked into the AMI), and the only
> symptom is `connection refused` on `:9203` several layers away. See the
> 2026-09-22 entry in [`notes/Issues.md`](../notes/Issues.md).

Render with the eight real values, then verify nothing is left:

```bash
cd autoscaling/asg
sed -e "s|\${boundary_addr}|https://<cluster-id>.boundary.hashicorp.cloud|g" \
    -e "s|\${hcp_boundary_cluster_id}|<cluster-id>|g" \
    -e "s|\${vault_addr}|http://<vault-nlb-hostname>:8200|g" \
    -e "s|\${aws_region}|ap-southeast-1|g" \
    -e "s|\${asg_name}|boundary-workers|g" \
    -e "s|\${lifecycle_hook_name}|boundary-worker-deregister|g" \
    -e "s|\${datadog_api_key_ssm_param}|/boundary-worker/datadog_api_key|g" \
    -e "s|\${datadog_site}|datadoghq.com|g" \
    user-data.sh.tpl > /tmp/user-data.rendered.sh

# MUST print nothing. Any output here means the instance will fail to boot.
grep -o '\${[a-z_]*}' /tmp/user-data.rendered.sh
```

Paste `/tmp/user-data.rendered.sh`. The Vault NLB hostname comes from
`kubectl get svc -n vault` (see the note in B6 — it changes every time the
Service is recreated).

**Verify on the first instance, before moving on** — two commands that would
have caught this immediately:

```bash
aws ssm start-session --target <instance-id>
cat /etc/boundary/env            # every line must have a real value, not ${…}
sudo tail -20 /var/log/cloud-init-output.log   # must not end in "unbound variable"
```

### B6. Auto Scaling group + lifecycle hook

**EC2 → Auto Scaling Groups → Create**

| Step | Value |
|---|---|
| Name / template | `boundary-workers`, launch template `boundary-workers`, *Latest* |
| Network | the EKS VPC, the **three private subnets** |
| Health checks | EC2, grace 180 s |
| Group size | desired 1, min 1, max 6 |
| Scaling policies | **None** — Datadog + GitHub decide, not CloudWatch |
| Tags | `asg = boundary-workers`, *Tag new instances* ticked |

Create. Then open the group → **Instance management → Lifecycle hooks → Create**:

| | |
|---|---|
| Name | `boundary-worker-deregister` |
| Transition | Instance terminate |
| Heartbeat timeout | 300 |
| Default result | CONTINUE |

**Confirm both of these — the console does not always keep what you picked:**

```bash
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names boundary-workers \
  --query 'AutoScalingGroups[0].{min:MinSize,max:MaxSize,desired:DesiredCapacity,lt:LaunchTemplate.Version}'
```

Expect `max: 6` and `lt: "$Latest"`. On the 2026-09-22 build this came back
`max: 1` and `lt: "2"` — a pinned version means every later launch-template
version is ignored, and `max: 1` makes scale-out a silent no-op (`scale.yml`
clamps to the bound and exits green). Fix either with:

```bash
aws autoscaling update-auto-scaling-group --auto-scaling-group-name boundary-workers \
  --max-size 6 --launch-template LaunchTemplateId=<lt-id>,Version='$Latest'
```

> **Vault's address is not stable.** `vault_addr` points at an internal NLB
> created by a `type: LoadBalancer` Service. Delete and recreate that Service
> and the hostname changes, which breaks every worker at registration — the
> worker never starts, so the visible symptom is `:9203 connection refused`.
> If the `vault` Service is `ClusterIP`, there is no address at all; expose it
> first (`vault/MANUAL-SETUP.md`). Re-render user-data on any change.

**See it**: **Activity** tab shows *Launching a new EC2 instance*. Under
**Instance management**, one instance, lifecycle *InService*. In ~2 minutes,
Boundary UI → **Workers** shows `worker-i-0…` — registration ran by itself
from user-data. That is the automated path; part C does it by hand so you see
each call.

If **Workers** stays empty, do not debug Datadog — debug the boot. In order:
`cat /etc/boundary/env` (placeholders?), `journalctl -u boundary-register`
(Vault reachable?), `systemctl status boundary-worker` (is there a
`worker.hcl`?). Datadog is the last link in that chain, not the first.

---

## C — Register a worker by hand, line by line

Launch a second instance so you can do the registration yourself: ASG →
**Edit** → desired **2** → Update. When it shows *InService*, connect:

```bash
aws ssm start-session --target <the new i-…> --profile hc-lab
sudo -i
systemctl stop boundary-register boundary-worker     # undo what user-data did
rm -f /etc/boundary/worker_id /etc/boundary/worker.hcl
source /etc/boundary/env
```

Also delete that worker in the Boundary UI (**Workers** → the newer
`worker-i-…` → Delete) so you can create it again yourself.

Now the exact sequence the script runs:

```bash
# 1. Who am I, to AWS?  (this is what Vault will check)
aws sts get-caller-identity
#   "Arn": "arn:aws:sts::173310766280:assumed-role/boundary-asg-worker/i-0…"

# 2. Log in to Vault with that identity. No password, no token on disk.
export VAULT_ADDR
vault login -method=aws role=boundary-worker-register
#   token, policies: ["boundary-worker-registrar"], ttl 5m

# 3. Read the one secret this role may read (try the other path - it is denied)
vault kv get secret/boundary/registrar
vault kv get secret/boundary/deregistrar          # permission denied  <- draw this

# 4. Log in to Boundary as the registrar
export BROKER_PASS=$(vault kv get -field=password secret/boundary/registrar)
export BOUNDARY_TOKEN=$(boundary authenticate password -auth-method-id ampw_WNbi76VghW \
  -login-name worker-registrar -password env://BROKER_PASS -keyring-type none -format json \
  | jq -r .item.attributes.token)

# 5. Create the worker record. Boundary answers with a ONE-TIME activation token.
boundary workers create controller-led -name worker-$(curl -s -H "X-aws-ec2-metadata-token: $(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" http://169.254.169.254/latest/meta-data/instance-id) -format json | tee /tmp/w.json
WID=$(jq -r .item.id /tmp/w.json); ACT=$(jq -r .item.controller_generated_activation_token /tmp/w.json)

# 6. Write the worker config with that token (identical to what boundary-register.sh writes)
cat > /etc/boundary/worker.hcl <<EOF
disable_mlock = true
hcp_boundary_cluster_id = "${HCP_BOUNDARY_CLUSTER_ID}"

listener "tcp" {
  address = "0.0.0.0:9202"
  purpose = "proxy"
}
listener "tcp" {                     # /health for Datadog + the lifecycle script
  address     = "127.0.0.1:9203"
  purpose     = "ops"
  tls_disable = true                 # REQUIRED - without it Boundary exits 3:
}                                    # "tls not disabled ... no certificate file supplied"

worker {
  controller_generated_activation_token = "${ACT}"
  auth_storage_path = "/opt/boundary/worker"
  tags {
    type = ["eks", "vpc", "private", "asg"]    # what the targets + cred store filter on
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
chown boundary:boundary /etc/boundary/worker.hcl; chmod 0640 /etc/boundary/worker.hcl
echo $WID > /etc/boundary/worker_id
unset BOUNDARY_TOKEN BROKER_PASS; rm /tmp/w.json

# 7. Start the worker. It dials OUT to HCP with the activation token, once.
systemctl start boundary-worker
journalctl -u boundary-worker -n 20 --no-pager      # "worker has successfully authenticated"
curl -s 'http://127.0.0.1:9203/health?worker_info=1'  # state: active, upstream: READY
# The session count comes from /metrics, not /health - active_session_count is
# always 0 on this build. This is the number every monitor reads:
curl -s http://127.0.0.1:9203/metrics | grep proxy_websocket_active_connections
```

**See it**: Boundary UI → **Workers** → your `worker-i-…` is *Active*, tags
`type: eks, vpc, private, asg`. Vault UI/CLI → `vault list auth/aws/roles`.
The arrows you just walked: EC2 → STS (identity) → Vault (login, read) →
Boundary (create) → HCP (worker dials out).

Put the ASG back to desired **1** when done. Watch what happens to the extra
instance — that is part G, so read G first if you want to follow it live.

---

## D — Datadog by hand

### D1. Confirm the metric arrives

**Metrics → Explorer** → metric `boundary.worker.active_sessions` → *from*
`asg:boundary-workers` → *avg by* `worker_name`. One flat line at 0 per worker.
Open one Boundary session from your laptop (`boundary connect …`) and watch
that worker's line go to 1. Close it — back to 0. This is the signal.

Also **Logs → Explorer** → `source:boundary` — the cloudevents from each
worker, one line per event. This is the audit trail, not the signal.

**If nothing ever appears**, check in this order — a healthy-looking agent
proves very little, because the agent, `conf.d` and `checks.d` all come from
the AMI and run fine with no valid key:

```bash
aws ssm start-session --target <instance-id>
sudo datadog-agent check boundary_worker      # does the check emit a metric at all?
sudo datadog-agent status | grep -A3 'API Keys status'
sudo grep -c '^api_key: 0123456789abcdef' /etc/datadog-agent/datadog.yaml
```

| Symptom | Cause |
|---|---|
| last line prints `1` | user-data never overwrote `datadog.yaml`, so the agent is running on the **dummy key baked by Ansible** and every submission is rejected. Check `/var/log/cloud-init-output.log`. |
| `API Keys status` says invalid | wrong key, or wrong `site` — an agent on `datadoghq.com` submitting to an `ap1` org reports healthy and arrives nowhere |
| check runs but `Metric Samples: 0` | the worker's ops listener is down; the check returns after a CRITICAL service check **without** emitting the gauge, so you get *no data* rather than a zero. Fix the worker, not Datadog. |

That last row matters for the monitors: `avg(last_15m) … < 3` with
`notify_no_data = false` stays silent on a dead worker rather than firing. The
`worker_stale` service check is what covers it. See items 3-4 in
[`notes/Issues.md`](../notes/Issues.md).

### D2. Webhooks — the actuator

Create the GitHub token first: **GitHub → Settings → Developer settings →
Personal access tokens → Fine-grained → Generate**: repository access = this
repo only; permissions = *Contents: Read and write*. Copy it.

**Datadog → Integrations → Webhooks → Configure → New**:

| Field | `gha-scale-out` | `gha-scale-in` |
|---|---|---|
| URL | `https://api.github.com/repos/<owner>/<repo>/dispatches` | same |
| Payload | `{"event_type":"scale","client_payload":{"direction":"out","monitor":"$ALERT_TITLE","asg":"boundary-workers"}}` | same with `"in"` |
| Custom headers | `{"Accept":"application/vnd.github+json","Authorization":"Bearer <token>","X-GitHub-Api-Version":"2022-11-28"}` | same |

Save both.

### D3. Two monitors

**Monitors → New Monitor → Metric**

*Scale OUT*

| | |
|---|---|
| Define the metric | `boundary.worker.active_sessions`, *from* `asg:boundary-workers`, **avg by** (everything) — i.e. the average over all workers |
| Set alert conditions | *above* threshold, *on average*, *during the last* **5 minutes**; Alert threshold **10** |
| Notify | title `[boundary] scale OUT - boundary-workers`; message `Adding one worker. @webhook-gha-scale-out`; **Renotify** every **10 minutes** *if the monitor has not been resolved* |
| Tags | `service:boundary-worker`, `asg:boundary-workers` |

*Scale IN*

Same metric; *below* **3**, *during the last* **15 minutes** (this is the
stabilization window); message `Removing one worker. @webhook-gha-scale-in`;
renotify every **20 minutes**.

Why the gap between 10 and 3: after a scale-out the average drops (same
sessions, more workers). A scale-in threshold close to 10 would fire straight
away and the pool would flap. Draw the two lines on the graph.

**See it**: **Monitors → Manage** → both *OK*. Open *Scale OUT* → **Test
Notifications** → state *Alert* → Run test. GitHub → **Actions** → a
`scale-workers` run appears within seconds. That is the Datadog → GitHub arrow.
(The run will move desired 1 → 2; put it back with `direction: in` in E.)

### D4. Dashboard

**Dashboards → New Dashboard → New Timeboard** and add, in this order:

1. Query Value — `sum:boundary.worker.active_sessions{asg:boundary-workers}` — *Active sessions*
2. Query Value — `avg:boundary.worker.active_sessions{asg:boundary-workers}` — *Avg per worker*; conditional format red > 10, yellow < 3
3. Query Value — `avg:aws.autoscaling.group_in_service_instances{autoscalinggroupname:boundary-workers}` — *Workers*
4. Monitor Summary — query `tag:(service:boundary-worker)`
5. Timeseries — sessions by `worker_name`; add **Markers** `y = 10` (error) and `y = 3` (warning)
6. Timeseries — `aws.autoscaling.group_desired_capacity` and `…group_in_service_instances`
7. Check Status — check `boundary.worker.health`, group by host
8. Timeseries (Logs) — `source:boundary @data.event_type:session*`, count, bars
9. Log Stream — `source:boundary`

That is the whole board. Add Vault/GitHub widgets later if you want them.

---

## E — GitHub by hand

**Settings → Secrets and variables → Actions → New repository secret**:
`AWS_GHA_ROLE_ARN` = the ARN of an IAM role GitHub can assume via OIDC.
Create that role once: **IAM → Identity providers → Add → OpenID Connect**,
provider `https://token.actions.githubusercontent.com`, audience
`sts.amazonaws.com`; then **IAM → Roles → Create → Web identity**, pick that
provider, condition `sub` = `repo:<owner>/<repo>:*`; inline policy allowing
`autoscaling:DescribeAutoScalingGroups` and `autoscaling:SetDesiredCapacity`.

Run the workflow by hand: **Actions → scale-workers → Run workflow →
direction `in`** (to undo the D3 test). Open the run → the step prints
`desired: 2 -> 1`.

**See it**: EC2 → Auto Scaling → `boundary-workers` → **Activity**:
*Terminating EC2 instance … waiting for lifecycle hook*. That's the GitHub →
AWS arrow, and the start of part G.

---

## F — SCALE OUT, end to end

Open four windows: Datadog dashboard, Boundary UI **Workers**, AWS ASG
**Activity**, GitHub **Actions**. Then from your laptop:

```bash
boundary authenticate oidc -auth-method-id amoidc_eY8ldrT0GG
cd autoscaling/scripts && ./scale-to-workers.sh 2 ttcp_d9cw5TgQOO 25
```

Watch, in order (times are typical):

| t | Where | What you see | Arrow to draw |
|---|---|---|---|
| 0:00 | laptop | 25 `boundary connect` processes | laptop → HCP → worker |
| 0:15 | Boundary UI → Workers | the one worker: *Active connections 25* | |
| 0:30 | Datadog dashboard | *Avg per worker* = 25, red; per-worker line above the 10 marker | worker → Datadog |
| 5:00 | Datadog → Monitors | *Scale OUT* → **Alert** | |
| 5:05 | GitHub → Actions | `scale-workers` run: `desired: 1 -> 2` | Datadog → GitHub → ASG |
| 5:10 | ASG → Activity | *Launching a new EC2 instance* | |
| 6:30 | new instance journal (`journalctl -u boundary-register`) | Vault login → registered `worker-i-…` | EC2 → Vault → Boundary |
| 6:40 | Boundary UI → Workers | **two** workers, both Active | |
| 7:00 | Datadog dashboard | *Workers* = 2; *Avg per worker* falls to ~12 | |
| 15:00 | Datadog → Monitors | still > 10 → renotify → `desired: 2 -> 3` | (repeats until avg < 10 or max 6) |

Stop the load test (Ctrl-C) whenever you have seen enough.

---

## G — SCALE IN, end to end

Continue from F with the load stopped. Watch:

| t | Where | What you see | Arrow to draw |
|---|---|---|---|
| 0:00 | Datadog dashboard | sessions 0 on every worker | |
| 0:00 | each instance, `journalctl -u boundary-protect` | *scale-in protection off (0 sessions)* | worker → ASG (protection) |
| 15:00 | Datadog → Monitors | *Scale IN* → **Alert** (15-minute window elapsed) | |
| 15:05 | GitHub → Actions | `scale-workers`: `desired: 2 -> 1` | Datadog → GitHub → ASG |
| 15:10 | ASG → Activity | *Terminating EC2 instance i-… — waiting for lifecycle hook* — lifecycle column shows **Terminating:Wait** | ASG hook holds the instance |
| 15:12 | that instance, `journalctl -u boundary-lifecycle -f` | `removal signalled` → `drained` → `deregistered w_…` → `lifecycle action completed` | EC2 → Vault → Boundary (delete) → ASG (continue) |
| 15:13 | Boundary UI → Workers | back to **one** worker — the record is gone *before* the instance is | |
| 15:14 | ASG → Activity | *Successful* — instance terminated | |
| 15:15 | Datadog dashboard | *Workers* = 1; no stale host under *Worker health* | |

Two experiments worth doing while you are here:

- **Protection**: open one session to the newest worker (`boundary connect`,
  check which worker took it in the Workers list), then trigger a scale-in
  (`Run workflow → in`). The ASG picks the *other* instance — the one with
  sessions is protected. `journalctl -u boundary-protect` on it shows
  *protection on (1 sessions)*.
- **Drain**: keep a session open on the instance being removed (force it with
  `aws autoscaling terminate-instance-in-auto-scaling-group --instance-id … --no-should-decrement-desired-capacity`).
  The lifecycle journal shows *draining: 1 active session(s), 5s elapsed …*
  until you close the session (or 240 s pass), and the ASG Activity stays in
  *Terminating:Wait* the whole time.

---

## What you have touched, and what the drawing needs

| Box | You made it in |
|---|---|
| Boundary: broker accounts `worker-registrar`, `worker-deregistrar` on `ampw_WNbi76VghW`, 1 grant each | A1 |
| Vault: `auth/aws`, roles `boundary-worker-register/deregister`, 2 policies, 2 KV secrets | A2 |
| IAM role `boundary-asg-worker` — the string both Vault and EC2 agree on | B2 ↔ A2 |
| Launch template (AMI + user-data) → ASG `boundary-workers` + hook `boundary-worker-deregister` | B5, B6 |
| On every instance: `register` (boot) · `lifecycle` (terminate) · `protect` (every minute) | C |
| Datadog: metric `boundary.worker.active_sessions` · webhooks · monitors OUT/IN · dashboard | D |
| GitHub: `scale-workers` workflow, OIDC role | E |

| Arrow | Label |
|---|---|
| worker → Datadog | `active_sessions` gauge every 15 s; cloudevents log |
| Datadog → GitHub | webhook `repository_dispatch {direction}` |
| GitHub → ASG | `set-desired-capacity ±1` |
| ASG → EC2 | launch from template / terminate via hook (`Terminating:Wait`, 300 s) |
| EC2 → STS → Vault | `vault login -method=aws role=…` (identity = IAM role ARN) |
| Vault → EC2 | one KV secret: the broker's Boundary login |
| EC2 → Boundary | `workers create controller-led` (boot) / `workers delete` (terminate) |
| worker → HCP | dials out with the activation token; then the session tunnel |
| worker → ASG | `set-instance-protection` on/off |
