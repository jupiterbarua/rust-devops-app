# Alerts

A dashboard only helps someone who is looking at it. Nobody watches a
dashboard at three in the morning, or during a long meeting, or on a Saturday.
**Alerts** turn the questions from the last chapter into rules that Prometheus
checks for you, every few seconds, and that tell a person when the answer is
bad.

Writing alerts is easy. Writing alerts that people trust is the hard part: an
alert that fires for nothing teaches everyone to ignore it, and an alert that
does not fire when users suffer is worse than none. In this chapter you write
three alerts for the service, deploy them with the Helm chart, break the
application on purpose to watch them fire, silence them for maintenance, and,
optionally, send them to Slack.

> **Time and typing**
>
> | | |
> |---|---|
> | Reading | 40 min |
> | Hands-on | 60 min, most of it watching alerts change state |
> | Practice | 60 min |
> | Cost | the k3s server from Chapter 12 while it runs. Use the in-cluster database for the drill (Step 4), so RDS can stay off |
>
> **Copy:** the `PrometheusRule` template and the optional Alertmanager values file.
> **Type yourself:** the three `expr:` lines and the escaped `description`
> lines in the rule template (Step 1, about 15 lines), and the commands of the
> drill in Step 4. The expressions are what decides whether you are woken up;
> the escaping is the detail that breaks every first attempt.

## The idea

### What makes a good alert

A few rules, learned the hard way by every team that runs services:

- **Alert on symptoms, not causes.** Users feel "requests fail" and "the
  service is down", not "CPU is at 90%". High CPU with happy users is not an
  emergency. Start with alerts on the RED signals.
- **Every alert needs an action.** If the person receiving it cannot do
  anything, it should be a dashboard panel or a ticket, not an alert.
- **Wait a little before firing.** A single failed scrape or a two-second spike
  is noise. A condition that lasts two minutes is a problem.
- **Severity decides who is disturbed.** `critical` means "someone acts now,
  even at night". `warning` means "look at it during working hours".

### Prometheus decides, Alertmanager notifies

Alerting is split between two components, and the split is worth remembering:

```text
 Prometheus                                   Alertmanager
 ┌─────────────────────────────┐   firing    ┌──────────────────────────────────┐
 │ evaluates rules every 30 s  │────alerts──▶│ groups related alerts            │──▶ Slack, email,
 │ expr true?                  │             │ removes duplicates               │    PagerDuty, ...
 │   ─ no  → inactive          │             │ routes by labels (severity, ...) │
 │   ─ yes → pending           │             │ silences (maintenance)           │
 │   ─ yes for `for:` → firing │             │ inhibits (hide less important)   │
 └─────────────────────────────┘             └──────────────────────────────────┘
```

**Prometheus** evaluates each rule's expression. An alert moves through three
states:

| State | Meaning |
|---|---|
| `inactive` | the expression returns nothing |
| `pending` | it returns something, but not yet for as long as `for:` says |
| `firing` | it has been true for the whole `for:` duration; Prometheus sends it to Alertmanager |

**Alertmanager** never evaluates anything. It receives firing alerts, groups
the ones that belong together (ten failing pods should be one message, not ten),
sends them to the right **receiver** based on their labels, and keeps quiet
about alerts you have **silenced**. One Alertmanager can serve many Prometheus
servers, and the same alert from two of them is delivered once.

### Rules as Kubernetes objects

With the Prometheus Operator, alert rules are a Kubernetes object, the
**PrometheusRule**, just as scrape targets are ServiceMonitors. So the rules
for the service live in its Helm chart, are reviewed in its pull requests, and
are deployed with it. The stack's own rules (more than a hundred, for nodes,
pods, Kubernetes components and the stack itself) are PrometheusRules too.

## Step 1: Three alerts for the service

The finished chart contains `charts/rust-app/templates/prometheusrule.yaml`.
Paste it, and type the `expr:` blocks and the two `description:` lines that use
backticks:

