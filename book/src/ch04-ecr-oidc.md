# Pushing to ECR with OIDC

The pipeline from the previous chapter builds an image on every pull request,
then throws it away. To deploy it anywhere, the image has to be stored in a
**container registry**. In this chapter, you push it to **Amazon ECR** (Elastic
Container Registry), and you do it without storing a single AWS secret in GitHub.

This chapter also contains the hardest debugging session of the whole project.
It is told here in full, because the way to the fix teaches more than the fix
itself.

## The idea: why not just use access keys?

The quick way to let GitHub Actions talk to AWS is to create an IAM user,
generate an access key, and paste it into GitHub secrets. It works, and it is a
bad idea:

- **Access keys do not expire.** If one leaks (through a log line, a compromised
  action, or a former colleague), it keeps working until someone notices.
- **Rotation is manual,** so in practice it rarely happens.
- **Anyone who has the key can use it,** from anywhere.

**OpenID Connect (OIDC)** removes the secret entirely:

```text
 GitHub Actions job                         AWS
 ──────────────────                         ───
 1. "I am a workflow from repo X,     ──▶   2. Is this token signed by GitHub?
     branch main" (signed token)               Does the role's trust policy
                                               allow repo X, branch main?
 4. Uses temporary credentials        ◀──   3. Yes: here are credentials,
    (valid ~1 hour) to push to ECR             valid for about an hour
```

GitHub signs a short-lived token for each job. AWS checks the signature and the
claims inside it, and hands out temporary credentials for one IAM role. Nothing
is stored, nothing needs rotating, and the role can be limited to one
repository and one branch.

## The pieces

You need four things in AWS and one in GitHub:

| Piece | Where | Purpose |
|---|---|---|
| ECR repository | AWS | Stores the images |
| OIDC identity provider | AWS | Tells AWS to trust tokens signed by GitHub |
| IAM role, trust policy | AWS | **Who** may use the role: only your repo and branch |
| IAM role, permissions policy | AWS | **What** the role may do: push to one repository |
| `AWS_ROLE_ARN` variable | GitHub | Tells the workflow which role to assume |

The two policies on the role answer two different questions. Think of a hotel:
the **trust policy** is the reception desk checking your ID before handing you a
key card at all; the **permissions policy** decides which doors that card opens.
AWS checks both, and the error message tells you which one failed.

This chapter creates everything with the AWS CLI, so you see each piece. In the
next chapter, Terraform takes it over.

## Step 1: Variables

Run these in your terminal, with admin credentials for your AWS account:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=eu-central-1
REPO_NAME=rust-devops-app
ROLE_NAME=github-actions-ecr-push
echo "$ACCOUNT_ID"
```

The last line should print your 12-digit account number. These variables only
exist in this terminal window; if you open a new one, set them again. Forgetting
this causes one of the errors in the troubleshooting section.

## Step 2: The ECR repository

```bash
aws ecr create-repository \
  --repository-name "$REPO_NAME" \
  --region "$REGION" \
  --image-scanning-configuration scanOnPush=true \
  --image-tag-mutability IMMUTABLE
```

- **`scanOnPush`** makes AWS scan every pushed image for known vulnerabilities.
- **`IMMUTABLE`** means a tag can never be overwritten. Combined with commit-SHA
  tags, `rust-devops-app:3f9c2a1...` will always mean exactly the same image.
  The side effect: pushing the same tag twice fails, which is intended.

## Step 3: The OIDC provider

An account needs this only once. Check first:

```bash
aws iam list-open-id-connect-providers
```

If `token.actions.githubusercontent.com` is not listed, create it:

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com
```

`sts.amazonaws.com` is the **audience**: the token says "this is meant for AWS
STS", and AWS rejects tokens meant for anything else.

## Step 4: Find your repository's subject

The trust policy matches the token's **subject** (`sub`) claim, which identifies
the repository and branch. Since July 2026, repositories created after
July 15, 2026 use a new, immutable format that includes the numeric owner and
repository IDs:

```text
Old format: repo:<owner>/<repo>:ref:refs/heads/main
New format: repo:<owner>@<owner-id>/<repo>@<repo-id>:ref:refs/heads/main
```

