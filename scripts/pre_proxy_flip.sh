#!/usr/bin/env bash
# scripts/pre_proxy_flip.sh
#
# Phase 1 of the zero-data-loss proxy flip sequence.
# Runs on the TERRAFORM HOST — uses SSM to execute MySQL commands on the bastion.
# The bastion is in the VPC and has MySQL connectivity to Aurora.
#
# When proxy_active_cluster → "old" (rollback):
#   1. Resolve Aurora cluster endpoints (AWS API — no VPC needed)
#   2. Fetch DB password from Secrets Manager (AWS API)
#   3. Send MySQL script to bastion via SSM:
#      a. SET GLOBAL read_only = 1 on SOURCE (new prod)
#      b. Poll SHOW SLAVE STATUS on TARGET until Seconds_Behind_Master = 0
#   4. Poll SSM until success
#   5. On failure: sends restore script to set SOURCE back to read-write
#
# When proxy_active_cluster → "new" (re-promote): exits 0 immediately — no pre-check needed.
#
# Required env vars (set by null_resource.pre_proxy_flip in blue_green.tf):
#   PROXY_ACTIVE          "new" or "old"
#   OLD_CLUSTER_ID        old blue cluster identifier
#   NEW_CLUSTER_ID        current production cluster identifier
#   AWS_REGION
#   DB_SECRET_NAME        Secrets Manager secret name for master password
#   BASTION_INSTANCE_ID   EC2 instance ID of the bastion (must have SSM agent + AmazonSSMManagedInstanceCore)
#
# Optional:
#   MAX_LAG_WAIT_SEC   seconds to wait for lag=0 (default 300)
#   DB_PORT            MySQL port (default 3306)

set -euo pipefail

PROXY_ACTIVE="${PROXY_ACTIVE:-new}"
OLD_CLUSTER_ID="${OLD_CLUSTER_ID:-}"
NEW_CLUSTER_ID="${NEW_CLUSTER_ID:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
DB_SECRET_NAME="${DB_SECRET_NAME:-}"
BASTION_INSTANCE_ID="${BASTION_INSTANCE_ID:-}"
MAX_LAG_WAIT_SEC="${MAX_LAG_WAIT_SEC:-300}"
DB_PORT="${DB_PORT:-3306}"

