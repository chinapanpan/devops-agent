#!/bin/bash
set -euo pipefail

# ============================================================
# AWS DevOps Agent Demo - Automated Deployment Script
# ============================================================

# --- Configuration (MUST be set before running) ---
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:?'Set AWS_ACCOUNT_ID env variable'}"
AWS_REGION="${AWS_REGION:?'Set AWS_REGION env variable'}"
EC2_INSTANCE_ID="${EC2_INSTANCE_ID:?'Set EC2_INSTANCE_ID env variable'}"
FEISHU_APP_ID="${FEISHU_APP_ID:?'Set FEISHU_APP_ID env variable'}"
FEISHU_APP_SECRET="${FEISHU_APP_SECRET:?'Set FEISHU_APP_SECRET env variable'}"
FEISHU_CHAT_ID="${FEISHU_CHAT_ID:?'Set FEISHU_CHAT_ID env variable'}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== AWS DevOps Agent Demo Deployment ==="
echo "Account: ${AWS_ACCOUNT_ID}"
echo "Region:  ${AWS_REGION}"
echo "EC2:     ${EC2_INSTANCE_ID}"
echo ""

# Step 1: IAM Roles
echo "[1/6] Creating IAM roles..."
aws iam create-role \
  --role-name CloudWatchInvestigationsRole \
  --assume-role-policy-document "file://${PROJECT_DIR}/iam/aiops-role-trust.json" \
  --description "Role for CloudWatch AIOps Investigations" \
  --no-cli-pager 2>/dev/null || echo "  Role already exists, skipping."

aws iam attach-role-policy \
  --role-name CloudWatchInvestigationsRole \
  --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess 2>/dev/null || true

aws iam create-role \
  --role-name DevOpsAgentDemoLambdaRole \
  --assume-role-policy-document "file://${PROJECT_DIR}/iam/lambda-role-trust.json" \
  --description "Lambda role for DevOps Agent Demo" \
  --no-cli-pager 2>/dev/null || echo "  Role already exists, skipping."

aws iam attach-role-policy \
  --role-name DevOpsAgentDemoLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true

echo "  Waiting 10s for IAM propagation..."
sleep 10

# Step 2: AIOps Investigation Group
echo "[2/6] Creating AIOps investigation group..."
INVESTIGATION_GROUP_ARN=$(aws aiops list-investigation-groups \
  --region "${AWS_REGION}" \
  --query 'investigationGroups[?name==`devops-agent-demo`].arn' \
  --output text 2>/dev/null)

if [ -z "$INVESTIGATION_GROUP_ARN" ] || [ "$INVESTIGATION_GROUP_ARN" = "None" ]; then
  RESULT=$(aws aiops create-investigation-group \
    --name "devops-agent-demo" \
    --role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/CloudWatchInvestigationsRole" \
    --retention-in-days 90 \
    --is-cloud-trail-event-history-enabled \
    --region "${AWS_REGION}" \
    --no-cli-pager 2>&1)
  INVESTIGATION_GROUP_ARN=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['arn'])")
  echo "  Created: ${INVESTIGATION_GROUP_ARN}"
else
  echo "  Already exists: ${INVESTIGATION_GROUP_ARN}"
fi

# Set resource policy
POLICY=$(cat "${PROJECT_DIR}/iam/investigation-group-policy.json" \
  | sed "s/\${AWS_ACCOUNT_ID}/${AWS_ACCOUNT_ID}/g" \
  | sed "s/\${AWS_REGION}/${AWS_REGION}/g")

aws aiops put-investigation-group-policy \
  --identifier "${INVESTIGATION_GROUP_ARN}" \
  --policy "${POLICY}" \
  --region "${AWS_REGION}" \
  --no-cli-pager >/dev/null 2>&1
echo "  Resource policy applied."

# Step 3: Lambda Function
echo "[3/6] Deploying Lambda function..."
cd "${PROJECT_DIR}/lambda"
zip -j function.zip lambda_function.py >/dev/null 2>&1

