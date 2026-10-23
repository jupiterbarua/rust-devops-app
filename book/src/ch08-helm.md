# Packaging with Helm

At the end of the last chapter the application ran on Kubernetes, but deploying
it took a list of manual steps: create two Secrets, find the newest image tag,
replace a placeholder with `sed`, apply a file, restart the pods when the
database changed. Every step is a chance to forget something, and nothing
records which version of the whole set is running.

**Helm** fixes this. It turns the YAML from Chapter 7 into a **chart**: templates
plus a file of settings. One command installs or upgrades everything, Helm
remembers every version it deployed, and one command rolls all of it back. This
chapter converts `k8s/app.yaml` into the chart that the rest of the book uses.

> **Time and typing**
>
> | | |
> |---|---|
> | Reading | 40 min |
> | Hands-on | 75 min |
> | Practice | 60 min |
> | Cost | the k3s server from Chapter 7 while it runs (about 2.5 to 10 cents per hour) |
>
> **Copy:** `Chart.yaml`, `values.yaml`, and the Service, Ingress and Secret templates.
> **Type yourself:** in `templates/deployment.yaml`, the `image:` line, the
> `imagePullSecrets` block and the `resources` block (about 10 lines). They use
> the three template features you will meet in every chart: `required`, `with`
> and `toYaml | nindent`. Type every `helm` command too; they are short, and
> `helm template`, `helm history` and `helm rollback` are worth knowing by heart.

## The idea

Three words matter in Helm:

| Word | Meaning | Analogy |
|---|---|---|
| **Chart** | a folder of templates and default settings | a recipe |
| **Release** | one installation of a chart in a cluster, with a name | a dish cooked from the recipe |
| **Revision** | one version of a release; every install, upgrade and rollback adds one | the photo of the dish each time you changed it |

The flow looks like this:

```text
 values.yaml  ─┐
 -f file.yaml ─┼──▶ templates/*.yaml ──▶ plain Kubernetes YAML ──▶ kubectl-style apply
 --set a=b    ─┘     (Go templates)       (what Chapter 7 wrote)      + revision stored
                                                                       in the cluster
```

Helm does not add new kinds of objects to your cluster. What it creates are the
same Deployment, Service, Ingress and Secret you wrote by hand. The difference
is that the image tag, the replica count and the database Secret's name are now
**values** that you set per installation, and that Helm stores every revision
as a Secret in the namespace, so it can show the history and go back.

Helm is to Kubernetes YAML roughly what Terraform variables are to `.tf`
files, plus a deployment history.

## Step 1: Check Helm on the server

Helm was installed by `user_data` in Chapter 7. Connect with Session Manager
and check:

```bash
bash
cd ~/rust-devops-app && git pull
helm version
```

You get either `v3.x` or `v4.x`. Everything in this chapter works with both;
where they differ, the text says so.

Helm uses the same kubeconfig as `kubectl` (`KUBECONFIG`, set in
`/etc/bash.bashrc`), so it talks to your k3s cluster with no extra setup.

## Step 2: The chart skeleton

A chart is a folder with a fixed layout:

```text
charts/rust-app/
├── Chart.yaml          # name and version of the chart
├── values.yaml         # default settings
└── templates/          # Kubernetes YAML with placeholders
    ├── deployment.yaml
    ├── service.yaml
    ├── ingress.yaml
    └── secret.yaml
```

`helm create` can generate a chart for you, but it produces about ten files of
generic templates that are hard to read for a beginner. Writing the four files
yourself from the YAML you already understand is quicker to learn from.

All files in this chapter are created **on your laptop**, committed, pushed,
and pulled on the server, as in Chapter 7.

Create `charts/rust-app/Chart.yaml`:

```yaml
apiVersion: v2
name: rust-app
description: Rust Axum API with PostgreSQL
type: application
version: 0.1.0
appVersion: "0.2.0"
```

There are two versions, and they mean different things:

- **`version`** is the version of the **chart**: the templates and defaults.
  Change it when you change the chart.
- **`appVersion`** is the version of the **application** the chart deploys by
  default. It is informational; `helm list` shows it. Here, the image tag is
  set at deploy time, so `appVersion` is only a label.

`apiVersion: v2` means a chart for Helm 3 or later.

## Step 3: The settings (`values.yaml`)

Create `charts/rust-app/values.yaml`. Every value is something that can differ
between installations:

```yaml
replicaCount: 2

image:
  repository: ""   # set at deploy time
  tag: ""          # set at deploy time
  pullPolicy: IfNotPresent

imagePullSecrets:
  - name: ecr-credentials

containerPort: 8080

# Learning only: points to the in-cluster Postgres
databaseUrl: postgres://app:app@postgres:5432/app

# Name of an existing Secret containing DATABASE_URL.
# If set, the chart uses it instead of creating its own.
existingSecret: ""

# Fingerprint of external config; when it changes, pods restart.
configChecksum: ""

service:
  port: 80

ingress:
  enabled: true
  className: traefik
  host: ""         # empty = match any host
  annotations: {}

resources:
  requests:
    cpu: 50m
    memory: 32Mi
  limits:
    memory: 128Mi
```

Compare it with `k8s/app.yaml` from Chapter 7: every number and name you
might want to change is here, and nothing else is. The image repository and tag
are empty on purpose. They are different for every account and every
deployment, so they are passed in on the command line, and the chart refuses to
render without them (Step 4).

> **If you are reading this in the finished repository**, the chart there also
> has a `metrics:` block in `values.yaml`, three more templates
> (`servicemonitor.yaml`, `prometheusrule.yaml`, `dashboard-configmap.yaml`) and a
> `dashboards/` folder. They belong to the Monitoring chapter. Leave them as they
> are: they switch themselves off on a cluster without the monitoring stack.

## Step 4: The templates

Helm templates are Kubernetes YAML with **Go template** expressions inside
`{{ }}`. Four things are available in every template:

| Expression | Value |
|---|---|
| `.Values.x` | the setting `x` from `values.yaml`, `-f` files and `--set` |
| `.Release.Name` | the release name you chose (`rust-app`) |
| `.Release.Namespace` | the namespace it is installed in |
| `.Chart.Version` | the `version` from `Chart.yaml` |

### The Deployment

