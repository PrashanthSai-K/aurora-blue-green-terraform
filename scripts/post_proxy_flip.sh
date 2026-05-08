#!/usr/bin/env bash
# scripts/post_proxy_flip.sh
#
# Phase 3 of the zero-data-loss proxy flip sequence.
# Runs on the TERRAFORM HOST — uses SSM to execute MySQL commands on the bastion.
#
# When proxy_active_cluster was flipped → "old" (rollback):
#   On bastion:
#   1. Stop replication on old blue (was replica of new prod)
#   2. Promote old blue to read-write (SET GLOBAL read_only = 0)
#   3. Get new prod's binlog position (SHOW MASTER STATUS)
#   4. Set up reverse replication on old blue → replicates TO new prod
#      (so new prod stays in sync; re-promote later will have minimal lag)
#   5. Start replication
#
# When proxy_active_cluster was flipped → "new" (re-promote):
#   On bastion:
#   1. Stop replication on new prod (was receiving from old blue during rollback)
#   2. Promote new prod to read-write
#   3. Stop replication + reset on old blue
#
# Required env vars (set by null_resource.post_proxy_flip in blue_green.tf):
#   PROXY_ACTIVE          "new" or "old" (the value just applied)
#   OLD_CLUSTER_ID        old blue cluster identifier
#   NEW_CLUSTER_ID        current production cluster identifier
#   AWS_REGION
#   DB_SECRET_NAME        Secrets Manager secret name for master password
#   BASTION_INSTANCE_ID   EC2 instance ID of the bastion
#
# Optional:
#   DB_PORT   MySQL port (default 3306)

set -euo pipefail

PROXY_ACTIVE="${PROXY_ACTIVE:-new}"
OLD_CLUSTER_ID="${OLD_CLUSTER_ID:-}"
NEW_CLUSTER_ID="${NEW_CLUSTER_ID:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
DB_SECRET_NAME="${DB_SECRET_NAME:-}"
BASTION_INSTANCE_ID="${BASTION_INSTANCE_ID:-}"
DB_PORT="${DB_PORT:-3306}"

