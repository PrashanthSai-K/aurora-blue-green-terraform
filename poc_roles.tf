locals {
  cluster_resource_id = "cluster-N7AJTGQ7DGR6J46G57OBOKZ2JM"
  aurora_endpoint     = "aurora-readonly-db-instance-1.cuukwis7t1js.us-east-1.rds.amazonaws.com"

  # All 3 roles share this trust policy — Okta SAML + direct assume for CLI testing
  saml_trust_policy = {
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
      },
      # Allow direct assume for CLI testing
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = "sts:AssumeRole"
      }
    ]
  }
}

# ─── ROLE 1: readonly ────────────────────────────────────────────────────────

resource "aws_iam_policy" "poc_readonly" {
  name = "${var.project_name}-poc-readonly"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ConnectAsReadonly"
      Effect = "Allow"
      Action = ["rds-db:connect"]
      Resource = [
        "arn:aws:rds-db:${var.aws_region}:${data.aws_caller_identity.current.account_id}:dbuser:${local.cluster_resource_id}/readonly_user"
      ]
    }]
  })
}

resource "aws_iam_role" "poc_readonly" {
  name                 = "${var.project_name}-poc-readonly-role"
  max_session_duration = var.session_duration
  assume_role_policy   = jsonencode(local.saml_trust_policy)
  tags                 = { Name = "${var.project_name}-poc-readonly-role" }
}

resource "aws_iam_role_policy_attachment" "poc_readonly" {
  role       = aws_iam_role.poc_readonly.name
  policy_arn = aws_iam_policy.poc_readonly.arn
}

# ─── ROLE 2: readwrite ───────────────────────────────────────────────────────

resource "aws_iam_policy" "poc_readwrite" {
  name = "${var.project_name}-poc-readwrite"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ConnectAsReadwrite"
      Effect = "Allow"
      Action = ["rds-db:connect"]
      Resource = [
        "arn:aws:rds-db:${var.aws_region}:${data.aws_caller_identity.current.account_id}:dbuser:${local.cluster_resource_id}/readwrite_user"
      ]
    }]
  })
}

resource "aws_iam_role" "poc_readwrite" {
  name                 = "${var.project_name}-poc-readwrite-role"
  max_session_duration = var.session_duration
  assume_role_policy   = jsonencode(local.saml_trust_policy)
  tags                 = { Name = "${var.project_name}-poc-readwrite-role" }
}

resource "aws_iam_role_policy_attachment" "poc_readwrite" {
  role       = aws_iam_role.poc_readwrite.name
  policy_arn = aws_iam_policy.poc_readwrite.arn
}

# ─── ROLE 3: dba ─────────────────────────────────────────────────────────────

resource "aws_iam_policy" "poc_dba" {
  name = "${var.project_name}-poc-dba"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ConnectAsDba"
      Effect = "Allow"
      Action = ["rds-db:connect"]
      Resource = [
        "arn:aws:rds-db:${var.aws_region}:${data.aws_caller_identity.current.account_id}:dbuser:${local.cluster_resource_id}/dba_user"
      ]
    }]
  })
}

resource "aws_iam_role" "poc_dba" {
  name                 = "${var.project_name}-poc-dba-role"
  max_session_duration = var.session_duration
  assume_role_policy   = jsonencode(local.saml_trust_policy)
  tags                 = { Name = "${var.project_name}-poc-dba-role" }
}

resource "aws_iam_role_policy_attachment" "poc_dba" {
  role       = aws_iam_role.poc_dba.name
  policy_arn = aws_iam_policy.poc_dba.arn
}

# ─── DB USER CREATION SQL ────────────────────────────────────────────────────

resource "null_resource" "create_poc_users" {
  triggers = {
    cluster_id = local.cluster_resource_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      cat > /tmp/create_poc_users.sql << 'EOF'
      -- readonly_user: SELECT only
      CREATE USER IF NOT EXISTS 'readonly_user'@'%' IDENTIFIED WITH AWSAuthenticationPlugin AS 'RDS';
      GRANT SELECT, SHOW VIEW ON ${var.database_name}.* TO 'readonly_user'@'%';

      -- readwrite_user: SELECT + DML
      CREATE USER IF NOT EXISTS 'readwrite_user'@'%' IDENTIFIED WITH AWSAuthenticationPlugin AS 'RDS';
      GRANT SELECT, INSERT, UPDATE, DELETE, SHOW VIEW ON ${var.database_name}.* TO 'readwrite_user'@'%';

      -- dba_user: full access on the database
      CREATE USER IF NOT EXISTS 'dba_user'@'%' IDENTIFIED WITH AWSAuthenticationPlugin AS 'RDS';
      GRANT ALL PRIVILEGES ON ${var.database_name}.* TO 'dba_user'@'%';

      FLUSH PRIVILEGES;
      EOF

      echo ""
      echo "=== Run this to create all 3 DB users ==="
      echo "mysql -h ${local.aurora_endpoint} -u ${var.aurora_master_username} -p < /tmp/create_poc_users.sql"
    EOT
  }

  depends_on = [
    aws_iam_role.poc_readonly,
    aws_iam_role.poc_readwrite,
    aws_iam_role.poc_dba
  ]
}

# ─── OUTPUTS ─────────────────────────────────────────────────────────────────

output "poc_role_readonly_arn"  { value = aws_iam_role.poc_readonly.arn }
output "poc_role_readwrite_arn" { value = aws_iam_role.poc_readwrite.arn }
output "poc_role_dba_arn"       { value = aws_iam_role.poc_dba.arn }

output "poc_cli_test_commands" {
  value = <<-EOT

    == POC CLI Test Commands ==

    # --- READONLY ---
    aws sts assume-role --role-arn ${aws_iam_role.poc_readonly.arn} --role-session-name poc-readonly-test
    export AWS_ACCESS_KEY_ID=<from above>
    export AWS_SECRET_ACCESS_KEY=<from above>
    export AWS_SESSION_TOKEN=<from above>
    TOKEN=$(aws rds generate-db-auth-token --hostname ${local.aurora_endpoint} --port 3306 --region ${var.aws_region} --username readonly_user)
    mysql -h ${local.aurora_endpoint} -u readonly_user --password="$TOKEN" --ssl-mode=REQUIRED ${var.database_name}
    -- Test: INSERT should fail, SELECT should work

    # --- READWRITE ---
    aws sts assume-role --role-arn ${aws_iam_role.poc_readwrite.arn} --role-session-name poc-readwrite-test
    TOKEN=$(aws rds generate-db-auth-token --hostname ${local.aurora_endpoint} --port 3306 --region ${var.aws_region} --username readwrite_user)
    mysql -h ${local.aurora_endpoint} -u readwrite_user --password="$TOKEN" --ssl-mode=REQUIRED ${var.database_name}
    -- Test: SELECT + INSERT + UPDATE + DELETE should all work

    # --- DBA ---
    aws sts assume-role --role-arn ${aws_iam_role.poc_dba.arn} --role-session-name poc-dba-test
    TOKEN=$(aws rds generate-db-auth-token --hostname ${local.aurora_endpoint} --port 3306 --region ${var.aws_region} --username dba_user)
    mysql -h ${local.aurora_endpoint} -u dba_user --password="$TOKEN" --ssl-mode=REQUIRED ${var.database_name}
    -- Test: ALL PRIVILEGES including CREATE TABLE, DROP, etc.

  EOT
}
