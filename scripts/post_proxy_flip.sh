#!/usr/bin/env bash
# scripts/post_proxy_flip.sh
#
# Promotes the newly active cluster to read-write after a proxy flip.
# Called as a GitHub Actions step — does NOT set up replication (see enable_replication.sh).
#
#   PROXY_ACTIVE=old → promote OLD blue cluster to read-write
#   PROXY_ACTIVE=new → promote NEW prod cluster to read-write
#
# Required env vars:
#   PROXY_ACTIVE          "new" or "old"
#   OLD_CLUSTER_ID        old blue cluster identifier
#   NEW_CLUSTER_ID        current production cluster identifier
#   AWS_REGION
#   DB_SECRET_NAME        Secrets Manager secret ARN for master credentials
#   BASTION_INSTANCE_ID   EC2 instance ID of the bastion

set -euo pipefail

PROXY_ACTIVE="${PROXY_ACTIVE:-new}"
OLD_CLUSTER_ID="${OLD_CLUSTER_ID:-}"
NEW_CLUSTER_ID="${NEW_CLUSTER_ID:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
DB_SECRET_NAME="${DB_SECRET_NAME:-}"
BASTION_INSTANCE_ID="${BASTION_INSTANCE_ID:-}"
DB_PORT="${DB_PORT:-3306}"

log() { echo "[post_proxy_flip] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[[ -z "$OLD_CLUSTER_ID" ]]      && die "OLD_CLUSTER_ID is not set."
[[ -z "$NEW_CLUSTER_ID" ]]      && die "NEW_CLUSTER_ID is not set."
[[ -z "$DB_SECRET_NAME" ]]      && die "DB_SECRET_NAME is not set."
[[ -z "$BASTION_INSTANCE_ID" ]] && die "BASTION_INSTANCE_ID is not set."

# Determine which cluster just became active
if [[ "$PROXY_ACTIVE" == "old" ]]; then
  ACTIVE_CLUSTER="$OLD_CLUSTER_ID"
  log "Proxy flipped to old blue — promoting $ACTIVE_CLUSTER to read-write"
elif [[ "$PROXY_ACTIVE" == "new" ]]; then
  ACTIVE_CLUSTER="$NEW_CLUSTER_ID"
  log "Proxy flipped to new prod — promoting $ACTIVE_CLUSTER to read-write"
else
  die "Unexpected PROXY_ACTIVE value: '$PROXY_ACTIVE'"
fi

log "  Bastion: $BASTION_INSTANCE_ID"

# ── Resolve endpoint ──────────────────────────────────────────────────────────
ACTIVE_ENDPOINT=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$ACTIVE_CLUSTER" \
  --region "$AWS_REGION" \
  --query 'DBClusters[0].Endpoint' \
  --output text) || die "Failed to describe cluster $ACTIVE_CLUSTER"

[[ -z "$ACTIVE_ENDPOINT" || "$ACTIVE_ENDPOINT" == "None" ]] && die "Could not resolve endpoint for $ACTIVE_CLUSTER"
log "  Endpoint: $ACTIVE_ENDPOINT"

# ── Fetch credentials ─────────────────────────────────────────────────────────
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$DB_SECRET_NAME" \
  --region "$AWS_REGION" \
  --query SecretString \
  --output text) || die "Failed to fetch secret $DB_SECRET_NAME"

DB_USER=$(echo "$SECRET_JSON" | python3 -c "
import sys, json; d = json.load(sys.stdin)
print(d.get('username', d.get('user', 'admin')))
" 2>/dev/null) || DB_USER="admin"

DB_PASS=$(echo "$SECRET_JSON" | python3 -c "
import sys, json; d = json.load(sys.stdin)
print(d.get('password', d.get('masterpassword', next(iter(d.values())))))
" 2>/dev/null) || die "Could not parse password from secret"

[[ -z "$DB_PASS" ]] && die "Empty password from Secrets Manager"

# ── Build promote script ──────────────────────────────────────────────────────
REMOTE_SCRIPT=$(cat <<SCRIPT
#!/bin/bash
set -euo pipefail

ENDPOINT='${ACTIVE_ENDPOINT}'
DB_PORT='${DB_PORT}'
DB_USER='${DB_USER}'
DB_PASS='${DB_PASS}'

mysql_exec() {
  mysql -h "\$ENDPOINT" -P "\$DB_PORT" -u "\$DB_USER" -p"\$DB_PASS" -sNe "\$@" 2>/dev/null
}

if ! command -v mysql &>/dev/null; then
  sudo dnf install -y mariadb105 2>/dev/null || \
  sudo yum install -y mariadb 2>/dev/null || \
  sudo apt-get install -y mysql-client 2>/dev/null || true
fi
command -v mysql &>/dev/null || { echo "[bastion] ERROR: mysql client not available"; exit 1; }

echo "[bastion] Stopping any replication on \$ENDPOINT..."
mysql_exec "CALL mysql.rds_stop_replication();" 2>/dev/null || true
mysql_exec "CALL mysql.rds_reset_external_master();" 2>/dev/null || true

echo "[bastion] Promoting to read-write..."
# Best-effort: Aurora writer instances are always read-write at the cluster level,
# so this may be a no-op. It works on plain RDS MySQL.
mysql -h "\$ENDPOINT" -P "\$DB_PORT" -u "\$DB_USER" -p"\$DB_PASS" \
  -sNe "SET GLOBAL read_only = 0;" 2>/dev/null || true

RO=\$(mysql_exec "SELECT @@global.read_only;" 2>/dev/null || echo "0")
if [[ "\$RO" == "1" ]]; then
  echo "[bastion] WARN: read_only=1 is still set — Aurora writer should still accept writes via the cluster endpoint."
fi
echo "[bastion] Cluster promoted (read_only=\$RO). Done."
SCRIPT
)

# ── Send via SSM ──────────────────────────────────────────────────────────────
log "Sending promote script to bastion via SSM..."
ENCODED=$(echo "$REMOTE_SCRIPT" | base64 | tr -d '\n')

CMD_ID=$(aws ssm send-command \
  --region "$AWS_REGION" \
  --instance-ids "$BASTION_INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[\"echo ${ENCODED} | base64 -d | bash\"]" \
  --timeout-seconds 120 \
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
      log "Promotion complete."
      exit 0 ;;
    Failed|Cancelled|TimedOut|DeliveryTimedOut|ExecutionTimedOut)
      echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('StandardOutputContent',''))" | sed 's/^/  [stdout] /' >&2
      echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('StandardErrorContent',''))" | sed 's/^/  [stderr] /' >&2
      die "Bastion script failed (status=$STATUS)" ;;
    *) log "SSM status: $STATUS — waiting..."; sleep 5 ;;
  esac
done
