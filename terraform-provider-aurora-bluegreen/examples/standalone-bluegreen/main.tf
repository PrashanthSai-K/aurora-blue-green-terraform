###############################################################################
# examples/standalone-bluegreen/main.tf
#
# Standalone example: use the custom aurora-bluegreen provider against an
# existing Aurora MySQL cluster.  No other Terraform resources required.
#
# Workflow
# ────────
# Phase 1  terraform apply                        → creates green cluster
# Phase 2  trigger_switchover = true → apply      → production switchover
###############################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    aurora-bluegreen = {
      # Installed locally after `make install` in the provider directory.
      # See README.md — "Build & Install the Provider" section.
      source  = "local/aurora-bluegreen/aurora-bluegreen"
      version = "~> 1.0"
    }
  }

  # Replace with your own S3 backend or remove for local state.
  backend "s3" {
    bucket = "YOUR_TF_STATE_BUCKET"
    key    = "bluegreen/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region
}

provider "aurora-bluegreen" {
  region = var.aws_region
}

# ── Read the existing blue cluster ────────────────────────────────────────────
# This does NOT take ownership of the cluster — it only reads its ARN.
data "aws_rds_cluster" "source" {
  cluster_identifier = var.source_cluster_identifier
}

# ── Parameter group for the green cluster ────────────────────────────────────
resource "aws_rds_cluster_parameter_group" "green" {
  name   = "${var.source_cluster_identifier}-green-params"
  family = var.parameter_group_family

  parameter {
    name         = "binlog_format"
    value        = "ROW"
    apply_method = "pending-reboot"
  }

  tags = var.tags
}

# ── Blue/Green Deployment ─────────────────────────────────────────────────────
resource "aurora-bluegreen_deployment" "this" {
  deployment_name             = "${var.source_cluster_identifier}-bg"
  source_cluster_arn          = data.aws_rds_cluster.source.arn
  target_engine_version       = var.target_engine_version
  target_parameter_group_name = aws_rds_cluster_parameter_group.green.name

  # Phase 1: false (creates green cluster and waits for AVAILABLE)
  # Phase 2: true  (triggers switchover — green becomes production)
  trigger_switchover = var.trigger_switchover # (Make this true for making the switchover)

  # rollback and replication testing in progress — keep it as it is
  retain_old_cluster    = true
  delete_source_cluster = false
  delete_old_cluster    = false
  rds_proxy_name        = ""
  proxy_active_cluster  = "new"

  create_timeout_minutes     = 90
  switchover_timeout_seconds = 300

  depends_on = [aws_rds_cluster_parameter_group.green]
}

###############################################################################
# Outputs
###############################################################################
output "deployment_id" {
  description = "AWS Blue/Green Deployment identifier (bgd-xxx)"
  value       = aurora-bluegreen_deployment.this.deployment_id
}

output "deployment_status" {
  description = "PROVISIONING | AVAILABLE | SWITCHOVER_IN_PROGRESS | SWITCHOVER_COMPLETED"
  value       = aurora-bluegreen_deployment.this.status
}

output "green_cluster_arn" {
  description = "ARN of the green cluster (test against this before switchover)"
  value       = aurora-bluegreen_deployment.this.green_cluster_arn
}

output "old_blue_cluster_id" {
  description = "Cluster ID of the old blue cluster after switchover"
  value       = aurora-bluegreen_deployment.this.old_source_cluster_id
}
