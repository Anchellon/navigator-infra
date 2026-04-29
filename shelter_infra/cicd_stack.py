import aws_cdk as cdk
from aws_cdk import (
    Stack,
    aws_ecr as ecr,
    aws_iam as iam,
)
from constructs import Construct

GITHUB_ORG = "Anchellon"

REPOS = {
    "mcp":       "shelter-mcp-server",
    "chatapi":   "shelter-chat-api",
    "ingestion": "rag-ingestion-pipeline-refuge",
}


class CICDStack(Stack):
    def __init__(self, scope: Construct, construct_id: str, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        oidc_provider = iam.OpenIdConnectProvider(self, "GithubOIDC",
            url="https://token.actions.githubusercontent.com",
            client_ids=["sts.amazonaws.com"],
            thumbprints=["6938fd4d98bab03faadb97b34396831e3780aea1"],
        )

        self.mcp_repo = ecr.Repository(self, "McpRepo",
            repository_name="mcp-server",
            removal_policy=cdk.RemovalPolicy.RETAIN,
        )
        self.chatapi_repo = ecr.Repository(self, "ChatApiRepo",
            repository_name="chat-api",
            removal_policy=cdk.RemovalPolicy.RETAIN,
        )
        self.ingestion_repo = ecr.Repository(self, "IngestionRepo",
            repository_name="ingestion-pipeline",
            removal_policy=cdk.RemovalPolicy.RETAIN,
        )

        repos = {
            "mcp":       (self.mcp_repo,       REPOS["mcp"]),
            "chatapi":   (self.chatapi_repo,    REPOS["chatapi"]),
            "ingestion": (self.ingestion_repo,  REPOS["ingestion"]),
        }

        for key, (ecr_repo, github_repo) in repos.items():
            role = iam.Role(self, f"{key.capitalize()}GithubRole",
                role_name=f"navigator-{key}-github-role",
                assumed_by=iam.WebIdentityPrincipal(
                    oidc_provider.open_id_connect_provider_arn,
                    conditions={
                        "StringLike": {
                            "token.actions.githubusercontent.com:sub": f"repo:{GITHUB_ORG}/{github_repo}:*",
                        },
                        "StringEquals": {
                            "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
                        },
                    },
                ),
            )
            ecr_repo.grant_push(role)

            cdk.CfnOutput(self, f"{key.capitalize()}RepoUri",
                value=ecr_repo.repository_uri,
                description=f"ECR repo URI for {github_repo}",
            )
            cdk.CfnOutput(self, f"{key.capitalize()}GithubRoleArn",
                value=role.role_arn,
                description=f"GitHub Actions IAM role ARN for {github_repo}",
            )
