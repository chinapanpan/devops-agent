"""
Lambda-B: DevOps Agent Investigation Completed → Feishu Notification
Triggered by EventBridge when DevOps Agent emits Investigation Completed event.
Retrieves investigation summary and sends to Feishu.
"""

import json
import os
import urllib.request
import boto3

DEVOPS_AGENT_SPACE_ID = os.environ["DEVOPS_AGENT_SPACE_ID"]
FEISHU_APP_ID = os.environ["FEISHU_APP_ID"]
FEISHU_APP_SECRET = os.environ["FEISHU_APP_SECRET"]
FEISHU_CHAT_ID = os.environ["FEISHU_CHAT_ID"]
AWS_REGION_NAME = os.environ.get("AWS_REGION", "us-west-2")
FEISHU_HOST = "https://open.feishu.cn"


def get_tenant_access_token():
    url = f"{FEISHU_HOST}/open-apis/auth/v3/tenant_access_token/internal"
    payload = json.dumps({"app_id": FEISHU_APP_ID, "app_secret": FEISHU_APP_SECRET}).encode()
    req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json; charset=utf-8"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read())
    if data.get("code") != 0:
        raise Exception(f"Failed to get Feishu token: {data}")
    return data["tenant_access_token"]


def send_feishu_message(token, chat_id, msg_type, content):
    url = f"{FEISHU_HOST}/open-apis/im/v1/messages?receive_id_type=chat_id"
    payload = json.dumps({
        "receive_id": chat_id,
        "msg_type": msg_type,
        "content": json.dumps(content),
    }).encode()
    req = urllib.request.Request(url, data=payload, headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json; charset=utf-8",
    })
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read())
    if data.get("code") != 0:
        raise Exception(f"Failed to send Feishu message: {data}")
    return data


def get_investigation_summary(agent_space_id, execution_id):
    """Retrieve investigation summary from DevOps Agent journal records."""
    client = boto3.client("devops-agent", region_name=AWS_REGION_NAME)

    response = client.list_journal_records(
        agentSpaceId=agent_space_id,
        executionId=execution_id,
    )
    records = response.get("records", [])
    print(f"Journal records count: {len(records)}, types: {set(r.get('recordType') for r in records)}")

    # Find the investigation_summary_md record (plain Markdown content)
    summary = ""
    for record in records:
        if record.get("recordType") == "investigation_summary_md":
            summary = record.get("content", "")
            break

    if not summary:
        # Fallback: try investigation_summary (JSON format)
        for record in records:
            if record.get("recordType") == "investigation_summary":
                content = record.get("content", "")
                try:
                    parsed = json.loads(content)
                    # Extract text from content array
                    for item in parsed.get("content", []):
                        if isinstance(item, dict) and "text" in item:
                            summary = item["text"]
                            break
                except (json.JSONDecodeError, TypeError):
                    summary = content
                break

    return summary if summary else "No investigation summary available."


def build_feishu_message(event_detail, summary):
    """Build rich-text Feishu message with investigation results."""
    metadata = event_detail.get("metadata", {})
    data = event_detail.get("data", {})

    task_id = metadata.get("task_id", "N/A")
    execution_id = metadata.get("execution_id", "N/A")
    priority = data.get("priority", "N/A")
    status = data.get("status", "COMPLETED")
    created_at = data.get("created_at", "N/A")
    updated_at = data.get("updated_at", "N/A")

    region = AWS_REGION_NAME
    console_url = f"https://{region}.console.aws.amazon.com/aidevops/home?region={region}"

    # Truncate summary if too long for Feishu
    if len(summary) > 2000:
        summary = summary[:2000] + "\n... (truncated)"

    content = {
        "zh_cn": {
            "title": "\U0001f50d DevOps Agent Investigation Completed",
            "content": [
                [
                    {"tag": "text", "text": "Task ID: ", "style": ["bold"]},
                    {"tag": "text", "text": task_id},
                ],
                [
                    {"tag": "text", "text": "Priority: ", "style": ["bold"]},
                    {"tag": "text", "text": priority},
                ],
                [
                    {"tag": "text", "text": "Status: ", "style": ["bold"]},
                    {"tag": "text", "text": status},
                ],
                [
                    {"tag": "text", "text": "Created: ", "style": ["bold"]},
                    {"tag": "text", "text": created_at},
                ],
                [
                    {"tag": "text", "text": "Completed: ", "style": ["bold"]},
                    {"tag": "text", "text": updated_at},
                ],
                [{"tag": "text", "text": ""}],
                [
                    {"tag": "text", "text": "\U0001f4cb Investigation Summary:", "style": ["bold"]},
                ],
                [
                    {"tag": "text", "text": summary},
                ],
                [{"tag": "text", "text": ""}],
                [
                    {"tag": "text", "text": "\U0001f517 "},
                    {"tag": "a", "href": console_url, "text": "View in DevOps Agent Console"},
                ],
            ],
        }
    }
    return content


def lambda_handler(event, context):
    print(f"Received event: {json.dumps(event)}")

    detail = event.get("detail", {})
    metadata = detail.get("metadata", {})
    agent_space_id = metadata.get("agent_space_id", DEVOPS_AGENT_SPACE_ID)
    execution_id = metadata.get("execution_id", "")

    if not execution_id:
        print("ERROR: No execution_id in event")
        return {"statusCode": 400, "body": "Missing execution_id"}

    try:
        # Get investigation summary
        summary = get_investigation_summary(agent_space_id, execution_id)
        print(f"Investigation summary ({len(summary)} chars): {summary[:500]}")

        # Build and send Feishu message
        feishu_content = build_feishu_message(detail, summary)
        token = get_tenant_access_token()
        result = send_feishu_message(token, FEISHU_CHAT_ID, "post", feishu_content)
        print(f"Feishu message sent: {json.dumps(result)}")

        return {"statusCode": 200, "body": "Notification sent"}

    except Exception as e:
        print(f"Error: {e}")
        # Try to send error notification to Feishu
        try:
            token = get_tenant_access_token()
            fallback = {
                "zh_cn": {
                    "title": "\u26a0\ufe0f DevOps Agent Notification Error",
                    "content": [
                        [{"tag": "text", "text": f"Failed to process investigation result: {str(e)[:300]}"}],
                        [{"tag": "text", "text": f"Execution ID: {execution_id}"}],
                    ],
                }
            }
            send_feishu_message(token, FEISHU_CHAT_ID, "post", fallback)
        except Exception as e2:
            print(f"Fallback notification also failed: {e2}")
        raise
