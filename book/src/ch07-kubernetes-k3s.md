# Kubernetes on k3s

The application is built, tested, packaged, and stored in ECR. The database is
waiting in a private subnet. Now the application needs somewhere to run: a
place that starts it, restarts it when it crashes, runs more than one copy,
replaces old versions with new ones without downtime, and routes traffic to
whichever copies are healthy.

That is what **Kubernetes** does. This chapter builds the smallest real
Kubernetes cluster that is still useful: **k3s** on a single EC2 instance. You
create the server with Terraform, connect to it without SSH, and deploy the
application with plain YAML files, so you see every object Kubernetes uses
before Helm (next chapter) hides them behind templates.

This is the longest chapter in the book, and the most important one if
Kubernetes is new to you. Take it slowly. The commands are short; the ideas
behind them are what matters.

> **Time and typing**
>
> | | |
> |---|---|
> | Reading | 60 min |
> | Hands-on | 2 h, plus 5 min waiting for the server to boot |
> | Practice | 90 min |
> | Cost | `t3.small`: about 2.5 cents per hour; `m7i-flex.large`: about 10 cents per hour, while it runs |
>
> **Copy:** `k3s.tf`, `k8s/postgres.yaml`, and `k8s/app.yaml` are complete files.
> **Type yourself:** the `selector`, `labels`, and the two probes in the
> Deployment (Step 7, about 15 lines). Labels and selectors are how every
> Kubernetes object finds every other one; if you understand those 15 lines, you
> understand most of Kubernetes. Every `kubectl` command in this chapter is one
> line and is meant to be typed: they are short, and you will use them every
> day.

## The idea

### Desired state, again

