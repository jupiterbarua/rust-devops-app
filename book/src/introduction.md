# Introduction

This book walks through building a small Rust web service and taking it all the
way to production on AWS: tested and packaged by a CI pipeline, running on
Kubernetes, created with Terraform, and reachable through a real load balancer.

The application itself is deliberately simple. It is a REST API that stores
"items" in PostgreSQL. The interesting part is everything around it: how the
code gets tested, built, stored, deployed, secured, and observed. That is the
work most backend and DevOps roles actually involve, and it is what this book
is about.

Every chapter is based on a real project that was built step by step, including
the mistakes. Where something failed, the book shows the actual error message,
how it was diagnosed, and how it was fixed. Those troubleshooting sections are
often more useful than the happy path.

## What you will build

By the end of the book, a `git push` to the `main` branch does all of this
automatically:

```text
 git push / merge to main
          │
          ▼
 ┌──────────────────────────────┐
 │ GitHub Actions               │
 │  lint → test (real Postgres) │
 │  → dependency audit          │
 │  → build Docker image        │
 └──────────────┬───────────────┘
                │ OIDC (no stored AWS keys)
                ▼
 ┌──────────────────────────────┐
 │ Amazon ECR                   │  image tagged with the commit SHA
 └──────────────┬───────────────┘
                │ Helm upgrade
                ▼
 ┌──────────────────────────────────────────────┐
 │ VPC (Terraform)                              │
 │                                              │
 │  Public subnets          Private subnets     │
 │  ┌──────────────┐        ┌──────────────┐    │
 │  │ ALB          │        │ RDS          │    │
 │  │   │          │        │ PostgreSQL   │    │
 │  │   ▼          │        └──────▲───────┘    │
 │  │ Kubernetes   │               │            │
 │  │ pods ────────┼───────────────┘            │
 │  └──────────────┘   password from            │
 │                     Secrets Manager          │
 └──────────────────────────────────────────────┘
```

Along the way you will use:

| Area | Tools |
|---|---|
| Application | Rust, Axum, sqlx, PostgreSQL |
| Containers | Docker, multi-stage builds, distroless images |
| CI/CD | GitHub Actions, OIDC, Amazon ECR, SSM Run Command |
| Infrastructure | Terraform, S3 remote state, VPC, RDS, EC2, EKS |
| Kubernetes | k3s, Amazon EKS, kubectl, Helm |
| Networking | Traefik, AWS Load Balancer Controller, ALB |
| Security | IAM roles, least privilege, Secrets Manager, EKS Pod Identity |

## Who this book is for

You will get the most out of this book if you:

- can read Rust (or are comfortable picking it up; the application code is short),
- know basic Git and the command line,
- have an AWS account and some familiarity with the AWS console.

You do **not** need prior experience with Terraform, Kubernetes, Helm, or GitHub
Actions. Each one is introduced when it is first needed.

## How to use this book

The chapters build on each other, so read them in order the first time. Each
chapter follows the same pattern:

1. **The idea:** what problem we are solving and why.
2. **Step by step:** the commands and code, with explanations.
3. **Troubleshooting:** real errors and how to fix them.
4. **What you learned:** a short summary.
5. **Practice:** exercises to do on your own.
6. **Interview questions:** questions you should be able to answer afterwards.

Type the code yourself rather than copying it. It is slower, but you will
remember far more, and you will make (and fix) the same small mistakes that
happen in real projects.

## A word about cost

Most of this project costs nothing or very little. Some parts, however, are
billed **per hour while they exist**, even when nothing is using them:

| Resource | Rough cost | Used in |
|---|---|---|
| RDS `db.t4g.micro` | a few cents per hour | Networking and the Database |
| EC2 `t3.small` | a few cents per hour | Kubernetes on k3s |
| EKS control plane | $0.10 per hour (~$73/month) | Amazon EKS |
| Application Load Balancer | a few cents per hour | Load Balancing |

Two habits will keep your bill small:

- **Create a budget alert first.** The Terraform chapter shows how. An email at
  $10 is much better than a surprise at the end of the month.
- **Create, practise, destroy, the same day.** Everything is defined in code, so
  rebuilding takes minutes. Never leave EKS or a database running overnight.

Prices change and differ by region, so check the AWS pricing pages for your
region. The examples use `eu-central-1` (Frankfurt).

## Repository layout

The finished repository looks like this:

```text
rust-devops-app/
├── .github/workflows/   # CI/CD pipelines
├── book/                # this book (mdBook)
├── charts/rust-app/     # Helm chart
├── infra/terraform/     # all AWS infrastructure
├── k8s/                 # plain Kubernetes manifests (in-cluster Postgres)
├── migrations/          # SQL migrations
├── scripts/             # deploy script
├── src/                 # the Rust service
├── tests/               # integration tests
├── Cargo.toml
├── Dockerfile
└── docker-compose.yml
```

## Placeholders

The examples use placeholders where you need your own values:

| Placeholder | Meaning |
|---|---|
| `<ACCOUNT_ID>` | your 12-digit AWS account ID |
| `<GITHUB_USER>` | your GitHub user or organisation name |
| `<YOUR_IP>` | your public IP address (`curl -s https://checkip.amazonaws.com`) |

Never commit your real account ID, IP address, or any credentials to a public
repository. The book shows how to keep them out of Git.

Let's start with the application.
