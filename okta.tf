# Okta Group for Aurora access
# Name must match the app's groupFilter pattern: aws_{accountid}_{rolename}
resource "okta_group" "aurora_users" {
  name        = "aws_${data.aws_caller_identity.current.account_id}_${var.iam_role_name}"
  description = "Group for users who can access Aurora database via SAML federation"
}

# Okta SAML Application for AWS (preconfigured amazon_aws app — required for AWS JDBC Wrapper Okta plugin)
resource "okta_app_saml" "aws" {
  preconfigured_app = "amazon_aws"
  label             = var.okta_app_name
  status            = "ACTIVE"

  app_settings_json = jsonencode({
    "awsEnvironmentType"  = "aws.amazon"
    "loginURL"            = "https://signin.aws.amazon.com/saml"
    "joinAllRoles"        = false
    "useGroupMapping"     = true
    "sessionDuration"     = tostring(var.session_duration)
    "identityProviderArn" = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:saml-provider/${var.project_name}-okta-provider"
    "groupFilter"         = "aws_(?{{accountid}}\\d+)_(?{{role}}[a-zA-Z0-9+=,.@\\-_]+)"
  })
}

# Assign group to Okta app
resource "okta_app_group_assignment" "aurora" {
  app_id   = okta_app_saml.aws.id
  group_id = okta_group.aurora_users.id
}

# AWS SAML Provider (linked to Okta)
# This should be created after okta_app_saml.aws has its metadata available
resource "aws_iam_saml_provider" "okta" {
  name                   = "${var.project_name}-okta-provider"
  saml_metadata_document = okta_app_saml.aws.metadata

  tags = {
    Name = "${var.project_name}-okta-saml-provider"
  }
}

# Okta app user assignment (optional - for testing)
# You can add users manually through Okta console or use this
# data "okta_user" "example" {
#   search {
#     name  = "search_query"
#     value = "user@example.com"
#   }
# }
#
# resource "okta_app_user_assignment" "example" {
#   app_id  = okta_app_saml.aws.id
#   user_id = data.okta_user.example.id
# }