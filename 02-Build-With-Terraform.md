# Automation walkthrough — Terraform

The same platform as [Build by hand](01-Build-By-Hand.md), built with
code. Read [README.md](README.md) for what it is and why.

Build the layers in order. Each one uses names the previous layer created.

```
aws/      →  k8s/      →  vault/    →  boundary worker  →  Okta  →  boundary/
EKS+VPC      RBAC         secrets      the proxy           IdP      targets
```

---

## 1. EKS and the network

```bash
cd aws
cp ../terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Creates the VPC (3 public + 3 private subnets, one NAT gateway), the EKS
cluster with a **private-only** API endpoint, a node group, and the
hand-managed Boundary worker.

To reach the cluster while building, temporarily allow your IP:

```bash
aws eks update-cluster-config --name hc-eks-cluster \
  --resources-vpc-config publicAccessCidrs=<your-ip>/32,endpointPublicAccess=true,endpointPrivateAccess=true
```

Turn it off again when Boundary works — that is the whole point of the build.
This call never needs cluster access, so it cannot lock you out.

```bash
aws eks update-kubeconfig --region ap-southeast-1 --name hc-eks-cluster
kubectl get nodes
```

## 2. Kubernetes RBAC

```bash
kubectl apply -f k8s/rbac.yaml
```

Creates the `demo-app` namespace, three ServiceAccounts (viewer, operator,
admin) and their Roles. These are the identities Vault will mint tokens for.

## 3. Vault

```bash
cd vault
cp terraform.tfvars.example terraform.tfvars   # kubernetes_host, ca.crt
terraform init && terraform apply
```

Enables the Kubernetes secrets engine and creates one role per tier.

Vault needs a credential that does not expire. Use a
`kubernetes.io/service-account-token` Secret, not `kubectl create token` —
EKS silently caps requested token lifetimes at 24 hours, and a day later
everything fails with an error naming the wrong ServiceAccount. See item 1 in
[notes/Issues.md](notes/Issues.md).

## 4. Okta

Console work — there is no Terraform for this layer.

1. **Applications → Create → OIDC → Web Application**
2. Sign-in redirect URI: your Boundary cluster's OIDC callback
3. **Groups**: `k8s-viewers`, `k8s-operators`, `k8s-admins`
4. **Sign On → OpenID Connect ID Token → Groups claim**: filter `k8s-.*`

The groups claim is the piece people miss. Without it Boundary sees an
authenticated user with no groups and every managed group stays empty.

## 5. Boundary

```bash
cd boundary
cp terraform.tfvars.example terraform.tfvars
terraform init && terraform apply
```

Creates the project scope, the OIDC auth method pointing at Okta, three managed
groups matching the Okta groups, three roles, the host catalog, the Vault
credential store, and one target per tier.

**Check the worker filter.** Targets select workers by tag. If the filter and
the worker's tags disagree, sessions fail with "no workers available" while
everything looks healthy in the UI.

## 6. End to end

```bash
boundary authenticate oidc -auth-method-id <amoidc_...>
boundary connect -target-id <ttcp_...>
```

You get a local port and a brokered ServiceAccount token. Use both:

```bash
kubectl --server=https://127.0.0.1:<port> \
  --tls-server-name=<cluster>.gr7.<region>.eks.amazonaws.com \
  --certificate-authority=vault/ca.crt \
  --token=<brokered token> \
  get pods -n demo-app
```

`--tls-server-name` is required: you dial `127.0.0.1` but must validate the EKS
certificate, which is issued for the cluster's real hostname.

---

## CI

Everything in `.github/workflows/` belongs to the autoscaling layer — AMI
builds, scale actuation, broker rotation. Nothing in this walkthrough needs a
pipeline; the four Terraform roots above are applied from a laptop.

> **Dependency — autoscaling.** For the workflows, the OIDC role they assume and
> the secrets they need, go to
> [autoscaling/02-Build-With-Terraform.md](autoscaling/02-Build-With-Terraform.md)
> **Step 6 (GitHub secrets)** and **Step 9 (hand the AMI build to CI)**.

---

## Next

You now have a working platform with **one** hand-managed worker. To replace it
with a pool that grows and shrinks on demand:

| | |
|---|---|
| Why it is built that way | [autoscaling/README.md](autoscaling/README.md) |
| Build it by hand | [autoscaling/01-Build-By-Hand.md](autoscaling/01-Build-By-Hand.md) |
| Build it with Terraform | [autoscaling/02-Build-With-Terraform.md](autoscaling/02-Build-With-Terraform.md) |

That layer needs this one finished first: it reuses the VPC, the EKS cluster,
the Vault secrets engine and the Boundary targets created here.
