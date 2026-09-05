# Boundary Manual Setup — Scopes, Roles, Targets (HCP UI)

> **Superseded in part.** Terraform now manages these objects
> ([boundary/main.tf](main.tf), [boundary/credentials.tf](credentials.tf)) and
> there are three per-tier targets rather than one. This file remains useful as
> the UI walkthrough and for understanding what each object is for.

The Terraform in this folder is **reference only — do not `terraform apply` it.**
This is the click-through for building the same objects by hand. Each section
names the Terraform resource it mirrors, so [main.tf](main.tf) stays readable as
a spec and the objects can be imported later.

**Cluster:** https://95390bdc-e040-47df-8638-7c996c0f98f7.boundary.hashicorp.cloud

### Prerequisites

- Okta app + `eks-viewers` / `eks-operators` / `eks-admins` groups exist, and the
  Okta authorization server emits a **`groups` claim in the ID token**. Without
  that claim every managed-group filter below silently matches nobody.
  See [../README.md](../README.md) Step 6.
- Worker `kst-eks-ap-southeast-1-worker-01` is registered and connected.

### Build order

Scopes must exist before roles, and host sets before targets:

```
Org scope (exists)
 ├── Auth method: okta-oidc          ← org level
 │    └── Managed groups: viewers, operators, admins
 └── Project: eks-access             ← everything below lives here
      ├── Roles: viewer, operator, admin   (principals = the managed groups)
      ├── Host catalog: eks-hosts
      │    ├── Host: eks-api
      │    └── Host set: eks-api-hosts
      └── Target: eks-api  (TCP/443, egress worker filter)
```

---

## 1. Project scope

