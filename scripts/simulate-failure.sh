#!/usr/bin/env bash
# Simulate a Region 1 outage by stopping its web servers.
# The ALB loses all healthy targets -> Route 53 health check fails ->
# the failover record starts answering with the backup region's ALB.
#
# Usage: scripts/simulate-failure.sh [--all]   (--all also stops the app tier)
source "$(dirname "$0")/lib.sh"

ids=$(tfo_json primary_web_instance_ids | jq -r '.[]')
if [[ "${1:-}" == "--all" ]]; then
  ids="$ids $(tfo_json primary_app_instance_ids | jq -r '.[]')"
fi

echo "Stopping Region 1 ($PRIMARY_REGION) instances: $ids"
# shellcheck disable=SC2086
aws ec2 stop-instances --region "$PRIMARY_REGION" --instance-ids $ids \
  --query 'StoppingInstances[].[InstanceId,CurrentState.Name]' --output text

echo
echo "Route 53 checks every 10s and fails after 2 misses, so expect the switch in ~30-90s."
echo "Watch it with: scripts/check-dns.sh"
echo "Undo with:     scripts/restore.sh"