aws lambda create-function \
  --function-name devops-agent-feishu-notifier \
  --runtime python3.12 \
  --handler lambda_function.lambda_handler \
  --role "arn:aws:iam::${AWS_ACCOUNT_ID}:role/DevOpsAgentDemoLambdaRole" \
  --zip-file fileb://function.zip \
  --timeout 30 \
  --memory-size 128 \
  --environment "Variables={FEISHU_APP_ID=${FEISHU_APP_ID},FEISHU_APP_SECRET=${FEISHU_APP_SECRET},FEISHU_CHAT_ID=${FEISHU_CHAT_ID}}" \
  --region "${AWS_REGION}" \
  --no-cli-pager 2>/dev/null || {
    echo "  Function exists, updating code and config..."
    aws lambda update-function-code \
      --function-name devops-agent-feishu-notifier \
      --zip-file fileb://function.zip \
      --region "${AWS_REGION}" \
      --no-cli-pager >/dev/null
    sleep 3
    aws lambda update-function-configuration \
      --function-name devops-agent-feishu-notifier \
      --environment "Variables={FEISHU_APP_ID=${FEISHU_APP_ID},FEISHU_APP_SECRET=${FEISHU_APP_SECRET},FEISHU_CHAT_ID=${FEISHU_CHAT_ID}}" \
      --region "${AWS_REGION}" \
      --no-cli-pager >/dev/null
  }
cd "${PROJECT_DIR}"
echo "  Lambda deployed."

# Step 4: CloudWatch Alarm
echo "[4/6] Creating CloudWatch alarm..."
aws cloudwatch put-metric-alarm \
  --alarm-name "DevOps-Agent-Demo-CPU-High" \
  --alarm-description "Triggers AIOps investigation when CPU > 80%" \
  --metric-name CPUUtilization \
  --namespace AWS/EC2 \
  --statistic Average \
  --period 60 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 1 \
  --dimensions "Name=InstanceId,Value=${EC2_INSTANCE_ID}" \
  --alarm-actions "${INVESTIGATION_GROUP_ARN}" \
  --treat-missing-data notBreaching \
  --region "${AWS_REGION}"
echo "  Alarm created."

# Step 5: EventBridge Rule
echo "[5/6] Creating EventBridge rule..."
aws events put-rule \
  --name "DevOps-Agent-Demo-Alarm-To-Lambda" \
  --description "Forward CloudWatch alarm state changes to Lambda" \
  --event-pattern "{\"source\":[\"aws.cloudwatch\"],\"detail-type\":[\"CloudWatch Alarm State Change\"],\"detail\":{\"alarmName\":[\"DevOps-Agent-Demo-CPU-High\"]}}" \
  --state ENABLED \
  --region "${AWS_REGION}" \
  --no-cli-pager >/dev/null

aws lambda add-permission \
  --function-name devops-agent-feishu-notifier \
  --statement-id EventBridgeInvoke \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "arn:aws:events:${AWS_REGION}:${AWS_ACCOUNT_ID}:rule/DevOps-Agent-Demo-Alarm-To-Lambda" \
  --region "${AWS_REGION}" \
  --no-cli-pager 2>/dev/null || echo "  Permission already exists."

aws events put-targets \
  --rule "DevOps-Agent-Demo-Alarm-To-Lambda" \
  --targets "Id=feishu-notifier,Arn=arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:devops-agent-feishu-notifier" \
  --region "${AWS_REGION}" \
  --no-cli-pager >/dev/null
echo "  EventBridge rule created."

# Step 6: Verify
echo "[6/6] Verifying deployment..."
echo ""
echo "  Alarm state: $(aws cloudwatch describe-alarms --alarm-names 'DevOps-Agent-Demo-CPU-High' --region ${AWS_REGION} --query 'MetricAlarms[0].StateValue' --output text)"
echo "  Lambda:      $(aws lambda get-function --function-name devops-agent-feishu-notifier --region ${AWS_REGION} --query 'Configuration.State' --output text)"
echo "  EventBridge: $(aws events describe-rule --name 'DevOps-Agent-Demo-Alarm-To-Lambda' --region ${AWS_REGION} --query 'State' --output text)"
echo "  AIOps:       ${INVESTIGATION_GROUP_ARN}"
echo ""
echo "=== Deployment complete! ==="
echo ""
echo "To test, run on the EC2 instance:"
echo "  stress --cpu 4 --timeout 180"
