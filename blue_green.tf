# Blue/Green Deployment — managed by the custom aurora-bluegreen provider.
#
# Phases:
#
# Phase 1 — Create green cluster:
#   terraform apply -var="enable_blue_green=true"
#
# Phase 2 — Switchover (green becomes production):
#   terraform apply -var="trigger_switchover=true"
#   After: capture output: terraform output old_blue_cluster_id
#          set old_blue_cluster_id = "<value>" in terraform.tfvars
#
# Phase 3 — Rollback (zero-data-loss proxy flip to old):
#   terraform apply -var="proxy_active_cluster=old"
#   Terraform automatically enforces:
#     pre_proxy_flip.sh  → (sets new prod read-only, waits lag=0)
#     provider flips proxy
#     post_proxy_flip.sh → (promotes old blue, sets up reverse replication)
#   Note: the bastion host must have MySQL connectivity to Aurora for the scripts.
#
# Phase 4 — Re-promote new cluster:
#   terraform apply -var="proxy_active_cluster=new"
#
# Phase 5 — Delete old cluster (cleanup):
#   terraform apply -var="delete_old_cluster=true"

# ── Pre-proxy-flip gate ───────────────────────────────────────────────────────
# Runs BEFORE aurora-bluegreen_deployment.main (via depends_on on the resource).
# Enforces: set new prod read-only + wait for replication lag = 0 before proxy flip.
# Only active after switchover (old_blue_cluster_id is set) and when proxy_active_cluster changes.
resource "null_resource" "pre_proxy_flip" {
  count = var.enable_blue_green && var.trigger_switchover && var.old_blue_cluster_id != "" ? 1 : 0

  triggers = {
    # Re-run whenever the desired proxy target changes.
    proxy_active_cluster = var.proxy_active_cluster
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/pre_proxy_flip.sh"
    environment = {
      PROXY_ACTIVE          = var.proxy_active_cluster
      OLD_CLUSTER_ID        = var.old_blue_cluster_id
      NEW_CLUSTER_ID        = var.aurora_cluster_name
      RDS_PROXY_NAME        = var.rds_proxy_name
      AWS_REGION            = var.aws_region
      DB_SECRET_NAME        = "${var.project_name}-master-password"
      BASTION_INSTANCE_ID   = var.bastion_instance_id
    }
  }
}

# ── Main Blue/Green deployment resource ───────────────────────────────────────
# depends_on null_resource.pre_proxy_flip ensures the pre-check always runs
# before any proxy flip is attempted.
resource "aurora-bluegreen_deployment" "main" {
  count = var.enable_blue_green ? 1 : 0

  deployment_name             = "${var.project_name}-bg"
  source_cluster_arn          = aws_rds_cluster.main.arn
  target_engine_version       = var.green_engine_version != "" ? var.green_engine_version : var.aurora_engine_version
  target_parameter_group_name = aws_rds_cluster_parameter_group.main.name

  trigger_switchover    = var.trigger_switchover
  delete_source_cluster = var.delete_source_cluster

  retain_old_cluster         = var.retain_old_cluster
  enable_reverse_replication = var.enable_reverse_replication
  rds_proxy_name             = var.rds_proxy_name
  proxy_active_cluster       = var.proxy_active_cluster
  delete_old_cluster         = var.delete_old_cluster

  create_timeout_minutes     = 90
  switchover_timeout_seconds = 300

  depends_on = [aws_rds_cluster.main, null_resource.pre_proxy_flip]
}

# ── Post-proxy-flip ────────────────────────────────────────────────────────────
# Runs AFTER aurora-bluegreen_deployment.main completes (proxy has been flipped).
# Promotes the newly active cluster to read-write and wires up reverse replication.
resource "null_resource" "post_proxy_flip" {
  count = var.enable_blue_green && var.trigger_switchover && var.old_blue_cluster_id != "" ? 1 : 0

  triggers = {
    proxy_active_cluster = var.proxy_active_cluster
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/post_proxy_flip.sh"
    environment = {
      PROXY_ACTIVE          = var.proxy_active_cluster
      OLD_CLUSTER_ID        = var.old_blue_cluster_id
      NEW_CLUSTER_ID        = var.aurora_cluster_name
      RDS_PROXY_NAME        = var.rds_proxy_name
      AWS_REGION            = var.aws_region
      DB_SECRET_NAME        = "${var.project_name}-master-password"
      BASTION_INSTANCE_ID   = var.bastion_instance_id
    }
  }

  depends_on = [aurora-bluegreen_deployment.main]
}
