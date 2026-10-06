# CI with GitHub Actions

You now have a tested service and a container image. But so far, everything
depends on you remembering to run `cargo fmt`, `cargo clippy`, the tests, and a
Docker build before every change. People forget, especially under time pressure.

**Continuous integration (CI)** means a machine does these checks
automatically, on every pull request and every merge. Nothing reaches `main`
without passing them. In this chapter, you build that pipeline with GitHub
Actions, and you secure it the way professional teams do: pinned actions,
least-privilege permissions, and automatic updates.

## The idea

A GitHub Actions setup has three levels:

| Level | What it is | In this chapter |
|---|---|---|
| **Workflow** | A YAML file in `.github/workflows/`; runs when an event happens | `ci.yml` |
| **Job** | A unit of work on its own fresh virtual machine (a **runner**) | `lint`, `security`, `test`, `docker` |
| **Step** | One command (`run:`) or one reusable **action** (`uses:`), run in order | `cargo test`, `actions/checkout` |

Two rules explain most of how workflows behave:

- **Jobs run in parallel** by default, each on a separate, empty machine. They
  share nothing unless you pass it explicitly.
- **`needs:` creates order.** A job with `needs: [a, b]` waits until `a` and `b`
  succeed, and is **skipped** if either fails.

The pipeline you will build:

```text
            ┌──────────┐
            │  lint    │──┐
            └──────────┘  │
            ┌──────────┐  │    ┌──────────┐
 PR / push ─│ security │──┼───▶│  docker  │
            └──────────┘  │    └──────────┘
            ┌──────────┐  │
            │  test    │──┘
            └──────────┘
```

The three checks run in parallel for fast feedback. The Docker build only runs
when all of them pass, so a broken commit never produces an image. In the next
chapter, the `docker` job also pushes the image to Amazon ECR.

## Step 1: The workflow file

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

# Least privilege: the token can only read the repository
permissions:
  contents: read

# One run per branch or PR; new commits on a PR cancel the older run
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

env:
  CARGO_TERM_COLOR: always

jobs:
  lint:
    name: Format & Clippy
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: dtolnay/rust-toolchain@89b12181fb390509a0842a86cc55eeb8eb928c1d # stable
        with:
          components: rustfmt, clippy
      - uses: Swatinem/rust-cache@6323deb102c322ba6fcbdcafc7e3dddab59af2b6 # v2.9.2
      - run: cargo fmt --all -- --check
      - run: cargo clippy --all-targets --locked -- -D warnings

  security:
    name: Dependency audit
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: EmbarkStudios/cargo-deny-action@3c6349835b2b7b196a839186cb8b78e02f7b5f25 # v2.1.1
        with:
          command: check advisories

  test:
    name: Tests (with Postgres)
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_USER: app
          POSTGRES_PASSWORD: app
          POSTGRES_DB: app
        ports:
          - 5432:5432
        options: >-
          --health-cmd "pg_isready -U app -d app"
          --health-interval 5s
          --health-timeout 3s
          --health-retries 10
    env:
      DATABASE_URL: postgres://app:app@localhost:5432/app
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: dtolnay/rust-toolchain@89b12181fb390509a0842a86cc55eeb8eb928c1d # stable
      - uses: Swatinem/rust-cache@6323deb102c322ba6fcbdcafc7e3dddab59af2b6 # v2.9.2
      - run: cargo test --locked -- --include-ignored

  docker:
    name: Build Docker image
    needs: [lint, security, test]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: docker/setup-buildx-action@f87e5991a6d7451dcb8d9637bfbc97413f497069 # v4.4.1
      - uses: docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc # v7.4.0
        with:
          context: .
          push: false
          tags: rust-devops-app:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

The rest of this chapter explains it, section by section.

## Triggers, permissions, and concurrency

```yaml
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:
```

The workflow runs on pushes to `main` (including merges), on pull requests
**targeting** `main`, and manually, through a **Run workflow** button that
`workflow_dispatch` adds to the Actions tab. For pull requests, `branches`
filters by the **target** branch, not the branch the changes come from.

A pull request run does **not** happen after merging. Merging creates a push to
`main`, which triggers the workflow again through the `push` trigger.

```yaml
permissions:
  contents: read
```

