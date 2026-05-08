// internal/provider/provider.go
// Defines the aurora-bluegreen provider: configuration schema + AWS client setup.

package provider

import (
	"context"
	"os"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/credentials/stscreds"
	"github.com/aws/aws-sdk-go-v2/service/applicationautoscaling"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	"github.com/hashicorp/terraform-plugin-framework/datasource"
	"github.com/hashicorp/terraform-plugin-framework/provider"
	"github.com/hashicorp/terraform-plugin-framework/provider/schema"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/types"
	"github.com/hashicorp/terraform-plugin-log/tflog"
)

// AWSClients bundles the RDS + AppAutoScaling SDK clients.
// Passed to each resource via providerData.
type AWSClients struct {
	RDS         *rds.Client
	AutoScaling *applicationautoscaling.Client
	Region      string
}

// AuroraBlueGreenProvider is the root provider struct.
type AuroraBlueGreenProvider struct {
	version string
}

// AuroraBlueGreenProviderModel mirrors the HCL provider block attributes.
type AuroraBlueGreenProviderModel struct {
	Region        types.String `tfsdk:"region"`
	AccessKey     types.String `tfsdk:"access_key"`
	SecretKey     types.String `tfsdk:"secret_key"`
	AssumeRoleArn types.String `tfsdk:"assume_role_arn"`
}

func New(version string) func() provider.Provider {
	return func() provider.Provider {
		return &AuroraBlueGreenProvider{version: version}
	}
}

func (p *AuroraBlueGreenProvider) Metadata(_ context.Context, _ provider.MetadataRequest, resp *provider.MetadataResponse) {
	resp.TypeName = "aurora-bluegreen"
	resp.Version = p.version
}

func (p *AuroraBlueGreenProvider) Schema(_ context.Context, _ provider.SchemaRequest, resp *provider.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description: "Manages Aurora MySQL Blue/Green Deployments via the AWS RDS API. " +
			"Provides proper Terraform state management for the blue/green lifecycle — " +
			"no null_resource hacks, no state drift between CI runners.",
		Attributes: map[string]schema.Attribute{
			"region": schema.StringAttribute{
				Description: "AWS region. Falls back to AWS_REGION / AWS_DEFAULT_REGION env vars.",
				Optional:    true,
			},
			"access_key": schema.StringAttribute{
				Description: "AWS access key. Falls back to AWS_ACCESS_KEY_ID env var or IAM role.",
				Optional:    true,
				Sensitive:   true,
			},
			"secret_key": schema.StringAttribute{
				Description: "AWS secret key. Falls back to AWS_SECRET_ACCESS_KEY env var or IAM role.",
				Optional:    true,
				Sensitive:   true,
			},
			"assume_role_arn": schema.StringAttribute{
				Description: "Optional ARN of an IAM role to assume (for cross-account access).",
				Optional:    true,
			},
		},
	}
}

func (p *AuroraBlueGreenProvider) Configure(ctx context.Context, req provider.ConfigureRequest, resp *provider.ConfigureResponse) {
	var data AuroraBlueGreenProviderModel
	resp.Diagnostics.Append(req.Config.Get(ctx, &data)...)
	if resp.Diagnostics.HasError() {
		return
	}

	// Resolve region: config → env var → default
	region := data.Region.ValueString()
	if region == "" {
		region = os.Getenv("AWS_REGION")
	}
	if region == "" {
		region = os.Getenv("AWS_DEFAULT_REGION")
	}
	if region == "" {
		region = "us-east-1"
	}

	tflog.Info(ctx, "Configuring aurora-bluegreen provider", map[string]any{
		"region": region,
	})

	// Build AWS SDK config options
	cfgOpts := []func(*config.LoadOptions) error{
		config.WithRegion(region),
	}

	// Explicit static credentials (optional — prefers env vars / IAM role if not set)
	if !data.AccessKey.IsNull() && !data.AccessKey.IsUnknown() &&
		!data.SecretKey.IsNull() && !data.SecretKey.IsUnknown() &&
		data.AccessKey.ValueString() != "" {
		cfgOpts = append(cfgOpts, config.WithCredentialsProvider(
			credentials.NewStaticCredentialsProvider(
				data.AccessKey.ValueString(),
				data.SecretKey.ValueString(),
				"",
			),
		))
	}

	awsCfg, err := config.LoadDefaultConfig(ctx, cfgOpts...)
	if err != nil {
		resp.Diagnostics.AddError(
			"Failed to configure AWS SDK",
			"Error loading AWS config: "+err.Error(),
		)
		return
	}

	// Role assumption — creates a new credential chain that calls STS AssumeRole
	if !data.AssumeRoleArn.IsNull() && data.AssumeRoleArn.ValueString() != "" {
		roleARN := data.AssumeRoleArn.ValueString()
		tflog.Info(ctx, "Assuming IAM role", map[string]any{"arn": roleARN})

		stsClient := sts.NewFromConfig(awsCfg)
		awsCfg.Credentials = aws.NewCredentialsCache(
			stscreds.NewAssumeRoleProvider(stsClient, roleARN),
		)
	}

	clients := &AWSClients{
		RDS:         rds.NewFromConfig(awsCfg),
		AutoScaling: applicationautoscaling.NewFromConfig(awsCfg),
		Region:      region,
	}

	resp.DataSourceData = clients
	resp.ResourceData = clients
}

func (p *AuroraBlueGreenProvider) Resources(_ context.Context) []func() resource.Resource {
	return []func() resource.Resource{
		NewBlueGreenDeploymentResource,
	}
}

func (p *AuroraBlueGreenProvider) DataSources(_ context.Context) []func() datasource.DataSource {
	return []func() datasource.DataSource{}
}

// awsStringValue safely dereferences a *string from the AWS SDK.
func awsStringValue(s *string) string {
	if s == nil {
		return ""
	}
	return aws.ToString(s)
}
