# VPC Outputs
output "vpc_id" {
  value       = aws_vpc.main.id
  description = "VPC ID"
}

output "vpc_cidr" {
  value       = aws_vpc.main.cidr_block
  description = "VPC CIDR block"
}

output "private_subnet_ids" {
  value       = aws_subnet.private[*].id
  description = "IDs of private subnets"
}

output "public_subnet_ids" {
  value       = aws_subnet.public[*].id
  description = "IDs of public subnets"
}

# Aurora Outputs
output "aurora_cluster_endpoint" {
  value       = aws_rds_cluster.main.endpoint
  description = "Aurora cluster endpoint for write operations"
}

output "aurora_reader_endpoint" {
  value       = aws_rds_cluster.main.reader_endpoint
  description = "Aurora cluster reader endpoint (read-only)"
}

output "aurora_cluster_id" {
  value       = aws_rds_cluster.main.cluster_identifier
  description = "Aurora cluster identifier"
}

output "aurora_database_name" {
  value       = aws_rds_cluster.main.database_name
  description = "Default database name"
}

output "aurora_instance_ids" {
  value       = aws_rds_cluster_instance.main[*].identifier
  description = "Aurora instance identifiers"
}

output "aurora_readonly_user" {
  value       = var.readonly_username
  description = "Read-only database user"
}

output "aurora_master_username" {
  value       = var.aurora_master_username
  description = "Aurora master username (for setup only)"
  sensitive   = true
}

# RDS Proxy Outputs
output "rds_proxy_endpoint" {
  value       = var.rds_proxy_enabled ? aws_db_proxy.main[0].endpoint : null
  description = "RDS Proxy endpoint for IAM authentication"
}

output "rds_proxy_enabled" {
  value       = var.rds_proxy_enabled
  description = "Whether RDS Proxy is enabled"
}

# Security Group Outputs
output "aurora_security_group_id" {
  value       = aws_security_group.aurora.id
  description = "Aurora security group ID"
}

# IAM Role Outputs
output "aurora_readonly_role_arn" {
  value       = aws_iam_role.aurora_readonly.arn
  description = "ARN of the read-only Aurora IAM role"
}

output "aurora_readonly_role_name" {
  value       = aws_iam_role.aurora_readonly.name
  description = "Name of the read-only Aurora IAM role"
}

# Okta Outputs
output "okta_saml_provider_arn" {
  value       = aws_iam_saml_provider.okta.arn
  description = "ARN of the Okta SAML provider"
}

output "okta_app_id" {
  value       = okta_app_saml.aws.id
  description = "Okta SAML application ID"
}

output "okta_app_name" {
  value       = okta_app_saml.aws.label
  description = "Okta SAML application name"
}

output "okta_group_id" {
  value       = okta_group.aurora_users.id
  description = "Okta group ID for Aurora users"
}

output "okta_group_name" {
  value       = okta_group.aurora_users.name
  description = "Okta group name for Aurora users"
}

