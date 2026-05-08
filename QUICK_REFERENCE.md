# Quick Reference Guide

## Common Commands

### Terraform Commands

```bash
# Initialize Terraform
terraform init

# Format code
terraform fmt -recursive

# Validate configuration
terraform validate

# Plan changes
terraform plan -out=tfplan

# Apply changes
terraform apply tfplan

# Destroy resources
terraform destroy

# Get specific output
terraform output aurora_cluster_endpoint

# Get all outputs
terraform output -json
```

### Get Connection Details

```bash
# Get Aurora endpoint
terraform output -raw aurora_cluster_endpoint

# Get RDS Proxy endpoint (if enabled)
terraform output -raw rds_proxy_endpoint

# Get IAM role ARN
terraform output -raw aurora_readonly_role_arn

# Get Okta app ID
terraform output -raw okta_app_id
```

### AWS CLI Commands

```bash
# Check Aurora cluster status
aws rds describe-db-clusters \
  --db-cluster-identifier aurora-readonly-db \
  --query 'DBClusters[0].[Status,Endpoint,ReaderEndpoint]' \
  --output table

# List Aurora instances
aws rds describe-db-instances \
  --filters "Name=db-cluster-id,Values=aurora-readonly-db" \
  --query 'DBInstances[*].[DBInstanceIdentifier,DBInstanceStatus]' \
  --output table

# Check RDS Proxy status
aws rds describe-db-proxies \
  --db-proxy-name aurora-okta-proxy \
  --query 'DBProxies[0].[DBProxyName,Status]' \
  --output table

# Get master password from Secrets Manager
aws secretsmanager get-secret-value \
  --secret-id aurora-okta-aurora-credentials \
  --query 'SecretString' \
  --output text | jq -r '.password'
```

### MySQL/Database Commands

```bash
# Connect to Aurora directly
mysql -h aurora-readonly-db.xxx.us-east-1.rds.amazonaws.com \
  -u admin \
  --ssl-ca=~/.mysql/certs/rds-ca-bundle.pem \
  --ssl-mode=VERIFY_IDENTITY \
  -p

# Connect with readonly user (non-IAM)
mysql -h aurora-readonly-db.xxx.us-east-1.rds.amazonaws.com \
  -u readonly_user \
  --ssl-ca=~/.mysql/certs/rds-ca-bundle.pem \
  --ssl-mode=VERIFY_IDENTITY \
  -p'<auth_token>'

# Run SQL from file
mysql -h endpoint -u user -p < script.sql

# Execute single query
mysql -h endpoint -u user -p -e "SELECT VERSION();"

# Check version
mysql -h endpoint -u user -p -e "SELECT @@version;"

# List users
mysql -h endpoint -u user -p -e "SELECT User, Host FROM mysql.user;"

# Check user privileges
mysql -h endpoint -u user -p -e "SHOW GRANTS FOR 'readonly_user'@'%';"

# View slow query log
mysql -h endpoint -u user -p -e "SELECT * FROM mysql.slow_log \G"
```

### IAM Authentication

```bash
# Generate auth token
aws rds-db auth-token \
  --hostname aurora-readonly-db.xxx.us-east-1.rds.amazonaws.com \
  --port 3306 \
  --region us-east-1 \
  --username readonly_user

# Store in variable (token valid for 15 minutes)
TOKEN=$(aws rds-db auth-token \
  --hostname aurora-readonly-db.xxx.us-east-1.rds.amazonaws.com \
  --port 3306 \
  --region us-east-1 \
  --username readonly_user)

echo $TOKEN

# Check IAM role permissions
aws iam get-role-policy \
  --role-name aurora-readonly-role \
  --policy-name aurora-readonly-policy \
  --query 'RolePolicyDetail.PolicyDocument'

# List all policies attached to role
aws iam list-attached-role-policies \
  --role-name aurora-readonly-role

# Verify current identity
aws sts get-caller-identity

# Assume role with STS
aws sts assume-role \
  --role-arn arn:aws:iam::123456789012:role/aurora-readonly-role \
  --role-session-name my-session
```

### Okta Commands

```bash
# List all Okta apps (via API)
curl -X GET https://your-okta-org.okta.com/api/v1/apps \
  -H "Authorization: Bearer YOUR_API_TOKEN"

# Get specific app details
curl -X GET https://your-okta-org.okta.com/api/v1/apps/YOUR_APP_ID \
  -H "Authorization: Bearer YOUR_API_TOKEN"

# List Okta groups
curl -X GET https://your-okta-org.okta.com/api/v1/groups \
  -H "Authorization: Bearer YOUR_API_TOKEN"

# Add user to group
curl -X PUT https://your-okta-org.okta.com/api/v1/groups/GROUP_ID/users/USER_ID \
  -H "Authorization: Bearer YOUR_API_TOKEN"
```

### CloudWatch Logs

