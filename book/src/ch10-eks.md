# Amazon EKS

k3s taught you Kubernetes on one machine that you built and own. That machine is
also a single point of failure: if it breaks, the control plane, the database
of desired state, and every pod go with it, and upgrading Kubernetes is your
job.

**Amazon EKS** (Elastic Kubernetes Service) is Kubernetes where AWS runs the
control plane for you: the API server and etcd run across several Availability
Zones, AWS patches and scales them, and you only manage the machines that run
your pods. In this chapter you create an EKS cluster with Terraform, connect to
it, and deploy the same Helm chart to it with the same deploy script. You will
see how much stays the same, and the few places where EKS is different.

> **Time and typing**
>
> | | |
> |---|---|
> | Reading | 50 min |
> | Hands-on | 90 min, of which about 20 min waiting for AWS |
> | Practice | 60 min |
> | Cost | EKS control plane $0.10 per hour, plus the node and the k3s server: about 30 cents per hour in total. **Destroy it the same day.** |
>
> **Copy:** `eks.tf` is complete; paste it.
> **Type yourself:** the access policy association and the security group rule
> at the end of `eks.tf` (Step 4, about 20 lines). They decide **who** may
> administer the cluster and **from where**, and both caused real failures in
> this project.

## The idea

### What AWS runs, and what you run

```text
                   AWS-managed (you never see these machines)
 ┌──────────────────────────────────────────────────────────────┐
 │ EKS control plane: API server + etcd, across 3 AZs           │
 │ endpoint: https://<id>.gr7.eu-central-1.eks.amazonaws.com    │
 └───────────────▲──────────────────────────────▲───────────────┘
                 │ kubectl / helm               │ kubelet
                 │                              │
 ┌───────────────┴────────────┐   ┌─────────────┴──────────────────┐
 │ admin host (k3s server)    │   │ managed node group (EC2)       │
 │ IAM role = cluster admin   │   │ your pods run here             │
 └────────────────────────────┘   └────────────────────────────────┘
          your VPC, public subnets
```

Compared with k3s:

| | k3s (Chapter 7) | EKS |
|---|---|---|
| Control plane | on your server, one copy | AWS, highly available, $0.10/hour |
| Upgrades | you reinstall k3s | one setting; AWS upgrades the control plane |
| Nodes | the same server | a **managed node group**: EC2 instances that AWS creates, joins and replaces |
| Who may use `kubectl` | whoever can read `k3s.yaml` | **IAM identities**, mapped to Kubernetes permissions with **access entries** |
| Pod IP addresses | a private overlay network (`10.42.x.x`) | **real VPC addresses** from your subnets (VPC CNI) |
| Ingress controller | Traefik, included | none; you install one (Chapter 11) |
| Pulling from ECR | pull secret, expires after 12 hours | the node's IAM role; nothing to refresh |

Everything you learned about Pods, Deployments, Services, probes and Helm is
unchanged. EKS is "real" Kubernetes; only the parts around it are AWS-specific.

### Who may talk to the cluster

On k3s, anyone with the kubeconfig file is admin. On EKS, every request to the
API carries an **IAM identity**, and the cluster decides what that identity may
do. The modern way to configure this is **access entries**, managed through the
EKS API (and Terraform):

1. An **access entry** says: this IAM role or user may authenticate to this
   cluster.
2. An **access policy association** says what it may do, for example
   `AmazonEKSClusterAdminPolicy` for the whole cluster.

Older guides use a ConfigMap called `aws-auth` instead. It works, but a typo in
it can lock everyone out of the cluster, and it cannot be managed cleanly from
outside the cluster. This book uses access entries only
(`authentication_mode = "API"`).

### Where the API is reachable

The EKS API endpoint can be **public** (reachable from the internet, optionally
limited to some IP ranges), **private** (reachable only from inside the VPC), or
both. This project uses both:

- **public**, limited to your IP (`my_ip_cidr`), so you could use `kubectl` from
  your laptop;
- **private**, so the admin host and the nodes reach the API inside the VPC.

With private access on, the endpoint's DNS name resolves to **private** VPC
addresses for anyone inside the VPC. That detail explains one of the errors in
Troubleshooting.

### The admin host

You need a machine with `kubectl`, `helm` and the AWS CLI. You already have one:
the k3s server. It has the tools, it sits inside the VPC, and its IAM role can
be made a cluster admin. Using it as an **admin host** (sometimes called a
bastion) means nothing has to be installed on your laptop, and your laptop's
credentials never need cluster access. In a company, this role is usually
played by a CI runner or a dedicated, locked-down admin instance.

