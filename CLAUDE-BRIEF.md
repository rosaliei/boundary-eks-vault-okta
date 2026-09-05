# CLAUDE BRIEF — hc-eks-vault-okta-boundary-rbac

## Mission
Generate Terraform + a step-by-step README implementing the architecture below.
**Never run `terraform apply`.** Only `init`, `fmt`, `validate`, `plan` are allowed. `plan` may fail without real AWS creds — that's fine, note it.

## Architecture (extracted from the two Excalidraw diagrams in this folder)
```
User (Okta account, MFA)
  └─> HashiCorp Boundary — HCP cluster: https://95390bdc-e040-47df-8638-7c996c0f98f7.boundary.hashicorp.cloud
        • OIDC auth method backed by Okta (issuer, client_id, client_secret → Terraform variables, never hardcoded)
        • Okta groups claim → Boundary roles → grants (per-group scoping)
        └─> Target "eks-api": the EKS Kubernetes API endpoint, type=tcp, port 443
              • EKS cluster endpoint = PRIVATE (public access disabled)
              • A self-managed Boundary worker inside the cluster VPC gives line-of-sight
                (matches diagram: self-managed worker1 + VPC peering pattern)
        └─> Dynamic, short-lived k8s credentials from Vault Kubernetes secrets engine
              • Vault reads path roles/<role>/credentials → short-lived ServiceAccount token (TTL 900s default)
              • Each Vault role maps 1:1 to a k8s ServiceAccount + Role/RoleBinding (viewer | operator | admin)
              • User assembles kubeconfig: server = cluster endpoint (via Boundary), CA = cluster CA, token = dynamic credential
```
Auth flow order: Okta SSO → Boundary session → Vault dynamic creds → kubectl through Boundary target.

## Deliverables (create in this directory)
1. `terraform/` — AWS side
   - VPC + EKS via `terraform-aws-modules/eks/aws` (v20+)
   - Provider: `profile = "pegb"`, region variable default `ap-southeast-1`
   - `cluster_endpoint_public_access = false`, `cluster_endpoint_private_access = true`
   - Authentication mode: **access entries** (API), not legacy configmap
   - One managed node group (t3.medium, spot ok), common tags
2. `k8s/rbac.yaml` — namespaces + ServiceAccounts + Roles + RoleBindings for viewer/operator/admin (least privilege, documented)
3. `vault/` — Kubernetes secrets engine enablement + one Vault role per k8s role (default_ttl 900s, max_ttl 3600s). Prefer `hashicorp/vault` provider Terraform; CLI fallback documented in README.
4. `boundary/` — `hashicorp/boundary` provider Terraform, all sensitive values as variables:
   - OIDC auth method (Okta issuer/client_id/client_secret), scopes incl. groups claim
   - Group→Role→Grant mapping (viewer/operator/admin)
   - Host catalog + host set + target `eks-api` (tcp/443) pinned to the self-managed worker (`worker_filter`)
5. `README.md` — step-by-step integration guide, exact commands, manual console steps clearly marked:
   prereqs → EKS apply → kubeconfig(admin) → apply RBAC → Vault setup (k8s auth mount + secrets engine + roles) → Boundary (Okta OIDC auth method + groups/roles + worker + target) → end-to-end demo (Okta login → boundary connect → vault read creds → kubectl --token)
6. `terraform.tfvars.example` + `variables.tf` with descriptions. **No secrets, no real IDs in code.**

## Hard rules
- EKS module = `terraform-aws-modules/eks/aws`; AWS profile `pegb` in the provider only.
- `terraform apply` is FORBIDDEN. `terraform init/fmt/validate` allowed (and `plan` — failure without creds is acceptable, say so).
- Keep files small, commented, and idiomatic; pin provider versions with `~>`.
- Summarize created files + any assumptions at the end.
