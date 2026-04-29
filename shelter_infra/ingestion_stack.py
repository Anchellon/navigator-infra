import aws_cdk as cdk
from aws_cdk import (
    Stack,
    aws_cloudwatch as cloudwatch,
    aws_cloudwatch_actions as cloudwatch_actions,
    aws_ec2 as ec2,
    aws_ecr as ecr,
    aws_ecs as ecs,
    aws_events as events,
    aws_events_targets as targets,
    aws_iam as iam,
    aws_logs as logs,
    aws_rds as rds,
    aws_secretsmanager as secretsmanager,
    aws_sns as sns,
    aws_sns_subscriptions as sns_subscriptions,
    aws_ssm as ssm,
)
from constructs import Construct


class IngestionStack(Stack):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        env_name: str,
        vpc: ec2.Vpc,
        db_instance: rds.DatabaseInstance,
        db_secret: secretsmanager.ISecret,
        ingestion_repo: ecr.Repository,
        alert_email: str = "",
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        log_group = logs.LogGroup(self, "LogGroup",
            log_group_name=f"/ecs/ingestion-pipeline-{env_name}",
            retention=logs.RetentionDays.ONE_MONTH,
            removal_policy=cdk.RemovalPolicy.DESTROY,
        )

        # Tracks last successful run; pipeline uses this for dirty-checking
        last_run_param = ssm.StringParameter(self, "LastRunAt",
            parameter_name=f"/ingestion-pipeline/{env_name}/last-run-at",
            string_value="never",
            description=f"Navigator {env_name} last successful ingestion run timestamp",
        )

        cluster = ecs.Cluster(self, "Cluster",
            vpc=vpc,
            cluster_name=f"navigator-{env_name}-ingestion",
        )

        # Outbound-only — task runs in public subnet with public IP, no NAT needed
        ingestion_sg = ec2.SecurityGroup(self, "IngestionSG",
            vpc=vpc,
            description=f"Navigator {env_name} ingestion task — outbound to AWS APIs only",
            allow_all_outbound=True,
        )

        task_def = ecs.FargateTaskDefinition(self, "TaskDef",
            cpu=1024,
            memory_limit_mib=2048,
        )

        # DB credentials injected as separate vars; pipeline assembles
        # DATABASE_URL as postgresql://DB_USER:DB_PASSWORD@DB_HOST:DB_PORT/DB_NAME
        task_def.add_container("ingestion",
            image=ecs.ContainerImage.from_ecr_repository(ingestion_repo),
            logging=ecs.LogDrivers.aws_logs(
                stream_prefix=f"ingestion-{env_name}",
                log_group=log_group,
            ),
            essential=True,
            environment={
                "EMBEDDING_PROVIDER": "bedrock",
                "EMBEDDING_MODEL": "amazon.titan-embed-text-v2:0",
                "AWS_REGION": self.region,
                "DB_HOST": db_instance.db_instance_endpoint_address,
                "DB_PORT": "5432",
                "DB_NAME": "shelter",
                "SSM_LAST_RUN_PARAM": last_run_param.parameter_name,
            },
            secrets={
                "DB_USER": ecs.Secret.from_secrets_manager(db_secret, "username"),
                "DB_PASSWORD": ecs.Secret.from_secrets_manager(db_secret, "password"),
            },
        )

        ingestion_repo.grant_pull(task_def.execution_role)
        db_secret.grant_read(task_def.execution_role)

        task_def.task_role.add_to_policy(iam.PolicyStatement(
            actions=["bedrock:InvokeModel"],
            resources=[
                f"arn:aws:bedrock:{self.region}::foundation-model/amazon.titan-embed-text-v2:0"
            ],
        ))
        task_def.task_role.add_to_policy(iam.PolicyStatement(
            actions=["ssm:GetParameter", "ssm:PutParameter"],
            resources=[last_run_param.parameter_arn],
        ))

        # Nightly cron — 6 AM UTC
        rule = events.Rule(self, "NightlySchedule",
            rule_name=f"navigator-{env_name}-ingestion-nightly",
            schedule=events.Schedule.cron(hour="10", minute="0"),
            description=f"Navigator {env_name} nightly ingestion pipeline — 2 AM PST / 3 AM PDT",
        )
        rule.add_target(targets.EcsTask(
            cluster=cluster,
            task_definition=task_def,
            launch_type=ecs.LaunchType.FARGATE,
            subnet_selection=ec2.SubnetSelection(subnet_type=ec2.SubnetType.PUBLIC),
            security_groups=[ingestion_sg],
            assign_public_ip=True,
        ))

        # Alerting — metric filter on ERROR/CRITICAL/FATAL → alarm → SNS → email
        metric_filter = logs.MetricFilter(self, "ErrorMetricFilter",
            log_group=log_group,
            metric_namespace=f"Navigator/{env_name}/IngestionPipeline",
            metric_name="Errors",
            filter_pattern=logs.FilterPattern.any_term("ERROR", "CRITICAL", "FATAL"),
            metric_value="1",
            default_value=0,
        )

        alert_topic = sns.Topic(self, "AlertTopic",
            display_name=f"Navigator {env_name} Ingestion Pipeline Alerts",
        )
        if alert_email:
            alert_topic.add_subscription(sns_subscriptions.EmailSubscription(alert_email))

        alarm = cloudwatch.Alarm(self, "ErrorAlarm",
            alarm_name=f"navigator-{env_name}-ingestion-errors",
            alarm_description=f"Navigator {env_name} ingestion pipeline logged an error",
            metric=metric_filter.metric(),
            threshold=1,
            evaluation_periods=1,
            comparison_operator=cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
            treat_missing_data=cloudwatch.TreatMissingData.NOT_BREACHING,
        )
        alarm.add_alarm_action(cloudwatch_actions.SnsAction(alert_topic))

        cdk.CfnOutput(self, "LastRunParamName",
            value=last_run_param.parameter_name,
            description=f"Navigator {env_name} SSM param tracking last successful ingestion",
        )
