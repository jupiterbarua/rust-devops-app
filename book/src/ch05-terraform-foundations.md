# Terraform Foundations

Everything in AWS so far was created by hand with the AWS CLI: an ECR
repository, an OIDC provider, an IAM role and two policies. That worked, but it
has the usual problems of manual work. Nobody can see what exists without
clicking through the console, nothing records why a setting was chosen, and
rebuilding it after a mistake means remembering every command.

**Infrastructure as code** fixes this: you describe the infrastructure in files,
keep them in Git next to the application, and let a tool make reality match the
files. This book uses **Terraform**. In this chapter, you take over the
resources from the previous chapter, move Terraform's memory into S3, learn how
to keep account-specific values out of a public repository, and create your
first new resource: a budget alert.

> **Time and typing**
>
> | | |
> |---|---|
> | Reading | 40 min |
> | Hands-on | 90 min |
> | Practice | 1–1.5 h |
> | Cost | free (a budget alert costs nothing) |
>
> **Copy:** `iam.tf` and `budget.tf`.
> **Type yourself:** `versions.tf`, `backend.tf` and the `import` blocks (about 30 lines). They are the parts you write at the start of every Terraform project.

## The idea

Terraform works in a loop that you will repeat hundreds of times:

```text
 edit .tf files ──▶ terraform plan ──▶ read the plan ──▶ terraform apply
       ▲                                                        │
       └────────────────────────────────────────────────────────┘
```

- **Code** (`.tf` files) describes the **desired state**: "there should be an ECR
  repository named `rust-devops-app` with immutable tags".
- **State** (`terraform.tfstate`) is Terraform's **memory**: which real AWS
  resource belongs to which block in your code.
- **`plan`** compares code, state and reality, and shows what it would change,
  without changing anything.
- **`apply`** makes the changes, then updates the state.

The plan uses a few symbols you must learn to read at a glance:

| Symbol | Meaning |
|---|---|
| `+` | will be created |
| `~` | will be updated in place |
| `-` | will be destroyed |
| `-/+` | must be **replaced**: destroyed and created again |
| `<=` | will be read (a data source) |

`-/+` deserves the most attention. For an ECR repository, a replacement deletes
every image in it. Always read the plan before typing `yes`.

## Step 1: Install Terraform

