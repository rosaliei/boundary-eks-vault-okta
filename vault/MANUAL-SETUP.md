# Vault Dev Mode — Manual Setup (in-cluster)

Deploys Vault **inside the EKS cluster in dev mode** and wires up the Kubernetes
secrets engine by hand with the CLI.

> **Dev mode is for demos only.** Storage is in-memory, Vault starts unsealed
> with a known root token, and everything is lost when the pod restarts. Never
> point anything real at it.

Running Vault in-cluster sidesteps the network problem: Vault reaches the
Kubernetes API at `https://kubernetes.default.svc` from inside the cluster, so
the private EKS endpoint and your `admin_public_cidrs` lock are irrelevant. A
Vault outside the VPC (HCP Vault, laptop) cannot reach that endpoint at all.

---

## 0. Prerequisites

```bash
# kubectl pointed at the cluster (uses your IAM access entry, not Boundary)
aws eks update-kubeconfig --region ap-southeast-1 --name hc-eks-cluster --profile pegb
kubectl get nodes

# The ServiceAccounts Vault will mint tokens for must exist FIRST
kubectl apply -f k8s/rbac.yaml
kubectl -n demo-app get sa
#   vault-viewer / vault-operator / vault-admin
```

Vault does not create those ServiceAccounts — it issues tokens *for* them. If
they are missing, credential requests fail at read time, not at config time.

---

## 1. Install Vault in dev mode

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm install vault hashicorp/vault \
  --namespace vault --create-namespace \
  --set "server.dev.enabled=true" \
  --set "server.dev.devRootToken=root" \
  --set "injector.enabled=false"
