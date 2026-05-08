#!/usr/bin/env bash
# Run Flyway migrations against the Navigator RDS Postgres database.
# Spins up a one-off Fargate task using the flyway/flyway image, then tears
# down all temporary infra (cluster, task def, IAM role, security group rule).
#
# Migrations live in sql/migrations/ and follow Flyway's V<n>__<desc>.sql convention.
# Flyway tracks applied versions in the flyway_schema_history table — re-runs
# only apply new migrations.
#
# Usage:
#   ./scripts/db_migrate.sh staging                     # run pending migrations
#   ./scripts/db_migrate.sh prod
#   ./scripts/db_migrate.sh staging --baseline 4        # mark V1..V4 as already
#                                                       # applied (one-time op for
#                                                       # DBs bootstrapped via the
#                                                       # legacy db_schema.sh)
#   ./scripts/db_migrate.sh staging --info              # show migration state
#                                                       # (applied / pending / failed)
#   ./scripts/db_migrate.sh staging --validate          # checksum-validate applied
#                                                       # migrations against the files
set -euo pipefail

ENV=${1:-staging}
shift || true

FLYWAY_CMD="migrate"
case "${1:-}" in
  --baseline)
    BASELINE_VERSION="${2:-}"
    if [ -z "$BASELINE_VERSION" ]; then
      echo "ERROR: --baseline requires a version number (e.g. --baseline 4)"
      exit 1
    fi
    FLYWAY_CMD="baseline -baselineVersion=$BASELINE_VERSION"
    ;;
  --info)
    FLYWAY_CMD="info"
    ;;
  --validate)
    FLYWAY_CMD="validate"
    ;;
  "")
    ;;
  *)
    echo "ERROR: unknown flag '$1' (supported: --baseline N, --info, --validate)"
    exit 1
    ;;
esac

LABEL="$(tr '[:lower:]' '[:upper:]' <<< ${ENV:0:1})${ENV:1}"
REGION="us-east-1"
ACCOUNT="746669221991"
S3_BUCKET="navigator-db-backups-${ACCOUNT}"
S3_KEY="migrate/migrations-$$.tgz"
MIGRATIONS_DIR="$(dirname "$0")/../sql/migrations"
TARBALL=$(mktemp /tmp/navigator_migrations_XXXXXX.tgz)

if [ ! -d "$MIGRATIONS_DIR" ]; then
  echo "==> ERROR: migrations dir not found at $MIGRATIONS_DIR"
  exit 1
fi
if [ -z "$(ls "$MIGRATIONS_DIR"/V*.sql 2>/dev/null)" ]; then
  echo "==> ERROR: no V*.sql files found in $MIGRATIONS_DIR"
  exit 1
fi

echo "==> Bundling migrations from $MIGRATIONS_DIR"
tar -czf "$TARBALL" -C "$MIGRATIONS_DIR" .
echo "    $(tar -tzf "$TARBALL" | grep -c '\.sql$') migration file(s) bundled"

echo "==> Fetching stack outputs for Navigator-${LABEL}-Database..."
STACK_OUTPUTS=$(aws cloudformation describe-stacks \
  --stack-name "Navigator-${LABEL}-Database" \
  --region "$REGION" \
  --query "Stacks[0].Outputs" \
  --output json)

DB_HOST=$(echo "$STACK_OUTPUTS" | python3 -c \
  "import sys,json; o={x['OutputKey']:x['OutputValue'] for x in json.load(sys.stdin)}; print(o['DbEndpoint'])")
SECRET_ARN=$(echo "$STACK_OUTPUTS" | python3 -c \
  "import sys,json; o={x['OutputKey']:x['OutputValue'] for x in json.load(sys.stdin)}; print(o['DbSecretArn'])")

echo "    DB host:    $DB_HOST"
echo "    Secret ARN: $SECRET_ARN"
echo "    Command:    $FLYWAY_CMD"