## Step 1: Choose the node size

Add a variable to `infra/terraform/variables.tf`:

```hcl
variable "eks_node_instance_type" {
  type        = string
  description = "EC2 instance type for EKS worker nodes"
  default     = "t3.small"
}
```

Then set the type in `terraform.tfvars`:

```hcl
eks_node_instance_type = "m7i-flex.large"
```

Why not `t3.small`? Two reasons:

- **Pod capacity.** With the VPC CNI, every pod gets a VPC IP address, and an
  instance type can only hold so many network interfaces and addresses. A
  `t3.small` fits 11 pods, and EKS's own system pods already use several. An
  `m7i-flex.large` fits 29, which leaves room for the monitoring stack later.
- **AWS free plan accounts** can only launch instance types marked as
  free-tier eligible. If your account is on the free plan, an ineligible type
  makes the node group fail after 30 minutes of waiting (Troubleshooting).
  `m7i-flex.large` is eligible. You can list the eligible types with:

```bash
aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true \
  --query 'InstanceTypes[].InstanceType' --output text
```

## Step 2: The control plane

Create `infra/terraform/eks.tf` and paste the first part:

```hcl
locals {
  eks_name = "${local.name}-eks"
}

# ---------------------------------------------------------------------------
# Control plane: the Kubernetes API, managed by AWS
# ---------------------------------------------------------------------------
resource "aws_iam_role" "eks_cluster" {
  name = "${local.name}-eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "main" {
  name     = local.eks_name
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = [var.my_ip_cidr]
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]

  tags = { Name = local.eks_name }
}
```

**The cluster role** is assumed by the EKS service itself, to manage AWS
resources for the control plane (network interfaces in your subnets, for
example). Its trust policy names `eks.amazonaws.com`, the same pattern as the
EC2 role in Chapter 7. `sts:TagSession` lets EKS tag the sessions it creates;
newer EKS features require it.

**`subnet_ids`** lists all four subnets. EKS places the control plane's network
interfaces in them, which is how the private endpoint gets its addresses inside
your VPC. `concat` joins two lists into one.

**`vpc_config`**: the endpoint settings from "The idea". Without
`public_access_cidrs`, the public endpoint would accept connections from the
whole internet. Authentication would still be required, but there is no reason
to let the world try.

**`access_config`**: `authentication_mode = "API"` means access entries only.
`bootstrap_cluster_creator_admin_permissions = true` gives the IAM identity that
**creates** the cluster (whoever runs `terraform apply`) admin access, so you
cannot lock yourself out on day one.

**`depends_on`**: Terraform cannot see that the cluster needs the policy
**attached** to the role, not only the role itself. Without `depends_on`, it
might create the cluster before the attachment exists, and creation would fail.
On destroy, the order is reversed, so the policy is removed only after the
cluster is gone.

## Step 3: The nodes

Paste the second part:

```hcl
# ---------------------------------------------------------------------------
# Worker nodes: EC2 instances that run your pods
# ---------------------------------------------------------------------------
resource "aws_iam_role" "eks_node" {
  name = "${local.name}-eks-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.eks_node.name
  policy_arn = each.value
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.name}-nodes"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = aws_subnet.public[*].id

  instance_types = [var.eks_node_instance_type]
  capacity_type  = "ON_DEMAND"

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 2
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [aws_iam_role_policy_attachment.eks_node]

  tags = { Name = "${local.name}-nodes" }
}
```

**The node role** is an EC2 role, like the k3s server's. Its three AWS-managed
policies let the node:

| Policy | Allows |
|---|---|
| `AmazonEKSWorkerNodePolicy` | joining the cluster and describing it |
| `AmazonEKS_CNI_Policy` | the VPC CNI (`aws-node`) to attach network interfaces and assign pod IPs |
| `AmazonEC2ContainerRegistryReadOnly` | pulling images from ECR, with no pull secret |

**`for_each = toset([...])`** creates one attachment per policy. You met `count`
in Chapter 6; `for_each` is its safer sibling. Each copy is addressed by its key
(`aws_iam_role_policy_attachment.eks_node["arn:...CNI_Policy"]`) instead of a
number, so removing one policy from the list removes exactly that attachment,
without shifting the others. Remember the `count` trap from Chapter 6, Practice
1: this is the fix.