Kubernetes works like Terraform, but it never stops. You tell it the **desired
state** ("two copies of this image, each with 128 MiB of memory, reachable
under the name `rust-app`"), and a set of **controllers** compares that with
reality, over and over, and fixes any difference:

```text
   you: kubectl apply -f app.yaml
              │
              ▼
   ┌─────────────────────┐      watches      ┌──────────────────────┐
   │ API server + etcd   │◀─────────────────▶│ controllers          │
   │ (the desired state) │                   │ "2 pods wanted,      │
   └─────────────────────┘                   │  1 running: start 1" │
              ▲                              └──────────────────────┘
              │ reports status
   ┌─────────────────────┐
   │ kubelet on the node │  starts and stops containers (containerd)
   └─────────────────────┘
```

When a container crashes, nobody runs a command. A controller notices that
reality (1 pod) no longer matches the desired state (2 pods) and starts a new
one. This loop is called **reconciliation**, and it explains almost every
behaviour you will see in this chapter.

### The cluster

A cluster has two parts:

- The **control plane** stores the desired state and runs the controllers:
  the **API server** (everything, including `kubectl`, talks to it), **etcd**
  (the database behind it), the **scheduler** (decides which node runs a pod),
  and the **controller manager**.
- **Nodes** are the machines that run your containers. Each node runs a
  **kubelet** (the agent that talks to the API server) and a **container
  runtime** (containerd).

In a managed service such as EKS (Chapter 10), AWS runs the control plane for
you. In k3s, both parts run in one process on one machine. That makes k3s ideal
for learning: everything that is hidden in EKS is visible on your own server.

### The objects you will use

| Object | What it is | Analogy |
|---|---|---|
| **Pod** | One or more containers that run together on one node, with one IP address | one running copy of the app |
| **Deployment** | Keeps N identical pods running and replaces them during updates | the shift manager |
| **ReplicaSet** | Created by a Deployment; one per version of the pod template | one shift's roster |
| **Service** | A stable name and IP in front of a changing set of pods | the phone number that always reaches whoever is on duty |
| **Ingress** | HTTP routing from outside the cluster to Services | the reception desk |
| **Namespace** | A folder for objects; names must be unique within it | a department |
| **Secret** / **ConfigMap** | Configuration handed to pods, sensitive / not sensitive | the envelope with the keys |

You almost never create Pods or ReplicaSets yourself. You create a Deployment,
and it creates the rest.

### Labels and selectors

Objects do not point at each other by name. They use **labels** (key/value
pairs on an object) and **selectors** (queries for labels):

```text
 Deployment  ── selector: app=rust-app ──▶  pods with label app=rust-app
 Service     ── selector: app=rust-app ──▶  the same pods
```

A Service does not know about the Deployment at all. It sends traffic to any
pod that carries the label and is **ready**. This loose coupling is what makes
rolling updates possible: during an update, old and new pods both carry the
label, and the Service sends traffic to whichever of them are ready.

### Why k3s

k3s is a complete, certified Kubernetes distribution packaged as one binary of
about 70 MB. It includes everything a small cluster needs:

| Component | Job |
|---|---|
| containerd | runs the containers |
| CoreDNS | gives every Service a DNS name |
| Traefik | the Ingress controller: receives HTTP on port 80 |
| ServiceLB | exposes Traefik on the node's own IP address |
| local-path provisioner | creates disk volumes on the node |
| metrics-server | makes `kubectl top` work |

On EKS you will install some of these yourself. Here, they are ready a minute
after installation.

## Step 1: The server (`k3s.tf`)

First add two variables to `infra/terraform/variables.tf`:

```hcl
variable "my_ip_cidr" {
  type        = string
  description = "Your public IP in CIDR form, e.g. 203.0.113.10/32"
}

variable "k3s_instance_type" {
  type        = string
  description = "EC2 instance type for the k3s node"
  default     = "t3.small"
}
```

and your IP to `terraform.tfvars` (which is git-ignored). This one paste does
it for you:

```bash
echo "my_ip_cidr = \"$(curl -s https://checkip.amazonaws.com)/32\"" >> terraform.tfvars
tail -1 terraform.tfvars
```

`t3.small` (2 vCPUs, 2 GiB) is enough for this chapter. When you add monitoring
later, use `m7i-flex.large` (8 GiB) by setting
`k3s_instance_type = "m7i-flex.large"` in `terraform.tfvars`.

Now create `infra/terraform/k3s.tf` and paste the whole file:

```hcl
# Latest official Ubuntu 24.04 image, looked up from AWS
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# --- Identity: what the server may do in AWS ------------------------------
resource "aws_iam_role" "k3s_node" {
  name = "${local.name}-k3s-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Browser terminal through Session Manager (no SSH, no port 22)
resource "aws_iam_role_policy_attachment" "k3s_ssm" {
  role       = aws_iam_role.k3s_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Pull images from ECR
resource "aws_iam_role_policy_attachment" "k3s_ecr" {
  role       = aws_iam_role.k3s_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Find the database and read its password
resource "aws_iam_role_policy" "k3s_read_db_secret" {
  name = "read-db-secret"
  role = aws_iam_role.k3s_node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DescribeDatabase"
        Effect   = "Allow"
        Action   = "rds:DescribeDBInstances"
        Resource = "arn:aws:rds:eu-central-1:${data.aws_caller_identity.current.account_id}:db:${local.name}-db"
      },
      {
        Sid      = "ReadRdsManagedSecret"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = "arn:aws:secretsmanager:eu-central-1:${data.aws_caller_identity.current.account_id}:secret:rds!db-*"
      },
    ]
  })
}

# EC2 needs the role wrapped in an "instance profile"
resource "aws_iam_instance_profile" "k3s_node" {
  name = "${local.name}-k3s-node"
  role = aws_iam_role.k3s_node.name
}

# --- Firewall: HTTP from your IP only, everything may go out --------------
resource "aws_security_group" "k3s" {
  name        = "${local.name}-k3s-sg"
  description = "k3s node: HTTP from my IP, all outbound"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-k3s-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "k3s_http_from_me" {
  security_group_id = aws_security_group.k3s.id
  description       = "HTTP from my IP only"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = var.my_ip_cidr
}

resource "aws_vpc_security_group_egress_rule" "k3s_all_out" {
  security_group_id = aws_security_group.k3s.id
  description       = "Allow all outbound traffic"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- The server ------------------------------------------------------------
resource "aws_instance" "k3s" {
  ami                    = data.aws_ssm_parameter.ubuntu.value
  instance_type          = var.k3s_instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.k3s.id]
  iam_instance_profile   = aws_iam_instance_profile.k3s_node.name

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  # Runs once, at first boot
  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh -

    # Wait until snap is ready after first boot, then install tools
    snap wait system seed.loaded
    snap install aws-cli --classic
    snap install helm --classic

    # Let kubectl and Helm find the cluster in every interactive shell
    echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> /etc/bash.bashrc
  EOF
  user_data_replace_on_change = true

  tags = { Name = "${local.name}-k3s" }
}

output "k3s_instance_id" {
  value = aws_instance.k3s.id
}

output "k3s_public_ip" {
  value = aws_instance.k3s.public_ip
}
```

What is new here:

**`data "aws_ssm_parameter" "ubuntu"`**: AMI IDs differ per region and change
with every Ubuntu update. Canonical publishes the current ID in a public SSM
parameter, so you never hard-code one.

**The role and the instance profile.** The server gets AWS permissions the
same way GitHub Actions does: by assuming a role. The difference is in the
trust policy: here the principal is the **EC2 service**, not an OIDC provider.
Software on the instance (the AWS CLI, the k3s image pulls) gets temporary
credentials automatically from the instance metadata service. No access keys
exist anywhere. The **instance profile** is just the container EC2 needs to
attach a role to an instance.

The role has exactly three jobs: Session Manager, reading from ECR, and reading
the database secret. It cannot push images, change infrastructure, or read any
other secret.

**The security group** allows one thing in: port 80, from your IP. There is no
port 22. You will reach the shell through **Session Manager**, which works the
other way round: the SSM agent on the instance opens an **outbound** connection
to AWS, and your terminal session travels through it. No inbound port, no SSH
key to lose, and every session is logged in CloudTrail.

**`user_data`** is a script that runs once, as root, at first boot (through
cloud-init). It installs k3s with the official script, then the AWS CLI and
Helm. `--write-kubeconfig-mode 644` makes the cluster's credentials file
readable by non-root users, so `kubectl` works without `sudo`. On a shared
server you would not do this; here, you are the only user.

**`user_data_replace_on_change = true`**: user data only runs at first boot, so
changing it on an existing instance would do nothing. This setting makes
Terraform replace the instance instead, so the script always matches the
server.

## Step 2: Create it

```bash
terraform fmt && terraform validate && terraform plan
```

Read the plan. You should see the role, three policies, the instance profile,
the security group and its two rules, and the instance: `9 to add`. Then:

```bash
terraform apply
terraform output k3s_public_ip
```

The instance is running within a minute, but `user_data` needs another 2 to 3
minutes to install everything. Give it that time before you connect.

## Step 3: Connect with Session Manager

In the AWS console, go to **EC2 → Instances**, select `rust-devops-k3s`, click
**Connect**, choose the **Session Manager** tab, and click **Connect**. A
terminal opens in your browser.

Session Manager starts a plain `sh` as the user `ssm-user`. Switch to bash and
your home folder:

```bash
bash
cd
```

First, check that the boot script finished:

```bash
cloud-init status --wait
```

It prints `status: done` when user data is complete. If it prints `error`, look
at `sudo tail -50 /var/log/cloud-init-output.log`.

Now meet your cluster:

```bash
kubectl get nodes -o wide
```

```text
NAME              STATUS   ROLES           AGE   VERSION         INTERNAL-IP
ip-10-0-1-23      Ready    control-plane   3m    v1.xx.x+k3s1    10.0.1.23
```

One node, which is both control plane and worker. Its name comes from its
private IP in the public subnet you created in Chapter 6.

```bash
kubectl get pods -A
```

`-A` means all namespaces. You see the components from the table in "The idea",
all running in the `kube-system` namespace:

```text
NAMESPACE     NAME                                      READY   STATUS      RESTARTS
kube-system   coredns-...                               1/1     Running     0
kube-system   local-path-provisioner-...                1/1     Running     0
kube-system   metrics-server-...                        1/1     Running     0
kube-system   helm-install-traefik-crd-...              0/1     Completed   0
kube-system   helm-install-traefik-...                  0/1     Completed   0
kube-system   svclb-traefik-...                         2/2     Running     0
kube-system   traefik-...                               1/1     Running     0
```

The `helm-install-*` pods are one-off jobs that k3s uses to install Traefik;
`Completed` is their success state. `kube-system` belongs to the cluster
itself: look, but do not deploy your own things there.

Finally, get the repository onto the server. It is public, so no credentials
are needed:

```bash
git clone https://github.com/<GITHUB_USER>/rust-devops-app.git
cd rust-devops-app
```

The rule for this server: **never edit files here.** Change code on your
laptop, push, and run `git pull` on the server. Otherwise the server and the
repository drift apart, and the next `git pull` ends in a conflict.

## Step 4: Your first pod, by hand

Before writing any YAML, see the basic loop with one command:

```bash
kubectl run hello --image=nginx:1.29
kubectl get pods -w
```

`-w` (watch) keeps printing changes. You see `ContainerCreating` while the image
is pulled, then `Running`. Press `Ctrl+C` to stop watching.

Look at it from every angle. These four commands are your entire debugging
toolkit, and you will use them in exactly this order whenever something is
wrong:

```bash
kubectl get pod hello -o wide      # 1. state, node, pod IP
kubectl describe pod hello         # 2. details + Events at the bottom
kubectl logs hello                 # 3. what the container printed
kubectl exec -it hello -- sh       # 4. a shell inside the container
```

In the `describe` output, scroll to **Events**: `Scheduled`, `Pulling`,
`Pulled`, `Created`, `Started`. When a pod is stuck, the reason is almost
always there. Type `exit` to leave the container shell.

Now delete it:

```bash
kubectl delete pod hello
kubectl get pods
```

It is gone, and it stays gone. A bare pod has no controller watching it, so
nothing brings it back. That is why you never run bare pods for real work.

## Step 5: A namespace and a database

Everything for the application goes into its own namespace:

```bash
kubectl create namespace rust-app
kubectl config set-context --current --namespace=rust-app
```

The second command makes `rust-app` your default, so you can leave out
`-n rust-app` from now on. (`kubectl config view --minify | grep namespace`
shows the current one.)

You have two databases to choose from: RDS from Chapter 6, or a throwaway
PostgreSQL inside the cluster. Start with the in-cluster one. It is free, it
starts in seconds, and it lets you learn Kubernetes without waiting for RDS.
You switch to RDS in Step 10.

The repository already contains `k8s/postgres.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-credentials
  namespace: rust-app
type: Opaque
stringData:
  POSTGRES_USER: app
  POSTGRES_PASSWORD: app        # learning only: throwaway in-cluster database
  POSTGRES_DB: app
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: rust-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16
          ports:
            - containerPort: 5432
          envFrom:
            - secretRef:
                name: postgres-credentials
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "app", "-d", "app"]
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: rust-app
spec:
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
```

Three objects in one file, separated by `---`. Every Kubernetes object has the
same four top-level fields:

| Field | Meaning |
|---|---|
| `apiVersion` | which API group and version defines this kind (`v1`, `apps/v1`, ...) |
| `kind` | what it is |
| `metadata` | name, namespace, labels |
| `spec` | the desired state; its shape depends on the kind |

Kubernetes adds a fifth, `status`, which reports the actual state. You never
write it.

Read the three objects:

- The **Secret** holds the credentials. `stringData` lets you write plain text;
  Kubernetes stores it base64-encoded under `data`. Base64 is an encoding, not
  encryption: anyone who can read Secrets in this namespace can read the
  password. That is acceptable for a throwaway database, and the reason the
  real password comes from Secrets Manager.
- The **Deployment** runs one pod. `envFrom.secretRef` turns every key in the
  Secret into an environment variable, which is how the official `postgres`
  image expects its settings.
- The **Service** gives the pod a stable name: `postgres`.

Note that there is no volume. When this pod is replaced, the data is gone. For
learning, that is a feature: every restart is a clean database.

Apply it and watch it start:

```bash
kubectl apply -f k8s/postgres.yaml
kubectl rollout status deployment/postgres
kubectl get deploy,rs,pods,svc
```

The last command shows the whole chain the Deployment created:

```text
NAME                       READY   UP-TO-DATE   AVAILABLE
deployment.apps/postgres   1/1     1            1

NAME                                  DESIRED   CURRENT   READY
replicaset.apps/postgres-7d9f8c6b5d   1         1         1

NAME                            READY   STATUS    RESTARTS
pod/postgres-7d9f8c6b5d-x2k8p   1/1     Running   0

NAME               TYPE        CLUSTER-IP     PORT(S)
service/postgres   ClusterIP   10.43.17.201   5432/TCP
```

Look at the names: the ReplicaSet is `postgres-<hash of the pod template>`, and
the pod is `<replicaset>-<random>`. You can tell from a pod's name which
Deployment and which version it belongs to.

### How the name `postgres` works

The Service got a **ClusterIP**, a virtual IP that exists only inside the
cluster, and CoreDNS gives it DNS names:

```text
postgres                                  (from the same namespace)
postgres.rust-app                         (from another namespace)
postgres.rust-app.svc.cluster.local       (fully qualified)
```

Check it from a temporary pod:

```bash
kubectl run dns-test --rm -it --image=busybox:1.37 --restart=Never -- nslookup postgres
```

`--rm -it --restart=Never` is a useful pattern: run one command in a throwaway
pod, show the output, and delete the pod afterwards.

## Step 6: Let the cluster pull from ECR

The application image is in a private ECR repository. The node's IAM role is
allowed to read it, but Kubernetes does not use the node's AWS credentials on
its own. It needs a **pull secret**: a Secret of type
`kubernetes.io/dockerconfigjson` containing a registry login.

Paste this block:

```bash
REGION=eu-central-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

kubectl create secret docker-registry ecr-credentials \
  --docker-server="$REGISTRY" \
  --docker-username=AWS \
  --docker-password="$(aws ecr get-login-password --region $REGION)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

`aws ecr get-login-password` uses the **node's role** to get a token, and
`kubectl` stores it in the cluster. Two patterns in this block are worth
remembering:

- **`--dry-run=client -o yaml | kubectl apply -f -`** turns an imperative
  `create` into a declarative `apply`: the first command only prints the YAML,
  and `apply` creates the Secret or updates it if it exists. A plain `create`
  would fail with `AlreadyExists` the second time.
- **The token expires after 12 hours.** After that, pods that are already
  running keep running, but new pods (a restart, a scale-up, a new version)
  fail with `ImagePullBackOff`. The deploy script in Chapter 9 refreshes the
  secret on every deployment. Practice exercise 5 shows the more robust
  alternative.

Now pick the image to deploy: the newest tagged image in ECR.

```bash
TAG=$(aws ecr describe-images --repository-name rust-devops-app --region $REGION \
  --query 'sort_by(imageDetails[?imageTags], &imagePushedAt)[-1].imageTags[0]' --output text)
export IMAGE="$REGISTRY/rust-devops-app:$TAG"
echo "$IMAGE"
```

If it prints `None`, the repository has no tagged images yet: push to `main`
and let CI build one (Chapter 4).

These variables only live in this terminal session. If you reconnect, paste
the two blocks again.

## Step 7: The application

The application needs four objects: a Secret with `DATABASE_URL`, a
Deployment, a Service, and an Ingress. Create the Secret directly:

```bash
kubectl create secret generic rust-app-db \
  --from-literal=DATABASE_URL=postgres://app:app@postgres:5432/app
```

The host in the URL is `postgres`: the Service name from Step 5.

On your **laptop**, create `k8s/app.yaml` (push it, then `git pull` on the
server). Paste everything, then type the parts marked `# type this` yourself:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rust-app
  labels:
    app: rust-app
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:                     # type this
    matchLabels:                # type this
      app: rust-app             # type this
  template:
    metadata:
      labels:                   # type this
        app: rust-app           # type this
    spec:
      imagePullSecrets:
        - name: ecr-credentials
      containers:
        - name: app
          image: IMAGE_PLACEHOLDER
          ports:
            - containerPort: 8080
          envFrom:
            - secretRef:
                name: rust-app-db
          livenessProbe:          # type this
            httpGet:              # type this
              path: /health       # type this
              port: 8080          # type this
            periodSeconds: 10     # type this
          readinessProbe:         # type this
            httpGet:              # type this
              path: /ready        # type this
              port: 8080          # type this
            periodSeconds: 5      # type this
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: rust-app
spec:
  selector:
    app: rust-app
  ports:
    - name: http
      port: 80
      targetPort: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: rust-app
spec:
  ingressClassName: traefik
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: rust-app
                port:
                  number: 80
```

### The Deployment, line by line

**`selector` and `template.metadata.labels`** must match. The selector says
"the pods I manage are the ones labelled `app: rust-app`", and the template
says "every pod I create gets the label `app: rust-app`". If they do not
match, the API server rejects the Deployment. The selector cannot be changed
after creation; changing it means deleting and recreating the Deployment.

**`strategy`**: during an update, `maxSurge: 1` allows one extra pod (3 while
the update runs), and `maxUnavailable: 0` means the number of ready pods must
never drop below 2. The update therefore goes: start one new pod, wait until it
is ready, stop one old pod, repeat. Users never see fewer than two working
copies.

**The two probes** are where the `/health` and `/ready` endpoints from Chapter 1
pay off:

| | Liveness (`/health`) | Readiness (`/ready`) |
|---|---|---|
| Question | Is the process stuck? | Can it serve traffic right now? |
| When it fails | the kubelet **restarts** the container | the pod is **removed from the Service** until it passes again |
| Our endpoint | returns 200 if the process responds | returns 200 only if the database answers |

Mixing these up is a classic mistake. If liveness checked the database, a
short database outage would make Kubernetes restart every pod in a loop, which
does not fix the database and makes everything worse. With the split, a
database outage makes pods unready (no traffic, no restarts), and they return
on their own when the database is back.

**`resources`**: `requests` is what the scheduler reserves on the node (50
millicores = 5% of a CPU, 32 MiB). `limits.memory` is a hard ceiling: if the
container uses more than 128 MiB, the kernel kills it (`OOMKilled`). There is
deliberately no CPU limit: a CPU limit throttles the process even when the
node is idle, while CPU requests already guarantee each pod its share under
contention.

**`envFrom.secretRef`** turns the Secret's `DATABASE_URL` key into an
environment variable, which is exactly what `main.rs` reads.

**`image: IMAGE_PLACEHOLDER`** is replaced when you apply the file, in the next
step. The file in Git never contains your account ID.

### The Service and the Ingress

The **Service** listens on port 80 and forwards to port 8080 on any ready pod
with the label `app: rust-app`. Its type is `ClusterIP` (the default): it is
reachable only inside the cluster.

The **Ingress** says: "HTTP requests for any host, on any path starting with
`/`, go to the Service `rust-app` on port 80". It does nothing by itself; an
**Ingress controller** reads it and configures itself. In k3s that is Traefik,
which ServiceLB exposes on port 80 of the node. The whole path of a request:

```text
 browser ──▶ node:80 ──▶ Traefik ──▶ Service rust-app:80 ──▶ pod:8080
          (security    (reads the   (picks a ready pod)
           group)       Ingress)
```

## Step 8: Deploy and test

On the server:

```bash
git pull
sed "s|IMAGE_PLACEHOLDER|$IMAGE|" k8s/app.yaml | kubectl apply -f -
kubectl rollout status deployment/rust-app
kubectl get pods -o wide
```

`sed` replaces the placeholder on the way to `kubectl`, without changing the
file. You should see two `rust-app` pods `1/1 Running`, plus `postgres`.

Test from inside the cluster first, then from outside:

```bash
kubectl run curl --rm -it --image=curlimages/curl:8.16.0 --restart=Never -- curl -s http://rust-app/ready
curl -s http://localhost/health
```

The first request goes through the Service, the second through Traefik on the
node. Now, on your **laptop**:

```bash
IP=<k3s_public_ip>
curl -s -X POST http://$IP/items -H 'content-type: application/json' -d '{"name":"first"}'
curl -s http://$IP/items
```

Your Rust service is running on Kubernetes, behind an Ingress, reachable only
from your IP.

## Step 9: Watch Kubernetes work

Everything in this step is something you will be asked about in interviews,
and something you should have seen with your own eyes. Each experiment takes a
few minutes.

### Self-healing

In a second Session Manager tab (or after `Ctrl+C`), watch the pods:

```bash
kubectl get pods -w
```

In the first tab, delete one application pod. Copy any pod name from the list:

```bash
kubectl delete pod <rust-app-pod-name>
```

In the watch, the old pod goes `Terminating` and a new one appears at once. The
ReplicaSet saw 1 pod where 2 were wanted. Unlike `hello` in Step 4, this pod
had a controller.

### Graceful shutdown

```bash
kubectl logs -l app=rust-app --tail=3 --prefix
```

Look for `shutdown signal received` from the deleted pod (if it is already
gone, delete another one with `kubectl logs -f` running). Kubernetes sent
`SIGTERM`, removed the pod from the Service, and gave it up to 30 seconds
(`terminationGracePeriodSeconds`) to finish its requests. That is the code from
Chapter 1 working.

### Scaling

```bash
kubectl scale deployment/rust-app --replicas=4
kubectl get pods
kubectl top pods
kubectl scale deployment/rust-app --replicas=2
```

`kubectl scale` changes the desired state directly. It works, but your YAML
file still says `replicas: 2`, so the next `apply` would scale back. That
mismatch between the cluster and Git is called **drift**, and it is why real
changes go through files.

### Readiness in action

Stop the database and watch what happens to the application:

```bash
kubectl scale deployment/postgres --replicas=0
kubectl get pods
kubectl get endpoints rust-app
```

Within about 15 seconds (three failed readiness checks, 5 seconds apart), the
application pods show `0/1` in the `READY` column and `endpoints` shows
`<none>`: the Service has no pods to send traffic to. (`kubectl` may warn that
`v1 Endpoints` is deprecated in favour of EndpointSlices; the command still
works, and it is the quickest check.)
`curl http://localhost/items` now returns an error from Traefik. But look at
`RESTARTS`: still 0. Liveness is fine, so Kubernetes does not restart anything.

```bash
kubectl scale deployment/postgres --replicas=1
kubectl get pods -w
```

When PostgreSQL is back, the application pods become ready on their own. But
try `curl -s http://localhost/items`: it fails with a `500`. The new database
pod started empty, without the `items` table. `/ready` only runs `SELECT 1`, so
it passes, while the migrations ran once, when the application started. A
restart runs them again:

```bash
kubectl rollout restart deployment/rust-app
kubectl rollout status deployment/rust-app
```

This is a good example of what readiness probes do *not* tell you: "can I
reach the database" is not the same as "the database is in the state I
expect". With RDS and its persistent storage (Step 10), the problem
disappears.

### A rolling update and a rollback

You need a second image tag. List the most recent ones:

```bash
aws ecr describe-images --repository-name rust-devops-app --region $REGION \
  --query 'sort_by(imageDetails[?imageTags], &imagePushedAt)[-3:].imageTags[0]' --output text
```

Pick an **older** tag from the list, and keep the watch running in the second
tab:

```bash
kubectl set image deployment/rust-app app=$REGISTRY/rust-devops-app:<older-tag>
kubectl rollout status deployment/rust-app
kubectl get rs
```

In the watch you see the pattern from the strategy: one new pod starts, becomes
ready, one old pod terminates, repeat. `kubectl get rs` now shows **two**
ReplicaSets: the new one with 2 pods, the old one scaled to 0. Kubernetes keeps
the old one so it can go back:

```bash
kubectl rollout history deployment/rust-app
kubectl rollout undo deployment/rust-app
kubectl rollout status deployment/rust-app
```

`undo` simply scales the previous ReplicaSet up again, so a rollback is as fast
as a deployment.

### A broken update

Finally, deploy an image that does not exist:

```bash
kubectl set image deployment/rust-app app=$REGISTRY/rust-devops-app:does-not-exist
kubectl get pods
```

The new pod goes to `ErrImagePull`, then `ImagePullBackOff`. And yet the
application still works: `curl -s http://localhost/health`. Because of
`maxUnavailable: 0`, the old pods are not stopped until the new one is ready,
which never happens. A bad deployment is stuck, not down. Find the reason
with step 2 of the toolkit:

```bash
kubectl describe pod <the-new-pod> | tail -8
kubectl rollout undo deployment/rust-app
```

## Step 10: Switch to RDS

If your RDS instance from Chapter 6 is not running, start it on your laptop
(`terraform apply`, about 10 minutes) and come back.

The application only needs a different `DATABASE_URL`. This block builds it
exactly as Chapter 6 described: endpoint from RDS, password from Secrets
Manager, URL-encoded, with TLS. Paste it on the server:

```bash
read -r DB_HOST DB_PORT SECRET_ARN <<<"$(aws rds describe-db-instances \
  --db-instance-identifier rust-devops-db --region $REGION \
  --query 'DBInstances[0].[Endpoint.Address,Endpoint.Port,MasterUserSecret.SecretArn]' --output text)"

DATABASE_URL=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --region $REGION \
  --query SecretString --output text | DB_HOST=$DB_HOST DB_PORT=$DB_PORT python3 -c '
import json, os, sys
from urllib.parse import quote
s = json.load(sys.stdin)
print("postgres://{}:{}@{}:{}/app?sslmode=require".format(
    quote(s["username"], safe=""), quote(s["password"], safe=""),
    os.environ["DB_HOST"], os.environ["DB_PORT"]))')

kubectl create secret generic rust-app-db --from-literal=DATABASE_URL="$DATABASE_URL" \
  --dry-run=client -o yaml | kubectl apply -f -
unset DATABASE_URL
```

The node's role allows exactly these two calls (`rds:DescribeDBInstances` and
`secretsmanager:GetSecretValue`), which is the policy you created in Step 1.