```yaml
{{- if and .Values.metrics.alerts.enabled (.Capabilities.APIVersions.Has "monitoring.coreos.com/v1/PrometheusRule") }}
{{- $ns := .Release.Namespace }}
{{- $name := .Release.Name }}
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: {{ $name }}-alerts
  labels:
    app: {{ $name }}
spec:
  groups:
    - name: {{ $name }}.rules
      rules:
        # More than 5% of all requests fail with a server error
        - alert: RustAppHighErrorRate
          expr: |
            (sum(rate(http_requests_total{namespace="{{ $ns }}",status=~"5.."}[5m])) or vector(0))
              /
            sum(rate(http_requests_total{namespace="{{ $ns }}"}[5m]))
              > 0.05
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "{{ $name }}: more than 5% of requests are failing"
            description: '{{`{{ $value | humanizePercentage }}`}} of requests returned a 5xx status over the last 5 minutes.'

        # Fewer pods are ready than the Deployment wants
        - alert: RustAppPodsNotReady
          expr: |
            kube_deployment_status_replicas_available{namespace="{{ $ns }}",deployment="{{ $name }}"}
              <
            kube_deployment_spec_replicas{namespace="{{ $ns }}",deployment="{{ $name }}"}
          for: 2m
          labels:
            severity: warning
          annotations:
            summary: "{{ $name }}: not all pods are ready"
            description: 'Only {{`{{ $value }}`}} pod(s) are available. Check readiness probes and the database.'

        # Prometheus cannot scrape any pod at all
        - alert: RustAppDown
          expr: |
            sum(up{namespace="{{ $ns }}",service="{{ $name }}"}) == 0
              or
            absent(up{namespace="{{ $ns }}",service="{{ $name }}"})
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "{{ $name }}: no pod can be scraped"
            description: "Prometheus has not reached any {{ $name }} pod for at least 1 minute."
{{- end }}
```

The template uses the same `.Capabilities` guard as the ServiceMonitor, and
`{{ $ns }}` and `{{ $name }}` so the rules follow the namespace and release
name the chart is installed under.

### `RustAppHighErrorRate`: the E of RED

The expression is the error-rate query from Chapter 12, Step 7, compared with a
threshold: "more than 5% of requests returned a 5xx status, averaged over 5
minutes". Two details:

- **`or vector(0)`**: when there are no errors at all, the top of the fraction
  returns **no data**, and "no data divided by something" is no data, so the
  alert could never fire and could not even be evaluated as zero. `or vector(0)`
  replaces "no data" with `0`.
- **No traffic, no alert**: if there are no requests at all, the bottom is no
  data too, and the alert stays inactive. That is usually right (no users, no
  failing users), but it is also why the third alert exists.

`severity: critical`: failing requests are failing users.

### `RustAppPodsNotReady`: capacity

Both metrics come from **kube-state-metrics**: how many replicas the Deployment
**wants** (`spec_replicas`) and how many are **available** (ready). It fires
when fewer pods are ready than wanted for 2 minutes: the readiness probe fails,
pods crash, or a deployment is stuck. A rolling update passes through this
state for a few seconds, which `for: 2m` ignores.

`severity: warning`: with one of two pods unready, users may notice nothing,
but you are one failure away from an outage.

### `RustAppDown`: is anybody there?

`up` is the series Prometheus writes for every scrape: `1` if the scrape
worked, `0` if not. The expression has two halves, because "down" can look like
two different things:

- `sum(up{...}) == 0`: the targets exist, but none of them answers.
- `absent(up{...})`: there are **no targets at all**. When the Deployment is
  scaled to zero or deleted, the series simply disappear, and `sum(...) == 0`
  returns no data instead of zero. `absent()` returns `1` exactly when a series
  does not exist.

Forgetting the `absent()` case is one of the most common alerting mistakes: the
alert that should report a dead service goes silent precisely when the service
is completely gone.

### The escaping: two template languages in one file

