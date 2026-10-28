# Continuous Deployment

Since Chapter 4, every merge to `main` produces a tested image in ECR. Since
Chapter 8, one Helm command deploys an image. What is still missing is the link
between them: today a person connects to the server, collects four values, and
types the Helm command.

This chapter closes the loop. First you turn the manual steps from Chapters 7
and 8 into one script that anyone can run safely, again and again. Then you let
GitHub Actions run that script on the server after every merge, without SSH,
without opening a port, and without storing a single credential in GitHub.

> **Time and typing**
>
> | | |
> |---|---|
> | Reading | 40 min |
> | Hands-on | 60 min, plus about 10 min per pipeline run |
> | Practice | 60 min |
> | Cost | the k3s server and RDS while they run |
>
> **Copy:** `scripts/deploy.sh` and the `deploy` job are complete; paste them.
> **Type yourself:** the `set -euo pipefail` line and the Helm command at the end
> of `deploy.sh` (about 10 lines), and the `Condition` block of the IAM policy in
> Step 4 (4 lines). The first decides whether the script stops on errors; the
> second decides which servers your pipeline may control.

## The idea

### Delivery or deployment?

The two terms sound alike and are often mixed up:

- **Continuous delivery**: every change that passes the pipeline *could* go to
  production. A person decides when, often with one click.
- **Continuous deployment**: every change that passes the pipeline *does* go to
  production, automatically.

This project does continuous deployment: a merge to `main` ends with the new
version running on the k3s server, usually within ten minutes. That is safe
only because of everything before it: required checks (Chapter 3), immutable
images (Chapter 4), readiness probes and rolling updates (Chapter 7), and
`--wait` (Chapter 8). If any of them is missing, automatic deployment just
means breaking things faster.

### Push or pull?

There are two ways for a pipeline to get a new version into a cluster:

```text
 PUSH  (this book)                        PULL  (GitOps)
 pipeline ──"deploy sha X"──▶ cluster     pipeline ──commits "sha X"──▶ Git
                                          cluster agent ──watches──▶ Git, applies it
```

- **Push**: the pipeline tells the cluster what to run. Simple, and easy to
  follow in the pipeline log. The pipeline needs a way into the cluster.
- **Pull (GitOps)**: an agent inside the cluster (Argo CD, Flux) watches a Git
  repository and applies whatever it says. The pipeline never touches the
  cluster; it only changes a file in Git.

GitOps is common in larger teams, and the Lessons Learned chapter returns to
it. Push is the right first step: you see every part of it, and it reuses
everything you have built.

### How the pipeline gets in

The obvious ways for a pipeline to reach a server all have a cost:

| Option | Problem |
|---|---|
| SSH with a private key in GitHub Secrets | a long-lived key that can leak; port 22 open to GitHub's IP ranges |
| Kubernetes API exposed to the internet | port 6443 open; a kubeconfig with cluster-admin rights stored in GitHub |
| A self-hosted GitHub runner on the server | the server runs code from every workflow run |

This project uses **AWS Systems Manager Run Command** instead. You already use
the same channel with Session Manager: the SSM agent on the server keeps an
**outbound** connection to AWS. The pipeline logs in to AWS with OIDC (no stored
keys, Chapter 4), asks SSM to run a command on the instance, and reads the
result. Nothing is opened, nothing is stored, and every command is recorded in
CloudTrail.

```text
 merge to main
      │
      ▼
 GitHub Actions: lint, audit, test ──▶ build, push image :<sha> to ECR
      │                                                  │
      ▼                                                  │
 deploy job ──OIDC──▶ AWS ──SSM Run Command──▶ k3s server│
                                                  │      │
                                    git checkout <sha>   │
                                    ./scripts/deploy.sh <sha>
                                                  │      │
                                                  ▼      ▼
                                         helm upgrade ◀── pulls image :<sha>
```

## Step 1: The deploy script

Everything the server has to do goes into one script in the repository:
`scripts/deploy.sh`. A script in Git can be reviewed, versioned, and run by
hand and by the pipeline in exactly the same way. The pipeline itself stays
small: it only starts the script.

