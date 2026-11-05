# Load Balancing with the AWS Load Balancer Controller

At the end of the last chapter the application ran on EKS, but only
`kubectl port-forward` could reach it. The Ingress existed, with
`className: alb`, and its `ADDRESS` column stayed empty, because nothing in the
cluster acts on that class.

In this chapter you install the component that does: the **AWS Load Balancer
Controller**. It watches Ingress objects and turns each one into a real
**Application Load Balancer (ALB)** in your AWS account, with listeners, rules,
target groups and health checks, and keeps it up to date as pods come and go.
To do that, a pod in your cluster must call AWS APIs, which is the other topic
of this chapter: giving a pod its own IAM role with **EKS Pod Identity**.

> **Time and typing**
>
> | | |
> |---|---|
> | Reading | 45 min |
> | Hands-on | 75 min, plus about 10 min waiting for AWS |
> | Practice | 60 min |
> | Cost | everything from Chapter 10, plus the ALB (about 3 cents per hour): roughly 35 cents per hour in total. **Destroy it the same day**, in the order from Step 8. |
>
> **Copy:** the IAM policy file, `lbc.tf`, and the Helm command for the
> controller.
> **Type yourself:** the Pod Identity association and the role's trust policy
> in `lbc.tf` (Step 2, about 15 lines), and the cleanup order in Step 8. The
> first is how a pod gets AWS permissions; the second is how you avoid paying
> for load balancers nobody can see any more.

## The idea

### Four ways into a cluster

Kubernetes has several ways to expose an application. You have used two:

| Way | What you get | Used in |
|---|---|---|
| Service `ClusterIP` | a virtual IP inside the cluster only | every chapter |
| `kubectl port-forward` | a tunnel through the Kubernetes API, for one person | Chapter 10 |
| Service `type: LoadBalancer` | one cloud load balancer per Service (on EKS, a Network Load Balancer), TCP level | Practice 4 |
| **Ingress** + controller | HTTP routing: hosts, paths, health checks, many services behind one entry point | k3s (Traefik), and now EKS (ALB) |

An **Ingress** only describes HTTP routing. A **controller** makes it real. On
k3s, Traefik ran inside the cluster and received the traffic itself. The AWS
Load Balancer Controller works differently: it never receives a single user
request. It is an **operator**: it reads Ingress objects and creates AWS
resources that do the work.

```text
            ┌──────────────── your AWS account ─────────────────────┐
 browser ──▶│ ALB (public subnets)                                  │
            │   listener :80 ─▶ rule "/" ─▶ target group            │
            │                                │ targets = pod IPs    │
            │                                ▼                      │
            │   EKS node ── pod 10.0.1.66:8080   pod 10.0.1.87:8080 │
            │                                                       │
            │   kube-system: aws-load-balancer-controller pod ──────┼──▶ AWS APIs
            │      watches Ingresses, Services, pods                │   (create ALB,
            └───────────────────────────────────────────────────────┘    register targets)
```

### The parts of an ALB

The controller creates one ALB per Ingress (by default) and fills it in:

| ALB part | Comes from |
|---|---|
| **Scheme** (internet-facing or internal) | annotation `alb.ingress.kubernetes.io/scheme` |
| **Subnets** | subnets tagged `kubernetes.io/role/elb = 1`: the tags you added in Chapter 6 |
| **Security group** | created by the controller; open to `inbound-cidrs` |
| **Listener** (port 80) | the Ingress, HTTP by default |
| **Rules** (path `/` → target group) | the Ingress `rules` and `paths` |
| **Target group** and its **targets** | the Service behind the path, and its ready pods |
| **Health check** | annotation `healthcheck-path`, here `/ready` |

### Target type: instance or IP

An ALB can send traffic to targets of two types:

- **`instance`**: to a port on each **node** (a NodePort), from where
  `kube-proxy` forwards it to a pod, maybe on another node. Two hops.
- **`ip`**: straight to each **pod's IP address**. One hop.

`ip` only works because pods on EKS have real VPC addresses (Chapter 10, VPC
CNI). It is the better choice: the ALB's health checks test the pods
themselves, and a rolling update changes the ALB's targets pod by pod. That is
why `values-eks.yaml` sets `target-type: ip`.

