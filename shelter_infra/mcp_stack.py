from pathlib import Path

from aws_cdk import (
    Stack,
    aws_ec2 as ec2,
    aws_ecs as ecs,
    aws_rds as rds,
    aws_secretsmanager as secretsmanager,
    aws_servicediscovery as servicediscovery,
)
from constructs import Construct

_ROOT = Path(__file__).parent.parent
MCP_SERVER_DIR = str(_ROOT.parent / "shelter-mcp-server")
OLLAMA_DOCKER_DIR = str(_ROOT / "docker" / "ollama")


class McpStack(Stack):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        env_name: str,
        vpc: ec2.Vpc,
        db_instance: rds.DatabaseInstance,
        db_secret: secretsmanager.ISecret,
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

        ollama_image = ecs.ContainerImage.from_asset(OLLAMA_DOCKER_DIR)
        mcp_image = ecs.ContainerImage.from_asset(MCP_SERVER_DIR)

        task_def = ecs.FargateTaskDefinition(self, "McpTaskDef",
            cpu=512,
            memory_limit_mib=2048,
        )

        ollama_container = task_def.add_container("ollama",
            image=ollama_image,
            memory_limit_mib=1024,
            port_mappings=[ecs.PortMapping(container_port=11434)],
            logging=ecs.LogDrivers.aws_logs(stream_prefix=f"navigator-{env_name}-ollama"),
            essential=True,
        )

        mcp_container = task_def.add_container("mcp-server",
            image=mcp_image,
            memory_limit_mib=1024,
            port_mappings=[ecs.PortMapping(container_port=8001)],
            logging=ecs.LogDrivers.aws_logs(stream_prefix=f"navigator-{env_name}-mcp"),
            essential=True,
            environment={
                "OLLAMA_BASE_URL": "http://localhost:11434",
                "OLLAMA_EMBEDDING_MODEL": "nomic-embed-text",
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

        mcp_container.add_container_dependencies(
            ecs.ContainerDependency(
                container=ollama_container,
                condition=ecs.ContainerDependencyCondition.START,
            )
        )

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
        scaling.scale_on_cpu_utilization("CpuScaling",
            target_utilization_percent=70,
        )
        scaling.scale_on_memory_utilization("MemoryScaling",
            target_utilization_percent=70,
        )

        db_secret.grant_read(task_def.task_role)

        self.cloud_map_service = mcp_service.cloud_map_service
