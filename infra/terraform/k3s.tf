# Latest official Ubuntu 24.04 image, looked up from AWS
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# IAM role the EC2 instance uses (like your GitHub role, but for EC2)
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

# Allow browser terminal access through Session Manager
resource "aws_iam_role_policy_attachment" "k3s_ssm" {
  role       = aws_iam_role.k3s_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Allow pulling images from ECR
resource "aws_iam_role_policy_attachment" "k3s_ecr" {
  role       = aws_iam_role.k3s_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# EC2 needs the role wrapped in an "instance profile"
resource "aws_iam_instance_profile" "k3s_node" {
  name = "${local.name}-k3s-node"
  role = aws_iam_role.k3s_node.name
}

# Firewall: nothing comes in, everything may go out
resource "aws_security_group" "k3s" {
  name        = "${local.name}-k3s-sg"
  description = "k3s node: no inbound, all outbound"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-k3s-sg" }
}

resource "aws_vpc_security_group_egress_rule" "k3s_all_out" {
  security_group_id = aws_security_group.k3s.id
  description       = "Allow all outbound traffic"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# The server
resource "aws_instance" "k3s" {
  ami                    = data.aws_ssm_parameter.ubuntu.value
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.k3s.id]
  iam_instance_profile   = aws_iam_instance_profile.k3s_node.name

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  # Runs once at first boot: installs k3s
  user_data = <<-EOF
    #!/bin/bash
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh -
  EOF

  tags = { Name = "${local.name}-k3s" }
}