The script has to be **idempotent**: running it twice must give the same result
as running it once. A pipeline retries, people run things again "to be sure",
and a new server starts empty. Each block below is written so that it works
whether or not its objects already exist.

Create `scripts/deploy.sh` on your laptop and make it executable with
`chmod +x scripts/deploy.sh`. Paste it block by block, reading the explanation
after each one.

### Settings and safety

```bash
#!/usr/bin/env bash
#
# Deploy rust-app to the k3s cluster with Helm.
# Safe to run again and again (idempotent).
#
# Database: uses the RDS instance if it exists, otherwise falls back to
# the in-cluster PostgreSQL from k8s/postgres.yaml.
#
# Usage (on the k3s server, from anywhere in the repo):
#   ./scripts/deploy.sh              # deploy the newest tagged image in ECR
#   ./scripts/deploy.sh <image-tag>  # deploy a specific image (e.g. for a rollback)

set -euo pipefail

REGION="eu-central-1"
REPO="rust-devops-app"
NAMESPACE="rust-app"
RELEASE="rust-app"
CHART_DIR="charts/rust-app"
DB_INSTANCE_ID="rust-devops-db"
DB_SECRET_NAME="${RELEASE}-db"

cd "$(dirname "$0")/.."
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

for cmd in aws kubectl helm python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' is not installed." >&2
    exit 1
  fi
done
```

**`set -euo pipefail`** is the most important line in any deployment script.
Type it yourself, and put it at the top of every Bash script you write:

| Flag | Without it | With it |
|---|---|---|
| `-e` | a failed command is ignored, and the script carries on | the script stops at the first failed command |
| `-u` | a misspelled `$IMAGE_TGA` is silently empty | using an unset variable is an error |
| `-o pipefail` | `failing-cmd \| tee log` counts as success, because `tee` succeeded | a pipeline fails if any part of it fails |

Without it, a script that could not log in to ECR would go on and deploy
anyway, and report success.

**`cd "$(dirname "$0")/.."`** changes to the repository root, whatever folder
the script is started from, so that relative paths like `charts/rust-app` work.

**`export KUBECONFIG="${KUBECONFIG:-...}"`** uses the existing value if there is
one, and the k3s default otherwise. This line matters for the pipeline: SSM runs
commands in a plain shell that does not read `/etc/bash.bashrc`, so without it
`kubectl` and `helm` would look for `localhost:8080` (Chapter 7,
Troubleshooting).

**The `for` loop** checks every tool before doing anything. Failing in the first
second with "`helm` is not installed" is far better than failing halfway
through, with a half-updated namespace.

### Which image

```bash
# --- Which image to deploy ------------------------------------------------
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

IMAGE_TAG="${1:-$(aws ecr describe-images \
  --repository-name "$REPO" \
  --region "$REGION" \
  --query 'sort_by(imageDetails[?imageTags], &imagePushedAt)[-1].imageTags[0]' \
  --output text)}"

if [[ -z "$IMAGE_TAG" || "$IMAGE_TAG" == "None" ]]; then
  echo "Error: no tagged image found in ECR repository '$REPO'." >&2
  exit 1
fi

echo "==> Deploying ${REPO}:${IMAGE_TAG} to namespace '${NAMESPACE}'"
```

The account ID comes from AWS at run time, so it never appears in the
repository. `${1:-...}` means "the first argument if given, otherwise the newest
tagged image". The pipeline always passes the commit SHA it just built, so it
deploys exactly the image it tested, even if another image was pushed a second
later. By hand, you leave it out and get the newest one, or pass an old tag to
roll back.

The JMESPath query in `--query` reads: take the images that have tags, sort them
by push time, take the last one, and return its first tag.

### Namespace and pull secret

