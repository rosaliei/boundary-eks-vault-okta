# Issues log — everything that broke while building this, and why

The drawing version, with causes and fixes on one board:
**[Issues — what broke and why](https://app.excalidraw.com/s/9hD7S5FgGWN/9x6Q0ZNzt0P)**
(scene 5 of the [five scenes](README.md#start-here--the-five-scenes)).

Below is the full written record, moved out of the README so the README stays
a design document. Nothing here is hypothetical — every item was hit on a live
build, measured, and fixed.

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
- `boundary/` Terraform expects project `eks-access`, project-scoped roles and
  a name-based worker filter. Live is project `linux`, org-scoped roles, tag
  filters. Either `terraform import` the live objects or accept the drift.
- Node security-group rules for the Vault NLB NodePorts (30773, 32531 from
  0.0.0.0/0) are added by the in-tree cloud controller and are not in
  Terraform. Narrow with `spec.loadBalancerSourceRanges` if wanted.

**Before any further Boundary / Vault change, check:** current Vault NLB
hostname · every filter is a tag filter · each target has exactly one library ·
every `authorize-session` grant is pinned to a target id · worker version ≤ HCP
controller · `--profile pegb`.

---

## Troubleshooting

Symptoms actually hit while building this, and their causes:

| Symptom | Cause |
|---|---|
| `unsupported Kubernetes version 1.29` | Version out of EKS support. `aws eks describe-cluster-versions` lists creatable ones |
| `name_prefix ... (1 - 38), got ...` | Node group IAM role name too long — set `iam_role_name` + `iam_role_use_name_prefix = false` |
| Worker crash-loops, `config cannot contain name or description` | `name` in `worker.hcl` with activation-token auth — set it via `-name` at registration |
| `No egress workers can handle this session` | Target's egress filter does not match the worker's registered name |
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

