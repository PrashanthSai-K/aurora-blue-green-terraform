# Aurora Blue/Green Deployment — Standalone Example

Use this example to create and manage an Aurora MySQL Blue/Green Deployment
against an **existing** Aurora cluster. No changes to your current Terraform
infrastructure code are required.

> **Scope:** This example covers Blue/Green creation and switchover only.
> Rollback and replication support are currently in testing and not included here.

---

## Prerequisites

| Requirement | Details |
|---|---|
| Existing Aurora MySQL cluster | Must have `binlog_format = ROW` in its cluster parameter group |
| AWS credentials | IAM permissions: `rds:*`, `iam:PassRole` |
| Terraform | >= 1.3 |
| Go | >= 1.21 (only needed once to build the provider) |
| S3 bucket | For Terraform remote state (or remove `backend "s3"` for local state) |

> **Binary logging required.** Set `binlog_format = ROW` (or `MIXED`) in the
> source cluster parameter group before creating the deployment. If it is not
> set, deployment creation will fail.

---

## Step 0 — Build & Install the Provider

Do this **once** on any machine that will run `terraform apply`.

```bash
cd terraform-provider-aurora-bluegreen/
make install
```

This compiles the provider and copies the binary to:
```
~/.terraform.d/plugins/local/aurora-bluegreen/aurora-bluegreen/1.0.0/
```

Verify:
```bash
ls ~/.terraform.d/plugins/local/aurora-bluegreen/aurora-bluegreen/
```

---

## Step 1 — Configure Your Variables

```bash
cd examples/standalone-bluegreen/
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your values:

```hcl
aws_region                = "us-east-1"
source_cluster_identifier = "my-aurora-cluster"       # your existing cluster ID
target_engine_version     = "8.0.mysql_aurora.3.07.1" # same or newer version
parameter_group_family    = "aurora-mysql8.0"
```

Update the `backend "s3"` block in `main.tf` with your state bucket, or remove
it entirely to use local state.

---

## Step 2 — Initialize Terraform

```bash
terraform init
```

---

## Phase 1 — Create the Green Cluster

```bash
# trigger_switchover = false  (default)
terraform apply
```

This creates the AWS Blue/Green Deployment and waits for the green cluster to
reach `AVAILABLE` (~30–60 minutes).

Check progress:
```bash
terraform output deployment_status   # → AVAILABLE when ready
terraform output green_cluster_arn   # → ARN of your green cluster
```

**Before proceeding to Phase 2:**
- Connect to the green cluster endpoint (AWS Console → RDS → Blue/Green
  Deployments → your deployment → Green environment endpoint)
- Run your smoke tests against the green cluster
- Confirm data looks correct

---

## Phase 2 — Switchover (Green Becomes Production)

```bash
# Edit terraform.tfvars:
trigger_switchover = true

terraform apply
```

The provider triggers the switchover and waits for `SWITCHOVER_COMPLETED`
(typically under 1 minute).

After switchover:
- The green cluster takes over the original cluster's name and endpoint
- The old blue cluster is renamed with a `-old1` suffix
- Your application traffic continues without any DNS change

Check:
```bash
terraform output deployment_status    # → SWITCHOVER_COMPLETED
terraform output old_blue_cluster_id  # → the renamed old cluster (kept for safety)
```

---

## Variable Reference

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `us-east-1` | AWS region |
| `source_cluster_identifier` | required | Your existing Aurora cluster ID |
| `target_engine_version` | required | Engine version for the green cluster |
| `parameter_group_family` | `aurora-mysql8.0` | Parameter group family |
| `trigger_switchover` | `false` | `false` = Phase 1, `true` = Phase 2 |
| `tags` | `{}` | Tags for created resources |

---

## Outputs

| Output | Description |
|---|---|
| `deployment_id` | AWS Blue/Green Deployment ID (`bgd-xxx`) |
| `deployment_status` | Current deployment status |
| `green_cluster_arn` | ARN of the green cluster |
| `old_blue_cluster_id` | Cluster ID of old blue after switchover |

---

## Troubleshooting

**`Error: binlog_format not set` or deployment fails immediately**
Set `binlog_format = ROW` in the cluster parameter group of your source cluster
and reboot the writer instance before running `terraform apply`.

**Green cluster stuck in `PROVISIONING` for a long time**
Check RDS Console → Blue/Green Deployments → Events for the deployment.
Common causes: parameter group family mismatch, or insufficient instance
capacity in the AZ.

**`terraform apply` times out during green cluster creation**
Increase `create_timeout_minutes` in `main.tf` (default is 90). Large clusters
with many read replicas can take longer.