Changing a Secret does **not** restart the pods that use it: environment
variables are read once, when a container starts. Restart them yourself:

```bash
kubectl rollout restart deployment/rust-app
kubectl rollout status deployment/rust-app
kubectl logs -l app=rust-app --tail=5 --prefix
```

`rollout restart` is a rolling update with the same image, so there is no
downtime. Create an item from your laptop and check that it survives a pod
restart this time. The in-cluster database is no longer needed:

```bash
kubectl delete -f k8s/postgres.yaml
```

The request now travels: browser → node → Traefik → Service → pod → **private
subnet** → RDS. The security group rule you typed in Chapter 6 allowed it,
because the node's IP is inside the VPC range.

## Step 11: Stop paying

At the end of a session, from `infra/terraform` on your laptop:

```bash
terraform destroy -target=aws_instance.k3s -target=aws_db_instance.main
```

The IAM role, the security group and the network stay; they are free. The next
`terraform apply` creates a fresh server, and `user_data` installs k3s again in
a few minutes. Everything inside the cluster is gone, which is fine: it all
comes from files and a few pasted commands, and from Chapter 9 on, from one
script.

## The debugging map

Most Kubernetes problems show up as a pod status. Start with `kubectl get pods`
and follow the row:

| Status | Meaning | Look at | Common causes |
|---|---|---|---|
| `Pending` | no node can run it | `describe` → Events | not enough CPU/memory for the `requests`; a volume that cannot be created |
| `ErrImagePull` / `ImagePullBackOff` | the image cannot be pulled | `describe` → Events | typo or placeholder in the image name; tag does not exist; expired or missing pull secret |
| `CreateContainerConfigError` | the container cannot be configured | `describe` → Events | a referenced Secret or ConfigMap does not exist |
| `CrashLoopBackOff` | the container starts and exits, again and again | `logs --previous` | missing env variable, wrong `DATABASE_URL`, panic at startup |
| `Running` but `0/1` ready | readiness probe failing | `describe`, then `logs` | the database is unreachable; wrong probe path or port |
| `OOMKilled` (in `describe` → Last State) | used more memory than its limit | `kubectl top pods` | limit too low, or a memory leak |

