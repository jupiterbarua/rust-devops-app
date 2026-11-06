# Monitoring with Prometheus and Grafana

Everything so far answers the question "is the new version deployed?". This
chapter answers the next one: "is it working?". How many requests does the
service handle? How many fail? How slow is it for the slowest users? Are pods
restarting? Without numbers, the honest answer is "I think so", and you find
out about problems from your users.

You will make the Rust service report its own metrics, install the standard
Kubernetes monitoring stack (Prometheus, Grafana and Alertmanager) with one
script, let Prometheus discover the service automatically, learn enough PromQL
to answer real questions, and ship a Grafana dashboard as code, in the Helm
chart, next to the application it describes. The next chapter turns these
metrics into alerts.

> **Time and typing**
>
> | | |
> |---|---|
> | Reading | 60 min |
> | Hands-on | 90 min, plus about 10 min waiting for the stack to start |
> | Practice | 60 min |
> | Cost | the k3s server as an `m7i-flex.large` (about 10 cents per hour) and RDS while they run; on EKS, three more ALBs (Step 9) |
>
> **Copy:** the two values files, `install-monitoring.sh`, the ServiceMonitor
> template and the dashboard JSON.
> **Type yourself:** the `track_metrics` middleware in `src/lib.rs` (Step 1,
> about 20 lines) and every PromQL query in Step 7. The middleware decides what
> your metrics can tell you; PromQL is how you will ask.

## The idea

### Three kinds of signals

Observability is usually split into three kinds of data:

| Signal | Answers | Example | In this book |
|---|---|---|---|
| **Metrics** | how much, how often, how fast, over time | 12 requests per second, 0.4% errors, p95 latency 30 ms | this chapter |
| **Logs** | what happened, in detail, for one event | `database error: connection refused` | the JSON logs from Chapter 1 |
| **Traces** | where the time went, across services, for one request | 3 ms in the API, 25 ms in the database | Lessons Learned |

Metrics are cheap to store, fast to query and easy to alert on, which is why
monitoring starts there. Logs explain a problem once metrics have shown it.

### What to measure: RED

For a service that answers requests, the **RED method** gives you three numbers
that cover most of what users feel:

- **Rate**: requests per second.
- **Errors**: how many of them fail.
- **Duration**: how long they take, as percentiles (p50, p95, p99), not
  averages. An average of 50 ms can hide that 1 in 20 users waits 2 seconds.

For machines and resources (CPU, memory, disks) the matching method is **USE**:
utilisation, saturation, errors. The monitoring stack collects those for you.

### How Prometheus works

**Prometheus** is a time-series database that **pulls** metrics. Every 15
seconds or so, it sends an HTTP request to each **target**, usually
`GET /metrics`, and stores the numbers it gets back:

```text
                  ┌────────────── monitoring namespace ──────────────┐
                  │                                                  │
 rust-app pods ◀──┤ Prometheus ── scrapes every 15 s ──▶ node-exporter│ (CPU, memory, disk per node)
   /metrics       │     │                         ──▶ kube-state-   │ (Deployments, pods, restarts)
                  │     │                              metrics      │
                  │     │ PromQL                  ──▶ kubelet       │ (container CPU and memory)
                  │     ▼                                            │
                  │  Grafana (dashboards)    Alertmanager (Chapter 13)│
                  └──────────────────────────────────────────────────┘
```

A scrape returns plain text like this:

```text
http_requests_total{method="GET",path="/items",status="200"} 1027
http_request_duration_seconds_bucket{method="GET",path="/items",status="200",le="0.05"} 1019
```

Each line is a **series**: a metric name, a set of **labels**, and a value.
Prometheus stores the value with a timestamp at every scrape. The three
**metric types** you need:

| Type | Behaviour | Example | Query it with |
|---|---|---|---|
| **Counter** | only goes up (resets to 0 on restart) | `http_requests_total` | `rate()`: per-second increase |
| **Gauge** | goes up and down | memory in use, pods ready | the value itself |
| **Histogram** | counts observations into buckets (`le` = "less or equal") | `http_request_duration_seconds` | `histogram_quantile()` |

Every unique combination of label values is a separate series, stored and
queried on its own. Labels like `method`, `path` and `status` have a handful of
values each, which is fine. A label with a user ID or a raw URL such as
`/items/42` would create a new series for every user or item, and eventually
take Prometheus down. This is called a **cardinality** problem, and you will see
how the middleware avoids it.

### The stack: kube-prometheus-stack

Running Prometheus on Kubernetes means many moving parts. The
**kube-prometheus-stack** Helm chart installs all of them, preconfigured:

| Component | Job |
|---|---|
| **Prometheus Operator** | runs Prometheus and Alertmanager, and turns custom resources into their configuration |
| **Prometheus** | scrapes and stores metrics, evaluates alert rules |
| **Alertmanager** | groups, routes and sends alerts (Chapter 13) |
| **Grafana** | dashboards, with Prometheus already connected and dozens of dashboards built in |
| **node-exporter** | one pod per node: CPU, memory, disk, network of the machine |
| **kube-state-metrics** | the state of Kubernetes objects: desired and available replicas, pod phases, restarts |

