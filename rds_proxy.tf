# RDS Proxy for connection pooling and IAM authentication
resource "aws_db_proxy" "main" {
  count                  = var.rds_proxy_enabled ? 1 : 0
  name                   = "${var.project_name}-proxy"
  debug_logging          = false
  engine_family          = "MYSQL"
  role_arn               = aws_iam_role.rds_proxy_role.arn
  vpc_subnet_ids         = aws_subnet.private[*].id
  vpc_security_group_ids = [aws_security_group.rds_proxy.id]
  require_tls            = true

  auth {
    auth_scheme = "SECRETS"
    secret_arn  = aws_secretsmanager_secret.aurora_credentials.arn
  }

  tags = {
    Name = "${var.project_name}-proxy"
  }

  depends_on = [
    aws_iam_role_policy_attachment.rds_proxy_secrets,
    aws_secretsmanager_secret_version.aurora_credentials
  ]
}

# RDS Proxy Default Target Group - configure connection pooling
resource "aws_db_proxy_default_target_group" "main" {
  count         = var.rds_proxy_enabled ? 1 : 0
  db_proxy_name = aws_db_proxy.main[0].name

  connection_pool_config {
    connection_borrow_timeout = 120
  }

  depends_on = [
    aws_db_proxy.main
  ]
}

# Register Aurora cluster with RDS Proxy.
# Disabled while a Blue/Green deployment is active — AWS manages the proxy target
# internally during B/G and blocks Terraform from registering it manually.
# After B/G is complete and enable_blue_green=false, Terraform re-registers it.
resource "aws_db_proxy_target" "main" {
  count                 = var.rds_proxy_enabled && !var.enable_blue_green ? 1 : 0
  db_proxy_name         = aws_db_proxy.main[0].name
  db_cluster_identifier = aws_rds_cluster.main.cluster_identifier
  target_group_name     = "default"

  depends_on = [
    aws_db_proxy_default_target_group.main
  ]
}