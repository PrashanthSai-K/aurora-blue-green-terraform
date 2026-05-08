# AWS Configuration
variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "production"
}

variable "project_name" {
  description = "Project name prefix"
  type        = string
  default     = "aurora-okta"
}

# VPC Configuration
variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones for subnets"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

# Aurora Configuration
variable "aurora_cluster_name" {
  description = "Aurora cluster identifier"
  type        = string
  default     = "aurora-readonly-db"
}

variable "aurora_engine_version" {
  description = "Aurora MySQL engine version"
  type        = string
  default     = "8.0.mysql_aurora.3.04.0"
}

variable "aurora_instance_class" {
  description = "Instance class for Aurora DB"
  type        = string
  default     = "db.t4g.small"
}

variable "aurora_backup_retention" {
  description = "Backup retention period in days"
  type        = number
  default     = 7
}

variable "aurora_master_username" {
  description = "Master username for Aurora (not used with IAM auth)"
  type        = string
  default     = "admin"
  sensitive   = true
}

variable "aurora_multi_az" {
  description = "Enable Multi-AZ deployment"
  type        = bool
  default     = true
}

# RDS Proxy Configuration
variable "rds_proxy_enabled" {
  description = "Enable RDS Proxy for connection pooling"
  type        = bool
  default     = true
}

variable "rds_proxy_max_connections" {
  description = "Max connections for RDS Proxy"
  type        = number
  default     = 100
}

variable "rds_proxy_max_idle_connections" {
  description = "Max idle connections for RDS Proxy"
  type        = number
  default     = 10
}

# Database Configuration
variable "database_name" {
  description = "Default database name to create"
  type        = string
  default     = "appdb"
}

variable "readonly_username" {
  description = "Read-only database user name"
  type        = string
  default     = "readonly_user"
}

# Okta Configuration
variable "okta_org_name" {
  description = "Okta organization name"
  type        = string
  sensitive   = true
}

variable "okta_base_url" {
  description = "Okta base URL (e.g., https://dev-12345678.okta.com)"
  type        = string
  sensitive   = true
}

variable "okta_api_token" {
  description = "Okta API token"
  type        = string
  sensitive   = true
}

variable "okta_app_name" {
  description = "Okta SAML application name"
  type        = string
  default     = "okta-aurora-app"
}

variable "okta_group_name" {
  description = "Okta group name for Aurora access"
  type        = string
  default     = "aurora-readonly-users"
}

# IAM Configuration
variable "iam_role_name" {
  description = "IAM role name for Aurora access"
  type        = string
  default     = "aurora-readonly-role"
}

variable "iam_policy_name" {
  description = "IAM policy name for Aurora access"
  type        = string
  default     = "aurora-readonly-policy"
}

variable "session_duration" {
  description = "IAM session duration in seconds"
  type        = number
  default     = 3600 # 1 hour
}

variable "local_ip_cidr" {
  description = "Local machine IP for testing access to Aurora (CIDR format). Remove before production."
  type        = string
  default     = "0.0.0.0/0"
}

variable "bastion_key_pair" {
  description = "EC2 key pair name for bastion SSH access"
  type        = string
  default     = "linux-key"
}

variable "bastion_ami" {
  description = "AMI for bastion (Amazon Linux 2023 x86_64)"
  type        = string
  default     = "ami-0e1e769742d1cfb49"
}

variable "bastion_instance_type" {
  description = "Instance type for bastion (must be in org SCP allowlist)"
  type        = string
  default     = "t3.nano"
}

# Blue/Green Deployment (custom aurora-bluegreen provider)
variable "enable_blue_green" {
  description = "Create the green environment via the custom aurora-bluegreen provider"
  type        = bool
  default     = false
}

variable "green_engine_version" {
  description = "Aurora engine version for green cluster (empty = same as blue, e.g. 8.0.mysql_aurora.3.10.3)"
  type        = string
  default     = ""
}

variable "trigger_switchover" {
  description = "Set true to trigger switchover (green becomes production). Requires enable_blue_green=true."
  type        = bool
  default     = false
}

variable "delete_source_cluster" {
  description = "Set true during destroy to also delete the old blue cluster. Default false keeps it for rollback."
  type        = bool
  default     = false
}

variable "retain_old_cluster" {
  description = "Keep the old blue cluster after switchover (true = safe default). Set false to auto-delete it on destroy."
  type        = bool
  default     = true
}

variable "enable_reverse_replication" {
  description = "Set up binlog replication from new production (green) back to old blue cluster for rollback readiness."
  type        = bool
  default     = false
}

variable "old_blue_cluster_id" {
  description = "Set this once after forward switchover (value from terraform output old_blue_cluster_id). Used by the proxy flip scripts."
  type        = string
  default     = ""
}

variable "bastion_instance_id" {
  description = "EC2 instance ID of the bastion host (e.g. i-0abc123). Must have SSM agent running and AmazonSSMManagedInstanceCore IAM policy. Used to run MySQL commands inside the VPC during proxy flips."
  type        = string
  default     = ""
}

variable "proxy_active_cluster" {
  description = "Which cluster the RDS Proxy routes traffic to: \"new\" (current production) or \"old\" (rollback to old blue). Changing triggers a proxy target flip."
  type        = string
  default     = "new"

  validation {
    condition     = contains(["new", "old"], var.proxy_active_cluster)
    error_message = "proxy_active_cluster must be \"new\" or \"old\"."
  }
}

variable "delete_old_cluster" {
  description = "Set true to delete the old blue cluster immediately via Update() (without terraform destroy). Cannot be true when proxy_active_cluster=\"old\"."
  type        = bool
  default     = false
}

variable "rds_proxy_name" {
  description = "RDS Proxy identifier to redirect during rollback. Required when using proxy_active_cluster."
  type        = string
  default     = ""
}