Create `charts/rust-app/templates/deployment.yaml`. Paste it, and type the
three marked blocks yourself:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  labels:
    app: {{ .Release.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/secret.yaml") . | sha256sum }}
        checksum/external: {{ .Values.configChecksum | quote }}
    spec:
      {{- with .Values.imagePullSecrets }}          # type this block
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: app
          # type this line:
          image: "{{ required "image.repository is required" .Values.image.repository }}:{{ required "image.tag is required" .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: {{ .Values.containerPort }}
          envFrom:
            - secretRef:
                name: {{ .Values.existingSecret | default (printf "%s-config" .Release.Name) }}
          livenessProbe:
            httpGet:
              path: /health
              port: {{ .Values.containerPort }}
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /ready
              port: {{ .Values.containerPort }}
            periodSeconds: 5
          resources:                                   # type this block
            {{- toYaml .Values.resources | nindent 12 }}
```

(Leave out the `# type this` comments in your file; a comment after
`{{- with ... }}` ends up in the rendered YAML.)

It is the Deployment from Chapter 7, with the fixed values replaced. The
template features, from simple to less simple:

**`{{ .Release.Name }}`** replaces the hard-coded `rust-app`. Install the same
chart twice under different release names, and you get two independent
applications whose labels do not collide.

**`required "message" .Values.image.repository`** stops rendering with that
message if the value is empty. Without it, an empty value would produce
`image: ":"`, and you would only find out from an `InvalidImageName` error in
the cluster. Failing early, before anything is sent to Kubernetes, is always
better.

**`{{- with .Values.imagePullSecrets }} ... {{- end }}`** renders the block only
if the value is not empty, and inside it `.` means that value. On EKS
(Chapter 10) the nodes pull from ECR with their IAM role, the list is empty, and
the whole `imagePullSecrets:` key disappears.

**`toYaml . | nindent 8`** turns a value (here a list, for `resources` a map)
back into YAML, starts a new line, and indents every line by 8 spaces. The pipe
`|` passes the result of one function to the next, as in a shell. The number
must match the indentation where the block lands; getting it wrong is the most
common Helm error (see Troubleshooting).

**`{{-` with a dash** removes the whitespace and newline before the
expression. Without it, `with` and `end` would leave empty lines in the output.
It does not change the meaning, only the tidiness of the YAML.

**`default (printf "%s-config" .Release.Name)`**: if `existingSecret` is empty,
use the name `rust-app-config`, a Secret the chart creates itself (below).
Otherwise use the Secret someone created outside Helm. Step 6 explains why you
want that.

**The two `checksum/` annotations** solve a problem you met in Chapter 7: a
changed Secret does not restart the pods. Annotations on the **pod template**
are part of the pod's definition, so when an annotation's value changes,
Kubernetes sees a new pod template and performs a rolling update:

- `checksum/config` is the SHA-256 of the rendered `secret.yaml`. If the chart's
  own Secret changes, the hash changes, and the pods restart.
- `checksum/external` is a value passed in from outside. The deploy script in
  Chapter 9 sets it to a hash of the database URL it put into the external
  Secret. Same effect, for a Secret Helm does not own.

### The Service, Ingress and Secret

Paste these three files. They contain nothing new except `if`.

`charts/rust-app/templates/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
  labels:
    app: {{ .Release.Name }}
spec:
  selector:
    app: {{ .Release.Name }}
  ports:
    - name: http
      port: {{ .Values.service.port }}
      targetPort: {{ .Values.containerPort }}
```

`charts/rust-app/templates/ingress.yaml`:

```yaml
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Release.Name }}
  {{- with .Values.ingress.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  ingressClassName: {{ .Values.ingress.className }}
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ .Release.Name }}
                port:
                  number: {{ .Values.service.port }}
      {{- with .Values.ingress.host }}
      host: {{ . | quote }}
      {{- end }}
{{- end }}
```

`charts/rust-app/templates/secret.yaml`:

```yaml
{{- if not .Values.existingSecret }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ .Release.Name }}-config
type: Opaque
stringData:
  DATABASE_URL: {{ .Values.databaseUrl | quote }}
{{- end }}
```

`if` renders a file or a block only when the condition holds, so one chart
covers several situations:

- `ingress.enabled: false` installs the application without an Ingress, which
  is useful for internal services.
- The Ingress annotations are empty for Traefik, but the ALB on EKS
  (Chapter 11) is configured almost entirely through annotations. The same
  template serves both.
- `secret.yaml` renders **only** when no `existingSecret` is given. With the
  in-cluster database, the chart creates the Secret from `databaseUrl`. With
  RDS, the real Secret is created outside Helm, and this file renders to
  nothing.

`| quote` wraps a value in double quotes. Use it for strings that YAML might
otherwise misread: a URL with `:` and `?`, a host name, or a value such as
`"true"` or `"0123"`.

## Step 5: Render without a cluster

Before installing anything, look at what the chart produces. Push the chart from
your laptop, then on the server:

```bash
git pull
helm lint charts/rust-app --set image.repository=x --set image.tag=y
```

`helm lint` checks the chart's structure and renders it once. It should end with
`1 chart(s) linted, 0 chart(s) failed`. Now try it without the image values:

```bash
helm template rust-app charts/rust-app
```

```text
Error: execution error at (rust-app/templates/deployment.yaml:...): image.repository is required
```

That is `required` doing its job. With values, `helm template` prints the plain
YAML that would be sent to the cluster:

```bash
helm template rust-app charts/rust-app --set image.repository=REPO --set image.tag=TAG
```

Read the output from top to bottom. You will find the `rust-app-config`
Secret, the Service, the Deployment with `image: "REPO:TAG"` and the two
checksum annotations, and the Ingress: almost exactly `k8s/app.yaml`. Now
compare the effect of one value:

```bash
helm template rust-app charts/rust-app --set image.repository=REPO --set image.tag=TAG \
  --set existingSecret=rust-app-db | grep -E '^kind:|name: rust-app'
```

The `Secret` is gone, and the Deployment's `secretRef` now points to
`rust-app-db`.

`helm template` is the most useful Helm command for learning and debugging. It
needs no cluster, changes nothing, and shows exactly what a change in the chart
or the values does.

## Step 6: Hand the application over to Helm

The objects from Chapter 7 still exist, created by `kubectl apply`. Helm will
not take over objects it did not create (Troubleshooting has the error message),
so delete them first. The database Secret, the ECR pull secret and, if you still
use it, the in-cluster PostgreSQL stay:

```bash
kubectl config set-context --current --namespace=rust-app
kubectl delete deployment,service,ingress rust-app
kubectl get all
```

Your application is now offline for a few minutes. That is acceptable here; in
Practice exercise 5 you learn how to adopt existing objects without downtime.

Next, the values for this installation. Paste the block from Chapter 7, Step 6
again if this is a new session, so that `REGISTRY`, `TAG` and `REGION` are set,
and refresh the pull secret (it expires after 12 hours). Then check what you
have:

```bash
echo "$REGISTRY/rust-devops-app:$TAG"
kubectl get secret ecr-credentials rust-app-db
```

Both Secrets must exist. `rust-app-db` holds the `DATABASE_URL`, pointing to
RDS or to the in-cluster PostgreSQL, whichever you used last in Chapter 7.

Now install:

```bash
helm upgrade --install rust-app charts/rust-app \
  --namespace rust-app \
  --set image.repository="$REGISTRY/rust-devops-app" \
  --set image.tag="$TAG" \
  --set existingSecret=rust-app-db \
  --wait --timeout 5m
```

Each part of the command:

| Part | Meaning |
|---|---|
| `upgrade --install` | upgrade the release if it exists, install it if not. One command for the first and every later deployment, which is what scripts need |
| `rust-app` | the release name, which becomes `.Release.Name` |
| `charts/rust-app` | the chart folder |
| `--set` | override values from `values.yaml` |
| `existingSecret=rust-app-db` | use the database Secret from Chapter 7; the chart creates no Secret of its own |
| `--wait` | do not return until the pods are ready (or the timeout expires) |
| `--timeout 5m` | how long `--wait` waits |

Without `--wait`, Helm returns as soon as Kubernetes has **accepted** the
objects, and the release shows `deployed` even if the pods then crash. With
`--wait`, a deployment that never becomes ready ends as `failed`, and the
command's exit code says so, which matters as soon as a pipeline runs it.

Check the result:

```bash
helm list
kubectl get pods,svc,ingress
curl -s http://localhost/health
```

`helm list` shows the release with `REVISION 1`, `STATUS deployed`, the chart
`rust-app-0.1.0` and the app version `0.2.0`. On your laptop,
`curl http://<k3s_public_ip>/items` works again, and the items you created are
still there if you were using RDS.

## Step 7: Look inside a release

Helm can show you everything about a release. These commands answer the
questions you will have during every incident:

```bash
helm status rust-app                # state, revision, time of last deployment
helm get values rust-app            # the values YOU passed (not the defaults)
helm get values rust-app --all      # all values, defaults included
helm get manifest rust-app | less   # the exact YAML that was applied
helm history rust-app               # all revisions
```

`helm get values` is the quickest answer to "which image is running?" and
"which settings did the last deployment use?".

Where does Helm keep all this? In the cluster, in the release's namespace:

```bash
kubectl get secrets -l owner=helm
```

```text
NAME                             TYPE                 DATA   AGE
sh.helm.release.v1.rust-app.v1   helm.sh/release.v1   1      3m
```

One Secret per revision, holding the rendered manifest and the values,
compressed. There is no Helm server and no database: delete these Secrets, and
Helm forgets the release, while the application keeps running. By default Helm
keeps the last 10 revisions (`--history-max`).

## Step 8: Upgrades and rollbacks

List a few image tags, and pick an older one:

```bash
aws ecr describe-images --repository-name rust-devops-app --region $REGION \
  --query 'sort_by(imageDetails[?imageTags], &imagePushedAt)[-3:].imageTags[0]' --output text
```

Upgrade to it, using `--reuse-values` so that you only have to pass what
changes:

```bash
helm upgrade rust-app charts/rust-app --reuse-values --set image.tag=<older-tag> --wait
helm history rust-app
```

The history now shows two revisions: the first `superseded`, the second
`deployed`. Under the hood this was the same rolling update as
`kubectl set image` in Chapter 7. The difference: the change is recorded with
its values, and you can roll back **everything** in the release at once, not
only the image:

```bash
helm rollback rust-app 1 --wait
helm history rust-app
```

A rollback is not a time machine. It creates a **new** revision (3) with the
contents of revision 1. History only ever grows, which is what you want when
you reconstruct an incident afterwards.

### A failed upgrade

Deploy an image that does not exist, as in Chapter 7, but now with Helm:

```bash
helm upgrade rust-app charts/rust-app --reuse-values --set image.tag=does-not-exist --wait --timeout 90s
echo "exit code: $?"
helm history rust-app
```

After 90 seconds Helm gives up: `Error: UPGRADE FAILED: context deadline
exceeded`, exit code `1`, and the revision is marked `failed`. The application
still works (`curl -s http://localhost/health`), for the same reason as in
Chapter 7: `maxUnavailable: 0` keeps the old pods until new ones are ready.
But the cluster now contains a stuck new ReplicaSet. Roll back to the last good
revision:

```bash
helm rollback rust-app --wait
```

Without a revision number, `rollback` goes to the previous one.

Helm can do this for you. With `--atomic` (Helm 3) or `--rollback-on-failure`
(the Helm 4 name for the same option), a failed upgrade is rolled back
automatically before the command returns. It is a sensible default for
pipelines; the Lessons Learned chapter discusses when you might not want it.

## Step 9: Values files and precedence

`--set` is fine for one or two values. For a group of settings that belong
together, such as "everything that is different on EKS", use a values file.
The finished repository has `charts/rust-app/values-eks.yaml`:

```yaml
# Overrides for EKS. Use with: -f charts/rust-app/values-eks.yaml

# EKS nodes pull from ECR with their IAM role: no pull secret needed
imagePullSecrets: []

ingress:
  enabled: true
  className: alb
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /ready
```

You will use it in Chapter 11. For now, look at what it would change, without
installing anything:

```bash
helm template rust-app charts/rust-app --set image.repository=R --set image.tag=T \
  -f charts/rust-app/values-eks.yaml | grep -A12 '^kind: Ingress'
```

When the same value is set in several places, the **last one wins**:

```text
 values.yaml  <  -f first.yaml  <  -f second.yaml  <  --set
 (weakest)                                              (strongest)
```

Maps are **merged**: `values-eks.yaml` changes `ingress.className`, and
`ingress.host` keeps its default. Lists are **replaced** as a whole: setting
`imagePullSecrets: []` removes the default entry completely. Remember that
difference; it explains most "why is my value ignored?" questions.

## Step 10: Restart on configuration change

Watch the checksum annotations at work. Look at the current pods, then change
nothing but `configChecksum`:

```bash
kubectl get pods
helm upgrade rust-app charts/rust-app --reuse-values --set configChecksum=test-1 --wait
kubectl get pods
```

The pods have new names: the changed annotation triggered a rolling update. Run
the same command again with the same value, and nothing restarts, because the
pod template is identical. This is how the deploy script in the next chapter
restarts the pods exactly when the database URL changed, and not on every
deployment.

## Step 11: Clean up

Remove the release with:

```bash
helm uninstall rust-app
```

It deletes every object the release created, and its history. The Secrets you
created with `kubectl` stay, because Helm never owned them.

At the end of the session, destroy the server and the database from your
laptop, as in Chapter 7:

```bash
terraform destroy -target=aws_instance.k3s -target=aws_db_instance.main
```

## Troubleshooting

All of these happened while building this project.

**`Error: INSTALLATION FAILED: rendered manifests contain a resource that already exists. Unable to continue with install: Service "rust-app" in namespace "rust-app" exists and cannot be imported into the current release: invalid ownership metadata`.**
An object with the same name was created outside Helm, usually by
`kubectl apply` in Chapter 7. Helm only manages objects carrying its labels and
annotations. Delete the old object (Step 6), or adopt it (Practice 5).

**`Error: Kubernetes cluster unreachable: Get "http://localhost:8080/version": dial tcp 127.0.0.1:8080: connect: connection refused`.**
Helm did not find a kubeconfig. Same cause and fix as for `kubectl` in
Chapter 7: start `bash`, or `export KUBECONFIG=/etc/rancher/k3s/k3s.yaml`. It
happens most often in scripts and SSM commands, which do not read
`/etc/bash.bashrc`.

**`error converting YAML to JSON: yaml: line 31: did not find expected key`.**
The rendered YAML is badly indented, nearly always because of a wrong number in
`nindent`. Run `helm template ... --debug`: it prints the broken output, so you
can see where the block landed. Count the spaces to the parent key, add two,
and use that number.

**`Error: UPGRADE FAILED: another operation (install/upgrade/rollback) is in progress`.**
A previous command was interrupted (`Ctrl+C`, a closed Session Manager tab, a
cancelled pipeline) while the release was `pending-upgrade`. Check
`helm history rust-app`. If no other Helm command is really running, roll back
to the last `deployed` revision with `helm rollback rust-app <revision>`, which
clears the pending state.

**`Error: UPGRADE FAILED: context deadline exceeded`.**
`--wait` timed out: the new pods never became ready. Helm's message says
nothing about why. Use the debugging map from Chapter 7: `kubectl get pods`,
then `describe` and `logs` on the new pod.

**`helm upgrade` succeeded, but the application still uses the old database
password.** The external Secret changed, but the pod template did not, so
nothing restarted. Pass a new `configChecksum` (Step 10), or run
`kubectl rollout restart deployment/rust-app`. The deploy script in Chapter 9
does the first automatically.

**A `--set` value with dots or commas ends up in the wrong place.** `--set`
treats `.` as nesting and `,` as a separator between values. An annotation key
such as `alb.ingress.kubernetes.io/inbound-cidrs` must have its dots escaped:
`--set-string "ingress.annotations.alb\.ingress\.kubernetes\.io/inbound-cidrs=1.2.3.4/32"`.
For anything more complicated, use a values file instead.

**`--reuse-values` does not pick up a new default from `values.yaml`.**
`--reuse-values` takes the values of the last revision and ignores the chart's
defaults, including new ones you just added. Pass all values explicitly (as the
deploy script does), or use `--reset-then-reuse-values` (Helm 3.14 and later),
which starts from the chart's defaults and then applies the previous values.

## What you learned

- What charts, releases and revisions are, and that Helm renders plain
  Kubernetes YAML and stores each revision as a Secret in the cluster.
- How to turn fixed YAML into templates with `.Values`, `.Release.Name`,
  `required`, `default`, `quote`, `with`, `if` and `toYaml | nindent`.
- Why `required` should guard values that have no sensible default.
- How `helm lint` and `helm template` let you check a chart without a cluster.
- How `helm upgrade --install --wait` installs and upgrades in one command,
  and why `--wait` makes failures visible.
- How to inspect a release (`status`, `get values`, `get manifest`, `history`)
  and how rollbacks create new revisions.
- How values files override defaults: last one wins, maps merge, lists are
  replaced.
- How checksum annotations restart pods exactly when configuration changes.

## Practice

Each exercise says how long it takes and how much you type.

1. **A second release** (15 min, one command). Install the same chart again as
   `rust-app-2` with `ingress.enabled=false` and `replicaCount=1`. List
   everything with `kubectl get all`. Which names come from `.Release.Name`?
   Uninstall it afterwards.
2. **Break the indentation** (10 min, change 1 number). Change `nindent 12` to
   `nindent 10` in the Deployment, and run `helm template`. Read the error,
   then run it again with `--debug` and find the broken lines. Undo the change.
3. **Add a value** (20 min, about 8 lines). Add `env:` to `values.yaml` as a map
   (for example `RUST_LOG: info`) and render it into the container as
   `env:` entries with a `range` loop:
   `{{- range $k, $v := .Values.env }}` … `{{- end }}`. Deploy with
   `--set env.RUST_LOG=debug` and check the logs.
4. **Diff before upgrading** (15 min, 2 commands). Install the
   [helm-diff](https://github.com/databus23/helm-diff) plugin and run
   `helm diff upgrade rust-app charts/rust-app --reuse-values --set replicaCount=3`.
   This is the Helm equivalent of `terraform plan`. Why would a team require it
   in code review?
5. **Adopt instead of delete** (20 min, 3 short commands). Helm adopts an
   existing object if it carries the label `app.kubernetes.io/managed-by=Helm`
   and the annotations `meta.helm.sh/release-name` and
   `meta.helm.sh/release-namespace`. Apply `k8s/app.yaml` again under a test
   release name, add the label and annotations with `kubectl label` and
   `kubectl annotate`, and install the chart with that release name. Why is this
   useful when moving a running production service to Helm?

Finish the session with Step 11.

## Interview questions

- What is the difference between a chart, a release and a revision?
- Where does Helm store release information? What happens if that data is lost?
- What does `helm upgrade --install` do, and why do pipelines use it?
- Why use `--wait`? What does `--atomic` (or `--rollback-on-failure`) add?
- How does a Helm rollback work? Does it change the history?
- How do you see the exact YAML a release applied, and the values it used?
- In what order are `values.yaml`, `-f` files and `--set` applied? What happens
  to maps and to lists?
- A Secret changed, but the pods still use the old value. How do you make Helm
  restart them automatically?
- What is the difference between `helm template` and `helm install --dry-run`?
- When would you not use Helm? (Think of Kustomize, plain manifests, or an
  operator.)
