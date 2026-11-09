#!/usr/bin/env bash
# OPTIONAL, one-way: promote the backup-region read replica to a standalone,
# writable database (what you'd do in a real, prolonged Region 1 outage).
#
# After this, replication is broken for good. Terraform will want to recreate
# the replica on the next apply. For the demo, run it only at the end, then
# `terraform destroy`.
source "$(dirname "$0")/lib.sh"

DB_ID=$(tfo secondary_db_identifier)
read -r -p "Promote $DB_ID in $SECONDARY_REGION to a standalone primary? This cannot be undone. [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

aws rds promote-read-replica --region "$SECONDARY_REGION" --db-instance-identifier "$DB_ID" \
  --backup-retention-period 1 --query 'DBInstance.DBInstanceStatus' --output text
echo "Waiting for $DB_ID to become available (a few minutes)..."
aws rds wait db-instance-available --region "$SECONDARY_REGION" --db-instance-identifier "$DB_ID"
echo "Done. The backup region page will now show the DB as PRIMARY (writable)."
