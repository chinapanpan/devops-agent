# AWS DevOps Agent Chat API Guide

## Overview

AWS DevOps Agent provides a **Chat API** for interactive, real-time conversations with the agent. Unlike the `create_backlog_task` API (asynchronous investigation), the Chat API returns **streaming responses** immediately, making it suitable for interactive tools, chatbots, or real-time analysis.

### Chat API vs Backlog Task API

| Feature | Chat API | Backlog Task API |
|---------|----------|-----------------|
| Response | Synchronous streaming | Asynchronous (EventBridge) |
| Use case | Interactive Q&A, real-time analysis | Formal investigation with lifecycle |
| Multi-turn | Yes (same executionId) | No |
| Tool calls | Agent calls AWS APIs in real-time | Agent runs autonomously |
| Result format | Streaming EventStream | Journal records (Markdown) |

## Prerequisites

- An AWS DevOps Agent Space with AWS account association
- boto3 with `devops-agent` service support (latest version required)
- IAM permissions: `aidevops:CreateChat`, `aidevops:SendMessage`

### IAM Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "aidevops:CreateChat",
        "aidevops:SendMessage"
      ],
      "Resource": "*"
    }
  ]
}
```

> **Note**: The IAM action prefix is `aidevops`, not `devops-agent`.

## API Reference

### 1. create_chat

Creates a new chat session with the DevOps Agent.

```python
import boto3

client = boto3.client("devops-agent", region_name="<YOUR_REGION>")

response = client.create_chat(
    agentSpaceId="<YOUR_AGENT_SPACE_ID>",
    userId="my-user-id",
    userType="IAM",
)

execution_id = response["executionId"]
created_at = response["createdAt"]
```

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `agentSpaceId` | string | Yes | Your DevOps Agent Space ID |
| `userId` | string | Yes | User identifier. Must match `^[a-zA-Z0-9_.-]+$` (no ARNs, no special chars) |
| `userType` | string | Yes | User type, e.g. `"IAM"` |

**Response:**
```json
{
  "executionId": "27f785ae-2b70-460f-9da2-56b3dc4efe3d",
  "createdAt": "2026-04-10T06:54:21.367Z"
}
```

### 2. send_message

Sends a message to the agent and receives a streaming response.

```python
response = client.send_message(
    agentSpaceId="<YOUR_AGENT_SPACE_ID>",
    executionId=execution_id,
    content="What EC2 instances are running in this account?",
    userId="my-user-id",
)

# Process the streaming EventStream
for event in response["events"]:
    if "contentBlockDelta" in event:
        delta = event["contentBlockDelta"]
        text = delta.get("delta", {}).get("textDelta", {}).get("text", "")
        if text:
            print(text, end="", flush=True)
```

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `agentSpaceId` | string | Yes | Your DevOps Agent Space ID |
| `executionId` | string | Yes | From `create_chat()` response |
| `content` | string | Yes | The message to send |
| `userId` | string | Yes | Must match the userId from `create_chat()` |

**Response:** Returns an `EventStream` object with streaming events.

### 3. Multi-turn Conversation

Use the same `executionId` to continue the conversation. The agent retains context from previous messages.

```python
# First message
response1 = client.send_message(
    agentSpaceId=SPACE_ID,
    executionId=execution_id,
    content="List all running EC2 instances.",
    userId=USER_ID,
)
# ... process response1 ...

# Follow-up (agent remembers previous context)
response2 = client.send_message(
    agentSpaceId=SPACE_ID,
    executionId=execution_id,
    content="Which of those instances has the highest CPU?",
    userId=USER_ID,
)
# ... process response2 ...
```

## EventStream Event Types

The `send_message` response contains an iterable `events` stream with these event types:

| Event Type | Description |
|------------|-------------|
| `responseCreated` | Response started |
| `responseInProgress` | Agent is processing |
| `contentBlockStart` | A new content block begins (text or tool call) |
| `contentBlockDelta` | Incremental content: `textDelta` (text) or `jsonDelta` (tool calls/results) |
| `contentBlockStop` | A content block ends |
| `heartbeat` | Keep-alive signal during long operations |
| `responseCompleted` | Response finished |
| `responseFailed` | Error occurred |

### Event Structure

```python
# Text content
{
    "contentBlockDelta": {
        "index": 0,
        "delta": {
            "textDelta": {
                "text": "Here are your running instances..."
            }
        }
    }
}

