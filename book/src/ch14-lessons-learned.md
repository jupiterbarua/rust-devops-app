# Lessons Learned and Costs

You started with a Rust function that returned `"ok"`. You end with a service
that is tested and scanned on every pull request, built into an immutable
image, pushed to a registry without a stored key, deployed automatically to
Kubernetes on infrastructure that exists only as code, reachable through a
load balancer, and watched by metrics, dashboards and alerts.

This last chapter steps back. It summarises what was built and why each choice
was made, lists what a production setup would do differently, puts numbers on
the cost, collects the mistakes that cost the most time while building this
project, and suggests where to go next.

> **Time and typing**
>
> | | |
> |---|---|
> | Reading | 40 min |
> | Hands-on | none |
> | Practice | 60 to 90 min, mostly writing |
> | Cost | nothing, if you destroyed everything at the end of the last chapter. Check: **EC2**, **EKS**, **RDS** and **Load Balancers** in the console should all be empty |
>
> **Type yourself:** the answers to the practice exercises. They are the
> material for the interview question you will hear most: "Tell me about a
> project you built."

## What you built

```text
 developer ── pull request ──▶ GitHub
                                 │ required checks: fmt, clippy, cargo-deny, tests (real Postgres), image build
                                 ▼ merge to main
                           GitHub Actions ──OIDC──▶ AWS (no stored keys)
                                 │                     │
                     push image :<sha> ──▶ ECR (immutable tags, promoted to versions)
                                 │
                     SSM Run Command ──▶ k3s server ── deploy.sh ── helm upgrade --wait
                                                        │
 VPC (2 AZs) ───────────────────────────────────────────┼──────────────────────────────
   public subnets:  k3s server (Traefik) · EKS nodes · ALBs (AWS Load Balancer Controller)
   private subnets: RDS PostgreSQL (password in Secrets Manager)
   monitoring:      Prometheus · Grafana (dashboards as code) · Alertmanager (rules as code)
 everything above:  Terraform, S3 remote state with locking, budget alert
```

And around it, a habit: every piece is written down, in code or in this book,
so it can be rebuilt in minutes and explained to someone else.

## The decisions, and what they trade

Every design choice in this project traded something. Being able to say
**what** you chose, **why**, and **what it costs** is what separates "I
followed a tutorial" from "I designed this".

| Decision | Why | Trade-off |
|---|---|---|
| GitHub OIDC instead of access keys (Ch. 4) | no long-lived secret to leak or rotate | the trust policy must be exact; the `sub` format can change (it did) |
| Immutable image tags by commit SHA (Ch. 4) | every running container maps to one commit; no silent overwrites | untagged layers and old images pile up without a lifecycle policy |
| Actions pinned to commit SHAs (Ch. 3) | a compromised tag cannot change your pipeline | updates need Dependabot or Renovate |
| Terraform with S3 state and locking (Ch. 5) | reviewable, repeatable infrastructure; safe for more than one person | state is now critical data; `-target` shortcuts can let code and state drift |
| No NAT gateway, servers in public subnets (Ch. 6) | saves about $35 per month per AZ | nodes have public IPs; security groups are the only barrier |
| RDS with a managed password (Ch. 6) | the password is never in code, state or a terminal | the password changes on recreation and rotation; the app must reread it |
| k3s on one EC2 instance (Ch. 7) | cheap, fast, every part visible | a single point of failure; you upgrade Kubernetes yourself |
| Helm chart with an external Secret (Ch. 8, 9) | one chart for every environment; the password stays out of Helm's history | the checksum trick is needed to restart pods on change |
| Push deployment through SSM (Ch. 9) | no SSH, no open ports, no stored credentials | the pipeline can run commands as root on the server; branch protection becomes security |
| EKS with access entries and Pod Identity (Ch. 10, 11) | managed control plane, IAM-based access, one role per pod | $73 per month before any node; more AWS-specific pieces |
| ALB per Ingress with IP targets (Ch. 11) | direct pod health checks, clean rolling updates | one ALB per Ingress adds up; controller-created resources must be cleaned up first |
| kube-prometheus-stack without storage (Ch. 12) | the full standard stack in one command | metrics are lost when Prometheus restarts |
| Rules and dashboards in the app's chart (Ch. 12, 13) | monitoring is reviewed and deployed with the code it watches | dashboards edited in Grafana must be exported back into Git |