### A pod with an IAM role

The controller must create load balancers, security groups and target groups,
so it needs AWS permissions. Where should they come from?

- **The node's IAM role**: every pod on the node would get the permissions,
  including your application. Far too broad.
- **Access keys in a Kubernetes Secret**: long-lived keys again, the problem
  you removed from CI in Chapter 4.
- **A role for this one pod**: the right answer. EKS has two mechanisms for it:
  **IRSA** (IAM Roles for Service Accounts, the older one, based on OIDC) and
  **EKS Pod Identity** (newer and simpler). This book uses Pod Identity.

With Pod Identity, three pieces connect a pod to a role:

```text
 Kubernetes service account          EKS pod identity association         IAM role
 kube-system/aws-load-balancer-  ─▶  (namespace + service account    ─▶  trusted by
 controller                           → role ARN)                         pods.eks.amazonaws.com
        ▲
        │ the controller pod runs as this service account
```

A small agent on each node (the **Pod Identity Agent**, an EKS add-on) hands
out temporary credentials to pods that run under an associated service
account. Nothing is stored in the cluster, and the credentials rotate on their
own. It is the same idea as OIDC in GitHub Actions: an identity that the cloud
trusts, exchanged for short-lived credentials.

## Step 1: The controller's IAM policy

The controller's project publishes the exact IAM policy it needs, one file per
release. Pick the controller version first, because newer controllers need
newer permissions. On the **admin host** (Session Manager, with the EKS
kubeconfig):

```bash
export KUBECONFIG=~/.kube/eks.yaml
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm search repo eks/aws-load-balancer-controller --versions | head -5
```

The output lists the **chart** version and the **app** (controller) version:

```text
NAME                               CHART VERSION   APP VERSION   DESCRIPTION
eks/aws-load-balancer-controller   1.x.y           v2.x.y        AWS Load Balancer Controller Helm chart for Kube...
```

Write both down; you need the app version now and the chart version in Step 4.
Then, **on your laptop**, in the repository root, download the policy for that
app version:

```bash
APP_VERSION=v2.x.y     # the APP VERSION from the table above
mkdir -p infra/terraform/policies
curl -fsSL -o infra/terraform/policies/aws-load-balancer-controller.json \
  "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${APP_VERSION}/docs/install/iam_policy.json"
grep -c '"Effect"' infra/terraform/policies/aws-load-balancer-controller.json
```

The last line counts the statements; a current policy has around 16. The file
contains no account-specific values, so it belongs in Git. Read the first few
statements: you will see `ec2:Describe*` actions, `elasticloadbalancing:Create*`
actions, and conditions on the tag `elbv2.k8s.aws/cluster`. The controller tags
everything it creates, and the policy only lets it modify resources carrying
that tag.

When you upgrade the controller later, download the policy for the new version
too. A controller that is newer than its policy fails with `AccessDenied` on
actions it did not need before.

## Step 2: Pod Identity and the role (`lbc.tf`)

Create `infra/terraform/lbc.tf`. Paste the add-on and the policy; **type** the
role's trust policy and the association:

```hcl
# EKS Pod Identity Agent: lets pods use IAM roles
resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "eks-pod-identity-agent"

  depends_on = [aws_eks_node_group.main]
}

# Official permissions for the AWS Load Balancer Controller
resource "aws_iam_policy" "lbc" {
  name   = "${local.name}-aws-load-balancer-controller"
  policy = file("${path.module}/policies/aws-load-balancer-controller.json")
}

# type this: role the controller pod uses (trusted by EKS Pod Identity)
resource "aws_iam_role" "lbc" {
  name = "${local.name}-aws-load-balancer-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

# type this: connect the role to the controller's Kubernetes service account
resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc.arn
}
```

**`aws_eks_addon`** installs the Pod Identity Agent as a managed EKS add-on: a
DaemonSet, one agent pod per node, kept up to date by AWS. It waits for the node
group (`depends_on`), since a DaemonSet needs nodes to run on.

**`file("${path.module}/policies/...")`** reads the JSON from Step 1.
`path.module` is the folder of the current `.tf` file, so the path works no
matter where you run Terraform from. Keeping a 250-line policy in its own file,
exactly as the project publishes it, also makes upgrades a matter of replacing
one file.