`kubectl logs --previous` shows the logs of the container **before** the last
restart, which is where a crash's reason is. Without `--previous`, you see the
new container, which may not have printed anything yet.

And when everything looks right but traffic does not arrive, walk the request
path backwards:

```bash
kubectl get endpoints rust-app                      # does the Service have ready pods?
kubectl run curl --rm -it --image=curlimages/curl:8.16.0 --restart=Never -- curl -sv http://rust-app/health
curl -sv http://localhost/health                    # on the node: does Traefik route it?
```

If all three work and your laptop still gets a timeout, the problem is outside
Kubernetes: the security group, or your IP has changed.

## Troubleshooting

All of these happened while building this project.

**The instance does not appear in Session Manager, or "Connect" is greyed
out.** The SSM agent needs three things: the `AmazonSSMManagedInstanceCore`
policy on the instance role, outbound internet access (public subnet, public
IP, egress rule), and a few minutes after boot to register. Check
**Systems Manager → Fleet Manager**. If the role was attached after the
instance started, reboot it, or wait up to 30 minutes for the agent to retry.

**`ImagePullBackOff` with `failed to resolve reference "<ACCOUNT_ID>.dkr.ecr..."`.**
A placeholder ended up in the image name. Check with
`kubectl get deploy rust-app -o jsonpath='{.spec.template.spec.containers[0].image}'`.
In this chapter, `$IMAGE` was empty because the session was new and the
variables from Step 6 were never set. Paste the block again, then reapply.

