# UNIVEN Hybrid DR: Architecture Diagram Spec

Input for a diagram generator. Every node has an **ID**; every connection is `FROM -> TO : label`.
Names use the pattern `univen-primary-*` and `univen-secondary-*`.

## 1. Layout (nested containers)

```
[Internet / Users]
[AWS Global]  Route 53
[ON-PREM: UNIVEN Campus]            (left)
[AWS us-east-1: REGION 1 PRIMARY]   (centre)
  [VPC 10.0.0.0/16]
    [AZ a]  public 10.0.1.0/24 | private 10.0.2.0/24
    [AZ b]  public 10.0.3.0/24 | private 10.0.4.0/24
[AWS us-west-2: BACKUP REGION]      (right)
  [VPC 10.1.0.0/16]
    [AZ a]  public 10.1.1.0/24 | private 10.1.2.0/24
    [AZ b]  public 10.1.3.0/24 | private 10.1.4.0/24
```

Region 1 and the backup region are **identical** apart from: VPN (Region 1 only), S3 backup bucket (Region 1 only), and the DB role (primary vs read replica).

## 2. Nodes

### Internet / global
| ID | Label | Type |
|---|---|---|
| USERS | Users (browser) | users |
| R53_ZONE | Route 53 hosted zone `univen-dr-demo.com` | Route 53 |
| R53_REC | Failover record `app.univen-dr-demo.com` (PRIMARY → Region 1, SECONDARY → Backup) | Route 53 record |
| R53_HC | Route 53 health check: HTTP :80 `/health` on Region 1 ALB, every 10 s, fails after 2, checkers in us-east-1 / us-west-1 / us-west-2 | Route 53 health check |

### AWS us-east-1 (Region 1, PRIMARY), VPC 10.0.0.0/16
| ID | Label | Subnet / AZ | Type |
|---|---|---|---|
| P_IGW | Internet Gateway | VPC | IGW |
| P_ALB | ALB `univen-primary-alb` (internet-facing, HTTP :80) | public a + b | ALB |
| P_WEB_A | Web server A (Apache, t3.micro) | public 10.0.1.0/24, AZ a | EC2 |
| P_WEB_B | Web server B (Apache, t3.micro) | public 10.0.3.0/24, AZ b | EC2 |
| P_NAT | NAT Gateway (single) | public 10.0.1.0/24, AZ a | NAT |
| P_APP_A | App server A (Apache + PHP-FPM, `/api/status.php`) | private 10.0.2.0/24, AZ a | EC2 |
| P_APP_B | App server B (Apache + PHP-FPM) | private 10.0.4.0/24, AZ b | EC2 |
| P_DB | RDS MySQL 8.4 **PRIMARY (writable)**, db.t4g.micro, encrypted | private a | RDS |
| P_DB_STBY | RDS Multi-AZ standby (sync) | private b | RDS standby |
| P_S3EP | S3 Gateway Endpoint (private route table) | VPC | VPC endpoint |
| P_S3 | S3 bucket `univen-db-backup-<acct>-us-east-1` (private, versioned, SSE, 7-day expiry) | region | S3 |
| P_SECRET | Secrets Manager `univen-db-credentials` | region | Secrets Manager |
| P_VGW | Virtual Private Gateway (ASN 64512) | VPC | VGW |
| P_CW | CloudWatch dashboard `univen-multi-region-dr` + alarms (+ optional SNS email) | region | CloudWatch |
| P_SSM | SSM Session Manager (admin shell, no SSH) | region | Systems Manager |

### AWS us-west-2 (BACKUP REGION), VPC 10.1.0.0/16
| ID | Label | Subnet / AZ | Type |
|---|---|---|---|
| S_IGW | Internet Gateway | VPC | IGW |
| S_ALB | ALB `univen-secondary-alb` (internet-facing, HTTP :80) | public a + b | ALB |
| S_WEB_A / S_WEB_B | Web servers A/B (Apache) | public 10.1.1.0/24 (a), 10.1.3.0/24 (b) | EC2 |
| S_NAT | NAT Gateway (single) | public 10.1.1.0/24, AZ a | NAT |
| S_APP_A / S_APP_B | App servers A/B (PHP) | private 10.1.2.0/24 (a), 10.1.4.0/24 (b) | EC2 |
| S_DB | RDS MySQL **READ REPLICA (read-only)**, own KMS key | private | RDS |
| S_KMS | KMS key `univen-secondary-rds-kms` | region | KMS |
| S_S3EP | S3 Gateway Endpoint | VPC | VPC endpoint |
| S_SECRET | Secrets Manager `univen-db-credentials` (copy) | region | Secrets Manager |

### ON-PREM: UNIVEN campus (Cisco Packet Tracer model)
| ID | Label | Type |
|---|---|---|
| ISP_A / ISP_B | ISP A / ISP B | cloud / router |
| R1 / R2 | Edge routers (NAT, HSRP VIP 172.16.5.1), WAN 196.21.100.2 / 41.76.200.2 | router |
| FW1 / FW2 | Firewalls (zone-based, HSRP, inside VIP 172.16.4.1) | firewall |
| VPNGW1 / VPNGW2 | VPN gateways (IPsec to AWS), public 196.21.101.2 / 41.76.201.2 | VPN router |
| CORE1 / CORE2 | L3 core switches (HSRP gateways, OSPF, LACP) | L3 switch |
| ACC | 8 access switches → user VLANs 10–150 (172.16.10–150.0/24) | switch group |
| DC_SW | DC switches DC-SW1 / DC-SW2 | switch |
| DC_SRV | Servers: DNS-1/2 (172.16.200.10/.11), DHCP-1/2, WEB-1/2 (172.16.210.10/.11), MAIL-1/2, FS-1/2, DB-PRI (172.16.230.10), DB-REP (.230.11), BKP, NAS | server group |

