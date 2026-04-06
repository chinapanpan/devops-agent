# AWS DevOps Agent Demo

## Architecture

```
EC2 Instance (CPU Stress)
       │
       ▼
CloudWatch Metrics (CPUUtilization)
       │
       ▼
CloudWatch Alarm (CPU > 80%)
       │
       ├──────────────────────────────┐
       ▼                              ▼
AIOps Investigation Group       EventBridge Rule
(Auto-start AI Investigation)   (Alarm State Change)
                                      │
                                      ▼
                                 Lambda Function
                                      │
                                      ▼
                                 Feishu Bot
                              (Rich-text Notification)
```

### Flow Description

1. **EC2 CPU Stress**: A stress test pushes EC2 CPU utilization above the threshold (80%)
2. **CloudWatch Alarm**: Detects high CPU and transitions to ALARM state
3. **AIOps Investigation**: CloudWatch automatically starts an AI-powered investigation that scans telemetry, metrics, logs, and deployment events to surface root-cause hypotheses
4. **EventBridge**: Captures the alarm state change event
5. **Lambda**: Processes the alarm event and extracts key details (alarm name, metric, instance, threshold, reason)
6. **Feishu Bot**: Sends a rich-text notification to a Feishu group chat with alarm details and a link to the AIOps investigation in the CloudWatch console

### Components

| Component | AWS Service | Purpose |
|-----------|------------|---------|
| Investigation Group | AWS AIOps (CloudWatch Investigations) | AI-powered root cause analysis |
| CPU Alarm | CloudWatch Alarms | Detect high CPU utilization |
| Event Router | EventBridge | Route alarm events to Lambda |
| Notifier | Lambda (Python 3.12) | Format and send Feishu messages |
| Chat Bot | Feishu Bot API | Deliver notifications to team |

## Prerequisites

- AWS CLI v2 configured with appropriate credentials
- IAM permissions: `AIOpsConsoleAdminPolicy` or equivalent
- A Feishu custom app with Bot capability enabled
- Python 3.12 (for local testing)
- An EC2 instance with CloudWatch detailed monitoring enabled

## Quick Start

See [DEPLOY.md](DEPLOY.md) for step-by-step deployment instructions.

## Files

```
.
├── README.md              # This file - architecture overview
├── DEPLOY.md              # Step-by-step deployment guide
├── lambda/
│   └── lambda_function.py # Lambda function source code
├── scripts/
│   ├── deploy.sh          # Automated deployment script
│   └── stress-test.sh     # CPU stress test script
└── iam/
    ├── aiops-role-trust.json
    ├── lambda-role-trust.json
    └── investigation-group-policy.json
```
