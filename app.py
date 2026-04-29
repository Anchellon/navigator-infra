#!/usr/bin/env python3
import aws_cdk as cdk

from shelter_infra.network_stack import NetworkStack
from shelter_infra.database_stack import DatabaseStack
from shelter_infra.cicd_stack import CICDStack
from shelter_infra.mcp_stack import McpStack
from shelter_infra.agent_stack import AgentStack
from shelter_infra.ingestion_stack import IngestionStack
from shelter_infra.frontend_stack import FrontendStack

app = cdk.App()

env_us = cdk.Environment(account="746669221991", region="us-east-1")

ALERT_EMAIL = "mathew.ans@northeastern.edu"

# CICD is account-level — one set of ECR repos + OIDC roles shared across environments
cicd_stack = CICDStack(app, "Navigator-CICD", env=env_us)

for env_name in ["staging", "prod"]:
    label = env_name.capitalize()

    network_stack = NetworkStack(app, f"Navigator-{label}-Network",
        env_name=env_name,
        env=env_us,
    )

    db_stack = DatabaseStack(app, f"Navigator-{label}-Database",
        env_name=env_name,
        vpc=network_stack.vpc,
        env=env_us,
    )
    db_stack.add_dependency(network_stack)

    mcp_stack = McpStack(app, f"Navigator-{label}-Mcp",
        env_name=env_name,
        vpc=network_stack.vpc,
        db_instance=db_stack.db_instance,
        db_secret=db_stack.db_secret,
        mcp_repo=cicd_stack.mcp_repo,
        env=env_us,
    )
    mcp_stack.add_dependency(db_stack)

    agent_stack = AgentStack(app, f"Navigator-{label}-Agent",
        env_name=env_name,
        vpc=network_stack.vpc,
        mcp_namespace=mcp_stack.namespace,
        mcp_service=mcp_stack.cloud_map_service,
        db_instance=db_stack.db_instance,
        db_secret=db_stack.db_secret,
        chatapi_repo=cicd_stack.chatapi_repo,
        env=env_us,
    )
    agent_stack.add_dependency(mcp_stack)

    ingestion_stack = IngestionStack(app, f"Navigator-{label}-Ingestion",
        env_name=env_name,
        vpc=network_stack.vpc,
        db_instance=db_stack.db_instance,
        db_secret=db_stack.db_secret,
        ingestion_repo=cicd_stack.ingestion_repo,
        alert_email=ALERT_EMAIL,
        env=env_us,
    )
    ingestion_stack.add_dependency(db_stack)

    frontend_stack = FrontendStack(app, f"Navigator-{label}-Frontend",
        env_name=env_name,
        oidc_provider_arn=cicd_stack.oidc_provider_arn,
        env=env_us,
    )

app.synth()
