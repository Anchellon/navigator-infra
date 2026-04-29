#!/usr/bin/env bash
# Manually trigger the ingestion pipeline ECS task (first run or ad-hoc re-seed).
# Usage: ./scripts/db_seed.sh staging
#        ./scripts/db_seed.sh prod
set -euo pipefail

ENV=${1:-staging}
LABEL="$(tr '[:lower:]' '[:upper:]' <<< ${ENV:0:1})${ENV:1}"
REGION="us-east-1"

echo "==> Fetching stack outputs for Navigator-${LABEL}-Ingestion..."
INGESTION_OUTPUTS=$(aws cloudformation describe-stacks \
  --stack-name "Navigator-${LABEL}-Ingestion" \
  --region "$REGION" \
  --query "Stacks[0].Outputs" \
  --output json)

TASK_DEF_ARN=$(echo "$INGESTION_OUTPUTS" | python3 -c \
  "import sys,json; o={x['OutputKey']:x['OutputValue'] for x in json.load(sys.stdin)}; print(o['TaskDefinitionArn'])")
CLUSTER=$(echo "$INGESTION_OUTPUTS" | python3 -c \
  "import sys,json; o={x['OutputKey']:x['OutputValue'] for x in json.load(sys.stdin)}; print(o['ClusterName'])")

echo "    Cluster:         $CLUSTER"
echo "    Task definition: $TASK_DEF_ARN"

echo "==> Fetching network config from Navigator-${LABEL}-Network..."
VPC_ID=$(aws cloudformation describe-stacks \
  --stack-name "Navigator-${LABEL}-Network" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" \
  --output text)

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