**The trust policy** trusts the service `pods.eks.amazonaws.com`, which is EKS
Pod Identity. `sts:TagSession` is required: Pod Identity tags each session with
the cluster, namespace and service account, which you could use in conditions.

**The association** is the link from the drawing above: pods running as the
service account `aws-load-balancer-controller` in `kube-system`, in this
cluster, get this role. The service account does not have to exist yet; the
Helm chart creates it in Step 4. The names must match **exactly**, or the
controller runs without credentials.

Compare this with **IRSA**, which you will meet in older projects: there, the
role's trust policy names the cluster's OIDC provider and a condition on the
service account, and the service account carries an annotation with the role
ARN. Pod Identity moves all of that into one association, and the same role can
be reused across clusters.

## Step 3: Apply

The EKS cluster from Chapter 10 must be running. On your laptop:

```bash
cd infra/terraform
terraform plan
```

Expect `5 to add`: the add-on, the policy, the role, the attachment and the
association. Then `terraform apply`. It takes a minute or two. Check the agent
on the admin host:

```bash
kubectl get daemonset -n kube-system eks-pod-identity-agent
```

`DESIRED 1, READY 1`: one agent on your one node.

## Step 4: Install the controller

On the admin host, with the chart version from Step 1 and your VPC ID (`terraform
output -raw vpc_id` on your laptop):

```bash
export KUBECONFIG=~/.kube/eks.yaml
CHART_VERSION=1.x.y          # CHART VERSION from Step 1
VPC_ID=vpc-xxxxxxxx          # from terraform output -raw vpc_id

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --version "$CHART_VERSION" \
  --set clusterName=rust-devops-eks \
  --set region=eu-central-1 \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set replicaCount=1 \
  --wait
```

| Setting | Why |
|---|---|
| `--version` | pins the chart, so the next install gives the same controller (and matches the policy from Step 1). Without it, Helm installs the newest one. |
| `clusterName` | the controller tags its resources with it and only manages resources of this cluster |
| `region`, `vpcId` | normally read from the instance metadata; passing them avoids a dependency on IMDS access from pods |
| `serviceAccount.name` | must be the name in the Pod Identity association |
| `replicaCount=1` | the chart's default is 2 for high availability; with one node, the second replica would only take up pod capacity |

Check it:

```bash
kubectl get deployment -n kube-system aws-load-balancer-controller
kubectl logs -n kube-system deployment/aws-load-balancer-controller --tail=20
```

`READY 1/1`, and the logs should show the controller starting and no
`AccessDenied`. Now confirm that Pod Identity really applies to this pod:

```bash
kubectl get pod -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller \
  -o jsonpath='{.items[0].spec.containers[0].env[*].name}'; echo
```

You should see `AWS_CONTAINER_CREDENTIALS_FULL_URI` and
`AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` among the names. EKS injects them into
pods whose service account has an association. They point to the Pod Identity
Agent, and the AWS SDK in the controller uses them automatically. If they are
missing, the pod was started before the association existed: restart it with
`kubectl rollout restart deployment/aws-load-balancer-controller -n kube-system`.

The controller also registers an **IngressClass** named `alb`:

```bash
kubectl get ingressclass
```

That is the name your chart's `ingress.className` refers to.

## Step 5: Deploy the application behind an ALB

The chart needs no changes; `values-eks.yaml` (Chapter 10, Step 7) already has
everything. Its three annotations, now that a controller reads them:

| Annotation | Meaning |
|---|---|
| `alb.ingress.kubernetes.io/scheme: internet-facing` | a public ALB in the subnets tagged `kubernetes.io/role/elb`. `internal` would use the private subnets. |
| `alb.ingress.kubernetes.io/target-type: ip` | targets are pod IPs (see "The idea") |
| `alb.ingress.kubernetes.io/healthcheck-path: /ready` | the ALB checks each pod at `/ready`; only healthy pods get traffic |

The fourth one is set at deploy time: who may connect. Without it, the ALB is
open to the whole internet. **On your laptop**, get your public IP:

```bash
curl -s https://checkip.amazonaws.com
```

