# Security Group for Bastion — no inbound SSH needed with SSM
resource "aws_security_group" "bastion" {
  name        = "${var.project_name}-bastion-sg"
  description = "Security group for bastion host"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound"
  }

  tags = {
    Name = "${var.project_name}-bastion-sg"
  }
}

# IAM role — SSM access + assume the 3 POC roles
resource "aws_iam_role" "bastion" {
  name = "${var.project_name}-bastion-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# AmazonSSMManagedInstanceCore lets SSM Session Manager connect without SSH
resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "bastion" {
  name = "${var.project_name}-bastion-policy"
  role = aws_iam_role.bastion.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AssumePocroles"
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Resource = [
          aws_iam_role.poc_readonly.arn,
          aws_iam_role.poc_readwrite.arn,
          aws_iam_role.poc_dba.arn,
        ]
      },
      {
        Sid      = "GenerateRdsToken"
        Effect   = "Allow"
        Action   = "rds-db:connect"
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.project_name}-bastion-profile"
  role = aws_iam_role.bastion.name
}

# Bastion EC2 — t3.nano x86_64, no key pair needed (SSM access)
resource "aws_instance" "bastion" {
  ami                         = var.bastion_ami
  instance_type               = var.bastion_instance_type
  subnet_id                   = aws_subnet.public[0].id
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids      = [aws_security_group.bastion.id]

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  user_data = <<-EOF
    #!/bin/bash
    dnf install -y mysql
  EOF

  tags = {
    Name = "${var.project_name}-bastion"
  }
}

# ─── OUTPUTS ─────────────────────────────────────────────────────────────────

output "bastion_instance_id" {
  value = aws_instance.bastion.id
}

output "bastion_connect_command" {
  value = "aws ssm start-session --target ${aws_instance.bastion.id} --region ${var.aws_region}"
}

output "bastion_poc_test_commands" {
  sensitive = true
  value = <<-EOT

    === Connect to bastion (no SSH key needed) ===
    aws ssm start-session --target ${aws_instance.bastion.id} --region ${var.aws_region}

    === Step 1: create DB users once (run with master password) ===
    mysql -h ${local.aurora_endpoint} -u ${var.aurora_master_username} -p < /tmp/create_poc_users.sql

    === Step 2: test each role ===

    # READONLY
    CREDS=$(aws sts assume-role --role-arn ${aws_iam_role.poc_readonly.arn} --role-session-name poc-readonly --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
    export AWS_ACCESS_KEY_ID=$(echo $CREDS | awk '{print $1}')
    export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | awk '{print $2}')
    export AWS_SESSION_TOKEN=$(echo $CREDS | awk '{print $3}')
    TOKEN=$(aws rds generate-db-auth-token --hostname ${local.aurora_endpoint} --port 3306 --region ${var.aws_region} --username readonly_user)
    mysql -h ${local.aurora_endpoint} -u readonly_user --password="$TOKEN" --ssl-mode=REQUIRED ${var.database_name}

    # READWRITE
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    CREDS=$(aws sts assume-role --role-arn ${aws_iam_role.poc_readwrite.arn} --role-session-name poc-readwrite --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
    export AWS_ACCESS_KEY_ID=$(echo $CREDS | awk '{print $1}')
    export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | awk '{print $2}')
    export AWS_SESSION_TOKEN=$(echo $CREDS | awk '{print $3}')
    TOKEN=$(aws rds generate-db-auth-token --hostname ${local.aurora_endpoint} --port 3306 --region ${var.aws_region} --username readwrite_user)
    mysql -h ${local.aurora_endpoint} -u readwrite_user --password="$TOKEN" --ssl-mode=REQUIRED ${var.database_name}

    # DBA
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    CREDS=$(aws sts assume-role --role-arn ${aws_iam_role.poc_dba.arn} --role-session-name poc-dba --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
    export AWS_ACCESS_KEY_ID=$(echo $CREDS | awk '{print $1}')
    export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | awk '{print $2}')
    export AWS_SESSION_TOKEN=$(echo $CREDS | awk '{print $3}')
    TOKEN=$(aws rds generate-db-auth-token --hostname ${local.aurora_endpoint} --port 3306 --region ${var.aws_region} --username dba_user)
    mysql -h ${local.aurora_endpoint} -u dba_user --password="$TOKEN" --ssl-mode=REQUIRED ${var.database_name}

  EOT
}
