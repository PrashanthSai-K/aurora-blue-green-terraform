###############################################################################
# examples/standalone-bluegreen/variables.tf
###############################################################################

variable "aws_region" {
  description = "AWS region where the Aurora cluster lives"
  type        = string
  default     = "us-east-1"
}

variable "source_cluster_identifier" {
  description = "Identifier of the existing Aurora cluster (the blue cluster)"
  type        = string
}

variable "target_engine_version" {
  description = "Aurora MySQL engine version for the green cluster. Use the same version as source for a same-version blue/green, or a newer version for an upgrade (e.g. 8.0.mysql_aurora.3.10.3)"
  type        = string
}

variable "parameter_group_family" {
  description = "Parameter group family for the green cluster (e.g. aurora-mysql8.0)"
  type        = string
  default     = "aurora-mysql8.0"
}

variable "trigger_switchover" {
  description = "Phase 1: false (create green only). Phase 2: true (trigger production switchover)"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to created resources"
  type        = map(string)
  default     = {}
}

# rollback and replication testing in progress — keep it as it is
