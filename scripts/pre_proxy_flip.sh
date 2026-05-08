#!/usr/bin/env bash
# scripts/pre_proxy_flip.sh
#
# Zero-data-loss pre-flight check before flipping the RDS Proxy.
# Called as a GitHub Actions step — sets the current active cluster read-only
# and waits for the target cluster's replication lag to reach zero.
#
#   PROXY_ACTIVE=old (rollback):
#     SOURCE = new prod  → set read-only
#     TARGET = old blue  → wait until Seconds_Behind_Master = 0
#
#   PROXY_ACTIVE=new (repromote):
#     SOURCE = old blue  → set read-only
#     TARGET = new prod  → wait until Seconds_Behind_Master = 0
#     If TARGET is not replicating, warns and skips the lag wait.
#
# Required env vars:
#   PROXY_ACTIVE          "new" or "old" (destination — where we're flipping TO)
#   OLD_CLUSTER_ID        old blue cluster identifier
#   NEW_CLUSTER_ID        current production cluster identifier
#   AWS_REGION
#   DB_SECRET_NAME        Secrets Manager secret ARN for master credentials
#   BASTION_INSTANCE_ID   EC2 instance ID of the bastion
#
# Optional:
#   MAX_LAG_WAIT_SEC   seconds to wait for lag=0 (default 300)
#   DB_PORT            MySQL port (default 3306)

set -euo pipefail

PROXY_ACTIVE="${PROXY_ACTIVE:-}"
OLD_CLUSTER_ID="${OLD_CLUSTER_ID:-}"
NEW_CLUSTER_ID="${NEW_CLUSTER_ID:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
DB_SECRET_NAME="${DB_SECRET_NAME:-}"
BASTION_INSTANCE_ID="${BASTION_INSTANCE_ID:-}"
MAX_LAG_WAIT_SEC="${MAX_LAG_WAIT_SEC:-300}"
DB_PORT="${DB_PORT:-3306}"

