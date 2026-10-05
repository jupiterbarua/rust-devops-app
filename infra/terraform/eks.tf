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

  instance_types = ["t3.small"]
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

# ---------------------------------------------------------------------------
# Admin access: let the k3s instance (your admin host) manage the cluster
# ---------------------------------------------------------------------------
resource "aws_eks_access_entry" "admin_host" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.k3s_node.arn
}

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

# Allow the admin host to reach the Kubernetes API (private endpoint)
resource "aws_vpc_security_group_ingress_rule" "eks_api_from_admin_host" {
  security_group_id            = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  description                  = "Kubernetes API from admin host"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.k3s.id
}