## 3. Connections

### User traffic (normal)
- USERS -> R53_REC : DNS query `app.univen-dr-demo.com`
- R53_REC -> P_ALB : answer when Region 1 healthy (PRIMARY)
- R53_REC -> S_ALB : answer when Region 1 unhealthy (SECONDARY, failover)
- USERS -> P_IGW -> P_ALB : HTTP :80 (only allowed CIDRs + Route 53 checker IPs)
- P_ALB -> P_WEB_A, P_WEB_B : HTTP :80, target group health check `/health`
- P_WEB_A, P_WEB_B -> P_APP_A, P_APP_B : HTTP :80 `/api/*` (Apache mod_proxy_balancer)
- P_APP_A, P_APP_B -> P_DB : MySQL TCP 3306 (TLS)
- P_DB -> P_DB_STBY : synchronous Multi-AZ replication
- *Backup region mirrors this:* S_ALB -> S_WEB_* -> S_APP_* -> S_DB

### Health check / failover
- R53_HC -> P_ALB : HTTP GET `/health` every 10 s
- R53_HC -> R53_REC : healthy/unhealthy decides PRIMARY vs SECONDARY
- R53_HC -> P_CW : `HealthCheckStatus` metric → alarm `univen-primary-route53-health-check-failed`

### Data
- P_DB -> S_DB : **cross-region async replication** (MySQL binlog), us-east-1 → us-west-2
- S_KMS -> S_DB : encrypts replica storage
- P_APP_A, P_APP_B -> P_S3EP -> P_S3 : hourly DB backup (`s3:PutObject`, only via the endpoint)
- P_APP_* -> P_SECRET : read DB credentials at boot
- S_APP_* -> S_SECRET : read DB credentials at boot (works even if Region 1 is down)

### Outbound / management
- P_APP_* -> P_NAT -> P_IGW : outbound only (packages, SSM, Secrets Manager)
- S_APP_* -> S_NAT -> S_IGW : same in the backup region
- Admin -> P_SSM / SSM : shell into any EC2 (port 22 never open)

### Hybrid link (Region 1 only)
- VPNGW1 -> ISP_A -> P_VGW : Site-to-Site VPN #1 (IPsec, 2 tunnels, BGP; on-prem ASN 65000 ↔ AWS 64512)
- VPNGW2 -> ISP_B -> P_VGW : Site-to-Site VPN #2 (backup path)
- P_VGW -> private route table (10.0.2.0/24, 10.0.4.0/24) : route propagation, on-prem 172.16.0.0/16 ↔ 10.0.0.0/16
- *Note:* tunnels are modelled in Packet Tracer; in AWS they show DOWN (no real campus router). The AWS customer gateways currently use placeholder IPs 203.0.113.10 / 198.51.100.10. In a real build they would be VPNGW1/VPNGW2's public IPs.

### On-prem internal
- ISP_A -> R1, ISP_B -> R2 : WAN links
- R1, R2 -> FW1, FW2 : transit VLAN 5 (172.16.5.0/24)
- FW1, FW2 -> CORE1, CORE2 : transit VLAN 4 (172.16.4.0/24)
- VPNGW1, VPNGW2 -> CORE1, CORE2 : VPN transit VLAN 6 (172.16.6.0/24), OSPF (GW1 preferred)
- CORE1 <-> CORE2 : LACP Port-channel 1
- CORE1, CORE2 -> ACC : user VLANs (trunks)
- CORE1, CORE2 -> DC_SW -> DC_SRV : DC VLANs 200/210/220/230
- DC_SRV (BKP/DB) -> VPN -> P_S3 : off-site backup copy (design intent)

## 4. Security boundaries (draw as SG badges)
| SG | Allows in |
|---|---|
| ALB SG | TCP 80 from allowed CIDRs + Route 53 health-checker ranges (never 0.0.0.0/0) |
| Web SG | TCP 80 from ALB SG |
| App SG | TCP 80 from Web SG |
| DB SG | TCP 3306 from App SG |

## 5. Failover sequence (for a sequence diagram)
1. Region 1 web tier fails → P_ALB has 0 healthy targets → `/health` returns error.
2. R53_HC fails 2 checks in a row (~20–60 s) → Region 1 marked unhealthy; CloudWatch alarm fires.
3. R53_REC answers with S_ALB → users reach the backup region (DB = S_DB, read-only).
4. Region 1 recovers → R53_HC healthy → R53_REC answers with P_ALB again (automatic failback).
5. Optional, one-way: promote S_DB to a writable primary (`scripts/promote-replica.sh`).

## 6. Key numbers
- **Strategy:** warm standby, multi-region.
- **RTO:** ~35–75 s. **RPO:** seconds.
- **Size:** 2 regions, 2 AZs each; 4 EC2 + 1 ALB + 1 NAT per region.
- **Databases:** 1 RDS primary (Multi-AZ) + 1 cross-region replica.
- **Deploy:** Terraform, ~129 resources.