**`subnet_ids = aws_subnet.public[*].id`**: the nodes run in the **public**
subnets. They need outbound internet access to reach the EKS API, ECR and the
AWS APIs, and there is no NAT gateway for the private subnets (Chapter 6). Their
security group allows no inbound traffic from the internet. Production clusters
usually put nodes in private subnets behind NAT gateways or VPC endpoints; the
Lessons Learned chapter returns to this.

**`scaling_config`**: one node, room for two. The node group is an EC2 Auto
Scaling group underneath: if the node dies, AWS replaces it. `max_size = 2` is
needed for `update_config`: during an update (a new AMI, a new Kubernetes
version), EKS starts a new node first, moves the pods, and only then removes the
old one, `max_unavailable = 1` at a time.

## Step 4: Admin access

The last part makes the k3s server the cluster's admin host. Paste the
`aws_eks_access_entry` and the `aws_iam_role_policy`, and **type** the policy
association and the security group rule:

```hcl
# ---------------------------------------------------------------------------
# Admin access: let the k3s instance (your admin host) manage the cluster
# ---------------------------------------------------------------------------
resource "aws_eks_access_entry" "admin_host" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.k3s_node.arn
}

# type this:
resource "aws_eks_access_policy_association" "admin_host" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_eks_access_entry.admin_host.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# The admin host needs to look up the cluster to create its kubeconfig
resource "aws_iam_role_policy" "k3s_eks_describe" {
  name = "eks-describe"
  role = aws_iam_role.k3s_node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "eks:DescribeCluster"
      Resource = "arn:aws:eks:eu-central-1:${data.aws_caller_identity.current.account_id}:cluster/${local.eks_name}"
    }]
  })
}

# type this:
# Allow the admin host to reach the Kubernetes API (private endpoint)
resource "aws_vpc_security_group_ingress_rule" "eks_api_from_admin_host" {
  security_group_id            = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  description                  = "Kubernetes API from admin host"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.k3s.id
}

output "eks_cluster_name" {
  value = aws_eks_cluster.main.name
}
```

Four resources, four questions answered:

1. **May the k3s server's role log in?** The **access entry** says yes.
2. **What may it do?** The **policy association** grants
   `AmazonEKSClusterAdminPolicy` across the whole cluster
   (`access_scope = cluster`). EKS also offers `AmazonEKSAdminPolicy`,
   `AmazonEKSEditPolicy` and `AmazonEKSViewPolicy`, and a `namespace` scope, for
   less powerful identities.
3. **Can it find the cluster?** `aws eks update-kubeconfig` calls
   `eks:DescribeCluster` to read the endpoint and certificate. That is an
   ordinary IAM permission, separate from Kubernetes access.
4. **Can it reach the API over the network?** EKS creates a **cluster security
   group** for the control plane's network interfaces and the nodes. The rule
   allows HTTPS from anything in the k3s server's security group.

Note `principal_arn = aws_eks_access_entry.admin_host.principal_arn` in the
association. It points to the **entry**, not straight to the role, even though
the value is the same. That reference tells Terraform to create the entry first.
With `aws_iam_role.k3s_node.arn` there, Terraform created both at the same time,
and the association failed with a 404, because its entry did not exist yet
(Troubleshooting). The same trick works everywhere: reference the resource that
must exist first, and Terraform orders them for you.

`referenced_security_group_id` is new: instead of an IP range, the rule allows
traffic from **members of another security group**. The k3s server's IP changes
every time it is recreated; its security group does not.

## Step 5: Create the cluster

The k3s server must exist, since the cluster refers to its role and security
group. From `infra/terraform` on your laptop:

```bash
terraform apply -target=aws_instance.k3s    # if the server is not running
terraform plan
```

The plan adds about 13 resources: two roles, four policy attachments, the
cluster, the node group, the access entry and association, the describe policy,
the security group rule, and the output. Then:

```bash
terraform apply
```

This is the slowest `apply` in the book. The cluster takes **10 to 15 minutes**,
the node group another **3 to 5**. Terraform prints `Still creating...` the
whole time. Do not press `Ctrl+C`. While you wait, look at the EKS console:
**EKS → Clusters → rust-devops-eks** shows the status moving from `Creating` to
`Active`, then the node group under **Compute**.

When it finishes, look at **EC2 → Instances**. You now have **two** instances:
your k3s server, and one **without a name**, in the security group
`eks-cluster-sg-rust-devops-eks-...`. That second
one is your EKS node. You did not create an `aws_instance` for it; the node
group did, through its Auto Scaling group. If you terminate it by hand, a new
one appears a few minutes later.

