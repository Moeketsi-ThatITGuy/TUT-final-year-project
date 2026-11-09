# UNIVEN Hybrid Cloud: AWS Multi-Region DR (Terraform)

The cloud half of the UNIVEN hybrid campus project. The on-prem campus is
modelled in Cisco Packet Tracer; this repo builds the AWS side for real:

- **Region 1 (us-east-1)** serves traffic: ALB → 2 web → 2 app → RDS MySQL (Multi-AZ, writable)
- **Backup region (us-west-2)** is identical, with a **cross-region read replica**
- **Route 53 failover**: a health check on Region 1. When it fails, `app.<domain>` answers with the backup region
- **Site-to-site VPN** (VGW + 2 Customer Gateways, ISP A / ISP B, BGP) for the on-prem link
- **S3 backups** through a VPC Gateway endpoint, **CloudWatch** alarms and a dashboard

A small Apache website shows which region served the request (**REGION 1 - PRIMARY** in green or
**BACKUP REGION** in orange) and **which database it's using**: region, endpoint, primary or
read replica, replication lag, and rows replicated from Region 1.

Design details, diagrams, security controls and costs are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

**Presenting?** Follow [docs/PRESENTATION-RUNBOOK.md](docs/PRESENTATION-RUNBOOK.md): deploy timeline, pre-flight checks, a step-by-step talk track for the live DR drill, likely questions, and what to do if something breaks.

---

## 1. Prerequisites

| Tool | Version | Used for |
|---|---|---|
| Terraform | ≥ 1.7 | deploy + tests |
| AWS CLI v2 | any | credentials + demo scripts |
| `jq`, `dig`, `curl` | any | demo scripts (preinstalled on macOS except `jq`: `brew install jq`) |

You also need an AWS account where you can create VPCs, EC2, RDS, Route 53, VPN, IAM and S3.

## 2. Credentials

Any normal AWS credential source works (`AWS_PROFILE`, env vars, SSO).

**Important:** the deploy takes **~40 minutes** (RDS Multi-AZ plus the cross-region replica).
Short-lived credentials must **auto-refresh**, or Terraform fails partway through with
`ExpiredToken`.

**Simplest (personal / student account):** `aws configure --profile univen-demo` with an IAM user's access key.

**AWS IAM Identity Center (SSO):** `aws configure sso` creates a profile that refreshes automatically.

**Any other credential helper:** use a `credential_process` profile in `~/.aws/config`, so the CLI fetches fresh credentials on demand:

```ini
[profile univen-demo]
credential_process = <your-credential-helper> <args>
region = us-east-1
```

Check it:

```bash
AWS_PROFILE=univen-demo aws sts get-caller-identity
```

## 3. Configure (optional)

```bash
cp terraform.tfvars.example terraform.tfvars   # everything in it is optional
```

The settings you'll most likely want:

| Variable | Default | Notes |
|---|---|---|
| `aws_profile` | `null` | or `export AWS_PROFILE=...` |
| `allowed_cidrs` | auto-detected `/32` | Who can open the site. **Behind a corporate VPN/NAT pool your IP may rotate**: use the pool's range (e.g. `x.y.z.0/24`). `0.0.0.0/0` is rejected on purpose |
| `primary_region` / `secondary_region` | `us-east-1` / `us-west-2` | |
| `domain_name` | `univen-dr-demo.com` | You don't need to own it (see section 5) |
| `existing_hosted_zone_id` | `null` | Set this if you own a domain and already have a zone |
| `enable_vpn` | `true` | `false` saves ~$2.40/day |
| `db_multi_az` | `true` | `false` saves ~$0.40/day |
| `customer_gateway_ips` | RFC 5737 test IPs | Public IPs of your edge routers |

## 4. Deploy

```bash
terraform init
terraform apply          # ~40 min; 127 resources across 2 regions
scripts/smoke-test.sh    # end-to-end verification, should print "0 failed"
```

Useful outputs:

```bash
terraform output primary_alb_url      # open in a browser: green "REGION 1 - PRIMARY"
terraform output secondary_alb_url    # orange "BACKUP REGION", DB = us-west-2 replica
terraform output failover_fqdn        # app.univen-dr-demo.com
terraform output route53_name_servers
terraform output vpn_connections      # tunnel IPs for the Packet Tracer write-up
```

> First boot: the instances install Apache/PHP after the DB exists. Allow ~2 min after
> `apply` before running the smoke test.

## 5. Demo script

**Terminal 1: watch DNS failover live**

```bash
scripts/check-dns.sh
```

It queries Route 53's authoritative name server directly, so it works even if you don't own
the domain. Every 5 s it prints the DNS answer, which ALB that IP belongs to, the app region,
and the DB region and role:

```
TIME (UTC)  DNS ANSWER      ALB                   APP REGION   DB (region / role)
10:00:05    3.218.x.x       REGION 1 (us-east-1)  us-east-1    us-east-1 / PRIMARY (writable)
```

**Terminal 2: run the scenario**

| Step | Command | What the audience sees |
|---|---|---|
| 1. Normal | open `primary_alb_url` | Green "REGION 1 - PRIMARY", DB in us-east-1, writable |
| 2. Backup is warm | open `secondary_alb_url` | Orange "BACKUP REGION", DB in **us-west-2**, read replica, rows written by us-east-1 |
| 3. Outage | `scripts/simulate-failure.sh` | Region 1 web servers stop |
| 4. Failover | watch terminal 1 | Within ~1–2 min the answer flips to `BACKUP (us-west-2)` / `us-west-2 / READ REPLICA` |
| 5. Monitoring | `terraform output cloudwatch_dashboard_url` | Health check drops to 0, alarm goes into ALARM |
| 6. Recovery | `scripts/restore.sh` | Route 53 fails back to Region 1 automatically |
| 7. (optional, one-way) | `scripts/promote-replica.sh` | Backup DB becomes writable PRIMARY. Do this last, then destroy |

