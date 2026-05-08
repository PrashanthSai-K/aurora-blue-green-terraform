# Aurora Blue/Green Deployment — Complete Guide

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [How AWS Blue/Green Works](#how-aws-bluegreen-works)
4. [Prerequisites](#prerequisites)
5. [Variable Reference](#variable-reference)
6. [Output Reference](#output-reference)
7. [Phase 1 — Create Green Cluster](#phase-1--create-green-cluster)
8. [Phase 2 — Switchover](#phase-2--switchover)
9. [Phase 3 — Rollback (Proxy → Old Blue)](#phase-3--rollback)
10. [Phase 4 — Re-promote (Proxy → New)](#phase-4--re-promote)
11. [Phase 5 — Delete Old Cluster](#phase-5--delete-old-cluster)
12. [Phase 6 — Cleanup B/G Object](#phase-6--cleanup)
13. [What Changes in AWS at Each Phase](#what-changes-in-aws-at-each-phase)
14. [Zero-Data-Loss Sequence Explained](#zero-data-loss-sequence-explained)
15. [State Reference](#state-reference)
16. [One-Time Setup Checklist](#one-time-setup-checklist)
17. [Decision Tree](#decision-tree)
18. [Troubleshooting](#troubleshooting)

---

## Overview

This project uses a **custom Terraform provider** (`aurora-bluegreen`) to manage the full Aurora Blue/Green lifecycle — create, switchover, rollback, and cleanup — entirely through Terraform variable changes.

**What exists in this design (no more, no less):**

| Operation | How |
|-----------|-----|
| Create green cluster | `enable_blue_green = true` |
| Switchover (green → production) | `trigger_switchover = true` |
| Rollback (proxy → old blue) | `proxy_active_cluster = "old"` |
| Re-promote (proxy → new prod) | `proxy_active_cluster = "new"` |
| Delete old cluster | `delete_old_cluster = true` |
| Cleanup B/G object | `enable_blue_green = false` |

**What does NOT exist in this design:**
- ~~Reverse Blue/Green deployment~~ — removed (was creating a clone of a broken cluster, not a true rollback)
- ~~`trigger_reverse_switchover`~~ — removed
- ~~`enable_reverse_blue_green`~~ — removed

Rollback is done purely via RDS Proxy target flip with binlog replication for zero data loss.

---

## Architecture

```
  Okta (SAML IdP)
       │ SAML assertion
       ▼
  AWS IAM (SAML)  ──►  aurora-readonly-role
       │
       ▼
  ┌──────────────────────────────┐
  │          RDS Proxy           │  ◄── single stable endpoint, never changes
  │    aurora-okta-8a1-proxy     │
  └──────────────────────────────┘
       │
       │  proxy_active_cluster = "new"  ──►  aurora-readonly-db       (production)
       │  proxy_active_cluster = "old"  ──►  aurora-readonly-db-old1  (rollback)
       ▼
  ┌─────────────────────┐     ┌──────────────────────────┐
  │    NEW cluster       │     │    OLD cluster            │
  │  aurora-readonly-db  │     │  aurora-readonly-db-old1  │
  │  (after switchover,  │◄────│  (original blue,          │
  │   was the green)     │repl │   retained for rollback)  │
  └─────────────────────┘     └──────────────────────────┘
    replication direction flips with each proxy flip
```

**After switchover AWS renames clusters:**
- Original blue `aurora-readonly-db` → `aurora-readonly-db-old1` (retained)
- Green `aurora-readonly-db-green-xxxxx` → `aurora-readonly-db` (new production)

---

## How AWS Blue/Green Works

AWS Blue/Green is a **one-shot, one-direction** operation per deployment object:

```
PROVISIONING → AVAILABLE → SWITCHOVER_IN_PROGRESS → SWITCHOVER_COMPLETED
```

| Status | What's happening |
|--------|-----------------|
| `PROVISIONING` | AWS clones blue → green cluster, sets up replication |
| `AVAILABLE` | Green is fully synced — safe to test |
| `SWITCHOVER_IN_PROGRESS` | Traffic cutover in progress (< 1 min downtime) |
| `SWITCHOVER_COMPLETED` | Green is production, blue is renamed and retained |

**Key constraints:**
- Once `SWITCHOVER_COMPLETED`, that B/G object is done — cannot be reused
- AWS handles zero data loss during the forward switchover automatically
- While B/G is active, `aws_db_proxy_target` cannot be Terraform-managed (AWS blocks it)
- For rollback (proxy flip), zero data loss is handled by `pre_proxy_flip.sh` + `post_proxy_flip.sh`

---

## Prerequisites

### Infrastructure (all managed by Terraform)

| Component | Resource | Purpose |
|-----------|----------|---------|
| Aurora cluster | `aws_rds_cluster.main` | Source (blue) cluster |
| RDS Proxy | `aws_db_proxy.main` | Stable endpoint, flipped during rollback |
| Parameter group | `aws_rds_cluster_parameter_group.main` | Applied to green cluster |
| Secrets Manager | `aws_secretsmanager_secret.aurora_credentials` | DB password for proxy + scripts |
| Bastion EC2 | `aws_instance.bastion` | Runs MySQL commands inside VPC via SSM |

### Custom provider

```bash
cd terraform-provider-aurora-bluegreen
make install-darwin-arm64   # macOS Apple Silicon
# or
make install-linux-amd64    # Linux / CI
```

---

## Variable Reference

| Variable | Type | Default | Purpose |
|----------|------|---------|---------|
| `enable_blue_green` | bool | `false` | Creates the B/G deployment resource |
| `trigger_switchover` | bool | `false` | Triggers forward switchover. Flip once, leave `true` |
| `retain_old_cluster` | bool | `true` | Keep old blue after switchover. Always `true` for rollback |
| `delete_source_cluster` | bool | `false` | Delete green cluster on `terraform destroy` |
| `green_engine_version` | string | `""` | Target engine version. Empty = same as blue |
| `enable_reverse_replication` | bool | `false` | Sets `replication_status = SETUP_PENDING` after switchover as a signal |
| `proxy_active_cluster` | string | `"new"` | `"new"` = proxy → production. `"old"` = proxy → old blue (rollback) |
| `rds_proxy_name` | string | `""` | RDS Proxy identifier. Required when using `proxy_active_cluster` |
| `old_blue_cluster_id` | string | `""` | Set after Phase 2 from `terraform output old_blue_cluster_id`. Used by proxy flip scripts |
| `bastion_instance_id` | string | `""` | EC2 instance ID of bastion. Used to run MySQL inside VPC via SSM |
| `delete_old_cluster` | bool | `false` | Delete old blue immediately via Update(). Blocked if proxy routes to old |

---

## Output Reference

| Output | Description |
|--------|-------------|
| `blue_green_deployment_id` | `bgd-xxx` identifier |
| `blue_green_status` | `AVAILABLE` → `SWITCHOVER_COMPLETED` |
| `green_cluster_arn` | ARN of green cluster (for direct testing before switchover) |
| `old_blue_cluster_id` | Cluster ID of old blue after switchover. **Copy to `terraform.tfvars`** |
| `proxy_active_cluster` | Which cluster proxy currently routes to: `"new"` or `"old"` |
| `replication_status` | `NOT_CONFIGURED` / `SETUP_PENDING` / `ACTIVE` / `STOPPED` |

---

## Phase 1 — Create Green Cluster

**Goal:** Clone the production cluster into a green cluster and sync it.

**`terraform.tfvars`:**
```hcl
enable_blue_green  = true
trigger_switchover = false
```

```bash
terraform plan    # should show 1 resource to add
terraform apply   # takes 20–60 minutes
```

**What happens:**
1. Provider calls `CreateBlueGreenDeployment` with the blue cluster as source
2. Polls every 30s until `AVAILABLE`
3. `aws_db_proxy_target` is automatically disabled (`count = 0`) — AWS blocks proxy target registration while B/G is active

**Test the green cluster before committing:**
```bash
terraform output green_cluster_arn
# Find the green cluster in AWS Console → RDS → get its reader endpoint
# Connect directly (bypasses proxy) and run smoke tests
```

**State after Phase 1:**
```
blue_green_status = "AVAILABLE"
green_cluster_arn = "arn:...cluster:aurora-readonly-db-green-xxxxxx"
```

---

## Phase 2 — Switchover

**Goal:** Promote green to production. < 1 min downtime, AWS guarantees zero data loss.

**Prerequisite:** `blue_green_status = "AVAILABLE"`

**`terraform.tfvars`:**
```hcl
trigger_switchover = true
```

```bash
terraform apply   # completes in under 90 seconds
```

**What happens:**
1. Provider calls `SwitchoverBlueGreenDeployment`
2. Polls until `SWITCHOVER_COMPLETED`
3. AWS renames: old blue → `aurora-readonly-db-old1`, green → `aurora-readonly-db`
4. RDS Proxy auto-reconnects to the new `aurora-readonly-db`
5. Provider sets `old_source_cluster_id = "aurora-readonly-db-old1"` in state

**Do this immediately after switchover:**
```bash
# Get the old blue cluster ID — needed for rollback scripts
terraform output old_blue_cluster_id
# → "aurora-readonly-db-old1"

# Set in terraform.tfvars:
old_blue_cluster_id    = "aurora-readonly-db-old1"
bastion_instance_id    = "i-0abc123..."   # from AWS Console or:
                                           # aws ec2 describe-instances --filters "Name=tag:Name,Values=*bastion*" --query 'Reservations[0].Instances[0].InstanceId' --output text
```

**State after Phase 2:**
```
blue_green_status    = "SWITCHOVER_COMPLETED"
old_blue_cluster_id  = "aurora-readonly-db-old1"
proxy_active_cluster = "new"
replication_status   = "SETUP_PENDING"   (if enable_reverse_replication=true)
```

---

## Phase 3 — Rollback

**Goal:** Redirect all traffic to the old blue cluster instantly, with zero data loss.

**Prerequisites:**
- `old_blue_cluster_id` set in `terraform.tfvars`
- `bastion_instance_id` set in `terraform.tfvars`
- Bastion has `AmazonSSMManagedInstanceCore` IAM policy

**`terraform.tfvars`:**
```hcl
proxy_active_cluster = "old"
```

```bash
terraform apply
```

**Terraform enforces this sequence automatically:**

```
Step 1 — null_resource.pre_proxy_flip
  scripts/pre_proxy_flip.sh  (runs on your machine, MySQL executes on bastion via SSM)
  ├─ SET GLOBAL read_only = 1  on new prod  (stops new writes)
  └─ poll SHOW SLAVE STATUS until lag = 0   (old blue is fully caught up)

Step 2 — aurora-bluegreen_deployment.main (Update)
  provider.flipProxy()
  ├─ DeregisterDBProxyTargets  (remove new prod from proxy)
  └─ RegisterDBProxyTargets    (add old blue to proxy)
  → all new connections now go to aurora-readonly-db-old1

Step 3 — null_resource.post_proxy_flip
  scripts/post_proxy_flip.sh  (runs on your machine, MySQL executes on bastion via SSM)
  ├─ CALL mysql.rds_stop_replication()   on old blue
  ├─ SET GLOBAL read_only = 0            old blue → read-write (active production)
  ├─ SHOW MASTER STATUS                  get new prod binlog position
  ├─ CALL mysql.rds_set_external_master  configure old blue to replicate → new prod
  └─ CALL mysql.rds_start_replication    writes to old blue replicate to new prod
```

**State after Phase 3:**
```
proxy_active_cluster = "old"
replication_status   = "STOPPED"
```

**After rollback:**
- Traffic goes to `aurora-readonly-db-old1`
- `aurora-readonly-db` (new prod) is idle but kept alive
- Binlog replication: old blue → new prod keeps new prod in sync
- Fix the issue in new prod, then re-promote (Phase 4)

---

## Phase 4 — Re-promote

**Goal:** After fixing the issue, switch traffic back to the new production cluster.

**`terraform.tfvars`:**
```hcl
proxy_active_cluster = "new"
```

```bash
terraform apply
```

**What happens:**
1. `pre_proxy_flip.sh` — exits immediately (no pre-check needed for "new" direction)
2. Provider flips proxy back to `aurora-readonly-db`
3. `post_proxy_flip.sh`:
   - Stops replication on new prod
   - Promotes new prod to read-write
   - Stops + resets replication on old blue

**State after Phase 4:**
```
proxy_active_cluster = "new"
```

---

## Phase 5 — Delete Old Cluster

**Goal:** Remove the old blue cluster once you're confident production is stable.

**`terraform.tfvars`:**
```hcl
delete_old_cluster = true
```

```bash
terraform apply
```

Provider deletes all instances then the cluster. **Blocked if `proxy_active_cluster = "old"`** — cannot delete the cluster while it's actively serving traffic.

---

## Phase 6 — Cleanup

**Goal:** Remove the B/G deployment object. Production cluster is not affected.

**`terraform.tfvars`:**
```hcl
enable_blue_green = false
```

```bash
terraform apply
```

**What happens:**
1. `aurora-bluegreen_deployment.main` count becomes 0 → Delete() runs
2. Provider checks `proxy_active_cluster` — blocks destroy if still `"old"`
3. Deletes old blue cluster if `retain_old_cluster = false`
4. Calls `DeleteBlueGreenDeployment` API
5. `aws_db_proxy_target` is re-enabled (count = 1) and re-registered automatically

---

## What Changes in AWS at Each Phase

```
INITIAL
────────────────────────────────────────────────
aurora-readonly-db          ← production (blue)
RDS Proxy → aurora-readonly-db
B/G object                  ← does not exist


AFTER PHASE 1 (Create Green)
────────────────────────────────────────────────
aurora-readonly-db          ← production (blue), still taking all writes
aurora-readonly-db-green-xx ← green, replicating from blue (status: AVAILABLE)
bgd-xxxxxxxxxxxxxxxx        ← B/G object
RDS Proxy → aurora-readonly-db  (proxy target disabled in TF while B/G active)


AFTER PHASE 2 (Switchover)
────────────────────────────────────────────────
aurora-readonly-db          ← production (was green, renamed)  ◄── proxy
aurora-readonly-db-old1     ← retained old blue
bgd-xxxxxxxxxxxxxxxx        ← B/G object (SWITCHOVER_COMPLETED)
RDS Proxy → aurora-readonly-db
Binlog replication: new prod → old blue  (if enable_reverse_replication=true)


AFTER PHASE 3 (Rollback — proxy_active_cluster = "old")
────────────────────────────────────────────────
aurora-readonly-db          ← idle, read-only
aurora-readonly-db-old1     ← active production, read-write         ◄── proxy
bgd-xxxxxxxxxxxxxxxx        ← B/G object (SWITCHOVER_COMPLETED)
RDS Proxy → aurora-readonly-db-old1
Binlog replication: old blue → new prod  (reverse, set up by post_proxy_flip.sh)


AFTER PHASE 4 (Re-promote — proxy_active_cluster = "new")
────────────────────────────────────────────────
aurora-readonly-db          ← production, read-write                ◄── proxy
aurora-readonly-db-old1     ← idle (replication stopped)
RDS Proxy → aurora-readonly-db


AFTER PHASE 5 (delete_old_cluster = true)
────────────────────────────────────────────────
aurora-readonly-db          ← production
aurora-readonly-db-old1     ← DELETED


AFTER PHASE 6 (enable_blue_green = false)
────────────────────────────────────────────────
aurora-readonly-db          ← production (tracked by aws_rds_cluster.main)
bgd-xxxxxxxxxxxxxxxx        ← DELETED
RDS Proxy → aurora-readonly-db  (aws_db_proxy_target re-registered)
```

---

## Zero-Data-Loss Sequence Explained

The **forward switchover** (Phase 2) is handled entirely by AWS — zero data loss is guaranteed by the service.

The **proxy flip rollback** (Phase 3) is done at the proxy level, not by AWS B/G machinery, so we must guarantee data consistency ourselves. Here is the exact sequence:

### pre_proxy_flip.sh (runs before proxy flip)

Runs on Terraform host → SSM → bastion → MySQL (Aurora private subnet):

1. Resolve cluster endpoints via AWS API (no VPC needed from Terraform host)
2. Fetch DB master password from Secrets Manager
3. **`SET GLOBAL read_only = 1`** on source (new prod) — no new writes can land
4. Poll **`SHOW SLAVE STATUS`** on target (old blue) every 5 seconds
5. Wait until `Seconds_Behind_Master = 0` — old blue has every write
6. Exit 0 → Terraform proceeds with proxy flip
7. On timeout: restores `read_only = 0` on source, exits 1 (aborts the apply)

### Provider flipProxy() (the actual switch)

1. `DescribeDBProxyTargets` — find current cluster target
2. `DeregisterDBProxyTargets` — remove current cluster
3. `RegisterDBProxyTargets` — add target cluster
4. All new connections via proxy now go to the new cluster

### post_proxy_flip.sh (runs after proxy flip)

Runs on Terraform host → SSM → bastion → MySQL:

**When rolling back (→ old):**
1. `CALL mysql.rds_stop_replication()` on old blue — stops receiving from new prod
2. `SET GLOBAL read_only = 0` on old blue — writable, now active production
3. `SHOW MASTER STATUS` on new prod — get binlog file + position
4. `CALL mysql.rds_set_external_master()` on old blue → set new prod as replication target
5. `CALL mysql.rds_start_replication()` — old blue → new prod replication starts
   *(new prod stays in sync; re-promote will have zero or minimal lag)*

**When re-promoting (→ new):**
1. `CALL mysql.rds_stop_replication()` on new prod
2. `SET GLOBAL read_only = 0` on new prod — writable, back in production
3. Stop + reset replication on old blue

---

## State Reference

| Field | Phase 1 | Phase 2 | Phase 3 (Rollback) | Phase 4 (Re-promote) |
|-------|---------|---------|-------------------|---------------------|
| `status` | `AVAILABLE` | `SWITCHOVER_COMPLETED` | `SWITCHOVER_COMPLETED` | `SWITCHOVER_COMPLETED` |
| `old_source_cluster_id` | null | `aurora-readonly-db-old1` | `aurora-readonly-db-old1` | `aurora-readonly-db-old1` |
| `proxy_active_cluster` | `new` | `new` | `old` | `new` |
| `replication_status` | `NOT_CONFIGURED` | `SETUP_PENDING` | `STOPPED` | `STOPPED` |

---

## One-Time Setup Checklist

Complete these steps once after Phase 2 to unlock fully automated rollback:

- [ ] Run `terraform output old_blue_cluster_id` → copy value to `terraform.tfvars` as `old_blue_cluster_id`
- [ ] Find bastion instance ID → copy to `terraform.tfvars` as `bastion_instance_id`
- [ ] Attach `AmazonSSMManagedInstanceCore` IAM policy to bastion's instance profile
- [ ] Verify `${var.project_name}-master-password` is the correct Secrets Manager secret name

After this, every rollback and re-promote is a single `terraform apply`.

---

## Decision Tree

```
Want to upgrade Aurora engine version or test changes?
  │
  ▼
Phase 1: enable_blue_green=true  (~20-60 min, green cluster created)
  │
  ▼
Test green cluster directly (connect to green endpoint, run smoke tests)
  │
  ├── Tests FAIL? ──► Keep enable_blue_green=true, trigger_switchover=false
  │                   Set enable_blue_green=false to clean up
  │
  ▼
Phase 2: trigger_switchover=true  (<90 sec, green becomes production)
  │
  ├── Issue in new production?
  │     │
  │     ▼
  │   Phase 3: proxy_active_cluster="old"  (rollback, seconds)
  │     │
  │     ▼ (fix the issue in new prod)
  │   Phase 4: proxy_active_cluster="new"  (re-promote)
  │
  ▼
Phase 5 (optional): delete_old_cluster=true
  │
  ▼
Phase 6: enable_blue_green=false  (cleanup B/G object, re-registers proxy target)
```

---

## Troubleshooting

### `RegisterDBProxyTargets: blue-green deployment exists`

**Cause:** `aws_db_proxy_target` is trying to register while B/G is active. AWS blocks this.

**Fix:** Already handled — `aws_db_proxy_target` count is 0 while `enable_blue_green=true`. Remove stale state entry:
```bash
terraform state rm 'aws_db_proxy_target.main[0]'
```

### Switchover reverts to AVAILABLE (abandoned)

**Cause:** AWS cancelled the switchover — usually the proxy can't reach the green cluster.

**Fix:**
1. Check proxy security group allows port 3306 from Aurora security group
2. Check proxy IAM role has `secretsmanager:GetSecretValue` on the credentials secret
3. Set `trigger_switchover=false`, apply, set back to `true`, apply again

### `pre_proxy_flip.sh` times out (lag never reaches 0)

**Cause:** Binlog replication from new prod → old blue is not running.

**Fix:**
1. Connect to old blue via bastion: `SHOW SLAVE STATUS\G` — check if replication is running
2. If not: set `enable_reverse_replication=true` and apply after Phase 2 switchover
3. Increase `MAX_LAG_WAIT_SEC` env variable (default 300) if the cluster is under heavy load

### NAT gateway shows as `+ create` in plan

**Cause:** State has a stale NAT gateway ID (deleted), while the real one exists in AWS.

```bash
terraform state rm aws_nat_gateway.main
terraform state rm aws_eip.nat
terraform import aws_nat_gateway.main nat-XXXXXXXXXXXXXXXXX
ALLOC=$(aws ec2 describe-nat-gateways --nat-gateway-ids nat-XXXXXXXXXXXXXXXXX --query 'NatGateways[0].NatGatewayAddresses[0].AllocationId' --output text --region us-east-1)
terraform import aws_eip.nat $ALLOC
```

### Lock file checksum mismatch after provider rebuild

```bash
rm .terraform.lock.hcl
terraform init -reconfigure
```

### State is empty (all resources show as `+ create`)

```bash
terraform state push -lock=false terraform.tfstate.backup
```

### Provider schema migration (after provider upgrade removes/adds attributes)

```bash
# Get deployment ID
terraform state show 'aurora-bluegreen_deployment.main[0]' | grep deployment_id

# Remove stale state, re-import with new schema
terraform state rm 'aurora-bluegreen_deployment.main[0]'
terraform init -reconfigure
terraform import 'aurora-bluegreen_deployment.main[0]' bgd-xxxxxxxxxxxx
terraform plan
```
