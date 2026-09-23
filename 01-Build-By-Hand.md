# Manual walkthrough — build the platform by hand

Every step here was done by hand before it was automated. Do this once and you
will have touched every moving part; after that,
[Build with Terraform](02-Build-With-Terraform.md) does the same thing with
Terraform.

Read [README.md](README.md) first for what this is and why it is shaped this way.

The autoscaling layer is a separate build on top of this one — see
[autoscaling/](autoscaling/).

---


# Step 1 — EKS cluster

> **Scene [1](https://app.excalidraw.com/s/9hD7S5FgGWN/73UzMQca6Am) + [2](https://app.excalidraw.com/s/9hD7S5FgGWN/2XoNL6sXrLz)** · **Manual:** AWS console — VPC, subnets, NAT, then EKS with the public endpoint OFF, one node group, an access entry for your IAM user
> **Automation:** [`aws/vpc.tf`](aws/vpc.tf), [`aws/eks.tf`](aws/eks.tf) — `terraform apply` in `aws/`

Infrastructure is the one layer where Terraform is genuinely simpler than
clicking; the manual equivalent is dozens of console screens.

```bash
cd aws
terraform init
terraform apply          # VPC, 3 AZs, NAT, EKS, node group, Boundary worker EC2
```

What matters in the result:

- **Private endpoint enabled**, public endpoint restricted to your `/32`
  (`admin_public_cidrs`). This is why a worker inside the VPC is needed at all.
- `authentication_mode = "API"` — access entries, not the legacy `aws-auth`
  ConfigMap.
- Node group on **AL2023** (`ami_type`); Amazon Linux 2 AMIs do not exist for
  EKS 1.33+.
- Cluster version must be in **standard support**. AWS refuses to create a
  cluster on an end-of-life version — 1.29 and 1.30 are already rejected.

Admin kubeconfig, authenticated by your IAM access entry:

```bash
aws eks update-kubeconfig --region ap-southeast-1 --name hc-eks-cluster --profile hc-lab
kubectl get nodes
```

This admin path is separate from the Boundary path and stays available for
setup. The demo is about *not* needing it.

---

# Step 2 — Kubernetes RBAC

> **Scene [2](https://app.excalidraw.com/s/9hD7S5FgGWN/2XoNL6sXrLz)** · **Manual:** read `k8s/rbac.yaml` and check each SA → RoleBinding → Role pair against the drawing
> **Automation:** `kubectl apply -f` [`k8s/rbac.yaml`](k8s/rbac.yaml)

Vault issues tokens *for* ServiceAccounts; it does not create them. These must
exist before Vault is configured.

```bash
kubectl apply -f k8s/rbac.yaml
kubectl -n demo-app get sa,role,rolebinding
```

Creates namespace `demo-app` and three tiers, each ServiceAccount bound to a
namespaced Role:

```
vault-viewer   ──▶ viewer-binding   ──▶ Role viewer     (get/list/watch)
vault-operator ──▶ operator-binding ──▶ Role operator   (+ manage workloads)
vault-admin    ──▶ admin-binding    ──▶ Role admin      (full, namespace only)
```

Verify the boundaries are real:

```bash
kubectl auth can-i get pods           --as=system:serviceaccount:demo-app:vault-viewer -n demo-app   # yes
kubectl auth can-i delete deployments --as=system:serviceaccount:demo-app:vault-viewer -n demo-app   # no
```

> **Note:** the `viewer` Role currently includes `secrets` in its read list. A
> read-only tier that can read every Secret in the namespace is worth removing
> before this is anything but a demo.

---

# Step 3 — Vault

> **Scene [4](https://app.excalidraw.com/s/9hD7S5FgGWN/2didKmVk95t)** · **Manual:** 3a–3e below with the CLI, or [`vault/MANUAL-SETUP.md`](vault/MANUAL-SETUP.md)
> **Automation:** [`vault/main.tf`](vault/main.tf) — secrets engine + one role per tier (3a install stays manual)

## 3a. Install (dev mode)

Dev mode is in-memory and auto-unsealed. **Every restart wipes the config in
3c–3d.** Demos only.

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm install vault hashicorp/vault \
  --namespace vault --create-namespace \
  --set "server.dev.enabled=true" \
  --set "server.dev.devRootToken=root" \
  --set "injector.enabled=false"

kubectl -n vault rollout status statefulset/vault --timeout=180s
```

## 3b. Let Vault mint ServiceAccount tokens

**The step everything else fails on.** The Helm chart binds Vault to
`system:auth-delegator`, which grants `tokenreviews` and
`subjectaccessreviews` — the ability to *validate* tokens. The Kubernetes
secrets engine does the opposite: it *creates* tokens via the TokenRequest API,
which needs `create` on `serviceaccounts/token`. Without this, configuration
succeeds and credential requests return 403.

This is applied by `k8s/rbac.yaml` in step 2 — the ServiceAccount, the Role, the
RoleBinding and the Secret-backed token all live there. Nothing to paste:

```bash
kubectl -n demo-app get sa vault-secrets
kubectl -n demo-app describe role vault-token-creator
```

The grant that matters:

```yaml
rules:
  - apiGroups: [""]
    resources: ["serviceaccounts/token"]
    verbs: ["create"]
    resourceNames: ["vault-viewer", "vault-operator", "vault-admin"]
```

> **`resourceNames` is load-bearing, not decoration.** Without it,
> `create` on `serviceaccounts/token` lets Vault mint a token for *any*
> ServiceAccount in the cluster — including one bound to `cluster-admin`. That
> is a documented privilege-escalation path. Verified live: with the three names
> present, minting `vault-viewer` succeeds and minting `default` is refused with
> `serviceaccounts "default" is forbidden`.
>
> `create` normally cannot be name-scoped, because the object does not exist yet.
> Subresources are the exception: TokenRequest posts to
> `/serviceaccounts/{name}/token`, so the name is known at authorization time.

A **namespaced Role**, not a ClusterRole. A ClusterRole with `resourceNames`
restricts by name but not namespace — a `vault-viewer` in any other namespace
would still match.

Two ServiceAccounts, deliberately:

| ServiceAccount | Grant | Purpose |
|---|---|---|
| `demo-app/vault-secrets` | the Role above | **mint** tokens (secrets engine) |
| `kube-system/vault-auth` | `system:auth-delegator` | **validate** tokens (auth method, only if you enable it) |

Never one identity for both. Minting is the dangerous power.

> `kubectl auth can-i create serviceaccounts/token --as=...` reports **`no`
> even when this is granted** — it mis-evaluates subresources under
> impersonation. Test the real operation (step 3e) instead.

## 3c. Reach Vault

Vault is a ClusterIP service in a private cluster; nothing routes to it from
outside, including the Boundary worker.

```bash
kubectl -n vault port-forward svc/vault 8200:8200      # leave running
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root
vault status                                            # Sealed: false, Storage: inmem
```

## 3d. Enable and configure the secrets engine

```bash
vault secrets enable -path=kubernetes kubernetes

TOKEN_REVIEW_JWT=$(kubectl create token vault-auth -n kube-system --duration=8760h)
KUBE_CA=$(aws eks describe-cluster --name hc-eks-cluster --region ap-southeast-1 --profile hc-lab \
  --query 'cluster.certificateAuthority.data' --output text | base64 -d)

vault write kubernetes/config \
  kubernetes_host="https://6F66E12DC9593ADDD5CA21204650E2DA.gr7.ap-southeast-1.eks.amazonaws.com" \
  kubernetes_ca_cert="$KUBE_CA" \
  service_account_jwt="$TOKEN_REVIEW_JWT" \
  disable_local_ca_jwt=true
```

One Vault role per ServiceAccount. The link between Vault and Kubernetes is the
**ServiceAccount name, matched as a string** — nothing validates it:

```bash
for R in viewer operator admin; do
  vault write kubernetes/roles/$R \
    allowed_kubernetes_namespaces="demo-app" \
    service_account_name="vault-$R" \
    token_default_ttl="15m" \
    token_max_ttl="1h"
done
```

> Running Vault **in-cluster** instead lets you skip the JWT and CA entirely —
> `vault write -f kubernetes/config` reads them from the pod's own mount, and
> the ClusterRole in 3b binds to `vault/vault` rather than
> `kube-system/vault-auth`. The config above is the external-Vault shape.

## 3e. Prove it issues credentials

```bash
vault write kubernetes/creds/viewer kubernetes_namespace=demo-app
```

`vault write`, not `read` — the engine requires the namespace parameter. A
403 here means step 3b was skipped.

---

# Step 4 — Boundary worker

> **Scene [4](https://app.excalidraw.com/s/9hD7S5FgGWN/2didKmVk95t)** · **Manual:** read the auth token off the instance over SSM and activate it from your laptop (below)
> **Automation:** [`aws/boundary-worker.tf`](aws/boundary-worker.tf) builds the instance
>
> **Dependency — autoscaling.** Build this one worker first: it proves the whole
> chain (Vault trust, worker tags, target filters) before any autoscaling exists.
> See [autoscaling/01-Build-By-Hand.md](autoscaling/01-Build-By-Hand.md) **part B**.
>
> **Then retire it.** It advertises `0.0.0.0:9202` from a private subnet, so once
> the pool adds an *ingress* worker filter the filter selects this worker and the
> client cannot reach it — sessions fail intermittently, depending on which
> worker Boundary picks. Stopping the instance is not enough; the registry entry
> outlives it. `boundary workers delete -id <its-id>`, or give it a tag the
> target filters do not match. See finding 18 in [notes/Issues.md](notes/Issues.md).

HCP's cloud workers cannot see a private endpoint. A self-managed worker inside
the VPC dials *out* to HCP, giving Boundary a reverse tunnel in.

The EC2 instance is created by `aws/boundary-worker.tf` in step 1 — a
t3.micro in a private subnet, no public IP, no SSH key, SSM only. Cloud-init
installs `boundary-enterprise` and starts a systemd unit.

Registration is **worker-led** — no Boundary credentials touch AWS state:

```bash
# 1. read the auth request token off the instance
aws ssm start-session --target $(terraform -chdir=aws output -raw boundary_worker_instance_id) \
  --region ap-southeast-1 --profile hc-lab
sudo /usr/local/bin/worker-auth-token

# 2. activate it (from your laptop)
export BOUNDARY_ADDR=https://95390bdc-e040-47df-8638-7c996c0f98f7.boundary.hashicorp.cloud
boundary authenticate
boundary workers create worker-led \
  -name=kst-eks-ap-southeast-1-worker-01 \
  -worker-generated-auth-token=<TOKEN>

# 3. confirm
boundary workers list -scope-id global
```

Two things that will cost you an hour each:

- **The name cannot be set in `worker.hcl`.** With activation-token auth,
  Boundary refuses to start if the config carries `name` or `description` —
  they must come from the API at registration. Whatever you pass to `-name` is
  what the target filter must match.
- Before registration the worker logs `node is not yet authorized` on a loop.
  That is the normal waiting state, not an error.

---

# Step 5 — Okta

> **Scene [3](https://app.excalidraw.com/s/9hD7S5FgGWN/7rGrKHxR5PL)** · **Manual:** Okta admin console — app, groups, groups claim (5a–5c). This step is manual only
> **Automation:** none — Boundary never returns the Okta client secret, so Terraform cannot own the auth method

## 5a. Application

An **OIDC → Web Application**:

| Field | Value |
|---|---|
| Sign-in redirect URI | `https://<cluster>.boundary.hashicorp.cloud/v1/auth-methods/oidc:authenticate:callback` |
| Sign-out redirect URI | `https://<cluster>.boundary.hashicorp.cloud` |
| Grant type | Authorization Code |

Note the **Client ID** — with several OIDC apps in a tenant it is very easy to
configure the wrong one, and every symptom looks identical.

## 5b. Groups

*Directory → Groups*: create `eks-viewers`, `eks-operators`, `eks-admins` and
assign users. Check the **literal** names — the claim filter is case-sensitive,
so `EKS-Viewers` will not match `eks-.*`.

## 5c. The groups claim

Assigning a user to a group does **not** put groups in the token. That is
configured separately, and *where* depends on which authorization server you
use:

**Org authorization server** (`https://your-org.okta.com`) — the simpler path:

> *Applications → (your app) → Sign On → OpenID Connect ID Token → Edit*
>
> | Field | Value |
> |---|---|
> | Groups claim type | **Filter** — not Expression |
> | Groups claim filter | `groups` · **Matches regex** · `eks-.*` |

`groups` is a **reserved scope** on the org server, which is why Okta refuses
to let you name a *custom* claim `groups` elsewhere — and why the client must
request the `groups` scope (step 6b) for it to appear.

**Custom authorization server** (`.../oauth2/default`) — more moving parts:
define the claim under *Claims*, add a custom scope under *Scopes* (there is no
built-in `groups` scope, so requesting one returns `invalid_scope`), and add an
*Access Policy* + rule permitting your client, or every login fails with
`Policy evaluation failed`.

Verify with **Token Preview** on the authorization server before moving on: the
ID token payload should show `"groups": ["eks-viewers"]`. If it shows group
IDs, the Boundary filters must match the IDs instead.

---

# Step 6 — Boundary

> **Scene [3](https://app.excalidraw.com/s/9hD7S5FgGWN/7rGrKHxR5PL)** · **Manual:** Boundary UI, 6a–6e below, or [`boundary/MANUAL-SETUP.md`](boundary/MANUAL-SETUP.md)
> **Automation:** [`boundary/main.tf`](boundary/main.tf) — managed groups, roles, host catalog, targets (auth method stays manual)

## 6a. Project scope

*Orgs → (your org) → Projects → New* — name `eks-access`.

**Delete the auto-created "Default Grants" role.** It grants
`type=target;actions=list` to `u_auth` — every authenticated user — which makes
targets appear for people who have no role at all. That produces a convincing
illusion of working RBAC: users see the target and then fail at Connect,
because listing and `authorize-session` are different grants.

## 6b. OIDC auth method

Created in the **org** scope, not the project:

| Field | Value |
|---|---|
| Name | `okta-oidc` |
| Issuer | `https://trial-9050012.okta.com` (must match Okta's app Issuer setting) |
| Client ID / Secret | from step 5a |
| Signing algorithms | `RS256` |
| API URL prefix | your Boundary cluster URL |
| Allowed audiences | the Client ID |
| Claims scopes | `profile`, `email`, **`groups`** |

Then set **State → Active (public)** and make it primary for the scope.

`groups` in claims scopes is required on the **org** server and fatal on a
**custom** server that has no such scope. Issuer and scopes must be changed
together.

## 6c. Managed groups

On the auth method, three groups. Membership is recomputed from the token at
**every login** — never synced, so any change needs a fresh login to take
effect:

| Name | Filter |
|---|---|
| `viewers` | `"eks-viewers" in "/token/groups"` |
| `operators` | `"eks-operators" in "/token/groups"` |
| `admins` | `"eks-admins" in "/token/groups"` |

## 6d. Roles

In the **project** scope, principals are the managed groups above:

```
viewer      ids=*;type=target;actions=list,no-op
            ids=*;type=target;actions=authorize-session
            ids=*;type=session;actions=list,read:self,cancel:self

operator    the above, plus read on targets and list on host-catalog/host-set/host

admin       ids=*;type=<target|session|host-catalog|host-set|host>;actions=*
            ids=*;type=<credential-store|credential-library>;actions=*
```

`no-op` makes a resource appear in a list without granting `read` on its
details. `read:self` / `cancel:self` confine session actions to the user's own
sessions.

## 6e. Host catalog and target

In the project:

1. Host catalog → **Static**, name `eks-hosts`
2. Host `eks-api`, address `6F66E12D...gr7.ap-southeast-1.eks.amazonaws.com`
   — the hostname, not an IP; the worker resolves it inside the VPC to the
   private endpoint addresses
3. Host set `eks-api-hosts` containing that host
4. Target `eks-api` — type **TCP**, default port **443**, max session 28800s,
   host source `eks-api-hosts`, and:

```
Egress worker filter:  "eks" in "/tags/type"
```

That filter is load-bearing. It used to match the worker's **registered name**;
it now matches a **tag** the worker sets in its own `worker.hcl`
(`tags { type = ["eks", ...] }`). Reason: the autoscaling layer adds workers
with generated names (`worker-i-0abc…`), and a name filter would leave every one
of them unused. Tag the worker now even though nothing else needs it yet — see
[autoscaling/README.md](autoscaling/README.md) for why the filter is a tag. A filter that matches nothing fails at session time
with:

```
No egress workers can handle this session, as they have all been filtered out
```

---

# Step 7 — Vault credential brokering

> **Scene [4](https://app.excalidraw.com/s/9hD7S5FgGWN/2didKmVk95t)** · **Manual:** 7a–7c below: NLB, scoped token, credential store + libraries in the UI (worker filter first!)
> **Automation:** [`boundary/credentials.tf`](boundary/credentials.tf) — store, libraries, one target per tier

Steps 1-6 leave one wart: to get a Vault credential you port-forward to Vault,
which uses your **admin kubeconfig** — the exact access this design exists to
avoid. Boundary can fetch the credential for you instead.

## 7a. Give Vault a stable address in the VPC

A ClusterIP is not routable from the worker EC2. Expose Vault on an internal NLB:

```bash
helm upgrade vault hashicorp/vault -n vault --reuse-values \
  --set "server.service.type=LoadBalancer" \
  --set-string "server.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-type=nlb" \
  --set-string "server.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-internal=true"
```

`--set-string` matters. Plain `--set` parses `true` as a boolean and Helm fails
with `cannot unmarshal bool into ... annotations of type string`.

## 7b. A scoped Vault token for Boundary

Not root. Boundary requires the token be **periodic, orphan and renewable**:

```bash
vault policy write boundary-broker - <<'EOF'
path "kubernetes/creds/viewer"   { capabilities = ["create", "update"] }
path "kubernetes/creds/operator" { capabilities = ["create", "update"] }
path "kubernetes/creds/admin"    { capabilities = ["create", "update"] }
path "sys/leases/renew"          { capabilities = ["update"] }
path "sys/leases/revoke"         { capabilities = ["update"] }
path "auth/token/renew-self"     { capabilities = ["update"] }
path "auth/token/lookup-self"    { capabilities = ["read"] }
EOF

vault token create -policy=boundary-broker -period=24h -orphan -renewable=true
```

## 7c. Credential store, libraries, and one target per tier

Applied by [boundary/credentials.tf](boundary/credentials.tf). The store carries
a `worker_filter` — Vault is private, so the HCP controller cannot reach it and
the calls must route through the in-VPC worker.

The Kubernetes secrets engine is *written* to and needs a namespace in the body,
so the library uses POST with an explicit request body rather than a plain GET.

Then one target per tier, each bound to its own library. **This is where the
tiering is enforced**: the credential you receive is decided by which target
your role lets you authorize, not by anything you type.

```
viewer   role -> ids=ttcp_d9cw5TgQOO ; authorize-session
operator role -> ids=ttcp_jeFYI2LB06 ; authorize-session
```

A wildcard (`ids=*`) here is a privilege escalation: a viewer could authorize
`eks-api-admin` and be handed an admin credential.

---

# Step 8 — End to end

> **Scene [4](https://app.excalidraw.com/s/9hD7S5FgGWN/2didKmVk95t) → [5](https://app.excalidraw.com/s/9hD7S5FgGWN/9x6Q0ZNzt0P)** · **Manual:** two terminals below; then run the checklist in [Issues.md](notes/Issues.md#state-before-autoscaling-2026-09-15)
> **Automation:** none — this step is the proof, not a pipeline
>
> **Dependency — autoscaling.** Load generation and the scale test live there:
> [autoscaling/02-Build-With-Terraform.md](autoscaling/02-Build-With-Terraform.md) **Step 8 (load test)**.

```bash
export BOUNDARY_ADDR=https://95390bdc-e040-47df-8638-7c996c0f98f7.boundary.hashicorp.cloud
boundary authenticate oidc -auth-method-id=amoidc_eY8ldrT0GG

# terminal 1 - session AND credential, in one command
boundary connect -target-id=ttcp_d9cw5TgQOO -listen-port=8443 -format=json > /tmp/sess.json
```

`8443` is the port on **your laptop**; `443` is what the worker dials at the far
end. Ports below 1024 need root on macOS. The **web UI cannot do this** — it has
no way to open a local port, so TCP targets need the CLI or Boundary Desktop.

```bash
# terminal 2
TOKEN=$(jq -r '.credentials[0].secret.decoded.service_account_token' /tmp/sess.json)

aws eks describe-cluster --name hc-eks-cluster --region ap-southeast-1 --profile hc-lab \
  --query 'cluster.certificateAuthority.data' --output text | base64 -d > /tmp/eks-ca.crt

kubectl --server=https://127.0.0.1:8443 \
  --certificate-authority=/tmp/eks-ca.crt \
  --tls-server-name=6F66E12DC9593ADDD5CA21204650E2DA.gr7.ap-southeast-1.eks.amazonaws.com \
  --token="$TOKEN" -n demo-app get pods
```

No `vault` command. No port-forward. No admin kubeconfig.

## What the tiers actually do

Measured with `kubectl auth can-i` through each tier's own session:

| Tier | get pods | get secrets | create deploy | delete deploy | kube-system |
|---|---|---|---|---|---|
| viewer | yes | yes | no | no | no |
| operator | yes | yes | yes | yes | no |
| admin | yes | yes | yes | yes | no |

Note `viewer` can read Secrets — see [Security posture](README.md#security-posture-and-roadmap).

---

