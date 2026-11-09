#!/usr/bin/env bash
# Bring Region 1 back after simulate-failure.sh. Route 53 fails back
# automatically once the health check passes again.
source "$(dirname "$0")/lib.sh"

ids="$(tfo_json primary_web_instance_ids | jq -r '.[]') $(tfo_json primary_app_instance_ids | jq -r '.[]')"

echo "Starting Region 1 ($PRIMARY_REGION) instances: $ids"
# shellcheck disable=SC2086
aws ec2 start-instances --region "$PRIMARY_REGION" --instance-ids $ids \
  --query 'StartingInstances[].[InstanceId,CurrentState.Name]' --output text
# shellcheck disable=SC2086
aws ec2 wait instance-running --region "$PRIMARY_REGION" --instance-ids $ids
echo "Instances running. ALB + Route 53 will mark Region 1 healthy in ~1-2 min."
