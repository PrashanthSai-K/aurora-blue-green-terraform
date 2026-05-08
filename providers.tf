terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    okta = {
      source  = "okta/okta"
      version = "~> 4.0"
    }
    aurora-bluegreen = {
      # Resolved from filesystem_mirror in ~/.terraformrc — no registry lookup.
      # Binary installed by: make install-darwin-arm64 (local) or workflow (CI).
      source  = "local/aurora-bluegreen"
      version = "~> 1.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment
      ManagedBy   = "Terraform"
      Project     = "Aurora-Okta-SAML"
    }
  }
}

provider "okta" {
  org_name  = var.okta_org_name
  base_url  = var.okta_base_url
  api_token = var.okta_api_token
}

provider "aurora-bluegreen" {
  region = var.aws_region
  # Credentials from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY env vars,
  # or from the IAM role attached to the runner — no hardcoding needed.
}