The operator adds **custom resources**, new object kinds in the Kubernetes API.
Two matter here:

- **ServiceMonitor**: "scrape the pods behind Services with these labels, on
  this port and path". You put one in your Helm chart, and Prometheus finds your
  application without anyone editing Prometheus's configuration.
- **PrometheusRule**: alert rules, as a Kubernetes object (Chapter 13).

This is the same operator pattern as the AWS Load Balancer Controller: you
declare what you want in a Kubernetes object, and a controller makes it so.

## Step 1: Make the service report metrics

The service needs two things: something that **records** numbers while it
handles requests, and an endpoint that **serves** them. Two crates do this:
`metrics` (the recording API, like `tracing` for logs) and
`metrics-exporter-prometheus` (stores the numbers and renders the text format).

**`Cargo.toml`**, under `[dependencies]`:

```toml
metrics = "0.24"
metrics-exporter-prometheus = { version = "0.17", default-features = false }
```

`default-features = false` leaves out the exporter's own HTTP server: the
service already has one, and serves `/metrics` itself.

**`src/lib.rs`**: add the imports, a field in `AppState`, and the recorder
setup. Paste these parts:

```rust
use std::time::Instant;

use axum::{
    extract::{MatchedPath, Path, Request, State},
    http::StatusCode,
    middleware::{self, Next},
    response::Response,
    routing::get,
    Json, Router,
};
use metrics_exporter_prometheus::{Matcher, PrometheusBuilder, PrometheusHandle};

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub metrics: PrometheusHandle,
}

/// Latency buckets in seconds for the request duration histogram.
const LATENCY_BUCKETS: &[f64] = &[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0];

/// Install the global Prometheus recorder. Call once at startup.
pub fn install_metrics() -> PrometheusHandle {
    PrometheusBuilder::new()
        .set_buckets_for_metric(
            Matcher::Full("http_request_duration_seconds".to_string()),
            LATENCY_BUCKETS,
        )
        .expect("valid histogram buckets")
        .install_recorder()
        .expect("failed to install Prometheus recorder")
}
```

The **buckets** decide what latency questions you can answer later. With these,
Prometheus can tell you how many requests took up to 5 ms, 10 ms, 25 ms and so
on, up to 5 seconds. Percentiles are estimated from these buckets, so they
should cover the range you care about, with more buckets where your normal
latency is. Without this call, the exporter would report a **summary** instead
of a histogram, and summaries from several pods cannot be combined into one
percentile.

The `PrometheusHandle` is what renders the text at `/metrics`. It lives in
`AppState` so the handler can reach it.

Now the part to **type yourself**, the middleware that measures every request,
below the `app` function:

```rust
/// Records a request counter and a latency histogram for every request.
async fn track_metrics(req: Request, next: Next) -> Response {
    let start = Instant::now();

    // The route pattern (e.g. "/items/{id}"), not the raw URL ("/items/42"),
    // so the number of label values stays small.
    let path = req
        .extensions()
        .get::<MatchedPath>()
        .map(|p| p.as_str().to_owned())
        .unwrap_or_else(|| "unmatched".to_owned());
    let method = req.method().to_string();

    let response = next.run(req).await;

    let labels = [
        ("method", method),
        ("path", path),
        ("status", response.status().as_u16().to_string()),
    ];
    metrics::counter!("http_requests_total", &labels).increment(1);
    metrics::histogram!("http_request_duration_seconds", &labels)
        .record(start.elapsed().as_secs_f64());

    response
}

async fn metrics_handler(State(state): State<AppState>) -> String {
    state.metrics.render()
}
```

**`MatchedPath`** is the route pattern that Axum matched, `/items/{id}`, not the
URL `/items/42`. That one choice keeps the `path` label at five values instead
of one per item: the cardinality problem from "The idea", avoided. Requests
that match no route get `unmatched`, so a scanner trying a thousand random URLs
adds one series, not a thousand.

**`next.run(req).await`** runs the actual handler; everything before it
happens on the way in, everything after it on the way out, when the status code
is known.

**The counter and the histogram** carry the same labels, so you can ask both
"how many `GET /items` returned `500`?" and "how slow were they?".

Then wire it into the router. In `app()`, the order of the lines matters:

```rust
pub fn app(state: AppState) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/ready", get(ready))
        .route("/items", get(list_items).post(create_item))
        .route("/items/{id}", get(get_item))
        .route_layer(middleware::from_fn(track_metrics)) // measures routes above
        .route("/metrics", get(metrics_handler)) // not measured
        .route("/version", get(version))
        .with_state(state)
}
```

`route_layer` applies the middleware to the routes added **before** it. So
`/metrics` is not measured, otherwise every scrape would count as traffic, and
`route_layer` (unlike `layer`) only runs for requests that matched a route.

Finally, count something that matters to the business, not only to HTTP. In the
`internal_error` helper, which every handler uses for database errors:

```rust
fn internal_error(err: sqlx::Error) -> StatusCode {
    tracing::error!(error = %err, "database error");
    metrics::counter!("database_errors_total").increment(1);
    StatusCode::INTERNAL_SERVER_ERROR
}
```

**`src/main.rs`**: install the recorder once, after the migrations, and put the
handle into the state:

```rust
use rust_devops_app::{app, install_metrics, AppState};

// ... after sqlx::migrate!(...).run(&pool).await?;
let metrics = install_metrics();

axum::serve(listener, app(AppState { pool, metrics }))
```

**`tests/api.rs`**: the tests build `AppState` too. A global recorder can only be
installed once per process, and tests run in parallel, so tests use a local
handle that records nothing globally:

```rust
use metrics_exporter_prometheus::PrometheusBuilder;

/// Tests use a local recorder handle instead of installing a global one.
fn test_state(pool: sqlx::PgPool) -> AppState {
    let metrics = PrometheusBuilder::new().build_recorder().handle();
    AppState { pool, metrics }
}
```

Use `test_state(pool)` wherever a test built `AppState { pool }` before.

Check it locally with Docker Compose (Chapter 2):

```bash
cargo fmt && cargo clippy --all-targets -- -D warnings && cargo test
docker compose up -d --build
curl -s localhost:8080/items > /dev/null
curl -s localhost:8080/items/999 > /dev/null
curl -s localhost:8080/metrics | grep -v '^#'
```

You see one `http_requests_total` line for `/items` with status `200`, one for
`/items/{id}` with `404`, and a block of `http_request_duration_seconds_bucket`
lines for each. Run `cargo fmt` before every commit: the CI's `lint` job fails
on unformatted code, and adding a block of imports and a new function is the
typical moment it happens.

Commit, open a pull request, and merge it. The pipeline builds the new image
and, if the k3s server is running, deploys it.

## Step 2: A bigger server

The monitoring stack needs about 1.5 GB of memory on its own, more than a
`t3.small` has left. Set the larger type in `terraform.tfvars` (Chapter 7):

```hcl
k3s_instance_type = "m7i-flex.large"
```

and apply on your laptop. If the server exists, Terraform changes the type **in
place**: AWS stops the instance, changes it and starts it again. The disk and
everything on it stay, but the **public IP changes**, which matters for the
next steps. If the server does not exist, it is simply created with the new
type.

```bash
terraform apply
terraform output k3s_public_ip
```

## Step 3: The settings for the stack

Create `monitoring/kube-prometheus-stack-values.yaml` and paste it:

```yaml
# Settings for kube-prometheus-stack on k3s.

# k3s runs these control-plane components inside its own process,
# so they can't be scraped separately. Without this, Prometheus would
# show them as "down" and fire alerts about them.
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeEtcd:
  enabled: false
kubeProxy:
  enabled: false

prometheus:
  prometheusSpec:
    retention: 2d
    # Pick up ServiceMonitors and rules from every Helm release,
    # not only from this chart (otherwise your app is ignored)
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
  ingress:
    enabled: true
    ingressClassName: traefik

grafana:
  admin:
    existingSecret: grafana-admin
    userKey: admin-user
    passwordKey: admin-password
  ingress:
    enabled: true
    ingressClassName: traefik
  defaultDashboardsTimezone: browser
  sidecar:
    dashboards:
      searchNamespace: ALL

alertmanager:
  alertmanagerSpec:
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
  ingress:
    enabled: true
    ingressClassName: traefik
```

The settings that matter:

**The four `enabled: false` blocks.** The chart expects a classic Kubernetes
control plane with separate scheduler, controller manager, etcd and kube-proxy
processes to scrape. k3s runs them all inside its one process, so the targets
do not exist. Without these lines, Prometheus shows them as `down`, and the
stack's built-in alerts fire about a problem you do not have. On EKS, AWS runs
the control plane, and the same components are not reachable either.

**`serviceMonitorSelectorNilUsesHelmValues: false`** is the most important line
in the file. By default, this Prometheus only picks up ServiceMonitors (and
rules) that carry the **stack's own Helm release label**. Your application's
ServiceMonitor comes from a different release (`rust-app`), so it would be
ignored, without any error message. Setting the three `...NilUsesHelmValues`
options to `false` means "select all of them, in every namespace".

**`retention: 2d`**: keep two days of data. There is no persistent volume in
this setup, so data is lost when the Prometheus pod is replaced anyway. A
production setup gives Prometheus a volume, or sends the data to a managed
service (Lessons Learned).

**`grafana.admin.existingSecret`**: Grafana's admin password comes from a
Secret that the install script creates once (Step 4), not from the values file,
which is in Git.

**`sidecar.dashboards.searchNamespace: ALL`**: Grafana runs a small **sidecar**
container that watches for ConfigMaps labelled `grafana_dashboard: "1"` and
loads them as dashboards. By default it only looks in the `monitoring`
namespace; `ALL` lets your chart ship its dashboard in `rust-app` (Step 8).

**The three Ingresses**: on k3s, Traefik serves the web interfaces.

## Step 4: The install script

