# DevOps Agent Investigation Trigger Methods

AWS DevOps Agent provides two ways to trigger investigations: **Webhook** (passive, from third-party services) and **create_backlog_task API** (active, from your code).

## Comparison

| | Webhook | create_backlog_task API |
|---|---|---|
| **Trigger source** | Third-party monitoring systems push alerts to a webhook URL | Your code calls boto3 API directly |
| **Direction** | Inbound: external system -> DevOps Agent | Outbound: your code -> DevOps Agent |
| **Authentication** | `hmac` / `apikey` / `gitlab` / `pagerduty` token | IAM (AWS Signature V4) |
| **Investigation creation** | Agent **auto-decides** whether to investigate based on alert content | You **explicitly create** an investigation task |
| **Setup required** | `register_service` + `associate_service` to generate webhook URL | Only IAM permissions needed |
| **Supported sources** | PagerDuty, GitLab, Dynatrace, ServiceNow, Datadog, Grafana, New Relic, Splunk, etc. | Any code with IAM credentials |
| **Customization** | Alert format defined by third-party service | You control title, description, priority |
| **Best for** | Organizations already using third-party monitoring tools | Custom integrations, AWS-native workflows |

## Webhook Flow

```
Third-Party Monitoring (PagerDuty, GitLab, Dynatrace, etc.)
  |
  | POST https://<webhook-url> (with HMAC signature or API key)
  v
DevOps Agent receives alert
  |
  | Agent auto-triages: determines priority, decides whether to investigate
  v
Investigation created (if agent deems necessary)
  |
  v
EventBridge event: source=aws.aidevops, detail-type=Investigation Completed
```

### Setup Steps

```
1. register_service(service='pagerduty', ...)    # Register the third-party service
2. associate_service(agentSpaceId, serviceId)     # Associate with your Agent Space
3. list_webhooks(agentSpaceId, associationId)     # Get the generated webhook URL
4. Configure webhook URL in your third-party tool  # PagerDuty/GitLab/etc. sends alerts here
```

### Supported Service Types

| Service | Type | Auth |
|---------|------|------|
| PagerDuty | `pagerduty` | PagerDuty integration |
| GitLab | `gitlab` | GitLab webhook token |
| Dynatrace | `dynatrace` | HMAC signature |
| ServiceNow | `servicenow` | API key |
| Datadog | `mcpserverdatadog` | MCP server |
| Grafana | `mcpservergrafana` | MCP server |
| New Relic | `mcpservernewrelic` | MCP server |
| Splunk | `mcpserversplunk` | MCP server |
| Custom MCP | `mcpserver` | MCP server |
| Event Channel | `eventChannel` | Custom events |

### Webhook Authentication Types

| Type | Description |
|------|-------------|
| `hmac` | Request body signed with shared secret (HMAC-SHA256) |
| `apikey` | API key passed in request header |
| `gitlab` | GitLab webhook secret token |
| `pagerduty` | PagerDuty native integration |

## create_backlog_task API Flow

```
Your Code (Lambda, script, application)
  |
  | boto3: client.create_backlog_task(
  |     agentSpaceId='...',
  |     taskType='INVESTIGATION',
  |     title='...',
  |     priority='HIGH',
  |     description='...'
  | )
  v
DevOps Agent starts investigation immediately
  |  status: PENDING_START -> IN_PROGRESS -> COMPLETED
  v
EventBridge event: source=aws.aidevops, detail-type=Investigation Completed
```

### API Example

```python
import boto3

client = boto3.client("devops-agent", region_name="<YOUR_REGION>")

response = client.create_backlog_task(
    agentSpaceId="<YOUR_AGENT_SPACE_ID>",
    taskType="INVESTIGATION",
    title="High CPU on i-0abc123",
    priority="HIGH",
    description="CloudWatch alarm triggered. CPU > 80%. Please investigate root cause.",
)

task = response["task"]
print(f"taskId: {task['taskId']}")
print(f"executionId: {task['executionId']}")
print(f"status: {task['status']}")  # PENDING_START
```

### IAM Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "aidevops:CreateBacklogTask",
      "Resource": "*"
    }
  ]
}
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `agentSpaceId` | string | Yes | Agent Space ID |
| `taskType` | string | Yes | `"INVESTIGATION"` |
| `title` | string | Yes | Short title for the investigation |
| `priority` | string | No | `CRITICAL` / `HIGH` / `MEDIUM` / `LOW` / `MINIMAL` |
| `description` | string | No | Detailed description of what to investigate |

### Response

```json
{
  "task": {
    "agentSpaceId": "f95eb69d-...",
    "taskId": "3bb4e347-...",
    "executionId": "exe-ops1-f5998e4d-...",
    "title": "High CPU on i-0abc123",
    "taskType": "INVESTIGATION",
    "priority": "HIGH",
    "status": "PENDING_START",
    "createdAt": "2026-04-06T15:10:05Z",
    "updatedAt": "2026-04-06T15:10:05Z"
  }
}
```

## Key Differences in Behavior

### 1. Investigation Guarantee

- **Webhook**: Agent receives the alert and **decides autonomously** whether it warrants an investigation. Low-priority or duplicate alerts may not trigger one.
- **create_backlog_task**: Investigation is **always created** — you explicitly requested it with `taskType='INVESTIGATION'`.

### 2. Context Provided

- **Webhook**: Alert context comes from the third-party service's native format (PagerDuty incident, GitLab pipeline failure, etc.). Agent interprets it automatically.
- **create_backlog_task**: You control the `title` and `description` — you can include CloudWatch alarm details, instance IDs, metric values, or any context you want the agent to focus on.

### 3. Setup Complexity

- **Webhook**: Requires service registration, association, webhook URL configuration in the third-party tool. More moving parts but zero custom code.
- **create_backlog_task**: Requires writing code (Lambda/script) to call the API. More flexible but needs development and IAM setup.

## When to Use Which

| Scenario | Recommended Approach |
|----------|---------------------|
| Already using PagerDuty/Datadog/GitLab for alerting | **Webhook** — direct integration, no code needed |
| CloudWatch Alarm triggers investigation | **create_backlog_task** — use Lambda to bridge CloudWatch -> API |
| Custom application detects anomaly | **create_backlog_task** — full control over investigation context |
| Multiple third-party tools need to trigger investigations | **Webhook** — register each service separately |
| Need guaranteed investigation for every alert | **create_backlog_task** — always creates investigation |
| Want agent to auto-triage and prioritize | **Webhook** — agent decides what to investigate |
