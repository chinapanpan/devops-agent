# AWS DevOps Agent Demo

## Architecture

```
EC2 Instance (CPU Stress)
       |
       v
CloudWatch Metrics (CPUUtilization)
       |
       v
CloudWatch Alarm (CPU > 80%)
       |
       v
EventBridge Rule-1 (Alarm State Change)
       |
       v
Lambda-A (Trigger Investigation)
  create_backlog_task(taskType='INVESTIGATION')
       |
       v
AWS DevOps Agent (Autonomous Investigation)
  - Analyzes CloudWatch metrics, logs, CloudTrail events
  - Identifies root cause
  - Generates investigation summary
       |
       v (EventBridge event: source=aws.aidevops, detail-type=Investigation Completed)
       |
EventBridge Rule-2 (Investigation Completed)
       |
       v
Lambda-B (Get Results + Notify)
  list_journal_records() -> investigation_summary_md
       |
       v
Feishu Bot (Rich-text Notification with Investigation Summary)
```

### Flow Description

1. **EC2 CPU Stress**: A stress test pushes EC2 CPU utilization above the threshold (80%)
2. **CloudWatch Alarm**: Detects high CPU and transitions to ALARM state
3. **EventBridge Rule-1**: Captures the alarm state change event and routes to Lambda-A
4. **Lambda-A**: Calls DevOps Agent `create_backlog_task(taskType='INVESTIGATION')` to start an autonomous investigation
5. **DevOps Agent**: Performs investigation - analyzes CloudWatch metrics, CloudTrail events, EC2 instance details, and generates a root cause analysis
6. **EventBridge Rule-2**: When investigation completes, DevOps Agent emits an event (`source: aws.aidevops`, `detail-type: Investigation Completed`) which triggers Lambda-B
7. **Lambda-B**: Retrieves the investigation summary via `list_journal_records()`, finds the `investigation_summary_md` record (Markdown format), and sends it to Feishu
8. **Feishu Bot**: Delivers a rich-text notification with the investigation summary to the team chat

### Components

| Component | AWS Service | Purpose |
|-----------|------------|---------|
| CPU Alarm | CloudWatch Alarms | Detect high CPU utilization |
| Event Router (Rule-1) | EventBridge | Route alarm events to Lambda-A |
| Event Router (Rule-2) | EventBridge | Route investigation completion events to Lambda-B |
| Investigation Trigger | Lambda-A (Python 3.12) | Call DevOps Agent to start investigation |
| Notification Sender | Lambda-B (Python 3.12) | Get investigation results and send to Feishu |
| Investigation Engine | AWS DevOps Agent | AI-powered autonomous root cause analysis |
| Chat Bot | Feishu Bot API | Deliver notifications to team |
| boto3 Layer | Lambda Layer | Latest boto3 with DevOps Agent support |

## Prerequisites

- AWS CLI v2 configured with appropriate credentials
- An AWS DevOps Agent Space configured with AWS account association
- A Feishu custom app with Bot capability enabled
- Python 3.12 (for local testing)
- An EC2 instance with CloudWatch detailed monitoring enabled
- `stress` tool installed on EC2 for testing

## Quick Start

See [DEPLOY.md](DEPLOY.md) for step-by-step deployment instructions.

## Files

```
.
├── README.md                # This file - architecture overview
├── DEPLOY.md                # Step-by-step deployment guide
├── lambda/
│   ├── lambda_a.py          # Lambda-A: Trigger DevOps Agent investigation
│   └── lambda_b.py          # Lambda-B: Get results and send Feishu notification
├── scripts/
│   ├── deploy.sh            # Automated deployment script
│   └── stress-test.sh       # CPU stress test script
└── iam/
    └── lambda-role-trust.json
```

## Key Technical Notes

- DevOps Agent EventBridge source: `aws.aidevops`
- IAM action prefix: `aidevops` (e.g., `aidevops:CreateBacklogTask`)
- Lambda runtime boto3 does NOT include the `devops-agent` service - a Lambda Layer with the latest boto3 is required
- Investigation is asynchronous - Lambda-A triggers it, Lambda-B receives the completion event
- Investigation summary is in Markdown format (record type: `investigation_summary_md`)
