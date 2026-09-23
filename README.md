<p align="center">
  <a href="https://kst-devops.com"><img src="docs/banner.svg" alt="Zero-Trust Kubernetes Access — Okta · HCP Boundary · Vault · Amazon EKS — kst-devops.com" width="100%"></a>
</p>

<h1 align="center">Zero-Trust Kubernetes Access</h1>

<p align="center">
  Identity-driven, short-lived, RBAC-scoped access to a <b>private</b> Kubernetes API —<br>
  no kubeconfig distributed, no long-lived credential anywhere, no inbound network path from the internet.
</p>

<p align="center">
  <img alt="Terraform" src="https://img.shields.io/badge/Terraform-1.9-7B42BC?logo=terraform&logoColor=white">
  <img alt="Amazon EKS" src="https://img.shields.io/badge/Amazon_EKS-1.35-FF9900?logo=kubernetes&logoColor=white">
  <img alt="HashiCorp Vault" src="https://img.shields.io/badge/Vault-k8s_secrets_engine-FFD814?logo=vault&logoColor=black">
  <img alt="HCP Boundary" src="https://img.shields.io/badge/HCP_Boundary-PAM-F24C53?logo=boundary&logoColor=white">
  <img alt="Okta" src="https://img.shields.io/badge/Okta-OIDC-007DC1?logo=okta&logoColor=white">
  <img alt="Datadog" src="https://img.shields.io/badge/Datadog-monitors-632CA6?logo=datadog&logoColor=white">
  <img alt="Packer" src="https://img.shields.io/badge/Packer-AMI-02A8EF?logo=packer&logoColor=white">
  <img alt="Ansible" src="https://img.shields.io/badge/Ansible-role-EE0000?logo=ansible&logoColor=white">
  <img alt="GitHub Actions" src="https://img.shields.io/badge/GitHub_Actions-OIDC-2088FF?logo=githubactions&logoColor=white">
</p>

<p align="center">
  <a href="https://github.com/rosaliei/boundary-eks-vault-okta/actions/workflows/infra.yml"><img alt="infra" src="https://github.com/rosaliei/boundary-eks-vault-okta/actions/workflows/infra.yml/badge.svg"></a>
  <a href="https://github.com/rosaliei/boundary-eks-vault-okta/actions/workflows/ami-build.yml"><img alt="ami-build" src="https://github.com/rosaliei/boundary-eks-vault-okta/actions/workflows/ami-build.yml/badge.svg"></a>
  <a href="https://github.com/rosaliei/boundary-eks-vault-okta/actions/workflows/scale.yml"><img alt="scale-workers" src="https://github.com/rosaliei/boundary-eks-vault-okta/actions/workflows/scale.yml/badge.svg"></a>
  <a href="https://github.com/rosaliei/boundary-eks-vault-okta/actions/workflows/rotate-broker-creds.yml"><img alt="rotate-broker-creds" src="https://github.com/rosaliei/boundary-eks-vault-okta/actions/workflows/rotate-broker-creds.yml/badge.svg"></a>
</p>

<p align="center">
  <a href="#start-here--the-five-scenes"><img alt="Diagrams hand-drawn in Excalidraw" src="https://img.shields.io/badge/diagrams-hand--drawn_in_Excalidraw-6965DB?logo=excalidraw&logoColor=white"></a>
  <a href="https://kst-devops.com"><img alt="kst-devops.com" src="https://img.shields.io/badge/kst--devops.com-visit-4FC47E?logo=googlechrome&logoColor=white"></a>
</p>

---


A private EKS cluster that nobody has credentials for. Access is granted by
**Okta group membership**, brokered as a **15-minute Kubernetes token**, and
proxied through a **self-scaling pool of Boundary workers** — with no kubeconfig
on any laptop, no VPN, and no standing permission anywhere.

**Built by hand first, in the console, until I could draw it from memory — then
automated.** The drawings in this README are mine, made while learning it. The
[20 documented failures](notes/Issues.md) are the real ones, measured on a live build.

> **Amazon EKS** · **HashiCorp Vault** (Kubernetes secrets engine, AWS IAM auth)
> · **HCP Boundary** (PAM, session brokering) · **Okta** (OIDC federation) ·
> **Terraform** · **Packer + Ansible** · **Datadog** (custom metrics, monitors)
> · **GitHub Actions** (OIDC to AWS, no static keys)
>
> Runs at roughly **$0.31/hour** in `ap-southeast-1` — over half of which is the
> EKS control plane and the NAT gateway, before a single worker exists. The pool
> scales **1 → 6** on live session count, with zero human steps.

---

## Where to start

