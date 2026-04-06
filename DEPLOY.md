# Deployment Guide

## Configuration

Set the following variables before running the deployment commands:

```bash
export AWS_ACCOUNT_ID="<YOUR_AWS_ACCOUNT_ID>"      # e.g., 123456789012
export AWS_REGION="<YOUR_AWS_REGION>"               # e.g., us-west-2
export EC2_INSTANCE_ID="<YOUR_EC2_INSTANCE_ID>"     # e.g., i-0abc123def456
export FEISHU_APP_ID="<YOUR_FEISHU_APP_ID>"         # e.g., cli_xxxxxxxxxxxx
export FEISHU_APP_SECRET="<YOUR_FEISHU_APP_SECRET>"
export FEISHU_CHAT_ID="<YOUR_FEISHU_CHAT_ID>"       # e.g., oc_xxxxxxxxxxxx
```

> **Note**: To get the `FEISHU_CHAT_ID`, you can use the Feishu API to list chats the bot is in, or create a new group chat. See [Step 3](#step-3-configure-feishu-bot).

---

## Step 1: Create IAM Roles

### 1.1 AIOps Investigation Role

This role allows CloudWatch Investigations to access your resources during investigations.

```bash
aws iam create-role \
  --role-name CloudWatchInvestigationsRole \
  --assume-role-policy-document file://iam/aiops-role-trust.json \
  --description "Role for CloudWatch AIOps Investigations"

aws iam attach-role-policy \
  --role-name CloudWatchInvestigationsRole \
  --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess
```

### 1.2 Lambda Execution Role

```bash
aws iam create-role \
  --role-name DevOpsAgentDemoLambdaRole \
  --assume-role-policy-document file://iam/lambda-role-trust.json \
  --description "Lambda role for DevOps Agent Demo"

aws iam attach-role-policy \
  --role-name DevOpsAgentDemoLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
```

Wait 10 seconds for IAM role propagation:
```bash
sleep 10
```

---

## Step 2: Create AIOps Investigation Group

```bash
# Create the investigation group
aws aiops create-investigation-group \
  --name "devops-agent-demo" \
  --role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/CloudWatchInvestigationsRole" \
  --retention-in-days 90 \
  --is-cloud-trail-event-history-enabled \
  --region ${AWS_REGION}
```

Save the ARN from the output, then set the resource policy to allow CloudWatch alarms to create investigations:

```bash
# Get the investigation group ARN
INVESTIGATION_GROUP_ARN=$(aws aiops list-investigation-groups \
  --region ${AWS_REGION} \
  --query 'investigationGroups[?name==`devops-agent-demo`].arn' \
  --output text)

echo "Investigation Group ARN: ${INVESTIGATION_GROUP_ARN}"

# Create resource policy (replace placeholders in the template)
POLICY=$(cat iam/investigation-group-policy.json \
  | sed "s/\${AWS_ACCOUNT_ID}/${AWS_ACCOUNT_ID}/g" \
  | sed "s/\${AWS_REGION}/${AWS_REGION}/g")

aws aiops put-investigation-group-policy \
  --identifier "${INVESTIGATION_GROUP_ARN}" \
  --policy "${POLICY}" \
  --region ${AWS_REGION}
```

---

## Step 3: Configure Feishu Bot

### 3.1 Prerequisites

1. Go to [Feishu Developer Console](https://open.feishu.cn/app/)
2. Ensure your app has **Bot capability** enabled
3. Enable the `im:message:send_as_bot` permission
4. Add the bot to a group chat (or create one)

### 3.2 Get Chat ID

If you don't have a chat ID yet, you can create a group or list existing chats:

```bash
# Get token
TOKEN=$(curl -s -X POST 'https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal' \
  -H 'Content-Type: application/json' \
  -d "{\"app_id\": \"${FEISHU_APP_ID}\", \"app_secret\": \"${FEISHU_APP_SECRET}\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['tenant_access_token'])")

# List chats the bot is in
curl -s 'https://open.feishu.cn/open-apis/im/v1/chats' \
  -H "Authorization: Bearer ${TOKEN}" | python3 -m json.tool

# Or create a new group
curl -s -X POST 'https://open.feishu.cn/open-apis/im/v1/chats' \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"name":"DevOps Agent Alerts","chat_type":"private"}' | python3 -m json.tool
```

Set the `FEISHU_CHAT_ID` from the output.

---

## Step 4: Deploy Lambda Function

```bash
# Package the Lambda function
cd lambda && zip -j function.zip lambda_function.py && cd ..

# Create the function
aws lambda create-function \
  --function-name devops-agent-feishu-notifier \
  --runtime python3.12 \
  --handler lambda_function.lambda_handler \
  --role "arn:aws:iam::${AWS_ACCOUNT_ID}:role/DevOpsAgentDemoLambdaRole" \
  --zip-file fileb://lambda/function.zip \
  --timeout 30 \
  --memory-size 128 \
  --environment "Variables={FEISHU_APP_ID=${FEISHU_APP_ID},FEISHU_APP_SECRET=${FEISHU_APP_SECRET},FEISHU_CHAT_ID=${FEISHU_CHAT_ID}}" \
  --region ${AWS_REGION}
```

---

## Step 5: Create CloudWatch Alarm

```bash
# Get investigation group ARN (if not already set)
INVESTIGATION_GROUP_ARN=$(aws aiops list-investigation-groups \
  --region ${AWS_REGION} \
  --query 'investigationGroups[?name==`devops-agent-demo`].arn' \
  --output text)

# Create the alarm
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
  --region ${AWS_REGION}
```

---

## Step 6: Create EventBridge Rule

```bash
# Create rule to match alarm state changes
aws events put-rule \
  --name "DevOps-Agent-Demo-Alarm-To-Lambda" \
  --description "Forward CloudWatch alarm state changes to Lambda" \
  --event-pattern "{
    \"source\": [\"aws.cloudwatch\"],
    \"detail-type\": [\"CloudWatch Alarm State Change\"],
    \"detail\": {
      \"alarmName\": [\"DevOps-Agent-Demo-CPU-High\"]
    }
  }" \
  --state ENABLED \
  --region ${AWS_REGION}

# Grant EventBridge permission to invoke Lambda
aws lambda add-permission \
  --function-name devops-agent-feishu-notifier \
  --statement-id EventBridgeInvoke \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "arn:aws:events:${AWS_REGION}:${AWS_ACCOUNT_ID}:rule/DevOps-Agent-Demo-Alarm-To-Lambda" \
  --region ${AWS_REGION}

# Add Lambda as target
aws events put-targets \
  --rule "DevOps-Agent-Demo-Alarm-To-Lambda" \
  --targets "Id=feishu-notifier,Arn=arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:devops-agent-feishu-notifier" \
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

2. Check Lambda logs:
   ```bash
   aws logs tail "/aws/lambda/devops-agent-feishu-notifier" \
     --region ${AWS_REGION} --since 5m
   ```

3. Check Feishu group chat for the notification

4. Check AIOps investigations in CloudWatch console:
   `https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#investigations`

---

## Cleanup

```bash
# Delete EventBridge target and rule
aws events remove-targets --rule "DevOps-Agent-Demo-Alarm-To-Lambda" --ids "feishu-notifier" --region ${AWS_REGION}
aws events delete-rule --name "DevOps-Agent-Demo-Alarm-To-Lambda" --region ${AWS_REGION}

# Delete Lambda
aws lambda delete-function --function-name devops-agent-feishu-notifier --region ${AWS_REGION}

# Delete CloudWatch alarm
aws cloudwatch delete-alarms --alarm-names "DevOps-Agent-Demo-CPU-High" --region ${AWS_REGION}

# Delete AIOps investigation group
INVESTIGATION_GROUP_ARN=$(aws aiops list-investigation-groups --region ${AWS_REGION} --query 'investigationGroups[?name==`devops-agent-demo`].arn' --output text)
aws aiops delete-investigation-group --identifier "${INVESTIGATION_GROUP_ARN}" --region ${AWS_REGION}

# Delete IAM roles
aws iam detach-role-policy --role-name CloudWatchInvestigationsRole --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess
aws iam detach-role-policy --role-name CloudWatchInvestigationsRole --policy-arn arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess
aws iam delete-role --role-name CloudWatchInvestigationsRole

aws iam detach-role-policy --role-name DevOpsAgentDemoLambdaRole --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role --role-name DevOpsAgentDemoLambdaRole
```