Use this address, from your laptop. Running the same command on the admin host
would give the **server's** IP, and your laptop would be locked out. Then, on the
admin host, with your IP in place of `<YOUR_IP>`:

```bash
cd ~/rust-devops-app && git pull
KUBECONFIG=~/.kube/eks.yaml VALUES_FILE=charts/rust-app/values-eks.yaml \
  ALLOW_CIDR=<YOUR_IP>/32 ./scripts/deploy.sh
```

`deploy.sh` turns `ALLOW_CIDR` into the annotation
`alb.ingress.kubernetes.io/inbound-cidrs` (Chapter 9, Step 1), with the dots in
the key escaped for `--set-string`. The controller puts exactly that range into
the ALB's security group.

## Step 6: Watch the ALB appear

```bash
kubectl get ingress -n rust-app -w
```

Within a minute, the `ADDRESS` column shows a DNS name like
`k8s-rustapp-rustapp-ab9c0ba2d6-633159078.eu-central-1.elb.amazonaws.com`. Press
`Ctrl+C`. The ALB itself needs **two to three minutes** to become active, and
its DNS name can take a few minutes more to resolve. Then, **on your laptop**:

```bash
ALB=<the address from the ADDRESS column>
curl -s http://$ALB/health; echo
curl -s http://$ALB/items; echo
```

`ok` and your items. If `curl` says `Could not resolve host`, wait a minute and
try again: that is DNS, not an error (Troubleshooting).

Now look at what the controller built, in the console under **EC2 → Load
Balancers**:

- **The load balancer**: scheme `internet-facing`, two Availability Zones (your
  two public subnets), and a security group named `k8s-rustapp-rustapp-...`.
- **Listeners and rules**: one listener on HTTP:80, with a rule forwarding
  `/` to a target group.
- **Target groups** (left menu): the target group's **targets** are two IP
  addresses on port 8080, both `healthy`. Compare them with
  `kubectl get pods -n rust-app -o wide`: they are your pods' IPs.
- **The security group**: inbound HTTP 80 from `<YOUR_IP>/32` only.

Every one of these resources was created by a pod, through the IAM role from
Step 2. None of them is in your Terraform state. Remember that for Step 8.

Read the controller's view of the same Ingress:

```bash
kubectl describe ingress rust-app -n rust-app | tail -15
```

The `Events` at the bottom show `SuccessfullyReconciled`. When something is
wrong with an Ingress, this is where the controller tells you: invalid
annotations, missing subnets, missing permissions.

## Step 7: A rolling update through the ALB

Watch the targets while you deploy. The admin host's IAM role cannot read
load balancers (it does not need to), so run this part **on your laptop**:

```bash
TG=$(aws elbv2 describe-target-groups --region eu-central-1 \
  --query "TargetGroups[?starts_with(TargetGroupName, 'k8s-rustapp')].TargetGroupArn | [0]" --output text)
while true; do
  date +%T
  aws elbv2 describe-target-health --region eu-central-1 --target-group-arn "$TG" \
    --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text
  sleep 3
done
```

In Session Manager on the admin host, restart the deployment, which is a
rolling update with the same image:

```bash
KUBECONFIG=~/.kube/eks.yaml kubectl rollout restart deployment/rust-app -n rust-app
```

On your laptop you see new pod IPs appear as `initial` (the ALB is checking
them), become `healthy`, and old IPs go to `draining` before they disappear.
**Draining** means the ALB stops sending new requests to a target but lets
running ones finish, for up to the target group's **deregistration delay**
(300 seconds by default). Together with the graceful shutdown from Chapter 1,
this is what makes a deployment invisible to users.

There is a small gap in this picture: Kubernetes marks a new pod ready as soon
as **its own** readiness probe passes, which can be before the **ALB's** health
check does. For a short moment, the old pod may be stopped while the new one is
still `initial` in the target group. Practice exercise 3 closes the gap with
**pod readiness gates**.

Press `Ctrl+C` on your laptop when the rollout is done.

## Step 8: Clean up, in the right order

This step matters more than in any chapter before. The ALB, its security group
and its target group were created by the controller, not by Terraform.
Terraform does not know they exist. If you destroy the cluster first, the
controller is gone, nobody deletes the ALB, and it keeps billing you. Worse, the
ALB and its security group still sit in your subnets, so a later
`terraform destroy` of the network fails with `DependencyViolation`.

