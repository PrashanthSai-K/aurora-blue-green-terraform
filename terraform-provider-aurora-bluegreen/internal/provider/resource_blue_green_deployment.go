// internal/provider/resource_blue_green_deployment.go
//
// Full CRUD lifecycle for an Aurora Blue/Green Deployment:
//
//   Create → CreateBlueGreenDeployment + poll until AVAILABLE
//   Read   → DescribeBlueGreenDeployments (drift detection on every plan)
//   Update → SwitchoverBlueGreenDeployment when trigger_switchover flips true
//            + re-attaches Auto Scaling policy post-switchover
//            + populates old_source_cluster_id after switchover
//            + optionally sets replication_status = SETUP_PENDING
//            + flips RDS Proxy target when proxy_active_cluster changes
//            + deletes old blue cluster when delete_old_cluster flips true
//   Delete → guards against destroying while proxy routes to old cluster
//            + optionally deletes old blue cluster (retain_old_cluster=false)
//            + DeleteBlueGreenDeployment
//
// State is stored in the Terraform backend (S3) — no local files, no state
// drift across CI runners or developer machines.

package provider

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/applicationautoscaling"
	astypes "github.com/aws/aws-sdk-go-v2/service/applicationautoscaling/types"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"
	"github.com/hashicorp/terraform-plugin-framework/attr"
	"github.com/hashicorp/terraform-plugin-framework/diag"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/booldefault"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/int64default"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/stringdefault"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/stringplanmodifier"
	"github.com/hashicorp/terraform-plugin-framework/types"
	"github.com/hashicorp/terraform-plugin-framework/types/basetypes"
	"github.com/hashicorp/terraform-plugin-log/tflog"
)

// Blue/Green deployment status strings.
const (
	bgStatusProvisioning         = "PROVISIONING"
	bgStatusAvailable            = "AVAILABLE"
	bgStatusSwitchoverInProgress = "SWITCHOVER_IN_PROGRESS"
	bgStatusSwitchoverCompleted  = "SWITCHOVER_COMPLETED"
	bgStatusSwitchoverFailed     = "SWITCHOVER_FAILED"
	bgStatusInvalidConfiguration = "INVALID_CONFIGURATION"
	bgStatusDeleting             = "DELETING"

	// Replication status values (externally managed).
	replStatusNotConfigured = "NOT_CONFIGURED"
	replStatusSetupPending  = "SETUP_PENDING"
	replStatusActive        = "ACTIVE"
	replStatusStopped       = "STOPPED"

	// proxy_active_cluster values.
	proxyClusterNew = "new"
	proxyClusterOld = "old"
)

// ─────────────────────────────────────────────────────────────
// Interface assertions
// ─────────────────────────────────────────────────────────────

var (
	_ resource.Resource                = &BlueGreenDeploymentResource{}
	_ resource.ResourceWithImportState = &BlueGreenDeploymentResource{}
	_ resource.ResourceWithConfigure   = &BlueGreenDeploymentResource{}
)

// ─────────────────────────────────────────────────────────────
// Resource struct
// ─────────────────────────────────────────────────────────────

type BlueGreenDeploymentResource struct {
	clients *AWSClients
}

func NewBlueGreenDeploymentResource() resource.Resource {
	return &BlueGreenDeploymentResource{}
}

func (r *BlueGreenDeploymentResource) Metadata(_ context.Context, req resource.MetadataRequest, resp *resource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_deployment"
}

// ─────────────────────────────────────────────────────────────
// State model
// ─────────────────────────────────────────────────────────────

type AutoScalingConfigModel struct {
	PolicyName       types.String  `tfsdk:"policy_name"`
	MinCapacity      types.Int64   `tfsdk:"min_capacity"`
	MaxCapacity      types.Int64   `tfsdk:"max_capacity"`
	TargetCPU        types.Float64 `tfsdk:"target_cpu"`
	ScaleInCooldown  types.Int64   `tfsdk:"scale_in_cooldown"`
	ScaleOutCooldown types.Int64   `tfsdk:"scale_out_cooldown"`
}

type BlueGreenDeploymentModel struct {
	// Computed — set by provider
	ID              types.String `tfsdk:"id"`
	DeploymentID    types.String `tfsdk:"deployment_id"`
	Status          types.String `tfsdk:"status"`
	GreenClusterARN types.String `tfsdk:"green_cluster_arn"`

	// Required inputs — all trigger replacement on change
	DeploymentName           types.String `tfsdk:"deployment_name"`
	SourceClusterARN         types.String `tfsdk:"source_cluster_arn"`
	TargetEngineVersion      types.String `tfsdk:"target_engine_version"`
	TargetParameterGroupName types.String `tfsdk:"target_parameter_group_name"`

	// Lifecycle flags
	TriggerSwitchover   types.Bool `tfsdk:"trigger_switchover"`
	DeleteSourceCluster types.Bool `tfsdk:"delete_source_cluster"`

	// Timeouts
	CreateTimeoutMinutes types.Int64 `tfsdk:"create_timeout_minutes"`
	SwitchoverTimeoutSec types.Int64 `tfsdk:"switchover_timeout_seconds"`

	// Optional — Auto Scaling re-attachment after switchover
	AutoScalingConfig types.Object `tfsdk:"autoscaling_config"`

	// Post-switchover: cluster ID of the old blue cluster (Computed).
	OldSourceClusterID types.String `tfsdk:"old_source_cluster_id"`

	// If false, Delete() removes the old blue cluster from AWS (default true).
	RetainOldCluster types.Bool `tfsdk:"retain_old_cluster"`

	// Binlog replication signaling.
	// Provider sets SETUP_PENDING after switchover when enable_reverse_replication=true.
	// The actual replication SQL is handled by scripts/pre_proxy_flip.sh and post_proxy_flip.sh.
	EnableReverseReplication types.Bool   `tfsdk:"enable_reverse_replication"`
	ReplicationStatus        types.String `tfsdk:"replication_status"`

	// Proxy-based rollback control.
	// "new" = proxy routes to current production (after switchover, the renamed green cluster).
	// "old" = proxy routes to old blue cluster (rollback mode).
	// Changing this triggers flipProxy() in Update(). Requires rds_proxy_name.
	RDSProxyName       types.String `tfsdk:"rds_proxy_name"`
	ProxyActiveCluster types.String `tfsdk:"proxy_active_cluster"`

	// Set true to delete the old blue cluster immediately via Update()
	// (instead of waiting for terraform destroy). Blocked if proxy_active_cluster="old".
	DeleteOldCluster types.Bool `tfsdk:"delete_old_cluster"`
}