```

`injector.enabled=false` skips the agent-injector webhook — it is for pods
pulling secrets at runtime, which this demo does not do.

Wait for it:

```bash
kubectl -n vault rollout status statefulset/vault --timeout=180s
kubectl -n vault get pods
#   vault-0   1/1   Running
```

Dev mode auto-initialises and auto-unseals. `kubectl -n vault exec vault-0 --
vault status` should show `Sealed: false`.

---

## 2. Give Vault permission to mint ServiceAccount tokens

This is the step that is easy to miss. Vault authenticates to Kubernetes as its
own ServiceAccount (`vault` in namespace `vault`), and that account has no
rights to create tokens for anyone else. Without this, every credential request
fails with a 403 from the Kubernetes API.

```bash
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: vault-token-creator
rules:
  # Mint short-lived tokens for the demo-app ServiceAccounts
  - apiGroups: [""]
    resources: ["serviceaccounts/token"]
    verbs: ["create"]
  # Read the ServiceAccounts it is minting for
  - apiGroups: [""]
    resources: ["serviceaccounts"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-token-creator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: vault-token-creator
subjects:
  - kind: ServiceAccount
    name: vault
    namespace: vault
EOF
```

Vault also needs `system:auth-delegator` if you later enable the Kubernetes
*auth* method (TokenReview). Not required for the secrets engine alone.

---

## 3. Reach Vault from your laptop

Vault has no public endpoint — it is a ClusterIP service in a private cluster.

```bash
kubectl -n vault port-forward svc/vault 8200:8200
```

Leave that running. In another shell:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root

vault status
#   Sealed  false
#   Storage Type  inmem
```

`http`, not `https` — dev mode serves plaintext.

---

## 4. Enable and configure the Kubernetes secrets engine

```bash
vault secrets enable -path=kubernetes kubernetes
```

Because Vault runs **inside** the cluster, it discovers the API address, the CA
certificate, and its own JWT from the pod's mounted service account. The config
is therefore almost empty:

```bash
vault write -f kubernetes/config
```

Verify what it picked up:

```bash
vault read kubernetes/config
#   kubernetes_host           https://172.20.0.1:443   (or kubernetes.default.svc)
#   disable_local_ca_jwt      false
```

> This differs from [main.tf](main.tf), which is written for a Vault **outside**
> the cluster: it sets `kubernetes_host` to the EKS public hostname, passes
> `kubernetes_ca_cert` and `service_account_jwt` explicitly, and sets
> `disable_local_ca_jwt = true`. If you later run this via Terraform against an
> in-cluster Vault, drop all four.

---

## 5. Create the three roles

One Vault role per Kubernetes ServiceAccount, matching [main.tf:42-90](main.tf#L42-L90).

```bash
for R in viewer operator admin; do
  vault write kubernetes/roles/$R \
    allowed_kubernetes_namespaces="demo-app" \
    service_account_name="vault-$R" \
    token_default_ttl="15m" \
    token_max_ttl="1h"
done

vault list kubernetes/roles
```

`service_account_name` means "issue tokens for this existing SA". The alternative
(`generated_role_rules`) has Vault create throwaway SAs and RoleBindings per
request — more dynamic, but then [k8s/rbac.yaml](../k8s/rbac.yaml) would be
redundant.

---

## 6. Request credentials

```bash
vault write kubernetes/creds/viewer kubernetes_namespace=demo-app
```

```
Key                          Value
lease_id                     kubernetes/creds/viewer/xxxx
lease_duration               15m
service_account_name         vault-viewer
service_account_namespace    demo-app
service_account_token        eyJhbGciOi...
```

Note it is `vault write`, not `vault read` — the engine needs the
`kubernetes_namespace` parameter, and it must be one of the namespaces allowed
on the role.

Use the token:

```bash
TOKEN=$(vault write -field=service_account_token \
  kubernetes/creds/viewer kubernetes_namespace=demo-app)

kubectl --token="$TOKEN" -n demo-app get pods          # allowed
kubectl --token="$TOKEN" -n demo-app delete deploy x   # forbidden
kubectl --token="$TOKEN" -n kube-system get pods       # forbidden (namespace-scoped Role)
```

The second and third commands failing is the demo. The token's power comes
entirely from the RoleBinding in [k8s/rbac.yaml](../k8s/rbac.yaml) — Vault only
decides *which* ServiceAccount you get and *for how long*.

---

## 7. Through Boundary (the full path)

Once the Boundary target works end to end, the same token is used over the
tunnel instead of your admin kubeconfig:

```bash
# terminal 1 - Boundary session to the EKS API
boundary connect -target-id ttcp_wjyPIYaOXp
#   Proxy listening on 127.0.0.1:PORT

# terminal 2
TOKEN=$(vault write -field=service_account_token \
  kubernetes/creds/viewer kubernetes_namespace=demo-app)

kubectl --server=https://127.0.0.1:PORT \
  --tls-server-name=BB0C8B66351A596AC1A823FDBAF38F90.gr7.ap-southeast-1.eks.amazonaws.com \
  --certificate-authority=<(aws eks describe-cluster --name hc-eks-cluster \
      --region ap-southeast-1 --profile pegb \
      --query 'cluster.certificateAuthority.data' --output text | base64 -d) \
  --token="$TOKEN" \
  -n demo-app get pods
```

`--tls-server-name` is required: the proxy is on localhost but the EKS
certificate is issued for the `*.gr7.ap-southeast-1.eks.amazonaws.com` name.

Note the port-forward in step 3 also needs a path to the cluster. Once you stop
using your admin kubeconfig, Vault itself has to be reached through a second
Boundary target, or exposed on an internal LoadBalancer.

---

## Teardown / restart

```bash
helm -n vault uninstall vault
kubectl delete ns vault
kubectl delete clusterrole vault-token-creator
kubectl delete clusterrolebinding vault-token-creator
```

If the `vault-0` pod restarts on its own, **everything in steps 4-5 is gone** —
in-memory storage. Re-run them. That is the main reason dev mode is demo-only;
a single-node Raft setup (`server.standalone.enabled=true` with a PVC) survives
restarts but needs manual unsealing each time.