# Connection Information
output "connection_instructions" {
  value = var.rds_proxy_enabled ? {
    method       = "RDS Proxy with IAM Authentication"
    endpoint     = aws_db_proxy.main[0].endpoint
    port         = 3306
    database     = var.database_name
    user         = var.readonly_username
    region       = var.aws_region
    instructions = <<-EOT
      1. Login to Okta at https://${var.okta_org_name}.okta.com
      2. Navigate to the ${okta_app_saml.aws.label} application
      3. Click to assume the ${aws_iam_role.aurora_readonly.name} role
      4. In AWS Console, navigate to RDS Proxy
      5. Note the RDS Proxy endpoint: ${aws_db_proxy.main[0].endpoint}
      6. Generate authentication token:
         aws rds-db auth-token \
           --hostname ${aws_db_proxy.main[0].endpoint} \
           --port 3306 \
           --region ${var.aws_region} \
           --username ${var.readonly_username}
      7. Connect with MySQL client:
         mysql -h ${aws_db_proxy.main[0].endpoint} \
           -P 3306 \
           -u ${var.readonly_username} \
           --ssl-ca=/path/to/rds-ca-bundle.pem \
           --ssl-mode=VERIFY_IDENTITY \
           -p"<auth_token>"
    EOT
    } : {
    method       = "Direct Aurora connection with IAM Authentication"
    endpoint     = aws_rds_cluster.main.endpoint
    port         = 3306
    database     = var.database_name
    user         = var.readonly_username
    region       = var.aws_region
    instructions = <<-EOT
      1. Login to Okta at https://${var.okta_org_name}.okta.com
      2. Navigate to the ${okta_app_saml.aws.label} application
      3. Click to assume the ${aws_iam_role.aurora_readonly.name} role
      4. In AWS Console, navigate to RDS Databases
      5. Note the Aurora cluster endpoint: ${aws_rds_cluster.main.endpoint}
      6. Generate authentication token:
         aws rds-db auth-token \
           --hostname ${aws_rds_cluster.main.endpoint} \
           --port 3306 \
           --region ${var.aws_region} \
           --username ${var.readonly_username}
      7. Connect with MySQL client:
         mysql -h ${aws_rds_cluster.main.endpoint} \
           -P 3306 \
           -u ${var.readonly_username} \
           --ssl-ca=/path/to/rds-ca-bundle.pem \
           --ssl-mode=VERIFY_IDENTITY \
           -p"<auth_token>"
    EOT
  }
  description = "Connection instructions for the Aurora database"
  sensitive = true
}

output "db_secret_arn" {
  value       = aws_secretsmanager_secret.aurora_credentials.id
  description = "ARN of the Secrets Manager secret holding Aurora master credentials — used by bg-03 workflow scripts"
}

output "aws_account_id" {
  value       = data.aws_caller_identity.current.account_id
  description = "AWS Account ID"
}

output "aws_region" {
  value       = var.aws_region
  description = "AWS Region"
}

# Blue/Green Deployment Outputs (custom aurora-bluegreen provider)
output "blue_green_deployment_id" {
  value       = var.enable_blue_green ? aurora-bluegreen_deployment.main[0].deployment_id : null
  description = "Blue/Green deployment identifier (bgd-xxx) — stored in state, no AWS Console needed"
}

output "blue_green_status" {
  value       = var.enable_blue_green ? aurora-bluegreen_deployment.main[0].status : null
  description = "Current deployment status (AVAILABLE = ready to switch, SWITCHOVER_COMPLETED = done)"
}

output "green_cluster_arn" {
  value       = var.enable_blue_green ? aurora-bluegreen_deployment.main[0].green_cluster_arn : null
  description = "ARN of the green cluster — use this to find the green endpoint for testing"
}

output "old_blue_cluster_id" {
  value       = var.enable_blue_green ? aurora-bluegreen_deployment.main[0].old_source_cluster_id : null
  description = "Cluster ID of the old blue cluster after switchover — the rollback target"
}

output "proxy_active_cluster" {
  value       = var.enable_blue_green ? aurora-bluegreen_deployment.main[0].proxy_active_cluster : "new"
  description = "Which cluster the RDS Proxy currently routes to: \"new\" (production) or \"old\" (rollback)"
}

output "replication_status" {
  value       = var.enable_blue_green ? aurora-bluegreen_deployment.main[0].replication_status : null
  description = "Binlog replication status for rollback (NOT_CONFIGURED / SETUP_PENDING / ACTIVE / STOPPED)"
}

output "rollback_source_cluster_id" {
  value       = var.enable_blue_green ? aurora-bluegreen_deployment.main[0].rollback_source_cluster_id : ""
  description = "Set to <orig>-new1 after Step 1 of name-swap rollback. Non-empty = partial rollback in progress — workflow skips pre-flight on re-runs."
}