On macOS with Homebrew:

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
terraform version
```

On other systems, use the official install page. This chapter needs version
1.10 or newer for S3 state locking without DynamoDB.

## Step 2: The project layout

All infrastructure lives in its own folder:

```text
infra/terraform/
├── versions.tf               # Terraform and provider versions, provider config
├── backend.tf                # where state is stored
├── variables.tf              # input values the code needs
├── terraform.tfvars          # your real values (git-ignored)
├── terraform.tfvars.example  # placeholders (committed)
├── ecr.tf                    # container registry
├── iam.tf                    # OIDC provider and CI role
└── budget.tf                 # cost alert
```

Terraform reads **every `.tf` file in the folder** as one configuration. The file
names are for humans; splitting by topic keeps each file small.

Create `infra/terraform/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "eu-central-1"

  default_tags {
    tags = {
      Project   = "rust-devops"
      ManagedBy = "terraform"
    }
  }
}
```

- A **provider** is the plugin that talks to a platform's API, here AWS.
- `~> 6.0` allows any 6.x version but not 7.0, so a future major version cannot
  change behaviour without you deciding to upgrade.
- **`default_tags`** puts these tags on every resource this provider creates.
  Later, you can filter costs and resources by `Project = rust-devops`.

## Step 3: Take over the existing ECR repository

The repository already exists, so Terraform must not create a second one. Instead,
you write code that describes the existing repository exactly, and an **import
block** that tells Terraform "this resource is already there; adopt it".

Create `infra/terraform/ecr.tf`:

```hcl
resource "aws_ecr_repository" "app" {
  name                 = "rust-devops-app"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

import {
  to = aws_ecr_repository.app
  id = "rust-devops-app"
}
```

The first line reads like this:

```text
resource  "aws_ecr_repository"  "app"
            └─ resource type      └─ your name for it inside Terraform
```

Together, `aws_ecr_repository.app` is the resource's **address**. AWS never sees
the name `app`; it only exists in your code and state.

For now, comment out `backend.tf` (or do not create it yet) and initialise:

```bash
cd infra/terraform
terraform init
terraform plan
```

`init` downloads the AWS provider into a hidden `.terraform` folder and writes
`.terraform.lock.hcl`, which pins the exact provider version. The plan should end
with:

```text
Plan: 1 to import, 0 to add, 0 to change, 0 to destroy.
```

That is exactly what you want. If you see `to change` or `to destroy`, your code
does not match the real repository yet; compare the settings before applying.

```bash
terraform apply
terraform plan
```

The second plan should say **"No changes. Your infrastructure matches the
configuration."** That sentence is the goal after every apply.

**An experiment:** change `scan_on_push = true` to `false` and run
`terraform plan`. Terraform shows `~ update in-place` with exactly one changed
setting. Do not apply; change it back and plan again.

## Step 4: Keep Terraform's files out of Git

Add to the `.gitignore` in your repository root:

```text
# Terraform
.terraform/
*.tfstate
*.tfstate.backup
terraform.tfvars
```

- **`.terraform/`** holds downloaded providers; `init` recreates it.
- **`*.tfstate`** can contain sensitive values in plain text. Never commit state.
- **`terraform.tfvars`** holds your personal values (next step).
- **Do commit `.terraform.lock.hcl`**, so everyone uses the same provider build.

## Step 5: Variables, and what belongs in a public repository

The IAM resources need your GitHub owner and repository IDs, and the budget needs
an email address. None of these should be hardcoded in a public repository.

Terraform separates **declaring** a value from **providing** it, like function
parameters and arguments. Create `infra/terraform/variables.tf`:

```hcl
variable "github_owner" {
  type        = string
  description = "GitHub user or organisation that owns the repository"
}

variable "github_repo" {
  type        = string
  description = "GitHub repository name"
  default     = "rust-devops-app"
}

variable "github_owner_id" {
  type        = string
  description = "Numeric GitHub owner ID (https://api.github.com/users/<owner>)"
}

variable "github_repo_id" {
  type        = string
  description = "Numeric GitHub repository ID (https://api.github.com/repos/<owner>/<repo>)"
}

variable "alert_email" {
  type        = string
  description = "Email address for AWS budget alerts"
}
```

Variables without a `default` are required. Provide them in
`infra/terraform/terraform.tfvars`, which Terraform reads automatically and which
Git ignores. Commit a copy with fake values, so others know what to fill in:

```hcl
# Copy to terraform.tfvars and fill in your own values.
# terraform.tfvars is git-ignored; this example file is committed.
github_owner    = "your-github-user"
github_owner_id = "12345678"
github_repo_id  = "987654321"
alert_email     = "you@example.com"
```

How sensitive are these values, really?

| Value | Secret? | Where it goes |
|---|---|---|
| Passwords, access keys, tokens | **Yes** | Never in Terraform files; use Secrets Manager (next chapter) |
| AWS account ID | No, but better not published | Looked up at runtime with a data source |
| GitHub numeric IDs, email | Not secret, but personal | `terraform.tfvars` |
| Role and bucket names | No | In the code |

The rule of thumb: **code is public, values are configuration, secrets and state
are private.**

## Step 6: Import the IAM resources

Create `infra/terraform/iam.tf`:

```hcl
# Who am I logged in as? Used to build ARNs without hardcoding the account ID.
data "aws_caller_identity" "current" {}

locals {
  role_name      = "github-actions-ecr-push"
  github_subject = "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}"
}

# 1. OIDC provider: AWS trusts tokens issued by GitHub Actions
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# 2. Role and trust policy: WHO may use this role
resource "aws_iam_role" "github_actions" {
  name = local.role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            "${local.github_subject}:ref:refs/heads/main",
            "${local.github_subject}:ref:refs/tags/v*",
          ]
        }
      }
    }]
  })
}

# 3. Permissions policy: WHAT the role may do
resource "aws_iam_role_policy" "ecr_push" {
  name = "ecr-push"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "EcrPushToOneRepo"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
        ]
        Resource = aws_ecr_repository.app.arn
      },
    ]
  })
}

