#!/bin/bash
# Checks a peer agent's health via SSM.
# Confirms the OpenClaw gateway process is alive on the peer instance.
# Tracks consecutive failures in STATE_FILE but does NOT send Slack alerts —
# alerting is each instance's own responsibility via its own heartbeat-check script.
# Silent on success. No LLM.
#
# Deploy this to the monitoring instance via SSM (see docs/peer-monitoring.md).
# Replace PEER_INSTANCE_PLACEHOLDER with the actual peer EC2 instance ID.

PEER_INSTANCE="PEER_INSTANCE_PLACEHOLDER"
REGION="eu-north-1"
STATE_FILE="/var/lib/hermes/openclaw-health-state.json"
STALE_SECONDS=3900  # 30-min heartbeat cron + 35-min grace window

mkdir -p /var/lib/hermes

# --- Run SSM check ---
CMD_ID=$(aws ssm send-command \
  --instance-ids "$PEER_INSTANCE" \
  --document-name AWS-RunShellScript \
  --parameters '{"commands":["pgrep -f \"openclaw gateway run\" > /dev/null && echo GATEWAY_ALIVE || echo GATEWAY_DEAD; systemctl is-active openclaw-gateway && echo SERVICE_ACTIVE || echo SERVICE_INACTIVE"]}' \
  --region "$REGION" \
  --query 'Command.CommandId' --output text 2>/dev/null)

if [ -z "$CMD_ID" ]; then
  ssm_failed=true
  output=""
else
  # Poll until the command reaches a terminal status (max 60s)
  output=""
  ssm_failed=true
  for i in $(seq 1 12); do
    sleep 5
    status=$(aws ssm get-command-invocation \
      --command-id "$CMD_ID" \
      --instance-id "$PEER_INSTANCE" \
      --region "$REGION" \
      --query 'Status' --output text 2>/dev/null)
    if [ "$status" = "Success" ] || [ "$status" = "Failed" ] || [ "$status" = "TimedOut" ]; then
      output=$(aws ssm get-command-invocation \
        --command-id "$CMD_ID" \
        --instance-id "$PEER_INSTANCE" \
        --region "$REGION" \
        --query 'StandardOutputContent' --output text 2>/dev/null)
      ssm_failed=false
      break
    fi
  done
fi

# --- Parse signals ---
gateway_alive=$(echo "$output" | grep -c "GATEWAY_ALIVE")
service_active=$(echo "$output" | grep -c "SERVICE_ACTIVE")

# --- Healthy path ---
if [ "$ssm_failed" = false ] && [ "$gateway_alive" -gt 0 ] && [ "$service_active" -gt 0 ]; then
  echo "{\"failures\":0,\"last_ok\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"alert_sent\":false}" > "$STATE_FILE"
  exit 0
fi

# --- Failure path: increment counter ---
prev=$(cat "$STATE_FILE" 2>/dev/null || echo '{}')
failures=$(echo "$prev" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('failures',0)+1)" 2>/dev/null || echo 1)
alert_sent=$(echo "$prev" | python3 -c "import sys,json; d=json.load(sys.stdin); print(str(d.get('alert_sent',False)).lower())" 2>/dev/null || echo false)
last_ok=$(echo "$prev" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('last_ok','unknown'))" 2>/dev/null || echo unknown)

echo "{\"failures\":$failures,\"last_ok\":\"$last_ok\",\"alert_sent\":$alert_sent,\"gateway_alive\":$gateway_alive,\"service_active\":$service_active}" > "$STATE_FILE"
exit 0
