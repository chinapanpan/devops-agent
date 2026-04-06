# Deployment Guide

## Configuration

Set the following variables before running the deployment commands:

```bash
export AWS_ACCOUNT_ID="<YOUR_AWS_ACCOUNT_ID>"      # e.g., 123456789012
export AWS_REGION="<YOUR_AWS_REGION>"               # e.g., us-west-2
export EC2_INSTANCE_ID="<YOUR_EC2_INSTANCE_ID>"     # e.g., i-0abc123def456
export DEVOPS_AGENT_SPACE_ID="<YOUR_AGENT_SPACE_ID>" # e.g., f95eb69d-xxxx-xxxx-xxxx-xxxxxxxxxxxx
export FEISHU_APP_ID="<YOUR_FEISHU_APP_ID>"         # e.g., cli_xxxxxxxxxxxx
export FEISHU_APP_SECRET="<YOUR_FEISHU_APP_SECRET>"
export FEISHU_CHAT_ID="<YOUR_FEISHU_CHAT_ID>"       # e.g., oc_xxxxxxxxxxxx
```

> **Prerequisites**: You must have an AWS DevOps Agent Space already created and associated with your AWS account. See [AWS DevOps Agent documentation](https://docs.aws.amazon.com/devopsagent/latest/userguide/) for setup instructions.

---

## Step 1: Create IAM Role for Lambda

```bash
aws iam create-role \
  --role-name DevOpsAgentDemoLambdaRole \
  --assume-role-policy-document file://iam/lambda-role-trust.json \
  --description "Lambda role for DevOps Agent Demo"

aws iam attach-role-policy \
  --role-name DevOpsAgentDemoLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

# Add DevOps Agent permissions
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

sleep 10  # Wait for IAM role propagation
```

---

## Step 2: Create Lambda Layer (Latest boto3)

The Lambda runtime's built-in boto3 does NOT include the `devops-agent` service. You must create a Lambda Layer with the latest boto3.

```bash
mkdir -p /tmp/boto3-layer/python
pip install boto3 -t /tmp/boto3-layer/python --upgrade
cd /tmp/boto3-layer && zip -r /tmp/boto3-layer.zip python/
cd -

LAYER_ARN=$(aws lambda publish-layer-version \
  --layer-name boto3-latest \
  --description "Latest boto3 with DevOps Agent support" \
  --zip-file fileb:///tmp/boto3-layer.zip \
  --compatible-runtimes python3.12 \
  --region ${AWS_REGION} \
  --query 'LayerVersionArn' --output text)

echo "Lambda Layer ARN: ${LAYER_ARN}"
```

---

## Step 3: Configure Feishu Bot

### 3.1 Prerequisites

1. Go to [Feishu Developer Console](https://open.feishu.cn/app/)
2. Ensure your app has **Bot capability** enabled
3. Enable the `im:message:send_as_bot` permission
4. Add the bot to a group chat (or create one)

### 3.2 Get Chat ID

```bash
# Get token
TOKEN=$(curl -s -X POST 'https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal' \
  -H 'Content-Type: application/json' \
  -d "{\"app_id\": \"${FEISHU_APP_ID}\", \"app_secret\": \"${FEISHU_APP_SECRET}\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['tenant_access_token'])")

# List chats the bot is in
curl -s 'https://open.feishu.cn/open-apis/im/v1/chats' \
  -H "Authorization: Bearer ${TOKEN}" | python3 -m json.tool
```

---

## Step 4: Deploy Lambda Functions

### 4.1 Lambda-A (Trigger Investigation)

```bash
cd lambda && zip -j lambda_a.zip lambda_a.py && cd ..

aws lambda create-function \
  --function-name devops-agent-trigger-investigation \
  --runtime python3.12 \
  --handler lambda_a.lambda_handler \
  --role "arn:aws:iam::${AWS_ACCOUNT_ID}:role/DevOpsAgentDemoLambdaRole" \
  --zip-file fileb://lambda/lambda_a.zip \
  --timeout 30 \
  --memory-size 128 \
  --layers "${LAYER_ARN}" \
  --environment "Variables={DEVOPS_AGENT_SPACE_ID=${DEVOPS_AGENT_SPACE_ID}}" \
  --region ${AWS_REGION}
```

### 4.2 Lambda-B (Get Results + Feishu Notification)

```bash
cd lambda && zip -j lambda_b.zip lambda_b.py && cd ..

aws lambda create-function \
  --function-name devops-agent-notify-feishu \
  --runtime python3.12 \
  --handler lambda_b.lambda_handler \
  --role "arn:aws:iam::${AWS_ACCOUNT_ID}:role/DevOpsAgentDemoLambdaRole" \
  --zip-file fileb://lambda/lambda_b.zip \
  --timeout 60 \
  --memory-size 128 \
  --layers "${LAYER_ARN}" \
  --environment "Variables={DEVOPS_AGENT_SPACE_ID=${DEVOPS_AGENT_SPACE_ID},FEISHU_APP_ID=${FEISHU_APP_ID},FEISHU_APP_SECRET=${FEISHU_APP_SECRET},FEISHU_CHAT_ID=${FEISHU_CHAT_ID}}" \
  --region ${AWS_REGION}
```

---

## Step 5: Create CloudWatch Alarm

```bash
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
  --region ${AWS_REGION}
```

---

## Step 6: Create EventBridge Rules

### 6.1 Rule-1: CloudWatch Alarm -> Lambda-A

```bash
# Create rule
aws events put-rule \
  --name "DevOps-Agent-Demo-Alarm-To-Lambda" \
  --description "Forward CloudWatch alarm state changes to Lambda-A" \
  --event-pattern "{
    \"source\": [\"aws.cloudwatch\"],
    \"detail-type\": [\"CloudWatch Alarm State Change\"],
    \"detail\": {
      \"alarmName\": [\"DevOps-Agent-Demo-CPU-High\"]
    }
  }" \
  --state ENABLED \
  --region ${AWS_REGION}

# Grant EventBridge permission to invoke Lambda-A
aws lambda add-permission \
  --function-name devops-agent-trigger-investigation \
  --statement-id EventBridgeAlarmInvoke \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "arn:aws:events:${AWS_REGION}:${AWS_ACCOUNT_ID}:rule/DevOps-Agent-Demo-Alarm-To-Lambda" \
  --region ${AWS_REGION}

# Add Lambda-A as target
aws events put-targets \
  --rule "DevOps-Agent-Demo-Alarm-To-Lambda" \
  --targets "Id=trigger-investigation,Arn=arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:devops-agent-trigger-investigation" \
  --region ${AWS_REGION}
```

### 6.2 Rule-2: Investigation Completed -> Lambda-B

```bash
# Create rule
aws events put-rule \
  --name "DevOps-Agent-Investigation-Completed" \
  --description "Forward DevOps Agent Investigation Completed events to Lambda-B" \
  --event-pattern "{
    \"source\": [\"aws.aidevops\"],
    \"detail-type\": [\"Investigation Completed\"]
  }" \
  --state ENABLED \
  --region ${AWS_REGION}

# Grant EventBridge permission to invoke Lambda-B
aws lambda add-permission \
  --function-name devops-agent-notify-feishu \
  --statement-id EventBridgeInvestigationInvoke \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "arn:aws:events:${AWS_REGION}:${AWS_ACCOUNT_ID}:rule/DevOps-Agent-Investigation-Completed" \
  --region ${AWS_REGION}

# Add Lambda-B as target
aws events put-targets \
  --rule "DevOps-Agent-Investigation-Completed" \
  --targets "Id=notify-feishu,Arn=arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:devops-agent-notify-feishu" \
  --region ${AWS_REGION}
```

---

## Step 7: Test

### Install stress tool on EC2

```bash
# Amazon Linux 2023
sudo yum install -y stress

# Ubuntu
# sudo apt-get install -y stress
```

### Run CPU stress test

```bash
# Run 4 CPU workers for 3 minutes
stress --cpu 4 --timeout 180
```

### Verify

1. Check alarm state:
   ```bash
   aws cloudwatch describe-alarms \
     --alarm-names "DevOps-Agent-Demo-CPU-High" \
     --region ${AWS_REGION} \
     --query 'MetricAlarms[0].StateValue'
   ```

2. Check Lambda-A logs (should show `create_backlog_task` response):
   ```bash
   aws logs tail "/aws/lambda/devops-agent-trigger-investigation" \
     --region ${AWS_REGION} --since 10m
   ```

3. Wait for investigation to complete (typically 5-10 minutes), then check Lambda-B logs:
   ```bash
   aws logs tail "/aws/lambda/devops-agent-notify-feishu" \
     --region ${AWS_REGION} --since 30m
   ```

4. Check Feishu group chat for the investigation summary notification

5. Check DevOps Agent console:
   `https://${AWS_REGION}.console.aws.amazon.com/aidevops/home?region=${AWS_REGION}`

---

## Cleanup

```bash
# Delete EventBridge targets and rules
aws events remove-targets --rule "DevOps-Agent-Demo-Alarm-To-Lambda" --ids "trigger-investigation" --region ${AWS_REGION}
aws events delete-rule --name "DevOps-Agent-Demo-Alarm-To-Lambda" --region ${AWS_REGION}

aws events remove-targets --rule "DevOps-Agent-Investigation-Completed" --ids "notify-feishu" --region ${AWS_REGION}
aws events delete-rule --name "DevOps-Agent-Investigation-Completed" --region ${AWS_REGION}

# Delete Lambda functions
aws lambda delete-function --function-name devops-agent-trigger-investigation --region ${AWS_REGION}
aws lambda delete-function --function-name devops-agent-notify-feishu --region ${AWS_REGION}

# Delete Lambda Layer
aws lambda delete-layer-version --layer-name boto3-latest --version-number 1 --region ${AWS_REGION}

# Delete CloudWatch alarm
aws cloudwatch delete-alarms --alarm-names "DevOps-Agent-Demo-CPU-High" --region ${AWS_REGION}

# Delete IAM role
aws iam delete-role-policy --role-name DevOpsAgentDemoLambdaRole --policy-name DevOpsAgentAccess
aws iam detach-role-policy --role-name DevOpsAgentDemoLambdaRole --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role --role-name DevOpsAgentDemoLambdaRole
```
