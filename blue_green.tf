# Blue/Green Deployment — managed by the custom aurora-bluegreen provider.
#
# Provider lifecycle:
#   Phase 1  enable_blue_green=true                  → creates green cluster (AVAILABLE)
#   Phase 2  trigger_switchover=true                 → production switchover; on success the
#                                                       B/G deployment object is auto-deleted
#                                                       and the old cluster is retained in state
#   Rollback trigger_rollback=true                   → name-swap: new prod → <orig>-new1,
#                                                       old blue → <orig> (original endpoint restored)
#   Cleanup  delete_cluster_after_rollback=true      → deletes the <orig>-new1 cluster
#
# MySQL operations (read_only, replication) are handled entirely in GitHub Actions.
# See bg-03-enable-replication.yml for replication setup and rollback pre-flight.

resource "aurora-bluegreen_deployment" "main" {
  count = var.enable_blue_green ? 1 : 0

  deployment_name             = "${var.project_name}-bg"
  source_cluster_arn          = aws_rds_cluster.main.arn
  target_engine_version       = var.green_engine_version != "" ? var.green_engine_version : var.aurora_engine_version
  target_parameter_group_name = aws_rds_cluster_parameter_group.main.name

  trigger_switchover    = var.trigger_switchover
  delete_source_cluster = var.delete_source_cluster

  trigger_rollback              = var.trigger_rollback
  delete_cluster_after_rollback = var.delete_cluster_after_rollback

  create_timeout_minutes     = 90
  switchover_timeout_seconds = 300

  depends_on = [aws_rds_cluster.main]
}
