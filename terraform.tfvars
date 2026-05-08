# AWS Configuration
aws_region  = "us-east-1"
environment = "production"
project_name = "aurora-okta-8a1"

# VPC Configuration (using defaults - adjust if needed)
vpc_cidr = "10.0.0.0/16"
availability_zones = ["us-east-1a", "us-east-1b"]
private_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]
public_subnet_cidrs = ["10.0.10.0/24", "10.0.11.0/24"]

# Aurora Configuration
aurora_cluster_name    = "aurora-readonly-db"
aurora_engine_version  = "8.0.mysql_aurora.3.10.3"
aurora_instance_class  = "db.t3.medium"
aurora_backup_retention = 7
aurora_master_username = "admin"
aurora_multi_az        = true

# Database Configuration
database_name    = "appdb"
readonly_username = "readonly_user"

# RDS Proxy Configuration
rds_proxy_enabled             = true
rds_proxy_max_connections     = 100
rds_proxy_max_idle_connections = 10

# Okta Configuration
# Get these values from your Okta account
# org_name is the subdomain, e.g., "dev-12345678" from "https://dev-12345678.okta.com"
# base_url is the domain suffix only, e.g., "okta.com" or "oktapreview.com"
okta_org_name = "trial-3604415"
okta_base_url = "okta.com"
okta_api_token = "00nLmuVfFPe6mMuDlm8-sZ2OA2i6x7lpQdlObmNr8U"
okta_app_name = "okta-aurora-app"
okta_group_name = "aurora-readonly-users"

# IAM Configuration
iam_role_name  = "aurora-readonly-role"
iam_policy_name = "aurora-readonly-policy"
session_duration = 3600 # 1 hour in seconds

# Testing only — remove before production
local_ip_cidr = "202.83.25.24/32"

# Bastion Configuration
bastion_key_pair      = "linux-key"
bastion_ami           = "ami-0e1e769742d1cfb49"
bastion_instance_type = "t3.nano"

enable_blue_green=true
trigger_switchover=false
retain_old_cluster=false
enable_reverse_replication=false
proxy_active_cluster   = "new"
delete_old_cluster     = false
# Set this after switchover — run: terraform output old_blue_cluster_id
old_blue_cluster_id    = ""
# Get from AWS console or: aws ec2 describe-instances --filters "Name=tag:Name,Values=*bastion*" --query 'Reservations[0].Instances[0].InstanceId' --output text
bastion_instance_id    = ""
rds_proxy_name         = "aurora-okta-8a1-proxy"