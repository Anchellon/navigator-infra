#!/usr/bin/env bash
# One-time DB bootstrap — creates service_snapshots table + pgvector extension.
# Run this after restore_db.sh, before the first ingestion pipeline run.
#
# Usage: ./scripts/bootstrap_db.sh staging
#        ./scripts/bootstrap_db.sh prod
set -euo pipefail

ENV=${1:-staging}
LABEL="$(tr '[:lower:]' '[:upper:]' <<< ${ENV:0:1})${ENV:1}"
REGION="us-east-1"
ACCOUNT="746669221991"
S3_BUCKET="navigator-db-backups-${ACCOUNT}"
S3_KEY="bootstrap/create_service_snapshot.sql"
SQL_FILE="$(dirname "$0")/../sql/create_service_snapshot.sql"

if [ ! -f "$SQL_FILE" ]; then
  echo "==> ERROR: SQL file not found at $SQL_FILE"
  exit 1
fi

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

VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:aws:cloudformation:stack-name,Values=Navigator-${LABEL}-Network" \
  --query "Vpcs[0].VpcId" --output text)

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

echo "==> Uploading SQL to S3..."
aws s3 cp "$SQL_FILE" "s3://${S3_BUCKET}/${S3_KEY}" --region "$REGION"

echo "==> Generating presigned S3 URL..."
SQL_URL=$(aws s3 presign "s3://${S3_BUCKET}/${S3_KEY}" --expires-in 3600 --region "$REGION")

echo "==> Creating temporary security group..."
BOOTSTRAP_SG=$(aws ec2 create-security-group --region "$REGION" \
  --group-name "navigator-${ENV}-bootstrap-$$" \
  --description "Temp SG for DB bootstrap" \
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
  --source-group "$BOOTSTRAP_SG"

echo "    Bootstrap SG: $BOOTSTRAP_SG"
echo "    DB SG:        $DB_SG (temporary ingress rule added)"

ROLE_NAME="navigator-${ENV}-bootstrap-$$"
TEMP_CLUSTER="navigator-${ENV}-bootstrap-$$"
TASK_DEF_ARN=""

cleanup() {
  echo "==> Cleaning up temporary resources..."
  aws s3 rm "s3://${S3_BUCKET}/${S3_KEY}" --region "$REGION" 2>/dev/null || true
  aws ec2 revoke-security-group-ingress --region "$REGION" \
    --group-id "$DB_SG" --protocol tcp --port 5432 \
    --source-group "$BOOTSTRAP_SG" 2>/dev/null || true
  aws ec2 delete-security-group --region "$REGION" \
    --group-id "$BOOTSTRAP_SG" 2>/dev/null || true
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
  --log-group-name "/ecs/navigator-${ENV}-bootstrap" \
  --region "$REGION" 2>/dev/null || true

CONTAINER_DEFS=$(python3 - "$DB_PASS" "$SQL_URL" "$DB_HOST" "$DB_USER" "$ENV" "$REGION" <<'PYEOF'
import json, sys
db_pass, sql_url, db_host, db_user, env, region = sys.argv[1:]
print(json.dumps([{
    "name": "bootstrap",
    "image": "postgres:16-alpine",
    "essential": True,
    "command": [
        "sh", "-c",
        'wget -qO- "$SQL_URL" | psql -h "$DB_HOST" -U "$DB_USER" -d shelter'
    ],
    "environment": [
        {"name": "PGPASSWORD", "value": db_pass},
        {"name": "SQL_URL",    "value": sql_url},
        {"name": "DB_HOST",    "value": db_host},
        {"name": "DB_USER",    "value": db_user},
    ],
    "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
            "awslogs-group":         f"/ecs/navigator-{env}-bootstrap",
            "awslogs-region":        region,
            "awslogs-stream-prefix": "bootstrap",
        }
    }
}]))
PYEOF
)

echo "==> Registering task definition..."
TASK_DEF_ARN=$(aws ecs register-task-definition --region "$REGION" \
  --family "navigator-${ENV}-db-bootstrap" \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu "512" --memory "1024" \
  --task-role-arn "$ROLE_ARN" \
  --execution-role-arn "$ROLE_ARN" \
  --container-definitions "$CONTAINER_DEFS" \
  --query "taskDefinition.taskDefinitionArn" --output text)

echo "==> Running bootstrap task..."
RUN_OUT=$(aws ecs run-task --region "$REGION" \
  --cluster "$TEMP_CLUSTER" \
  --task-definition "$TASK_DEF_ARN" \
  --launch-type FARGATE \
  --network-configuration \
    "awsvpcConfiguration={subnets=[$SUBNET_ID],securityGroups=[$BOOTSTRAP_SG],assignPublicIp=ENABLED}" \
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
echo "==> Waiting for bootstrap to complete..."
aws ecs wait tasks-stopped --region "$REGION" --cluster "$TEMP_CLUSTER" --tasks "$TASK_ARN"

EXIT_CODE=$(aws ecs describe-tasks --region "$REGION" \
  --cluster "$TEMP_CLUSTER" --tasks "$TASK_ARN" \
  --query "tasks[0].containers[0].exitCode" --output text)

if [ "$EXIT_CODE" = "0" ]; then
  echo "==> Bootstrap completed successfully."
  echo "    service_snapshots table is ready — run the ingestion pipeline to populate it."
else
  echo "==> Bootstrap FAILED (exit code: $EXIT_CODE)."
  echo "    Stream logs with: aws logs tail /ecs/navigator-${ENV}-bootstrap --region $REGION --follow"
  exit 1
fi