The IDs exist for security: names can be reused. If you deleted your repository
and someone else created one with the same name, the old format would let their
workflows assume your role. Numeric IDs are never reused. Existing repositories
keep the old format unless they opt in, but renamed or transferred ones switch.

Find the exact prefix GitHub uses for your repository:

```bash
gh api /repos/<GITHUB_USER>/rust-devops-app/actions/oidc/customization/sub
```

Look at `sub_claim_prefix`. Without the GitHub CLI, for a public repository:

```bash
curl -s https://api.github.com/users/<GITHUB_USER> | grep '"id"'
curl -s https://api.github.com/repos/<GITHUB_USER>/rust-devops-app | grep '"id"' | head -1
```

Store the prefix in a variable (use the old format if your repository uses it):

```bash
SUB_PREFIX="repo:<GITHUB_USER>@<OWNER_ID>/rust-devops-app@<REPO_ID>"
```

## Step 5: The IAM role

The **trust policy** allows only your repository's `main` branch and version
tags to assume the role:

```bash
cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "${SUB_PREFIX}:ref:refs/heads/main",
            "${SUB_PREFIX}:ref:refs/tags/v*"
          ]
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://trust-policy.json
```

The `sub` condition is the important part. Without it, **any** GitHub repository
in the world could assume your role. `StringLike` instead of `StringEquals`
allows the `*` wildcard for version tags like `v0.1.0`.

The **permissions policy** allows pushing to this one repository only:

```bash
cat > ecr-push-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EcrLogin",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "EcrPushToOneRepo",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage",
        "ecr:BatchGetImage"
      ],
      "Resource": "arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${REPO_NAME}"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name ecr-push \
  --policy-document file://ecr-push-policy.json
```

`GetAuthorizationToken` must use `"*"`, because AWS does not support restricting
it to a repository. Everything else is limited to one repository: least privilege.

Before running `create-role`, look at the files with `cat trust-policy.json`.
Every `${...}` should have been replaced by a real value. An empty account ID or
subject prefix is the most common cause of trouble later.

## Step 6: Tell GitHub the role

Print the role's ARN:

```bash
aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text
```

In your GitHub repository, go to **Settings → Secrets and variables → Actions →
Variables** (not Secrets) and add `AWS_ROLE_ARN` with that value. A role ARN is
not secret: it is useless without the trust policy behind it.

## Step 7: The workflow

Replace the `docker` job from the previous chapter with this version, and add
two values to the workflow-level `env` block:

```yaml
env:
  CARGO_TERM_COLOR: always
  AWS_REGION: eu-central-1
  ECR_REPOSITORY: rust-devops-app
```

```yaml
  docker:
    name: Build image (push to ECR on main)
    needs: [lint, security, test]
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write   # required for AWS OIDC login (no stored access keys)
    env:
      SHOULD_PUSH: ${{ github.event_name == 'push' && github.ref == 'refs/heads/main' && vars.AWS_ROLE_ARN != '' }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: docker/setup-buildx-action@f87e5991a6d7451dcb8d9637bfbc97413f497069 # v4.4.1

      - name: Configure AWS credentials (OIDC)
        if: env.SHOULD_PUSH == 'true'
        uses: aws-actions/configure-aws-credentials@e1253824e5c10ff9df46874f81ed3ec929e19cfd # v6.3.0
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Log in to Amazon ECR
        if: env.SHOULD_PUSH == 'true'
        id: ecr
        uses: aws-actions/amazon-ecr-login@03f1aad4c6c7ffd436567f42f9384779290529bd # v2.1.7

      - name: Build (and push on main)
        uses: docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc # v7.4.0
        with:
          context: .
          push: ${{ env.SHOULD_PUSH == 'true' }}
          tags: ${{ steps.ecr.outputs.registry || 'local' }}/${{ env.ECR_REPOSITORY }}:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

What changed:

- **`permissions: id-token: write`** lets this job request an OIDC token from
  GitHub. "Write" here means "may request a token", not "may write to the repo".
  Job-level permissions replace the workflow-level ones, so `contents: read` is
  repeated. Only this job gets the extra permission.
- **`SHOULD_PUSH`** is calculated once: true only for a push to `main`, and only
  once `AWS_ROLE_ARN` is configured. Pull requests still build the image, which
  proves the Dockerfile works, but never push. Environment variables are always
  strings, so later steps compare it with `'true'` in quotes.
- **`configure-aws-credentials`** exchanges the OIDC token for temporary
  credentials of the role.
- **`amazon-ecr-login`** logs Docker in to the registry. Its `id: ecr` lets later
  steps read its output, the registry address.
- **`tags`** uses `steps.ecr.outputs.registry || 'local'`: on pull requests the
  login step is skipped, the output is empty, and the image gets a local tag
  instead.

Merge a change to `main`, and check the result:

```bash
aws ecr describe-images --repository-name rust-devops-app --region eu-central-1 \
  --query 'imageDetails[?imageTags].imageTags' --output json