The rule: **the component that created a resource must delete it.** Type these
steps yourself, in this order.

1. **Admin host**: remove the app. Deleting its Ingress makes the controller
   delete the ALB.

   ```bash
   export KUBECONFIG=~/.kube/eks.yaml
   helm uninstall rust-app -n rust-app
   ```

2. **Laptop**: wait until the ALB is really gone. Run this until it prints
   nothing (usually within a minute):

   ```bash
   aws elbv2 describe-load-balancers --region eu-central-1 \
     --query "LoadBalancers[?starts_with(LoadBalancerName, 'k8s-')].LoadBalancerName" --output text
   ```

3. **Admin host**: only now remove the controller.

   ```bash
   helm uninstall aws-load-balancer-controller -n kube-system
   ```

Then, on your laptop, destroy the cluster, the server and the database as in
Chapter 10, Step 9. Finally, check **EC2 → Load Balancers** and **EC2 → Target
Groups**: both should be empty.

If you ever find an orphaned ALB after a cluster is gone, delete it by hand in
the console (load balancer first, then its target groups, then its
`k8s-...` security group).

## Troubleshooting

All of these happened while building this project.

**The Ingress never gets an `ADDRESS`, and `describe` shows no events.**
No controller handles its class. Either the controller is not installed or not
running (`kubectl get deployment -n kube-system aws-load-balancer-controller`),
or the Ingress has the wrong class. A deployment without
`VALUES_FILE=charts/rust-app/values-eks.yaml` creates an Ingress with class
`traefik`, which nothing on EKS serves. Check the `CLASS` column of
`kubectl get ingress -A`.

**`Failed build model due to ingress: rust-app/rust-app: invalid inbound-cidrs settings on Ingress: ... invalid CIDR address: YOUR.IP.ADDRESS/32`.**
A placeholder from the instructions ended up in the annotation. Run the deploy
again with your real IP (Step 5). The controller retries on its own once the
annotation is valid.

**`Failed add finalizer due to Internal error occurred: failed calling webhook "vingress.elbv2.k8s.aws": ... no endpoints available for service "aws-load-balancer-webhook-service"`.**
The controller also runs a **webhook** that Kubernetes asks to validate every
Ingress. This message means the Ingress was created while the controller pod was
not ready yet (just installed, restarting, or crashing). Check that the
controller is `1/1`. Once it is, the controller reconciles the Ingress on its
own; if not, re-run the deploy.

**`curl: (6) Could not resolve host: k8s-rustapp-rustapp-....elb.amazonaws.com`.**
The ALB exists, but its DNS name is not resolvable yet. New ALBs take a few
minutes. Wait and retry. Check the state on your laptop with
`aws elbv2 describe-load-balancers --region eu-central-1 --query 'LoadBalancers[].[LoadBalancerName,State.Code]' --output table`;
it must be `active`.

**The ALB answers `404 Not Found` with `Server: awselb/2.0`.**
The request reached the ALB, but no rule matched, so the ALB answered itself.
The most common cause is `pathType: ImplementationSpecific` on an Ingress
path `/`: the ALB then matches **only** `/` exactly, and every other path
(`/health`, `/items`) gets the default 404. Use `pathType: Prefix`, as this
book's chart does. Charts from other projects (the monitoring stack, for
example) often default to `ImplementationSpecific`; set it in their values.

**The ALB answers `502 Bad Gateway` or `503 Service Temporarily Unavailable`.**
No healthy targets. Check the target group's targets in the console, or run
`aws elbv2 describe-target-health` on your laptop. Unhealthy targets mean the health check
fails: wrong `healthcheck-path`, or the pods' `/ready` fails because the
database is unreachable. No targets at all mean the Service has no ready pods.

**`curl` from your laptop times out, but the ALB is `active` and targets are healthy.**
The ALB's security group does not allow your IP: your IP changed, or
`ALLOW_CIDR` was the admin host's address. Re-run the deploy with the IP from
`curl -s https://checkip.amazonaws.com` **on your laptop**.

