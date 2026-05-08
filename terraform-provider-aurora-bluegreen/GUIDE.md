###############################################################################
# BUILD, INSTALL & USAGE GUIDE
# terraform-provider-aurora-bluegreen
###############################################################################

## Project structure

terraform-provider-aurora-bluegreen/
├── main.go                                        # Binary entry point
├── go.mod                                         # Go module
├── internal/
│   └── provider/
│       ├── provider.go                            # Provider config + AWS client
│       └── resource_blue_green_deployment.go      # Full CRUD resource
└── examples/
    └── aurora-57-to-80/
        ├── main.tf                                # Usage example
        └── variables.tf


## Why this approach beats null_resource

  null_resource              │  Custom provider
  ────────────────────────── │  ────────────────────────────────────
  deployment_id in /tmp file │  deployment_id in .tfstate (S3)
  Lost between CI runs       │  Survives any runner, any machine
  No drift detection         │  Read() called on every plan
  No terraform import        │  ImportState() supported
  No plan output             │  Full diff in terraform plan
  State drift after switchover│  Status synced on every apply


## Build

  # Prerequisites: Go 1.21+, AWS SDK v2
  cd terraform-provider-aurora-bluegreen
  go mod tidy
  go build -o terraform-provider-aurora-bluegreen .


## Install for local use

  # Linux/macOS (amd64)
  OS=linux_amd64

  PLUGIN_DIR=~/.terraform.d/plugins/registry.terraform.io/yourorg/aurora-bluegreen/1.0.0/$OS
  mkdir -p $PLUGIN_DIR
  cp terraform-provider-aurora-bluegreen $PLUGIN_DIR/

  # macOS arm64
  OS=darwin_arm64
  PLUGIN_DIR=~/.terraform.d/plugins/registry.terraform.io/yourorg/aurora-bluegreen/1.0.0/$OS
  mkdir -p $PLUGIN_DIR
  cp terraform-provider-aurora-bluegreen $PLUGIN_DIR/


## For Atlantis / GitHub Actions CI — distribute the binary

  Option 1 (recommended): Publish to Terraform Registry
    - Follow https://developer.hashicorp.com/terraform/registry/providers/publishing
    - Binary auto-downloaded by Terraform on init

  Option 2: S3 bucket + custom source
    - Upload binary to S3
    - Use filesystem_mirror in ~/.terraformrc:
        provider_installation {
          filesystem_mirror {
            path    = "/opt/terraform-plugins"
            include = ["yourorg/*"]
          }
          direct {
            exclude = ["yourorg/*"]
          }
        }
    - Bake the binary into your Atlantis Docker image:
        COPY terraform-provider-aurora-bluegreen /opt/terraform-plugins/registry.terraform.io/yourorg/aurora-bluegreen/1.0.0/linux_amd64/

  Option 3: GitHub Releases (simplest for teams)
    - Create a GitHub release with the compiled binary as an asset
    - Use goreleaser for multi-arch builds
    - Refer to in .terraformrc via network_mirror or install_method


## Usage

  ### Phase 1: Create green cluster
  terraform apply -var="trigger_switchover=false"
  # → Creates blue/green deployment
  # → Polls until status = AVAILABLE (~20-60 min)
  # → All state stored in S3 backend — safe to run from any machine

  ### Phase 2: Switch to MySQL 8.0 (maintenance window)
  terraform apply -var="trigger_switchover=true"
  # → Triggers switchover
  # → Polls until SWITCHOVER_COMPLETED
  # → Automatically re-attaches Auto Scaling policy
  # → Updates .tfstate with new status

  ### Check status anytime (no AWS console needed)
  terraform show
  # → Shows deployment_id, status, green_cluster_arn from state

  ### Import an existing deployment (if created outside Terraform)
  terraform import aurora-bluegreen_deployment.upgrade bgd-xxxxxxxxxxxx
  # → Reads real AWS state, populates .tfstate

  ### Phase 3: Cleanup
  terraform destroy -var="delete_source_cluster=true"
  # → Deletes the B/G deployment object
  # → Also deletes old blue cluster (because delete_source_cluster=true)


## Atlantis integration

  # .atlantis.yaml — no changes needed from the previous guide
  # The custom provider behaves exactly like any other Terraform provider
  # from Atlantis's perspective.

  # Phase 1 PR: change trigger_switchover = false (initial)
  # atlantis plan → atlantis apply

  # Phase 2 PR: change trigger_switchover = true
  # atlantis plan → see the "update" diff in plan output
  # Get 2 approvals
  # atlantis apply


## Required IAM permissions

  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "rds:CreateBlueGreenDeployment",
          "rds:DeleteBlueGreenDeployment",
          "rds:DescribeBlueGreenDeployments",
          "rds:SwitchoverBlueGreenDeployment",
          "rds:DescribeDBClusters",
          "application-autoscaling:RegisterScalableTarget",
          "application-autoscaling:PutScalingPolicy",
          "application-autoscaling:DescribeScalableTargets",
          "application-autoscaling:DescribeScalingPolicies"
        ],
        "Resource": "*"
      }
    ]
  }
