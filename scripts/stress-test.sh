#!/bin/bash
set -euo pipefail

# ============================================================
# CPU Stress Test Script for DevOps Agent Demo
# ============================================================

AWS_REGION="${AWS_REGION:-us-west-2}"
ALARM_NAME="DevOps-Agent-Demo-CPU-High"
CPU_WORKERS="${1:-4}"
DURATION="${2:-180}"

echo "=== DevOps Agent Demo - CPU Stress Test ==="
echo "Region:      ${AWS_REGION}"
echo "CPU Workers: ${CPU_WORKERS}"
echo "Duration:    ${DURATION}s"
echo ""

# Check alarm state before test
echo "Pre-test alarm state: $(aws cloudwatch describe-alarms --alarm-names "${ALARM_NAME}" --region ${AWS_REGION} --query 'MetricAlarms[0].StateValue' --output text 2>/dev/null || echo 'N/A')"
echo ""

# Run stress
echo "Starting CPU stress at $(date)..."
stress --cpu ${CPU_WORKERS} --timeout ${DURATION}
echo "Stress completed at $(date)"
echo ""

# Wait for CloudWatch to process
echo "Waiting 60s for CloudWatch to process metrics..."
sleep 60

# Check alarm state after test
STATE=$(aws cloudwatch describe-alarms \
  --alarm-names "${ALARM_NAME}" \
  --region ${AWS_REGION} \
  --query 'MetricAlarms[0].{State:StateValue,Reason:StateReason}' \
  --output json 2>/dev/null)

echo "Post-test alarm state:"
echo "${STATE}" | python3 -m json.tool 2>/dev/null || echo "${STATE}"
echo ""
echo "Check your Feishu group for the notification!"
