###############################################################################
# examples/aurora-57-to-80/main.tf
#
# Complete example: use the custom aurora-bluegreen provider to upgrade
# Aurora MySQL 5.7 → 8.0 with zero state drift.
#
# Phase 1: Apply with trigger_switchover = false  (creates green cluster)
# Phase 2: Apply with trigger_switchover = true   (production switchover)
# Phase 3: terraform destroy (cleanup, with delete_source_cluster = true)
###############################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    aurora-bluegreen = {
      # For local development, this resolves from ~/.terraform.d/plugins/
      # For team use, publish to registry.terraform.io/yourorg/aurora-bluegreen
      source  = "yourorg/aurora-bluegreen"
      version = "~> 1.0"
    }
  }

  backend "s3" {
    bucket = "my-terraform-state"
    key    = "aurora/upgrade/terraform.tfstate"
    region = "ap-south-1"
  }
}

###############################################################################
# Configure the custom provider
###############################################################################
provider "aurora-bluegreen" {
  region = "ap-south-1"
  # Credentials from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY env vars
  # or from the EC2/ECS instance role — no need to hardcode
}

provider "aws" {
  region = "ap-south-1"
}

###############################################################################
# Reference the existing blue cluster (managed by your existing Terraform)
# This data source reads the ARN without taking ownership of the cluster
###############################################################################
data "aws_rds_cluster" "production" {
  cluster_identifier = var.cluster_identifier
}

###############################################################################
# MySQL 8.0 parameter group (created by the existing aws provider)
# Must exist before creating the blue/green deployment
###############################################################################
resource "aws_rds_cluster_parameter_group" "aurora_80" {
  name   = "${var.cluster_identifier}-params-80"
  family = "aurora-mysql8.0"

  parameter {
    name         = "binlog_format"
    value        = "ROW"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "character_set_server"
    value        = "utf8mb4"
    apply_method = "immediate"
  }

  tags = var.common_tags
}

###############################################################################
# THE CUSTOM RESOURCE — full lifecycle managed in Terraform state
#
# Phase 1 (create green):  trigger_switchover = false
# Phase 2 (switchover):    trigger_switchover = true
###############################################################################
resource "aurora-bluegreen_deployment" "upgrade" {
  deployment_name              = "${var.cluster_identifier}-bg-upgrade"
  source_cluster_arn           = data.aws_rds_cluster.production.arn
  target_engine_version        = var.target_engine_version
  target_parameter_group_name  = aws_rds_cluster_parameter_group.aurora_80.name

  # ── Lifecycle flags ──────────────────────────────────────────
  # Phase 1: keep false → creates green cluster and waits for AVAILABLE
  # Phase 2: change to true → triggers switchover in a single `terraform apply`
  trigger_switchover = var.trigger_switchover

  # Set true when running `terraform destroy` after successful upgrade
  delete_source_cluster = var.delete_source_cluster

  # ── Timeouts ──────────────────────────────────────────────────
  create_timeout_minutes    = 90   # green cluster setup can take ~60 min
  switchover_timeout_seconds = 300 # actual switchover < 1 min

  # ── Auto Scaling — re-attached automatically post-switchover ──
  autoscaling_config = {
    policy_name        = "${var.cluster_identifier}-cpu-scaling"
    min_capacity       = 1
    max_capacity       = 5
    target_cpu         = 40.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 300
  }

  depends_on = [aws_rds_cluster_parameter_group.aurora_80]
}

###############################################################################
# OUTPUTS — all from Terraform state, no AWS API calls needed
###############################################################################
output "deployment_id" {
  description = "The AWS Blue/Green Deployment identifier"
  value       = aurora-bluegreen_deployment.upgrade.deployment_id
}

output "deployment_status" {
  description = "Current deployment status"
  value       = aurora-bluegreen_deployment.upgrade.status
}

output "green_cluster_arn" {
  description = "ARN of the green cluster (becomes production after switchover)"
  value       = aurora-bluegreen_deployment.upgrade.green_cluster_arn
}