```bash
# --- Namespace -----------------------------------------------------------
echo "==> Namespace"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# --- ECR pull secret (refreshed every run: tokens expire after 12 hours) -
echo "==> ECR pull secret"
kubectl create secret docker-registry ecr-credentials \
  --namespace "$NAMESPACE" \
  --docker-server="$REGISTRY" \
  --docker-username=AWS \
  --docker-password="$(aws ecr get-login-password --region "$REGION")" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Both use the `--dry-run=client -o yaml | kubectl apply -f -` pattern from
Chapter 7, which makes `create` idempotent. A plain
`kubectl create namespace` fails with `AlreadyExists` on the second run, and
with `set -e`, that would stop the script.

The pull secret is refreshed on **every** run, because the ECR token is only
valid for 12 hours. A deployment refreshes it right before Helm needs it.

### The database

```bash
# --- Database: RDS if it exists, otherwise in-cluster PostgreSQL --------
RDS_ERR=$(mktemp)
trap 'rm -f "$RDS_ERR"' EXIT

if RDS_INFO=$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --region "$REGION" \
  --query 'DBInstances[0].[DBInstanceStatus,Endpoint.Address,Endpoint.Port,DBName,MasterUserSecret.SecretArn]' \
  --output text 2>"$RDS_ERR"); then

  read -r DB_STATUS DB_HOST DB_PORT DB_NAME SECRET_ARN <<<"$RDS_INFO"
  if [[ "$DB_STATUS" != "available" ]]; then
    echo "Error: RDS instance is '$DB_STATUS'. Wait until it is 'available'." >&2
    exit 1
  fi
  echo "==> Database: RDS ($DB_HOST)"

  # Read username/password from Secrets Manager (never printed)
  SECRET_JSON=$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ARN" --region "$REGION" \
    --query SecretString --output text)

  # Build the URL in Python so special characters in the password are URL-encoded.
  # sslmode=require: RDS for PostgreSQL 15+ only accepts encrypted connections.
  DATABASE_URL=$(SECRET_JSON="$SECRET_JSON" DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_NAME="$DB_NAME" python3 -c '
import json, os
from urllib.parse import quote
s = json.loads(os.environ["SECRET_JSON"])
print("postgres://{}:{}@{}:{}/{}?sslmode=require".format(
    quote(s["username"], safe=""), quote(s["password"], safe=""),
    os.environ["DB_HOST"], os.environ["DB_PORT"], os.environ["DB_NAME"]))
')
  unset SECRET_JSON

  # The in-cluster database is not needed when RDS is used
  kubectl delete -f k8s/postgres.yaml --ignore-not-found

elif grep -q "DBInstanceNotFound" "$RDS_ERR"; then
  echo "==> Database: in-cluster PostgreSQL (no RDS instance found)"
  kubectl apply -f k8s/postgres.yaml
  kubectl rollout status deployment/postgres --namespace "$NAMESPACE" --timeout=180s
  DATABASE_URL="postgres://app:app@postgres:5432/app"

else
  echo "Error: could not check for the RDS instance:" >&2
  cat "$RDS_ERR" >&2
  exit 1
fi
```

This block is Step 10 of Chapter 7 with one important addition: it decides
**which** database to use, and it is careful about **why** the RDS lookup
failed. There are three outcomes, not two:

1. **RDS exists** and is `available`: build the URL from Secrets Manager, as in
   Chapter 6.
2. **RDS does not exist** (`DBInstanceNotFound`): fall back to the in-cluster
   PostgreSQL. This lets you practise Kubernetes without paying for RDS.
3. **Anything else** (no permission, network error, expired credentials):
   **stop**. A careless script would treat every error as "no RDS" and quietly
   switch the application to an empty in-cluster database, which looks exactly
   like data loss to a user.

The error output goes to a temporary file (`mktemp`), so the script can look at
it. **`trap '...' EXIT`** deletes that file when the script ends, whether it
succeeds or fails. Use `trap` for every temporary file.

Note how the password is handled: it travels in an environment variable
(`SECRET_JSON=... python3`), never as a command-line argument (visible to every
user in `ps`), and it is never echoed. `unset` removes it as soon as it is no
longer needed.

### The database Secret

```bash
# Store the connection string in a Kubernetes Secret (created outside Helm)
echo "==> Database secret"
kubectl create secret generic "$DB_SECRET_NAME" \
  --namespace "$NAMESPACE" \
  --from-literal=DATABASE_URL="$DATABASE_URL" \
  --dry-run=client -o yaml | kubectl apply -f -

# Fingerprint of the config: when it changes, Helm restarts the pods
CONFIG_CHECKSUM=$(printf '%s' "$DATABASE_URL" | sha256sum | cut -d' ' -f1)
unset DATABASE_URL
```

Why not pass the URL to Helm with `--set databaseUrl=...`? Because Helm stores
the values of every revision in the cluster, and `helm get values` would print
the database password for anyone with read access to the namespace. Keeping the
Secret outside Helm, and passing only its **name** (`existingSecret`), keeps the
password out of Helm's history.

The price is the problem from Chapter 8, Step 10: Helm cannot see when this
Secret changes. The **checksum** solves it. The script hashes the URL and passes
the hash as `configChecksum`. When the database is recreated and the password
changes, the hash changes, the pod template changes, and Kubernetes rolls the
pods. When nothing changed, the hash is identical, and nothing restarts. The
hash reveals nothing about the password.

### Deploy with Helm

```bash
# --- Lint and deploy -----------------------------------------------------
HELM_ARGS=(
  --set image.repository="${REGISTRY}/${REPO}"
  --set image.tag="$IMAGE_TAG"
  --set existingSecret="$DB_SECRET_NAME"
  --set configChecksum="$CONFIG_CHECKSUM"
)
# Optional: extra values file (e.g. VALUES_FILE=charts/rust-app/values-eks.yaml)
if [[ -n "${VALUES_FILE:-}" ]]; then
  HELM_ARGS+=(-f "$VALUES_FILE")
fi

# Optional: restrict the ALB to one IP range (e.g. ALLOW_CIDR=203.0.113.10/32)
if [[ -n "${ALLOW_CIDR:-}" ]]; then
  HELM_ARGS+=(--set-string "ingress.annotations.alb\\.ingress\\.kubernetes\\.io/inbound-cidrs=${ALLOW_CIDR}")
fi

echo "==> Helm lint"
helm lint "$CHART_DIR" "${HELM_ARGS[@]}"

echo "==> Helm upgrade"
if ! helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  "${HELM_ARGS[@]}" \
  --wait \
  --timeout 5m; then
  echo >&2
  echo "Deployment failed. Pod status, recent events and logs:" >&2
  kubectl get pods --namespace "$NAMESPACE" >&2
  kubectl describe pods --namespace "$NAMESPACE" -l "app=${RELEASE}" | tail -25 >&2
  kubectl logs --namespace "$NAMESPACE" -l "app=${RELEASE}" --tail=10 >&2 || true
  exit 1
fi

# --- Summary -------------------------------------------------------------
echo
echo "==> Done. Recent releases:"
helm history "$RELEASE" --namespace "$NAMESPACE" --max 5
echo
kubectl get pods,svc,ingress --namespace "$NAMESPACE"
```

**`HELM_ARGS=( ... )`** is a Bash **array**. `"${HELM_ARGS[@]}"` expands it
into separate arguments, each one quoted correctly, even if a value contains
spaces. The same arguments are used twice, for `lint` and `upgrade`, so they
cannot drift apart. Building a command as one long string instead is a classic
source of quoting bugs.

**`VALUES_FILE` and `ALLOW_CIDR`** are optional environment variables that the
EKS chapters use. On k3s, they are not set, and the `if` blocks do nothing.
`${VALUES_FILE:-}` gives an empty string for an unset variable, which keeps
`set -u` happy.

**`helm lint` before `upgrade`** catches template errors before anything in the
cluster changes.

**The Helm command** is the one from Chapter 8. Type it yourself; you should be
able to write `helm upgrade --install ... --wait --timeout` from memory.

**`if ! helm upgrade ...; then`**: when the deployment fails, the script prints
what you would otherwise collect by hand: pod status, the end of `describe`
(with the events), and the last log lines. In the pipeline, this output appears
in the GitHub Actions log, so most failures can be diagnosed without opening a
terminal on the server. `|| true` after `kubectl logs` stops `set -e` from
ending the script before the real `exit 1` (`logs` fails if a pod never
started).

## Step 2: Run it by hand

Push the script, then on the server:

```bash
cd ~/rust-devops-app && git pull
./scripts/deploy.sh
```

Read the output: each `==>` line is one block of the script. At the end you see
the Helm history and the running objects. Now run it **again**, unchanged.
It succeeds, Helm creates a new revision, but the pods do **not** restart: same
image, same checksum, same pod template. That is idempotency you can see.

Then roll back to an older image by tag:

```bash
aws ecr describe-images --repository-name rust-devops-app --region eu-central-1 \
  --query 'sort_by(imageDetails[?imageTags], &imagePushedAt)[-3:].imageTags[0]' --output text
./scripts/deploy.sh <older-tag>
./scripts/deploy.sh
```

The last command goes back to the newest image. From now on, this script is the
only way anything gets deployed, by you or by the pipeline.

## Step 3: Give the pipeline its permissions

The GitHub Actions role from Chapter 4 can push images, nothing else. To deploy,
it needs to find the server and send it a command. Add this to
`infra/terraform/iam.tf`, and type the `Condition` block yourself:

```hcl
# Allow GitHub Actions to trigger deployments on the k3s instance via SSM
resource "aws_iam_role_policy" "ssm_deploy" {
  name = "ssm-deploy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "FindInstance"
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*"
      },
      {
        Sid      = "RunShellScriptDocument"
        Effect   = "Allow"
        Action   = "ssm:SendCommand"
        Resource = "arn:aws:ssm:eu-central-1::document/AWS-RunShellScript"
      },
      {
        Sid      = "OnlyOnTheK3sInstance"
        Effect   = "Allow"
        Action   = "ssm:SendCommand"
        Resource = "arn:aws:ec2:eu-central-1:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = {
          StringEquals = { "ssm:resourceTag/Name" = "${local.name}-k3s" }
        }
      },
      {
        Sid      = "ReadCommandResults"
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
        Resource = "*"
      },
    ]
  })
}
```

`ssm:SendCommand` is checked against **two** resources at once: the **document**
(what to run) and the **instance** (where to run it). Both must be allowed:

- The document is `AWS-RunShellScript`, an AWS-owned document that runs shell
  commands. Note the empty account field in its ARN (`::document`): it belongs
  to AWS, not to you.
- The instance is any instance in your account **whose `Name` tag is
  `rust-devops-k3s`**. That `Condition` is the security boundary of this whole
  chapter. Without it, the pipeline could run any command, as root, on every
  instance in the account.

Why a tag and not the instance ID? Because the instance is destroyed and
recreated all the time, and each new one has a new ID. The tag stays the same,
since Terraform sets it.

`ec2:DescribeInstances` and the two read actions do not support resource-level
restrictions, so they need `"*"`. They only read.

Apply it from your laptop:

```bash
cd infra/terraform
terraform plan     # 1 to add: aws_iam_role_policy.ssm_deploy
terraform apply
```

Think about what this role can now do. Anyone who can make the workflow run
with a changed `deploy` job could run commands on your server. The OIDC trust
policy from Chapter 4 is what prevents it: only workflows on `refs/heads/main`
can assume the role, and the `main` branch only changes through reviewed pull
requests with required checks (Chapter 3). Branch protection is part of your
deployment security.

## Step 4: The deploy job

Add this job at the end of `.github/workflows/ci.yml`, after the `docker` job:

```yaml
  deploy:
    name: Deploy to k3s
    needs: [docker]
    if: github.event_name == 'push' && github.ref == 'refs/heads/main' && vars.AWS_ROLE_ARN != ''
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
    concurrency:
      group: deploy-k3s
      cancel-in-progress: false
    env:
      AWS_REGION: eu-central-1
      INSTANCE_NAME: rust-devops-k3s
    steps:
      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@7474bc4690e29a8392af63c5b98e7449536d5c3a # v4.3.1
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Find the k3s instance
        id: instance
        run: |
          ID=$(aws ec2 describe-instances \
            --filters "Name=tag:Name,Values=${INSTANCE_NAME}" "Name=instance-state-name,Values=running" \
            --query 'Reservations[0].Instances[0].InstanceId' --output text)
          if [ -z "$ID" ] || [ "$ID" = "None" ]; then
            echo "::notice::No running k3s instance found - skipping deployment."
            echo "id=" >> "$GITHUB_OUTPUT"
          else
            echo "Found instance $ID"
            echo "id=$ID" >> "$GITHUB_OUTPUT"
          fi

      - name: Deploy through SSM Run Command
        if: steps.instance.outputs.id != ''
        env:
          INSTANCE_ID: ${{ steps.instance.outputs.id }}
        run: |
          set -euo pipefail

          PARAMS=$(jq -n --arg repo "$GITHUB_REPOSITORY" --arg sha "$GITHUB_SHA" '{
            commands: [
              "set -e",
              "export HOME=/root PATH=$PATH:/snap/bin",
              "[ -d /opt/rust-devops-app ] || git clone --quiet https://github.com/\($repo).git /opt/rust-devops-app",
              "cd /opt/rust-devops-app",
              "git fetch --quiet origin",
              "git checkout --quiet --force \($sha)",
              "bash ./scripts/deploy.sh \($sha)"
            ]
          }')

          CMD_ID=$(aws ssm send-command \
            --instance-ids "$INSTANCE_ID" \
            --document-name AWS-RunShellScript \
            --comment "Deploy ${GITHUB_SHA::7}" \
            --timeout-seconds 900 \
            --parameters "$PARAMS" \
            --query Command.CommandId --output text)
          echo "SSM command: $CMD_ID"

          STATUS=Pending
          for _ in $(seq 1 60); do
            sleep 10
            STATUS=$(aws ssm get-command-invocation \
              --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
              --query Status --output text 2>/dev/null || echo Pending)
            echo "Status: $STATUS"
            case "$STATUS" in
              Success|Failed|Cancelled|TimedOut) break ;;
            esac
          done

          echo "----- output from the server -----"
          aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
            --query StandardOutputContent --output text
          echo "----- errors from the server -----"
          aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
            --query StandardErrorContent --output text

          [ "$STATUS" = "Success" ]