Like `deploy.sh`, the install steps go into a script, so they are the same every
time. Create `scripts/install-monitoring.sh`, make it executable
(`chmod +x scripts/install-monitoring.sh`), and paste it:

```bash
#!/usr/bin/env bash
#
# Install or update the monitoring stack (Prometheus, Grafana, Alertmanager).
# Safe to run again: it only changes what is different.
#
# Usage (on the admin host, from anywhere in the repo):
#   ./scripts/install-monitoring.sh                                  # k3s (default)
#   PLATFORM=eks ALLOW_CIDR=203.0.113.10/32 ./scripts/install-monitoring.sh
#
# On EKS, set KUBECONFIG to the EKS cluster first:
#   export KUBECONFIG=~/.kube/eks.yaml

set -euo pipefail

PLATFORM="${PLATFORM:-k3s}"
NAMESPACE="monitoring"
RELEASE="kube-prometheus-stack"
CHART="prometheus-community/kube-prometheus-stack"
VALUES_FILE="monitoring/kube-prometheus-stack-values.yaml"
EKS_VALUES_FILE="monitoring/kube-prometheus-stack-values-eks.yaml"

cd "$(dirname "$0")/.."
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

for cmd in kubectl helm curl openssl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' is not installed." >&2
    exit 1
  fi
done

echo "==> Platform: $PLATFORM (cluster: $(kubectl config current-context))"
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "Error: cannot reach a Kubernetes cluster. Check KUBECONFIG." >&2
  exit 1
fi

# --- Platform-specific Helm arguments --------------------------------------------
HELM_ARGS=(-f "$VALUES_FILE")

case "$PLATFORM" in
  k3s)
    # Traefik routes by host name; nip.io resolves <name>.<ip>.nip.io to <ip>
    IP=$(curl -fsS https://checkip.amazonaws.com)
    HELM_ARGS+=(
      --set "grafana.ingress.hosts[0]=grafana.${IP}.nip.io"
      --set "prometheus.ingress.hosts[0]=prometheus.${IP}.nip.io"
      --set "alertmanager.ingress.hosts[0]=alertmanager.${IP}.nip.io"
    )
    ;;
  eks)
    if [[ -z "${ALLOW_CIDR:-}" ]]; then
      echo "Error: on EKS, set ALLOW_CIDR to your IP, e.g. ALLOW_CIDR=203.0.113.10/32" >&2
      exit 1
    fi
    if [[ ! "$ALLOW_CIDR" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
      echo "Error: ALLOW_CIDR '$ALLOW_CIDR' is not a valid IPv4 CIDR like 203.0.113.10/32" >&2
      exit 1
    fi
    HELM_ARGS+=(-f "$EKS_VALUES_FILE")
    for ui in grafana prometheus alertmanager; do
      HELM_ARGS+=(--set-string "${ui}.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/inbound-cidrs=${ALLOW_CIDR}")
    done
    ;;
  *)
    echo "Error: PLATFORM must be 'k3s' or 'eks', not '$PLATFORM'." >&2
    exit 1
    ;;
esac

# --- Helm chart repository ----------------------------------------------------------
echo "==> Helm repository"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo update prometheus-community

# --- Namespace ----------------------------------------------------------------------
echo "==> Namespace"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# --- Grafana admin password (created once, never overwritten) -------------------
echo "==> Grafana admin secret"
if kubectl get secret grafana-admin --namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "secret/grafana-admin already exists, keeping it"
else
  kubectl create secret generic grafana-admin --namespace "$NAMESPACE" \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$(openssl rand -base64 18)"
fi

# --- Install or upgrade the stack ------------------------------------------------------
echo "==> Installing $RELEASE (this can take several minutes)"
helm upgrade --install "$RELEASE" "$CHART" \
  --namespace "$NAMESPACE" \
  "${HELM_ARGS[@]}" \
  --wait \
  --timeout 10m

# --- Summary -----------------------------------------------------------------------------
echo
kubectl get pods --namespace "$NAMESPACE"
echo
if [[ "$PLATFORM" == "k3s" ]]; then
  echo "Grafana:      http://grafana.${IP}.nip.io   (user: admin)"
  echo "Prometheus:   http://prometheus.${IP}.nip.io"
  echo "Alertmanager: http://alertmanager.${IP}.nip.io"
else
  echo "Load balancers are being created (1-3 minutes). Their addresses:"
  echo "  kubectl get ingress -n $NAMESPACE"
  echo "Open http://<ADDRESS> for each. Grafana user: admin"
fi
echo
echo "Grafana password:"
echo "  kubectl get secret grafana-admin -n $NAMESPACE -o jsonpath='{.data.admin-password}' | base64 -d; echo"
echo
echo "Next: run ./scripts/deploy.sh so the app's ServiceMonitor, dashboard and alerts are created."
```

Most of it is the pattern from `deploy.sh`: `set -euo pipefail`, a tool check,
idempotent namespace creation, an array of Helm arguments, and
`helm upgrade --install --wait`. What is new:

**`kubectl cluster-info` before anything else.** If `KUBECONFIG` points
nowhere, the script stops in the first second with a clear message, instead of
failing halfway with `localhost:8080 ... connection refused`. That exact failure
happened while building this project; this check is the fix.

**`nip.io`.** Traefik routes by **host name**, and three web interfaces need
three names. You have no domain, but `nip.io` is a free public DNS service that
answers every name of the form `<anything>.<ip>.nip.io` with `<ip>`. So
`grafana.203.0.113.10.nip.io` resolves to your server. Here `checkip` runs **on
the server**, and returns the server's IP: exactly what these names need. (Your
own IP, for the security group, is a different thing.)

**`case "$PLATFORM"`** keeps both platforms in one script. The EKS branch also
**validates** `ALLOW_CIDR` with a regular expression, because a placeholder
like `YOUR.IP/32` there once produced three load balancers that never worked
(Chapter 11, Troubleshooting).

**The Grafana secret is created only if it does not exist.** Rerunning the
script, for an upgrade, must not change the password under you. The password
itself comes from `openssl rand`, is stored only in the cluster, and is never
printed by the script.

**`--timeout 10m`**: the stack pulls a dozen images and starts several
components; on a fresh server, five minutes is not always enough.

The script does not pin the chart's version, unlike the controller in
Chapter 11. Practice exercise 1 fixes that.

## Step 5: Install it on k3s

On the server, in Session Manager:

```bash
bash
cd ~/rust-devops-app && git pull
./scripts/install-monitoring.sh
```

It takes three to five minutes. Then look at what you got:

```bash
kubectl get pods -n monitoring
```

```text
NAME                                                        READY   STATUS
alertmanager-kube-prometheus-stack-alertmanager-0           2/2     Running
kube-prometheus-stack-grafana-xxxxxxxxxx-xxxxx              3/3     Running
kube-prometheus-stack-kube-state-metrics-xxxxxxxxxx-xxxxx   1/1     Running
kube-prometheus-stack-operator-xxxxxxxxxx-xxxxx             1/1     Running
kube-prometheus-stack-prometheus-node-exporter-xxxxx        1/1     Running
prometheus-kube-prometheus-stack-prometheus-0               2/2     Running
```

Each component from the table in "The idea". Grafana has three containers:
Grafana itself and the sidecars that load dashboards and data sources.
Prometheus and Alertmanager end in `-0`: they run as **StatefulSets**, a kind
for pods with a stable identity, because a database should not be replaced by
a randomly named copy.

The script prints three URLs at the end. Open the Prometheus one in your
browser, with **`http://`**. There is no TLS on these names, so `https://` does
not connect. The security group from Chapter 7 already allows port 80 from your
IP.

## Step 6: Let Prometheus find the application

The finished chart already contains a ServiceMonitor template
(`charts/rust-app/templates/servicemonitor.yaml`):

```yaml
{{- if and .Values.metrics.serviceMonitor.enabled (.Capabilities.APIVersions.Has "monitoring.coreos.com/v1/ServiceMonitor") }}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ .Release.Name }}
  labels:
    app: {{ .Release.Name }}
spec:
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  endpoints:
    - port: http
      path: /metrics
      interval: {{ .Values.metrics.serviceMonitor.interval }}
{{- end }}
```

and the matching block in `values.yaml`:

```yaml
metrics:
  serviceMonitor:
    enabled: true
    interval: 15s
  dashboard:
    enabled: true
  alerts:
    enabled: true
```

Read the ServiceMonitor like this: "find **Services** labelled `app: rust-app`,
take the port **named** `http`, and scrape `/metrics` on every pod behind it,
every 15 seconds". That is why the Service in Chapter 8 has `labels` and a
**named** port (`name: http`): the ServiceMonitor refers to both.

**`.Capabilities.APIVersions.Has`** checks whether the cluster knows the
`ServiceMonitor` kind. Before the stack was installed it did not, and creating a
ServiceMonitor would have failed the whole Helm release with
`no matches for kind "ServiceMonitor"`. With this check, the chart works on any
cluster and adds monitoring when monitoring is there. It is also why Helm must
run **after** the stack is installed: the check happens at render time.

Deploy the application again, so the template renders:

```bash
./scripts/deploy.sh
kubectl get servicemonitor -n rust-app
```

In Prometheus, open **Status → Target health** (in older versions, **Status →
Targets**). Within half a minute, a group `serviceMonitor/rust-app/rust-app/0`
appears with **two** targets, one per pod, both `UP`. The operator read your
ServiceMonitor, wrote the scrape configuration, and Prometheus found the pods
through the Service, all without anyone touching Prometheus.

## Step 7: Ask questions with PromQL

Prometheus is only useful once you can query it. Generate some traffic first,
from your **laptop**, and leave it running in its own terminal:

```bash
IP=<k3s_public_ip>
while true; do
  curl -s "http://$IP/items" > /dev/null
  curl -s "http://$IP/items/999" > /dev/null
  sleep 0.2
done
```

Then open Prometheus, go to **Query**, type each query into the box (type them,
do not paste), and press **Execute**. Switch between the **Table** and **Graph**
tabs.

