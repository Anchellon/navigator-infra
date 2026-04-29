from aws_cdk import (
    Stack,
    aws_ec2 as ec2,
    aws_ecr as ecr,
    aws_ecs as ecs,
    aws_iam as iam,
    aws_rds as rds,
    aws_secretsmanager as secretsmanager,
    aws_servicediscovery as servicediscovery,
)
from constructs import Construct


class McpStack(Stack):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        env_name: str,
        vpc: ec2.Vpc,
        db_instance: rds.DatabaseInstance,
        db_secret: secretsmanager.ISecret,
        mcp_repo: ecr.Repository,
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        self.namespace = servicediscovery.PrivateDnsNamespace(self, "Namespace",
            name=f"navigator-{env_name}.internal",
            vpc=vpc,
        )

        cluster = ecs.Cluster(self, "Cluster",
            vpc=vpc,
            cluster_name=f"navigator-{env_name}",
        )

        task_def = ecs.FargateTaskDefinition(self, "McpTaskDef",
            cpu=512,
            memory_limit_mib=1024,
        )

        task_def.add_container("mcp-server",
            image=ecs.ContainerImage.from_ecr_repository(mcp_repo),
            memory_limit_mib=1024,
            port_mappings=[ecs.PortMapping(container_port=8001)],
            logging=ecs.LogDrivers.aws_logs(stream_prefix=f"navigator-{env_name}-mcp"),
            essential=True,
            environment={
                "BEDROCK_EMBEDDING_MODEL": "amazon.titan-embed-text-v2:0",
                "AWS_REGION": self.region,
                "PGVECTOR_PORT": "5432",
                "PGVECTOR_DB": "shelter",
                "PGVECTOR_TABLE": "service_snapshots",
                "PGVECTOR_HOST": db_instance.db_instance_endpoint_address,
            },
            secrets={
                "PGVECTOR_USER": ecs.Secret.from_secrets_manager(db_secret, "username"),
                "PGVECTOR_PASSWORD": ecs.Secret.from_secrets_manager(db_secret, "password"),
            },
        )

        task_def.task_role.add_to_policy(iam.PolicyStatement(
            actions=["bedrock:InvokeModel"],
            resources=[
                f"arn:aws:bedrock:{self.region}::foundation-model/amazon.titan-embed-text-v2:0"
            ],
        ))

        mcp_repo.grant_pull(task_def.execution_role)
        db_secret.grant_read(task_def.task_role)

        mcp_sg = ec2.SecurityGroup(self, "McpSG",
            vpc=vpc,
            description=f"Navigator {env_name} MCP server security group",
        )
        mcp_sg.add_ingress_rule(
            ec2.Peer.ipv4(vpc.vpc_cidr_block),
            ec2.Port.tcp(8001),
            "Allow MCP server from within VPC",
        )

        mcp_service = ecs.FargateService(self, "McpService",
            cluster=cluster,
            task_definition=task_def,
            desired_count=1,
            min_healthy_percent=0,
            max_healthy_percent=200,
            assign_public_ip=True,
            vpc_subnets=ec2.SubnetSelection(subnet_type=ec2.SubnetType.PUBLIC),
            security_groups=[mcp_sg],
            cloud_map_options=ecs.CloudMapOptions(
                cloud_map_namespace=self.namespace,
                name="mcp",
            ),
        )

        scaling = mcp_service.auto_scale_task_count(min_capacity=1, max_capacity=4)
        scaling.scale_on_cpu_utilization("CpuScaling", target_utilization_percent=70)
        scaling.scale_on_memory_utilization("MemoryScaling", target_utilization_percent=70)

        self.cloud_map_service = mcp_service.cloud_map_service
