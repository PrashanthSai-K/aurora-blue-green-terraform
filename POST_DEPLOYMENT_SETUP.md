# Post-Deployment Setup Guide

After running `terraform apply`, follow these steps to complete the setup.

## Step 1: Wait for Aurora to Be Ready

Aurora clusters take 10-15 minutes to become available. Monitor progress:

```bash
# Check cluster status
aws rds describe-db-clusters \
  --db-cluster-identifier aurora-readonly-db \
  --query 'DBClusters[0].Status' \
  --output text

# Wait until status is "available"
```

Or in AWS Console:
1. Go to **RDS** → **Databases**
2. Find `aurora-readonly-db-instance-1` and `aurora-readonly-db-instance-2`
3. Wait for both to show **Available** status

## Step 2: Download RDS CA Certificate

Required for SSL/TLS connections:

```bash
# Create directory for certs
mkdir -p ~/.mysql/certs

# Download RDS CA bundle
curl https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
  -o ~/.mysql/certs/rds-ca-bundle.pem

chmod 400 ~/.mysql/certs/rds-ca-bundle.pem
```

## Step 3: Create Database and Read-Only User

### Get Connection Details

```bash
# Retrieve endpoints and credentials
CLUSTER_ENDPOINT=$(terraform output -raw aurora_cluster_endpoint)
MASTER_USER=$(terraform output -raw aurora_master_username)

echo "Cluster Endpoint: $CLUSTER_ENDPOINT"
echo "Master User: $MASTER_USER"
```

### Option A: Interactive Connection

```bash
# The password is stored in Secrets Manager
# Option 1: Get it from Secrets Manager
aws secretsmanager get-secret-value \
  --secret-id aurora-okta-aurora-credentials \
  --query 'SecretString' \
  --output text | jq -r '.password'

# Option 2: Connect and it will prompt for password
mysql -h $CLUSTER_ENDPOINT \
  -u $MASTER_USER \
  --ssl-ca=~/.mysql/certs/rds-ca-bundle.pem \
  --ssl-mode=VERIFY_IDENTITY \
  -p
```

### Option B: Non-Interactive with Stored Credentials

```bash
# Create ~/.mysql/credentials.conf with master password
cat > ~/.mysql/credentials.conf << 'EOF'
[client]
user=admin
password=YOUR_MASTER_PASSWORD_HERE
host=YOUR_CLUSTER_ENDPOINT_HERE
ssl-ca=/Users/YOUR_USER/.mysql/certs/rds-ca-bundle.pem
ssl-mode=VERIFY_IDENTITY
EOF

chmod 400 ~/.mysql/credentials.conf

# Then connect
mysql --defaults-file=~/.mysql/credentials.conf
```

### Create IAM-Authenticated Read-Only User

Once connected to Aurora, run:

```sql
-- Create read-only user with IAM authentication
CREATE USER 'readonly_user' IDENTIFIED WITH AWSAuthenticationPlugin AS 'RDS';

-- Grant read-only permissions on all databases
GRANT SELECT, SHOW VIEW ON appdb.* TO 'readonly_user'@'%';

-- Grant information_schema access (needed by MySQL tools)
GRANT SELECT ON information_schema.* TO 'readonly_user'@'%';

-- Grant performance_schema access (optional, for monitoring)
GRANT SELECT ON performance_schema.* TO 'readonly_user'@'%';

-- Apply changes
FLUSH PRIVILEGES;

-- Verify user was created
SELECT User, Host, authentication_string FROM mysql.user WHERE User='readonly_user';
```

### Create Sample Database Content (Optional)

```sql
-- Create tables in appdb
USE appdb;

CREATE TABLE users (
  id INT AUTO_INCREMENT PRIMARY KEY,
  email VARCHAR(255) NOT NULL UNIQUE,
  name VARCHAR(255),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE products (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  price DECIMAL(10, 2),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert sample data
INSERT INTO users (email, name) VALUES 
  ('alice@example.com', 'Alice'),
  ('bob@example.com', 'Bob');

INSERT INTO products (name, price) VALUES 
  ('Widget', 9.99),
  ('Gadget', 19.99);

-- Verify
SELECT COUNT(*) as user_count FROM users;
SELECT COUNT(*) as product_count FROM products;
```

## Step 4: Verify IAM Authentication Works

### Generate Auth Token