**1. Is everything being scraped?**

```promql
up
```

One series per target, `1` for up, `0` for down. Filter it:
`up{namespace="rust-app"}`.

**2. A counter, as it is stored:**

```promql
http_requests_total{namespace="rust-app"}
```

One row per pod, path, method and status, with the raw total since the pod
started. Prometheus added `namespace`, `pod`, `service` and `job` labels when it
scraped. On its own, the raw count is not useful: it only goes up.

**3. Rate: requests per second.**

```promql
rate(http_requests_total{namespace="rust-app"}[5m])
```

`[5m]` selects the last five minutes of samples, and `rate()` turns them into a
per-second increase, and handles counter resets when a pod restarts. Always
`rate()` a counter before doing anything else with it.

**4. Aggregate: one line per endpoint, across all pods.**

```promql
sum by (path) (rate(http_requests_total{namespace="rust-app"}[5m]))
```

`sum by (path)` adds up all series with the same `path` and drops the other
labels. This is the **R** of RED. In the **Graph** tab you see your loop: about
five requests per second on each of `/items` and `/items/{id}`, plus the probes
on `/health` and `/ready`.

**5. Errors: the share of server errors.**

```promql
sum(rate(http_requests_total{namespace="rust-app",status=~"5.."}[5m]))
  /
sum(rate(http_requests_total{namespace="rust-app"}[5m]))
```

`=~"5.."` is a regular expression: any status from 500 to 599. Right now, this
returns **no data**: there are no 5xx responses, so the top has no series, and
dividing nothing by something gives nothing. Your `404`s are client errors and
not counted, which is right: a missing item is not the service failing. The
alert in Chapter 13 handles the "no data" case.

**6. Duration: the 95th percentile.**

```promql
histogram_quantile(0.95,
  sum by (le) (rate(http_request_duration_seconds_bucket{namespace="rust-app"}[5m])))
```

`histogram_quantile` estimates a percentile from the buckets. `sum by (le)`
first adds up the buckets of all pods and paths, so the result is "95% of all
requests were faster than this many seconds". Use `sum by (le, path)` for one
line per endpoint. This is the **D** of RED.

**7. Kubernetes itself, from kube-state-metrics:**

```promql
kube_deployment_status_replicas_available{namespace="rust-app"}
```

and from the kubelet:

```promql
sum by (pod) (container_memory_working_set_bytes{namespace="rust-app",container!=""})
```

The first shows two available replicas of `rust-app`; the second, how much
memory each pod uses. Compare it with the `128Mi` limit from Chapter 7.

## Step 8: Grafana and a dashboard as code

Get the admin password, on the server:

```bash
kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Open the Grafana URL from Step 5 (`http://`), and log in as `admin`. Two places
are worth a visit first:

- **Dashboards**: the stack ships dozens of dashboards. Open **Kubernetes /
  Compute Resources / Namespace (Pods)** and choose the namespace `rust-app` at
  the top: CPU and memory of your pods, without writing a query.
- **Explore**: a query box like the one in Prometheus, with the data source
  `Prometheus` already set up. Switch the editor from **Builder** to **Code**
  and paste any query from Step 7.

### The application's own dashboard

Dashboards clicked together in the browser have the same problem as
infrastructure clicked together in the console: nobody knows how they were
built, and they are gone when Grafana is replaced. So the application's
dashboard lives **in the Helm chart**, as JSON, and is deployed with the
application.

The chart has two parts for this. The dashboard itself,
`charts/rust-app/dashboards/rust-app.json`, is Grafana's own export format.
Copy it from the repository; it is about 300 lines of JSON that nobody writes
by hand. And a template that wraps it in a ConfigMap,
`charts/rust-app/templates/dashboard-configmap.yaml`:

```yaml
{{- if .Values.metrics.dashboard.enabled }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-dashboard
  labels:
    app: {{ .Release.Name }}
    # The Grafana sidecar loads every ConfigMap with this label as a dashboard
    grafana_dashboard: "1"
data:
  rust-app.json: |-
{{ .Files.Get "dashboards/rust-app.json" | indent 4 }}
{{- end }}
```

**`.Files.Get`** reads a file from the chart folder into the template. Keeping
the JSON in its own file means you can edit it in Grafana, export it, and
replace the file, without touching YAML. `indent 4` places every line under
`rust-app.json: |-`.

**`grafana_dashboard: "1"`** is the label the sidecar from Step 3 watches for.

The ConfigMap was already created by your last `deploy.sh`. In Grafana, open
**Dashboards** and search for **Rust App – RED overview**. With your traffic loop
still running, you see:

| Row | Panels | Query idea |
|---|---|---|
| Top | Requests/sec, Error rate (5xx), p95 latency, Ready pods | Step 7, queries 4 to 7 |
| Rate | requests per second by endpoint | `sum by (path) (rate(...))` |
| Errors | responses per second by status | `sum by (status) (rate(...))` |
| Duration | p50, p95, p99 latency | `histogram_quantile` with three quantiles |
| Business | items created per minute | a counter the service does not emit yet: Practice 2 |
| Resources | pod restarts, memory per pod | kube-state-metrics, kubelet |

