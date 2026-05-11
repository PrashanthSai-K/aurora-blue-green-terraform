// internal/provider/resource_blue_green_deployment.go
//
// Full CRUD lifecycle for an Aurora Blue/Green Deployment:
//
//   Create → CreateBlueGreenDeployment + poll until AVAILABLE
//   Read   → DescribeBlueGreenDeployments (drift detection on every plan)
//            Skipped when deployment_deleted=true (B/G object already deleted)
//   Update → SwitchoverBlueGreenDeployment when trigger_switchover flips true
//            + re-attaches Auto Scaling policy post-switchover
//            + populates old_source_cluster_id after switchover
//            + optionally sets replication_status = SETUP_PENDING
//            + flips RDS Proxy target when proxy_active_cluster changes
//            + deletes B/G deployment object when delete_deployment_after_switchover flips true (keeps clusters)
//            + name-swap rollback when trigger_rollback flips true:
//                renames new prod → <orig>-new1
//                renames old blue → <orig>  (restores original endpoint)
//            + deletes old blue cluster when delete_old_cluster flips true
//   Delete → guards against destroying while proxy routes to old cluster
//            + optionally deletes old blue cluster (retain_old_cluster=false)
//            + DeleteBlueGreenDeployment (skipped when deployment_deleted=true)
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

	// Suffix appended to the new prod cluster during name-swap rollback.
	rollbackNewClusterSuffix = "-new1"
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
	EnableReverseReplication types.Bool   `tfsdk:"enable_reverse_replication"`
	ReplicationStatus        types.String `tfsdk:"replication_status"`

	// Proxy-based rollback control.
	RDSProxyName       types.String `tfsdk:"rds_proxy_name"`
	ProxyActiveCluster types.String `tfsdk:"proxy_active_cluster"`

	// Set true to delete the old blue cluster immediately via Update().
	DeleteOldCluster types.Bool `tfsdk:"delete_old_cluster"`

	// ── Name-swap rollback ────────────────────────────────────────────────────
	// delete_deployment_after_switchover: deletes the B/G deployment object after
	// switchover completes, keeping both clusters intact. Required before trigger_rollback.
	DeleteDeploymentAfterSwitchover types.Bool `tfsdk:"delete_deployment_after_switchover"`

	// deployment_deleted: computed true once the B/G deployment object is deleted.
	// Read() skips DescribeBlueGreenDeployments when this is true.
	DeploymentDeleted types.Bool `tfsdk:"deployment_deleted"`

	// trigger_rollback: when flipped to true, performs name-swap rollback:
	//   1. Rename new prod (<orig>) → <orig>-new1
	//   2. Rename old blue (<orig>-old1) → <orig>   (restores original endpoint)
	// MySQL pre-flight (lag=0, read-only) must be done by GitHub Actions before applying.
	TriggerRollback types.Bool `tfsdk:"trigger_rollback"`

	// rollback_completed: computed true once name-swap rollback finishes.
	// After this, delete_old_cluster=true removes the <orig>-new1 cluster.
	RollbackCompleted types.Bool `tfsdk:"rollback_completed"`
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
			"Creates the green cluster, handles switchover, deletes the B/G deployment object, " +
			"and supports name-swap rollback to restore the original cluster endpoint.",

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
				Description: "Cluster ID of the old blue cluster after switchover. Used for rollback.",
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
				Description: "Signals that binlog replication should be set up. " +
					"When true, provider sets replication_status = SETUP_PENDING after switchover. " +
					"Actual replication SQL is handled by GitHub Actions (enable_replication.sh).",
			},

			"replication_status": schema.StringAttribute{
				Computed:    true,
				Description: "One of: NOT_CONFIGURED / SETUP_PENDING / ACTIVE / STOPPED.",
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
				Description: "Which cluster the RDS Proxy routes to: \"new\" (current production) or \"old\" (rollback). Requires rds_proxy_name.",
			},

			// ── On-demand old cluster deletion ────────────────────────────
			"delete_old_cluster": schema.BoolAttribute{
				Optional:    true,
				Computed:    true,
				Default:     booldefault.StaticBool(false),
				Description: "Set true to delete the old cluster immediately (without destroying this resource). " +
					"After name-swap rollback this deletes the <orig>-new1 cluster.",
			},

			// ── Name-swap rollback ────────────────────────────────────────
			"delete_deployment_after_switchover": schema.BoolAttribute{
				Optional:    true,
				Computed:    true,
				Default:     booldefault.StaticBool(false),
				Description: "Delete the B/G deployment object after switchover completes, keeping both clusters intact. " +
					"Set true before trigger_rollback so the deployment object does not interfere with cluster renames.",
			},

			"deployment_deleted": schema.BoolAttribute{
				Computed:    true,
				Description: "True once the B/G deployment object has been deleted. Read() skips DescribeBlueGreenDeployments when true.",
			},

			"trigger_rollback": schema.BoolAttribute{
				Optional:    true,
				Computed:    true,
				Default:     booldefault.StaticBool(false),
				Description: "Trigger name-swap rollback. " +
					"Step 1: rename new prod (<orig>) → <orig>-new1. " +
					"Step 2: rename old blue (<orig>-old1) → <orig> (restores original endpoint). " +
					"Run GitHub Actions pre-flight (lag=0 + read-only) BEFORE setting this to true. " +
					"After rollback completes, set delete_old_cluster=true to remove the <orig>-new1 cluster.",
			},

			"rollback_completed": schema.BoolAttribute{
				Computed:    true,
				Description: "True after name-swap rollback finishes successfully. The original cluster endpoint is restored.",
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
	plan.DeleteDeploymentAfterSwitchover = types.BoolValue(false)
	plan.DeploymentDeleted = types.BoolValue(false)
	plan.TriggerRollback = types.BoolValue(false)
	plan.RollbackCompleted = types.BoolValue(false)

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
// Skipped when deployment_deleted=true.
// ─────────────────────────────────────────────────────────────

func (r *BlueGreenDeploymentResource) Read(ctx context.Context, req resource.ReadRequest, resp *resource.ReadResponse) {
	var state BlueGreenDeploymentModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	// B/G deployment object was deleted — clusters are managed independently.
	// Skip the Describe call; keep state as-is so rollback flags remain usable.
	if state.DeploymentDeleted.ValueBool() {
		tflog.Debug(ctx, "deployment_deleted=true — skipping DescribeBlueGreenDeployments")
		resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
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

	if state.SourceClusterARN.IsNull() || state.SourceClusterARN.ValueString() == "" {
		if bg.Source != nil {
			state.SourceClusterARN = types.StringValue(*bg.Source)
		}
	}

	if bg.Target != nil {
		state.GreenClusterARN = types.StringValue(*bg.Target)

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

	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}

// ─────────────────────────────────────────────────────────────
// UPDATE
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

	// ── Section 1: Forward switchover ────────────────────────────────────────
	if plan.TriggerSwitchover.ValueBool() && !alreadyCompleted && !state.DeploymentDeleted.ValueBool() {
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

	// ── Section 2: Post-switchover actions ───────────────────────────────────
	if state.Status.ValueString() == bgStatusSwitchoverCompleted && !state.DeploymentDeleted.ValueBool() {
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

	// ── Section 3: Delete B/G deployment object ──────────────────────────────
	// Deletes the AWS B/G deployment record after switchover. Both clusters are
	// kept intact. Required before trigger_rollback so renames are unambiguous.
	if plan.DeleteDeploymentAfterSwitchover.ValueBool() && !state.DeploymentDeleted.ValueBool() {
		if state.Status.ValueString() != bgStatusSwitchoverCompleted {
			resp.Diagnostics.AddError(
				"Cannot delete B/G deployment object before switchover completes",
				fmt.Sprintf("Current status: %s. Set trigger_switchover=true and apply first.", state.Status.ValueString()),
			)
			return
		}

		tflog.Info(ctx, "Deleting B/G deployment object (keeping both clusters)", map[string]any{
			"deployment_id": deploymentID,
		})

		_, err := r.clients.RDS.DeleteBlueGreenDeployment(ctx, &rds.DeleteBlueGreenDeploymentInput{
			BlueGreenDeploymentIdentifier: aws.String(deploymentID),
			// DeleteTarget=false (default) keeps both clusters.
		})
		if err != nil && !isNotFoundError(err) {
			resp.Diagnostics.AddError(
				"Failed to delete B/G deployment object",
				fmt.Sprintf("Error deleting %s: %s", deploymentID, err.Error()),
			)
			return
		}

		state.DeploymentDeleted = types.BoolValue(true)
		resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
		if resp.Diagnostics.HasError() {
			return
		}
		tflog.Info(ctx, "B/G deployment object deleted, both clusters retained", map[string]any{
			"deployment_id":      deploymentID,
			"old_cluster_id":     state.OldSourceClusterID.ValueString(),
		})
	}

	// ── Section 4: Name-swap rollback ────────────────────────────────────────
	// Restores the original cluster endpoint by renaming:
	//   new prod (<orig>)      → <orig>-new1
	//   old blue (<orig>-old1) → <orig>
	//
	// GitHub Actions MUST run pre-flight (read-only + lag=0) before this apply.
	if plan.TriggerRollback.ValueBool() && !state.RollbackCompleted.ValueBool() {
		oldClusterID := state.OldSourceClusterID.ValueString()
		if oldClusterID == "" {
			resp.Diagnostics.AddError(
				"Cannot trigger rollback",
				"old_source_cluster_id is empty — switchover must complete before rolling back.",
			)
			return
		}

		origClusterID := clusterIDFromARN(state.SourceClusterARN.ValueString())
		newClusterTempID := origClusterID + rollbackNewClusterSuffix

		tflog.Info(ctx, "Starting name-swap rollback", map[string]any{
			"orig_cluster_id":  origClusterID,
			"old_cluster_id":   oldClusterID,
			"temp_cluster_id":  newClusterTempID,
		})

		// Step 1: rename new prod → <orig>-new1 (endpoint goes dark briefly)
		tflog.Info(ctx, "Step 1: renaming new prod cluster", map[string]any{
			"from": origClusterID, "to": newClusterTempID,
		})
		resp.Diagnostics.Append(r.renameCluster(ctx, origClusterID, newClusterTempID)...)
		if resp.Diagnostics.HasError() {
			return
		}

		// Step 2: rename old blue → <orig> (endpoint restored)
		tflog.Info(ctx, "Step 2: renaming old blue cluster to original name", map[string]any{
			"from": oldClusterID, "to": origClusterID,
		})
		resp.Diagnostics.Append(r.renameCluster(ctx, oldClusterID, origClusterID)...)
		if resp.Diagnostics.HasError() {
			return
		}

		// After rollback: <orig>-new1 is now the cluster to delete.
		// Reuse old_source_cluster_id to point at it so delete_old_cluster=true works.
		state.OldSourceClusterID = types.StringValue(newClusterTempID)
		state.RollbackCompleted = types.BoolValue(true)
		state.TriggerRollback = types.BoolValue(true)

		resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
		if resp.Diagnostics.HasError() {
			return
		}

		tflog.Info(ctx, "Name-swap rollback complete — original endpoint restored", map[string]any{
			"restored_cluster":    origClusterID,
			"pending_delete":      newClusterTempID,
		})
	}

	// ── Section 5: Proxy flip ─────────────────────────────────────────────────
	if !plan.ProxyActiveCluster.Equal(state.ProxyActiveCluster) {
		proxyName := plan.RDSProxyName.ValueString()
		if proxyName == "" {
			proxyName = state.RDSProxyName.ValueString()
		}
		if proxyName == "" {
			resp.Diagnostics.AddError(
				"rds_proxy_name required for proxy flip",
				"rds_proxy_name must be set to use proxy_active_cluster.",
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

		if wantCluster == proxyClusterOld {
			state.ReplicationStatus = types.StringValue(replStatusStopped)
		}

		resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
		if resp.Diagnostics.HasError() {
			return
		}

		tflog.Info(ctx, "Proxy flip complete", map[string]any{
			"proxy_name":        proxyName,
			"target_cluster_id": targetClusterID,
		})
	}

	// ── Section 6: Delete old cluster on demand ───────────────────────────────
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
			tflog.Info(ctx, "delete_old_cluster=true — deleting cluster", map[string]any{
				"cluster_id": oldClusterID,
			})
			resp.Diagnostics.Append(r.deleteClusterAndInstances(ctx, oldClusterID)...)
			if resp.Diagnostics.HasError() {
				resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
				return
			}
			state.OldSourceClusterID = types.StringNull()
			tflog.Info(ctx, "Cluster deleted", map[string]any{"cluster_id": oldClusterID})
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
	state.DeleteDeploymentAfterSwitchover = plan.DeleteDeploymentAfterSwitchover
	if plan.ProxyActiveCluster.Equal(state.ProxyActiveCluster) {
		// Already in sync — no-op.
	}
	if !state.DeleteOldCluster.ValueBool() {
		state.DeleteOldCluster = plan.DeleteOldCluster
	}

	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}

// ─────────────────────────────────────────────────────────────
// DELETE
// ─────────────────────────────────────────────────────────────

func (r *BlueGreenDeploymentResource) Delete(ctx context.Context, req resource.DeleteRequest, resp *resource.DeleteResponse) {
	var state BlueGreenDeploymentModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	deploymentID := state.DeploymentID.ValueString()

	currentProxy := state.ProxyActiveCluster.ValueString()
	if currentProxy == proxyClusterOld {
		resp.Diagnostics.AddError(
			"Cannot destroy while proxy routes to old cluster",
			"Set proxy_active_cluster=\"new\" and run terraform apply before running terraform destroy.",
		)
		return
	}

	tflog.Info(ctx, "Deleting Blue/Green deployment resource", map[string]any{
		"deployment_id":      deploymentID,
		"deployment_deleted": state.DeploymentDeleted.ValueBool(),
		"retain_old_cluster": state.RetainOldCluster.ValueBool(),
	})

	// Delete old blue cluster if retain_old_cluster=false.
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

	// Skip if deployment object was already deleted via delete_deployment_after_switchover.
	if state.DeploymentDeleted.ValueBool() {
		tflog.Info(ctx, "deployment_deleted=true — B/G deployment object already deleted, skipping API call")
		return
	}

	input := &rds.DeleteBlueGreenDeploymentInput{
		BlueGreenDeploymentIdentifier: aws.String(deploymentID),
	}
	if state.DeleteSourceCluster.ValueBool() {
		input.DeleteTarget = aws.Bool(true)
	}

	_, err := r.clients.RDS.DeleteBlueGreenDeployment(ctx, input)
	if err != nil {
		if isNotFoundError(err) {
			tflog.Info(ctx, "Deployment already deleted", map[string]any{"deployment_id": deploymentID})
			return
		}
		resp.Diagnostics.AddError(
			"Failed to delete Blue/Green Deployment",
			fmt.Sprintf("Error deleting %s: %s", deploymentID, err.Error()),
		)
		return
	}

	tflog.Info(ctx, "Blue/Green deployment deleted", map[string]any{"deployment_id": deploymentID})
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
		ID:                              types.StringValue(req.ID),
		DeploymentID:                    types.StringValue(req.ID),
		TriggerSwitchover:               types.BoolValue(false),
		DeleteSourceCluster:             types.BoolValue(false),
		CreateTimeoutMinutes:            types.Int64Value(90),
		SwitchoverTimeoutSec:            types.Int64Value(300),
		AutoScalingConfig:               types.ObjectNull(autoScalingAttrTypes),
		OldSourceClusterID:              types.StringNull(),
		RetainOldCluster:                types.BoolValue(true),
		EnableReverseReplication:        types.BoolValue(false),
		ReplicationStatus:               types.StringValue(replStatusNotConfigured),
		RDSProxyName:                    types.StringNull(),
		ProxyActiveCluster:              types.StringValue(proxyClusterNew),
		DeleteOldCluster:                types.BoolValue(false),
		DeleteDeploymentAfterSwitchover: types.BoolValue(false),
		DeploymentDeleted:               types.BoolValue(false),
		TriggerRollback:                 types.BoolValue(false),
		RollbackCompleted:               types.BoolValue(false),
	}

	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}

// ─────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────

// waitForStatus polls until targetStatus or timeout.
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
			"deployment_id":  deploymentID,
			"current_status": currentStatus,
			"target_status":  targetStatus,
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

		if targetStatus == bgStatusSwitchoverCompleted && currentStatus == bgStatusAvailable && seenNonAvailable {
			diags.AddError(
				"Switchover abandoned",
				fmt.Sprintf("Deployment %s reverted to AVAILABLE — AWS abandoned the operation. Check RDS Events.", deploymentID),
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

// renameCluster calls ModifyDBCluster with a new identifier and waits for
// the cluster to become available under the new name.
func (r *BlueGreenDeploymentResource) renameCluster(ctx context.Context, currentID, newID string) diag.Diagnostics {
	var diags diag.Diagnostics

	tflog.Info(ctx, "Renaming Aurora cluster", map[string]any{"from": currentID, "to": newID})

	_, err := r.clients.RDS.ModifyDBCluster(ctx, &rds.ModifyDBClusterInput{
		DBClusterIdentifier:    aws.String(currentID),
		NewDBClusterIdentifier: aws.String(newID),
		ApplyImmediately:       aws.Bool(true),
	})
	if err != nil {
		diags.AddError(
			"Failed to rename cluster",
			fmt.Sprintf("ModifyDBCluster %s → %s: %s", currentID, newID, err.Error()),
		)
		return diags
	}

	tflog.Info(ctx, "Cluster rename initiated, waiting for available", map[string]any{"new_id": newID})
	diags.Append(r.waitForClusterAvailable(ctx, newID, 15*time.Minute)...)
	return diags
}

// waitForClusterAvailable polls DescribeDBClusters until the cluster
// reaches "available" status under the given identifier.
func (r *BlueGreenDeploymentResource) waitForClusterAvailable(ctx context.Context, clusterID string, timeout time.Duration) diag.Diagnostics {
	var diags diag.Diagnostics
	deadline := time.Now().Add(timeout)

	for time.Now().Before(deadline) {
		out, err := r.clients.RDS.DescribeDBClusters(ctx, &rds.DescribeDBClustersInput{
			DBClusterIdentifier: aws.String(clusterID),
		})
		if err == nil && len(out.DBClusters) > 0 {
			status := awsStringValue(out.DBClusters[0].Status)
			tflog.Info(ctx, "Polling cluster availability", map[string]any{
				"cluster_id": clusterID, "status": status,
			})
			if status == "available" {
				return diags
			}
		}

		select {
		case <-ctx.Done():
			diags.AddError("Context cancelled", fmt.Sprintf("cancelled while waiting for cluster %s to become available", clusterID))
			return diags
		case <-time.After(15 * time.Second):
		}
	}

	diags.AddError(
		"Timeout",
		fmt.Sprintf("Cluster %s did not become available within %s after rename", clusterID, timeout),
	)
	return diags
}

// flipProxy deregisters current cluster targets and registers targetClusterID.
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
			"proxy_name": proxyName, "cluster_id": currentClusterID,
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

// deleteClusterAndInstances deletes all instances then the cluster itself.
func (r *BlueGreenDeploymentResource) deleteClusterAndInstances(ctx context.Context, clusterID string) diag.Diagnostics {
	var diags diag.Diagnostics

	tflog.Info(ctx, "Deleting cluster instances before cluster deletion", map[string]any{"cluster_id": clusterID})

	instancesOut, instancesErr := r.clients.RDS.DescribeDBInstances(ctx, &rds.DescribeDBInstancesInput{
		Filters: []rdstypes.Filter{
			{Name: aws.String("db-cluster-id"), Values: []string{clusterID}},
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
				"instance_id": instanceID, "cluster_id": clusterID,
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
				"cluster_id": clusterID, "instance_count": len(instancesOut.DBInstances),
			})
			diags.Append(r.waitForInstancesDeletion(ctx, clusterID, 30*time.Minute)...)
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
			"Failed to delete cluster",
			fmt.Sprintf("Error deleting cluster %s: %s", clusterID, delClusterErr.Error()),
		)
		return diags
	}

	tflog.Info(ctx, "Cluster deleted", map[string]any{"cluster_id": clusterID})
	return diags
}

// waitForInstancesDeletion polls until all instances in the cluster are gone.
func (r *BlueGreenDeploymentResource) waitForInstancesDeletion(ctx context.Context, clusterID string, timeout time.Duration) diag.Diagnostics {
	var diags diag.Diagnostics
	deadline := time.Now().Add(timeout)

	for time.Now().Before(deadline) {
		instancesOut, instancesErr := r.clients.RDS.DescribeDBInstances(ctx, &rds.DescribeDBInstancesInput{
			Filters: []rdstypes.Filter{
				{Name: aws.String("db-cluster-id"), Values: []string{clusterID}},
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
			tflog.Info(ctx, "All cluster instances deleted", map[string]any{"cluster_id": clusterID})
			return diags
		}

		tflog.Info(ctx, "Waiting for cluster instances to be deleted", map[string]any{
			"cluster_id":               clusterID,
			"remaining_instance_count": len(instancesOut.DBInstances),
		})

		select {
		case <-ctx.Done():
			diags.AddError("Context cancelled", "cancelled while waiting for instance deletion")
			return diags
		case <-time.After(30 * time.Second):
		}
	}

	diags.AddError("Timeout", fmt.Sprintf("Instances in cluster %s were not deleted within the timeout", clusterID))
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