The `description:` lines contain `{{ $value }}`, but this file is a Helm
template, and Helm would try to evaluate `{{ $value }}` itself, fail
(`undefined variable "$value"`), and stop. The value must reach Prometheus
unchanged, because Prometheus fills it in when the alert fires.

```yaml
description: '{{`{{ $value | humanizePercentage }}`}} of requests ...'
```

Read it from the outside in: `{{ ... }}` is a Helm expression; inside it,
`` `...` `` is a Go **raw string**, which Helm prints as it is. So Helm outputs
`{{ $value | humanizePercentage }}`, and Prometheus later turns that into
`23.5%`. The `summary` lines use `{{ $name }}`, which **is** meant for Helm, so
they need no escaping. Check the rendered result any time with:

```bash
helm template rust-app charts/rust-app --set image.repository=R --set image.tag=T \
  --api-versions monitoring.coreos.com/v1/PrometheusRule | grep -A3 'description'
```

`--api-versions` tells `helm template` to pretend the cluster has the
`PrometheusRule` kind, so the guarded template renders without a cluster.

## Step 2: Deploy and find the rules

The stack is running from Chapter 12, and `ruleSelectorNilUsesHelmValues: false`
(Chapter 12, Step 3) lets Prometheus pick up rules from your release. On the
server:

```bash
cd ~/rust-devops-app && git pull
./scripts/deploy.sh
kubectl get prometheusrule -n rust-app
```

`rust-app-alerts` is listed. In Prometheus, open **Alerts**. Find the group
`rust-app.rules`: three alerts, all `Inactive`, in green. The operator turned
your PrometheusRule into a rule file and told Prometheus to reload it.

The same page lists the stack's built-in rules, grouped by area:
`kubernetes-apps`, `node-exporter`, `kubernetes-resources` and many more. Two
are worth knowing:

- **`Watchdog`** is **always firing**. It is a heartbeat: it proves that the
  whole chain from Prometheus through Alertmanager works. Teams send it to a
  "dead man's switch" service that raises an alarm when the heartbeat
  **stops**. If monitoring itself breaks, nothing else would tell you.
- **`InfoInhibitor`** fires whenever an `info`-level alert fires, and is used
  only to hide those from notifications. You can ignore it.

## Step 3: Alertmanager

Open the Alertmanager URL from Chapter 12, Step 5 (`http://alertmanager.<ip>.nip.io`).
You see the alerts it currently holds, grouped. Right now, that is `Watchdog`
(and possibly `InfoInhibitor`).

Where do these alerts go? Look at the configuration the stack installed:

```bash
kubectl get secret -n monitoring alertmanager-kube-prometheus-stack-alertmanager \
  -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d
```

The important parts:

```yaml
route:
  group_by: ['namespace']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
  receiver: 'null'
  routes:
  - receiver: 'null'
    matchers:
    - alertname = "Watchdog"
receivers:
- name: 'null'
```

| Setting | Meaning |
|---|---|
| `group_by` | alerts with the same `namespace` become one notification |
| `group_wait` | wait 30 s after the first alert of a group, so related alerts arrive in the same message |
| `group_interval` | when a group changes, send an update at most every 5 minutes |
| `repeat_interval` | while an alert keeps firing, remind every 12 hours |
| `receiver: 'null'` | **send nowhere** |

So out of the box, alerts are evaluated, visible in both UIs, and delivered to
nobody. That is a safe default for a chart that cannot know your Slack
workspace, and it is enough for this chapter's drill. Step 6 adds a real
receiver.

## Step 4: A drill: break it and watch

Teams that trust their alerts **test** them, the same way they test code. You
will cause a database outage and a full service outage, and watch each alert
move from `inactive` through `pending` to `firing`, and back.

Use the in-cluster database for this, so that stopping it is one command. If
RDS is running, destroy it first (`terraform destroy -target=aws_db_instance.main`
on your laptop), then run `./scripts/deploy.sh`: it falls back to the in-cluster
PostgreSQL (Chapter 9).

Keep Prometheus's **Alerts** page open in your browser, and in a second browser
tab the **RustAppHighErrorRate** query from Step 1 in **Query → Graph**.