var autoScalingAttrTypes = map[string]attr.Type{
	"policy_name":        types.StringType,
	"min_capacity":       types.Int64Type,
	"max_capacity":       types.Int64Type,
	"target_cpu":         types.Float64Type,
	"scale_in_cooldown":  types.Int64Type,
	"scale_out_cooldown": types.Int64Type,
}

// ─────────────────────────────────────────────────────────────
// Schema
// ─────────────────────────────────────────────────────────────

func (r *BlueGreenDeploymentResource) Schema(_ context.Context, _ resource.SchemaRequest, resp *resource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description: "Manages the full lifecycle of an Aurora MySQL Blue/Green Deployment. " +
			"Creates the green cluster, stores deployment_id in Terraform state, handles " +
			"switchover via a flag flip, re-attaches Auto Scaling policies post-switchover, " +
			"and supports zero-data-loss rollback via RDS Proxy target flipping.",

		Attributes: map[string]schema.Attribute{
			// ── Computed ────────────────────────────────────────────────
			"id": schema.StringAttribute{
				Computed:    true,
				Description: "The BlueGreenDeploymentIdentifier (same as deployment_id).",
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"deployment_id": schema.StringAttribute{
				Computed:    true,
				Description: "AWS Blue/Green Deployment identifier (bgd-xxxxxxxxxxxxxxxx).",
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"status": schema.StringAttribute{
				Computed:    true,
				Description: "Current status: PROVISIONING, AVAILABLE, SWITCHOVER_IN_PROGRESS, SWITCHOVER_COMPLETED, INVALID_CONFIGURATION, SWITCHOVER_FAILED, DELETING.",
			},
			"green_cluster_arn": schema.StringAttribute{
				Computed:    true,
				Description: "ARN of the green (target) cluster. Changes after switchover when AWS renames the cluster.",
			},

			// ── Required inputs — all force replacement ──────────────────
			"deployment_name": schema.StringAttribute{
				Required:    true,
				Description: "Name for the Blue/Green Deployment.",
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.RequiresReplace(),
				},
			},
			"source_cluster_arn": schema.StringAttribute{
				Required:    true,
				Description: "ARN of the blue (source) Aurora cluster.",
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.RequiresReplace(),
				},
			},
			"target_engine_version": schema.StringAttribute{
				Required:    true,
				Description: "Target engine version for the green cluster (e.g. 8.0.mysql_aurora.3.10.3).",
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.RequiresReplace(),
				},
			},
			"target_parameter_group_name": schema.StringAttribute{
				Required:    true,
				Description: "DB cluster parameter group name for the green cluster.",
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.RequiresReplace(),
				},
			},

			// ── Lifecycle flags ──────────────────────────────────────────
			"trigger_switchover": schema.BoolAttribute{
				Optional:    true,
				Computed:    true,
				Default:     booldefault.StaticBool(false),
				Description: "Set to true to trigger switchover. Green becomes production. Once SWITCHOVER_COMPLETED, further flips are a no-op.",
			},
			"delete_source_cluster": schema.BoolAttribute{
				Optional:    true,
				Computed:    true,
				Default:     booldefault.StaticBool(false),
				Description: "If true, the old blue cluster is deleted when this resource is destroyed.",
			},

			// ── Timeouts ────────────────────────────────────────────────
			"create_timeout_minutes": schema.Int64Attribute{
				Optional:    true,
				Computed:    true,
				Default:     int64default.StaticInt64(90),
				Description: "Minutes to wait for green cluster to reach AVAILABLE. Default 90.",
			},
			"switchover_timeout_seconds": schema.Int64Attribute{
				Optional:    true,
				Computed:    true,
				Default:     int64default.StaticInt64(300),
				Description: "Seconds allowed for switchover (30–3600). Default 300.",
			},

			// ── Auto Scaling ─────────────────────────────────────────────
			"autoscaling_config": schema.SingleNestedAttribute{
				Optional:    true,
				Description: "Auto Scaling configuration to re-attach after switchover.",
				Attributes: map[string]schema.Attribute{
					"policy_name": schema.StringAttribute{
						Required:    true,
						Description: "Name of the Application Auto Scaling policy.",
					},
					"min_capacity": schema.Int64Attribute{
						Required:    true,
						Description: "Minimum number of Aurora read replicas.",
					},
					"max_capacity": schema.Int64Attribute{
						Required:    true,
						Description: "Maximum number of Aurora read replicas.",
					},
					"target_cpu": schema.Float64Attribute{
						Required:    true,
						Description: "Target CPU utilization percentage (0–100).",
					},
					"scale_in_cooldown": schema.Int64Attribute{
						Optional:    true,
						Computed:    true,
						Default:     int64default.StaticInt64(300),
						Description: "Scale-in cooldown in seconds. Default 300.",
					},
					"scale_out_cooldown": schema.Int64Attribute{
						Optional:    true,
						Computed:    true,
						Default:     int64default.StaticInt64(300),
						Description: "Scale-out cooldown in seconds. Default 300.",
					},
				},
			},

			// ── Post-switchover state ─────────────────────────────────────
			"old_source_cluster_id": schema.StringAttribute{
				Computed:    true,
				Description: "Cluster ID of the old blue cluster after switchover. Used for proxy-based rollback.",
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},

			"retain_old_cluster": schema.BoolAttribute{
				Optional:    true,
				Computed:    true,
				Default:     booldefault.StaticBool(true),
				Description: "If false, Delete() deletes the old blue cluster from AWS. Default true.",
			},

			// ── Binlog replication signaling ─────────────────────────────
			"enable_reverse_replication": schema.BoolAttribute{
				Optional:    true,
				Computed:    true,
				Default:     booldefault.StaticBool(false),
				Description: "Signals that binlog replication should be set up (actual SQL handled by pre/post_proxy_flip.sh). " +
					"When true, provider sets replication_status = SETUP_PENDING after switchover.",
			},

			"replication_status": schema.StringAttribute{
				Computed:    true,
				Description: "One of: NOT_CONFIGURED / SETUP_PENDING / ACTIVE / STOPPED. " +
					"Provider sets SETUP_PENDING after switchover when enable_reverse_replication=true.",
			},

			// ── Proxy-based rollback ──────────────────────────────────────
			"rds_proxy_name": schema.StringAttribute{
				Optional:    true,
				Description: "Name of the RDS Proxy to redirect during rollback. Required when using proxy_active_cluster.",
			},

			"proxy_active_cluster": schema.StringAttribute{
				Optional:    true,
				Computed:    true,
				Default:     stringdefault.StaticString(proxyClusterNew),
				Description: "Which cluster the RDS Proxy routes to: \"new\" (current production) or \"old\" (rollback). " +
					"Changing this value triggers a proxy target flip. " +
					"Requires rds_proxy_name. Run pre_proxy_flip.sh before and post_proxy_flip.sh after changing to \"old\".",
			},

			// ── On-demand old cluster deletion ────────────────────────────
			"delete_old_cluster": schema.BoolAttribute{
				Optional:    true,
				Computed:    true,
				Default:     booldefault.StaticBool(false),
				Description: "Set true to delete the old blue cluster immediately (without destroying this resource). " +
					"Blocked when proxy_active_cluster=\"old\". Idempotent — safe to leave true after deletion.",
			},
		},
	}
}