## Step 6: Connect from the admin host

Open Session Manager on the k3s server, as always:

```bash
bash
cd ~/rust-devops-app && git pull
aws eks update-kubeconfig --name rust-devops-eks --region eu-central-1 --kubeconfig ~/.kube/eks.yaml
export KUBECONFIG=~/.kube/eks.yaml
kubectl get nodes -o wide
```

`update-kubeconfig` writes a kubeconfig with the cluster's endpoint and
certificate. It does **not** contain a password or token. Instead, it tells
`kubectl` to run `aws eks get-token` before each request, which turns the
instance's IAM role into a short-lived token. The access entry decides what that
role may do.

The file goes to `~/.kube/eks.yaml`, a **separate** file, on purpose. This
server now holds two clusters, and you choose between them with `KUBECONFIG`:

```bash
export KUBECONFIG=~/.kube/eks.yaml            # EKS
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml   # k3s (the default from bash.bashrc)
kubectl config current-context                # which one am I talking to?
```

Check the context before every command that changes something. Running a
deployment against the wrong cluster is a classic incident.

`kubectl get nodes -o wide` shows your node, `Ready`, with an internal IP in a
public subnet (`10.0.1.x` or `10.0.2.x`) and a version like `v1.3x.x-eks-...`.
Now the system pods:

```bash
kubectl get pods -A -o wide
```

```text
NAMESPACE     NAME                       READY   STATUS    IP
kube-system   aws-node-xxxxx             2/2     Running   10.0.1.57
kube-system   coredns-xxxxxxxxx-aaaaa    1/1     Running   10.0.1.112
kube-system   coredns-xxxxxxxxx-bbbbb    1/1     Running   10.0.1.80
kube-system   kube-proxy-xxxxx           1/1     Running   10.0.1.57
```

Compare with k3s in Chapter 7. There is **no Traefik**, no ServiceLB and no
metrics-server: EKS gives you a bare cluster. `aws-node` is the VPC CNI, and it
explains the IP column: the CoreDNS pods have **VPC addresses** from the same
subnet as the node. On k3s, pods had `10.42.x.x` addresses that only existed
inside the cluster.

That matters in the next chapter: because pods have real VPC addresses, an AWS
load balancer can send traffic **straight to the pods**, skipping the node.

## Step 7: Deploy the application

The deploy script already supports EKS. Only two things differ from k3s, and
one small values file covers both. If you are building the project yourself,
create `charts/rust-app/values-eks.yaml` **on your laptop**, next to
`values.yaml` (in the finished repository it already exists):

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

It contains **only the differences** from `values.yaml`; everything else comes
from the defaults (Chapter 8, Step 9 explains how the files are merged):

- `imagePullSecrets: []`: the nodes pull from ECR with their IAM role, so the
  chart renders no pull secret. The list replaces the default list completely.
- `ingress.className: alb`: the Ingress is handled by the AWS Load Balancer
  Controller instead of Traefik. You install it in Chapter 11, together with
  the meaning of the three annotations. Until then, the Ingress simply waits.

Commit and push the file, then `git pull` on the admin host. Run the deploy
script with the EKS kubeconfig and the values file:

```bash
KUBECONFIG=~/.kube/eks.yaml VALUES_FILE=charts/rust-app/values-eks.yaml ./scripts/deploy.sh
```

Setting variables in front of a command passes them to that command only. The
script uses RDS if it is running, otherwise the in-cluster PostgreSQL, exactly
as on k3s. The database security group allows the whole VPC range (Chapter 6),
and the EKS nodes live in the VPC, so RDS works without changes.

When it finishes:

```bash
kubectl get pods,svc,ingress -n rust-app -o wide
```

Two `rust-app` pods are running, with VPC IPs. The Ingress exists, but its
`ADDRESS` column is empty: there is no controller for the `alb` class yet, so
nothing acts on it. To test the application anyway, forward a local port to the
Service:

```bash
kubectl port-forward -n rust-app svc/rust-app 8080:80 &
sleep 3                                       # give the tunnel time to open
curl -sS -m 5 -w '\nHTTP %{http_code}\n' localhost:8080/health
curl -sS -m 5 -w '\nHTTP %{http_code}\n' localhost:8080/items
kill %1
```

`&` starts `port-forward` in the background, and the next line runs at once.
Without the `sleep`, `curl` is faster than the tunnel and gets nothing back.
`-m 5` stops `curl` after 5 seconds instead of waiting forever, and `-w`
prints the HTTP status, so an empty answer and an error look different.

