# Remote state backend — required for GitHub Actions workflows.
#
# One-time setup before first GitHub Actions run:
#
#   # 1. Create the S3 bucket
#   aws s3api create-bucket \
#     --bucket <your-tf-state-bucket> \
#     --region us-east-1
#
#   # 2. Enable versioning
#   aws s3api put-bucket-versioning \
#     --bucket <your-tf-state-bucket> \
#     --versioning-configuration Status=Enabled
#
#   # 3. Create DynamoDB lock table
#   aws dynamodb create-table \
#     --table-name terraform-state-lock \
#     --attribute-definitions AttributeName=LockID,AttributeType=S \
#     --key-schema AttributeName=LockID,KeyType=HASH \
#     --billing-mode PAY_PER_REQUEST \
#     --region us-east-1
#
#   # 4. Migrate existing local state to S3 (run once)
#   terraform init -migrate-state \
#     -backend-config="bucket=<your-tf-state-bucket>" \
#     -backend-config="key=aurora-okta/terraform.tfstate" \
#     -backend-config="region=us-east-1" \
#     -backend-config="dynamodb_table=terraform-state-lock" \
#     -backend-config="encrypt=true"
#
# After migration, store bucket name as GitHub Secret: TF_STATE_BUCKET

terraform {
  backend "s3" {
    region = "us-east-1"
  }
}