```

You should see an image tagged with the merge commit's full SHA. Note that a
pull request merge creates a new **merge commit** on `main`, so the tag matches
that commit, not the last commit on your branch.

## Why are there untagged images in ECR?

After the first push, ECR shows **three** entries for one build, two of them
without a tag. This is normal. Docker's BuildKit adds **provenance
attestations** by default: signed metadata about how and where the image was
built. ECR therefore stores:

- an **image index** (tagged with the SHA), a small table of contents,
- the **image** itself (untagged),
- the **attestation** (untagged).

When you pull by tag, Docker follows the index to the right image. **Do not
delete the untagged entries**, because the tagged index depends on them. Be
careful later with lifecycle rules that delete "all untagged images" for the
same reason. If you prefer one entry per build, add `provenance: false` to the
build step, at the cost of losing the attestation.

## Version tags: build once, promote

Every build gets a SHA tag. For releases, you also want a human-readable
version like `v0.1.0`. The right way is **not** to rebuild, but to add a second
tag to the image that was already built and tested:

- you release exactly what you tested, and
- it works with immutable tags, since nothing is pushed twice.

Create `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    tags: ["v*.*.*"]        # runs only when you push a tag like v0.1.0

permissions:
  contents: read
  id-token: write

env:
  AWS_REGION: eu-central-1
  ECR_REPOSITORY: rust-devops-app

jobs:
  promote:
    name: Tag existing image with version
    runs-on: ubuntu-latest
    steps:
      - uses: aws-actions/configure-aws-credentials@e1253824e5c10ff9df46874f81ed3ec929e19cfd # v6.3.0
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - id: ecr
        uses: aws-actions/amazon-ecr-login@03f1aad4c6c7ffd436567f42f9384779290529bd # v2.1.7

      - uses: docker/setup-buildx-action@f87e5991a6d7451dcb8d9637bfbc97413f497069 # v4.4.1

      - name: Add version tag to the SHA image
        env:
          REGISTRY: ${{ steps.ecr.outputs.registry }}
        run: |
          set -euo pipefail
          SOURCE="$REGISTRY/$ECR_REPOSITORY:$GITHUB_SHA"
          TARGET="$REGISTRY/$ECR_REPOSITORY:$GITHUB_REF_NAME"

          echo "Checking that $SOURCE exists..."
          docker buildx imagetools inspect "$SOURCE" > /dev/null

          echo "Tagging as $GITHUB_REF_NAME"
          docker buildx imagetools create --tag "$TARGET" "$SOURCE"
