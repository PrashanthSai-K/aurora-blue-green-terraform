# Aurora MySQL with Okta SAML and IAM Authentication

This Terraform configuration creates a complete setup for Aurora MySQL with Okta SAML-based authentication and IAM roles. Users log in through Okta and assume an IAM role to connect to the Aurora database.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    Okta IdP                              │
│         (SAML Authentication Provider)                   │
└──────────────────┬──────────────────────────────────────┘
                   │
                   │ SAML Assertion
                   ▼
┌─────────────────────────────────────────────────────────┐
│              AWS STS (Security Token Service)            │
│    - Validates SAML assertion                            │
│    - Issues temporary credentials                        │
│    - Assumes IAM Role                                    │
└──────────────────┬──────────────────────────────────────┘
                   │
                   │ Temporary Credentials
                   ▼
┌─────────────────────────────────────────────────────────┐
│          RDS Proxy (Optional)                            │
│  - Connection pooling                                    │
│  - IAM authentication                                    │
│  - Enhanced security                                     │
└──────────────────┬──────────────────────────────────────┘
                   │
                   │ IAM Authenticated Connection
                   ▼
┌─────────────────────────────────────────────────────────┐
│        Aurora MySQL Cluster (Private)                    │
│  - Read-only user with IAM auth                          │
│  - Encrypted storage                                     │
│  - Multi-AZ deployment                                   │
│  - Enhanced monitoring                                   │
└─────────────────────────────────────────────────────────┘
```

## Components Created

### Infrastructure
- **VPC**: Custom VPC with public and private subnets across 2 AZs
- **Security Groups**: Restricted inbound/outbound for Aurora and RDS Proxy
- **NAT Gateway**: For private subnet internet access
- **DB Subnet Group**: For Aurora deployment

### Database
- **Aurora MySQL Cluster**: Multi-AZ deployment with 2 instances
- **Parameter Groups**: Customized for performance and logging
- **Read-only IAM User**: Database user authenticated via IAM
- **Enhanced Monitoring**: CloudWatch metrics and logs
- **Encryption**: KMS-encrypted storage and backups

### Authentication & Authorization
- **Okta SAML App**: AWS SAML application in Okta
- **Okta Group**: For managing user access
- **AWS SAML Provider**: Identity provider configuration
- **IAM Role**: Assumable via Okta SAML with read-only Aurora access
- **IAM Policies**: Granular permissions for RDS and RDS Proxy access

### Connection Management
- **RDS Proxy**: Connection pooling with IAM authentication (optional)
- **Secrets Manager**: Stores Aurora master credentials
- **KMS Keys**: Encryption for database and secrets

## Prerequisites

### Required
1. **AWS Account** with appropriate permissions (EC2, RDS, IAM, Secrets Manager, KMS)
2. **Okta Organization** with admin access
3. **Terraform** >= 1.0
4. **AWS CLI** configured with credentials
5. **MySQL Client** (for testing connections)

### Okta Setup
1. Create an Okta organization or use existing one
2. Get Okta organization name (subdomain) and base URL
3. Generate an Okta API token for Terraform

## Quick Start

### Step 1: Prepare Okta API Token

1. Log in to your Okta Admin Console
2. Navigate to **Security** → **API** → **Tokens**
3. Click **Create Token**
4. Give it a name (e.g., "Terraform")
5. Copy the token value (save it securely)

### Step 2: Configure Terraform Variables

```bash
# Copy the example file
cp terraform.tfvars.example terraform.tfvars

# Edit with your values
nano terraform.tfvars
```

Update the following in `terraform.tfvars`:
- `okta_org_name`: Your Okta subdomain (e.g., "dev-12345678")
- `okta_base_url`: Your Okta URL (e.g., "https://dev-12345678.okta.com")
- `okta_api_token`: The API token you generated
- `aws_region`: Your preferred AWS region
- Other variables as needed

### Step 3: Initialize Terraform

```bash
terraform init
```

### Step 4: Review Plan

```bash
terraform plan
```

This shows all resources that will be created. Review for any issues.

### Step 5: Apply Configuration

```bash
terraform apply
```

This will:
1. Create VPC and networking
2. Create Aurora cluster (takes ~10-15 minutes)
3. Create RDS Proxy
4. Configure Okta SAML app
5. Set up IAM roles and policies

### Step 6: Create Database Read-Only User

After Terraform completes, you need to create the read-only user in Aurora:

```bash
# Get the endpoint and master password from Terraform outputs
ENDPOINT=$(terraform output -raw aurora_cluster_endpoint)
MASTER_USER=$(terraform output -raw aurora_master_username)

# Connect to Aurora (you'll be prompted for password)
mysql -h $ENDPOINT -u $MASTER_USER -p