VPC_ID=$(aws cloudformation describe-stacks \
  --stack-name "Navigator-${LABEL}-Network" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" \
  --output text)

SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=*Public*" \
  --query "Subnets[0].SubnetId" --output text)

echo "    VPC:    $VPC_ID"
echo "    Subnet: $SUBNET_ID"

echo "==> Fetching DB credentials from Secrets Manager..."
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" --region "$REGION" \
  --query SecretString --output text)
DB_USER=$(echo "$SECRET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])")
DB_PASS=$(echo "$SECRET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

echo "==> Uploading migrations tarball to S3..."
aws s3 cp "$TARBALL" "s3://${S3_BUCKET}/${S3_KEY}" --region "$REGION"

echo "==> Generating presigned S3 URL..."
SQL_URL=$(aws s3 presign "s3://${S3_BUCKET}/${S3_KEY}" --expires-in 3600 --region "$REGION")

echo "==> Creating temporary security group..."
MIGRATE_SG=$(aws ec2 create-security-group --region "$REGION" \
  --group-name "navigator-${ENV}-migrate-$$" \
  --description "Temp SG for Flyway migrate" \
  --vpc-id "$VPC_ID" \
  --query "GroupId" --output text)

DB_SG=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters \
    "Name=vpc-id,Values=$VPC_ID" \
    "Name=description,Values=Navigator ${ENV} RDS security group" \
  --query "SecurityGroups[0].GroupId" --output text)

aws ec2 authorize-security-group-ingress --region "$REGION" \
  --group-id "$DB_SG" \
  --protocol tcp --port 5432 \
  --source-group "$MIGRATE_SG"

echo "    Migrate SG: $MIGRATE_SG"
echo "    DB SG:      $DB_SG (temporary ingress rule added)"

ROLE_NAME="navigator-${ENV}-migrate-$$"
TEMP_CLUSTER="navigator-${ENV}-migrate-$$"
TASK_DEF_ARN=""

cleanup() {
  echo "==> Cleaning up temporary resources..."
  rm -f "$TARBALL"
  aws s3 rm "s3://${S3_BUCKET}/${S3_KEY}" --region "$REGION" 2>/dev/null || true
  aws ec2 revoke-security-group-ingress --region "$REGION" \
    --group-id "$DB_SG" --protocol tcp --port 5432 \
    --source-group "$MIGRATE_SG" 2>/dev/null || true
  aws ec2 delete-security-group --region "$REGION" \
    --group-id "$MIGRATE_SG" 2>/dev/null || true
  [ -n "$TASK_DEF_ARN" ] && \
    aws ecs deregister-task-definition --region "$REGION" \
      --task-definition "$TASK_DEF_ARN" > /dev/null 2>/dev/null || true
  aws iam delete-role-policy --role-name "$ROLE_NAME" \
    --policy-name "logs" 2>/dev/null || true
  aws iam detach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true
  aws ecs delete-cluster --region "$REGION" \
    --cluster "$TEMP_CLUSTER" > /dev/null 2>/dev/null || true
}
trap cleanup EXIT

aws ecs create-cluster --region "$REGION" --cluster-name "$TEMP_CLUSTER" > /dev/null

echo "==> Creating IAM role..."
ROLE_ARN=$(aws iam create-role --role-name "$ROLE_NAME" \
  --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  --query "Role.Arn" --output text)

aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"

aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name "logs" \
  --policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],"Resource":"*"}]}'

echo "==> Waiting for IAM propagation..."
sleep 15

aws logs create-log-group \
  --log-group-name "/ecs/navigator-${ENV}-migrate" \
  --region "$REGION" 2>/dev/null || true