> `boundary_scope.project` — [main.tf:18](main.tf#L18)

*Orgs → (your org) → Projects → **New Project***

| Field | Value |
|---|---|
| Name | `eks-access` |
| Description | `EKS cluster access via Boundary and Vault dynamic credentials` |

Note the project's ID (`p_...`) — several later screens ask for it.

**Then delete the auto-created default role.** The UI adds a permissive default
role to every new project; the Terraform sets `auto_create_default_role = false`
because the three explicit roles in section 3 are meant to be the whole grant
surface. Leaving it in place means anonymous/authenticated users get grants you
did not intend.

Keep the auto-created **admin** role — the Terraform keeps that one
(`auto_create_admin_role = true`), and it is what lets you keep administering
the project.

---

## 2. Auth method and managed groups

> `boundary_auth_method_oidc.okta` — [main.tf:30](main.tf#L30)
> `boundary_managed_group.*` — [main.tf:56-81](main.tf#L56-L81)

These live in the **org** scope, *not* in `eks-access`. That is deliberate:
identity is org-wide, while the things people connect to are per-project.

*Org → Auth Methods → **New** → OIDC*

| Field | Value |
|---|---|
| Name | `okta-oidc` |
| Description | `Okta OIDC authentication for EKS access` |
| Issuer | your Okta issuer URL |
| Client ID / Secret | from the Okta app |
| Signing algorithms | `RS256` |
| API URL prefix | `https://95390bdc-e040-47df-8638-7c996c0f98f7.boundary.hashicorp.cloud` |
| Allowed audiences | your Client ID |
| Claims scopes | `profile`, `email`, `groups` |

Do **not** list `openid` — Boundary always requests it. ([main.tf:41](main.tf#L41)
includes it and is wrong on that point.)

After saving: set **State → Active (public)**, and make it the **primary auth
method for the scope** so first-time Okta logins auto-create a Boundary account.

Then *Auth Method `okta-oidc` → Managed Groups → **New*** three times:

| Name | Filter |
|---|---|
| `viewers` | `"eks-viewers" in "/token/groups"` |
| `operators` | `"eks-operators" in "/token/groups"` |
| `admins` | `"eks-admins" in "/token/groups"` |

Quoting is literal on both sides. Membership is re-evaluated from the token at
every login — there is no directory sync, so removing someone in Okta revokes
their access on next auth.

---

## 3. Roles and grants

> `boundary_role.{viewer,operator,admin}` — [main.tf:87-142](main.tf#L87-L142)

Create all three inside **`eks-access`**, not the org. For each role:

1. *Project `eks-access` → Roles → **New*** — set the name
2. Open the role → **Principals** tab → **Add Principals** → pick the managed
   group from section 2
3. **Grants** tab → paste the grant strings, one per line

Roles live in the project while their principals live in the org. That is
allowed and expected — a project role may reference principals from its parent
org.

### `viewer` ← managed group `viewers`

Can see the target exists and open a session to it. Nothing else.

```
ids=*;type=target;actions=list,no-op
ids=*;type=target;actions=authorize-session
ids=*;type=session;actions=list,read:self,cancel:self
```

`no-op` is what makes a resource *appear* in a list without granting `read` on
its details. `read:self` / `cancel:self` scope session actions to the user's own
sessions — they cannot see or kill anyone else's.

### `operator` ← managed group `operators`

Viewer, plus visibility into the host plumbing behind the target.

```
ids=*;type=target;actions=list,no-op,read
ids=*;type=target;actions=authorize-session
ids=*;type=session;actions=list,read:self,cancel:self
ids=*;type=host-catalog;actions=list,no-op
ids=*;type=host-set;actions=list,no-op
ids=*;type=host;actions=list,no-op
```

### `admin` ← managed group `admins`

Full control of everything inside the project.

```
ids=*;type=target;actions=*
ids=*;type=session;actions=*
ids=*;type=host-catalog;actions=*
ids=*;type=host-set;actions=*
ids=*;type=host;actions=*
ids=*;type=credential-store;actions=*
ids=*;type=credential-library;actions=*
```

The last two are unused today — they are there for when Vault credential
libraries get attached to the target.

> These grants control **Boundary** only: who may reach the cluster's API port.
> What they can actually *do* once connected is decided separately by Vault's
> issued token and [../k8s/rbac.yaml](../k8s/rbac.yaml). A Boundary `admin` with a
> viewer-level Kubernetes role still cannot write to the cluster.

---

## 4. Host catalog, host, host set

> `boundary_host_catalog_static.eks` / `boundary_host_static.eks_api` /
> `boundary_host_set_static.eks_api` — [main.tf:148-176](main.tf#L148-L176)

All inside `eks-access`.

1. *Host Catalogs → **New** → type **Static*** — name `eks-hosts`
2. Inside it, *Hosts → **New*** — name `eks-api`, address:
   ```
   BB0C8B66351A596AC1A823FDBAF38F90.gr7.ap-southeast-1.eks.amazonaws.com
   ```
   Use the hostname, not an IP. The worker resolves it from inside the VPC,
   where Route 53 returns the private endpoint addresses (10.0.1.142,
   10.0.3.136). Hard-coding an IP breaks when AWS rotates the control-plane ENIs.
3. *Host Sets → **New*** — name `eks-api-hosts`, add host `eks-api`

---

## 5. Target

> `boundary_target.eks_api` — [main.tf:178-194](main.tf#L178-L194)

*Project `eks-access` → Targets → **New***

| Field | Value |
|---|---|
| Name | `eks-api` |
| Description | `EKS Kubernetes API (private endpoint, port 443)` |
| Type | **TCP** |
| Default port | `443` |
| Max session duration | `28800` (8 hours) |
| Max connections | `-1` (unlimited) |

Save, then attach the rest on the target's own pages:

- **Host Sources** tab → add `eks-api-hosts`
- **Workers** / egress filter field → `"/name" == "kst-eks-ap-southeast-1-worker-01"`

The egress worker filter is the load-bearing setting on this whole page. Without
it, HCP's cloud-hosted workers try to reach a private endpoint they have no
route to, and every session hangs until it times out. The value must match the
name the worker was **registered** under — that name came from
`boundary workers create -name=...`, not from `worker.hcl`.

---

## 6. Verify each layer

```bash
export BOUNDARY_ADDR=https://95390bdc-e040-47df-8638-7c996c0f98f7.boundary.hashicorp.cloud

# Worker is healthy (should show kst-eks-ap-southeast-1-worker-01 with a recent status)
boundary workers list -scope-id global

# Log in as a member of one of the Okta groups
boundary authenticate oidc -auth-method-id=<amoidc_...>

# Did the managed group match? Empty output = the groups claim never arrived
boundary users read -id=<u_...> -format=json | jq '.item.name'

# Does the role grant visibility?
boundary targets list -scope-id=<p_...>

# Open the tunnel
boundary connect -target-name eks-api -target-scope-name eks-access
```

Failure map:

| Symptom | Cause |
|---|---|
| Login works, `targets list` empty | Managed-group filter matched nothing — check the Okta `groups` claim is in the **ID token** |
| Target visible, `connect` hangs then times out | Egress worker filter wrong, or worker offline |
| `connect` opens but kubectl rejects the cert | Expected — see below |

### kubectl over a TCP target

`boundary connect` hands you `127.0.0.1:<port>`, but the EKS certificate is
issued for `*.gr7.ap-southeast-1.eks.amazonaws.com`, so kubectl fails hostname
verification. Either:

```bash
boundary connect kube -target-name eks-api -target-scope-name eks-access -- get pods -A
```

or point kubeconfig at the proxy and override the expected name:

```bash
kubectl config set-cluster hc-eks-cluster \
  --server=https://127.0.0.1:<port> \
  --tls-server-name=BB0C8B66351A596AC1A823FDBAF38F90.gr7.ap-southeast-1.eks.amazonaws.com
```

---

## Adopting this into Terraform later

The resource blocks already describe every object above, so this is an import,
not a rewrite. Collect the IDs from the UI:

```bash
terraform import boundary_scope.project                p_xxxxxxxx
terraform import boundary_auth_method_oidc.okta        amoidc_xxxxxxxx
terraform import boundary_managed_group.viewers        mgoidc_xxxxxxxx
terraform import boundary_managed_group.operators      mgoidc_xxxxxxxx
terraform import boundary_managed_group.admins         mgoidc_xxxxxxxx
terraform import boundary_role.viewer                  r_xxxxxxxx
terraform import boundary_role.operator                r_xxxxxxxx
terraform import boundary_role.admin                   r_xxxxxxxx
terraform import boundary_host_catalog_static.eks      hcst_xxxxxxxx
terraform import boundary_host_static.eks_api          hst_xxxxxxxx
terraform import boundary_host_set_static.eks_api      hsst_xxxxxxxx
terraform import boundary_target.eks_api               ttcp_xxxxxxxx
```

Drop `openid` from `claims_scopes` first, or the first `plan` after import shows
a diff that is not real.
