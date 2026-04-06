#!/bin/bash
set -euo pipefail

# ============================================================
# AWS DevOps Agent Demo - Automated Deployment Script
# ============================================================

# --- Configuration (MUST be set before running) ---
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:?'Set AWS_ACCOUNT_ID env variable'}"
AWS_REGION="${AWS_REGION:?'Set AWS_REGION env variable'}"
EC2_INSTANCE_ID="${EC2_INSTANCE_ID:?'Set EC2_INSTANCE_ID env variable'}"
DEVOPS_AGENT_SPACE_ID="${DEVOPS_AGENT_SPACE_ID:?'Set DEVOPS_AGENT_SPACE_ID env variable'}"
FEISHU_APP_ID="${FEISHU_APP_ID:?'Set FEISHU_APP_ID env variable'}"
FEISHU_APP_SECRET="${FEISHU_APP_SECRET:?'Set FEISHU_APP_SECRET env variable'}"
FEISHU_CHAT_ID="${FEISHU_CHAT_ID:?'Set FEISHU_CHAT_ID env variable'}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== AWS DevOps Agent Demo Deployment ==="
echo "Account:    ${AWS_ACCOUNT_ID}"
echo "Region:     ${AWS_REGION}"
echo "EC2:        ${EC2_INSTANCE_ID}"
echo "Agent Space: ${DEVOPS_AGENT_SPACE_ID}"
echo ""

# Step 1: IAM Role
echo "[1/7] Creating IAM role..."
aws iam create-role \
  --role-name DevOpsAgentDemoLambdaRole \
  --assume-role-policy-document "file://${PROJECT_DIR}/iam/lambda-role-trust.json" \
  --description "Lambda role for DevOps Agent Demo" \
  --no-cli-pager 2>/dev/null || echo "  Role already exists, skipping."

aws iam attach-role-policy \
  --role-name DevOpsAgentDemoLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true

aws iam put-role-policy \
  --role-name DevOpsAgentDemoLambdaRole \
  --policy-name DevOpsAgentAccess \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "aidevops:CreateBacklogTask",
          "aidevops:ListJournalRecords",
          "aidevops:GetTask",
          "aidevops:ListTasks"
        ],
        "Resource": "*"
      }
    ]
  }'

echo "  Waiting 10s for IAM propagation..."
sleep 10

# Step 2: Lambda Layer (latest boto3)
echo "[2/7] Creating Lambda Layer (latest boto3)..."
LAYER_ARN=$(aws lambda list-layer-versions \
  --layer-name boto3-latest \
  --region "${AWS_REGION}" \
  --query 'LayerVersions[0].LayerVersionArn' \
  --output text 2>/dev/null)

if [ -z "$LAYER_ARN" ] || [ "$LAYER_ARN" = "None" ]; then
  TMPDIR=$(mktemp -d)
  mkdir -p "${TMPDIR}/python"
  pip install boto3 -t "${TMPDIR}/python" --upgrade -q
  cd "${TMPDIR}" && zip -r /tmp/boto3-layer.zip python/ -q && cd -
  LAYER_ARN=$(aws lambda publish-layer-version \
    --layer-name boto3-latest \
    --description "Latest boto3 with DevOps Agent support" \
    --zip-file fileb:///tmp/boto3-layer.zip \
    --compatible-runtimes python3.12 \
    --region "${AWS_REGION}" \
    --query 'LayerVersionArn' --output text)
  rm -rf "${TMPDIR}" /tmp/boto3-layer.zip
  echo "  Layer created: ${LAYER_ARN}"
else
  echo "  Layer exists: ${LAYER_ARN}"
fi

# Step 3: Lambda-A (Trigger Investigation)
echo "[3/7] Deploying Lambda-A (trigger investigation)..."
cd "${PROJECT_DIR}/lambda"
zip -j lambda_a.zip lambda_a.py >/dev/null 2>&1

