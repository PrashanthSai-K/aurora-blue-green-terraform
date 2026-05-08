# Get current AWS account ID
data "aws_caller_identity" "current" {}

# IAM Policy for Aurora Database Access
resource "aws_iam_policy" "aurora_access" {
  name        = var.iam_policy_name
  description = "Policy for read-only Aurora database access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRDSConnect"
        Effect = "Allow"
        Action = [
          "rds-db:connect"
        ]
        Resource = [
          "arn:aws:rds:${var.aws_region}:${data.aws_caller_identity.current.account_id}:db:${var.aurora_cluster_name}-instance-*"
        ]
      },
      {
        Sid    = "AllowRDSProxyConnect"
        Effect = "Allow"
        Action = [
          "rds-db:connect"
        ]
        Resource = [
          "arn:aws:rds:${var.aws_region}:${data.aws_caller_identity.current.account_id}:prx:*"
        ]
      },
      {
        Sid    = "AllowRDSConsoleReadOnly"
        Effect = "Allow"
        Action = [
          "rds:DescribeDBClusters",
          "rds:DescribeDBInstances",
          "rds:DescribeDBSubnetGroups",
          "rds:DescribeDBParameterGroups",
          "rds:DescribeDBClusterParameterGroups",
          "rds:DescribeDBSnapshots",
          "rds:DescribeDBClusterSnapshots",
          "rds:DescribeDBProxies",
          "rds:DescribeDBProxyTargetGroups",
          "rds:DescribeDBProxyTargets",
          "rds:DescribeEvents",
          "rds:ListTagsForResource",
          "ec2:DescribeVpcs",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeAvailabilityZones",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:GetLogEvents",
          "kms:ListKeys",
          "kms:ListAliases",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = var.iam_policy_name
  }
}

# IAM Role for Aurora Access via Okta SAML
resource "aws_iam_role" "aurora_readonly" {
  name                 = var.iam_role_name
  description          = "Role for read-only Aurora database access via Okta SAML"
  max_session_duration = var.session_duration

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_saml_provider.okta.arn
        }
        Action = "sts:AssumeRoleWithSAML"
        Condition = {
          StringEquals = {
            "SAML:aud" = "https://signin.aws.amazon.com/saml"
          }
        }
      }
    ]
  })

  tags = {
    Name = var.iam_role_name
  }
}

# Attach Aurora policy to role
resource "aws_iam_role_policy_attachment" "aurora_access" {
  role       = aws_iam_role.aurora_readonly.name
  policy_arn = aws_iam_policy.aurora_access.arn
}

# Policy for RDS Proxy authentication
resource "aws_iam_policy" "rds_proxy_auth" {
  name        = "${var.project_name}-rds-proxy-auth"
  description = "Policy for RDS Proxy IAM database authentication"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRDSProxyConnect"
        Effect = "Allow"
        Action = [
          "rds-db:connect"
        ]
        Resource = [
          "arn:aws:rds:${var.aws_region}:${data.aws_caller_identity.current.account_id}:prx:*"
        ]
      }
    ]
  })
}

# Attach RDS Proxy policy to role
resource "aws_iam_role_policy_attachment" "rds_proxy_auth" {
  role       = aws_iam_role.aurora_readonly.name
  policy_arn = aws_iam_policy.rds_proxy_auth.arn
}

# IAM Role for RDS Proxy to access Secrets Manager
resource "aws_iam_role" "rds_proxy_role" {
  name        = "${var.project_name}-rds-proxy-role"
  description = "Role for RDS Proxy to access Secrets Manager"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-rds-proxy-role"
  }
}

# Policy for RDS Proxy to access Secrets Manager
resource "aws_iam_policy" "rds_proxy_secrets" {
  name        = "${var.project_name}-rds-proxy-secrets"
  description = "Policy for RDS Proxy to access Aurora credentials in Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.project_name}-aurora-credentials-*"
        ]
      },
      {
        Sid    = "AllowDecrypt"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${var.aws_region}.amazonaws.com"
          }
        }
      }
    ]
  })
}

# Attach Secrets Manager policy to RDS Proxy role
resource "aws_iam_role_policy_attachment" "rds_proxy_secrets" {
  role       = aws_iam_role.rds_proxy_role.name
  policy_arn = aws_iam_policy.rds_proxy_secrets.arn
}

# KMS Key for encrypting Secrets Manager secrets
resource "aws_kms_key" "secrets" {
  description             = "KMS key for encrypting RDS Proxy secrets"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  tags = {
    Name = "${var.project_name}-secrets-key"
  }
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.project_name}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# Allow RDS Proxy role to use the KMS key
resource "aws_kms_grant" "rds_proxy" {
  name              = "${var.project_name}-rds-proxy-grant"
  grantee_principal = aws_iam_role.rds_proxy_role.arn
  operations        = ["Decrypt", "DescribeKey", "GenerateDataKey"]
  key_id            = aws_kms_key.secrets.id
}