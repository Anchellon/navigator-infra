import aws_cdk as cdk
from aws_cdk import (
    Stack,
    aws_ec2 as ec2,
    aws_rds as rds,
)
from constructs import Construct


class DatabaseStack(Stack):
    def __init__(self, scope: Construct, construct_id: str, env_name: str, vpc: ec2.Vpc, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        db_sg = ec2.SecurityGroup(self, "DatabaseSG",
            vpc=vpc,
            description=f"Navigator {env_name} RDS security group",
            allow_all_outbound=False,
        )
        db_sg.add_ingress_rule(
            ec2.Peer.ipv4(vpc.vpc_cidr_block),
            ec2.Port.tcp(5432),
            "Allow PostgreSQL from within VPC",
        )

        instance_size = (
            ec2.InstanceSize.MICRO if env_name == "staging"
            else ec2.InstanceSize.MEDIUM
        )

        self.db_instance = rds.DatabaseInstance(self, "Database",
            engine=rds.DatabaseInstanceEngine.postgres(
                version=rds.PostgresEngineVersion.VER_16,
            ),
            instance_type=ec2.InstanceType.of(ec2.InstanceClass.T3, instance_size),
            vpc=vpc,
            vpc_subnets=ec2.SubnetSelection(subnet_type=ec2.SubnetType.PRIVATE_ISOLATED),
            security_groups=[db_sg],
            database_name="shelter",
            multi_az=False,
            publicly_accessible=False,
            storage_encrypted=True,
            backup_retention=cdk.Duration.days(7),
            deletion_protection=env_name == "prod",
            removal_policy=(
                cdk.RemovalPolicy.RETAIN if env_name == "prod"
                else cdk.RemovalPolicy.DESTROY
            ),
        )

        self.db_secret = self.db_instance.secret

        cdk.CfnOutput(self, "DbEndpoint",
            value=self.db_instance.db_instance_endpoint_address,
            description=f"Navigator {env_name} RDS endpoint",
        )
        cdk.CfnOutput(self, "DbSecretArn",
            value=self.db_secret.secret_arn,
            description=f"Navigator {env_name} DB credentials secret ARN",
        )
