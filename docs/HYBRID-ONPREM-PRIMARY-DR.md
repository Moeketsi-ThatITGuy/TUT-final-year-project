# Hybrid DR: On-Prem Primary, AWS as Backup

The live demo fails over **AWS Region 1 → AWS Region 2**. This document explains the same idea when the
**UNIVEN campus data centre is the primary** and **AWS is the DR site**, plus how to move from manual to
automatic database promotion.

---

## 1. The one-paragraph explanation

> "Normally, users go to the campus data centre. Route 53 owns our public DNS. It health-checks the campus
> website from several locations around the world, every 10 seconds. The campus database replicates
> continuously over the site-to-site VPN into an RDS database in AWS, and a small web/app stack sits ready
> in AWS. If the campus goes offline (power, ISP, or a failed server), the health checks fail, and Route 53
> automatically answers with the AWS address instead. When the campus is fixed, we resync the data and
> switch back in a planned window."

## 2. What maps to what

| Role | Current demo (cloud-to-cloud) | Hybrid (on-prem primary) |
|---|---|---|
| Primary site | AWS us-east-1 | Campus DC (WEB-1/2, DB-PRI) |
| DR site | AWS us-west-2 | AWS us-east-1 (this Terraform's Region 1 stack) |
| User entry point | `app.univen-dr-demo.com` | e.g. `www.univen.ac.za` (public zone in Route 53) |
| PRIMARY DNS answer | Region 1 ALB (alias) | Campus public IPs **196.21.100.2** (R1, ISP A) + **41.76.200.2** (R2, ISP B) |
| SECONDARY DNS answer | Region 2 ALB | AWS ALB |
| Health check target | Region 1 ALB `/health` | Campus public IPs `/health` (via R1/R2 static NAT → WEB-1/2) |
| Data replication | RDS cross-region read replica | DB-PRI (MySQL) → RDS MySQL, binlog replication **over the VPN** |
| Link between sites | none needed | Site-to-site VPN: VPN-GW1/2 ↔ AWS VGW (2 ISPs, BGP) |
| Backups | App servers → S3 via gateway endpoint | BKP/NAS → S3 over the VPN (off-site copy) |

## 3. How the DNS check and change works

**DNS records** (public hosted zone in Route 53):

```
www.univen.ac.za  A  PRIMARY    196.21.100.2, 41.76.200.2   TTL 60   health check = HC-CAMPUS
www.univen.ac.za  A  SECONDARY  alias → AWS ALB                       (evaluate target health)
```

**Health checks:**

| ID | Type | What it checks |
|---|---|---|
| HC-ISPA | HTTP | `http://196.21.100.2/health` (campus via ISP A) |
| HC-ISPB | HTTP | `http://41.76.200.2/health` (campus via ISP B) |
| HC-HEARTBEAT | CloudWatch alarm | on-prem heartbeat metric (section 4); *insufficient data = unhealthy* |
| HC-CAMPUS | **Calculated** | healthy if HC-HEARTBEAT is healthy **and** at least 1 of HC-ISPA / HC-ISPB is healthy |

**Flow:**
1. Route 53 checkers in 3+ regions send `GET /health` every 10 s.
2. If a check fails 2 times in a row at most checkers, that child check is unhealthy.
3. HC-CAMPUS goes unhealthy when **both ISPs fail**, or when the **heartbeat stops**.
4. Route 53 stops returning the campus IPs and returns the AWS ALB. Clients switch when their cached answer expires (TTL 60 s).
5. When HC-CAMPUS is healthy again, Route 53 returns the campus IPs. **Only allow this after the data is resynced** (section 6).

> **Campus users inside the network:** internal DNS-1/DNS-2 answer `www` with 172.16.210.10, so they never fail over.
> Fix: on DNS-1/2, forward the DR-protected name to Route 53 (conditional forwarder). This is the same idea as
> `scripts/local-dns.sh`, applied to the whole campus.

## 4. What goes on-prem so AWS knows there is an outage

| Item | Where | Purpose |
|---|---|---|
| **`/health` endpoint** | WEB-1, WEB-2 | A *deep* check: returns 200 only if the web app **and** DB-PRI respond. Published through the existing R1/R2 static NAT (port 80). |
| **Firewall / ACL rule** | FW1/FW2 ZBF + R1/R2 `WAN-IN` ACL | Allow TCP 80 from the **Route 53 health-checker IP ranges** to the published web IPs. Without this, every check fails and you fail over by mistake. |
| **Heartbeat agent** | BKP server (or a small monitoring VM) | Every 60 s: checks the critical services (web, DB, DNS), then sends `PutMetricData` `UNIVEN/OnPrem Heartbeat=1` to CloudWatch. If the campus dies, the metric stops, the alarm goes to ALARM, and HC-HEARTBEAT becomes unhealthy. |
| **AWS credentials for the agent** | BKP server | **IAM Roles Anywhere** (X.509 certificate from the campus CA): short-lived credentials, no stored access keys. The policy allows only `cloudwatch:PutMetricData`. |
| **MySQL replication user + binlog** | DB-PRI | `binlog_format=ROW`, GTID on, a replication user restricted to the RDS subnet (10.0.2.0/24, 10.0.4.0/24). TLS required. |
| **VPN** | VPN-GW1/GW2 | Carries DB replication (TCP 3306) and backups. Two ISPs, so one ISP failing doesn't break replication. |
| **Maintenance switch** | Admin | For planned work, set HC-CAMPUS to *inverted* to force traffic to AWS on purpose. |

**Why both the HTTP checks and a heartbeat?**
- **HTTP checks** catch "the campus is unreachable from the internet".
- **The heartbeat** catches "the campus is reachable, but things are broken inside", and it shows up in CloudWatch for alerting.

## 5. Data path (on-prem MySQL → AWS)

1. RDS MySQL in AWS is set up as a replica of DB-PRI (*replication from an external source*):
   ```sql
   CALL mysql.rds_set_external_source_with_auto_position('172.16.230.10', 3306, 'repl', '<from Secrets Manager>', 1);
   CALL mysql.rds_start_replication;
   ```
2. The DB SG allows TCP 3306 from 172.16.230.10/32 over the VPN (it currently allows only the app SG).
3. The AWS app servers read from it as a read-only copy until it's promoted.
4. **RPO:** seconds (async replication lag), as long as the VPN is up. A nightly dump to S3 is the fallback if the VPN is down for a long time.

## 6. Failback (campus is fixed)

1. Keep traffic on AWS: the primary health check stays *inverted*.
2. Make DB-PRI a **replica of RDS**, so it catches up on the writes made during the outage. Keep binlogs on RDS for 24 h with `mysql.rds_set_configuration('binlog retention hours', 24)`.
3. In a maintenance window: stop writes in AWS, wait for lag = 0, promote DB-PRI, and point RDS back at DB-PRI as its source.
4. Un-invert the health check, and Route 53 sends users back to the campus.

---

## 7. Manual → automatic database promotion

**Today:**
- Failover of **traffic** is automatic (Route 53).
- Promotion of the **database** is manual (`scripts/promote-replica.sh`), so in DR the site is **read-only** until a person acts.
- RDS promotes a Multi-AZ standby automatically *inside* a region. Cross-region (or on-prem → AWS) promotion is **never automatic out of the box**: you have to automate the trigger.

### Design: "DR watchdog"

```
Route 53 HC  ─┐
Heartbeat    ─┼─> CloudWatch composite alarm ─> EventBridge rule ─> Lambda "dr-promote"
Replication  ─┘   (all say "primary down"                           1. guard checks
 IO thread         for >= 5 min)                                     2. promote DB
                                                                     3. fence + pin DNS
                                                                     4. SNS notify
```

**Signals (all three must agree; this avoids promoting on a blip):**
1. **Route 53 health check unhealthy** (`HealthCheckStatus` < 1).
2. **Heartbeat missing** (hybrid) or **Region 1 `/health` failing from the DR region** (cloud-to-cloud).
3. **Replication broken:** the replica's IO thread is not connected and lag is unknown, so the source database is really gone, not just the website.

These go into a **CloudWatch composite alarm** that must stay in ALARM for **5 minutes**. This is your tolerance: shorter means a lower RTO but a higher risk of false promotion.

**Lambda `dr-promote` steps:**
1. **Guard:**
   - an SSM parameter `/univen/dr/auto-promote` = `enabled` (kill switch);
   - the DB is not already promoted;
   - replica lag before the outage was under N seconds (it records the RPO).
2. **Promote:**
   - Cloud-to-cloud: `rds:PromoteReadReplica` on `univen-secondary-mysql-replica`.
   - Hybrid: `CALL mysql.rds_stop_replication; CALL mysql.rds_reset_external_source;`
   - Then wait until the instance is `available`. The app needs no change: it already connects to its own region's DB, and it becomes writable.
3. **Fence the old primary, so it can't come back and accept writes (split-brain):**
   - **Pin DNS:** set the PRIMARY health check to `Inverted = true`, so the old site stays "unhealthy" when it returns. Don't "disable" it: Route 53 treats a *disabled* health check as **healthy**.
   - Cloud-to-cloud: also remove the old primary's DB SG ingress, or stop it, if its region is reachable.
   - Hybrid: page the on-prem team. DB-PRI must start as `read_only` until failback.
4. **Notify:** SNS email/SMS with the timestamp, the replica lag at promotion (that's the RPO), and the next steps.

**Where to run it:**
- Run the watchdog **in the DR site**, never in the site it's protecting.
- Hybrid: AWS is the DR site, so Lambda in us-east-1 is fine.
- Cloud-to-cloud:
  - Route 53 health-check metrics live in us-east-1, which is also the region that might be down.
  - So run the Lambda in **us-west-2**, on an EventBridge schedule (every 1 min), and let it probe Region 1 itself.
  - It needs a VPC Lambda behind the us-west-2 NAT. Add that NAT's EIP to the Region 1 ALB allow-list.
  - For production, use **Route 53 Application Recovery Controller** routing controls. Their data plane is spread across 5 regions, so the "switch" still works when a region is down.

**Terraform pieces:**
- `aws_cloudwatch_metric_alarm` (replica-broken, heartbeat or probe) and `aws_cloudwatch_composite_alarm`
- `aws_cloudwatch_event_rule` + `aws_cloudwatch_event_target` (or `aws_scheduler_schedule`)
- `aws_lambda_function` + an IAM role limited to `rds:PromoteReadReplica` / `rds:DescribeDBInstances` on the replica, `route53:UpdateHealthCheck` on the primary check, `ssm:GetParameter` on the kill switch, `sns:Publish`
- `aws_ssm_parameter` `/univen/dr/auto-promote` (default `disabled`)

**Trade-offs to state:**

| | Manual promotion | Automatic promotion |
|---|---|---|
| RTO for **writes** | Minutes to hours (needs a person) | ~5–10 min (alarm window + promote) |
| Risk | Low: a human confirms the primary is really gone | False promotion and split-brain if the guards are weak |
| Failback | Same either way: rebuild replication in reverse, then a planned switch | Same |

Recommendation: **automatic traffic failover (have it), automatic DB promotion behind a kill switch
with 3 agreeing signals, and planned (manual) failback.**