# Run these SQL commands:
CREATE USER 'readonly_user' IDENTIFIED WITH AWSAuthenticationPlugin AS 'RDS';
GRANT SELECT, SHOW VIEW, EXECUTE ON appdb.* TO 'readonly_user'@'%';
GRANT SELECT ON information_schema.* TO 'readonly_user'@'%';
FLUSH PRIVILEGES;
```

Or save the SQL and run:
```bash
cat > setup_db.sql << 'EOF'
CREATE USER 'readonly_user' IDENTIFIED WITH AWSAuthenticationPlugin AS 'RDS';
GRANT SELECT, SHOW VIEW, EXECUTE ON appdb.* TO 'readonly_user'@'%';
GRANT SELECT ON information_schema.* TO 'readonly_user'@'%';
FLUSH PRIVILEGES;
EOF

mysql -h $ENDPOINT -u $MASTER_USER -p < setup_db.sql
```

## Authentication Flow

### 1. Login to Okta
1. Navigate to https://your-okta-org.okta.com
2. Click the "okta-aurora-app" SAML application

### 2. Assume IAM Role
The Okta app automatically triggers SAML flow:
- Okta validates your identity
- Issues SAML assertion
- AWS STS assumes the `aurora-readonly-role`
- You receive temporary AWS credentials

### 3. Connect to Aurora
With temporary credentials active in your AWS session:

#### Using RDS Proxy (Recommended)
```bash
# Get RDS Proxy endpoint
PROXY_ENDPOINT=$(terraform output -raw rds_proxy_endpoint)

# Generate auth token
TOKEN=$(aws rds-db auth-token \
  --hostname $PROXY_ENDPOINT \
  --port 3306 \
  --region us-east-1 \
  --username readonly_user)

# Connect
mysql -h $PROXY_ENDPOINT \
  -P 3306 \
  -u readonly_user \
  --ssl-ca=rds-ca-bundle.pem \
  --ssl-mode=VERIFY_IDENTITY \
  -p"$TOKEN"
```

#### Direct Aurora Connection
```bash
# Get Aurora endpoint
ENDPOINT=$(terraform output -raw aurora_cluster_endpoint)

# Generate auth token
TOKEN=$(aws rds-db auth-token \
  --hostname $ENDPOINT \
  --port 3306 \
  --region us-east-1 \
  --username readonly_user)

# Connect
mysql -h $ENDPOINT \
  -P 3306 \
  -u readonly_user \
  --ssl-ca=rds-ca-bundle.pem \
  --ssl-mode=VERIFY_IDENTITY \
  -p"$TOKEN"
```

## Key Security Features

✅ **End-to-End Encryption**
- Database storage encrypted with KMS
- RDS Proxy connections over TLS
- Secrets encrypted in Secrets Manager

✅ **Identity-Based Access**
- No database passwords in code
- IAM-based authentication
- SAML federation with Okta
- Temporary session tokens

✅ **Network Isolation**
- Aurora in private subnets
- Security groups restrict access
- RDS Proxy provides additional layer

✅ **Audit Trail**
- CloudWatch logs for all database activity
- Enhanced monitoring metrics
- IAM role assumption tracking

✅ **High Availability**
- Multi-AZ Aurora deployment
- Automated failover
- Read replicas via reader endpoint

## Okta Configuration Details

### SAML Application Attributes
The Terraform creates Okta SAML app with these attributes:

| Attribute | Value |
|-----------|-------|
| Name Format | Email Address |
| NameID | user.email |
| RoleSessionName | user.email |
| Role | arn:aws:iam::ACCOUNT:role/aurora-readonly-role |

### Adding Users to Okta Group
1. Log in to Okta Admin Console
2. Navigate to **Directory** → **Groups**
3. Find "aurora-readonly-users" group
4. Click **Add people**
5. Select users to add

## Troubleshooting

### Issue: Cannot assume role from Okta SAML
**Solution**: 
- Verify Okta user is in "aurora-readonly-users" group
- Check SAML assertion in Okta app
- Verify AWS account ID in IAM role trust policy

### Issue: MySQL connection refused
**Solution**:
- Verify Aurora cluster is in "available" state
- Check security group allows port 3306
- Confirm temporary AWS credentials are active
- Verify read-only user exists in database

### Issue: "Access Denied" when connecting
**Solution**:
- Ensure you're using the correct username (readonly_user)
- Verify IAM policy includes rds-db:connect
- Check that database user has SELECT permissions
- Verify using IAM authentication (auth token)

### Issue: RDS Proxy connection fails
**Solution**:
- Check RDS Proxy status is "available"
- Verify Secrets Manager secret is accessible
- Confirm KMS key grants are proper
- Check security group allows proxy-to-Aurora communication

## Customization

### Change Instance Size
Edit `terraform.tfvars`:
```hcl
aurora_instance_class = "db.t4g.medium"
```

### Enable Performance Insights
Already enabled with 7-day retention. To change:
Edit `aurora.tf` and modify performance_insights_retention_period.

### Disable RDS Proxy
Edit `terraform.tfvars`:
```hcl
rds_proxy_enabled = false
```

### Add More Databases
Add to Aurora cluster:
```sql
CREATE DATABASE your_database;
GRANT SELECT ON your_database.* TO 'readonly_user'@'%';
```

### Change Session Duration
Edit `terraform.tfvars`:
```hcl
session_duration = 7200  # 2 hours instead of 1
```

## Outputs

After successful apply, Terraform outputs important values:

```bash
terraform output
```

Key outputs:
- `aurora_cluster_endpoint`: Aurora write endpoint
- `aurora_reader_endpoint`: Aurora read-only endpoint
- `rds_proxy_endpoint`: RDS Proxy endpoint (if enabled)
- `aurora_readonly_role_arn`: IAM role for access
- `okta_saml_provider_arn`: Okta identity provider ARN
- `connection_instructions`: Step-by-step connection guide

## Cost Estimation

### Primary Costs
- **Aurora Instances**: db.t4g.small × 2 = ~$100-150/month
- **RDS Proxy**: Hourly rates (~$0.12/hour) + request fees
- **Data Transfer**: Minimal if within same region
- **Backups**: Included in Aurora backup retention
- **KMS Encryption**: Minimal key usage (~$1/month)
- **CloudWatch Logs**: Depends on query volume (~$5-20/month)

**Estimated Monthly Cost**: $120-200

## Maintenance

### Regular Tasks
1. **Monitor Aurora metrics**: Check CloudWatch dashboards
2. **Review slow queries**: Analyze slow query logs
3. **Update Aurora version**: AWS applies patches automatically
4. **Rotate Okta API token**: Every 90 days recommended
5. **Review IAM policies**: Quarterly access audit

### Backup & Recovery
- Automated backups: 7 days retention (configurable)
- Point-in-time recovery: Available within retention window
- Manual snapshots: Create via AWS Console or CLI

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

**Warning**: This will delete:
- Aurora cluster and snapshots
- VPC and all networking
- IAM roles and policies
- Okta SAML app (if created by Terraform)

To keep final snapshot:
```bash
# Modify state before destroy to create snapshot
terraform destroy
```

## Advanced Topics

### Connecting from EC2 Instance
```bash
# On EC2 instance with IAM role that has rds-db:connect

