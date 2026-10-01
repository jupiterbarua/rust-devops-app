# Which subnets RDS may use: the private ones, in two AZs
resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db-subnets"
  subnet_ids = aws_subnet.private[*].id

  tags = { Name = "${local.name}-db-subnets" }
}

# Firewall for the database
resource "aws_security_group" "db" {
  name        = "${local.name}-db-sg"
  description = "PostgreSQL access from inside the VPC"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-db-sg" }
}

# Allow PostgreSQL only from inside the VPC
resource "aws_vpc_security_group_ingress_rule" "db_postgres" {
  security_group_id = aws_security_group.db.id
  description       = "PostgreSQL from VPC"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = aws_vpc.main.cidr_block
}

# The database itself
resource "aws_db_instance" "main" {
  identifier     = "${local.name}-db"
  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t4g.micro"

  allocated_storage = 20
  storage_type      = "gp3"

  db_name  = "app"
  username = "app"

  # AWS generates the password and stores it in Secrets Manager.
  # It never appears in your code.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  # Learning settings: cheap and easy to delete.
  # In production: multi_az = true, deletion_protection = true,
  # skip_final_snapshot = false, longer backup retention.
  multi_az                = false
  backup_retention_period = 1
  deletion_protection     = false
  skip_final_snapshot     = true
  apply_immediately       = true

  tags = { Name = "${local.name}-db" }
}