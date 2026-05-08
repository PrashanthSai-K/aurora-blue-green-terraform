###############################################################################
# examples/aurora-57-to-80/variables.tf
###############################################################################

variable "cluster_identifier" {
  type    = string
  default = "prod-aurora-mysql"
}

variable "target_engine_version" {
  type    = string
  default = "8.0.mysql_aurora.3.07.1"
}

variable "trigger_switchover" {
  type        = bool
  default     = false
  description = "Set to true in Phase 2 to trigger production switchover"
}

variable "delete_source_cluster" {
  type        = bool
  default     = false
  description = "Set to true during terraform destroy to also delete the old blue cluster"
}

variable "common_tags" {
  type = map(string)
  default = {
    ManagedBy   = "terraform"
    Environment = "production"
  }
}