If `curl` times out although the tunnel says `Forwarding from 127.0.0.1:8080`,
the tunnel works, but no pod answers. Check
`kubectl get pods,endpoints -n rust-app`: the pods must be `1/1` ready, and
the Service must have endpoints.

`port-forward` tunnels through the Kubernetes API, so it works without any load
balancer. It is the standard way to reach a service that is not exposed, for
debugging only. The same Helm chart, the same script, the same image, on a
different kind of cluster.

## Step 8: Explore the differences

A few commands show what EKS adds. Each takes a minute.

The node's capacity, including the pod limit from Step 1:

```bash
kubectl describe node | grep -A6 '^Capacity'
```

`pods: 29` for an `m7i-flex.large`.

No pull secret was used, yet the image came from your private ECR:

```bash
kubectl get pod -n rust-app -l app=rust-app -o jsonpath='{.items[0].spec.imagePullSecrets}'; echo
```

It prints nothing (or `[]`). The kubelet on the node used the node's IAM role.

Who you are, as the cluster sees you:

```bash
kubectl auth whoami
```

The username contains the k3s server's role (`assumed-role/rust-devops-k3s-node/...`): the access entry at work. Ask what
that identity may do:

```bash
kubectl auth can-i '*' '*' --all-namespaces
```

`yes`: cluster admin, from the policy association.

## Step 9: Clean up

EKS costs money every hour, and the cluster is fully defined in code. Remove the
application first, then the cluster:

```bash
helm uninstall rust-app -n rust-app      # on the admin host, with the EKS kubeconfig
```

In this chapter the release created no AWS resources, but from Chapter 11 on,
an Ingress creates a real load balancer that Terraform does not know about.
**Uninstalling the Helm releases before destroying the cluster** is the habit
that prevents orphaned load balancers from billing you after the cluster is
gone. Start it now.

Then, on your laptop:

```bash
terraform destroy -target=aws_eks_cluster.main
```

Targeting the cluster also destroys everything that depends on it: the node
group, the access entry and association, and the security group rule. It takes
about 10 minutes. The IAM roles stay; they are free. Destroy the k3s server and
the database too, as at the end of every session:

```bash
terraform destroy -target=aws_instance.k3s -target=aws_db_instance.main
```

Then check **EC2 → Instances** and **EKS → Clusters**: both should be empty.

## Troubleshooting

All of these happened while building this project.

**`Error: waiting for EKS Node Group (rust-devops-eks:rust-devops-nodes) create: unexpected state 'CREATE_FAILED', wanted target 'ACTIVE'. last error: ... AsgInstanceLaunchFailures: Could not launch On-Demand Instances. InvalidParameterCombination - The specified instance type is not eligible for Free Tier.`**
The account is on the AWS free plan, and the node instance type is not
free-tier eligible. Terraform only finds out after waiting about 30 minutes,
because the node group keeps retrying. Set an eligible type such as
`m7i-flex.large` in `terraform.tfvars` (Step 1). The failed node group must be
replaced: `terraform apply` does that automatically.

**`Error: creating EKS Access Policy Association (...): operation error EKS: AssociateAccessPolicy, https response error StatusCode: 404, ... ResourceNotFoundException: The requested resource does not exist.`**
The association was created before its access entry existed, because both
referred to the role directly and Terraform created them in parallel. Make the
association refer to `aws_eks_access_entry.admin_host.principal_arn` (Step 4) and
apply again. It also happens when the cluster itself failed to create; fix that
first.

**`kubectl get nodes` hangs, then: `couldn't get current server API group list: Get "https://<id>.gr7.eu-central-1.eks.amazonaws.com/api?timeout=32s": dial tcp 10.0.11.233:443: i/o timeout`.**
The address is **private** (`10.0.x.x`): inside the VPC, the endpoint's name
resolves to the private endpoint. The admin host reached the right address, but
the cluster security group did not allow it, so packets were silently dropped.
Add the security group rule from Step 4. An `i/o timeout` almost always means a
security group or routing problem; a refused connection or a TLS error would
mean something else.

**`error: You must be logged in to the server (Unauthorized)`.**
The IAM identity behind the request has no access entry. Check which identity
that is with `aws sts get-caller-identity`. On the admin host, it must be the
role `rust-devops-k3s-node`. If you created the cluster with one identity and
use another (a different profile on your laptop, for example), the second needs
its own access entry.

