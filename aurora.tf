# Generate random password for Aurora master user (backup only)
resource "random_password" "aurora_master" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>?"
}

# Store master password in Secrets Manager for RDS Proxy
resource "aws_secretsmanager_secret" "aurora_credentials" {
  name                    = "${var.project_name}-aurora-credentialss"
  description             = "Aurora master credentials for RDS Proxy"
  kms_key_id              = aws_kms_key.secrets.id
  recovery_window_in_days = 7

  tags = {
    Name = "${var.project_name}-aurora-credentials"
  }
}

resource "aws_secretsmanager_secret_version" "aurora_credentials" {
  secret_id = aws_secretsmanager_secret.aurora_credentials.id
  secret_string = jsonencode({
    username = var.aurora_master_username
    password = random_password.aurora_master.result
  })
}

# DB Cluster Parameter Group
resource "aws_rds_cluster_parameter_group" "main" {
  name_prefix = "${var.project_name}-cluster-param-group"
  family      = "aurora-mysql8.0"
  description = "Cluster parameter group for Aurora with IAM auth"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  parameter {
    name  = "binlog_format"
    value = "ROW"
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "binlog_row_image"
    value = "FULL"
  }

  parameter {
    name  = "binlog_checksum"
    value = "NONE"
  }

  tags = {
    Name = "${var.project_name}-cluster-pg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# DB Parameter Group
resource "aws_db_parameter_group" "main" {
  name   = "${var.project_name}-param-group"
  family = "aurora-mysql8.0"

  parameter {
    name  = "slow_query_log"
    value = 1
  }

  parameter {
    name  = "long_query_time"
    value = 2
  }

  tags = {
    Name = "${var.project_name}-param-group"
  }
}

# Aurora MySQL Cluster
resource "aws_rds_cluster" "main" {
  cluster_identifier              = var.aurora_cluster_name
  engine                          = "aurora-mysql"
  engine_version                  = var.aurora_engine_version
  database_name                   = var.database_name
  master_username                 = var.aurora_master_username
  master_password                 = random_password.aurora_master.result
  db_subnet_group_name            = aws_db_subnet_group.main.name
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.main.name
  vpc_security_group_ids          = [aws_security_group.aurora.id]

  # Backups
  backup_retention_period      = var.aurora_backup_retention
  preferred_backup_window      = "03:00-04:00"
  preferred_maintenance_window = "mon:04:00-mon:05:00"
  copy_tags_to_snapshot        = true
  skip_final_snapshot          = false
  final_snapshot_identifier    = "${var.aurora_cluster_name}-final-snapshot-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"

  # Enhanced Monitoring
  enabled_cloudwatch_logs_exports = ["error", "general", "slowquery", "audit"]
  iam_database_authentication_enabled = true
  enable_http_endpoint              = false

  # Encryption
  storage_encrypted = true
  kms_key_id        = aws_kms_key.aurora.arn

  # Deletion Protection
  deletion_protection = false

  tags = {
    Name = var.aurora_cluster_name
  }

  depends_on = [
    aws_db_subnet_group.main,
    aws_security_group.aurora
  ]
}

# Aurora MySQL Instances
resource "aws_rds_cluster_instance" "main" {
  count              = 2
  identifier         = "${var.aurora_cluster_name}-instance-${count.index + 1}"
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = var.aurora_instance_class
  engine             = aws_rds_cluster.main.engine
  engine_version     = aws_rds_cluster.main.engine_version

  db_parameter_group_name = aws_db_parameter_group.main.name
  publicly_accessible     = true
  auto_minor_version_upgrade = true

  monitoring_interval  = 60
  monitoring_role_arn  = aws_iam_role.rds_monitoring.arn

  tags = {
    Name = "${var.aurora_cluster_name}-instance-${count.index + 1}"
  }
}

# KMS Key for Aurora encryption
resource "aws_kms_key" "aurora" {
  description             = "KMS key for Aurora encryption"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  tags = {
    Name = "${var.project_name}-aurora-key"
  }
}

resource "aws_kms_alias" "aurora" {
  name          = "alias/${var.project_name}-aurora"
  target_key_id = aws_kms_key.aurora.key_id
}

# IAM Role for Enhanced Monitoring
resource "aws_iam_role" "rds_monitoring" {
  name        = "${var.project_name}-rds-monitoring-role"
  description = "Role for RDS Enhanced Monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-rds-monitoring-role"
  }
}

# Attach RDS monitoring policy
resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# Create read-only user in Aurora (using null_resource)
resource "null_resource" "create_readonly_user" {
  triggers = {
    cluster_id = aws_rds_cluster.main.cluster_resource_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      cat > /tmp/create_db_user.sql << 'EOF'
      -- Create read-only user with IAM authentication
      CREATE USER '${var.readonly_username}' IDENTIFIED WITH AWSAuthenticationPlugin AS 'RDS';

      -- Grant read-only permissions
      GRANT SELECT, SHOW VIEW, EXECUTE ON ${var.database_name}.* TO '${var.readonly_username}'@'%';

      -- Grant information schema access for client tools
      GRANT SELECT ON information_schema.* TO '${var.readonly_username}'@'%';

      FLUSH PRIVILEGES;
      EOF

      echo "SQL file created at /tmp/create_db_user.sql"
      echo "Use this to create the readonly user in Aurora:"
      echo "mysql -h <aurora_endpoint> -u ${var.aurora_master_username} -p < /tmp/create_db_user.sql"
    EOT
  }

  depends_on = [aws_rds_cluster.main]
}