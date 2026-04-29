from aws_cdk import (
    CfnOutput,
    Stack,
    aws_cloudfront as cloudfront,
    aws_cloudfront_origins as origins,
    aws_ec2 as ec2,
    aws_ecr as ecr,
    aws_ecs as ecs,
    aws_elasticloadbalancingv2 as elbv2,
    aws_rds as rds,
    aws_secretsmanager as secretsmanager,
    aws_servicediscovery as servicediscovery,
)
from constructs import Construct


class AgentStack(Stack):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        env_name: str,
        vpc: ec2.Vpc,
        mcp_namespace: servicediscovery.PrivateDnsNamespace,
        mcp_service,
        db_instance: rds.DatabaseInstance,
        db_secret: secretsmanager.ISecret,
        chatapi_repo: ecr.Repository,
        frontend_origin: str = "",
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        agent_image = ecs.ContainerImage.from_ecr_repository(chatapi_repo)

        # Must be pre-created: aws secretsmanager create-secret \
        #   --name navigator/{env_name}/anthropic-api-key \
        #   --secret-string '{"api_key":"sk-ant-..."}'
        anthropic_secret = secretsmanager.Secret.from_secret_name_v2(
            self, "AnthropicSecret",
            secret_name=f"navigator/{env_name}/anthropic-api-key",
        )

        cluster = ecs.Cluster(self, "Cluster",
            vpc=vpc,
            cluster_name=f"navigator-{env_name}-agent",
        )

        task_def = ecs.FargateTaskDefinition(self, "AgentTaskDef",
            cpu=1024,
            memory_limit_mib=2048,
        )

        mcp_url = f"http://mcp.navigator-{env_name}.internal:8001/mcp"

        cors_origins = "http://localhost:5173"
        if frontend_origin:
            cors_origins = f"http://localhost:5173,{frontend_origin}"

        task_def.add_container("agent",
            image=agent_image,
            port_mappings=[ecs.PortMapping(container_port=3000)],
            logging=ecs.LogDrivers.aws_logs(stream_prefix=f"navigator-{env_name}-agent"),
            essential=True,
            environment={
                "PORT": "3000",
                "MCP_SERVER_URL": mcp_url,
                "DB_HOST": db_instance.db_instance_endpoint_address,
                "DB_PORT": "5432",
                "DB_NAME": "shelter",
                "CLASSIFIER_PROVIDER": "anthropic",
                "CLASSIFIER_MODEL": "claude-haiku-4-5-20251001",
                "INTAKE_PROVIDER": "anthropic",
                "INTAKE_MODEL": "claude-haiku-4-5-20251001",
                "FORMATTER_PROVIDER": "anthropic",
                "FORMATTER_MODEL": "claude-haiku-4-5-20251001",
                "CORS_ORIGINS": cors_origins,
                "AUTH0_DOMAIN": "dev-c3fkdc5r55mfewzg.us.auth0.com",
                "AUTH0_AUDIENCE": "navigator-api",
            },
            secrets={
                "ANTHROPIC_API_KEY": ecs.Secret.from_secrets_manager(anthropic_secret, "api_key"),
                "DB_USER": ecs.Secret.from_secrets_manager(db_secret, "username"),
                "DB_PASSWORD": ecs.Secret.from_secrets_manager(db_secret, "password"),
            },
        )

        chatapi_repo.grant_pull(task_def.execution_role)
        anthropic_secret.grant_read(task_def.task_role)
        db_secret.grant_read(task_def.task_role)

        alb_sg = ec2.SecurityGroup(self, "AlbSG",
            vpc=vpc,
            description=f"Navigator {env_name} Agent ALB security group",
        )
        alb_sg.add_ingress_rule(ec2.Peer.any_ipv4(), ec2.Port.tcp(80))

        agent_sg = ec2.SecurityGroup(self, "AgentSG",
            vpc=vpc,
            description=f"Navigator {env_name} Agent security group",
        )
        agent_sg.add_ingress_rule(alb_sg, ec2.Port.tcp(3000))

        alb = elbv2.ApplicationLoadBalancer(self, "Alb",
            vpc=vpc,
            internet_facing=True,
            security_group=alb_sg,
            vpc_subnets=ec2.SubnetSelection(subnet_type=ec2.SubnetType.PUBLIC),
        )

        listener = alb.add_listener("Listener", port=80, open=False)

        agent_service = ecs.FargateService(self, "AgentService",
            cluster=cluster,
            task_definition=task_def,
            desired_count=1,
            min_healthy_percent=0,
            max_healthy_percent=200,
            assign_public_ip=True,
            vpc_subnets=ec2.SubnetSelection(subnet_type=ec2.SubnetType.PUBLIC),
            security_groups=[agent_sg],
        )

        listener.add_targets("AgentTarget",
            port=3000,
            protocol=elbv2.ApplicationProtocol.HTTP,
            targets=[agent_service],
            health_check=elbv2.HealthCheck(path="/health"),
        )

        scaling = agent_service.auto_scale_task_count(min_capacity=1, max_capacity=4)
        scaling.scale_on_cpu_utilization("CpuScaling", target_utilization_percent=70)
        scaling.scale_on_memory_utilization("MemoryScaling", target_utilization_percent=70)

        api_distribution = cloudfront.Distribution(self, "ApiDistribution",
            default_behavior=cloudfront.BehaviorOptions(
                origin=origins.LoadBalancerV2Origin(alb,
                    protocol_policy=cloudfront.OriginProtocolPolicy.HTTP_ONLY,
                ),
                viewer_protocol_policy=cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
                allowed_methods=cloudfront.AllowedMethods.ALLOW_ALL,
                cache_policy=cloudfront.CachePolicy.CACHING_DISABLED,
                origin_request_policy=cloudfront.OriginRequestPolicy.ALL_VIEWER_EXCEPT_HOST_HEADER,
            ),
        )

        CfnOutput(self, "AgentUrl",
            value=f"https://{api_distribution.distribution_domain_name}",
            description=f"Navigator {env_name} Agent API URL (HTTPS via CloudFront)",
        )