**`ImagePullBackOff` with `401 Unauthorized` or `no basic auth credentials`.**
The pull secret is missing, in a different namespace, or older than 12 hours.
Rerun the `ecr-credentials` block from Step 6, then delete the failing pod so
it retries at once.

**`kubectl` says `The connection to the server localhost:8080 was refused`.**
`kubectl` (or Helm) did not find the kubeconfig and fell back to the default
address. You are probably in `sh` instead of `bash`, or in a shell started
before `user_data` finished, so `KUBECONFIG` is not set. Run `bash`, or
`export KUBECONFIG=/etc/rancher/k3s/k3s.yaml`.

**`error loading config file "/etc/rancher/k3s/k3s.yaml": permission denied`.**
k3s was installed without `--write-kubeconfig-mode 644`. Use `sudo kubectl`, or
`sudo chmod 644 /etc/rancher/k3s/k3s.yaml`, and fix `user_data` so the next
server is right.

**`helm: command not found` or `aws: command not found` right after boot.**
`user_data` is still running. `cloud-init status --wait` waits until it is
done.

**`curl` from the laptop times out, but `curl localhost` on the server works.**
Your public IP changed (home internet connections change it now and then), so
the security group no longer matches. Update `my_ip_cidr` in
`terraform.tfvars` with the one-liner from Step 1 (delete the old line first)
and run `terraform apply`; only the rule changes.