# Container shell:
#   1. download migrations tarball from S3 presigned URL
#   2. extract into /flyway/sql (Flyway's default locations dir)
#   3. log the files that landed (helps debug "wrong migrations bundled" issues)
#   4. invoke Flyway with the chosen subcommand against the 'shelter' database
CONTAINER_DEFS=$(python3 - "$DB_PASS" "$SQL_URL" "$DB_HOST" "$DB_USER" "$ENV" "$REGION" "$FLYWAY_CMD" <<'PYEOF'
import json, sys
db_pass, sql_url, db_host, db_user, env, region, flyway_cmd = sys.argv[1:]
shell = (
    'set -e; '
    'mkdir -p /flyway/sql && '
    'wget -qO /tmp/m.tgz "$SQL_URL" && '
    'tar -xzf /tmp/m.tgz -C /flyway/sql && '
    'echo "Migrations on disk:" && ls -1 /flyway/sql && '
    '/flyway/flyway '
    '-url="jdbc:postgresql://$DB_HOST:5432/shelter" '
    '-user="$DB_USER" -password="$FLYWAY_PASSWORD" '
    '-locations=filesystem:/flyway/sql '
    '-connectRetries=10 '
    f'{flyway_cmd}'
)
print(json.dumps([{
    "name": "flyway",
    "image": "flyway/flyway:10-alpine",
    "essential": True,
    "entryPoint": ["/bin/sh", "-c"],
    "command": [shell],
    "environment": [
        {"name": "FLYWAY_PASSWORD", "value": db_pass},
        {"name": "SQL_URL",         "value": sql_url},
        {"name": "DB_HOST",         "value": db_host},
        {"name": "DB_USER",         "value": db_user},
    ],
    "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
            "awslogs-group":         f"/ecs/navigator-{env}-migrate",
            "awslogs-region":        region,
            "awslogs-stream-prefix": "migrate",
        }
    }
}]))
PYEOF
)

echo "==> Registering task definition..."
TASK_DEF_ARN=$(aws ecs register-task-definition --region "$REGION" \
  --family "navigator-${ENV}-db-migrate" \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu "512" --memory "1024" \
  --task-role-arn "$ROLE_ARN" \
  --execution-role-arn "$ROLE_ARN" \
  --container-definitions "$CONTAINER_DEFS" \
  --query "taskDefinition.taskDefinitionArn" --output text)

echo "==> Running Flyway task..."
RUN_OUT=$(aws ecs run-task --region "$REGION" \
  --cluster "$TEMP_CLUSTER" \
  --task-definition "$TASK_DEF_ARN" \
  --launch-type FARGATE \
  --network-configuration \
    "awsvpcConfiguration={subnets=[$SUBNET_ID],securityGroups=[$MIGRATE_SG],assignPublicIp=ENABLED}" \
  --output json)

TASK_ARN=$(echo "$RUN_OUT" | python3 -c \
  "import sys,json; t=json.load(sys.stdin).get('tasks',[]); print(t[0]['taskArn'] if t else '')")

if [ -z "$TASK_ARN" ]; then
  REASON=$(echo "$RUN_OUT" | python3 -c \
    "import sys,json; f=json.load(sys.stdin).get('failures',[]); print(f[0].get('reason','unknown') if f else 'unknown')")
  echo "==> Failed to launch task: $REASON"
  exit 1
fi

echo "    Task: $TASK_ARN"
echo "==> Waiting for Flyway to complete..."
aws ecs wait tasks-stopped --region "$REGION" --cluster "$TEMP_CLUSTER" --tasks "$TASK_ARN"

EXIT_CODE=$(aws ecs describe-tasks --region "$REGION" \
  --cluster "$TEMP_CLUSTER" --tasks "$TASK_ARN" \
  --query "tasks[0].containers[0].exitCode" --output text)

if [ "$EXIT_CODE" = "0" ]; then
  echo "==> Flyway $FLYWAY_CMD completed successfully."
else
  echo "==> Flyway FAILED (exit code: $EXIT_CODE)."
  echo "    Stream logs with: aws logs tail /ecs/navigator-${ENV}-migrate --region $REGION --follow"
  exit 1
fi