| | |
|---|---|
| **[Build by hand](01-Build-By-Hand.md)** | Build the platform by hand, console by console. Do this first. |
| **[Build with Terraform](02-Build-With-Terraform.md)** | The same thing in Terraform. |
| **[autoscaling/](autoscaling/)** | A worker pool that grows and shrinks on its own. Built on top. |
| **[Integrations](03-Integrations.md)** | Every trust relationship on one page: who proves what to whom, and how each one fails. |
| **[notes/Issues.md](notes/Issues.md)** | My build log — 20 findings, each measured on a live system, indexed by component. |

This page is the **architecture** — what the system is and why each decision
went the way it did. No build steps.

---
## 1. The problem

Teams that run Kubernetes on a private endpoint usually solve access with one of
three things: a VPN, a bastion host, or a kubeconfig file handed to every
engineer. Each one ends the same way — a long-lived credential on a laptop, an
inbound door in the network, and no reliable answer to *who did what, and were
they still allowed to at the time?*

The requirements here were stricter:

| Requirement | Meaning in practice |
|---|---|
| **Identity is the perimeter** | access is granted to a person in an Okta group, never to a file or an IP |
| **Credentials expire by default** | every Kubernetes token lives 15 minutes and is minted per session |
| **Least privilege is enforced, not requested** | the tier you get (viewer / operator / admin) is decided by your group — you cannot ask for more |
| **No inbound surface** | the EKS endpoint stays private; nothing in the VPC accepts a connection from outside |
| **Auditable** | every session is authorized by a control plane and recorded, with the identity attached |
| **Elastic** | access capacity grows and shrinks with demand, with zero human steps |

## 2. The solution

Each capability is delivered by a purpose-built technology, chosen for the job
it does rather than the tool it is:

| Capability | Technology | Role in this design |
|---|---|---|
| Identity provider (IdP) | **Okta** | authenticates the human; issues an ID token carrying the `groups` claim that drives every downstream decision |
| Privileged Access Management (PAM) | **HCP Boundary** | the policy enforcement point: maps Okta groups → roles → targets, authorizes each session, brokers the credential, proxies the connection through a worker inside the VPC |
| Secrets management & dynamic credentials | **HashiCorp Vault** (Kubernetes secrets engine) | mints a 15-minute ServiceAccount token per session, bound to a named RBAC tier; Boundary fetches it so the user never touches Vault |
| Workload platform | **Amazon EKS** (private endpoint, access-entries auth) | the protected system; Kubernetes RBAC bounds what each tier may do |
| Network isolation | **AWS VPC**, private subnets, NAT-only egress | the EKS API is never exposed; the hand-built worker dials *out* to Boundary. The autoscaled pool accepts 9202 from a short IP allowlist — [deliberately, and only that port](autoscaling/README.md) |
| Infrastructure as code | **Terraform** | one root per layer: `aws/`, `vault/`, `boundary/`, `autoscaling/` |
| Image build & configuration | **Packer + Ansible** | immutable worker AMI; instance-specific facts arrive at boot |
| Observability & scaling signal | **Datadog** | active-session metric, monitors, dashboard; the source of truth for scale decisions |
| Delivery & automation | **GitHub Actions** (OIDC to AWS, no static keys) | AMI builds, infrastructure apply, scale actuation, credential rotation |

## 3. Outcomes

- **Zero standing access.** No kubeconfig on any laptop. The only long-lived
  identity in the chain is the person's Okta account.
- **One command, one session, one credential.** `boundary connect` opens the
  tunnel *and* returns the 15-minute token for the caller's tier.
- **Tiering is structural.** One Boundary target per tier, one Vault credential
  library per target, one Kubernetes RBAC Role per ServiceAccount. A viewer
  cannot be handed an admin token because no path exists for it.
- **Private stays private.** The EKS API is never exposed; the Boundary worker
  holds a reverse tunnel out to the control plane.
- **Elastic access layer.** Workers on an Auto Scaling Group register and
  deregister themselves, driven by Datadog session counts through GitHub
  Actions. That is a **separate layer built on top of this one** and has its own
  three documents — start at [`autoscaling/README.md`](autoscaling/README.md).

## 4. Architecture

![End-to-end access flow: Okta to Boundary to Vault to a private EKS API](docs/e2e-flow.svg)

### Every integration on one page

![Integration map: the exact mechanism joining Okta, Boundary, Vault, EKS, AWS, Datadog and GitHub Actions](docs/integration-map.svg)

Ten system-to-system integrations, each labelled with the exact call that carries
it — `vault login -method=aws`, `sts:AssumeRoleWithWebIdentity`, the TokenRequest
API. Not one of them stores a password for the next. Detail and failure modes in
[Integrations](03-Integrations.md).

### The two tokens

Almost every confusion in this stack comes from conflating them:

| | Okta ID token | Kubernetes ServiceAccount token |
|---|---|---|
| Issued by | Okta | The EKS API server (via Vault) |
| `iss` | `https://<org>.okta.com` | `https://oidc.eks.<region>.amazonaws.com/id/<id>` |
| `sub` | your Okta user id | `system:serviceaccount:demo-app:vault-viewer` |
| Proves identity to | **Boundary** | **Kubernetes** |
| Lifetime | Okta session | 15 minutes |

Boundary decides *whether you may reach the cluster's API port*.
Kubernetes RBAC decides *what you may do once you are there*.
They are independent — a Boundary admin holding a viewer SA token still cannot
write to the cluster.

### Traffic flow

![Traffic flow: which host talks to which, on what port, and which side opens the connection](docs/traffic-flow.svg)

The property that makes this work: **the EKS API is never exposed.** Its
endpoint is private-only. The single hand-built worker has no public IP and no
inbound rule — it dials *out* to HCP on 9202 through the NAT gateway and holds
that tunnel open, and HCP pushes session bytes back down it. A private API is
reachable with no VPN, no bastion and nothing listening on the internet.

> **The autoscaled workers differ, deliberately.** They sit in public subnets
> and accept 9202 from a small list of client IPs. Boundary only instruments
> sessions where the client reaches the worker *directly*; over the dial-out
> path the worker reports zero sessions forever, so there is nothing to scale
> on. The EKS API stays private either way — only the worker's proxy port is
> reachable, and only from listed addresses. Reasoning in
> [autoscaling/README.md](autoscaling/README.md).

TLS is end to end between kubectl and the EKS API — every hop in between relays
ciphertext it cannot read. Hence `--tls-server-name` and the cluster CA on the
kubectl command: you dial `127.0.0.1`, but you validate the EKS certificate.

Build order matters: **EKS → Kubernetes RBAC → Vault → worker → Okta → Boundary**.
Each layer references names created by the one before it.

### The access layer scales itself

Everything above works with a **single** worker, and that worker is a
bottleneck and a single point of failure. The last layer replaces it with a
pool that sizes itself to demand.

![Scaling loop: workers report open sessions to Datadog, monitors fire above 10 or below 3 average sessions per worker, a GitHub Actions workflow assumes an AWS role by OIDC and moves the ASG desired capacity by one, and the pool re-registers itself](docs/scaling-loop.svg)

Three decisions shape it:

- **Sessions are the signal, not CPU.** A proxy is busy when people are
  connected through it; its CPU barely moves either way.
- **Datadog decides, GitHub acts.** Datadog holds the metric but cannot change
  an ASG, so it calls a workflow that can. One place to look when nothing
  scales: the workflow run.
- **A worker deregisters itself before it dies.** An ASG lifecycle hook pauses
  termination while the worker finishes its sessions and deletes its own record
  from Boundary — and fails open, so a broken script can never wedge the pool.

It is a separate build with its own three documents. Start at
**[autoscaling/README.md](autoscaling/README.md)** for the reasoning, including
the one decision that surprises people — the pooled workers are deliberately
reachable from the internet on their proxy port, because Boundary only
instruments sessions that reach a worker directly.

---

## Start here — the five scenes

AI can generate every file in this repository in minutes. What it cannot do is
understand the system for me — and understanding is the thing an operator is
actually paid for at 3 a.m. So I built this the slow way first: **every layer by
hand in the console and the UI (ClickOps), until I could draw it from memory,
and only then automated it.** Every picture below is my own work, drawn in
Excalidraw as I went. The code is the *output* of that understanding, not a
substitute for it.

**Scenes 1–5 are the foundation. They build on each other — do them in order.**
For every scene: **Manual** is what you do by hand to understand it;
**Automation** is the code in this repo that does the same thing once you do.