## What production would do differently

This project is deliberately small and cheap. A company running real users'
data would change these things, roughly in this order of importance:

**Accounts and access**
- **Separate AWS accounts** per environment (development, staging,
  production), created with AWS Organizations or Control Tower, so a mistake in
  one cannot touch the others.
- **SSO for people** (IAM Identity Center) instead of IAM users, and no one using
  the root user.

**Network**
- **Nodes and servers in private subnets**, with NAT gateways or **VPC
  endpoints** for ECR, S3 and the AWS APIs. Only load balancers are public.
- **HTTPS everywhere**: a domain in Route 53, certificates from AWS Certificate
  Manager on the ALB, HTTP redirected to HTTPS, and often AWS WAF in front.

**Data**
- **RDS Multi-AZ**, automated backups for 7 to 35 days, deletion protection, and
  a final snapshot: the opposite of every practice setting in Chapter 6.
- **Restores tested regularly**. A backup nobody has restored is a hope, not a
  backup.

**Delivery**
- **Terraform in CI**: `plan` on every pull request, posted for review; `apply`
  after merge, by a pipeline role, not from laptops. Code split into
  **modules**, state split per environment.
- **Policy checks** on infrastructure code (Checkov, OPA/Conftest) and on
  Kubernetes objects (Kyverno), so "no public RDS" is enforced, not hoped.
- **GitOps** (Argo CD or Flux) instead of pushing from the pipeline, and
  **progressive delivery** (canary releases with Argo Rollouts) for risky
  changes.
- **Image scanning** (Trivy, Amazon Inspector) and SBOMs in the pipeline, and
  **Renovate** for dependency updates across all ecosystems.

**Kubernetes**
- **At least two nodes in two AZs**, a **PodDisruptionBudget**, and
  **autoscaling**: the Horizontal Pod Autoscaler for pods, Karpenter or Cluster
  Autoscaler for nodes.
- **Secrets from AWS** through the External Secrets Operator or the Secrets
  Store CSI driver, instead of a script that copies them.
- Regular **Kubernetes version upgrades**: EKS versions leave standard support
  after about 14 months.

**Observability**
- **Persistent metrics**: a volume for Prometheus, or a managed service such as
  Amazon Managed Service for Prometheus and Managed Grafana.
- **Central logs** (Loki, CloudWatch Logs or OpenSearch) and **traces**
  (OpenTelemetry), so you can follow one request through all services.
- **SLOs and burn-rate alerts** instead of fixed thresholds, **runbooks** for
  every alert, and an on-call rotation with a real paging tool.

None of these is hard after this book. Each one is a project of a few days,
built on exactly the ideas you have practised: code, review, least privilege,
and automation.

## What it costs

Prices change and differ between regions. The figures below are approximate
on-demand prices for `eu-central-1` (Frankfurt) in late 2026, rounded. Check the
AWS pricing pages before you rely on them, and remember that new accounts may
have free-tier credits that cover some of it.