aws lambda create-function \
  --function-name devops-agent-trigger-investigation \
  --runtime python3.12 \
  --handler lambda_a.lambda_handler \
  --role "arn:aws:iam::${AWS_ACCOUNT_ID}:role/DevOpsAgentDemoLambdaRole" \
  --zip-file fileb://lambda_a.zip \
  --timeout 30 \
  --memory-size 128 \
  --layers "${LAYER_ARN}" \
  --environment "Variables={DEVOPS_AGENT_SPACE_ID=${DEVOPS_AGENT_SPACE_ID}}" \
  --region "${AWS_REGION}" \
  --no-cli-pager 2>/dev/null || {
    echo "  Function exists, updating..."
    aws lambda update-function-code \
      --function-name devops-agent-trigger-investigation \
      --zip-file fileb://lambda_a.zip \
      --region "${AWS_REGION}" --no-cli-pager >/dev/null
    sleep 3
    aws lambda update-function-configuration \
      --function-name devops-agent-trigger-investigation \
      --layers "${LAYER_ARN}" \
      --environment "Variables={DEVOPS_AGENT_SPACE_ID=${DEVOPS_AGENT_SPACE_ID}}" \
      --region "${AWS_REGION}" --no-cli-pager >/dev/null
  }
rm -f lambda_a.zip
cd "${PROJECT_DIR}"
echo "  Lambda-A deployed."

# Step 4: Lambda-B (Get Results + Feishu)
echo "[4/7] Deploying Lambda-B (notify feishu)..."
cd "${PROJECT_DIR}/lambda"
zip -j lambda_b.zip lambda_b.py >/dev/null 2>&1

aws lambda create-function \
  --function-name devops-agent-notify-feishu \
  --runtime python3.12 \
  --handler lambda_b.lambda_handler \
  --role "arn:aws:iam::${AWS_ACCOUNT_ID}:role/DevOpsAgentDemoLambdaRole" \
  --zip-file fileb://lambda_b.zip \
  --timeout 60 \
  --memory-size 128 \
  --layers "${LAYER_ARN}" \
  --environment "Variables={DEVOPS_AGENT_SPACE_ID=${DEVOPS_AGENT_SPACE_ID},FEISHU_APP_ID=${FEISHU_APP_ID},FEISHU_APP_SECRET=${FEISHU_APP_SECRET},FEISHU_CHAT_ID=${FEISHU_CHAT_ID}}" \
  --region "${AWS_REGION}" \
  --no-cli-pager 2>/dev/null || {
    echo "  Function exists, updating..."
    aws lambda update-function-code \
      --function-name devops-agent-notify-feishu \
      --zip-file fileb://lambda_b.zip \
      --region "${AWS_REGION}" --no-cli-pager >/dev/null
    sleep 3
    aws lambda update-function-configuration \
      --function-name devops-agent-notify-feishu \
      --layers "${LAYER_ARN}" \
      --environment "Variables={DEVOPS_AGENT_SPACE_ID=${DEVOPS_AGENT_SPACE_ID},FEISHU_APP_ID=${FEISHU_APP_ID},FEISHU_APP_SECRET=${FEISHU_APP_SECRET},FEISHU_CHAT_ID=${FEISHU_CHAT_ID}}" \
      --region "${AWS_REGION}" --no-cli-pager >/dev/null
  }
rm -f lambda_b.zip
cd "${PROJECT_DIR}"
echo "  Lambda-B deployed."

# Step 5: CloudWatch Alarm
echo "[5/7] Creating CloudWatch alarm..."
aws cloudwatch put-metric-alarm \
  --alarm-name "DevOps-Agent-Demo-CPU-High" \
  --alarm-description "Triggers DevOps Agent investigation when CPU > 80%" \
  --metric-name CPUUtilization \
  --namespace AWS/EC2 \
  --statistic Average \
  --period 60 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 2 \
  --dimensions "Name=InstanceId,Value=${EC2_INSTANCE_ID}" \
  --treat-missing-data missing \
  --region "${AWS_REGION}"