// ─────────────────────────────────────────────────────────────
// Configure — inject AWS clients from provider
// ─────────────────────────────────────────────────────────────

func (r *BlueGreenDeploymentResource) Configure(_ context.Context, req resource.ConfigureRequest, resp *resource.ConfigureResponse) {
	if req.ProviderData == nil {
		return
	}
	clients, ok := req.ProviderData.(*AWSClients)
	if !ok {
		resp.Diagnostics.AddError(
			"Unexpected provider data type",
			fmt.Sprintf("Expected *AWSClients, got: %T", req.ProviderData),
		)
		return
	}
	r.clients = clients
}

// ─────────────────────────────────────────────────────────────
// CREATE — CreateBlueGreenDeployment + poll until AVAILABLE
// ─────────────────────────────────────────────────────────────

func (r *BlueGreenDeploymentResource) Create(ctx context.Context, req resource.CreateRequest, resp *resource.CreateResponse) {
	var plan BlueGreenDeploymentModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	if resp.Diagnostics.HasError() {
		return
	}

	tflog.Info(ctx, "Creating Aurora Blue/Green deployment", map[string]any{
		"name":           plan.DeploymentName.ValueString(),
		"source_arn":     plan.SourceClusterARN.ValueString(),
		"target_version": plan.TargetEngineVersion.ValueString(),
	})

	output, err := r.clients.RDS.CreateBlueGreenDeployment(ctx, &rds.CreateBlueGreenDeploymentInput{
		BlueGreenDeploymentName:           aws.String(plan.DeploymentName.ValueString()),
		Source:                            aws.String(plan.SourceClusterARN.ValueString()),
		TargetEngineVersion:               aws.String(plan.TargetEngineVersion.ValueString()),
		TargetDBClusterParameterGroupName: aws.String(plan.TargetParameterGroupName.ValueString()),
	})
	if err != nil {
		resp.Diagnostics.AddError("Failed to create Blue/Green Deployment", err.Error())
		return
	}

	deploymentID := awsStringValue(output.BlueGreenDeployment.BlueGreenDeploymentIdentifier)

	plan.ID = types.StringValue(deploymentID)
	plan.DeploymentID = types.StringValue(deploymentID)
	plan.Status = types.StringValue(awsStringValue(output.BlueGreenDeployment.Status))
	plan.GreenClusterARN = types.StringValue("")
	plan.OldSourceClusterID = types.StringNull()
	plan.ReplicationStatus = types.StringValue(replStatusNotConfigured)
	plan.ProxyActiveCluster = types.StringValue(proxyClusterNew)
	plan.DeleteOldCluster = types.BoolValue(false)

	// Save partial state immediately — preserves deployment_id if poll is interrupted.
	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
	if resp.Diagnostics.HasError() {
		return
	}

	tflog.Info(ctx, "Deployment created, polling for AVAILABLE", map[string]any{
		"deployment_id": deploymentID,
	})

	timeout := time.Duration(plan.CreateTimeoutMinutes.ValueInt64()) * time.Minute
	resp.Diagnostics.Append(r.waitForStatus(ctx, deploymentID, bgStatusAvailable, timeout, &plan)...)
	if resp.Diagnostics.HasError() {
		return
	}

	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

// ─────────────────────────────────────────────────────────────
// READ — DescribeBlueGreenDeployments (drift detection)
// Called on every terraform plan and terraform apply.
// ─────────────────────────────────────────────────────────────

func (r *BlueGreenDeploymentResource) Read(ctx context.Context, req resource.ReadRequest, resp *resource.ReadResponse) {
	var state BlueGreenDeploymentModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	deploymentID := state.DeploymentID.ValueString()
	if deploymentID == "" {
		deploymentID = state.ID.ValueString()
	}

	tflog.Debug(ctx, "Reading Blue/Green deployment", map[string]any{
		"deployment_id": deploymentID,
	})

	output, err := r.clients.RDS.DescribeBlueGreenDeployments(ctx, &rds.DescribeBlueGreenDeploymentsInput{
		BlueGreenDeploymentIdentifier: aws.String(deploymentID),
	})
	if err != nil {
		if isNotFoundError(err) {
			tflog.Info(ctx, "Deployment not found, removing from state", map[string]any{
				"deployment_id": deploymentID,
			})
			resp.State.RemoveResource(ctx)
			return
		}
		resp.Diagnostics.AddError(
			"Failed to read Blue/Green deployment",
			fmt.Sprintf("Error describing %s: %s", deploymentID, err.Error()),
		)
		return
	}

	if len(output.BlueGreenDeployments) == 0 {
		resp.State.RemoveResource(ctx)
		return
	}

	bg := output.BlueGreenDeployments[0]
	state.Status = types.StringValue(awsStringValue(bg.Status))
	state.DeploymentID = types.StringValue(awsStringValue(bg.BlueGreenDeploymentIdentifier))
	state.ID = state.DeploymentID

	if bg.BlueGreenDeploymentName != nil {
		state.DeploymentName = types.StringValue(*bg.BlueGreenDeploymentName)
	}

	// Only populate source_cluster_arn when not already in state.
	// After switchover AWS renames the source cluster, so bg.Source no longer matches
	// the user's config (which still references the original cluster name).
	// Overwriting would cause a RequiresReplace diff and an unwanted destroy+recreate.
	if state.SourceClusterARN.IsNull() || state.SourceClusterARN.ValueString() == "" {
		if bg.Source != nil {
			state.SourceClusterARN = types.StringValue(*bg.Source)
		}
	}

	if bg.Target != nil {
		state.GreenClusterARN = types.StringValue(*bg.Target)

		// target_engine_version and target_parameter_group_name are not returned
		// by DescribeBlueGreenDeployments — fetch from the green cluster on import.
		needVersion := state.TargetEngineVersion.IsNull() || state.TargetEngineVersion.ValueString() == ""
		needParamGroup := state.TargetParameterGroupName.IsNull() || state.TargetParameterGroupName.ValueString() == ""

		if needVersion || needParamGroup {
			clusterID := clusterIDFromARN(*bg.Target)
			clusterOut, clusterErr := r.clients.RDS.DescribeDBClusters(ctx, &rds.DescribeDBClustersInput{
				DBClusterIdentifier: aws.String(clusterID),
			})
			if clusterErr == nil && len(clusterOut.DBClusters) > 0 {
				cluster := clusterOut.DBClusters[0]
				if needVersion && cluster.EngineVersion != nil {
					state.TargetEngineVersion = types.StringValue(*cluster.EngineVersion)
				}
				if needParamGroup && cluster.DBClusterParameterGroup != nil {
					state.TargetParameterGroupName = types.StringValue(*cluster.DBClusterParameterGroup)
				}
			}
		}
	}

	// replication_status is externally managed — Read() does not overwrite it.

	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}

// ─────────────────────────────────────────────────────────────
// UPDATE — switchover, proxy flip, on-demand old cluster deletion
// ─────────────────────────────────────────────────────────────

func (r *BlueGreenDeploymentResource) Update(ctx context.Context, req resource.UpdateRequest, resp *resource.UpdateResponse) {
	var plan, state BlueGreenDeploymentModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	deploymentID := state.DeploymentID.ValueString()

	alreadyCompleted := state.Status.ValueString() == bgStatusSwitchoverCompleted
	alreadyInProgress := state.Status.ValueString() == bgStatusSwitchoverInProgress

	// ── Forward switchover ────────────────────────────────────────────────────
	if plan.TriggerSwitchover.ValueBool() && !alreadyCompleted {
		timeoutSec := state.SwitchoverTimeoutSec.ValueInt64()
		if timeoutSec == 0 {
			timeoutSec = 300
		}

		if alreadyInProgress {
			tflog.Info(ctx, "Switchover already in progress — resuming wait", map[string]any{
				"deployment_id": deploymentID,
			})
		} else {
			tflog.Info(ctx, "Initiating Blue/Green switchover", map[string]any{
				"deployment_id": deploymentID,
			})

			_, err := r.clients.RDS.SwitchoverBlueGreenDeployment(ctx, &rds.SwitchoverBlueGreenDeploymentInput{
				BlueGreenDeploymentIdentifier: aws.String(deploymentID),
				SwitchoverTimeout:             aws.Int32(int32(timeoutSec)),
			})
			if err != nil {
				resp.Diagnostics.AddError(
					"Switchover API call failed",
					fmt.Sprintf("Failed to initiate switchover for %s: %s", deploymentID, err.Error()),
				)
				return
			}
		}

		// Persist status immediately before polling — ensures deployment_id survives an interrupted apply.
		state.TriggerSwitchover = types.BoolValue(true)
		state.Status = types.StringValue(bgStatusSwitchoverInProgress)
		resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
		if resp.Diagnostics.HasError() {
			return
		}

		pollingTimeout := time.Duration(timeoutSec*2+600) * time.Second
		if pollingTimeout < 60*time.Minute {
			pollingTimeout = 60 * time.Minute
		}

		tflog.Info(ctx, "Waiting for switchover completion", map[string]any{
			"deployment_id":   deploymentID,
			"polling_timeout": pollingTimeout.String(),
		})

		pollDiags := r.waitForStatus(ctx, deploymentID, bgStatusSwitchoverCompleted, pollingTimeout, &state)

		if len(pollDiags) > 0 && state.Status.ValueString() == bgStatusAvailable {
			state.TriggerSwitchover = types.BoolValue(false)
		}

		resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
		resp.Diagnostics.Append(pollDiags...)
		if resp.Diagnostics.HasError() {
			return
		}
	}

	// ── Post-switchover actions ──────────────────────────────────────────────
	// Runs whenever the deployment is SWITCHOVER_COMPLETED — whether it just
	// completed in this apply or was completed in a previous one.
	if state.Status.ValueString() == bgStatusSwitchoverCompleted {
		postDescOut, postDescErr := r.clients.RDS.DescribeBlueGreenDeployments(ctx, &rds.DescribeBlueGreenDeploymentsInput{
			BlueGreenDeploymentIdentifier: aws.String(deploymentID),
		})

		if postDescErr == nil && len(postDescOut.BlueGreenDeployments) > 0 {
			bg := postDescOut.BlueGreenDeployments[0]
			if bg.Source != nil && (state.OldSourceClusterID.IsNull() || state.OldSourceClusterID.ValueString() == "") {
				oldClusterID := clusterIDFromARN(*bg.Source)
				state.OldSourceClusterID = types.StringValue(oldClusterID)
				tflog.Info(ctx, "Populated old_source_cluster_id", map[string]any{
					"old_source_cluster_id": oldClusterID,
				})
			}
		}

		if plan.EnableReverseReplication.ValueBool() && state.ReplicationStatus.ValueString() == replStatusNotConfigured {
			state.ReplicationStatus = types.StringValue(replStatusSetupPending)
			tflog.Info(ctx, "Set replication_status = SETUP_PENDING")
		}

		if !plan.AutoScalingConfig.IsNull() && !plan.AutoScalingConfig.IsUnknown() {
			tflog.Info(ctx, "Re-attaching Auto Scaling policy post-switchover")
			resp.Diagnostics.Append(r.reattachAutoScaling(ctx, plan)...)
			if resp.Diagnostics.HasError() {
				return
			}
		}
	}

	// ── Section A: Proxy flip ─────────────────────────────────────────────────
	// Triggered when proxy_active_cluster changes. The null_resource.pre_proxy_flip
	// in blue_green.tf runs before this resource (via depends_on), ensuring the
	// zero-data-loss sequence: read-only source → lag=0 → proxy flip → promote target.
	if !plan.ProxyActiveCluster.Equal(state.ProxyActiveCluster) {
		proxyName := plan.RDSProxyName.ValueString()
		if proxyName == "" {
			proxyName = state.RDSProxyName.ValueString()
		}
		if proxyName == "" {
			resp.Diagnostics.AddError(
				"rds_proxy_name required for proxy flip",
				"rds_proxy_name must be set to use proxy_active_cluster. "+
					"Set rds_proxy_name in the resource configuration.",
			)
			return
		}

		wantCluster := plan.ProxyActiveCluster.ValueString()
		var targetClusterID string

		switch wantCluster {
		case proxyClusterOld:
			targetClusterID = state.OldSourceClusterID.ValueString()
			if targetClusterID == "" {
				resp.Diagnostics.AddError(
					"Cannot flip proxy to old cluster",
					"old_source_cluster_id is empty — forward switchover must complete before rolling back to old cluster.",
				)
				return
			}
		case proxyClusterNew:
			// Current production cluster keeps the original cluster identifier after switchover.
			targetClusterID = clusterIDFromARN(plan.SourceClusterARN.ValueString())
		default:
			resp.Diagnostics.AddError(
				"Invalid proxy_active_cluster",
				fmt.Sprintf("Expected %q or %q, got %q", proxyClusterNew, proxyClusterOld, wantCluster),
			)
			return
		}

		tflog.Info(ctx, "Flipping RDS Proxy target", map[string]any{
			"proxy_name":        proxyName,
			"target_cluster_id": targetClusterID,
			"direction":         wantCluster,
		})

		resp.Diagnostics.Append(r.flipProxy(ctx, proxyName, targetClusterID)...)
		if resp.Diagnostics.HasError() {
			resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
			return
		}

		state.ProxyActiveCluster = plan.ProxyActiveCluster

		// Mark replication as stopped when proxy moves to old cluster.
		// The post_proxy_flip.sh script will set up reverse replication separately.
		if wantCluster == proxyClusterOld {
			state.ReplicationStatus = types.StringValue(replStatusStopped)
		}

		// Save state immediately after proxy flip.
		resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
		if resp.Diagnostics.HasError() {
			return
		}

		tflog.Info(ctx, "Proxy flip complete", map[string]any{
			"proxy_name":        proxyName,
			"target_cluster_id": targetClusterID,
		})
	}

	// ── Section B: Delete old cluster on demand ───────────────────────────────
	// Triggered when delete_old_cluster flips from false → true.
	// Guard: proxy must not be pointing to old cluster.
	if plan.DeleteOldCluster.ValueBool() && !state.DeleteOldCluster.ValueBool() {
		currentProxy := state.ProxyActiveCluster.ValueString()
		if currentProxy == "" {
			currentProxy = proxyClusterNew
		}

		if currentProxy == proxyClusterOld {
			resp.Diagnostics.AddError(
				"Cannot delete old cluster while proxy routes to it",
				"Set proxy_active_cluster=\"new\" and re-apply before setting delete_old_cluster=true.",
			)
			return
		}

		oldClusterID := state.OldSourceClusterID.ValueString()
		if oldClusterID == "" {
			tflog.Warn(ctx, "delete_old_cluster=true but old_source_cluster_id is empty — nothing to delete")
		} else {
			tflog.Info(ctx, "delete_old_cluster=true — deleting old blue cluster", map[string]any{
				"old_cluster_id": oldClusterID,
			})
			resp.Diagnostics.Append(r.deleteClusterAndInstances(ctx, oldClusterID)...)
			if resp.Diagnostics.HasError() {
				resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
				return
			}
			state.OldSourceClusterID = types.StringNull()
			tflog.Info(ctx, "Old blue cluster deleted", map[string]any{
				"old_cluster_id": oldClusterID,
			})
		}
		state.DeleteOldCluster = types.BoolValue(true)
	}

	// ── Sync all mutable plan fields to state ────────────────────────────────
	state.TriggerSwitchover = plan.TriggerSwitchover
	state.DeleteSourceCluster = plan.DeleteSourceCluster
	state.AutoScalingConfig = plan.AutoScalingConfig
	state.CreateTimeoutMinutes = plan.CreateTimeoutMinutes
	state.SwitchoverTimeoutSec = plan.SwitchoverTimeoutSec
	state.RetainOldCluster = plan.RetainOldCluster
	state.EnableReverseReplication = plan.EnableReverseReplication
	state.RDSProxyName = plan.RDSProxyName
	// ProxyActiveCluster is synced in Section A; if Section A didn't run, keep current.
	if plan.ProxyActiveCluster.Equal(state.ProxyActiveCluster) {
		// Already in sync — no-op.
	}
	// DeleteOldCluster: if it was already true in state (cluster deleted), keep true even if plan says false.
	if !state.DeleteOldCluster.ValueBool() {
		state.DeleteOldCluster = plan.DeleteOldCluster
	}

	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}

// ─────────────────────────────────────────────────────────────
// DELETE — idempotent, guards against destroying during rollback
// ─────────────────────────────────────────────────────────────

func (r *BlueGreenDeploymentResource) Delete(ctx context.Context, req resource.DeleteRequest, resp *resource.DeleteResponse) {
	var state BlueGreenDeploymentModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	deploymentID := state.DeploymentID.ValueString()

	// ── Guard: Proxy must not route to old cluster ───────────────────────────
	// Destroying while proxy=old would strand production traffic on the old cluster
	// with no Terraform-managed way to flip it back.
	currentProxy := state.ProxyActiveCluster.ValueString()
	if currentProxy == proxyClusterOld {
		resp.Diagnostics.AddError(
			"Cannot destroy while proxy routes to old cluster",
			"Set proxy_active_cluster=\"new\" and run terraform apply before running terraform destroy. "+
				"This prevents stranding production traffic on the old cluster.",
		)
		return
	}

	tflog.Info(ctx, "Deleting Blue/Green deployment", map[string]any{
		"deployment_id":      deploymentID,
		"retain_old_cluster": state.RetainOldCluster.ValueBool(),
	})

	// ── Step 1: Delete old blue cluster if retain_old_cluster=false ──────────
	if !state.RetainOldCluster.ValueBool() {
		oldClusterID := state.OldSourceClusterID.ValueString()
		if oldClusterID != "" {
			tflog.Info(ctx, "retain_old_cluster=false — deleting old blue cluster", map[string]any{
				"old_cluster_id": oldClusterID,
			})
			resp.Diagnostics.Append(r.deleteClusterAndInstances(ctx, oldClusterID)...)
			if resp.Diagnostics.HasError() {
				return
			}
		}
	}

	// ── Step 2: Delete the main B/G deployment ───────────────────────────────
	input := &rds.DeleteBlueGreenDeploymentInput{
		BlueGreenDeploymentIdentifier: aws.String(deploymentID),
	}
	if state.DeleteSourceCluster.ValueBool() {
		input.DeleteTarget = aws.Bool(true)
	}

	_, err := r.clients.RDS.DeleteBlueGreenDeployment(ctx, input)
	if err != nil {
		if isNotFoundError(err) {
			tflog.Info(ctx, "Deployment already deleted", map[string]any{
				"deployment_id": deploymentID,
			})
			return
		}
		resp.Diagnostics.AddError(
			"Failed to delete Blue/Green Deployment",
			fmt.Sprintf("Error deleting %s: %s", deploymentID, err.Error()),
		)
		return
	}

	tflog.Info(ctx, "Blue/Green deployment deleted", map[string]any{
		"deployment_id": deploymentID,
	})
}

// ─────────────────────────────────────────────────────────────
// IMPORT STATE
// terraform import aurora-bluegreen_deployment.main bgd-xxxx
// ─────────────────────────────────────────────────────────────

func (r *BlueGreenDeploymentResource) ImportState(ctx context.Context, req resource.ImportStateRequest, resp *resource.ImportStateResponse) {
	if !strings.HasPrefix(req.ID, "bgd-") {
		resp.Diagnostics.AddError(
			"Invalid import ID",
			fmt.Sprintf("Expected an identifier starting with 'bgd-', got: %q", req.ID),
		)
		return
	}

	tflog.Info(ctx, "Importing Blue/Green deployment", map[string]any{"id": req.ID})

	state := BlueGreenDeploymentModel{
		ID:                       types.StringValue(req.ID),
		DeploymentID:             types.StringValue(req.ID),
		TriggerSwitchover:        types.BoolValue(false),
		DeleteSourceCluster:      types.BoolValue(false),
		CreateTimeoutMinutes:     types.Int64Value(90),
		SwitchoverTimeoutSec:     types.Int64Value(300),
		AutoScalingConfig:        types.ObjectNull(autoScalingAttrTypes),
		OldSourceClusterID:       types.StringNull(),
		RetainOldCluster:         types.BoolValue(true),
		EnableReverseReplication: types.BoolValue(false),
		ReplicationStatus:        types.StringValue(replStatusNotConfigured),
		RDSProxyName:             types.StringNull(),
		ProxyActiveCluster:       types.StringValue(proxyClusterNew),
		DeleteOldCluster:         types.BoolValue(false),
	}

	// Read() will hydrate status, green_cluster_arn, etc. from AWS.
	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}

// ─────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────

// waitForStatus polls DescribeBlueGreenDeployments until targetStatus is
// reached or the timeout expires, updating the model in-place each poll.
func (r *BlueGreenDeploymentResource) waitForStatus(
	ctx context.Context,
	deploymentID string,
	targetStatus string,
	timeout time.Duration,
	model *BlueGreenDeploymentModel,
) diag.Diagnostics {
	var diags diag.Diagnostics

	hardFailures := map[string]bool{
		bgStatusSwitchoverFailed:     true,
		bgStatusInvalidConfiguration: true,
		bgStatusDeleting:             true,
	}

	deadline := time.Now().Add(timeout)
	seenNonAvailable := false

	for time.Now().Before(deadline) {
		output, err := r.clients.RDS.DescribeBlueGreenDeployments(ctx, &rds.DescribeBlueGreenDeploymentsInput{
			BlueGreenDeploymentIdentifier: aws.String(deploymentID),
		})
		if err != nil {
			diags.AddError("Poll error", fmt.Sprintf("Failed to describe %s: %s", deploymentID, err.Error()))
			return diags
		}

		if len(output.BlueGreenDeployments) == 0 {
			diags.AddError("Deployment disappeared", fmt.Sprintf("Deployment %s not found during polling", deploymentID))
			return diags
		}

		bg := output.BlueGreenDeployments[0]
		currentStatus := awsStringValue(bg.Status)

		tflog.Info(ctx, "Polling Blue/Green deployment", map[string]any{
			"deployment_id":      deploymentID,
			"current_status":     currentStatus,
			"target_status":      targetStatus,
			"seen_non_available": seenNonAvailable,
		})

		model.Status = types.StringValue(currentStatus)
		if bg.Target != nil {
			model.GreenClusterARN = types.StringValue(awsStringValue(bg.Target))
		}

		if currentStatus != bgStatusAvailable {
			seenNonAvailable = true
		}

		if hardFailures[currentStatus] {
			diags.AddError(
				"Deployment reached failure status",
				fmt.Sprintf("Deployment %s is %s. Check the AWS Console for details.", deploymentID, currentStatus),
			)
			return diags
		}

		// AVAILABLE after the switchover has started = AWS abandoned and reverted.
		if targetStatus == bgStatusSwitchoverCompleted && currentStatus == bgStatusAvailable && seenNonAvailable {
			diags.AddError(
				"Switchover abandoned",
				fmt.Sprintf("Deployment %s reverted to AVAILABLE after switchover started — AWS abandoned the operation. Check RDS Events in the AWS Console.", deploymentID),
			)
			return diags
		}

		if currentStatus == targetStatus {
			tflog.Info(ctx, "Reached target status", map[string]any{
				"deployment_id": deploymentID,
				"status":        targetStatus,
			})
			return diags
		}

		select {
		case <-ctx.Done():
			diags.AddError("Context cancelled", "Terraform context was cancelled during polling")
			return diags
		case <-time.After(30 * time.Second):
		}
	}

	diags.AddError(
		"Timeout",
		fmt.Sprintf("Deployment %s did not reach %s within the timeout", deploymentID, targetStatus),
	)
	return diags
}

// flipProxy deregisters the current cluster target(s) from the proxy and
// registers the given targetClusterID. Idempotent: no-op if proxy already
// points to targetClusterID.
func (r *BlueGreenDeploymentResource) flipProxy(ctx context.Context, proxyName, targetClusterID string) diag.Diagnostics {
	var diags diag.Diagnostics

	targetsOut, err := r.clients.RDS.DescribeDBProxyTargets(ctx, &rds.DescribeDBProxyTargetsInput{
		DBProxyName:     aws.String(proxyName),
		TargetGroupName: aws.String("default"),
	})
	if err != nil {
		diags.AddError(
			"Failed to describe proxy targets",
			fmt.Sprintf("Error describing targets for proxy %s: %s", proxyName, err.Error()),
		)
		return diags
	}

	// Deregister existing cluster targets. Skip if already pointing to target.
	for _, target := range targetsOut.Targets {
		if target.Type != rdstypes.TargetTypeTrackedCluster {
			continue
		}
		currentClusterID := awsStringValue(target.RdsResourceId)
		if currentClusterID == targetClusterID {
			tflog.Info(ctx, "Proxy already routes to target cluster — skipping flip", map[string]any{
				"proxy_name":        proxyName,
				"target_cluster_id": targetClusterID,
			})
			return diags
		}
		tflog.Info(ctx, "Deregistering proxy target", map[string]any{
			"proxy_name": proxyName,
			"cluster_id": currentClusterID,
		})
		_, deregErr := r.clients.RDS.DeregisterDBProxyTargets(ctx, &rds.DeregisterDBProxyTargetsInput{
			DBProxyName:          aws.String(proxyName),
			DBClusterIdentifiers: []string{currentClusterID},
		})
		if deregErr != nil && !isNotFoundError(deregErr) {
			diags.AddError(
				"Failed to deregister proxy target",
				fmt.Sprintf("Error deregistering cluster %s from proxy %s: %s", currentClusterID, proxyName, deregErr.Error()),
			)
			return diags
		}
	}

	// Register the target cluster.
	_, regErr := r.clients.RDS.RegisterDBProxyTargets(ctx, &rds.RegisterDBProxyTargetsInput{
		DBProxyName:          aws.String(proxyName),
		TargetGroupName:      aws.String("default"),
		DBClusterIdentifiers: []string{targetClusterID},
	})
	if regErr != nil {
		diags.AddError(
			"Failed to register proxy target",
			fmt.Sprintf("Error registering cluster %s with proxy %s: %s", targetClusterID, proxyName, regErr.Error()),
		)
		return diags
	}

	return diags
}

// deleteClusterAndInstances deletes all instances in the given cluster, waits
// for each instance to be deleted, then deletes the cluster itself.
func (r *BlueGreenDeploymentResource) deleteClusterAndInstances(ctx context.Context, clusterID string) diag.Diagnostics {
	var diags diag.Diagnostics

	tflog.Info(ctx, "Deleting cluster instances before cluster deletion", map[string]any{
		"cluster_id": clusterID,
	})

	instancesOut, instancesErr := r.clients.RDS.DescribeDBInstances(ctx, &rds.DescribeDBInstancesInput{
		Filters: []rdstypes.Filter{
			{
				Name:   aws.String("db-cluster-id"),
				Values: []string{clusterID},
			},
		},
	})
	if instancesErr != nil && !isNotFoundError(instancesErr) {
		diags.AddError(
			"Failed to describe cluster instances",
			fmt.Sprintf("Error listing instances for cluster %s: %s", clusterID, instancesErr.Error()),
		)
		return diags
	}

	if instancesOut != nil {
		for _, instance := range instancesOut.DBInstances {
			instanceID := awsStringValue(instance.DBInstanceIdentifier)
			tflog.Info(ctx, "Deleting cluster instance", map[string]any{
				"instance_id": instanceID,
				"cluster_id":  clusterID,
			})

			_, delInstanceErr := r.clients.RDS.DeleteDBInstance(ctx, &rds.DeleteDBInstanceInput{
				DBInstanceIdentifier: aws.String(instanceID),
				SkipFinalSnapshot:    aws.Bool(true),
			})
			if delInstanceErr != nil && !isNotFoundError(delInstanceErr) {
				diags.AddError(
					"Failed to delete cluster instance",
					fmt.Sprintf("Error deleting instance %s: %s", instanceID, delInstanceErr.Error()),
				)
				return diags
			}
		}

		if len(instancesOut.DBInstances) > 0 {
			tflog.Info(ctx, "Waiting for cluster instances to be deleted", map[string]any{
				"cluster_id":     clusterID,
				"instance_count": len(instancesOut.DBInstances),
			})
			waitDiags := r.waitForInstancesDeletion(ctx, clusterID, 30*time.Minute)
			diags.Append(waitDiags...)
			if diags.HasError() {
				return diags
			}
		}
	}

	_, delClusterErr := r.clients.RDS.DeleteDBCluster(ctx, &rds.DeleteDBClusterInput{
		DBClusterIdentifier: aws.String(clusterID),
		SkipFinalSnapshot:   aws.Bool(false),
	})
	if delClusterErr != nil && !isNotFoundError(delClusterErr) {
		diags.AddError(
			"Failed to delete old blue cluster",
			fmt.Sprintf("Error deleting cluster %s: %s", clusterID, delClusterErr.Error()),
		)
		return diags
	}

	tflog.Info(ctx, "Old blue cluster deleted", map[string]any{
		"cluster_id": clusterID,
	})

	return diags
}

// waitForInstancesDeletion polls until all instances in the given cluster are deleted.
func (r *BlueGreenDeploymentResource) waitForInstancesDeletion(ctx context.Context, clusterID string, timeout time.Duration) diag.Diagnostics {
	var diags diag.Diagnostics
	deadline := time.Now().Add(timeout)

	for time.Now().Before(deadline) {
		instancesOut, instancesErr := r.clients.RDS.DescribeDBInstances(ctx, &rds.DescribeDBInstancesInput{
			Filters: []rdstypes.Filter{
				{
					Name:   aws.String("db-cluster-id"),
					Values: []string{clusterID},
				},
			},
		})

		if instancesErr != nil {
			if isNotFoundError(instancesErr) {
				return diags
			}
			diags.AddError(
				"Error polling instance deletion",
				fmt.Sprintf("Error describing instances for cluster %s: %s", clusterID, instancesErr.Error()),
			)
			return diags
		}

		if instancesOut == nil || len(instancesOut.DBInstances) == 0 {
			tflog.Info(ctx, "All cluster instances deleted", map[string]any{
				"cluster_id": clusterID,
			})
			return diags
		}

		tflog.Info(ctx, "Waiting for cluster instances to be deleted", map[string]any{
			"cluster_id":               clusterID,
			"remaining_instance_count": len(instancesOut.DBInstances),
		})

		select {
		case <-ctx.Done():
			diags.AddError("Context cancelled", "Terraform context was cancelled while waiting for instance deletion")
			return diags
		case <-time.After(30 * time.Second):
		}
	}

	diags.AddError(
		"Timeout",
		fmt.Sprintf("Instances in cluster %s were not deleted within the timeout", clusterID),
	)
	return diags
}

// reattachAutoScaling re-registers the scalable target and scaling policy
// after switchover (AWS removes it during the cluster swap).
func (r *BlueGreenDeploymentResource) reattachAutoScaling(ctx context.Context, plan BlueGreenDeploymentModel) diag.Diagnostics {
	var diags diag.Diagnostics
	var asCfg AutoScalingConfigModel

	diags.Append(plan.AutoScalingConfig.As(ctx, &asCfg, basetypes.ObjectAsOptions{
		UnhandledNullAsEmpty:    true,
		UnhandledUnknownAsEmpty: true,
	})...)
	if diags.HasError() {
		return diags
	}

	// After switchover the production cluster keeps the original cluster identifier.
	clusterID := clusterIDFromARN(plan.SourceClusterARN.ValueString())
	resourceID := "cluster:" + clusterID

	scaleInCooldown := int32(300)
	if !asCfg.ScaleInCooldown.IsNull() {
		scaleInCooldown = int32(asCfg.ScaleInCooldown.ValueInt64())
	}
	scaleOutCooldown := int32(300)
	if !asCfg.ScaleOutCooldown.IsNull() {
		scaleOutCooldown = int32(asCfg.ScaleOutCooldown.ValueInt64())
	}

	_, err := r.clients.AutoScaling.RegisterScalableTarget(ctx, &applicationautoscaling.RegisterScalableTargetInput{
		ServiceNamespace:  astypes.ServiceNamespaceRds,
		ResourceId:        aws.String(resourceID),
		ScalableDimension: astypes.ScalableDimensionRDSClusterReadReplicaCount,
		MinCapacity:       aws.Int32(int32(asCfg.MinCapacity.ValueInt64())),
		MaxCapacity:       aws.Int32(int32(asCfg.MaxCapacity.ValueInt64())),
	})
	if err != nil {
		diags.AddError(
			"Failed to register scalable target",
			fmt.Sprintf("Error registering Auto Scaling for %s: %s", clusterID, err.Error()),
		)
		return diags
	}

	tflog.Info(ctx, "Registered scalable target", map[string]any{"resource_id": resourceID})

	_, err = r.clients.AutoScaling.PutScalingPolicy(ctx, &applicationautoscaling.PutScalingPolicyInput{
		PolicyName:        aws.String(asCfg.PolicyName.ValueString()),
		ServiceNamespace:  astypes.ServiceNamespaceRds,
		ResourceId:        aws.String(resourceID),
		ScalableDimension: astypes.ScalableDimensionRDSClusterReadReplicaCount,
		PolicyType:        astypes.PolicyTypeTargetTrackingScaling,
		TargetTrackingScalingPolicyConfiguration: &astypes.TargetTrackingScalingPolicyConfiguration{
			TargetValue: aws.Float64(asCfg.TargetCPU.ValueFloat64()),
			PredefinedMetricSpecification: &astypes.PredefinedMetricSpecification{
				PredefinedMetricType: astypes.MetricTypeRDSReaderAverageCPUUtilization,
			},
			ScaleInCooldown:  aws.Int32(scaleInCooldown),
			ScaleOutCooldown: aws.Int32(scaleOutCooldown),
		},
	})
	if err != nil {
		diags.AddError(
			"Failed to put scaling policy",
			fmt.Sprintf("Error applying Auto Scaling policy to %s: %s", clusterID, err.Error()),
		)
		return diags
	}

	tflog.Info(ctx, "Auto Scaling policy re-attached", map[string]any{
		"policy_name": asCfg.PolicyName.ValueString(),
		"cluster_id":  clusterID,
	})

	return diags
}

// clusterIDFromARN extracts the cluster identifier from an RDS ARN.
// Format: arn:aws:rds:region:account:cluster:cluster-id
func clusterIDFromARN(arn string) string {
	parts := strings.Split(arn, ":")
	if len(parts) > 0 {
		return parts[len(parts)-1]
	}
	return arn
}

// isNotFoundError returns true when an AWS error indicates the resource does not exist.
func isNotFoundError(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "NotFound") ||
		strings.Contains(msg, "not found") ||
		strings.Contains(msg, "does not exist") ||
		strings.Contains(msg, "No Blue Green Deployment found")
}