**`404 page not found` from Traefik.** Traefik answered, but no Ingress rule
matched. Check `kubectl get ingress`: is it in the right namespace, does it
have `ingressClassName: traefik`, and, if you set a `host`, does the request
use that host name?

**The pods are `Running` but never ready after switching to RDS.**
`kubectl logs` shows the reason. `no pg_hba.conf entry ... no encryption` means
`sslmode=require` is missing; `password authentication failed` means the
Secret holds an old password (the database was recreated); a timeout means the
database security group does not allow the node.

**`git pull` on the server fails with a merge conflict.** A file was edited on
the server. Throw the local change away with `git checkout -- <file>` (or
`git reset --hard origin/main` to discard everything local), then pull again.

## What you learned

- How Kubernetes reconciles desired state, and what the control plane and the
  nodes do.
- What Pods, Deployments, ReplicaSets, Services, Ingresses, Namespaces and
  Secrets are, and how labels and selectors connect them.
- How to create an EC2 server with an IAM role, no inbound SSH, and k3s
  installed at boot, and how to reach it with Session Manager.
- How a private ECR image gets into a cluster, and why the token expires.
- The difference between liveness and readiness probes, and why the database
  check belongs only in readiness.
- What `requests` and `limits` do, and why there is no CPU limit.
- How rolling updates, `maxSurge` and `maxUnavailable` avoid downtime, and how
  rollbacks work through old ReplicaSets.