| # | Scene (open the drawing) | What it settles | Manual | Automation |
|---|---|---|---|---|
| **1** | [VPC & subnets — analysis → ClickOps](https://app.excalidraw.com/s/9hD7S5FgGWN/73UzMQca6Am) | one VPC, 3 AZs, public + private subnets, NAT, the subnet tags EKS and the NLB discover | AWS console, exactly as drawn: VPC → subnets → NAT → route tables → tags `kubernetes.io/role/elb` / `internal-elb` | [`aws/vpc.tf`](aws/vpc.tf) — `terraform-aws-modules/vpc` |
| **2** | [EKS — detailed analysis](https://app.excalidraw.com/s/9hD7S5FgGWN/2XoNL6sXrLz) | private endpoint, access-entries auth, node group, the RBAC tiers (SA → RoleBinding → Role) | console: create cluster (private only), node group, access entry for your IAM user; then `kubectl apply -f k8s/rbac.yaml` — [Step 1](01-Build-By-Hand.md#step-1--eks-cluster), [Step 2](01-Build-By-Hand.md#step-2--kubernetes-rbac) | [`aws/eks.tf`](aws/eks.tf), [`k8s/rbac.yaml`](k8s/rbac.yaml) |
| **3** | [Boundary ↔ Okta identity](https://app.excalidraw.com/s/9hD7S5FgGWN/7rGrKHxR5PL) | Okta app + groups claim → OIDC auth method → managed groups → roles → grants | Okta admin + Boundary UI — [Step 5](01-Build-By-Hand.md#step-5--okta), [Step 6](01-Build-By-Hand.md#step-6--boundary), [`boundary/MANUAL-SETUP.md`](boundary/MANUAL-SETUP.md) | [`boundary/main.tf`](boundary/main.tf) (managed groups, roles, host catalog, targets) |
| **4** | [Boundary → Okta → Vault → EKS RBAC](https://app.excalidraw.com/s/9hD7S5FgGWN/2didKmVk95t) | the whole runtime path: worker in the VPC, Vault k8s secrets engine, credential brokering, one target per tier, the numbered 1–8 flow | [Step 3](01-Build-By-Hand.md#step-3--vault), [Step 4](01-Build-By-Hand.md#step-4--boundary-worker), [Step 7](01-Build-By-Hand.md#step-7--vault-credential-brokering), [Step 8](01-Build-By-Hand.md#step-8--end-to-end), [`vault/MANUAL-SETUP.md`](vault/MANUAL-SETUP.md) | [`aws/boundary-worker.tf`](aws/boundary-worker.tf), [`vault/main.tf`](vault/main.tf), [`boundary/credentials.tf`](boundary/credentials.tf) |
| **5** | [Issues — what broke and why](https://app.excalidraw.com/s/9hD7S5FgGWN/9x6Q0ZNzt0P) | the failures from the real build, their causes, the checklist, and why the autoscaling design looks the way it does | run the checklist, then [`autoscaling/01-Build-By-Hand.md`](autoscaling/01-Build-By-Hand.md) parts A–G | [`autoscaling/02-Build-With-Terraform.md`](autoscaling/02-Build-With-Terraform.md) |

Rule of thumb for each scene: **do the Manual column once, watch it work, then
apply the Automation column and confirm it produces the same objects.** If the
two differ, the drawing is the truth and the code has drifted.

---

# Lessons learned

None of this worked the first time, and the failures are the most valuable part
of the record. They are kept in two places rather than here:

- **The drawing:** [Issues — what broke and why](https://app.excalidraw.com/s/9hD7S5FgGWN/9x6Q0ZNzt0P)
  — twelve failures on one board, each with *seen / cause / fix*, the pre-change
  checklist, and the line from each failure to the design decision it forced.
- **The written log:** [notes/Issues.md](notes/Issues.md) — the full narrative:
  the 24-hour token cap on EKS, the privilege-escalation path in an unscoped
  TokenRequest grant, six attempts at one Okta claim, the GPG-key mismatch,
  the state of the environment before autoscaling, and a symptom → cause
  troubleshooting table.

# Security posture and roadmap

Known-weak by design in this build, and what changes for production:

- **Vault dev mode** — in-memory storage (a pod restart wipes every mount, role
  and policy), auto-unsealed, root token `root`, and plaintext HTTP across the
  VPC via the internal NLB.
- **Worker port 9202 is open to a few allowed IPs, on purpose.** Autoscaling
  counts sessions that connect straight to a worker. If clients cannot reach a
  worker directly, that count stays at zero and nothing scales. The security
  group is the only thing guarding that port. Reasoning in
  [autoscaling/README.md](autoscaling/README.md).
- **The allowed-IP list fails silently.** If your IP changes, sessions still
  work — they just take another route — but the count drops to zero. It looks
  like the autoscaling broke, when in fact only your address changed.

## Roadmap

- **Session recording (BSR)** on the targets — full keystroke audit, which is
  usually the thing that makes a PAM story complete for auditors.
- **Spot instances for the worker pool** — the lifecycle hook and self-registration
  already handle abrupt termination, so most of the work is done.
- **Drop `secrets` from the viewer Role** — the most restricted tier can currently
  read every Secret in `demo-app`.
- **A self-hosted runner in the VPC** — unblocks both `rotate-broker-creds.yml`
  and `infra.yml` without exposing Vault publicly.
- **AMI hygiene** — nothing deregisters superseded images or deletes their
  snapshots; five were built in a single day of iteration.
- **Terraform-manage the lifecycle hook.** It is declared as
  `initial_lifecycle_hook`, which AWS honours only at ASG creation — later edits
  do nothing and `plan` shows no drift. `aws_autoscaling_lifecycle_hook` is the
  resource that actually manages updates.

---

<p align="center">
  <sub>Designed, built by hand, drawn, then automated by <b>Kyaw Sithu</b> ·
  <a href="https://kst-devops.com">kst-devops.com</a> ·
  <a href="https://github.com/rosaliei">@rosaliei</a></sub>
</p>