The queries use `$__rate_interval` instead of `[5m]`. Grafana replaces it with
a window that fits the zoom level and the scrape interval, which avoids gaps
and spikes. The **namespace** dropdown at the top is a dashboard variable, so
the same dashboard works for any namespace the chart is installed in.

Stop the traffic loop on your laptop with `Ctrl+C` when you are done.

## Step 9: The same stack on EKS

On EKS, the interfaces are exposed through ALBs instead of Traefik. A second
values file, `monitoring/kube-prometheus-stack-values-eks.yaml`, overrides the
Ingress settings:

```yaml
# Overrides for Amazon EKS. Used together with kube-prometheus-stack-values.yaml:
#   PLATFORM=eks ALLOW_CIDR=<your-ip>/32 ./scripts/install-monitoring.sh
#
# EKS has no Traefik. Each web UI gets its own internet-facing ALB through the
# AWS Load Balancer Controller, reachable by the ALB's DNS name (no host names).
# The script adds inbound-cidrs so only your IP can reach them.

grafana:
  ingress:
    ingressClassName: alb
    hosts: []
    annotations:
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/target-type: ip
      alb.ingress.kubernetes.io/healthcheck-path: /api/health

prometheus:
  ingress:
    ingressClassName: alb
    pathType: Prefix
    hosts: []
    annotations:
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/target-type: ip
      alb.ingress.kubernetes.io/healthcheck-path: /-/ready

alertmanager:
  ingress:
    ingressClassName: alb
    pathType: Prefix
    hosts: []
    annotations:
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/target-type: ip
      alb.ingress.kubernetes.io/healthcheck-path: /-/ready
```

**`hosts: []`**: there are no host names on EKS. Each ALB is reached by its own
DNS name.

**`pathType: Prefix`**: the chart's default for Prometheus and Alertmanager is
`ImplementationSpecific`, which the ALB treats as "only `/` exactly". The UI's
start page loads, and every other page answers `404` from `awselb/2.0`
(Chapter 11, Troubleshooting). Grafana's sub-chart already defaults to
`Prefix`.

**`healthcheck-path`**: each component has its own health endpoint. The ALB
would otherwise check `/`, which redirects (Grafana to `/login`), and count the
redirect as unhealthy.

With the EKS cluster and the controller from Chapters 10 and 11 running, on the
admin host, with your **laptop's** IP:

```bash
export KUBECONFIG=~/.kube/eks.yaml
PLATFORM=eks ALLOW_CIDR=<YOUR_IP>/32 ./scripts/install-monitoring.sh
VALUES_FILE=charts/rust-app/values-eks.yaml ALLOW_CIDR=<YOUR_IP>/32 ./scripts/deploy.sh
kubectl get ingress -A
```

Four Ingresses with class `alb`, and after a few minutes four addresses: one
ALB each for the application, Grafana, Prometheus and Alertmanager. Four ALBs
cost about 12 cents per hour together; Chapter 11, Practice 1 shows how one ALB
can serve all of them.

**Cleanup on EKS gets one more step.** Uninstall the monitoring stack too, before
the controller and the cluster (Chapter 11, Step 8):

```bash
helm uninstall kube-prometheus-stack -n monitoring
helm uninstall rust-app -n rust-app
# wait until no k8s-... load balancers are left, then:
helm uninstall aws-load-balancer-controller -n kube-system
```

## Step 10: Clean up on k3s

On k3s, nothing outside the server was created, so destroying the server is
enough (Chapter 7, Step 11). To remove only the stack and keep the server:

```bash
helm uninstall kube-prometheus-stack -n monitoring
```

Helm does not delete the **CRDs** (`ServiceMonitor`, `PrometheusRule` and
others) that the chart installed, on purpose: deleting a CRD deletes every
object of that kind in the cluster. `kubectl get crd | grep monitoring.coreos.com`
shows them. They do no harm.

## Troubleshooting

All of these happened while building this project.

**`/metrics` returns only `# HELP` and `# TYPE` lines, or nothing, after a
request.** Two common reasons. First, metrics are **per pod**, and so is every
request: with two pods behind a Service, your request to `/items` went to one
pod and your request to `/metrics` to the other, which has not counted anything
yet. Send a few more requests, or look at both pods. Second, a series only
appears after it is used for the first time: right after a restart, there is
nothing to show.

**CI fails in `Format & Clippy` with `Diff in .../src/lib.rs`.** The new code was
not formatted. Run `cargo fmt`, commit, push.

**The application's target does not appear in Prometheus.** In order of
likelihood: the ServiceMonitor is ignored because
`serviceMonitorSelectorNilUsesHelmValues: false` is missing (Step 3); the
ServiceMonitor was never created, because the chart was rendered before the
stack existed (run `deploy.sh` again and check
`kubectl get servicemonitor -n rust-app`); or the labels or the port name do not
match the Service (`kubectl get svc rust-app -n rust-app -o yaml`).

**`https://prometheus.<ip>.nip.io` does not load.** These names have no
certificate and no listener on port 443. Use `http://`.