**Browsing by name:** if you **own** the domain (delegate NS to `route53_name_servers`), just
open `http://app.<domain>`. If you don't, either use `check-dns.sh`, or point your laptop at
whichever IP Route 53 returns:

```bash
dig +short @$(terraform output -json route53_name_servers | jq -r '.[0]') app.univen-dr-demo.com
```

## 6. Tear down (do this when the demo ends)

```bash
terraform destroy        # ~15 min
```

Then confirm nothing is left (everything is tagged `Project=univen`):

```bash
for r in us-east-1 us-west-2; do
  aws resourcegroupstaggingapi get-resources --region $r --tag-filters Key=Project,Values=univen \
    --query 'ResourceTagMappingList[].ResourceARN' --output text
done
```

Only KMS keys "pending deletion" (7-day window, not billed) may remain.

## 7. Tests

```bash
terraform test           # 20 plan-time tests, mock providers, no AWS credentials needed
```

These check the subnet layout, that no security group opens `0.0.0.0/0`, that each tier only trusts
the tier in front of it, IMDSv2 and encryption, least-privilege IAM (secret per region, S3 only via
the endpoint), failover record wiring, S3 Block Public Access, the VPN toggle and input validation.
The same checks run in GitHub Actions (`.github/workflows/terraform-ci.yml`) on every push.
`scripts/smoke-test.sh` is the live end-to-end check.

## 8. Layout

```
.
├── versions.tf  providers.tf  variables.tf  outputs.tf
├── main.tf            # wires both regions: network, compute, database, VPN
├── secrets.tf         # generated DB password, one secret per region
├── dns.tf             # hosted zone, health check, PRIMARY/SECONDARY failover records
├── backup.tf          # private S3 backup bucket
├── monitoring.tf      # alarms + cross-region dashboard
├── modules/
│   ├── network/       # VPC, 4 subnets, IGW, NAT, route tables, S3 endpoint
│   ├── compute/       # SGs, IAM, web + app EC2, ALB, Apache/PHP site
│   ├── database/      # RDS primary OR cross-region replica
│   └── vpn/           # VGW, 2x CGW, 2x VPN connection (BGP)
├── scripts/           # smoke-test, check-dns, simulate-failure, restore, promote-replica
├── tests/             # terraform test files (mock providers)
└── docs/ARCHITECTURE.md
```

## 9. Troubleshooting

| Symptom | Fix |
|---|---|
| `ExpiredToken` during apply | Use a `credential_process` profile (section 2). Then if `terraform state show` marks an RDS instance `(tainted)` but the console shows it `available`, run `terraform untaint <address>` and apply again so it isn't rebuilt |
| Browser times out on the ALB URL | Your public IP isn't in `allowed_cidrs` (it may have rotated). Check `curl https://checkip.amazonaws.com`, then update and re-apply |
| Page loads but "app tier unavailable" | Instances are still bootstrapping. Wait 2 min. Check with SSM: `aws ssm start-session --target <id>` then `sudo cat /var/log/cloud-init-output.log` |
| Backup page shows `connect failed` | Replica still being created, or secret not readable. Check `/etc/univen/db.json` exists on the app server |
| VPN tunnels DOWN | Expected: the CGW IPs aren't real routers (see docs/ARCHITECTURE.md section 5) |

## Test results

Live run on 2026-11-05, us-east-1 primary and us-west-2 backup, 127 resources.

**Offline tests** (`terraform test`): 20/20 pass.

**Smoke test** (`scripts/smoke-test.sh`): 20 passed, 0 failed.

```
== Web tier
  PASS  Region 1 /health returns OK
  PASS  Backup   /health returns OK
  PASS  Region 1 page says 'REGION 1 - PRIMARY'
  PASS  Backup   page says 'BACKUP REGION'
== App + DB, Region 1 (us-east-1)
  PASS  app runs in us-east-1
  PASS  DB connected
  PASS  DB is in us-east-1
  PASS  DB is writable PRIMARY
== App + DB, Backup region (us-west-2)
  PASS  app runs in us-west-2
  PASS  DB connected
  PASS  DB is in us-west-2 (its own replica)
  PASS  DB is a read-only REPLICA
  PASS  replication threads running
  PASS  rows written in Region 1 visible in backup
== Route 53 failover
  PASS  app.univen-dr-demo.com resolves via ns-1512.awsdns-61.org
  PASS  app.univen-dr-demo.com currently points at Region 1
  PASS  Route 53 health checkers report Success (6)
== Backup + security
  PASS  S3 backup objects present (6)
  PASS  no 0.0.0.0/0 inbound rule in us-east-1
  PASS  no 0.0.0.0/0 inbound rule in us-west-2
```

**Failover drill** (`simulate-failure.sh`, then `restore.sh`; DNS polled every 5s):

| Step | Result |
|---|---|
| Before | `REGION 1 - PRIMARY`, app us-east-1, DB us-east-1 `PRIMARY (writable)` |
| Stop Region 1 web servers until DNS answers with the backup ALB | **34 s** |
| During outage | `BACKUP REGION`, app us-west-2, DB us-west-2 `READ REPLICA (read-only)`, `last_written_by: us-east-1` (data replicated from Region 1) |
| Start instances until DNS answers with Region 1 again | **24-53 s** after instances report `running` (two runs) |
| After failback | `REGION 1 - PRIMARY`, DB writable, visit counter keeps increasing |

Right after failback, DNS answers can alternate between regions for about
30 s while all Route 53 checkers agree the endpoint is healthy. This is
expected.
