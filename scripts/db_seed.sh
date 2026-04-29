#!/usr/bin/env bash
# Manually trigger the ingestion pipeline ECS task.
# Usage: ./scripts/run_ingestion.sh staging
#        ./scripts/run_ingestion.sh prod
set -euo pipefail

ENV=${1:-staging}
LABEL="$(tr '[:lower:]' '[:upper:]' <<< ${ENV:0:1})${ENV:1}"
REGION="us-east-1"

echo "==> Fetching ingestion cluster and task definition for Navigator-${LABEL}-Ingestion..."

CLUSTER="navigator-${ENV}-ingestion"

TASK_DEF_ARN=$(aws ecs list-task-definitions --region "$REGION" \
  --family-prefix "Navigator${LABEL}IngestionTaskDef" \
  --sort DESC \
  --query "taskDefinitionArns[0]" \
  --output text)

if [ -z "$TASK_DEF_ARN" ] || [ "$TASK_DEF_ARN" = "None" ]; then
  echo "==> ERROR: No task definition found. Has Navigator-${LABEL}-Ingestion been deployed?"
  exit 1
fi

echo "    Task definition: $TASK_DEF_ARN"

VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:aws:cloudformation:stack-name,Values=Navigator-${LABEL}-Network" \
  --query "Vpcs[0].VpcId" --output text)

SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=*Public*" \
  --query "Subnets[0].SubnetId" --output text)

SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters \
    "Name=vpc-id,Values=$VPC_ID" \
    "Name=description,Values=Navigator ${ENV} ingestion task*" \
  --query "SecurityGroups[0].GroupId" --output text)

echo "    Subnet: $SUBNET_ID"
echo "    SG:     $SG_ID"

echo "==> Triggering ingestion pipeline..."
RUN_OUT=$(aws ecs run-task --region "$REGION" \
  --cluster "$CLUSTER" \
  --task-definition "$TASK_DEF_ARN" \
  --launch-type FARGATE \
  --network-configuration \
    "awsvpcConfiguration={subnets=[$SUBNET_ID],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
  --output json)

TASK_ARN=$(echo "$RUN_OUT" | python3 -c \
  "import sys,json; t=json.load(sys.stdin).get('tasks',[]); print(t[0]['taskArn'] if t else '')")

if [ -z "$TASK_ARN" ]; then
  REASON=$(echo "$RUN_OUT" | python3 -c \
    "import sys,json; f=json.load(sys.stdin).get('failures',[]); print(f[0].get('reason','unknown') if f else 'unknown')")
  echo "==> Failed to launch task: $REASON"
  exit 1
fi

echo "==> Ingestion pipeline started."
echo "    Task ARN: $TASK_ARN"
echo ""
echo "    Stream logs:"
echo "    aws logs tail /ecs/ingestion-pipeline-${ENV} --follow --region $REGION --profile navigator-infra"
