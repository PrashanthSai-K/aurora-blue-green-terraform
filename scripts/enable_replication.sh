#!/usr/bin/env bash
# scripts/enable_replication.sh
#
# Sets up MySQL replication from the active (source) cluster to the standby (target).
# ONLY does replication — does NOT touch read_only settings or proxy configuration.
#
# Direction is determined by PROXY_ACTIVE:
#   new → source = new prod, target = old blue  (new prod writes replicate to old blue)
#   old → source = old blue, target = new prod  (old blue writes replicate to new prod)
#
# Run this after:
#   bg-02 switchover (proxy_active_cluster=new): sets up new→old replication for rollback safety
#   bg-04 rollback   (proxy_active_cluster=old): sets up old→new replication for re-promote safety
#
# Required env vars:
#   PROXY_ACTIVE          "new" or "old"
#   OLD_CLUSTER_ID        old blue cluster identifier
#   NEW_CLUSTER_ID        current production cluster identifier
#   AWS_REGION
#   DB_SECRET_NAME        Secrets Manager secret ARN for master credentials
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

log()  { echo "[enable_replication] $*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

# ── Validate inputs ───────────────────────────────────────────────────────────
[[ -z "$OLD_CLUSTER_ID" ]]        && die "OLD_CLUSTER_ID is not set."
[[ -z "$NEW_CLUSTER_ID" ]]        && die "NEW_CLUSTER_ID is not set."
[[ -z "$DB_SECRET_NAME" ]]        && die "DB_SECRET_NAME is not set."
[[ -z "$BASTION_INSTANCE_ID" ]]   && die "BASTION_INSTANCE_ID is not set."

# Determine source → target based on which cluster is currently active
if [[ "$PROXY_ACTIVE" == "new" ]]; then
  SOURCE_CLUSTER="$NEW_CLUSTER_ID"
  TARGET_CLUSTER="$OLD_CLUSTER_ID"
  log "Direction: new prod → old blue (replication for rollback safety)"
elif [[ "$PROXY_ACTIVE" == "old" ]]; then
  SOURCE_CLUSTER="$OLD_CLUSTER_ID"
  TARGET_CLUSTER="$NEW_CLUSTER_ID"
  log "Direction: old blue → new prod (replication for re-promote safety)"
else
  die "Unexpected PROXY_ACTIVE value: '$PROXY_ACTIVE' (expected 'new' or 'old')"
fi

log "  Source (active, receives writes): $SOURCE_CLUSTER"
log "  Target (standby, replication target): $TARGET_CLUSTER"
log "  Bastion: $BASTION_INSTANCE_ID"

# ── Step 1: Resolve endpoints ─────────────────────────────────────────────────
log "Resolving Aurora endpoints via AWS API..."

SOURCE_ENDPOINT=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$SOURCE_CLUSTER" \
  --region "$AWS_REGION" \
  --query 'DBClusters[0].Endpoint' \
  --output text) || die "Failed to describe source cluster $SOURCE_CLUSTER"

TARGET_ENDPOINT=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$TARGET_CLUSTER" \
  --region "$AWS_REGION" \
  --query 'DBClusters[0].Endpoint' \
  --output text) || die "Failed to describe target cluster $TARGET_CLUSTER"

[[ -z "$SOURCE_ENDPOINT" || "$SOURCE_ENDPOINT" == "None" ]] && die "Could not resolve endpoint for $SOURCE_CLUSTER"
[[ -z "$TARGET_ENDPOINT" || "$TARGET_ENDPOINT" == "None" ]] && die "Could not resolve endpoint for $TARGET_CLUSTER"

log "  Source endpoint: $SOURCE_ENDPOINT"
log "  Target endpoint: $TARGET_ENDPOINT"

# ── Step 2: Fetch DB credentials ──────────────────────────────────────────────
log "Fetching DB credentials from Secrets Manager..."
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$DB_SECRET_NAME" \
  --region "$AWS_REGION" \
  --query SecretString \
  --output text) || die "Failed to fetch secret $DB_SECRET_NAME"

DB_USER=$(echo "$SECRET_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('username', d.get('user', 'admin')))
" 2>/dev/null) || die "Could not parse username from secret"

DB_PASS=$(echo "$SECRET_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('password', d.get('masterpassword', next(iter(d.values())))))
" 2>/dev/null) || die "Could not parse password from secret"

[[ -z "$DB_PASS" ]] && die "Empty password from Secrets Manager"
[[ -z "$DB_USER" ]] && DB_USER="admin"

# ── Step 3: Build and send replication setup script to bastion ────────────────
REMOTE_SCRIPT=$(cat <<SCRIPT
#!/bin/bash
set -euo pipefail

SOURCE_ENDPOINT='${SOURCE_ENDPOINT}'
TARGET_ENDPOINT='${TARGET_ENDPOINT}'
DB_PORT='${DB_PORT}'
DB_USER='${DB_USER}'
DB_PASS='${DB_PASS}'

mysql_exec() {
  local host="\$1"; shift
  mysql -h "\$host" -P "\$DB_PORT" -u "\$DB_USER" -p"\$DB_PASS" -sNe "\$@" 2>/dev/null
}

if ! command -v mysql &>/dev/null; then
  sudo dnf install -y mariadb105 2>/dev/null || \
  sudo yum install -y mariadb 2>/dev/null || \
  sudo apt-get install -y mysql-client 2>/dev/null || true
fi
command -v mysql &>/dev/null || { echo "[bastion] ERROR: mysql client not available"; exit 1; }

# Idempotency: if already replicating from the correct source, skip setup
CURRENT_MASTER=\$(mysql_exec "\$TARGET_ENDPOINT" "SHOW SLAVE STATUS\G" 2>/dev/null \
  | grep "Master_Host:" | awk '{print \$2}' || echo "")
if [[ "\$CURRENT_MASTER" == "\$SOURCE_ENDPOINT" ]]; then
  echo "[bastion] Already replicating from \$SOURCE_ENDPOINT — verifying status..."
  LAG=\$(mysql_exec "\$TARGET_ENDPOINT" "SHOW SLAVE STATUS\G" 2>/dev/null \
    | grep "Seconds_Behind_Master:" | awk '{print \$2}')
  echo "[bastion] Replication already running. Seconds_Behind_Master=\${LAG:-unknown}"
  exit 0
fi

echo "[bastion] Stopping any existing replication on target (\$TARGET_ENDPOINT)..."
mysql_exec "\$TARGET_ENDPOINT" "CALL mysql.rds_stop_replication();" 2>/dev/null || true
mysql_exec "\$TARGET_ENDPOINT" "CALL mysql.rds_reset_external_master();" 2>/dev/null || true

echo "[bastion] Getting binlog position from source (\$SOURCE_ENDPOINT)..."
MASTER_STATUS=\$(mysql_exec "\$SOURCE_ENDPOINT" "SHOW MASTER STATUS\G")
BINLOG_FILE=\$(echo "\$MASTER_STATUS" | grep "File:" | awk '{print \$2}')
BINLOG_POS=\$(echo "\$MASTER_STATUS" | grep "Position:" | awk '{print \$2}')

[[ -z "\$BINLOG_FILE" ]] && { echo "[bastion] ERROR: Could not read binlog position from source"; exit 1; }
echo "[bastion] Binlog: file=\$BINLOG_FILE  pos=\$BINLOG_POS"

echo "[bastion] Setting up replication: \$TARGET_ENDPOINT → replicates from \$SOURCE_ENDPOINT ..."
mysql_exec "\$TARGET_ENDPOINT" "CALL mysql.rds_set_external_master('\$SOURCE_ENDPOINT', \$DB_PORT, '\$DB_USER', '\$DB_PASS', '\$BINLOG_FILE', \$BINLOG_POS, 0);"
mysql_exec "\$TARGET_ENDPOINT" "CALL mysql.rds_start_replication();"

echo "[bastion] Replication started. Waiting for initial sync..."
sleep 5
LAG=\$(mysql_exec "\$TARGET_ENDPOINT" "SHOW SLAVE STATUS\G" 2>/dev/null \
  | grep "Seconds_Behind_Master:" | awk '{print \$2}')
echo "[bastion] Replication running. Seconds_Behind_Master=\${LAG:-unknown}"
echo "[bastion] Done: \$SOURCE_ENDPOINT → \$TARGET_ENDPOINT"
SCRIPT
)

# ── Step 4: Send to bastion via SSM ──────────────────────────────────────────
log "Sending replication setup script to bastion via SSM..."
ENCODED=$(echo "$REMOTE_SCRIPT" | base64 | tr -d '\n')

SSM_INPUT=$(python3 -c "
import json
print(json.dumps({
  'InstanceIds': ['${BASTION_INSTANCE_ID}'],
  'DocumentName': 'AWS-RunShellScript',
  'Parameters': {'commands': ['echo ${ENCODED} | base64 -d | bash']},
  'TimeoutSeconds': 120
}))
")

CMD_ID=$(aws ssm send-command \
  --region "$AWS_REGION" \
  --cli-input-json "$SSM_INPUT" \
  --output text \
  --query "Command.CommandId") || die "Failed to send SSM command"

log "SSM command sent: $CMD_ID — polling..."

# ── Step 5: Poll SSM ──────────────────────────────────────────────────────────
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
      log "Replication setup complete."
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