Every job receives a temporary `GITHUB_TOKEN`. This line limits it to reading the
repository. Once you write a `permissions` block, every permission you do not
list becomes `none`. If a malicious dependency or action ever ran in your
pipeline, the token could not push code, change releases, or edit issues.

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

Runs with the same group name never run in parallel. The group combines the
workflow name with the Git reference, for example `CI-refs/pull/5/merge` or
`CI-refs/heads/main`. When you push several commits to a pull request quickly,
the newest run **cancels** the older ones, so only the latest code is tested. On
`main`, runs **queue** instead, because cancelling a pipeline halfway through
pushing an image or deploying would be worse than waiting.

`${{ ... }}` is GitHub's **expression syntax**. It inserts values at runtime from
**contexts** such as `github` (information about the event), `env`, `vars`, and
`secrets`.

## The `lint` job

```yaml
  lint:
    name: Format & Clippy
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@... # v7.0.1
        with:
          persist-credentials: false
      - uses: dtolnay/rust-toolchain@... # stable
        with:
          components: rustfmt, clippy
      - uses: Swatinem/rust-cache@... # v2.9.2
      - run: cargo fmt --all -- --check
      - run: cargo clippy --all-targets --locked -- -D warnings
```

- **`runs-on: ubuntu-latest`** asks GitHub for a fresh Ubuntu virtual machine.
- **`actions/checkout`** clones your repository onto that empty machine. Almost
  every job starts with it; only steps that read your files need it first.
- **`persist-credentials: false`** stops checkout from leaving the Git token on
  disk afterwards. The jobs only need to read the code once, so there is no
  reason to keep a credential lying around for later steps.
- **`dtolnay/rust-toolchain`** installs Rust plus `rustfmt` and `clippy`.
- **`Swatinem/rust-cache`** caches compiled dependencies between runs. Without
  it, every run would compile Tokio, Axum, and sqlx from scratch.
- **`cargo fmt -- --check`** changes nothing; it fails if code is not formatted.
- **`-D warnings`** turns every Clippy warning into an error, so warnings cannot
  slowly accumulate on `main`.

Everything under `with:` is an **input** of that particular action. Each action
defines its own input names (`components`, `command`, `tool`, ...), listed in the
`action.yml` file of its repository. A misspelled input is usually **silently
ignored**, which is worth remembering when debugging.

## The `security` job

```yaml
      - uses: EmbarkStudios/cargo-deny-action@... # v2.1.1
        with:
          command: check advisories
```