- A repeatable way to debug: `get`, `describe`, `logs`, `exec`, and the status
  table.

## Practice

Each exercise says how long it takes and how much you type.

1. **The selector mismatch** (10 min, change 1 line). In a copy of the
   Deployment, change only the template label to `app: rust-app-v2` and
   apply it. Read the error. Then explain why Kubernetes refuses it instead of
   creating pods that the Deployment would not recognise.
2. **Break liveness on purpose** (15 min, change 1 line). Change the liveness
   probe's path to `/does-not-exist` and apply. Watch `RESTARTS` climb in
   `kubectl get pods -w`, and find the probe failures in `describe`. Then think:
   what would happen if you made the *readiness* probe wrong instead? Try it.
   Undo both with `kubectl rollout undo`.
3. **OOMKilled** (10 min, change 1 line). Set `limits.memory` to `4Mi` and
   apply. Find `OOMKilled` and the exit code `137` in `describe`. What is 137?
   (Hint: 128 + 9, and signal 9 is `SIGKILL`.)
4. **Move the configuration to a ConfigMap** (20 min, about 10 lines). Create a
   ConfigMap with `RUST_LOG: debug` and add a second `envFrom` entry with
   `configMapRef`. Apply, restart, and check that the logs became more
   detailed. Why is `RUST_LOG` a ConfigMap and `DATABASE_URL` a Secret?