```bash
# Get connection details
CLUSTER_ENDPOINT=$(terraform output -raw aurora_cluster_endpoint)
AWS_REGION="us-east-1"  # Change if different

# Generate authentication token (valid for 15 minutes)
AUTH_TOKEN=$(aws rds-db auth-token \
  --hostname $CLUSTER_ENDPOINT \
  --port 3306 \
  --region $AWS_REGION \
  --username readonly_user)

echo "Auth token generated (truncated): ${AUTH_TOKEN:0:50}..."
```

### Test Connection with Auth Token

```bash
# Using auth token instead of password
mysql -h $CLUSTER_ENDPOINT \
  -P 3306 \
  -u readonly_user \
  --ssl-ca=~/.mysql/certs/rds-ca-bundle.pem \
  --ssl-mode=VERIFY_IDENTITY \
  -p"$AUTH_TOKEN" \
  -e "SELECT 'IAM Authentication Successful!' as status;"
```

Expected output:
```
+----------------------------------+
| status                           |
+----------------------------------+
| IAM Authentication Successful!   |
+----------------------------------+
```

## Step 5: Test RDS Proxy Connection (If Enabled)

### Get RDS Proxy Endpoint

```bash
PROXY_ENDPOINT=$(terraform output -raw rds_proxy_endpoint)

# Verify proxy is available
aws rds describe-db-proxies \
  --db-proxy-name aurora-okta-proxy \
  --query 'DBProxies[0].Status' \
  --output text
```

### Connect Through RDS Proxy

```bash
# Generate token for proxy
PROXY_TOKEN=$(aws rds-db auth-token \
  --hostname $PROXY_ENDPOINT \
  --port 3306 \
  --region $AWS_REGION \
  --username readonly_user)

# Connect
mysql -h $PROXY_ENDPOINT \
  -P 3306 \
  -u readonly_user \
  --ssl-ca=~/.mysql/certs/rds-ca-bundle.pem \
  --ssl-mode=VERIFY_IDENTITY \
  -p"$PROXY_TOKEN" \
  -e "SELECT 'RDS Proxy Connection Successful!' as status;"
```

## Step 6: Configure Okta Application

### Access Okta SAML App Configuration