**`error: current-context is not set`, or `localhost:8080 ... connection refused` with EKS.**
`KUBECONFIG` does not point to `~/.kube/eks.yaml` in this shell. Each new
Session Manager tab starts with the k3s default from `/etc/bash.bashrc`. Run
`export KUBECONFIG=~/.kube/eks.yaml` again, or prefix the command as in Step 7.

**The EKS console says `Your current IAM principal doesn't have access to Kubernetes objects on this cluster.`**
The console uses **your** IAM identity, which may differ from the one Terraform
used (for example, the root user or an SSO role). The cluster still works.
Add an access entry for that identity if you want to browse workloads in the
console.

**Node group status `CREATE_FAILED` with `NodeCreationFailure: Instances failed to join the kubernetes cluster`.**
The node started but could not reach the EKS API. In this design, nodes need
public IPs in the public subnets (`map_public_ip_on_launch = true`, Chapter 6)
to reach the internet. Check the subnet setting and the node role's policies.

**Pods stay `Pending` with `0/1 nodes are available: 1 Too many pods.`**
The node reached its pod limit (Step 1). Use a larger instance type, or raise
`desired_size` in the node group.

**"Why do I have two instances?"** One is the k3s server, the other is the EKS
node created by the node group (Step 5). Do not terminate the node by hand; the
Auto Scaling group just replaces it. Remove it with `terraform destroy`.

## What you learned

- What EKS manages for you, what you still manage, and what it costs.
- How IAM identities get Kubernetes permissions through access entries and
  access policy associations, and why they replace the `aws-auth` ConfigMap.
- How public and private endpoint access work, and why a private endpoint
  resolves to VPC addresses.
- How a managed node group creates, joins and replaces EC2 nodes, which IAM
  policies they need, and why `for_each` is safer than `count`.
- How to make one resource wait for another by referencing it, and how
  security groups can reference other security groups.
- How `aws eks update-kubeconfig` turns an IAM role into short-lived cluster
  tokens, and how to switch between clusters safely with `KUBECONFIG`.
- That pods on EKS have real VPC addresses, nodes pull from ECR with their IAM
  role, and the same chart and script deploy to both clusters.
- Why Helm releases are uninstalled before a cluster is destroyed.

## Practice

Each exercise says how long it takes and how much you type.

1. **Scale the node group** (15 min, change 1 number). Set `desired_size = 2`,
   apply, and watch the second node join with `kubectl get nodes -w`. Then scale
   the app to 4 replicas and check with `kubectl get pods -o wide` which node
   each pod landed on. Scale both back down.
2. **A read-only user** (20 min, about 15 lines). Create an IAM role that your
   own IAM user can assume, give it an access entry with
   `AmazonEKSViewPolicy` at `namespace` scope for `rust-app`, and test with
   `kubectl auth can-i delete pods -n rust-app` while assuming it. What does
   `kubectl get pods -n kube-system` return?
3. **Endpoint access** (15 min, change 1 line, then wait). Set
   `endpoint_public_access = false` and apply. Does the admin host still work?
   Would your laptop? Which setting would you choose for a production cluster,
   and how would the CI pipeline reach it?
4. **The cluster version** (10 min, reading). Find your cluster's Kubernetes
   version with `aws eks describe-cluster --name rust-devops-eks --query
   cluster.version`. Look up when that version leaves standard support, and what
   **extended support** costs. Why does this matter for a team's planning?
5. **Count the cost** (10 min, no typing). With the AWS pricing pages for
   `eu-central-1`, calculate what this setup costs per month if left running:
   control plane, one node, the k3s server and RDS. Compare it with one ECS
   Fargate service running two small tasks.

Finish the session with Step 9.

## Interview questions

- What does EKS manage, and what remains your responsibility?
- How do IAM identities get access to an EKS cluster? What are access entries,
  and what problems of the `aws-auth` ConfigMap do they solve?
- Explain public and private endpoint access. Which would you use in
  production, and how do CI pipelines and administrators reach the cluster?
- What is a managed node group? What happens when a node fails, and during a
  node group update?
- How do pods get IP addresses on EKS with the VPC CNI? What limits the number
  of pods per node?
- How do EKS nodes pull images from a private ECR repository?
- `kubectl` times out connecting to the cluster from inside the VPC. What do you
  check?
- Why should you delete Kubernetes-created load balancers before destroying a
  cluster?
- When would you choose EKS over ECS Fargate, and the other way round?