echo "  Alarm created."

# Step 6: EventBridge Rules
echo "[6/7] Creating EventBridge rules..."

# Rule-1: Alarm -> Lambda-A
aws events put-rule \
  --name "DevOps-Agent-Demo-Alarm-To-Lambda" \
  --description "Forward CloudWatch alarm state changes to Lambda-A" \
  --event-pattern "{\"source\":[\"aws.cloudwatch\"],\"detail-type\":[\"CloudWatch Alarm State Change\"],\"detail\":{\"alarmName\":[\"DevOps-Agent-Demo-CPU-High\"]}}" \
  --state ENABLED \
  --region "${AWS_REGION}" --no-cli-pager >/dev/null

aws lambda add-permission \
  --function-name devops-agent-trigger-investigation \
  --statement-id EventBridgeAlarmInvoke \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "arn:aws:events:${AWS_REGION}:${AWS_ACCOUNT_ID}:rule/DevOps-Agent-Demo-Alarm-To-Lambda" \
  --region "${AWS_REGION}" --no-cli-pager 2>/dev/null || echo "  Permission already exists."

aws events put-targets \
  --rule "DevOps-Agent-Demo-Alarm-To-Lambda" \
  --targets "Id=trigger-investigation,Arn=arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:devops-agent-trigger-investigation" \
  --region "${AWS_REGION}" --no-cli-pager >/dev/null
echo "  Rule-1 (Alarm -> Lambda-A) created."

# Rule-2: Investigation Completed -> Lambda-B
aws events put-rule \
  --name "DevOps-Agent-Investigation-Completed" \
  --description "Forward DevOps Agent Investigation Completed events to Lambda-B" \
  --event-pattern "{\"source\":[\"aws.aidevops\"],\"detail-type\":[\"Investigation Completed\"]}" \
  --state ENABLED \
  --region "${AWS_REGION}" --no-cli-pager >/dev/null

aws lambda add-permission \
  --function-name devops-agent-notify-feishu \
  --statement-id EventBridgeInvestigationInvoke \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "arn:aws:events:${AWS_REGION}:${AWS_ACCOUNT_ID}:rule/DevOps-Agent-Investigation-Completed" \
  --region "${AWS_REGION}" --no-cli-pager 2>/dev/null || echo "  Permission already exists."

aws events put-targets \
  --rule "DevOps-Agent-Investigation-Completed" \
  --targets "Id=notify-feishu,Arn=arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:devops-agent-notify-feishu" \
  --region "${AWS_REGION}" --no-cli-pager >/dev/null
echo "  Rule-2 (Investigation Completed -> Lambda-B) created."

# Step 7: Verify
echo "[7/7] Verifying deployment..."
echo ""
echo "  Alarm state:  $(aws cloudwatch describe-alarms --alarm-names 'DevOps-Agent-Demo-CPU-High' --region ${AWS_REGION} --query 'MetricAlarms[0].StateValue' --output text)"
echo "  Lambda-A:     $(aws lambda get-function --function-name devops-agent-trigger-investigation --region ${AWS_REGION} --query 'Configuration.State' --output text)"
echo "  Lambda-B:     $(aws lambda get-function --function-name devops-agent-notify-feishu --region ${AWS_REGION} --query 'Configuration.State' --output text)"
echo "  Rule-1:       $(aws events describe-rule --name 'DevOps-Agent-Demo-Alarm-To-Lambda' --region ${AWS_REGION} --query 'State' --output text)"
echo "  Rule-2:       $(aws events describe-rule --name 'DevOps-Agent-Investigation-Completed' --region ${AWS_REGION} --query 'State' --output text)"
echo ""
echo "=== Deployment complete! ==="
echo ""
echo "To test, run on the EC2 instance:"
echo "  stress --cpu 4 --timeout 180"
