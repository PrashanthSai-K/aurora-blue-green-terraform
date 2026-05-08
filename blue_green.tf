# Blue/Green Deployment — managed by the custom aurora-bluegreen provider.
#
# The provider handles AWS-level operations:
#   - Creating the green Aurora cluster (enable_blue_green=true)
#   - Triggering switchover (trigger_switchover=true)
#   - Flipping the RDS Proxy target (proxy_active_cluster=old|new)
#   - Deleting the old cluster (delete_old_cluster=true)
#
# MySQL operations (read_only, replication) are handled entirely in GitHub Actions.
# See bg-03-enable-replication.yml for replication setup, rollback, and re-promote.

resource "aurora-bluegreen_deployment" "main" {
  count = var.enable_blue_green ? 1 : 0

  deployment_name             = "${var.project_name}-bg"
  source_cluster_arn          = aws_rds_cluster.main.arn
  target_engine_version       = var.green_engine_version != "" ? var.green_engine_version : var.aurora_engine_version
  target_parameter_group_name = aws_rds_cluster_parameter_group.main.name

  trigger_switchover    = var.trigger_switchover
  delete_source_cluster = var.delete_source_cluster

  retain_old_cluster   = var.retain_old_cluster
  rds_proxy_name       = var.rds_proxy_name
  proxy_active_cluster = var.proxy_active_cluster
  delete_old_cluster   = var.delete_old_cluster

  create_timeout_minutes     = 90
  switchover_timeout_seconds = 300

  depends_on = [aws_rds_cluster.main]
}