1. Log in to **Okta Admin Console**
2. Go to **Applications** → **Applications**
3. Find **okta-aurora-app** (created by Terraform)
4. Note the **Metadata URL** (you'll need it later)

### Verify SAML Attributes

1. In the Okta app, go to **Sign On** tab
2. Under **SAML Settings**, click **View SAML Setup Instructions**
3. Verify these attributes are set:
   - `https://aws.amazon.com/SAML/Attributes/RoleSessionName` → `user.email`
   - `https://aws.amazon.com/SAML/Attributes/Role` → `arn:aws:iam::ACCOUNT:role/aurora-readonly-role,arn:aws:iam::ACCOUNT:saml-provider/aurora-okta-okta-provider`

### Add Users to Okta Group

1. Go to **Directory** → **Groups**
2. Find **aurora-readonly-users**
3. Click **Add Members**
4. Select users who should have Aurora access
5. Click **Save**

## Step 7: Test Okta SAML Flow

### Login to AWS with Okta

1. Go to **Okta Admin Console** or user portal
2. Find **okta-aurora-app** application tile
3. Click it (this triggers SAML login to AWS)
4. You'll be redirected to AWS console with assumed role session

### Verify Role Assumption

In AWS Console:
1. Click your username (top right)
2. Verify it shows `aurora-readonly-role` as the active role
3. The session name should be your Okta email

Or via CLI:

```bash
# Verify current credentials
aws sts get-caller-identity

# Should output:
# {
#     "UserId": "AIDAI...:user@example.com",
#     "Account": "123456789012",
#     "Arn": "arn:aws:iam::123456789012:role/aurora-readonly-role/user@example.com"
# }
```

## Step 8: Test Full SAML + Aurora Flow

### Complete User Journey

1. **Okta Login**:
   ```
   Open: https://your-okta-org.okta.com
   Login with your Okta credentials
   ```

2. **Assume Role**:
   ```
   Click okta-aurora-app SAML application
   You're redirected to AWS STS
   AWS grants you temporary credentials for aurora-readonly-role
   ```

3. **Connect to Aurora**:
   ```bash
   # With temporary credentials from Okta SAML active:
   
   ENDPOINT=$(terraform output -raw aurora_cluster_endpoint)
   
   TOKEN=$(aws rds-db auth-token \
     --hostname $ENDPOINT \
     --port 3306 \
     --region us-east-1 \
     --username readonly_user)
   
   mysql -h $ENDPOINT \
     -u readonly_user \
     --ssl-ca=~/.mysql/certs/rds-ca-bundle.pem \
     --ssl-mode=VERIFY_IDENTITY \
     -p"$TOKEN" \
     appdb
   ```

4. **Verify Read-Only Access**:
   ```sql
   -- These should work
   SELECT * FROM users;
   SELECT * FROM products;
   
   -- This should fail (read-only user)
   DELETE FROM users WHERE id = 1;
   -- Error: User 'readonly_user' does not have permission...
   ```

## Step 9: Set Up Monitoring & Logging

### Enable CloudWatch Dashboards

```bash
# View Aurora metrics
aws cloudwatch list-metrics \
  --namespace AWS/RDS \
  --metric-name DatabaseConnections \
  --dimensions Name=DBClusterIdentifier,Value=aurora-readonly-db
```

### Create CloudWatch Alarm

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name aurora-high-cpu \
  --alarm-description "Alert when Aurora CPU is high" \
  --metric-name CPUUtilization \
  --namespace AWS/RDS \
  --statistic Average \
  --period 300 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 2 \
  --dimensions Name=DBClusterIdentifier,Value=aurora-readonly-db
```

### View Database Logs

```bash
# Slow query log
aws logs tail /aws/rds/cluster/aurora-readonly-db/slowquery --follow

# Error log
aws logs tail /aws/rds/cluster/aurora-readonly-db/error --follow

# General log (if enabled)
aws logs tail /aws/rds/cluster/aurora-readonly-db/general --follow
```

## Step 10: Documentation & Access Control

### Document Your Setup

Create a shared document with your team:

```markdown
## Aurora Database Access via Okta

### How to Connect
1. Log in to Okta
2. Click okta-aurora-app
3. Assume aurora-readonly-role
4. Generate auth token:
   ```
   aws rds-db auth-token \
     --hostname aurora-readonly-db.xxx.us-east-1.rds.amazonaws.com \
     --port 3306 \
     --region us-east-1 \
     --username readonly_user
   ```
5. Connect with auth token

### Permissions
- SELECT queries allowed
- INSERT/UPDATE/DELETE not allowed
- Can query information_schema and performance_schema

### Support
Contact: DevOps team
Documentation: [link]
```

### Grant Access to Users

```bash
# Add user to Okta group (in Okta Admin Console)
# User automatically gets Aurora access via SAML role
```

## Troubleshooting Checklist

- [ ] Aurora cluster shows "Available" status
- [ ] RDS CA certificate downloaded
- [ ] Master user created in Aurora
- [ ] readonly_user created with IAM auth
- [ ] Okta SAML app configured with correct attributes
- [ ] Users added to aurora-readonly-users group in Okta
- [ ] Can generate auth token for readonly_user
- [ ] Can connect with auth token (IAM auth)
- [ ] Can connect through RDS Proxy
- [ ] SAML login to okta-aurora-app works
- [ ] Can query databases after SAML login

## Security Checklist

- [ ] Master password stored securely (Secrets Manager)
- [ ] Database encryption enabled (KMS)
- [ ] RDS Proxy uses TLS
- [ ] Security groups restrict access
- [ ] IAM policies follow least privilege
- [ ] Okta MFA enforced for users
- [ ] CloudWatch logs enabled for audit trail
- [ ] Backup retention configured
- [ ] No hardcoded credentials in code/configs
- [ ] Regular key rotation configured

## Performance Testing

### Test Connection Speed

```bash
# Time 100 connections
time for i in {1..100}; do
  mysql -h $ENDPOINT \
    -u readonly_user \
    --ssl-ca=~/.mysql/certs/rds-ca-bundle.pem \
    -p"$AUTH_TOKEN" \
    -e "SELECT 1;" 2>/dev/null
done
```

### Test Query Performance

```sql
-- With RDS Proxy
mysql -h rds-proxy-endpoint ...
SELECT * FROM users WHERE id = 1;  -- Should be fast

-- Check connections
SHOW PROCESSLIST;
SHOW STATUS LIKE 'Threads%';
```

## Next Steps

1. Set up automated backups (already configured via Terraform)
2. Configure CloudWatch alarms for monitoring
3. Set up database access audit logging
4. Document custom parameter groups
5. Plan capacity for growth
6. Set up disaster recovery procedures
7. Train team on Okta SAML Aurora access flow