```

- It runs only when you push a Git tag like `v0.1.0`. The trust policy's
  `refs/tags/v*` line allows this.
- `GITHUB_SHA` is the commit the tag points to, so `SOURCE` is the image CI built
  for it. `GITHUB_REF_NAME` is the tag's short name.
- `imagetools inspect` fails clearly if no image exists for that commit, for
  example if you tagged a commit that never went through `main`.
- `imagetools create --tag` adds the new tag inside the registry, without
  downloading or rebuilding anything, and keeps the attestation with it.

Release a version once its commit has been built on `main`:

```bash
git switch main && git pull
git tag v0.1.0
git push origin v0.1.0
```

## Troubleshooting: the full story

Everything below happened, in this order, while building this project. Each
error points at a different piece, which is why reading the message carefully
matters so much.

### `aws: error: the following arguments are required: --thumbprint-list`

The OIDC provider command failed on an old AWS CLI (version 2.1.7, from 2020).
Old versions require certificate thumbprints; newer versions make them
optional, because AWS now validates GitHub's tokens through trusted certificate
authorities. Update the CLI, or pass GitHub's published thumbprints:

```bash
--thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 1c58a3a8518e8759bf075b76b750d4f2df264fcd
```

The trap: because this command failed, **the provider was never created**, which
caused the next error.

### `Could not assume role with OIDC: The web identity token provided could not be validated`

GitHub created the token fine, but AWS found no matching OIDC provider. Check
that the provider exists **in the same account** as the role, that its URL is
exactly `token.actions.githubusercontent.com`, and that its client ID list
contains `sts.amazonaws.com`:

```bash
aws iam list-open-id-connect-providers
```

### `Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity`

Progress: the provider works, and AWS accepted the token, but the role's trust
policy did not match it. Work through these, one at a time:

1. **Does the GitHub variable point to an existing role?** In this project, the
   role had been created as `rust-devops-apps-github-actions-ecr-push`, while the
   variable used a different name. A role that does not exist produces exactly
   this message.

   ```bash
   aws iam list-roles --query "Roles[?contains(RoleName, 'ecr-push')].[RoleName, Arn]" --output table
   ```

2. **Does the `Federated` principal match the provider ARN exactly?** An empty
   `ACCOUNT_ID` variable when the policy was written produces a broken ARN.

   ```bash
   aws iam get-role --role-name "$ROLE_NAME" \
     --query 'Role.AssumeRolePolicyDocument.Statement[0]' --output json
   ```

3. **Does the `sub` value match what GitHub sends?** This was the final cause:
   the repository was created after July 15, 2026, so GitHub sent the new format
   with numeric IDs, while the policy (and almost every tutorial online) used the
   old one. Everything else looked perfect. The fix was Step 4 of this chapter.

Fix the policy file and update the role, then use **Re-run failed jobs**; no new
commit is needed:

```bash
aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
  --policy-document file://trust-policy.json
```

### `AccessDenied` on an ECR action

Login worked, but the **permissions** policy does not allow the action. Check
that the repository name in the policy's `Resource`, the ECR repository itself,
and `ECR_REPOSITORY` in the workflow are all identical.

### `tag already exists` / `ImageTagAlreadyExistsException`

You re-ran a workflow for a commit whose image was already pushed. With
immutable tags, that is expected: nothing is broken.

## What you learned

- Why OIDC is safer than access keys: short-lived credentials, nothing stored,
  nothing to rotate, and access restricted to one repository and branch.
- How a role's trust policy (who) and permissions policy (what) work together,
  and how error messages tell you which one failed.
- GitHub's 2026 change to the OIDC subject format, and why numeric IDs protect
  against reused names.
- Why SHA tags plus immutable repositories make every image traceable, and how
  to promote releases without rebuilding.
- What provenance attestations are, and why untagged ECR entries must stay.

## Practice

1. Add an ECR **lifecycle policy** that keeps only the last 20 tagged images.
   Make sure it cannot delete images referenced by an index.
2. Add a `refs/heads/dev` line to the trust policy, and a job that pushes
   `dev-<sha>` images from the `dev` branch. What would you change to clean them
   up automatically?
3. Read the decoded OIDC token claims in a workflow (the
   `actions/github-script` action can request a token) and find the `sub`,
   `aud`, `repository_id`, and `ref` claims yourself.
4. Try the release workflow with a tag on a commit that never went through `main`.
   Read the error from `imagetools inspect`.

## Interview questions

- Why use OIDC instead of AWS access keys in CI? What does the trust policy
  check?
- What is the difference between an IAM role's trust policy and its permissions
  policy?
- How would you restrict a CI role so that pull requests from other branches
  cannot push images?
- Why tag images with the commit SHA, and why make the repository's tags immutable?
- How do you release a version without rebuilding the image?
- You see `Not authorized to perform sts:AssumeRoleWithWebIdentity`. How do you
  debug it?