```bash
# List all log groups
aws logs describe-log-groups --query 'logGroups[*].logGroupName' --output table

# View Aurora error logs
aws logs tail /aws/rds/cluster/aurora-readonly-db/error --follow

# View slow query logs
aws logs tail /aws/rds/cluster/aurora-readonly-db/slowquery --follow

# View audit logs (if enabled)
aws logs tail /aws/rds/cluster/aurora-readonly-db/audit --follow

# Search for specific query in logs
aws logs filter-log-events \
  --log-group-name /aws/rds/cluster/aurora-readonly-db/slowquery \
  --filter-pattern "SELECT" \
  --query 'events[*].message'
```

### Security Group Management

```bash
# Get Aurora security group ID
AURORA_SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=aurora-okta-aurora-sg" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

echo $AURORA_SG

# View inbound rules
aws ec2 describe-security-groups \
  --group-ids $AURORA_SG \
  --query 'SecurityGroups[0].IpPermissions' \
  --output table

# View outbound rules
aws ec2 describe-security-groups \
  --group-ids $AURORA_SG \
  --query 'SecurityGroups[0].IpPermissionsEgress' \
  --output table

# Add inbound rule (for example, from IP)
aws ec2 authorize-security-group-ingress \
  --group-id $AURORA_SG \
  --protocol tcp \
  --port 3306 \
  --cidr 10.0.0.0/8
```

### Performance Monitoring

```bash
# Get Aurora metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name DatabaseConnections \
  --dimensions Name=DBClusterIdentifier,Value=aurora-readonly-db \
  --start-time 2024-01-01T00:00:00Z \
  --end-time 2024-01-02T00:00:00Z \
  --period 300 \
  --statistics Average,Maximum,Minimum

# CPU utilization
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name CPUUtilization \
  --dimensions Name=DBClusterIdentifier,Value=aurora-readonly-db \
  --start-time 2024-01-01T00:00:00Z \
  --end-time 2024-01-02T00:00:00Z \
  --period 300 \
  --statistics Average,Maximum

# Replication lag (for reader instances)
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name AuroraBinlogReplicaLag \
  --dimensions Name=DBClusterIdentifier,Value=aurora-readonly-db \
  --start-time 2024-01-01T00:00:00Z \
  --end-time 2024-01-02T00:00:00Z \
  --period 300 \
  --statistics Average
```

### Backup Management

```bash
# List backups
aws rds describe-db-cluster-snapshots \
  --db-cluster-identifier aurora-readonly-db \
  --query 'DBClusterSnapshots[*].[DBClusterSnapshotIdentifier,SnapshotCreateTime,Status]' \
  --output table

# Create manual snapshot
aws rds create-db-cluster-snapshot \
  --db-cluster-snapshot-identifier aurora-readonly-db-manual-backup-$(date +%Y%m%d-%H%M%S) \
  --db-cluster-identifier aurora-readonly-db

# Restore from snapshot
aws rds restore-db-cluster-from-snapshot \
  --db-cluster-identifier aurora-readonly-db-restored \
  --snapshot-identifier aurora-readonly-db-manual-backup-20240101-120000 \
  --engine aurora-mysql

# Delete snapshot
aws rds delete-db-cluster-snapshot \
  --db-cluster-snapshot-identifier aurora-readonly-db-manual-backup-20240101-120000
```

## File Paths

```bash
# RDS CA Certificate
~/.mysql/certs/rds-ca-bundle.pem

# MySQL credentials
~/.mysql/credentials.conf

# Terraform files location
./aurora-okta-terraform/

# Terraform state
./aurora-okta-terraform/terraform.tfstate

# Terraform variables
./aurora-okta-terraform/terraform.tfvars
```

## Port Information

| Service | Port | Protocol | Notes |
|---------|------|----------|-------|
| Aurora MySQL | 3306 | TCP | Direct database connection |
| RDS Proxy | 3306 | TCP | Connection pooling |
| Okta SAML | 443 | HTTPS | Web-based authentication |
| AWS STS | 443 | HTTPS | Token service |

## Important Environment Variables

```bash
# Set these for easier command usage
export AWS_REGION="us-east-1"
export AURORA_ENDPOINT="aurora-readonly-db.xxx.us-east-1.rds.amazonaws.com"
export PROXY_ENDPOINT="aurora-okta-proxy.proxy-xxx.us-east-1.rds.amazonaws.com"
export DB_USER="readonly_user"
export DB_PORT="3306"
export DB_NAME="appdb"

# Use in commands
mysql -h $AURORA_ENDPOINT -u $DB_USER --ssl-ca=~/.mysql/certs/rds-ca-bundle.pem -p"$TOKEN"
```

## Useful Aliases

Add to `~/.bashrc` or `~/.zshrc`:

```bash
# Aurora connection
alias aurora-connect='mysql -h $(terraform output -raw aurora_cluster_endpoint) -u admin --ssl-ca=~/.mysql/certs/rds-ca-bundle.pem --ssl-mode=VERIFY_IDENTITY -p'

# RDS Proxy connection
alias proxy-connect='TOKEN=$(aws rds-db auth-token --hostname $(terraform output -raw rds_proxy_endpoint) --port 3306 --region us-east-1 --username readonly_user) && mysql -h $(terraform output -raw rds_proxy_endpoint) -u readonly_user --ssl-ca=~/.mysql/certs/rds-ca-bundle.pem --ssl-mode=VERIFY_IDENTITY -p"$TOKEN"'

# Generate token
alias get-db-token='aws rds-db auth-token --hostname $(terraform output -raw aurora_cluster_endpoint) --port 3306 --region us-east-1 --username readonly_user'

# Check cluster status
alias check-aurora='aws rds describe-db-clusters --db-cluster-identifier aurora-readonly-db --query "DBClusters[0].Status" --output text'

# Get Terraform outputs
alias tf-outputs='terraform output -json | jq'
```

## Common Errors & Solutions

| Error | Cause | Solution |
|-------|-------|----------|
| `Access denied for user` | Wrong password or token expired | Regenerate auth token, verify permissions |
| `SSL: CERTIFICATE_VERIFY_FAILED` | Missing or wrong CA cert | Download RDS CA bundle, check path |
| `Host is not allowed to connect` | Security group blocks traffic | Add inbound rule for your IP/CIDR |
| `SAML Assertion is Invalid` | Clock skew or wrong assertion | Check system time, verify SAML config |
| `Role ARN not found` | IAM role doesn't exist or wrong ARN | Verify role name in terraform.tfvars |
| `Proxy unavailable` | Proxy target group not ready | Wait for RDS Proxy to reach "Available" status |
| `Cannot assume role` | SAML principal not in trust policy | Verify Okta SAML provider ARN in role |

## Useful Queries

### Database Information

```sql
-- Show all databases
SHOW DATABASES;

-- Show current database
SELECT DATABASE();

-- Show all tables in current database
SHOW TABLES;

-- Show table schema
DESCRIBE users;
SHOW CREATE TABLE users\G

-- Show storage engine
SHOW ENGINES;

-- Show variables
SHOW VARIABLES LIKE 'character%';

-- Current connections
SHOW PROCESSLIST;

-- Binary log status
SHOW BINARY LOGS;

-- Show master status
SHOW MASTER STATUS;
```

### User Management

```sql
-- Show all users
SELECT User, Host, authentication_string FROM mysql.user;

-- Show current user
SELECT CURRENT_USER();

-- Show user privileges
SHOW GRANTS FOR 'readonly_user'@'%';

-- Show all users with IAM auth
SELECT User, Host, plugin FROM mysql.user WHERE plugin='mysql_native_password' OR plugin='AWSAuthenticationPlugin';

-- Create user with IAM auth
CREATE USER 'newuser' IDENTIFIED WITH AWSAuthenticationPlugin AS 'RDS';

-- Grant permissions
GRANT SELECT ON database.* TO 'readonly_user'@'%';

-- Revoke permissions
REVOKE ALL ON database.* FROM 'readonly_user'@'%';

-- Drop user
DROP USER 'readonly_user'@'%';

-- Flush privileges
FLUSH PRIVILEGES;
```

### Performance Analysis

```sql
-- Slow query log status
SHOW VARIABLES LIKE 'slow_query%';

-- Query execution statistics
SHOW STATUS LIKE 'Slow_queries';

-- Table sizes
SELECT table_schema, table_name, round(((data_length + index_length) / 1024 / 1024), 2) AS 'Size (MB)' 
FROM information_schema.tables 
WHERE table_schema != 'information_schema';

-- Long-running queries
SELECT id, user, host, command, time, state, info 
FROM information_schema.processlist 
WHERE time > 60 ORDER BY time DESC;

-- Connection count
SHOW STATUS LIKE 'Threads_connected';

-- Query cache stats
SHOW STATUS LIKE 'Qcache%';
```

## Disaster Recovery

```bash
# List all snapshots
aws rds describe-db-cluster-snapshots \
  --query 'DBClusterSnapshots[*].[DBClusterSnapshotIdentifier,SnapshotCreateTime]' \
  --output table

# Create backup before major change
aws rds create-db-cluster-snapshot \
  --db-cluster-snapshot-identifier aurora-readonly-db-backup-$(date +%s) \
  --db-cluster-identifier aurora-readonly-db

# Restore from backup to new cluster
aws rds restore-db-cluster-from-snapshot \
  --db-cluster-identifier aurora-readonly-db-restored \
  --snapshot-identifier aurora-readonly-db-backup-TIMESTAMP \
  --engine aurora-mysql

# Delete original cluster (after verifying restored cluster)
aws rds delete-db-cluster \
  --db-cluster-identifier aurora-readonly-db \
  --skip-final-snapshot
```