| Resource | Per hour | Per month (730 h) if left running | Used in |
|---|---|---|---|
| ECR storage (a few images, ~1 GB) | – | about $0.10 | Ch. 4 onwards |
| S3 state bucket | – | a few cents | Ch. 5 onwards |
| Secrets Manager (per secret) | – | about $0.40 | Ch. 6 onwards |
| RDS `db.t4g.micro` + 20 GB gp3 | about $0.02 | about $15 | Ch. 6 onwards |
| EC2 `t3.small` (k3s) | about $0.025 | about $18 | Ch. 7 |
| EC2 `m7i-flex.large` (k3s with monitoring, or an EKS node) | about $0.11 | about $80 | Ch. 10 onwards |
| Public IPv4 address (per address) | $0.005 | about $3.60 | every instance |
| EKS control plane | $0.10 | about $73 | Ch. 10, 11 |
| Application Load Balancer (each, plus a small usage charge) | about $0.03 | about $20 | Ch. 11, 12 |
| NAT gateway (avoided in this design) | about $0.05 | about $35 + data | not used |

**What a session costs.** A four-hour session with the k3s server
(`m7i-flex.large`) and RDS costs about 50 cents. A four-hour EKS session with
the k3s admin host, one node, RDS and four ALBs (application plus monitoring)
costs about $2. Each internet-facing ALB also holds a public IPv4 address per
Availability Zone, so ten or so public addresses add up to about 5 cents per
hour on their own.

**What forgetting costs.** The same EKS setup left running for a month costs
about $370. That is the single biggest financial risk in this book, and why
every chapter ends with a cleanup step.

The habits that kept this project cheap:

- **A budget alert first** (Chapter 5). It is free, and an email at $10 is
  better than a surprise at $370.
- **Create, practise, destroy, the same day.** Everything is code, so rebuilding
  takes minutes. Keep only what is free or nearly free: VPC, IAM, ECR, S3.
- **`-target` for the expensive parts** (RDS, the server, the cluster), and the
  network stays.
- **Controllers clean up what they created**: uninstall Helm releases with
  Ingresses before destroying a cluster (Chapter 11, Step 8).
- **Tags on everything.** `default_tags` (Chapter 5) puts `Project =
  rust-devops` on every resource Terraform creates. Activate it as a **cost
  allocation tag** in the Billing console, and Cost Explorer can show exactly
  what this project costs, separated from everything else in the account.

## The mistakes that cost the most time

Every chapter's Troubleshooting section is real. Looking across all of them,
the same few patterns caused most of the lost hours. Recognising them is more
valuable than remembering any single fix.

1. **Placeholders that reached real systems.** `<ACCOUNT_ID>` in an image name
   (`ImagePullBackOff`), `YOUR.IP/32` in an ALB annotation (load balancers that
   never worked). Validate inputs in scripts, as `install-monitoring.sh` does
   with its CIDR check, and fail early.
2. **The wrong context.** `kubectl` talking to k3s when you meant EKS, a
   kubeconfig that was not set in a new shell (`localhost:8080`), AWS commands
   in the wrong region (an empty secret in `eu-central-1` while the server read
   `us-east-1`), the IP of the server instead of the laptop. Before every
   change, check **where** you are: `kubectl config current-context`,
   `aws sts get-caller-identity`, the region.
3. **Environments that are not your terminal.** SSM runs commands without a
   login shell: no `PATH` to `/snap/bin`, no `KUBECONFIG`, and in one case an
   `aws` command whose output, redirected into a file, arrived empty while
   reporting success. A command that works by hand proves little about how it
   runs under automation. Test it **in the same environment** (Chapter 9's SSM
   debugging did exactly this).
4. **Things that changed underneath you.** GitHub's OIDC `sub` format for new
   repositories, a Node 20 deprecation in a pinned action, new security
   advisories in dependencies that turned CI red without a code change. Systems
   you depend on move. Pinning keeps you stable; Dependabot and scheduled checks
   tell you when to move.
5. **Order and dependencies.** An access policy association created before its
   access entry, a cluster destroyed before its load balancers, a chart rendered
   before the CRDs it checks for existed. When something fails with "not found"
   or "dependency", ask what had to exist first.
6. **Edits in the wrong place.** Files changed on the server, then a `git pull`
   that refused to merge. The rule that fixes it: change code in one place, Git,
   and let servers only pull.