log() { echo "[pre_proxy_flip] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[[ -z "$PROXY_ACTIVE" ]]        && die "PROXY_ACTIVE is not set."
[[ -z "$OLD_CLUSTER_ID" ]]      && die "OLD_CLUSTER_ID is not set."
[[ -z "$NEW_CLUSTER_ID" ]]      && die "NEW_CLUSTER_ID is not set."
[[ -z "$DB_SECRET_NAME" ]]      && die "DB_SECRET_NAME is not set."
[[ -z "$BASTION_INSTANCE_ID" ]] && die "BASTION_INSTANCE_ID is not set."

# SOURCE = cluster being set read-only (currently active, receiving writes)
# TARGET = cluster being promoted (currently replica, we wait for its lag=0)
if [[ "$PROXY_ACTIVE" == "old" ]]; then
  SOURCE_CLUSTER="$NEW_CLUSTER_ID"
  TARGET_CLUSTER="$OLD_CLUSTER_ID"
  log "Pre-flight for rollback (proxy → old)"
  log "  Source (→ read-only): $SOURCE_CLUSTER"
  log "  Target (wait lag=0):  $TARGET_CLUSTER"
elif [[ "$PROXY_ACTIVE" == "new" ]]; then
  SOURCE_CLUSTER="$OLD_CLUSTER_ID"
  TARGET_CLUSTER="$NEW_CLUSTER_ID"
  log "Pre-flight for repromote (proxy → new)"
  log "  Source (→ read-only): $SOURCE_CLUSTER"
  log "  Target (wait lag=0):  $TARGET_CLUSTER"
else
  die "Unexpected PROXY_ACTIVE value: '$PROXY_ACTIVE' (expected 'new' or 'old')"
fi

log "  Bastion: $BASTION_INSTANCE_ID"

# ── Resolve endpoints ─────────────────────────────────────────────────────────
log "Resolving Aurora endpoints..."
SOURCE_ENDPOINT=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$SOURCE_CLUSTER" --region "$AWS_REGION" \
  --query 'DBClusters[0].Endpoint' --output text) || die "Failed to describe $SOURCE_CLUSTER"
TARGET_ENDPOINT=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$TARGET_CLUSTER" --region "$AWS_REGION" \
  --query 'DBClusters[0].Endpoint' --output text) || die "Failed to describe $TARGET_CLUSTER"

[[ -z "$SOURCE_ENDPOINT" || "$SOURCE_ENDPOINT" == "None" ]] && die "No endpoint for $SOURCE_CLUSTER"
[[ -z "$TARGET_ENDPOINT" || "$TARGET_ENDPOINT" == "None" ]] && die "No endpoint for $TARGET_CLUSTER"
log "  Source endpoint: $SOURCE_ENDPOINT"
log "  Target endpoint: $TARGET_ENDPOINT"

# ── Fetch credentials ─────────────────────────────────────────────────────────
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$DB_SECRET_NAME" --region "$AWS_REGION" \
  --query SecretString --output text) || die "Failed to fetch secret $DB_SECRET_NAME"

DB_USER=$(echo "$SECRET_JSON" | python3 -c "
import sys, json; d = json.load(sys.stdin)
print(d.get('username', d.get('user', 'admin')))
" 2>/dev/null) || DB_USER="admin"

DB_PASS=$(echo "$SECRET_JSON" | python3 -c "
import sys, json; d = json.load(sys.stdin)
print(d.get('password', d.get('masterpassword', next(iter(d.values())))))
" 2>/dev/null) || die "Could not parse password from secret"

[[ -z "$DB_PASS" ]] && die "Empty password from Secrets Manager"

# ── Build pre-flight script for bastion ──────────────────────────────────────
REMOTE_SCRIPT=$(cat <<SCRIPT
#!/bin/bash
set -euo pipefail

SOURCE_ENDPOINT='${SOURCE_ENDPOINT}'
TARGET_ENDPOINT='${TARGET_ENDPOINT}'
DB_PORT='${DB_PORT}'
DB_USER='${DB_USER}'
DB_PASS='${DB_PASS}'
MAX_LAG_WAIT_SEC='${MAX_LAG_WAIT_SEC}'
PROXY_ACTIVE='${PROXY_ACTIVE}'

mysql_exec() {
  local host="\$1"; shift
  mysql -h "\$host" -P "\$DB_PORT" -u "\$DB_USER" -p"\$DB_PASS" -sNe "\$@" 2>/dev/null
}
# mysql_status keeps column headers (no -N) so SHOW...STATUS\G output can be grepped by label
mysql_status() {
  local host="\$1"; shift
  mysql -h "\$host" -P "\$DB_PORT" -u "\$DB_USER" -p"\$DB_PASS" -se "\$@" 2>/dev/null
}

if ! command -v mysql &>/dev/null; then
  sudo dnf install -y mariadb105 2>/dev/null || \
  sudo yum install -y mariadb 2>/dev/null || \
  sudo apt-get install -y mysql-client 2>/dev/null || true
fi
command -v mysql &>/dev/null || { echo "[bastion] ERROR: mysql client not available"; exit 1; }

# For repromote: check if target is actually replicating before waiting
if [[ "\$PROXY_ACTIVE" == "new" ]]; then
  LAG_CHECK=\$(mysql_status "\$TARGET_ENDPOINT" "SHOW SLAVE STATUS\G" \
    | grep "Seconds_Behind_Master:" | awk '{print \$2}' || true)
  if [[ -z "\$LAG_CHECK" || "\$LAG_CHECK" == "NULL" ]]; then
    echo "[bastion] WARN: target (\$TARGET_ENDPOINT) is not replicating — skipping lag wait."
    echo "[bastion] TIP: run bg-03 enable-replication after rollback to set up replication for zero-lag repromote."
    echo "[bastion] Pre-flight complete (no replication active)."
    exit 0
  fi
fi

echo "[bastion] Setting source (\$SOURCE_ENDPOINT) to read-only..."
mysql_exec "\$SOURCE_ENDPOINT" "CALL mysql.rds_set_read_only();" || {
  echo "[bastion] ERROR: Failed to set read-only on source."
  exit 1
}
echo "[bastion] Source is read-only."

echo "[bastion] Polling replication lag on target (\$TARGET_ENDPOINT)..."
STARTED=\$(date +%s)
while true; do
  ELAPSED=\$(( \$(date +%s) - STARTED ))
  if (( ELAPSED >= MAX_LAG_WAIT_SEC )); then
    echo "[bastion] TIMEOUT: lag did not reach 0 within \${MAX_LAG_WAIT_SEC}s"
    echo "[bastion] Restoring source to read-write..."
    mysql_exec "\$SOURCE_ENDPOINT" "CALL mysql.rds_set_read_write();" 2>/dev/null || true
    exit 1
  fi
  LAG=\$(mysql_status "\$TARGET_ENDPOINT" "SHOW SLAVE STATUS\G" \
    | grep "Seconds_Behind_Master:" | awk '{print \$2}' || true)
  if [[ "\$LAG" == "0" ]]; then
    echo "[bastion] Replication lag = 0. Ready to flip proxy."
    exit 0
  fi
  echo "[bastion] Lag: \${LAG:-unknown}s (elapsed: \${ELAPSED}s) — waiting..."
  sleep 5
done
SCRIPT
)

# ── Send via SSM ──────────────────────────────────────────────────────────────
log "Sending pre-flight script to bastion via SSM..."
ENCODED=$(echo "$REMOTE_SCRIPT" | base64 | tr -d '\n')

CMD_ID=$(aws ssm send-command \
  --region "$AWS_REGION" \
  --instance-ids "$BASTION_INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[\"echo ${ENCODED} | base64 -d | bash\"]" \
  --timeout-seconds $((MAX_LAG_WAIT_SEC + 60)) \
  --output text \
  --query "Command.CommandId") || die "Failed to send SSM command"

log "SSM command sent: $CMD_ID — polling..."

while true; do
  RESULT=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" --instance-id "$BASTION_INSTANCE_ID" \
    --region "$AWS_REGION" --output json 2>/dev/null || echo '{"Status":"Pending"}')
  STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Status','Pending'))")
  case "$STATUS" in
    Success)
      echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('StandardOutputContent',''))" | sed 's/^/  /' >&2
      log "Pre-flight checks passed."
      exit 0 ;;
    Failed|Cancelled|TimedOut|DeliveryTimedOut|ExecutionTimedOut)
      echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('StandardOutputContent',''))" | sed 's/^/  [stdout] /' >&2
      echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('StandardErrorContent',''))" | sed 's/^/  [stderr] /' >&2
      die "Pre-flight failed (status=$STATUS)" ;;
    *) log "SSM status: $STATUS — waiting..."; sleep 5 ;;
  esac
done