log()  { echo "[post_proxy_flip] $*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

# ── Validate inputs ───────────────────────────────────────────────────────────
[[ -z "$OLD_CLUSTER_ID" ]]        && die "OLD_CLUSTER_ID is not set."
[[ -z "$NEW_CLUSTER_ID" ]]        && die "NEW_CLUSTER_ID is not set."
[[ -z "$DB_SECRET_NAME" ]]        && die "DB_SECRET_NAME is not set."
[[ -z "$BASTION_INSTANCE_ID" ]]   && die "BASTION_INSTANCE_ID is not set. Add it to terraform.tfvars."

log "Post-proxy-flip (proxy_active_cluster=$PROXY_ACTIVE)"
log "  Old cluster: $OLD_CLUSTER_ID"
log "  New cluster: $NEW_CLUSTER_ID"
log "  Bastion: $BASTION_INSTANCE_ID"

# ── Step 1: Resolve endpoints (AWS API — runs on Terraform host) ──────────────
log "Resolving Aurora endpoints via AWS API..."

NEW_ENDPOINT=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$NEW_CLUSTER_ID" \
  --region "$AWS_REGION" \
  --query 'DBClusters[0].Endpoint' \
  --output text) || die "Failed to describe new cluster $NEW_CLUSTER_ID"

OLD_ENDPOINT=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$OLD_CLUSTER_ID" \
  --region "$AWS_REGION" \
  --query 'DBClusters[0].Endpoint' \
  --output text) || die "Failed to describe old cluster $OLD_CLUSTER_ID"

[[ -z "$NEW_ENDPOINT" || "$NEW_ENDPOINT" == "None" ]] && die "Could not resolve endpoint for $NEW_CLUSTER_ID"
[[ -z "$OLD_ENDPOINT" || "$OLD_ENDPOINT" == "None" ]] && die "Could not resolve endpoint for $OLD_CLUSTER_ID"

log "  New prod endpoint: $NEW_ENDPOINT"
log "  Old blue endpoint: $OLD_ENDPOINT"

# ── Step 2: Fetch DB password from Secrets Manager (runs on Terraform host) ──
log "Fetching DB password from Secrets Manager: $DB_SECRET_NAME"
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$DB_SECRET_NAME" \
  --region "$AWS_REGION" \
  --query SecretString \
  --output text) || die "Failed to fetch secret $DB_SECRET_NAME"

DB_PASS=$(echo "$SECRET_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('password', d.get('masterpassword', d.get('MYSQL_ROOT_PASSWORD', next(iter(d.values()))))))
" 2>/dev/null) || die "Could not parse password from Secrets Manager JSON"

[[ -z "$DB_PASS" ]] && die "Empty password from Secrets Manager"

# ── Step 3: Build MySQL script for bastion ────────────────────────────────────
if [[ "$PROXY_ACTIVE" == "old" ]]; then
  # Proxy just flipped to old blue. Promote old blue, set up reverse replication.
  REMOTE_SCRIPT=$(cat <<SCRIPT
#!/bin/bash
set -euo pipefail

OLD_ENDPOINT='${OLD_ENDPOINT}'
NEW_ENDPOINT='${NEW_ENDPOINT}'
DB_PORT='${DB_PORT}'
DB_PASS='${DB_PASS}'

mysql_exec() {
  local host="\$1"; shift
  mysql -h "\$host" -P "\$DB_PORT" -u admin -p"\$DB_PASS" --ssl-mode=REQUIRED -sNe "\$@" 2>/dev/null
}

if ! command -v mysql &>/dev/null; then
  sudo dnf install -y mariadb105 2>/dev/null || \
  sudo yum install -y mariadb 2>/dev/null || \
  sudo apt-get install -y mysql-client 2>/dev/null || true
fi
command -v mysql &>/dev/null || { echo "[bastion] ERROR: mysql client not available after install attempt"; exit 1; }

echo "[bastion] Stopping replication on old blue (\$OLD_ENDPOINT)..."
mysql_exec "\$OLD_ENDPOINT" "CALL mysql.rds_stop_replication();" 2>/dev/null || true
echo "[bastion] Replication stopped."

echo "[bastion] Promoting old blue to read-write..."
mysql_exec "\$OLD_ENDPOINT" "SET GLOBAL read_only = 0;"
echo "[bastion] Old blue is now read-write (active production)."

echo "[bastion] Getting new prod binlog position (\$NEW_ENDPOINT)..."
MASTER_STATUS=\$(mysql_exec "\$NEW_ENDPOINT" "SHOW MASTER STATUS\G")
BINLOG_FILE=\$(echo "\$MASTER_STATUS" | grep "File:" | awk '{print \$2}')
BINLOG_POS=\$(echo "\$MASTER_STATUS" | grep "Position:" | awk '{print \$2}')
echo "[bastion] Binlog: file=\$BINLOG_FILE pos=\$BINLOG_POS"

# Idempotency: skip if already replicating from new prod
CURRENT_MASTER=\$(mysql_exec "\$OLD_ENDPOINT" "SHOW SLAVE STATUS\G" 2>/dev/null \
  | grep "Master_Host:" | awk '{print \$2}' || echo "")
if [[ "\$CURRENT_MASTER" == "\$NEW_ENDPOINT" ]]; then
  echo "[bastion] Already replicating from new prod — skipping setup."
else
  echo "[bastion] Setting up reverse replication: old blue → new prod..."
  mysql_exec "\$OLD_ENDPOINT" "CALL mysql.rds_set_external_master('\$NEW_ENDPOINT', \$DB_PORT, 'admin', '\$DB_PASS', '\$BINLOG_FILE', \$BINLOG_POS, 0);"
  mysql_exec "\$OLD_ENDPOINT" "CALL mysql.rds_start_replication();"
  echo "[bastion] Reverse replication started: old blue → new prod."
fi

echo "[bastion] Post-flip (rollback) complete."
echo "[bastion]   Active: OLD cluster (\$OLD_ENDPOINT)"
echo "[bastion]   Replication: old blue → new prod (new prod stays in sync for re-promote)"
SCRIPT
)

elif [[ "$PROXY_ACTIVE" == "new" ]]; then
  # Proxy just flipped back to new prod. Promote new prod, stop reverse replication.
  REMOTE_SCRIPT=$(cat <<SCRIPT
#!/bin/bash
set -euo pipefail

OLD_ENDPOINT='${OLD_ENDPOINT}'
NEW_ENDPOINT='${NEW_ENDPOINT}'
DB_PORT='${DB_PORT}'
DB_PASS='${DB_PASS}'

mysql_exec() {
  local host="\$1"; shift
  mysql -h "\$host" -P "\$DB_PORT" -u admin -p"\$DB_PASS" --ssl-mode=REQUIRED -sNe "\$@" 2>/dev/null
}

if ! command -v mysql &>/dev/null; then
  sudo dnf install -y mariadb105 2>/dev/null || \
  sudo yum install -y mariadb 2>/dev/null || \
  sudo apt-get install -y mysql-client 2>/dev/null || true
fi
command -v mysql &>/dev/null || { echo "[bastion] ERROR: mysql client not available after install attempt"; exit 1; }

echo "[bastion] Stopping replication on new prod (\$NEW_ENDPOINT)..."
mysql_exec "\$NEW_ENDPOINT" "CALL mysql.rds_stop_replication();" 2>/dev/null || true
echo "[bastion] Replication stopped on new prod."

echo "[bastion] Promoting new prod to read-write..."
mysql_exec "\$NEW_ENDPOINT" "SET GLOBAL read_only = 0;"
echo "[bastion] New prod is now read-write (active production)."

echo "[bastion] Stopping reverse replication on old blue (\$OLD_ENDPOINT)..."
mysql_exec "\$OLD_ENDPOINT" "CALL mysql.rds_stop_replication();" 2>/dev/null || true
mysql_exec "\$OLD_ENDPOINT" "CALL mysql.rds_reset_external_master();" 2>/dev/null || true
echo "[bastion] Old blue replication stopped."

echo "[bastion] Post-flip (re-promote) complete."
echo "[bastion]   Active: NEW cluster (\$NEW_ENDPOINT)"
echo "[bastion]   Old blue is idle — delete with delete_old_cluster=true when ready."
SCRIPT
)

else
  die "Unexpected PROXY_ACTIVE value: '$PROXY_ACTIVE' (expected 'new' or 'old')"
fi

# ── Step 4: Base64-encode and send to bastion via SSM ────────────────────────
log "Sending script to bastion via SSM..."
ENCODED=$(echo "$REMOTE_SCRIPT" | base64 | tr -d '\n')

SSM_INPUT=$(python3 -c "
import json
print(json.dumps({
  'InstanceIds': ['${BASTION_INSTANCE_ID}'],
  'DocumentName': 'AWS-RunShellScript',
  'Parameters': {'commands': ['echo ${ENCODED} | base64 -d | bash']},
  'TimeoutSeconds': 300
}))
")

CMD_ID=$(aws ssm send-command \
  --region "$AWS_REGION" \
  --cli-input-json "$SSM_INPUT" \
  --output text \
  --query "Command.CommandId") || die "Failed to send SSM command"

log "SSM command sent: $CMD_ID — polling for completion..."

# ── Step 5: Poll SSM until completion ────────────────────────────────────────
while true; do
  RESULT=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" \
    --instance-id "$BASTION_INSTANCE_ID" \
    --region "$AWS_REGION" \
    --output json 2>/dev/null || echo '{"Status":"Pending"}')

  STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Status','Pending'))")

  case "$STATUS" in
    Success)
      OUTPUT=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('StandardOutputContent',''))")
      log "Post-proxy-flip operations completed successfully."
      echo "$OUTPUT" | sed 's/^/  /' >&2
      exit 0
      ;;
    Failed|Cancelled|TimedOut|DeliveryTimedOut|ExecutionTimedOut)
      STDOUT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('StandardOutputContent',''))")
      STDERR=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('StandardErrorContent',''))")
      log "Script failed on bastion (status=$STATUS):"
      echo "$STDOUT" | sed 's/^/  [stdout] /' >&2
      echo "$STDERR" | sed 's/^/  [stderr] /' >&2
      exit 1
      ;;
    *)
      log "SSM status: $STATUS — waiting..."
      sleep 5
      ;;
  esac
done