5. **Pull from ECR without a pull secret** (30 min, about 15 lines). k3s can
   use the node's IAM role directly with the
   [ECR credential provider](https://docs.k3s.io/installation/private-registry)
   and a `registries.yaml`. Research how, and write down which lines of
   `user_data` you would add. You do not have to apply it; just understand why
   it removes the 12-hour problem.
6. **Explain the request path** (5 min, no typing). Draw the path of
   `curl http://<ip>/items` from your laptop to RDS and back, naming every hop:
   security group, ServiceLB, Traefik, Ingress, Service, endpoint, pod, DB
   security group, RDS. If you can draw it without looking, you are ready for
   the interview question about it.

Finish the session with Step 11.

## Interview questions

- What happens, step by step, between `kubectl apply -f deployment.yaml` and a
  running container?
- What is the difference between a Pod, a ReplicaSet, and a Deployment? Why do
  you rarely create Pods directly?
- How does a Service find its pods? What happens to traffic during a rolling
  update?
- What is the difference between a liveness probe and a readiness probe? What
  goes wrong if the liveness probe checks the database?
- What do `requests` and `limits` do? What happens when a container exceeds its
  memory limit? Its CPU limit?
- Explain `maxSurge` and `maxUnavailable`. How would you configure a rollout
  that never reduces capacity?
- A pod is in `CrashLoopBackOff`. How do you find out why?
- A pod is in `ImagePullBackOff`. What are the likely causes?
- Why does changing a Secret not change the running application? How do you
  roll the change out?
- How are Kubernetes Secrets stored, and why are they not enough on their own
  for sensitive values?
- What is the difference between a Service of type ClusterIP, NodePort, and
  LoadBalancer? What does an Ingress add?
- Why connect to servers with Session Manager instead of SSH?
