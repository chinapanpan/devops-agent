"""
Lambda function: CloudWatch Alarm -> Feishu Notification
Triggered by EventBridge when a CloudWatch alarm changes state.
Sends a rich-text notification to Feishu with alarm details and
a link to the AIOps investigation in the CloudWatch console.
"""

import json
import os
import urllib.request
import urllib.error

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


def build_message(event):
    """Build a rich-text Feishu message from a CloudWatch Alarm EventBridge event."""
    detail = event.get("detail", {})
    alarm_name = detail.get("alarmName", "Unknown")
    state_value = detail.get("state", {}).get("value", "Unknown")
    previous_state = detail.get("previousState", {}).get("value", "Unknown")
    reason = detail.get("state", {}).get("reason", "N/A")
    timestamp = detail.get("state", {}).get("timestamp", event.get("time", "N/A"))
    region = event.get("region", AWS_REGION_NAME)
    account = event.get("account", "N/A")

    # Extract metric info
    config = detail.get("configuration", {})
    metrics = config.get("metrics", [])
    metric_info = "N/A"
    namespace = ""
    instance_id = ""
    if metrics:
        m = metrics[0].get("metricStat", {}).get("metric", {})
        metric_name = m.get("name", "")
        namespace = m.get("namespace", "")
        dims = m.get("dimensions", {})
        instance_id = dims.get("InstanceId", "")
        metric_info = f"{namespace}/{metric_name}"
        if instance_id:
            metric_info += f" (Instance: {instance_id})"

    # Build investigation console URL
    investigation_url = (
        f"https://{region}.console.aws.amazon.com/cloudwatch/home?"
        f"region={region}#investigations"
    )

    # State emoji
    state_icon = "🔴" if state_value == "ALARM" else "🟢" if state_value == "OK" else "🟡"

    content = {
        "zh_cn": {
            "title": f"{state_icon} CloudWatch Alarm: {alarm_name}",
            "content": [
                [
                    {"tag": "text", "text": "Alarm State: ", "style": ["bold"]},
                    {"tag": "text", "text": f"{previous_state} → {state_value}"},
                ],
                [
                    {"tag": "text", "text": "Metric: ", "style": ["bold"]},
                    {"tag": "text", "text": metric_info},
                ],
                [
                    {"tag": "text", "text": "Time: ", "style": ["bold"]},
                    {"tag": "text", "text": timestamp},
                ],
                [
                    {"tag": "text", "text": "Account: ", "style": ["bold"]},
                    {"tag": "text", "text": f"{account} / {region}"},
                ],
                [
                    {"tag": "text", "text": "Reason: ", "style": ["bold"]},
                    {"tag": "text", "text": reason[:200]},
                ],
                [{"tag": "text", "text": ""}],
                [
                    {"tag": "text", "text": "🤖 AIOps Investigation: ", "style": ["bold"]},
                    {"tag": "a", "href": investigation_url, "text": "View in CloudWatch Console"},
                ],
                [
                    {"tag": "text", "text": "An AI-powered investigation has been automatically started to analyze this alarm."},
                ],
            ],
        }
    }
    return content


def lambda_handler(event, context):
    print(f"Received event: {json.dumps(event)}")

    try:
        message_content = build_message(event)
        token = get_tenant_access_token()
        result = send_feishu_message(token, FEISHU_CHAT_ID, "post", message_content)
        print(f"Feishu message sent successfully: {json.dumps(result)}")
        return {"statusCode": 200, "body": "Message sent successfully"}
    except Exception as e:
        print(f"Error: {e}")
        raise
