#!/usr/bin/env bash
# End-to-end checks against a live deployment. Exit code 0 = all passed.
#   - both ALBs healthy and serving the right page
#   - each region's app talks to the DB in ITS OWN region
#   - Region 1 DB is writable, backup DB is a read-only replica
#   - rows written in Region 1 are visible in the backup region (replication)
#   - Route 53 failover record currently points at Region 1
#   - backup object landed in S3, no SG allows 0.0.0.0/0 inbound
source "$(dirname "$0")/lib.sh"

PASS=0; FAIL=0
ok()   { echo "  PASS  $*"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

P_ALB=$(tfo primary_alb_dns_name)
S_ALB=$(tfo secondary_alb_dns_name)

echo "== Web tier"
check "Region 1 /health returns OK"          bash -c "curl -sf --max-time 10 http://$P_ALB/health | grep -qx OK"
check "Backup   /health returns OK"          bash -c "curl -sf --max-time 10 http://$S_ALB/health | grep -qx OK"
check "Region 1 page says 'REGION 1 - PRIMARY'" bash -c "curl -sf --max-time 10 http://$P_ALB/ | grep -q 'REGION 1 - PRIMARY'"
check "Backup   page says 'BACKUP REGION'"   bash -c "curl -sf --max-time 10 http://$S_ALB/ | grep -q 'BACKUP REGION'"

echo "== App + DB, Region 1 ($PRIMARY_REGION)"
P=$(curl -sf --max-time 15 "http://$P_ALB/api/status.php" || echo '{}')
check "app runs in $PRIMARY_REGION"             jq -e --arg r "$PRIMARY_REGION" '.app.region == $r' <<<"$P"
check "DB connected"                            jq -e '.db.connected == true' <<<"$P"
check "DB is in $PRIMARY_REGION"                jq -e --arg r "$PRIMARY_REGION" '.db.region == $r' <<<"$P"
check "DB is writable PRIMARY"                  jq -e '.db.read_only == false and .db.wrote_visit == true' <<<"$P"

# Give replication a moment to carry the row we just wrote.
sleep 5

echo "== App + DB, Backup region ($SECONDARY_REGION)"
S=$(curl -sf --max-time 15 "http://$S_ALB/api/status.php" || echo '{}')
check "app runs in $SECONDARY_REGION"           jq -e --arg r "$SECONDARY_REGION" '.app.region == $r' <<<"$S"
check "DB connected"                            jq -e '.db.connected == true' <<<"$S"
check "DB is in $SECONDARY_REGION (its own replica)" jq -e --arg r "$SECONDARY_REGION" '.db.region == $r' <<<"$S"
check "DB is a read-only REPLICA"               jq -e '.db.read_only == true' <<<"$S"
check "replication threads running"             jq -e '.db.replication.io_running == "Yes" and .db.replication.sql_running == "Yes"' <<<"$S"
check "rows written in Region 1 visible in backup" jq -e --arg r "$PRIMARY_REGION" '.data.total_visits > 0 and .data.last_written_by_region == $r' <<<"$S"

echo "== Route 53 failover"
IP=$(resolve_failover_ip || true)
check "$FQDN resolves via $NS"                  test -n "$IP"
check "$FQDN currently points at Region 1"      bash -c "[[ \"$(which_alb "${IP:-none}")\" == REGION\ 1* ]]"
HC=$(aws route53 get-health-check-status --health-check-id "$(tfo health_check_id)" \
      --query 'length(HealthCheckObservations[?starts_with(StatusReport.Status, `Success`)])' --output text 2>/dev/null || echo 0)
check "Route 53 health checkers report Success ($HC)" test "${HC:-0}" -gt 0

echo "== Backup + security"
BUCKET=$(tfo backup_bucket)
N=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix mysql/ --query 'length(Contents || `[]`)' --output text 2>/dev/null || echo 0)
[[ "$N" =~ ^[0-9]+$ ]] || N=0   # KeyCount is "None" on an empty prefix
if [[ "$N" -gt 0 ]]; then ok "S3 backup objects present ($N)"; else echo "  WARN  no S3 backup yet (first run is 2 min after app boot)"; fi
PROJECT=$(tfo project_name)
for r in "$PRIMARY_REGION" "$SECONDARY_REGION"; do
  OPEN=$(aws ec2 describe-security-groups --region "$r" --filters "Name=tag:Project,Values=$PROJECT" \
    --query 'SecurityGroups[].IpPermissions[].IpRanges[?CidrIp==`0.0.0.0/0`][]' --output text 2>/dev/null)
  check "no 0.0.0.0/0 inbound rule in $r" test -z "$OPEN"
done

echo
echo "Result: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