[cargo-deny](https://github.com/EmbarkStudios/cargo-deny) checks every crate in
`Cargo.lock` against the [RustSec advisory database](https://rustsec.org/) of
known vulnerabilities, unmaintained crates, and yanked versions. It needs no
Rust toolchain or cache, because it only reads `Cargo.lock`, so this job runs in
seconds. `cargo-deny` can also check licenses and banned crates later, configured
in a `deny.toml` file.

## The `test` job

```yaml
    services:
      postgres:
        image: postgres:16
        ...
        options: >-
          --health-cmd "pg_isready -U app -d app"
          ...
    env:
      DATABASE_URL: postgres://app:app@localhost:5432/app
```

**`services:`** starts a PostgreSQL container next to the job, much like the `db`
service in Docker Compose. `ports: 5432:5432` makes it reachable at
`localhost:5432`. The **health check options** are essential: GitHub waits until
`pg_isready` succeeds before running your steps. Without them, tests could start
before the database accepts connections and fail at random, a classic cause of
"flaky" pipelines.

The password is plain text in the file. That is acceptable only because this is
a throwaway database that exists for the few minutes of the job. Real
credentials always belong in GitHub **secrets** or, better, are never needed at
all, as the next chapter shows.

`cargo test --locked -- --include-ignored` also runs the integration test marked
`#[ignore]`, because here a real database is available. Everything after `--` is
passed to the test runner instead of Cargo.

## The `docker` job

```yaml
  docker:
    name: Build Docker image
    needs: [lint, security, test]
```

The `needs` line is the **quality gate**: no image is built unless formatting,
Clippy, the dependency audit, and all tests pass.

- **`docker/setup-buildx-action`** enables BuildKit, Docker's modern build
  engine, which supports the cache options below.
- **`docker/build-push-action`** builds the image from your Dockerfile.
  `push: false` means the image is only built, which proves on every pull request
  that the Dockerfile still works.
- **`cache-from` and `cache-to: type=gha`** store Docker layers in GitHub's cache,
  so the slow `cargo chef cook` layer from the previous chapter is reused across
  runs. `mode=max` caches the intermediate build stages too, not just the final
  image.
- The tag uses **`github.sha`**, the commit hash, so every image is traceable to
  the exact code it was built from.

## Step 2: Pin your actions to commit SHAs

Look closely at how actions are referenced in the workflow:

```yaml
- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
```

instead of the shorter, more common form:

```yaml
- uses: actions/checkout@v7
```

### Why pinning matters

A third-party action is **code that runs inside your pipeline**, with access to
your repository and to any credentials the job has. A tag like `v7` is just a
movable label in someone else's repository: whoever controls that repository can
point it at different code at any time, and your next run would execute it
without any change on your side.

This is not a theoretical risk. In March 2025, attackers compromised the popular
`tj-actions/changed-files` action and moved its version tags to a malicious
commit. Thousands of repositories that referenced it by tag ran the malicious
code, which dumped CI secrets into build logs.

A **full commit SHA** cannot be moved. `3d3c42e5...` always means exactly the
same code. The comment after `#` records the human-readable version, so you and
your tools still know which release it is.

### How to find the SHA for a version

You can look it up on the action's **Releases** page on GitHub, or from the
command line with `git ls-remote`:

```bash
git ls-remote https://github.com/actions/checkout.git 'refs/tags/v7.0.1*'
```

If the output has two lines, one ending in `^{}`, use the SHA on the `^{}` line:
that is the commit itself, while the other line is an annotated tag object. If
there is only one line, use that SHA.

Pin to a **full release version** (`v7.0.1`), not a major-version tag (`v7`).
Major-version tags move with every release, so their SHA changes too.

**One special case:** `dtolnay/rust-toolchain` has no version tags. Instead, its
**branches** select the toolchain (`stable`, `nightly`, `1.89.0`). Pin the latest
commit of the `stable` branch, and it still installs the current stable Rust at
run time:

```bash
git ls-remote https://github.com/dtolnay/rust-toolchain.git refs/heads/stable
```

### Keep pinned actions updated with Dependabot

Pinning has one downside: you no longer get updates automatically, including
security fixes. **Dependabot** solves this. Create `.github/dependabot.yml`:

```yaml
version: 2
updates:
  # Keep pinned GitHub Actions up to date (updates the SHA and the version comment)
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    groups:
      github-actions:
        patterns: ["*"]

  # Keep Rust dependencies up to date
  - package-ecosystem: cargo
    directory: /
    schedule:
      interval: weekly
```

Once a week, Dependabot checks for new releases. When it finds one, it opens a
pull request that updates **both** the SHA and the version comment. Your CI runs
on that pull request like on any other, so you see whether the update breaks
anything before you merge it. `groups` combines all action updates into one pull
request instead of one per action. The second entry does the same for your
Rust crates in `Cargo.toml`.

Dependabot reads the `# v7.0.1` comments to know which version a SHA represents.
Keep them accurate, and write them exactly in this form.

## Step 3: Run it

Commit both files on a branch, push, and open a pull request into `main`:

```bash
git switch -c add-ci
git add .github/
git commit -m "Add CI workflow with pinned actions"
git push -u origin add-ci
```

On the pull request page, scroll to the checks section. `Format & Clippy`,
`Dependency audit`, and `Tests (with Postgres)` start at the same time; `Build
Docker image` starts when all three are green. Click **Details** on any check to
see the full log of each step.

The first run is slow, because the caches are empty. Push another small commit,
and compare the times: the Rust cache and the Docker layer cache both kick in.

## Step 4: Make the checks required

A green check is only useful if a red one blocks the merge. In your repository,
go to **Settings → Branches** (or **Rules → Rulesets**) and add a rule for
`main`:

- Require a pull request before merging.
- Require status checks to pass, and select `Format & Clippy`,
  `Dependency audit`, `Tests (with Postgres)`, and `Build Docker image`.

Now nobody, including you, can merge code that fails CI.

## Step 5: Break things on purpose

The best way to understand a pipeline is to watch it fail. On your branch, try
each of these, push, and read which job fails and why:

1. Add extra spaces in `src/lib.rs`. `Format & Clippy` fails at `cargo fmt`, and
   `Build Docker image` is **skipped**, not failed.
2. Add an unused variable. Clippy fails because of `-D warnings`.
3. Change an assertion in `tests/api.rs` so it fails. Only `Tests` fails.
4. Remove the `options:` health check from the Postgres service and push a few
   times. Does the test job become unreliable?
5. Add a step `- run: echo "event=${{ github.event_name }} ref=${{ github.ref }}"`
   and compare its output on a pull request and after merging.

Revert each change afterwards.

## Troubleshooting

These all happened while building this project.

**`Invalid workflow file` in the Actions tab.** Almost always YAML indentation.
YAML uses spaces, never tabs, and each level must be consistent. The error
message names the line. Running [actionlint](https://github.com/rhysd/actionlint)
locally catches this before you push.

**`Unable to resolve action action/checkout, repository not found`.** A typo in
the action name: the organisation is `actions`, plural. With SHA pinning, also
check that you copied the full 40-character SHA.

**A step behaves as if an input were missing.** A misspelled input name is
ignored without an error. In this project, `commmand: check advisories` (three
m's) made cargo-deny run its default command, which checks licenses too and
failed without a `deny.toml`. Compare your input names with the action's
`action.yml`.

**`The job was not acquired by Runner of type hosted even after multiple attempts`.**
Not your fault: GitHub could not provide a runner. Check
[githubstatus.com](https://www.githubstatus.com), wait, and use **Re-run jobs**.

**Tests fail with `connection refused` on port 5432.** The service container was
not ready, or not reachable. Check the health check options and the `ports`
mapping, and that `DATABASE_URL` uses `localhost`. (Inside a job, the service is
on `localhost`; in Docker Compose, it is the service name.)

**`the lock file needs to be updated but --locked was passed`.** `Cargo.lock` is
out of date or not committed. Run `cargo build` locally and commit `Cargo.lock`.

**`cargo deny` reports an advisory.** Read the advisory ID in the output. Usually
`cargo update -p <crate>` pulls in a patched version; commit the updated
`Cargo.lock`. If no fix exists yet, you can document an exception in a
`deny.toml` file, with a reason.

**The workflow runs twice for one push.** Two workflow files both trigger on the
same event, or one workflow has both `push` and `pull_request` triggers for the
same branch with a pull request open. Each matching trigger starts its own run.

## What you learned

- How workflows, jobs, and steps relate, and why jobs run in parallel on separate
  machines.
- How `needs` creates a quality gate, and why skipped jobs protect you.
- How triggers, `permissions`, and `concurrency` shape when and how a workflow runs.
- How service containers give tests a real database, and why health checks matter.
- Why third-party actions should be pinned to full commit SHAs, and how
  Dependabot keeps them updated.
- How required status checks turn CI from advice into a rule.

## Practice

1. Add a `shellcheck` job that lints shell scripts once you have some in a
   `scripts/` folder. ShellCheck is preinstalled on GitHub's Ubuntu runners.
2. Add an [actionlint](https://github.com/rhysd/actionlint) step that checks your
   workflow files themselves.
3. Find the SHA for `taiki-e/install-action` yourself with `git ls-remote`, and
   use it to install `cargo-nextest`. Then switch the test job to `cargo nextest run`.
4. Add a `paths-ignore` filter so the workflow does not run when only Markdown
   files change. What are the risks of path filters on required checks?
5. Use a `strategy.matrix` to run the test job on both `stable` and `beta` Rust.

## Interview questions

- Why do the lint, security, and test jobs run in parallel, and why does the
  Docker build wait for them?
- What does `permissions: contents: read` protect against?
- Why pin GitHub Actions to commit SHAs instead of version tags? What is the
  downside, and how do you handle it?
- How do you give integration tests a real database in CI, and how do you avoid
  flaky tests while it starts?
- What happens to a job whose `needs` dependency fails?
- Why might you cancel in-progress runs on pull requests but not on `main`?
- How do you make sure nobody can merge code that fails CI?
