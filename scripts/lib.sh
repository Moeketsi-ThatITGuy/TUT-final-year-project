#!/usr/bin/env bash
# Shared helpers for the demo scripts. Reads values from `terraform output`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' is required" >&2; exit 1; }; }
need terraform
need aws
need jq
need curl
need dig

tfo() { terraform -chdir="$TF_DIR" output -raw "$1"; }
tfo_json() { terraform -chdir="$TF_DIR" output -json "$1"; }

# Pick up aws_profile from terraform.tfvars if the user set it there.
if [[ -z "${AWS_PROFILE:-}" && -f "$TF_DIR/terraform.tfvars" ]]; then
  prof=$(sed -nE 's/^[[:space:]]*aws_profile[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$TF_DIR/terraform.tfvars" | head -1)
  [[ -n "$prof" ]] && export AWS_PROFILE="$prof"
fi

PRIMARY_REGION=$(tfo primary_region)
SECONDARY_REGION=$(tfo secondary_region)
FQDN=$(tfo failover_fqdn)
NS=$(tfo_json route53_name_servers | jq -r '.[0]')
PRIMARY_ALB_DNS=$(tfo primary_alb_dns_name)
SECONDARY_ALB_DNS=$(tfo secondary_alb_dns_name)

# Resolve the failover record straight from Route 53's authoritative server
# (works even if you don't own the domain), then return the first IP.
resolve_failover_ip() {
  dig +short +time=3 +tries=2 "@$NS" "$FQDN" A | grep -E '^[0-9.]+$' | head -1
}

# All public IPs of an ALB. DNS only returns a rotating subset, so read the
# ALB's network interfaces from the EC2 API (plus DNS as a fallback).
#   $1 = ALB DNS name, $2 = region
alb_ips() {
  local dns="$1" region="$2" name
  name=$(sed -E 's/-[0-9]+\..*$//' <<<"$dns")   # univen-primary-alb-123.us-east-1... -> univen-primary-alb
  aws ec2 describe-network-interfaces --region "$region" \
    --filters "Name=description,Values=ELB app/$name/*" \
    --query 'NetworkInterfaces[].Association.PublicIp' --output text 2>/dev/null | tr '\t' '\n' || true
  dig +short "$dns" | grep -E '^[0-9.]+$' || true
}

refresh_alb_ips() {
  PRIMARY_ALB_IPS=$(alb_ips "$PRIMARY_ALB_DNS" "$PRIMARY_REGION")
  SECONDARY_ALB_IPS=$(alb_ips "$SECONDARY_ALB_DNS" "$SECONDARY_REGION")
}
# Warm the cache here, in the parent shell, so $(which_alb ...) subshells
# inherit it and only hit the API again on a miss (e.g. ALB scaled).
refresh_alb_ips

# Which ALB does an IP belong to?
which_alb() {
  local ip="$1" try
  for try in 1 2; do
    if [[ $try == 2 ]]; then refresh_alb_ips; fi
    if grep -qxF "$ip" <<<"$PRIMARY_ALB_IPS"; then echo "REGION 1 ($PRIMARY_REGION)"; return; fi
    if grep -qxF "$ip" <<<"$SECONDARY_ALB_IPS"; then echo "BACKUP ($SECONDARY_REGION)"; return; fi
  done
  echo "unknown"
}

# GET a path through a specific IP while sending the failover hostname.
curl_via_ip() {
  local ip="$1" path="$2"
  curl -sS --max-time 10 -H "Host: $FQDN" "http://$ip$path"
}