# Tool call (agent calling AWS APIs)
{
    "contentBlockDelta": {
        "index": 1,
        "delta": {
            "jsonDelta": {
                "partialJson": "{\"type\": \"tool_call\", \"name\": \"use_aws\", ...}"
            }
        }
    }
}

# Tool result
{
    "contentBlockDelta": {
        "index": 1,
        "delta": {
            "jsonDelta": {
                "partialJson": "{\"type\": \"tool_result\", \"status\": \"success\", ...}"
            }
        }
    }
}

# Error
{
    "responseFailed": {
        "errorMessage": "error description"
    }
}
```

## Complete Example

A full working example that creates a chat, sends a message, and parses the streaming response:

```python
import boto3
import json
from collections import Counter

AGENT_SPACE_ID = "<YOUR_AGENT_SPACE_ID>"
REGION = "<YOUR_REGION>"
USER_ID = "my-app-user"


def parse_streaming_response(response):
    """Parse EventStream and return full text response."""
    event_types = Counter()
    text_blocks = {}

    for event in response["events"]:
        for key in event.keys():
            if key != "ResponseMetadata":
                event_types[key] += 1

        if "contentBlockDelta" in event:
            delta = event["contentBlockDelta"]
            idx = delta.get("index", 0)
            if idx not in text_blocks:
                text_blocks[idx] = []

            # Collect text content
            text = delta.get("delta", {}).get("textDelta", {}).get("text", "")
            if text:
                text_blocks[idx].append(text)

        elif "responseFailed" in event:
            raise Exception(f"Agent error: {event['responseFailed']}")

    # Reconstruct full response from text blocks
    full_text = ""
    for idx in sorted(text_blocks.keys()):
        full_text += "".join(text_blocks[idx])

    return full_text, dict(event_types)


def main():
    client = boto3.client("devops-agent", region_name=REGION)

    # Step 1: Create chat session
    chat = client.create_chat(
        agentSpaceId=AGENT_SPACE_ID,
        userId=USER_ID,
        userType="IAM",
    )
    execution_id = chat["executionId"]
    print(f"Chat created: executionId={execution_id}")

    # Step 2: Send message
    response = client.send_message(
        agentSpaceId=AGENT_SPACE_ID,
        executionId=execution_id,
        content="What EC2 instances are running in this account?",
        userId=USER_ID,
    )
    text, stats = parse_streaming_response(response)
    print(f"Event stats: {stats}")
    print(f"Agent response:\n{text}")

    # Step 3: Follow-up question (multi-turn)
    response2 = client.send_message(
        agentSpaceId=AGENT_SPACE_ID,
        executionId=execution_id,
        content="Which one has the highest CPU utilization?",
        userId=USER_ID,
    )
    text2, stats2 = parse_streaming_response(response2)
    print(f"\nFollow-up response:\n{text2}")


if __name__ == "__main__":
    main()
```

## Test Results

Tested on 2026-04-10 with Agent Space `demo`:

| Test | Description | Events | Duration | Result |
|------|-------------|--------|----------|--------|
| create_chat | Create session | - | <1s | PASS |
| send_message | List EC2 instances | 123 events (6 tool calls) | 23.6s | PASS |
| Multi-turn | Follow-up: highest CPU | 293 events (19 tool calls) | 51.9s | PASS |

Key observations:
- Agent automatically calls AWS APIs (`ec2.describe_instances`, `cloudwatch.get_metric_statistics`) via `use_aws` tool
- Multi-turn context is preserved: follow-up question correctly referenced instances from the first response
- Response includes both text blocks and JSON tool call/result blocks interleaved

## Important Notes

1. **boto3 version**: The default Lambda runtime boto3 does NOT include the `devops-agent` service. Use a Lambda Layer with the latest boto3, or run from an environment with an updated boto3.
2. **userId format**: Must match `^[a-zA-Z0-9_.-]+$`. Using an IAM ARN will cause a `ValidationException`.
3. **Streaming duration**: Responses can take 20-60+ seconds as the agent calls multiple AWS APIs. Set appropriate timeouts.
4. **Text vs JSON blocks**: Text blocks contain the agent's natural language response. JSON blocks contain tool calls and results. Filter by `textDelta` to get only the readable response.
5. **IAM prefix**: All IAM actions use the `aidevops` prefix (e.g., `aidevops:CreateChat`), not `devops-agent`.
