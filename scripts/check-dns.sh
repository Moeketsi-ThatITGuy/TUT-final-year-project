#!/usr/bin/env bash
# Watch the Route 53 failover record and show which region is serving.
# Usage: scripts/check-dns.sh [interval_seconds]   (Ctrl+C to stop)
source "$(dirname "$0")/lib.sh"

INTERVAL="${1:-5}"
echo "Watching $FQDN via $NS (every ${INTERVAL}s). Ctrl+C to stop."
printf '%-20s %-16s %-22s %-12s %-26s\n' "TIME (UTC)" "DNS ANSWER" "ALB" "APP REGION" "DB (region / role)"

while true; do
  ip=$(resolve_failover_ip || true)
  if [[ -z "$ip" ]]; then
    printf '%-20s %s\n' "$(date -u +%H:%M:%S)" "no answer"
  else
    alb=$(which_alb "$ip")
    status=$(curl_via_ip "$ip" /api/status.php 2>/dev/null || echo '{}')
    app_region=$(jq -r '.app.region // "-"' <<<"$status" 2>/dev/null || echo "-")
    db=$(jq -r '"\(.db.region // "-") / \(.db.role // "unreachable")"' <<<"$status" 2>/dev/null || echo "-")
    printf '%-20s %-16s %-22s %-12s %-26s\n' "$(date -u +%H:%M:%S)" "$ip" "$alb" "$app_region" "$db"
  fi
  sleep "$INTERVAL"
done