```

### When it runs

**`needs: [docker]`**: only after the image was built and pushed. And because
`docker` needs `lint`, `security` and `test`, a deployment can only happen after
every check passed.

**`if:`** repeats the `docker` job's push condition: only for a `push` to `main`
(a merged pull request), never for a pull request, and only when the AWS role is
configured. Pull requests run the checks and build the image, but never deploy.

**`concurrency: deploy-k3s`** with `cancel-in-progress: false`: if two pull
requests are merged a minute apart, the second deployment **waits** for the
first one. It is not cancelled, because a Helm upgrade interrupted halfway
leaves the release in `pending-upgrade` (Chapter 8, Troubleshooting). Compare
this with the workflow-level `concurrency` from Chapter 3, which does cancel:
cancelling a test run is harmless, cancelling a deployment is not.

**`permissions: id-token: write`** lets the job request the OIDC token, as in
Chapter 4. This job uses the same role as the `docker` job; it now has the
extra policy from Step 3.

### What it does

**Find the instance.** The job looks for a **running** instance with the right
`Name` tag. If there is none (you destroyed the server at the end of your last
session), it writes a `::notice::` and skips the deploy step. The workflow stays
green: "no server to deploy to" is a normal state in this project, not an error.
`$GITHUB_OUTPUT` is how one step passes a value to later steps
(`steps.instance.outputs.id`).

**Build the commands.** The commands for the server are built with `jq`, which
produces correct JSON with the repository name and the SHA filled in. Writing
JSON by hand inside a YAML file inside a shell script is a reliable way to get
quoting wrong. On the server, the commands:

1. Set `HOME` and add `/snap/bin` to `PATH`. SSM runs as `root` in a minimal
   environment; without this, `aws` and `helm` (installed with snap) are not
   found.
2. Clone the repository into `/opt/rust-devops-app` if it is not there yet (a
   new server), so the first deployment works on an empty machine.
3. Check out **exactly** the commit that was tested (`$GITHUB_SHA`), not
   "whatever `main` is now". `--force` throws away any local change, which is
   the "never edit files on the server" rule enforced by code.
4. Run `deploy.sh` with the SHA as image tag: the image built in this very
   workflow run.

This is a separate copy of the repository from your `~/rust-devops-app`, owned
by root and used only by the pipeline.

**Send and wait.** `send-command` returns at once with a command ID. The loop
asks for the status every 10 seconds, for up to 10 minutes, and stops when the
command has finished. `|| echo Pending` covers the first seconds, when SSM may
not know the invocation yet.

**Show the output, then fail or pass.** The server's output is printed into the
Actions log either way, so you can read the `==>` lines and, if it failed, the
pod diagnostics from `deploy.sh`. The last line, `[ "$STATUS" = "Success" ]`, is
a test that fails the step unless the command succeeded. With `set -e`, that
makes the job red.

Note the pinned SHA on `configure-aws-credentials`, as in Chapter 3. A deploy
job holds the most powerful credentials in your pipeline, so it is the last
place to use a moving tag like `@v4`.

## Step 5: Watch it deploy

Make a change you can see from outside. The service has a `/version` endpoint
that returns the version from `Cargo.toml`. On your laptop, on the `dev`
branch, change it:

```bash
sed -i '' 's/^version = "0.2.0"/version = "0.2.1"/' Cargo.toml   # macOS sed
cargo build                                                      # updates Cargo.lock
git commit -am "Bump version to 0.2.1"
git push
```

(On Linux, use `sed -i` without the `''`.)

Make sure the k3s server is running (`terraform apply` if not), then open a
pull request from `dev` to `main`. The checks run, but the `Deploy to k3s` job
shows as **skipped**: pull requests do not deploy. Merge it, and open the
**Actions** tab:

```text
 Format & Clippy ✓   Dependency audit ✓   Tests ✓
          └──────────────┬──────────────┘
                 Build image ✓ (pushed :<sha>)
                         │
                  Deploy to k3s ●  Status: InProgress ... Success
