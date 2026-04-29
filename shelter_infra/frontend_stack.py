import aws_cdk as cdk
from aws_cdk import (
    CfnOutput,
    Stack,
    aws_cloudfront as cloudfront,
    aws_cloudfront_origins as origins,
    aws_iam as iam,
    aws_s3 as s3,
)
from constructs import Construct

GITHUB_ORG = "Anchellon"
FRONTEND_REPO = "shelter-search"


class FrontendStack(Stack):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        env_name: str,
        oidc_provider_arn: str,
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        bucket = s3.Bucket(self, "Bucket",
            bucket_name=f"navigator-{env_name}-frontend-{self.account}",
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            removal_policy=cdk.RemovalPolicy.DESTROY,
            auto_delete_objects=True,
        )

        oac = cloudfront.S3OriginAccessControl(self, "OAC",
            description=f"Navigator {env_name} frontend OAC",
        )

        distribution = cloudfront.Distribution(self, "Distribution",
            default_behavior=cloudfront.BehaviorOptions(
                origin=origins.S3BucketOrigin.with_origin_access_control(bucket,
                    origin_access_control=oac,
                ),
                viewer_protocol_policy=cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
                cache_policy=cloudfront.CachePolicy.CACHING_DISABLED,
                compress=True,
            ),
            default_root_object="index.html",
            # SPA routing — all 404s and 403s serve index.html so React Router handles them
            error_responses=[
                cloudfront.ErrorResponse(
                    http_status=403,
                    response_http_status=200,
                    response_page_path="/index.html",
                ),
                cloudfront.ErrorResponse(
                    http_status=404,
                    response_http_status=200,
                    response_page_path="/index.html",
                ),
            ],
        )

        # GitHub Actions deploy role — scoped to this bucket and distribution only
        oidc_provider = iam.OpenIdConnectProvider.from_open_id_connect_provider_arn(
            self, "GithubOIDC", oidc_provider_arn,
        )

        deploy_role = iam.Role(self, "FrontendGithubRole",
            role_name=f"navigator-frontend-github-role-{env_name}",
            assumed_by=iam.WebIdentityPrincipal(
                oidc_provider.open_id_connect_provider_arn,
                conditions={
                    "StringLike": {
                        "token.actions.githubusercontent.com:sub": f"repo:{GITHUB_ORG}/{FRONTEND_REPO}:*",
                    },
                    "StringEquals": {
                        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
                    },
                },
            ),
        )

        bucket.grant_read_write(deploy_role)
        distribution.grant_create_invalidation(deploy_role)

        self.frontend_url = f"https://{distribution.distribution_domain_name}"

        CfnOutput(self, "BucketName",
            value=bucket.bucket_name,
            description=f"Navigator {env_name} frontend S3 bucket name",
        )
        CfnOutput(self, "DistributionId",
            value=distribution.distribution_id,
            description=f"Navigator {env_name} frontend CloudFront distribution ID",
        )
        CfnOutput(self, "FrontendUrl",
            value=f"https://{distribution.distribution_domain_name}",
            description=f"Navigator {env_name} frontend URL",
        )
        CfnOutput(self, "DeployRoleArn",
            value=deploy_role.role_arn,
            description=f"GitHub Actions IAM role ARN for {FRONTEND_REPO} ({env_name})",
        )
