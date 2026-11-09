# UNIVEN DR Demo: Presentation Runbook

**Strategy being shown:** *Warm standby*, multi-region.
- **Region 1, us-east-1:** serves all traffic and holds the writable database.
- **Backup region, us-west-2:** fully built and running at minimum size, with a live read replica of the database.
- **Route 53:** health-checks Region 1 and moves traffic to the backup region automatically.

| Metric | Measured in rehearsal |
|---|---|
| RTO (failover) | **~34 s** from outage to DNS answering with the backup |
| RPO (data loss) | **~seconds** (asynchronous replication lag) |
| Failback | **Automatic**, ~25–55 s after Region 1 is healthy |
| Trade-off | Backup region is **read-only** until someone promotes the replica |

---

## Phase 0: The day before (rehearsal, ~1.5 h)

1. Do one full dress rehearsal (Phases 1–3 below) on the **same laptop and network** you'll present on, if you can.
2. **Screen-record the rehearsal.** That's your fallback if the venue Wi-Fi or AWS has a bad day.
3. Take screenshots of the key moments: both pages, the `check-dns.sh` flip, and the CloudWatch alarm.
4. `terraform destroy` afterwards, unless you're presenting the next morning. Running it overnight costs about $5.

## Phase 1: Deploy (start **90 min before** you present)

```bash
cd TUT-final-year-project
curl -s https://checkip.amazonaws.com        # note your public IP
# put it in terraform.tfvars:  allowed_cidrs = ["<ip>/32"]
terraform init
terraform apply                              # ~30–40 min, type "yes"
```

> ⚠️ **Biggest risk:** the load balancers only accept the IPs in `allowed_cidrs`.
> - If you deploy at home and present on campus Wi-Fi, the pages **will time out**.
> - So either deploy from the venue, or re-run `terraform apply` there after adding the venue IP. That only adds an ingress rule and takes about 1 min.
> - A phone hotspot is the most predictable option.

## Phase 2: Pre-flight (**T-30 min**)

```bash
scripts/smoke-test.sh          # expect: 20 passed, 0 failed
```

Wait for about 5 min after apply finishes so the S3 backup check passes.

Then set up the screen:
- **Browser tab 1:** `terraform output -raw primary_alb_url` (green "REGION 1 - PRIMARY")
- **Browser tab 2:** `terraform output -raw secondary_alb_url` (orange "BACKUP REGION")
- **Browser tab 3:** `terraform output -raw cloudwatch_dashboard_url`, logged in to the console
- **Terminal 1:** `scripts/check-dns.sh` (leave it running; it takes ~20 s to start)
- **Terminal 2:** an empty prompt in the repo folder
- **Packet Tracer:** your on-prem campus file, open

Increase the terminal font size so the back row can read it.

## Phase 3: The live show (~12–15 min)

| # | Time | Do | Say |
|---|---|---|---|
| 1 | 2 min | Packet Tracer | "This is the campus on-prem network. It connects to AWS over two site-to-site VPN tunnels, one per ISP, using BGP." |
| 2 | 1 min | Show code / `docs/ARCHITECTURE.md` diagram | "The whole cloud side is Terraform: 127 resources, two regions, one `terraform apply`." |
| 3 | 1 min | Tab 1 | "Normal operation. Region 1 serves the site, and the database is the writable primary in us-east-1." Refresh twice; the visit counter goes up. |
| 4 | 1 min | Tab 2 | "The backup region is already running: warm standby. Its database is a read replica in us-west-2, and the rows you see were written by Region 1." |
| 5 | 1 min | Terminal 1 | "This asks Route 53 directly which region it's sending users to. Right now: Region 1." |
| 6 | **Disaster** | Terminal 2: `scripts/simulate-failure.sh` | "I'm taking Region 1's web tier down. This simulates a regional outage." |
| 7 | ~1 min | Tab 3 while waiting | "Route 53 checks from multiple locations every 10 s. Two failures in a row and it marks the region unhealthy." Show the health check dropping and the alarm firing. |
| 8 | 30 s | Terminal 1 flips | "There: DNS now answers with **BACKUP (us-west-2)**, and the DB shows **us-west-2 / READ REPLICA**. That's about 30–40 seconds of RTO with no human involved." |
| 9 | 30 s | Refresh tab 1 (times out), then tab 2 | "Region 1 is dead; the backup is serving, with the data that was replicated before the outage." |
| 10 | **Recovery** | Terminal 2: `scripts/restore.sh` | "Region 1 is back. Watch: nobody touches DNS." |
| 11 | ~1–2 min | Terminal 1 flips back | "Automatic failback. And because only Region 1 ever accepted writes, there's nothing to merge." |
| 12 | 2 min | Wrap up | RTO/RPO table above, the trade-off (read-only during failover), cost (~$11/day; pilot light would be cheaper, active-active would cost more). |

**Dead air:** after steps 6 and 10 there are 30–90 s of waiting. Have the talking points for steps 7 and 11 ready.

**Flip-flop:** just after failback, the answer can alternate between regions for about 30 s. Say "the health checkers are reaching agreement". It's expected behaviour.

### Optional finale (only at the very end; one-way)
`scripts/promote-replica.sh` makes the backup DB a writable primary. It shows how you'd recover if Region 1 never came back, but replication can't be restored afterwards. Only run it right before you destroy the stack.

## Phase 4: After the presentation

```bash
terraform destroy              # ~15 min, type "yes"
```

Run it **from the same folder that deployed** (it holds the state file).

## Likely questions

- **Why not active-active?** It costs more, and writes in two regions need conflict handling. Warm standby is the usual middle ground.
- **Why is the backup read-only?** The replica is asynchronous. Promoting it automatically risks split-brain if Region 1 is only partly down, so promotion is a deliberate human decision.
- **Why don't the VPN tunnels show UP?** There are no real campus routers at the RFC 5737 test IPs. The Packet Tracer model represents that side.
- **Is it secure?** The site isn't open to the whole internet, there's no SSH (shell access is through SSM), databases are private and encrypted, credentials are in Secrets Manager in both regions, and the backup bucket is private.

## If something goes wrong live

| Symptom | Fix |
|---|---|
| Pages time out | Your IP changed. Run `checkip`, update `allowed_cidrs`, `terraform apply` (~1 min) |
| `check-dns.sh` doesn't flip after 2 min | Show the CloudWatch dashboard and the recording; give it another minute |
| `ExpiredToken` | Refresh your AWS credentials and re-run the script |
| Anything else | Switch to the screen recording and carry on talking |