```

Open the `Deploy to k3s` job and expand the last step. You see your own
`deploy.sh` output, sent back from the server. When it is green, check from
your laptop:

```bash
curl -s http://<k3s_public_ip>/version
```

It answers `0.2.1`. From a merge on GitHub to a new version on your server, with
no terminal, no SSH, and no stored credential.

### After creating a new server

The pipeline only deploys when something is merged. After a new server boots,
nothing is deployed on it until the next merge. You have two options:

- Run `./scripts/deploy.sh` once in Session Manager. It deploys the newest image.
- In GitHub, open the last successful workflow run on `main` and use
  **Re-run jobs → Re-run this job** on the `Deploy to k3s` job only. Do not
  re-run **all** jobs: the `docker` job would try to push the same tag again, and
  ECR's immutable tags reject it (Chapter 4, Troubleshooting).

## Troubleshooting

All of these happened while building this project.

**The deploy job is green, but nothing changed on the server.** Open the job: it
says `No running k3s instance found - skipping deployment.` The server was not
running, or its `Name` tag is different. Check with
`aws ec2 describe-instances --filters Name=tag:Name,Values=rust-devops-k3s --query 'Reservations[].Instances[].State.Name'`.

**`An error occurred (AccessDeniedException) when calling the SendCommand operation: User: arn:aws:sts::<ACCOUNT_ID>:assumed-role/... is not authorized to perform: ssm:SendCommand on resource: arn:aws:ec2:...:instance/i-...`.**
The policy from Step 3 is missing (not applied yet), or the instance's `Name` tag
does not match the condition. The message names the resource that was denied: if
it is the instance, check the tag; if it is the document, check the document ARN.

**`An error occurred (InvalidInstanceId) when calling the SendCommand operation`.**
The instance is running, but its SSM agent is not connected yet. This happens in
the first minutes after a new server boots, or when the instance role lost
`AmazonSSMManagedInstanceCore`. Wait until the instance shows up in
**Systems Manager → Fleet Manager**, then re-run the deploy job.

**`aws: command not found` or `helm: command not found` in the server output.**
The commands ran without `/snap/bin` in `PATH`. SSM does not use a login shell.
Check the `export HOME=/root PATH=$PATH:/snap/bin` line in the job.

**`Error: Kubernetes cluster unreachable: ... localhost:8080` in the server output.**
`KUBECONFIG` is not set in the SSM shell. The `export KUBECONFIG=...` line near
the top of `deploy.sh` fixes it for every caller.

**`Status: Failed`, and the output ends with `Deployment failed. Pod status, recent events and logs:`.**
The script worked; the new version did not become ready. Read the pod status and
events printed below it, and use the debugging map from Chapter 7. A common
cause on a new server: the RDS instance is still being created, so the script
stopped with `RDS instance is 'creating'`. Wait, then re-run the deploy job.

**The status loop ends with `Status: InProgress` after 10 minutes.** The script
is still running on the server, usually stuck in `helm --wait` or in
`rollout status` for PostgreSQL. The job fails, but SSM keeps the command running
until `--timeout-seconds` (15 minutes). Look at it in **Systems Manager → Run
Command → Command history**, which shows the full output.

**A second merge waits a long time before deploying.** That is the
`deploy-k3s` concurrency group doing its job: the second deployment starts when
the first has finished.

## What you learned

- The difference between continuous delivery and continuous deployment, and
  between push-based deployment and GitOps.
- Why SSM Run Command with OIDC is safer than SSH keys, an exposed Kubernetes
  API, or a self-hosted runner.
- How to write a deployment script that is idempotent, stops on errors
  (`set -euo pipefail`), checks its tools first, cleans up with `trap`, keeps
  secrets out of arguments and logs, and prints diagnostics when it fails.
- Why the database Secret is kept outside Helm, and how a checksum restarts pods
  only when the configuration really changed.
- How an IAM condition on a resource tag limits a pipeline to one server.
- How the deploy job finds the server, runs the script for the exact tested
  commit, waits for the result, and shows the server's output in the pipeline
  log.
- Why deployments are queued, never cancelled.

## Practice

Each exercise says how long it takes and how much you type.

1. **Break a deployment** (15 min, change 1 line). On `dev`, change the
   readiness probe path in the chart to `/nope`, merge, and watch the deploy job
   fail. Find the reason in the Actions log alone, without Session Manager. Then
   revert with a new pull request. Why is "revert and merge" the right fix,
   instead of `helm rollback` on the server?
2. **A rollback button** (30 min, about 15 lines). Add a separate workflow,
   `rollback.yml`, with `on: workflow_dispatch` and an input `tag`. It reuses the
   deploy steps and runs `deploy.sh <tag>`. What must you change in the IAM trust
   policy, if anything, for a manually started workflow on `main`?
3. **A deployment summary** (10 min, 3 lines). At the end of the deploy step,
   append the deployed SHA and the server's `helm history` to
   `$GITHUB_STEP_SUMMARY`. It appears on the workflow run's summary page.
4. **An approval gate** (20 min, 2 lines plus settings). Create a GitHub
   **environment** called `production` with yourself as required reviewer, and
   add `environment: production` to the deploy job. Merge something and approve
   the deployment. You have turned continuous deployment into continuous
   delivery. When would a team want that?
5. **Shellcheck the script** (10 min, no typing). Run `shellcheck
   scripts/deploy.sh` (it is preinstalled on GitHub's Ubuntu runners, and
   `brew install shellcheck` on a Mac). Understand every warning it prints, if
   any. Then add it as a step to the `lint` job.

Finish the session by destroying the server and the database (Chapter 7,
Step 11).

## Interview questions

- What is the difference between continuous delivery and continuous deployment?
- Compare push-based deployment from a pipeline with GitOps (Argo CD, Flux).
  What are the trade-offs?
- How does your pipeline get access to the server? Why not SSH?
- What does `set -euo pipefail` do? Give an example of a bug each flag prevents.
- What makes a deployment script idempotent? Why does it matter?
- Your pipeline can run commands on a server. How do you limit what it can do,
  and who can change it?
- Why should a deployment use the commit SHA instead of `latest` or "the newest
  image"?
- Two merges happen a minute apart. What happens to the deployments, and why
  should the second not cancel the first?
- How do you roll back a bad deployment in this setup? What are the options,
  and which is best long-term?
- Where do you keep the database password so that it does not end up in Helm's
  release history?