TOKEN=$(aws rds-db auth-token \
  --hostname $ENDPOINT \
  --port 3306 \
  --region us-east-1 \
  --username readonly_user)

mysql -h $ENDPOINT \
  -u readonly_user \
  --ssl-ca=/path/to/rds-ca-2019-root.pem \
  --ssl-mode=VERIFY_IDENTITY \
  -p"$TOKEN" \
  -e "SELECT VERSION();"
```

### Using AWS Lambda
```python
import boto3
import pymysql
import ssl

rds_client = boto3.client('rds')
endpoint = 'your-aurora-endpoint'
port = 3306
username = 'readonly_user'

# Generate token
token = rds_client.generate_db_auth_token(
    DBHostname=endpoint,
    Port=port,
    DBUser=username,
    Region='us-east-1'
)

# Connect with token
connection = pymysql.connect(
    host=endpoint,
    user=username,
    password=token,
    port=port,
    ssl_ca='/opt/rds-ca-bundle.pem',
    ssl_verify_cert=True,
    ssl_verify_identity=True
)
```

### Monitoring with CloudWatch
```bash
# View Aurora metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name DatabaseConnections \
  --dimensions Name=DBClusterIdentifier,Value=aurora-readonly-db \
  --start-time 2024-01-01T00:00:00Z \
  --end-time 2024-01-01T01:00:00Z \
  --period 300 \
  --statistics Average
```

## Support & References

- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest)
- [Terraform Okta Provider](https://registry.terraform.io/providers/okta/okta/latest)
- [AWS IAM Database Authentication](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.IAMDBAuth.html)
- [Okta SAML Configuration](https://developer.okta.com/docs/guides/build-sso-integration/)
- [RDS Proxy Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy.html)

## License

This Terraform configuration is provided as-is for educational purposes.

## Author Notes

This setup demonstrates:
- Federation between Okta and AWS
- Modern database authentication without passwords
- Infrastructure as Code best practices
- Security-first architecture design
- Multi-layer connection pooling and authentication

For production use, consider:
- VPC Peering for application connectivity
- Enhanced monitoring and alerting
- Larger instance sizes for production workloads
- Custom parameter groups for your workload
- Additional read replicas for scaling

curl -o /tmp/global-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem

TOKEN=$(aws rds generate-db-auth-token \
    --hostname aurora-okta-8a1-proxy.proxy-cuukwis7t1js.us-east-1.rds.amazonaws.com \
    --port 3306 \
    --username readonly_user \
    --profile readonly \
    --region us-east-1)
    
mysql -h aurora-okta-8a1-proxy.proxy-cuukwis7t1js.us-east-1.rds.amazonaws.com \
        -P 3306 \
        -u readonly_user \
        --password="$TOKEN" \
        --ssl-ca=/tmp/global-bundle.pem \
        --ssl-mode=VERIFY_CA \
        appdb

echo "Auth token (first 80 chars): ${TOKEN:0:80}"
  echo "Token length: ${#TOKEN}"
  aws sts get-caller-identity --profile readonly