7. **Silent defaults.** Prometheus ignoring a ServiceMonitor because of a
   selector default, Alertmanager sending alerts to a receiver called `'null'`,
   Helm `--wait` missing and a broken deployment reported as `deployed`. When
   nothing happens and nothing complains, look for a default.

What helped every time was the same method: **find the layer that fails, prove
each layer below it works, one test at a time.** For the private-repository
deploy in Chapter 9, that meant: can the server read the secret (yes, 419
bytes), is it a valid key (yes), does GitHub accept it (yes), so the problem
must be in how the pipeline writes it. Guessing would have taken all night.

## Where to go next

The project is a platform to grow on. These extensions follow naturally, each
building on what exists, and each a good story for an interview:

**Infrastructure as code, done like a team**
1. On/off switches: variables such as `enable_eks` and `enable_rds` with
   `count`, so one `terraform apply -var enable_eks=true` builds a session's
   setup, and `moved` blocks to restructure without destroying.
2. Modules for the network, the database and the cluster, and separate state
   per environment.
3. Terraform in GitHub Actions: `plan` on pull requests with a read-only role,
   `apply` on merge with a separate role, and Checkov in the same pipeline.

**Delivery**
4. Merge queues and `--atomic` (or `--rollback-on-failure`) deployments,
   automatic rollback, and DORA metrics (deployment frequency, lead time, change
   failure rate, time to restore) collected from the pipeline.
5. GitOps with Argo CD, and canary releases with Argo Rollouts driven by the
   Prometheus metrics you already have.

**Reliability**
6. An SLO for the service with burn-rate alerts, runbooks, alerts delivered to
   a real channel, and a written postmortem of one of your drills.
7. Logs with Loki and traces with OpenTelemetry, so the dashboard links from a
   slow request to its trace.

**Security and cost**
8. Renovate, Trivy image scanning with an SBOM, and Kyverno policies that
   reject containers running as root.
9. Cost visibility per namespace with OpenCost, and a monthly cost report.

**Certifications** turn this experience into a line recruiters search for. The
**CKA** (Certified Kubernetes Administrator) is hands-on and tests exactly the
`kubectl` skills from Chapters 7 to 11. The **AWS Solutions Architect –
Associate** covers the AWS side of Chapters 4 to 6 and 10 to 11.

## Practice

Each exercise says how long it takes and how much you type. All of them are
writing, and all of them prepare you for interviews.

1. **The two-minute walkthrough** (20 min). Write, then say out loud, a
   two-minute description of this project: what it does, the delivery path from
   commit to production, and two decisions you made and why. Time yourself.
2. **An architecture decision record** (20 min). Pick one decision from the
   table above, and write an ADR: context, decision, alternatives considered,
   consequences. One page. Add it to `docs/adr/` in the repository.
3. **Your real costs** (15 min). Activate the `Project` cost allocation tag (it
   takes up to a day to appear), open Cost Explorer, and find what this project
   cost you per month. Compare it with the table above.
4. **Your hardest problem** (20 min). Write the story of the most difficult
   problem you solved in this project, in four parts: the symptom, what you
   checked, what the cause was, what you changed so it cannot happen again.
   Interviewers ask for exactly this.
5. **Plan your next step** (15 min). Pick one extension from "Where to go next".
   Write down what you will build, how you will know it works, and what you
   expect to be hard. Then build it.

## Interview questions

These are the questions this whole project prepares you for.

- Walk me through your project. What happens between a commit and a running
  container?
- Why did you choose k3s and EKS? When would you choose ECS Fargate instead?
- How do your pipeline, your servers and your pods authenticate to AWS? Where
  are there long-lived secrets, if anywhere?
- What would you change before putting real customer data on this platform?
- What does your setup cost per month, and how do you keep it down?
- How do you know the service is healthy? What would wake you up at night, and
  what would not?
- Tell me about the hardest problem you solved in this project.
- What would you do differently if you started again?