**`helm: command not found` on your laptop.**
In this book, Helm and `kubectl` run on the admin host, not on your laptop. Run
the `helm` commands in Session Manager.

**The controller logs show `AccessDenied` for an action such as `elasticloadbalancing:DescribeListenerAttributes`.**
The IAM policy is older than the controller. Download the policy for the
controller's app version (Step 1), `terraform apply`, and restart the
controller. If **every** call is denied, the pod has no Pod Identity
credentials: check the environment variables from Step 4 and that the
association's namespace and service account name match exactly.

**`terraform destroy` fails with `DependencyViolation` on a subnet or security group.**
An ALB or a `k8s-...` security group created by the controller is still there,
because the cluster was destroyed before the Helm releases were uninstalled.
Delete them in the console (Step 8), then run `terraform destroy` again.

## What you learned

- The ways to expose an application in Kubernetes, and what an Ingress
  controller adds.
- How the AWS Load Balancer Controller works as an operator: it never handles
  traffic itself, but turns Ingress objects into ALBs, listeners, rules, target
  groups and security groups.
- How the ALB's settings come from the Ingress, its annotations, and the subnet
  tags from Chapter 6.
- The difference between `instance` and `ip` targets, and why `ip` fits EKS.
- How EKS Pod Identity gives one pod its own IAM role, and how it compares with
  node roles, stored keys and IRSA.
- Why the controller's IAM policy must match its version, and why chart
  versions are pinned.
- How targets register, pass health checks and drain during a rolling update.
- Why resources created by controllers must be deleted by those controllers,
  before the cluster is destroyed.

## Practice

Each exercise says how long it takes and how much you type.

1. **One ALB for several Ingresses** (20 min, 1 annotation). Every Ingress gets
   its own ALB by default, at about 3 cents per hour each. Add
   `alb.ingress.kubernetes.io/group.name: rust-devops` to `values-eks.yaml` and
   to a second, small test Ingress. Check in the console that both share one
   ALB, with one rule each. This matters in the Monitoring chapter, which adds
   three more Ingresses.
2. **Instance targets** (15 min, change 1 value). Deploy once with
   `target-type: instance`. What changes in the target group's targets? What
   does the chart need for this to work? (Hint: the Service type.) Switch back
   to `ip` afterwards.
3. **Pod readiness gates** (20 min, 1 command). Label the namespace with
   `kubectl label namespace rust-app elbv2.k8s.aws/pod-readiness-gate-inject=enabled`,
   restart the deployment, and look at `kubectl get pods -o wide`: a new
   `READINESS GATES` column appears. Explain what problem from Step 7 this
   solves.
4. **A Network Load Balancer** (20 min, about 10 lines). Create a second
   Service of `type: LoadBalancer` for the app, with the annotation
   `service.beta.kubernetes.io/aws-load-balancer-type: external` and
   `service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip`. The same
   controller creates an NLB. When would you choose an NLB over an ALB? Delete
   the Service before cleaning up.
5. **HTTPS, on paper** (15 min, reading). Look up the annotations
   `alb.ingress.kubernetes.io/certificate-arn` and `listen-ports`, and AWS
   Certificate Manager. Write down the steps to serve the app on
   `https://api.example.com` with a redirect from HTTP. What would you need
   that this project does not have? (A domain.)

Finish the session with Step 8, in that order.

## Interview questions

- What is the difference between a Service of type `LoadBalancer` and an
  Ingress? When would you use each?
- How does the AWS Load Balancer Controller work? Does traffic pass through the
  controller pod?
- How does the controller choose subnets for an ALB?
- Explain `target-type: ip` and `target-type: instance`. Which do you prefer on
  EKS, and why?
- How do pods get AWS permissions on EKS? Compare node roles, IRSA and EKS Pod
  Identity.
- An ALB returns `404` from `awselb/2.0`. Another returns `502`. What does each
  tell you, and where do you look?
- What happens to in-flight requests when a pod behind an ALB is replaced? What
  are draining and the deregistration delay?
- Why must you delete Ingresses before destroying the cluster? What happens if
  you do not?
- How would you limit an internet-facing ALB to certain users or networks?
- Why pin the controller's chart version, and what must change together with
  it?
