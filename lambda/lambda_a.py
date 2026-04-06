"""
Lambda-A: CloudWatch Alarm → DevOps Agent Investigation
Triggered by EventBridge when CloudWatch alarm transitions to ALARM state.
Calls create_backlog_task to start a DevOps Agent investigation.
"""

import json
import os
import boto3

DEVOPS_AGENT_SPACE_ID = os.environ["DEVOPS_AGENT_SPACE_ID"]
AWS_REGION_NAME = os.environ.get("AWS_REGION", "us-west-2")


def lambda_handler(event, context):
    print(f"Received event: {json.dumps(event)}")

    detail = event.get("detail", {})
    state_value = detail.get("state", {}).get("value", "")

    # Only trigger investigation for ALARM state
    if state_value != "ALARM":
        print(f"Skipping non-ALARM state: {state_value}")
        return {"statusCode": 200, "body": f"Skipped: state={state_value}"}

    # Extract alarm details
    alarm_name = detail.get("alarmName", "Unknown")
    reason = detail.get("state", {}).get("reason", "N/A")
    config = detail.get("configuration", {})
    metrics = config.get("metrics", [])

    instance_id = ""
    metric_name = ""
    if metrics:
        m = metrics[0].get("metricStat", {}).get("metric", {})
        metric_name = m.get("name", "")
        dims = m.get("dimensions", {})
        instance_id = dims.get("InstanceId", "")

    description = (
        f"CloudWatch Alarm '{alarm_name}' triggered.\n"
        f"State: {state_value}\n"
        f"Metric: {metric_name}\n"
        f"EC2 Instance: {instance_id}\n"
        f"Reason: {reason}\n\n"
        f"Please investigate the root cause of high CPU utilization "
        f"and provide remediation recommendations."
    )

    title = f"Investigate: {alarm_name} - {instance_id or 'unknown instance'}"

    client = boto3.client("devops-agent", region_name=AWS_REGION_NAME)

    try:
        response = client.create_backlog_task(
            agentSpaceId=DEVOPS_AGENT_SPACE_ID,
            taskType="INVESTIGATION",
            title=title,
            priority="HIGH",
            description=description,
        )
        print(f"create_backlog_task response: {json.dumps(response, default=str)}")
        task = response.get("task", {})
        task_id = task.get("taskId", "")
        execution_id = task.get("executionId", "")
        status = task.get("status", "")
        print(f"Investigation created: taskId={task_id}, executionId={execution_id}, status={status}")

        return {
            "statusCode": 200,
            "body": json.dumps({
                "message": "Investigation triggered",
                "taskId": task_id,
                "executionId": execution_id,
                "status": status,
            }),
        }

    except Exception as e:
        print(f"Error creating investigation: {e}")
        raise