log()  { echo "[pre_proxy_flip]  $*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

# ── No pre-check needed when flipping back to new ────────────────────────────
if [[ "$PROXY_ACTIVE" == "new" ]]; then
  log "Flipping proxy to new cluster — no pre-flight required. Exiting."
  exit 0
fi

# ── Validate inputs ───────────────────────────────────────────────────────────
[[ -z "$OLD_CLUSTER_ID" ]]        && die "OLD_CLUSTER_ID is not set. Has forward switchover completed?"
[[ -z "$NEW_CLUSTER_ID" ]]        && die "NEW_CLUSTER_ID is not set."
[[ -z "$DB_SECRET_NAME" ]]        && die "DB_SECRET_NAME is not set."
[[ -z "$BASTION_INSTANCE_ID" ]]   && die "BASTION_INSTANCE_ID is not set. Add it to terraform.tfvars."

log "Starting pre-proxy-flip checks for rollback (proxy → old)"
log "  Source (will go read-only): $NEW_CLUSTER_ID"
log "  Target (old blue, checking lag): $OLD_CLUSTER_ID"
log "  Bastion: $BASTION_INSTANCE_ID"

# ── Step 1: Resolve endpoints (AWS API — runs on Terraform host) ──────────────
log "Resolving Aurora endpoints via AWS API..."

SOURCE_ENDPOINT=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$NEW_CLUSTER_ID" \
  --region "$AWS_REGION" \
  --query 'DBClusters[0].Endpoint' \
  --output text) || die "Failed to describe source cluster $NEW_CLUSTER_ID"

TARGET_ENDPOINT=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$OLD_CLUSTER_ID" \
  --region "$AWS_REGION" \
  --query 'DBClusters[0].Endpoint' \
  --output text) || die "Failed to describe target cluster $OLD_CLUSTER_ID"

[[ -z "$SOURCE_ENDPOINT" || "$SOURCE_ENDPOINT" == "None" ]] && die "Could not resolve source endpoint for $NEW_CLUSTER_ID"
[[ -z "$TARGET_ENDPOINT" || "$TARGET_ENDPOINT" == "None" ]] && die "Could not resolve target endpoint for $OLD_CLUSTER_ID"

log "  Source endpoint: $SOURCE_ENDPOINT"
log "  Target endpoint: $TARGET_ENDPOINT"

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

# ── Step 3: Build the MySQL script to run on the bastion ─────────────────────
# Inject resolved values — bastion only needs MySQL client, not AWS access.
REMOTE_SCRIPT=$(cat <<SCRIPT
#!/bin/bash
set -euo pipefail

SOURCE_ENDPOINT='${SOURCE_ENDPOINT}'
TARGET_ENDPOINT='${TARGET_ENDPOINT}'
DB_PORT='${DB_PORT}'
DB_PASS='${DB_PASS}'
MAX_LAG_WAIT_SEC='${MAX_LAG_WAIT_SEC}'

mysql_exec() {
  local host="\$1"; shift
  mysql -h "\$host" -P "\$DB_PORT" -u admin -p"\$DB_PASS" --ssl-mode=REQUIRED -sNe "\$@" 2>/dev/null
}

# Install mysql client if missing (Amazon Linux 2023 ships mariadb105, not mysql)
if ! command -v mysql &>/dev/null; then
  sudo dnf install -y mariadb105 2>/dev/null || \
  sudo yum install -y mariadb 2>/dev/null || \
  sudo apt-get install -y mysql-client 2>/dev/null || true
fi
command -v mysql &>/dev/null || { echo "[bastion] ERROR: mysql client not available after install attempt"; exit 1; }

echo "[bastion] Setting source (\$SOURCE_ENDPOINT) to read-only..."
mysql_exec "\$SOURCE_ENDPOINT" "SET GLOBAL read_only = 1;" || {
  echo "[bastion] ERROR: Failed to set read_only=1 on source. Check MySQL connectivity."
  exit 1
}
echo "[bastion] Source is now read-only."

echo "[bastion] Polling replication lag on target (\$TARGET_ENDPOINT)..."
STARTED=\$(date +%s)
while true; do
  ELAPSED=\$(( \$(date +%s) - STARTED ))
  if (( ELAPSED >= MAX_LAG_WAIT_SEC )); then
    echo "[bastion] TIMEOUT: lag did not reach 0 within \${MAX_LAG_WAIT_SEC}s"
    echo "[bastion] Restoring source to read-write..."
    mysql_exec "\$SOURCE_ENDPOINT" "SET GLOBAL read_only = 0;" 2>/dev/null || true
    exit 1
  fi
  LAG=\$(mysql_exec "\$TARGET_ENDPOINT" "SHOW SLAVE STATUS\G" 2>/dev/null \
    | grep "Seconds_Behind_Master:" | awk '{print \$2}')
  if [[ "\$LAG" == "0" ]]; then
    echo "[bastion] Replication lag = 0. Ready for proxy flip."
    exit 0
  fi
  echo "[bastion] Lag: \${LAG:-unknown}s (elapsed: \${ELAPSED}s) — waiting..."
  sleep 5
done
SCRIPT
)

# ── Step 4: Base64-encode and send to bastion via SSM ────────────────────────
log "Sending script to bastion via SSM..."
ENCODED=$(echo "$REMOTE_SCRIPT" | base64 | tr -d '\n')

SSM_INPUT=$(python3 -c "
import json, sys
print(json.dumps({
  'InstanceIds': ['${BASTION_INSTANCE_ID}'],
  'DocumentName': 'AWS-RunShellScript',
  'Parameters': {'commands': ['echo ${ENCODED} | base64 -d | bash']},
  'TimeoutSeconds': $((MAX_LAG_WAIT_SEC + 60))
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
      log "Pre-proxy-flip checks passed."
      echo "$OUTPUT" | sed 's/^/  [bastion] /' >&2
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