### Outage 1: the database goes away

On the server:

```bash
kubectl scale deployment/postgres -n rust-app --replicas=0
kubectl get pods -n rust-app -w
```

Within about 15 seconds, both `rust-app` pods show `0/1` ready: `/ready` checks
the database (Chapter 7). Press `Ctrl+C`. Now watch the Alerts page:

1. After about a minute, **`RustAppPodsNotReady`** turns yellow: `pending`.
   Prometheus has seen the condition, and `for: 2m` is counting.
2. Around the same time, **`RustAppHighErrorRate`** goes `pending` too, and
   your second tab shows the error rate jumping to well over 50%. Nobody is
   sending requests. Who is failing?
3. After two more minutes, both turn red: `firing`. They appear in
   Alertmanager, grouped under `namespace="rust-app"`.

The answer to point 2 is the **readiness probe itself**. Every 5 seconds, the
kubelet calls `/ready` on each pod, the middleware counts it, and with the
database gone, `/ready` returns `503`. Two pods, one `503` every 5 seconds each,
against one `200` from `/health` every 10 seconds: about two thirds of all
"requests" fail. The alert fires correctly, there is an outage, but for a
reason you did not design. In a real service with real traffic, probes are a
small share, but on a quiet service, probe traffic can dominate your error
rate. Practice exercise 1 fixes the expression.

Look at the alert's details in Prometheus: the `description` now reads
something like `67.2% of requests returned a 5xx status...`. That is the
escaped `{{ $value | humanizePercentage }}` from Step 1, filled in.

Restore the database:

```bash
kubectl scale deployment/postgres -n rust-app --replicas=1
kubectl rollout status deployment/postgres -n rust-app
kubectl rollout restart deployment/rust-app -n rust-app
```

The restart is needed for the reason from Chapter 7, Step 9: the new
PostgreSQL pod starts empty, and the migrations run when the application
starts. Within a few minutes, both alerts go back to `inactive`. In Alertmanager
they disappear; with a real receiver, it would now send a **resolved**
message.

### Outage 2: the service is gone

```bash
kubectl scale deployment/rust-app -n rust-app --replicas=0
```

The pods disappear, and with them the scrape targets. `sum(up) == 0` returns no
data, but `absent(up{...})` returns `1`, so **`RustAppDown`** goes `pending`,
and `firing` one minute later. `RustAppPodsNotReady` stays quiet: zero
available out of zero wanted is not "fewer than wanted". The two alerts cover
different failures, which is exactly the point.

Bring it back:

```bash
kubectl scale deployment/rust-app -n rust-app --replicas=2
```

You just ran a small **game day**: a planned failure to prove that detection
works. Teams do this regularly, because alerts that have never fired are alerts
nobody knows to be working.

## Step 5: Silences

Before planned maintenance, a database upgrade for example, you do not want to
be alerted about the outage you are causing. In Alertmanager, click **New
Silence**:

- **Matchers**: `namespace = rust-app` (all alerts of the service), or
  `alertname = RustAppPodsNotReady` (only one).
- **Duration**: `1h`.
- **Creator** and **Comment**: who and why. Write "DB maintenance, ticket 123",
  not "test".

Repeat Outage 1. Prometheus still shows the alerts as `firing`; the silence
only affects **notifications**, not evaluation. In Alertmanager, the alerts are
marked as silenced. When the silence expires, notifications resume, if the
problem is still there. Expire the silence by hand when you are done, and
restore the database as before.

## Step 6 (optional): Send alerts to Slack

If you have a Slack workspace you may use (a free personal one is fine), you
can send alerts to a channel. Create an **incoming webhook** for a channel such
as `#alerts` in Slack (search the Slack help for "incoming webhooks"). You get a
URL starting with `https://hooks.slack.com/services/`. That URL is a secret:
anyone who has it can post to your channel.

Store it in the cluster, never in Git. On the server:

```bash
kubectl create secret generic alertmanager-slack -n monitoring \
  --from-literal=url='https://hooks.slack.com/services/XXX/YYY/ZZZ'
```

Create `monitoring/alertmanager-slack.yaml` on your laptop. It contains no
secret, only where to find it:

```yaml
alertmanager:
  alertmanagerSpec:
    # Mounted at /etc/alertmanager/secrets/alertmanager-slack/<key>
    secrets:
      - alertmanager-slack
  config:
    route:
      group_by: ['namespace', 'alertname']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      receiver: 'null'
      routes:
        - receiver: 'null'
          matchers:
            - alertname = "Watchdog"
        - receiver: slack
          matchers:
            - namespace = "rust-app"
    receivers:
      - name: 'null'
      - name: slack
        slack_configs:
          - api_url_file: /etc/alertmanager/secrets/alertmanager-slack/url
            channel: '#alerts'
            send_resolved: true
```

**`alertmanagerSpec.secrets`** mounts the Kubernetes Secret into the
Alertmanager pod as files. **`api_url_file`** reads the webhook URL from that
file, so the URL never appears in the configuration, in Helm's history, or in
Git.

**The `routes` list** is checked from top to bottom, and the first match wins:
`Watchdog` still goes nowhere, everything from `rust-app` goes to Slack, the
rest (the stack's own alerts) falls through to `'null'`. Because Helm
**replaces** lists (Chapter 8, Step 9), this file must repeat the `Watchdog`
route and the `'null'` receiver from the default configuration; leave them out
and Alertmanager rejects the configuration for using an unknown receiver.

Commit and push the file, pull on the server, and add it to the stack:

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --reuse-values -f monitoring/alertmanager-slack.yaml --wait
```

Repeat Outage 1. About 30 seconds after the alerts fire (`group_wait`), one
Slack message arrives with both alerts, and a **resolved** message after you
restore the database.

`install-monitoring.sh` does not know about this file yet, so running the
script again would remove the Slack route. Practice exercise 4 fixes that.

## Troubleshooting

All of these happened while building this project, or are the classic first
mistakes with these tools.

**`Error: ... template: rust-app/templates/prometheusrule.yaml: ... undefined variable "$value"`.**
Helm tried to evaluate a Prometheus template. Escape it as in Step 1:
``{{`{{ $value }}`}}``.

**The `rust-app.rules` group does not appear on the Alerts page.** Prometheus
ignores the PrometheusRule: `ruleSelectorNilUsesHelmValues: false` is missing
from the stack's values (Chapter 12, Step 3), or the rule was never rendered
because the chart was deployed before the stack existed. Check
`kubectl get prometheusrule -n rust-app`, then rerun `deploy.sh`.

**The rule is there, but its expression has a syntax error.** The operator
validates PrometheusRules when they are created; Helm then fails with an
`admission webhook "prometheusrulevalidate.monitoring.coreos.com" denied the
request` message that names the bad expression. Test the expression in
**Query** first.

**`RustAppHighErrorRate` fires on a quiet service.** Probe requests make up most
of the traffic, and a failing `/ready` counts as a 5xx. Exclude the probe paths
from the expression (Practice 1).

**`RustAppDown` never fires when the Deployment is scaled to zero.** The
`absent()` half of the expression is missing: without targets there are no
series, and `sum(...) == 0` has nothing to compare.

**Built-in alerts such as `KubeControllerManagerDown` or `KubeSchedulerDown` fire all the time on k3s.**
k3s has no separate control-plane processes to scrape. Disable those components
in the stack's values (Chapter 12, Step 3).

**Alerts fire in Prometheus but no notification arrives.** In this setup that is
the default: every alert goes to the `'null'` receiver (Step 3). With Slack
configured, check the Alertmanager logs:
`kubectl logs -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager --tail=30`.
An error about the configuration means it was rejected; a `404` or
`invalid_token` from Slack means a wrong webhook URL.

**An alert stays `pending` and never fires.** The condition was not true for the
whole `for:` duration. A short gap, for example one successful scrape in the
middle of an outage, resets the timer. Look at the expression in **Graph** over
the last 15 minutes.

## What you learned

- What makes an alert worth having: symptoms over causes, an action for every
  alert, a waiting time, and severities that decide who is disturbed.
- How Prometheus evaluates rules (`inactive`, `pending`, `firing`) and what
  Alertmanager adds: grouping, deduplication, routing, silences and inhibition.
- How to ship alert rules with the application as a PrometheusRule in its Helm
  chart.
- How `or vector(0)` and `absent()` handle the "no data" cases that silently
  disable naive alerts.
- How to escape Prometheus templates inside Helm templates.
- What `Watchdog` is for, and why a heartbeat alert matters.
- How to test alerts with a planned failure, and how probe traffic can distort
  an error rate.
- How to silence alerts during maintenance, and how to send alerts to Slack
  without putting the webhook URL in Git.

## Practice

Each exercise says how long it takes and how much you type.

1. **Fix the error rate** (15 min, change 2 lines). Exclude the probe endpoints
   from both halves of the `RustAppHighErrorRate` expression with
   `path!~"/health|/ready"`, as the dashboard already does. Repeat Outage 1. Does
   the alert still fire without traffic? Should it? (Think about which alert
   *should* report this outage.)
2. **A latency alert** (20 min, about 12 lines). Add `RustAppSlowRequests`: p95
   latency of non-probe requests above 0.5 seconds for 5 minutes, severity
   `warning`. Test it with the database stopped: send requests to `/items` straight to
   a pod IP (`kubectl get pods -o wide`), from a pod started with
   `kubectl run curl --rm -it --image=curlimages/curl:8.16.0 --restart=Never -- sh`.
   Through the Service they would never arrive, because unready pods get no
   traffic. Each request waits for the 5-second `acquire_timeout` in `main.rs`
   before failing.
3. **Runbooks** (15 min, 3 lines). Add a `runbook_url` annotation to each alert,
   pointing to a section in your repository's README or the book (for example
   `https://<GITHUB_USER>.github.io/rust-devops-app/ch13-alerts.html#step-4-a-drill-break-it-and-watch`).
   Write two or three sentences per alert: what it means, the first three
   commands to run. Why is this the most useful thing you can add to an alert?
4. **Keep the Slack route** (15 min, about 5 lines). Teach
   `install-monitoring.sh` to add `monitoring/alertmanager-slack.yaml` with an
   extra `-f` when the file exists, so reruns keep the configuration.
5. **An inhibit rule** (20 min, about 8 lines, if you did Step 6). When
   `RustAppDown` fires, `RustAppPodsNotReady` is redundant noise. Add an
   `inhibit_rules` entry to the Alertmanager values that suppresses
   `RustAppPodsNotReady` while `RustAppDown` fires for the same namespace. Note
   that `inhibit_rules` is a list: what happens to the stack's default inhibit
   rules?
6. **SLOs, on paper** (20 min, reading). Look up **error budgets** and
   **multi-window, multi-burn-rate alerts** (the Google SRE workbook has a
   chapter on them). Write down an SLO for this service ("99.5% of requests
   succeed over 30 days") and how much downtime its error budget allows per
   month. Why do burn-rate alerts replace fixed thresholds like 5%?

Finish the session by destroying the server, as always.

## Interview questions

- What makes a good alert? Give an example of an alert you would not create.
- What is the difference between Prometheus alert rules and Alertmanager? Why
  are they separate?
- What do `pending` and `firing` mean? What is the `for:` clause for?
- Your error-rate alert never fires, even during an outage. What could be wrong
  with the expression?
- How do you alert on a service that has disappeared completely?
- What are grouping, inhibition and silences in Alertmanager?
- What is the `Watchdog` alert, and what is a dead man's switch?
- How do you test that your alerts work?
- How would you keep a Slack webhook URL or a PagerDuty key out of Git and out
  of Helm's release history?
- What is an SLO, and what is an error budget? How do they change the way you
  alert?
