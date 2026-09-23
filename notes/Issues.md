# Issues log — everything that broke while building this, and why

The drawing version, with causes and fixes on one board:
**[Issues — what broke and why](https://app.excalidraw.com/s/9hD7S5FgGWN/9x6Q0ZNzt0P)**
(scene 5 of the [five scenes](../README.md#start-here--the-five-scenes)).

Below is the full written record, moved out of the README so the README stays
a design document. Nothing here is hypothetical — every item was hit on a live
build, measured, and fixed.

---

## Index — by component

Findings are written up in the order they were hit (the story matters), but this
is how to reach them when something is broken **now**.

| Component | Go to |
|---|---|
| **AWS / EKS** | [AWS / EKS](#aws--eks) · [11. t3.micro is too small](#11-t3micro-is-too-small-and-the-way-it-fails-hides-itself) · [7. ASG pinned to an old launch template](#7-the-asg-was-pinned-to-launch-template-version-2-and-max-was-1) |
| **Vault** | [Vault](#vault) · [5. Vault was never exposed](#5-vault-was-never-exposed) · [8. source never exported anything](#8-source-etcboundaryenv-never-exported-anything) |
| **Boundary — control plane** | [Boundary authorization](#boundary-authorization) · [1. Two auth methods where two accounts were needed](#1-two-auth-methods-created-where-two-accounts-were-needed) · [9. Registrar authenticates but cannot create](#9-the-registrar-broker-authenticates-but-cannot-create) |
| **Boundary — the worker** | [Boundary worker](#boundary-worker) · [10. Ops listener had no tls_disable](#10-the-ops-listener-had-no-tls_disable-so-the-worker-never-started) · [18. Bootstrap worker cannot coexist with the pool](#18-the-bootstrap-worker-cannot-coexist-with-the-pool-once-ingress-filtering-exists) |
| **Worker filters / targets** | [2. Worker-tag vocabulary drift](#2-worker-tag-vocabulary-drift) · [17. targets update clears filters you do not restate](#17-boundary-targets-update-clears-filters-you-do-not-restate) |
| **The autoscaling metric** | [14. The metric does not exist on this path](#14-the-metric-the-whole-design-scales-on-does-not-exist-on-this-path) · [4. The check reports no-data, not zero](#4-the-custom-check-reports-no-data-not-zero-when-the-worker-is-down) |
| **Datadog** | [3. The AMI's dummy key makes a dead agent look alive](#3-the-amis-dummy-datadog-key-makes-a-dead-agent-look-alive) · [12. enable --now is a no-op](#12-systemctl-enable---now-is-a-no-op-on-an-already-running-unit) · [13. events.log is mode 0600](#13-boundary-writes-eventslog-mode-0600-so-dd-agent-cannot-tail-it) · [16. UMask cannot widen an explicit mode](#16-umask-cannot-fix-a-file-created-with-an-explicit-mode) |
| **GitHub Actions / CI** | [15. Could not assume the AWS role](#15-github-actions-could-not-assume-its-aws-role--the-role-never-existed) |
| **Boot / user-data** | [1. Launch template held the raw template](#1-the-launch-template-held-the-raw-template-not-a-rendered-one) · [2. /etc/boundary/env exists but is empty](#2-etcboundaryenv-exists-but-is-empty--which-defeats-the-guard) · [6. Two walkthrough steps skipped](#6-two-walkthrough-steps-were-skipped-and-neither-fails-loudly) |
| **Okta** | [Okta — six failed attempts at one claim](#okta--six-failed-attempts-at-one-claim) |
| **Symptom → cause** | [Troubleshooting](#troubleshooting) |

### The three shapes these keep taking

| Shape | Why it costs hours |
|---|---|
| An address set but not **exported** | the CLI falls back to its own localhost default and reports `connection refused` against a port nothing is listening on |
| A valid credential with **no authority** | `403`, never `401` — login succeeds, every action is refused, and the role reads as perfectly configured |
| A component reporting **healthy while delivering nothing** | agent status green on a dummy key; a red monitor with an empty Actions tab; a counter that never moves |

A successful authentication proves identity, never permission. A component
saying "OK" means it did its own job, not that the next one received anything.

---

## Problems found on the 2026-09-10/12 rebuild

Everything in this section was hit, measured and fixed on a live rebuild.

**Vault's own credential expires after ~24 hours, and the error blames the wrong
ServiceAccount.** Step 3d originally ran
`kubectl create token vault-auth --duration=8760h`. The API server silently caps
that — **measured on EKS: requested 8760h, granted exactly 24.0h**. A day later
every credential request fails with
`failed to create a service account token for demo-app/vault-viewer: Unauthorized`,
which points at `demo-app/vault-viewer` while the dead credential is
`kube-system/vault-auth`. You cannot raise the cap: it comes from the API
server's `--service-account-max-token-expiration`, and on EKS the control plane
is managed. There is a standing request for it in
[aws/containers-roadmap#1836](https://github.com/aws/containers-roadmap/issues/1836).
Fixed by using a `kubernetes.io/service-account-token` Secret, whose token has
no `exp` claim at all — see step 3b.

**The unscoped token-creator grant was a privilege-escalation path.** `create` on
`serviceaccounts/token` with no `resourceNames` lets Vault mint a token for any
ServiceAccount in the cluster, including any bound to `cluster-admin`. The 24h
expiry was masking it; attaching a non-expiring token would have made it
permanent. Verified after scoping: minting `vault-viewer` succeeds, minting
`default` returns `serviceaccounts "default" is forbidden`.

**Vault ignores its own auto-rotating credential.** `disable_local_ca_jwt=true`
means "do not read the pod's mounted token". Vault runs *in* this cluster, so it
already has a projected token the kubelet rotates forever — and the external
recipe tells it to ignore that and use a pasted one instead. If Vault is
in-cluster, bind the Role to the Vault pod's ServiceAccount and run
`vault write -f kubernetes/config` with no arguments.

**`service_account_jwt` does not have to be a ServiceAccount JWT.** Tested: an
IAM token from `aws eks get-token` — a presigned STS URL, not a JWT — works
fine. Vault sends whatever string it holds as a bearer token and lets the API
server decide. The field name is misleading.

**`kubectl -n vault rollout status statefulset/vault` fails.** The Vault chart's
StatefulSet uses `OnDelete`, so the command errors with
`rollout status is only available for RollingUpdate strategy type`. Use
`kubectl -n vault wait --for=condition=Ready pod/vault-0 --timeout=180s`.

**The Boundary worker never installed — two stacked causes.** First,
`Error: GPG check FAILED`: the HashiCorp repo's `gpgkey` endpoint serves
`CA026560` while the `boundary-enterprise` RPM is signed with the retired
`a621e701`. Under `set -euxo pipefail` that aborts the whole cloud-init, leaving
no binary, no `worker.hcl`, no unit file. Replaced with a pinned release archive
verified by SHA256. Second, a worker newer than its controller cannot enrol —
`1.0.2+ent` against a `1.0.1` controller fails with
`(nodeenrollment.registration.validateFetchRequest) empty nonce` and
`remote error: tls: internal error`. Both are now variables
(`boundary_version`, `boundary_sha256`) in `aws/variables.tf`.

**An egress worker filter alone is not enough — multi-hop is required.** The
client must reach *some* worker, and a self-managed worker in a private subnet
advertises `0.0.0.0:9202` with no public IP. Sessions sit in `pending` and
kubectl dies with `net/http: TLS handshake timeout`. Adding an ingress filter
selecting the HCP-managed workers fixed it immediately:

```
egress_worker_filter  = "/name" == "kst-eks-ap-southeast-1-worker-01"
ingress_worker_filter = "/name" matches "hcp-managed-worker.*"
```

**Worker filters are top-level target fields, not under `.attributes`.** Reading
`.item.attributes.egress_worker_filter` returns nothing and makes a correctly
configured target look unconfigured. They live at `.item.egress_worker_filter`.
`worker_info` in an `authorize-session` response is likewise not populated by
this version — do not diagnose from its emptiness.

**`-vault-token env://VAR` is not resolved by the Boundary CLI.** Creating a
Vault credential store with it sends the literal string `env://VAR`, and Vault
answers `403 permission denied / invalid token`. Only `-token` supports that
indirection. Pass the value.

**Okta trial orgs cannot issue machine-to-machine tokens.** The
`client_credentials` grant is gated behind Okta's **NHI Authentication Tokens**
SKU. The grant simply never appears in the access-policy rule UI, which looks
like a configuration mistake and is not. One request settles it before you build
anything around it:

```bash
curl -s https://<org>.okta.com/oauth2/<authServerId>/.well-known/openid-configuration \
  | jq -r '.grant_types_supported'
# no "client_credentials" -> the SKU is not enabled; the path is closed
```

**The admin `/32` breaks whenever your ISP rotates you.** `admin_public_cidrs`
pinned to an old address locks `kubectl` out entirely, and every symptom looks
like a cluster fault. Check `curl https://checkip.amazonaws.com` against
`aws eks describe-cluster --query 'cluster.resourcesVpcConfig.publicAccessCidrs'`
before debugging anything else.

## Problems along the way

Every one of these was hit while building this. They are recorded because none
of them announced itself clearly, and several cost hours.

### AWS / EKS

**`unsupported Kubernetes version 1.29`**
AWS refuses to *create* a cluster on a version past end-of-life. 1.29 and 1.30
are already rejected. `aws eks describe-cluster-versions` lists what is
creatable; anything in EXTENDED_SUPPORT also bills at a premium.

**`expected length of name_prefix to be in the range (1 - 38)`**
The EKS module derives the node IAM role from `"<node group name>-eks-node-group-"`,
which overran AWS's 38-char cap. Fixed with an explicit `iam_role_name` and
`iam_role_use_name_prefix = false`.

**AL2 AMIs do not exist for EKS 1.33+.** The module leaves `ami_type` unset and
AWS's default would have failed. Pinned to `AL2023_x86_64_STANDARD`.

### Boundary worker

**Worker crash-looped:** `Worker config cannot contain name or description when
using activation-token-based worker authentication`. With `hcp_boundary_cluster_id`,
the name must come from the API at registration (`-name=`), not from `worker.hcl`.

**`No egress workers can handle this session, as they have all been filtered out`**
The target's `egress_worker_filter` said `eks-vpc-worker`; the worker had
actually registered as `kst-eks-ap-southeast-1-worker-01`. The filter must match
the **registered** name exactly. This blocks every session while looking like a
network problem.

### Vault

**Credentials 403 with `cannot create resource "serviceaccounts/token"`.**
The Helm chart binds Vault to `system:auth-delegator`, which grants
`tokenreviews` and `subjectaccessreviews` — the ability to *validate* tokens.
The Kubernetes secrets engine *mints* them via the TokenRequest API and needs
`create` on `serviceaccounts/token`. Configuration succeeds either way; only
credential issuance fails. See step 3b.

**`kubectl auth can-i create serviceaccounts/token --as=...` reports `no` even
when the permission is granted.** It mis-evaluates subresources under
impersonation. Test the real operation instead.

**Revoking a Vault lease does not invalidate the token.** Verified: revoke the
lease, the token still works until its `exp`. Because EKS signs the token and it
is bound to no object, nothing can call it back. Vault's lease is bookkeeping.
`kubernetes_role_name` / `generated_role_rules` mode makes revocation real, at
the cost of Vault needing create/delete on ServiceAccounts and RoleBindings.

**`helm upgrade` failed with `cannot unmarshal bool into ... annotations of type
string`.** Kubernetes annotations must be strings; `--set` parsed `true` as a
boolean. Use `--set-string`. The upgrade silently never happened — `helm history`
showed only revision 1 while the Service stayed ClusterIP.

### Okta — six failed attempts at one claim

This consumed more time than everything else combined. In order:

1. **Groups claim missing entirely.** `claims_scopes` did not request `groups`,
   so no claim arrived and every managed group matched nobody.
2. **`invalid_scope`.** After switching to the custom authorization server,
   requesting `groups` failed — custom servers have no built-in `groups` scope.
3. **`Policy evaluation failed`.** Custom authorization servers deny by default;
   they need an Access Policy permitting the client. The org server does not.
4. **`'groups' is reserved and cannot be used.`** On the org server `groups` is a
   reserved scope, so a *custom* claim cannot be named `groups` — the reason the
   two server types need opposite configurations.
5. **Thin ID tokens.** Okta's docs note the authorization-code flow may return
   groups only via `/userinfo`. Filters were widened to accept either
   (`"x" in "/token/groups" or "x" in "/userinfo/groups"`).
6. **The actual bug:** the app's Group claim filter was `Starts with` with value
   `eks-.*`. "Starts with" is a *literal* prefix match, so it looked for groups
   whose names begin with the characters `eks-.*`. Nothing matched, and **Okta
   omits the claim entirely rather than sending an empty array** — so every
   probe came back identical to "not configured at all". Changing the operator to
   `Matches regex`, or the value to `eks-`, fixed it immediately.

**Debugging technique that finally worked:** create throwaway managed groups with
filters that *must* match — `"/token/email" == "you@example.com"`, then
`"/token/groups" is not empty` and the same for `/userinfo`. One login then
distinguishes "claims are not arriving" from "claims arrive but values differ".
Without this, every failure looks the same.

### Boundary authorization

**Targets visible to everyone.** Two roles grant `type=target;actions=list` to
`u_auth` (every authenticated user): the project's auto-created `Default Grants`,
and a global `Authenticated User Grants`. Users saw all targets regardless of
role and only failed at connect. Listing and `authorize-session` are separate
grants — the second is the real control.

**Privilege escalation via `ids=*`.** The tier roles granted
`ids=*;type=target;actions=authorize-session`, so a viewer could authorize
`eks-api-admin` and receive an admin credential. Grants must name the specific
target ID.

**Managed group membership is evaluated at login, never synced.** Every Okta
change needs a full logout — a cached Okta session reissues the old claims and
nothing appears to change.

### Operational

**Terraform state holds live secrets.** `boundary/terraform.tfstate` contains the
Vault broker token in cleartext. State is gitignored; treat it as a credential.

**A shared Boundary cluster is not isolated by default.** This org sits alongside
34 others, and global-scope roles from other people's setups can carry
`ids=*;type=target` grants. Project isolation depends on roles outside the project.

---

## State before autoscaling (2026-09-15)

What was found and fixed live, one session before the autoscaling work.
Drawn as scene 5, linked at the top of this page.

**Fixed live in Boundary (not yet reflected in `boundary/*.tf`):**

- The single target `eks-api` carried **all three** credential libraries, so
  every authorized session returned viewer + operator + admin tokens. Split
  into `eks-api-viewer` / `-operator` / `-admin` (ids in the reference block),
  one library each. The viewer target kept the original id.
- `viewers` and `operator` roles granted `ids=*;type=target;actions=authorize-session`.
  Pinned to their own target id.
- Credential store creation from the UI failed until a **worker filter** was
  set — the HCP controller cannot reach the internal NLB; only the in-VPC
  worker can.
- "Cannot add brokered credential sources" was simply: no credential
  **libraries** existed yet. Libraries need `POST` and
  `{"kubernetes_namespace":"demo-app"}`; a GET returns 404/405.
- Editing an org role's scopes threw `iam_role_org_grant_scope_fkey`: an org
  role cannot have `children` **and** an individual project. Pick one.

**Still open:**

- Roles `target-read-only` (`r_hKbTJaPsnM`) and `Login and Default Grants`
  (`r_mAiKdBC8gx`) still grant `authorize-session` on **every** target to
  Google-auth users — including your own Google login. Strip the
  `type=target` line or delete them.
- `boundary/` Terraform expects project `eks-access` and project-scoped roles.
  Live is project `linux` with org-scoped role grants. The worker filter is no
  longer part of the drift — `boundary/variables.tf` now defaults to the same
  tag filter the live targets use. Either `terraform import` the rest or accept
  the drift.
- Node security-group rules for the Vault NLB NodePorts (30773, 32531 from
  0.0.0.0/0) are added by the in-tree cloud controller and are not in
  Terraform. Narrow with `spec.loadBalancerSourceRanges` if wanted.

**Before any further Boundary / Vault change, check:** current Vault NLB
hostname · every filter is a tag filter · each target has exactly one library ·
every `authorize-session` grant is pinned to a target id · worker version ≤ HCP
controller · `--profile hc-lab`.

---

## Found during the autoscaling walkthrough (2026-09-17)

Two misalignments surfaced while walking [`../autoscaling/01-Build-By-Hand.md`](../autoscaling/01-Build-By-Hand.md)
A–C by hand.

### 1. Two auth methods created where two accounts were needed

In step A1 the
brokers were made as *auth methods* instead of *accounts on the existing
method*. Live global scope ended up with three password methods:

| id | name | what it actually is |
|---|---|---|
| `ampw_WNbi76VghW` | Generated global scope initial password auth method | the real one — `admin` lives here, and this is what the Terraform provider, `brokers/` and `rotate-broker-creds.yml` authenticate against |
| `ampw_ARewCYhH63` | worker-registrar | a stray login realm — the Vault KV `registrar` secret pointed here (v3) |
| `ampw_DYtMf796Nf` | worker-deregistrar | same |

Why it matters: the brokers ended up in two realms that share nothing with the
admin's method, so one `boundary_auth_method_id` can no longer address both —
exactly what `autoscaling/brokers` and the weekly rotation workflow assume —
and every doc referenced the original id while the secrets pointed at the new
one. Fix: create `worker-registrar` / `worker-deregistrar` as **accounts** on
`ampw_WNbi76VghW`, wire them to the users, re-put both KV secrets with
`auth_method_id=ampw_WNbi76VghW`, prove both logins, then delete the two stray
methods (accounts first — Boundary refuses to delete a non-empty method).
Documented as the recovery box in walkthrough A1.

### 2. Worker-tag vocabulary drift

The credential store and targets were
built filtering on `"k8s_vault" in "/tags/type"` (earlier still: the worker's
registered *name*). The ASG workers carry `type = ["eks","vpc","private","asg"]`
— no `k8s_vault` — so under the old filters every autoscaled worker would be
filtered out of every session while looking perfectly healthy in the UI.
The intent was to unify on one tag, `"eks" in "/tags/type"`, across all three
per-tier targets and the credential store.

> **It was only ever applied to `eks-api-viewer`.** Checked on 2026-09-23:
> `eks-api-operator` and `eks-api-admin` were still filtering on
> `"k8s_vault" in "/tags/type"`, and **no worker has ever carried that tag** —
> so both tiers could select zero workers and every session on them would have
> failed with "no workers available". Nobody noticed because only the viewer
> tier was ever tested. Writing down a fix is not applying it; re-read the
> objects afterwards. See finding 17 below.

---

## Found on the 2026-09-22/23 run — one silent failure, five layers of symptom

The presenting complaint was "the ASG worker is running but nothing appears in
Datadog". Datadog was the *last* link in a chain that broke at the first. Worth
recording in order, because the diagnosis went backwards through every layer.

### 1. The launch template held the raw template, not a rendered one

The
user-data in `lt-03048f2080f792bee` version 2 was byte-for-byte identical to
`autoscaling/asg/user-data.sh.tpl`, all eight `${…}` placeholders intact — the
file was pasted into the console without being run through `templatefile()`.

Why it is silent: user-data starts with `set -euo pipefail`, and the heredoc
that writes `/etc/boundary/env` is **unquoted**, so bash expands
`${boundary_addr}` as a shell variable. It is unset, `set -u` makes that fatal,
and the script dies on **line 10** — before the SSM read, before `datadog.yaml`,
before all four `systemctl start` lines. Nothing surfaces it: cloud-init's
failure is not a health check, so the ASG reports the instance `InService`.

### 2. `/etc/boundary/env` exists but is empty — which defeats the guard

Every
unit gates on `ConditionPathExists=/etc/boundary/env`. `install … /dev/null`
created the file before the `cat` died, so the condition *passes* and
`boundary-register.service` starts anyway, then dies inside
`boundary-common.sh` on `AWS_REGION: unbound variable`. No `worker.hcl` → the
`ConditionPathExists` on `boundary-worker.service` fails → nothing listens on
`:9203`. A condition that checks existence but not content is not a guard.

### 3. The AMI's dummy Datadog key makes a dead agent look alive

The Ansible
install runs with `DD_API_KEY=0123456789abcdef0123456789abcdef` so the image
bakes without a real key. `conf.d`, `checks.d` and the agent all come from the
AMI, so with user-data dead the agent still starts, loads the custom check and
runs it cleanly — while every submission is rejected for an invalid key.
`datadog-agent status` looks healthy end to end. The only true signal was
`Metric Samples: Last Run: 0`.

### 4. The custom check reports no-data, not zero, when the worker is down

`boundary_worker.py` returns immediately after `service_check(CRITICAL)` on any
exception, before reaching `self.gauge(…)`. So a worker with no ops listener
emits *nothing* for `boundary.worker.active_sessions`. The scale-in monitor —
`avg(last_15m) < 3` with `notify_no_data = false` — therefore stays silent
rather than firing. Correct by accident, but for the wrong reason.

### 5. Vault was never exposed

`vault_addr` pointed at an NLB hostname that
returned no DNS; the account had **zero** load balancers. `vault-0` was Running
and ready the whole time — the `vault` Service is `ClusterIP`, so there was no
external address at all. The URL had not changed; it had never existed on this
rebuild. Fixed with an additive `vault-nlb` Service (`type: LoadBalancer`,
`aws-load-balancer-internal: "true"`), leaving the ClusterIP alone for the
in-cluster clients. Note this hostname is regenerated on every recreate — it is
the same failure as the NLB-hostname entry in the pre-autoscaling list.

### 6. Two walkthrough steps were skipped, and neither fails loudly

The SSM
parameter `/boundary-worker/datadog_api_key` did not exist (the IAM role had
`ssm:GetParameter` on a path holding nothing), and
`AmazonSSMManagedInstanceCore` was never attached — so the workers never
appeared in Session Manager and everything had to be inferred from outside.
Added verification commands to walkthrough B1/B2.

### 7. The ASG was pinned to launch-template version 2, and `max` was 1

Not
`$Latest`, despite the walkthrough saying *Latest* and the Terraform declaring
`version = "$Latest"` — so a new template version changed nothing until the ASG
was repointed. With `max: 1`, `scale.yml` also clamps every scale-out to the
bound and exits green: the autoscaling loop could never demonstrate anything.

### 8. `source /etc/boundary/env` never exported anything

With user-data fixed
and `/etc/boundary/env` fully populated, registration still failed:

```
Error authenticating: Put "https://127.0.0.1:8200/v1/auth/aws/login":
dial tcp 127.0.0.1:8200: connect: connection refused
```

`127.0.0.1:8200` is the `vault` CLI's *built-in default*. `boundary-common.sh`
did a bare `source /etc/boundary/env`, which creates **shell** variables — and
`vault` and `boundary` are child processes that read `VAULT_ADDR` /
`BOUNDARY_ADDR` from the **environment**. Only `AWS_DEFAULT_REGION` had an
explicit `export`, so it was the only value that ever reached a child. Vault was
reachable the whole time (`curl $VAULT_ADDR/v1/sys/health` → 200); nothing was
ever asking it. The error names an address no one configured, which is what made
it read like a networking fault. Fixed twice over: `set -a` around the `source`
in `boundary-common.sh` (correct fix, needs an AMI rebuild) and an `export`
prefix on every line written by user-data (takes effect immediately, no rebuild).
Verified no unit consumes that file as an `EnvironmentFile=`, which would reject
the prefix.

### 9. The registrar broker authenticates but cannot create

With Vault working,
the next failure was from Boundary itself:

```
{"context":"Error from controller when performing create on controller-led-type worker",
 "status_code":403,"api_error":{"kind":"PermissionDenied","message":"Forbidden."}}
```

Vault login, secret read and Boundary login all succeeded — this is authorization,
not authentication. The role itself was fine: `worker-registrar` (`r_NnBA0zqQHb`)
sits in `global`, `grant_scope_ids = ["children","this"]`, with exactly
`type=worker;actions=create:controller-led`.

**The real cause: the item-1 remediation was only half applied.** There are two
`worker-registrar` accounts, and the roles point at the wrong one:

| account | auth method | attached to a user? |
|---|---|---|
| `acctpw_qf5Ty3xOv4` | `ampw_ARewCYhH63` (stray) | yes — it is the role's principal |
| `acctpw_H7IEi7BFEI` | `ampw_WNbi76VghW` (real) | **no user, therefore no role** |

New accounts were created on the real method and both KV secrets were re-pointed
at it, but the accounts were never added to the users — so the users, and with
them both roles, are still bound to accounts on the stray methods. The worker
authenticates perfectly against the real method as an identity holding zero
grants. That is why the failure is `403`, not `401`: getting a valid token
proves nothing about having a role. Same fault on `worker-deregistrar`
(`acctpw_QtfxSbNECn`), where it would surface only at scale-in, as a worker that
fails to deregister. Fix:

```bash
boundary users add-accounts -id u_uoIkzXPEJW -account acctpw_H7IEi7BFEI  # registrar
boundary users add-accounts -id u_BJaBUYCBcr -account acctpw_QtfxSbNECn  # deregistrar
```

Then delete the two stray methods (accounts first — Boundary refuses to delete a
non-empty method), which is what item 1 always called for.

### 10. The ops listener had no `tls_disable`, so the worker never started

With
registration finally working, `boundary-worker.service` crash-looped on:

```
Error initializing listener of type tcp: tls not disabled for listener at
address "127.0.0.1:9203" with purpose "ops" but no certificate file supplied
```

Boundary refuses an ops listener with neither a certificate nor TLS explicitly
off (exit 3). The `worker.hcl` heredoc in `boundary-register.sh` omitted it,
while both readers of that port use plain `http://` on loopback. Fixed in the
script — which lives **in the AMI**, so it needs a Packer rebuild to take
effect; patching a running instance does nothing for the next one.

### 11. `t3.micro` is too small, and the way it fails hides itself

With the
rebuilt AMI the worker started and was then **OOM-killed**:

```
Out of memory: Killed process 1865 (boundary) anon-rss:473652kB
task_memcg=/system.slice/boundary-worker.service
```

1 GiB does not hold the Boundary worker (~470 MiB RSS plus two
`boundary-plugin` children) next to the Datadog agent stack (`agent`,
`trace-loader`, `agent-data-plane`, `system-probe`). The worker's own comment
called `t3.micro` "ample" for a TCP proxy, which it is — the agent is what does
not fit.

The cascade is what makes it expensive to diagnose: OOM kill → systemd restarts
every 5 s → sustained ~52% CPU on a box with a 10% baseline → **CPUCreditBalance
hits 0** → the instance is throttled to ~0.2 vCPU → the **SSM agent is starved**
and goes `ConnectionLost`, so Session Manager and Run Command both stop
answering. The box becomes unreachable *because of* the bug you are trying to
inspect. `aws ec2 get-console-output --latest` needs no agent and is what
finally showed the OOM line — reach for it first when an instance stops
responding to SSM. Fixed with `t3.small` (2 GiB) plus
`CreditSpecification: unlimited`.

### 12. `systemctl enable --now` is a no-op on an already-running unit

No
Boundary logs ever reached Datadog. `logs_enabled: true` was in `datadog.yaml`,
the `logs:` block was in `conf.d`, the agent reported healthy — and
`datadog-agent status` said **"Logs Agent is not running"**. Timestamps explain
it:

```
ActiveEnterTimestamp = 07:17:27   agent started (the RPM enables the unit, so systemd starts it at boot)
datadog.yaml mtime   = 07:17:33   user-data wrote the real config 6 s later
```

The Datadog RPM enables the service, so systemd starts the agent *before*
user-data runs. `enable --now` then does nothing, because the unit is already
active — the agent keeps the AMI's baked config (dummy key, no `logs_enabled`)
and never re-reads the file. The config on disk looks perfect, which is what
makes it hard to see. Fixed by `systemctl enable` + `systemctl restart` in
user-data. Note the same no-op would have kept the *metrics* on the dummy key
too; item 3 and this one are the same latent fault seen from two directions.

### 13. Boundary writes `events.log` mode 0600, so dd-agent cannot tail it

The
Ansible role does add `dd-agent` to the `boundary` group and makes
`/var/log/boundary` 0750 — both correct, and both useless, because Boundary
creates the log file itself under the default umask:

```
-rw-------. 1 boundary boundary  events.log
$ sudo -u dd-agent head /var/log/boundary/events.log
head: cannot open ... Permission denied
```

Group membership grants nothing against 0600. Nothing errors: the tailer simply
never delivers. Fixed with `UMask=0027` in `boundary-worker.service`, which
makes new files 0640 — readable by the boundary group, still closed to others.
Verified after both fixes: tailer `Status: OK`, 76 logs processed and sent.

Note Datadog tails a pre-existing file from the **end**, so nothing already
written is back-filled; generate new events (restart the worker) before
concluding it is still broken.

### 14. The metric the whole design scales on does not exist on this path

`active_session_count` from `/health?worker_info=1` is **always 0** on Boundary
v1.0.1+ent for a multi-hop egress worker. Not a reporting lag — a live k8s API
tunnel and 1815 `worker.(*dataplaneService).ProxyChain` events in three minutes,
with every counter reading zero, including cumulative `_total` ones that can
only grow.

The cause is which path the traffic takes. A worker that only dials **out** is
reached over the enterprise reverse-connection dataplane (`reverseconn_ent`,
`ProxyChain`), and that path is not instrumented. The counters that exist are
all `boundary_worker_proxy_websocket_*`, which belong to the **direct**
client→worker proxy. Protocol is irrelevant: an SSH target over the same egress
worker behaves identically, because the transport differs, not the protocol.

Proved by making the worker directly reachable — public subnet, public IP,
`public_addr` resolved from IMDS at boot, 9202 open to the client, and an
`ingress_worker_filter` on the target. `boundary_worker_proxy_websocket_active_connections`
then tracked the session count exactly (13 sessions → 13).

Consequences, all from the same root: the two scaling monitors,
`boundary-protect.sh` scale-in protection, and the lifecycle drain were every
one of them reading a constant zero. Fixed by pointing `boundary_worker.py` at
`/metrics` instead of `/health` — same port, same metric name out, no change
needed to monitors or dashboard.

**Two traps when driving load against it.** The gauge counts OPEN connections,
so short requests raise the byte counters while it samples ~0; a Kubernetes
watch needs `timeoutSeconds` or the API returns at once and curl reconnects in
a loop. And `boundary connect` brokers the credential **once**, with a 900s
TTL, so unauthenticated or expired requests get an instant 401 that closes the
connection — the gauge read a correct 13 for 15 minutes and then decayed to 0
while the load script still reported 13 sessions, because it counts processes,
not working credentials. `scale-to-workers.sh` now retires each session at 720s.

### 15. GitHub Actions could not assume its AWS role — the role never existed

`autoscaling/asg/github-oidc.tf` was never applied, so neither the
`token.actions.githubusercontent.com` OIDC provider nor
`boundary-workers-github-actions` was present:
`Could not assume role with OIDC: The web identity token provided could not be
validated`. Everything upstream worked — the Datadog monitor fired and the
webhook reached GitHub (run 35841289818 exists) — only the last hop was unbuilt.
After creating both, the error changed to `Not authorized to perform
sts:AssumeRoleWithWebIdentity` — with the trust policy byte-identical to the
Terraform, the correct audience, the ARN confirmed by overwriting the secret,
and no SCP (this is the org's management account).

**The cause: GitHub's `sub` claim is not `repo:owner/name`.** It carries
immutable numeric ids:

```
expected  repo:rosaliei/boundary-eks-vault-okta:*
actual    repo:rosaliei@40911856/boundary-eks-vault-okta@1358281041:ref:refs/heads/main
```

GitHub embeds `@<owner-id>` and `@<repo-id>` so the subject survives a rename.
Every tutorial and every Terraform example — including this repo's
`github-oidc.tf` — writes the readable form, which silently never matches. The
failure is indistinguishable from a misconfigured trust policy, and no amount of
re-reading it helps, because the policy *is* what the documentation says.

The only way to see it is to print the claims from inside a workflow:

```yaml
- run: |
    TOKEN=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
      "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" | jq -r .value)
    echo "$TOKEN" | cut -d. -f2 | base64 -d | jq '{sub,aud,repository}'
```

Fixed by a `github_repo_sub` variable holding the real value. With it the same
workflow succeeded immediately: `desired: 1 -> 2`.

Note the diagnostic that did **not** work: widening the trust policy to drop
the `sub` condition. It would have proved the point, but weakening a trust
policy to debug it is the wrong instinct — reading the claim is both safer and
more informative, because it tells you the correct value rather than only that
the old one was wrong.

### 16. `UMask` cannot fix a file created with an explicit mode

The Datadog log
tailer could not read `/var/log/boundary/events.log` (0600). Adding
`UMask=0027` to `boundary-worker.service` looked right — the unit had it, the
process had it, a probe file it created came out 0640 — and changed nothing,
because a umask can only *remove* permission bits and Boundary opens that file
with an explicit 0600. Fixed with a systemd `.path` unit that fires on
`PathExists` and chmods the file to 0640, re-arming if it is rotated away.

**A note on SSM and crash-looping units.** `systemctl restart` over Run Command
**hangs** on a unit in a restart loop, wedging the SSM agent's command queue;
a reboot just replays the queued command and wedges it again. Use
`systemctl --no-block restart`, and prefer the console output for diagnosis.

**Ordering lesson.** Every one of these presents as a Datadog problem. The
working order is boot → register → worker → ops listener → agent → metric →
monitor, and the first check should always be `cat /etc/boundary/env`. Items
1, 8 and 9 are three different failures that all surface as the same
`:9203 connection refused`; only the journal for `boundary-register`
distinguishes them.

---

### 17. `boundary targets update` CLEARS filters you do not restate

Setting one filter wipes the other. Running

```bash
boundary targets update tcp -id <t> -ingress-worker-filter '"eks" in "/tags/type"'
```

left `eks-api-viewer` with an ingress filter and **egress set to null**. The
update call replaces unspecified fields rather than merging them, and the
immediate response still printed both — the clearing showed up only on a later
read.

Null egress is not harmless: it means "any worker", which is exactly the
condition that put every session on an uninstrumented path and held the metric
at 0 (finding 14). Always pass **both** filters together, and re-read the target
afterwards:

```bash
boundary targets update tcp -id <t> \
  -ingress-worker-filter '"eks" in "/tags/type"' \
  -egress-worker-filter  '"eks" in "/tags/type"'
boundary targets read -id <t> -format json | jq '{ingress:.item.ingress_worker_filter, egress:.item.egress_worker_filter}'
```

### 18. The bootstrap worker cannot coexist with the pool once ingress filtering exists

`kst-eks-ap-southeast-1-worker-01` — the single hand-built worker that proves
the chain before any autoscaling exists — kept the `eks` tag, so the target
filters selected it. But it:

| | |
|---|---|
| advertised `0.0.0.0:9202` | which no client can dial |
| sat in a **private** subnet | so it could never be an ingress worker |
| ran **no** Datadog agent and **no** ops listener | so any session on it was invisible to the metric |
| had been dead since 2026-09-20 | while still sitting in the worker registry |

Before ingress filtering, an unreachable worker was merely useless. After it, it
is worse than absent: Boundary selects it, the client cannot connect, and the
session fails — intermittently, depending on which worker is picked.

**The rule:** a worker may carry the `eks` tag only if it is *directly
reachable*. Stopping the instance is not enough — the registry entry outlives
it. Delete the worker record, or give the bootstrap instance a tag the target
filters do not match.

`aws/boundary-worker.tf` still declares that instance, so a `terraform apply` in
`aws/` restarts it and it re-registers with the `eks` tag. That is the one path
by which this reappears.


## Troubleshooting

Symptoms actually hit while building this, and their causes:

| Symptom | Cause |
|---|---|
| `unsupported Kubernetes version 1.29` | Version out of EKS support. `aws eks describe-cluster-versions` lists creatable ones |
| `name_prefix ... (1 - 38), got ...` | Node group IAM role name too long — set `iam_role_name` + `iam_role_use_name_prefix = false` |
| Worker crash-loops, `config cannot contain name or description` | `name` in `worker.hcl` with activation-token auth — set it via `-name` at registration |
| `No egress workers can handle this session` | Target's egress filter matches no worker — filter is `"eks" in "/tags/type"`; check the worker's `worker.hcl` tags |
| `failed to create a service account token ... forbidden` | Step 3b missing — `auth-delegator` is not enough |
| Okta `invalid_scope` | Requesting `groups` from a custom authorization server that has no such scope |
| Okta `Policy evaluation failed` | Custom authorization server has no Access Policy permitting the client |
| `'groups' is reserved and cannot be used` | Naming a custom claim `groups` — it is a reserved scope on the org server |
| Login works, targets list empty | Managed group matched nobody. Check the claim reaches the **ID token**, then that group names match exactly |
| Target visible but Connect denied | Seeing it via `Default Grants` (`u_auth`), not a role. Listing ≠ `authorize-session` |
| Membership unchanged after fixing Okta | Groups are evaluated at login. Log out fully — a cached Okta session reissues the old claims |

**Debugging managed groups:** create a temporary managed group with a filter you
know must match, e.g. `"/token/email" == "you@example.com"`, and another with
`"/token/groups" is not empty`. One login then distinguishes "claims are not
arriving at all" from "claims arrive but values differ".

---