**The Prometheus query page is empty.** It shows nothing until you type a query
and press **Execute**. Start with `up`.

**`error: current-context is not set` followed by `localhost:8080 ... connection refused`.**
The script ran without a kubeconfig for the cluster you meant, typically on EKS
in a new Session Manager tab. `export KUBECONFIG=~/.kube/eks.yaml` and run it
again. The `cluster-info` check in the script now catches this at the start.

**The dashboard does not show up in Grafana.** Check that the ConfigMap exists
(`kubectl get cm -n rust-app -l grafana_dashboard=1`), and that
`sidecar.dashboards.searchNamespace: ALL` is set. The sidecar's logs say what it
loaded:
`kubectl logs -n monitoring deploy/kube-prometheus-stack-grafana -c grafana-sc-dashboard --tail=20`.

**A dashboard panel says `No data`.** Run the panel's query in Explore, and
remove parts until something shows up. The **Business** panel has no data
because the service does not emit `items_created_total` yet: Practice 2.

**`git pull` on the server fails: `Your local changes to the following files would be overwritten by merge: scripts/install-monitoring.sh`.**
The script was edited on the server. Discard the change with
`git checkout -- scripts/install-monitoring.sh`, pull again, and make changes on
your laptop.

**On EKS, Prometheus's start page loads but every other page is a `404` from `awselb/2.0`.**
`pathType` is `ImplementationSpecific`. Set `pathType: Prefix` in the EKS values
file and rerun the install script.

**On EKS, the Ingresses show `invalid CIDR address: YOUR.IP/32`, or `failed calling webhook "vingress.elbv2.k8s.aws"`.**
See Chapter 11, Troubleshooting: a placeholder in `ALLOW_CIDR`, or a controller
that was not ready yet.

**Pods are `Pending` with `Insufficient memory`.** The server is too small for
the stack. Use `m7i-flex.large` (Step 2).

## What you learned

- The difference between metrics, logs and traces, and why monitoring starts
  with metrics.
- The RED method, and why percentiles beat averages.
- How Prometheus pulls metrics, what counters, gauges and histograms are, and
  why label cardinality matters.
- How to instrument an Axum service with a middleware that records a counter
  and a histogram per route pattern.
- What kube-prometheus-stack installs, and how the Prometheus Operator turns
  ServiceMonitors into scrape configuration.
- The PromQL you need daily: selectors, `rate()`, `sum by`, ratios and
  `histogram_quantile()`.
- How to ship a Grafana dashboard as code, with the application, through a
  labelled ConfigMap.
- How to expose the stack on k3s with `nip.io` names and on EKS with ALBs, and
  what has to be cleaned up.

## Practice

Each exercise says how long it takes and how much you type.

1. **Pin the chart** (10 min, 3 lines). Find the current version with
   `helm search repo prometheus-community/kube-prometheus-stack --versions | head -3`,
   add `CHART_VERSION="<version>"` to the script's settings and
   `--version "$CHART_VERSION"` to the Helm command. Why does this matter more
   for this chart than for your own?
2. **The business metric** (15 min, 1 line). The dashboard's **Business** panel
   expects `items_created_total`. Add
   `metrics::counter!("items_created_total").increment(1);` to `create_item`, at
   the right place: only when the insert succeeded. Deploy, create a few items,
   and watch the panel.
3. **A cardinality experiment** (15 min, change 1 line, then revert). Change
   the middleware to use `req.uri().path()` instead of `MatchedPath`, run it
   locally, and request `/items/1` to `/items/50`. Count the series in `/metrics`.
   Then revert, and explain the difference in one sentence.
4. **Latency per endpoint** (10 min, 1 query). Write the PromQL for the p99
   latency of `GET /items` only. Then add it as a panel to the dashboard in
   Grafana, export the JSON (**Share → Export**), and compare it with the file
   in the chart. What would you do to keep the file and Grafana in sync?
5. **One ALB for the stack** (20 min, 1 annotation, on EKS). Give all four
   Ingresses the same `alb.ingress.kubernetes.io/group.name`. What breaks, and
   why? (Hint: all of them use path `/` without host names.) How would you fix
   it with paths or host names?

Finish the session by destroying the server and the database, and on EKS follow
the cleanup order in Step 9.

## Interview questions

- What are the RED and USE methods? Which metrics would you collect first for a
  new HTTP service?
- Prometheus pulls metrics. What are the advantages and disadvantages of pull
  compared with push?
- What is the difference between a counter, a gauge and a histogram? Why must
  you use `rate()` on a counter?
- What is label cardinality, and how can it bring down Prometheus? Give an
  example from an HTTP service.
- Why are percentiles better than averages for latency? How does Prometheus
  calculate them from a histogram?
- How does Prometheus discover targets in Kubernetes? What is a ServiceMonitor?
- Your application's metrics do not appear in Prometheus. How do you debug it?
- Why keep dashboards as code? How do you deploy them with the application?
- What happens to Prometheus's data when its pod is replaced in this setup? How
  would you change that for production?