# One-time import of the resources created by hand in the previous chapter.
# Delete these blocks after a successful apply.
import {
  to = aws_iam_openid_connect_provider.github
  id = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

import {
  to = aws_iam_role.github_actions
  id = local.role_name
}

import {
  to = aws_iam_role_policy.ecr_push
  id = "${local.role_name}:ecr-push"
}
```

Several new ideas appear here.

**Data sources** read information without creating anything.
`data "aws_caller_identity" "current"` asks AWS which account you are logged in
to, so the account ID never appears in the code. You use it as
`data.aws_caller_identity.current.account_id`.

**Locals** are named values used inside the configuration, like constants.
`local.github_subject` builds the OIDC subject prefix once, from variables.

**String interpolation**: `"${...}"` inserts a value into a string, like
`format!` in Rust.

**`jsonencode(...)`** turns Terraform syntax into the JSON policy document AWS
expects. It is the same policy as the JSON files from the previous chapter,
written with `=` instead of `:`, and able to use references.

**References** are the most important idea in this chapter:

```hcl
Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
role      = aws_iam_role.github_actions.id
Resource  = aws_ecr_repository.app.arn
```

Instead of copying ARNs by hand, you point to other resources. Terraform fills in
the real values **and** learns the order: the provider must exist before the
role, and the repository before the policy that names it. The class of mistake
from the previous chapter, a trust policy pointing at an empty or wrong account
ID, cannot happen this way.

Run the plan:

```bash
terraform plan
```

The goal is `3 to import, 0 to add, 0 to change, 0 to destroy`. An
`~ update in-place` on the trust policy is acceptable **only if you understand
it**, for example if the code adds the `refs/tags/v*` line your manual policy did
not have. If anything says **must be replaced** or **destroy**, stop: replacing
the role or OIDC provider would break your pipeline.

After a successful `terraform apply`, **delete the three import blocks**. They are
only needed once; the resources are now in the state. Run `terraform plan`
again: it should still say "No changes".

Then merge a change to `main` and check that the pipeline can still push to ECR.
That proves the trust policy Terraform now manages is correct.

## Step 7: Move the state to S3

Right now, `terraform.tfstate` exists only on your laptop. That causes three
problems:

- **Lose the file, lose the memory.** Terraform would no longer know it manages
  these resources, and would try to create duplicates.
- **Nobody else can use it,** including a CI pipeline later.
- **No protection against two runs at once,** which can corrupt the state.

A **remote backend** in S3 solves all three. There is a chicken-and-egg problem:
Terraform needs the bucket to store its state, so the bucket must exist first.
Create it once by hand. Bucket names are global across all AWS accounts, so make
yours unique:

```bash
BUCKET=<your-name>-rust-devops-tfstate
aws s3api create-bucket --bucket "$BUCKET" --region eu-central-1 \
  --create-bucket-configuration LocationConstraint=eu-central-1
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
aws s3api get-public-access-block --bucket "$BUCKET"
```

Versioning keeps every previous state file, so a corrupted state can be restored.
All four public access block values must be `true`.

Create `infra/terraform/backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket       = "<YOUR_STATE_BUCKET>"
    key          = "rust-devops-app/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

- **`key`** is the path of the state file inside the bucket. A folder-like name
  lets one bucket hold several projects or environments.
- **`use_lockfile`** creates a small `.tflock` object in the bucket while a run is
  in progress, so a second run waits instead of corrupting the state. Older
  tutorials use a DynamoDB table for this; it is no longer needed.

Migrate:

```bash
terraform init -migrate-state
```

Answer `yes` when asked to copy the existing state. Then verify:

```bash
aws s3 ls s3://<your-bucket>/rust-devops-app/
terraform plan
```

The plan must say "No changes": Terraform is reading its memory from S3. Move the
old local state files aside (don't delete them for a few days):

```bash
mkdir -p ~/tfstate-backup && mv terraform.tfstate* ~/tfstate-backup/
```

## Step 8: Create something new: a budget alert

Everything so far was imported. Now create a new resource, and one that protects
you in the following chapters, where some resources cost money every hour.

Create `infra/terraform/budget.tf`:

```hcl
resource "aws_budgets_budget" "monthly" {
  name         = "monthly-cost-limit"
  budget_type  = "COST"
  limit_amount = "20"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Actual spending passes 50% of the limit
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  # Actual spending passes 100%
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  # AWS forecasts that spending will pass 100% by month end
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}
```

- The **`notification`** block appears three times: some resources accept a
  block repeatedly, once per rule.
- **`ACTUAL`** means money already spent; **`FORECASTED`** means AWS predicts,
  from your spending so far, that you will pass the limit by the end of the
  month. The forecast warns you earlier, for example when you forgot to destroy
  an EKS cluster on day three.

```bash
terraform plan    # Plan: 1 to add, 0 to change, 0 to destroy.
terraform apply
```

This time the plan shows a `+`: a resource being created. Check it under
**Billing and Cost Management → Budgets** in the console.

## Troubleshooting

All of these happened while building this project.

**`provider registry registry.terraform.io does not have a provider named hashicrop/aws`.**
A typo in `source`: `hashicorp`, not `hashicrop`. `init` checks providers before
anything touches AWS, which is why it is a separate step.

**`terraform fmt` seems to do nothing.** It only formats `.tf` files in the
current folder, and only prints the names of files it changed. Use
`terraform fmt -recursive` from the repository root, or `terraform fmt -diff` to
see the changes. Check that the file really ends in `.tf`.

**`Failed to load plugin schemas ... timeout while waiting for plugin to start`.**
The provider binary did not start in time. Run the command again first; the
first start can be slow. On an Apple Silicon Mac, check that you installed the
**arm64** build of Terraform (`terraform version` shows `darwin_arm64`); an
amd64 build running under Rosetta can hang while starting the AWS provider.
After switching, run `rm -rf .terraform && terraform init -upgrade`.

**The plan wants to replace something you only renamed.** Renaming a resource's
Terraform address (`aws_vpc.main` to `aws_vpc.primary`) looks like "remove one,
add one". Use a `moved` block to tell Terraform it is the same resource:

```hcl
moved {
  from = aws_vpc.main
  to   = aws_vpc.primary
}
```

Renaming the resource's **AWS name** (the `name` argument) is different: for many
resource types, AWS cannot rename in place, so Terraform must replace it. Never
rename an ECR repository that holds images you need.

**`Error acquiring the state lock`.** Another run holds the lock, or an
interrupted run left it behind. Wait for the other run. If you are certain none
is running, `terraform force-unlock <LOCK_ID>` releases it. Avoid pressing
`Ctrl+C` during `apply`; let Terraform finish or fail.

**Your AWS CLI and Terraform target different accounts.** Run
`aws sts get-caller-identity` before `apply`. Terraform uses the same credentials
and profile as the CLI.

## What you learned

- How Terraform's code, state and plan relate, and how to read plan symbols.
- How to adopt existing resources with `import` blocks instead of recreating them.
- Providers, resources, data sources, variables, locals and references, and why
  references prevent copy-paste mistakes.
- What belongs in a public repository, what goes in `terraform.tfvars`, and what
  must never be in Terraform files at all.
- Why state belongs in a versioned, locked S3 backend.
- How to create a new resource, and how a budget alert protects you.

## Practice

1. **(15 min)** Add an ECR **lifecycle policy** (`aws_ecr_lifecycle_policy`) that expires images
   beyond the 30 most recent. Read the plan before applying.
2. **(15 min)** Rename `aws_ecr_repository.app` to `aws_ecr_repository.service` in the code
   only. Run `plan` and see the destroy/create. Then add a `moved` block and plan
   again.
3. **(5 min)** Add an `output "ecr_repository_url"` and print it with
   `terraform output -raw ecr_repository_url`.
4. **(15 min)** Change the budget's first threshold to 25% using a new variable
   `budget_warning_percent` with a default. Run `plan` with
   `-var budget_warning_percent=10` and compare.
5. **(10 min)** Open your state file in S3, or run `terraform state list` and
   `terraform state show aws_ecr_repository.app`. What information does state
   hold that the code does not?

## Interview questions

- What is Terraform state, and why should it be stored remotely with locking?
- What is the difference between `plan` and `apply`? What does `-/+` mean in a plan?
- How do you bring existing, manually created resources under Terraform management?
- What is the difference between a resource and a data source?
- How do references between resources affect the order Terraform creates them in?
- Where do you keep account-specific values and secrets in a Terraform project?
- You renamed a resource in code and the plan wants to destroy it. What do you do?
