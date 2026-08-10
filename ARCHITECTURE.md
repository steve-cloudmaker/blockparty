# Minecraft on AWS — Architecture

Small, whitelisted server (2–10 friends) running both a plugin-based world (Paper)
and a modded world (Forge/Fabric), managed through Pterodactyl — the same
panel/agent pattern commercial hosts like AccuWebHosting use. Reachable at
`blockparty.charliesystems.ai`, under a Let's Encrypt wildcard cert.

## Topology

One EC2 instance runs both roles, logically separated by software rather than
by hardware — the right tradeoff at this scale. It can be split into a
dedicated panel box + one or more Wings hosting nodes later without rebuilding
anything, since the panel/node relationship is already modeled that way.

```
      Route 53 (charliesystems.ai zone)
      blockparty.charliesystems.ai        A     ─┐
      *.blockparty.charliesystems.ai      A      │  all → Elastic IP
      _minecraft._tcp.blockparty...       SRV    │  → :25565
      _minecraft._tcp.modded.blockparty.  SRV    │  → :25566
                            │                    ─┘
                        Internet
                            |
                    [Elastic IP + AWS Shield Standard]
                            |
                 ┌─────────────────────┐
                 │   EC2 (Graviton)     │
                 │  c6g.xlarge, ARM64   │
                 │                      │
                 │  ┌────────────────┐  │
                 │  │ certbot         │  │  Let's Encrypt wildcard cert
                 │  │ (dns-route53)  │  │  *.blockparty.charliesystems.ai
                 │  └───────┬────────┘  │  auto-renews (systemd timer)
                 │          ▼           │
                 │  ┌────────────────┐  │
                 │  │ Pterodactyl    │  │  :443  → panel UI (admin CIDR only,
                 │  │ Panel (Docker) │  │          real TLS cert)
                 │  │ MariaDB, Redis │  │
                 │  └────────────────┘  │
                 │                      │
                 │  ┌────────────────┐  │
                 │  │ Wings daemon   │  │  :25565 → Paper world (plain TCP)
                 │  │ (systemd)      │  │  :25566 → Forge/Fabric world (plain TCP)
                 │  │  ├─ Paper ctr  │  │
                 │  │  └─ Forge ctr  │  │
                 │  └────────────────┘  │
                 └─────────┬────────────┘
                            │
                   EBS gp3 data volume
                  (world saves, backups)
                            │
                  ┌─────────┴─────────┐
                  │   DLM snapshots    │  daily, 7-day retention
                  │   S3 backup bucket │  Pterodactyl per-world backups
                  └────────────────────┘
```

## Why Pterodactyl

Open-source, runs each game server in an isolated Docker container, has a
polished web UI for console/file access/backups/scheduling, and is the
de facto standard behind most commercial Minecraft VPS panels — the closest
open match to what AccuWebHosting-style hosts run. Two components:

- **Panel** — web UI + API, the "orchestrator." Tracks nodes, users, servers,
  permissions, backups, schedules.
- **Wings** — the per-node daemon that actually starts/stops Docker
  containers for each game server. This maps directly onto the
  "management server + hosting server(s)" split you described; here both
  happen to live on one box.

## Compute

- **Instance**: `c6g.xlarge` (4 vCPU / 8 GB, Graviton/ARM64). Graviton is the
  best price/performance for Java game servers on AWS and both Paper and
  Forge/Fabric run fine on an ARM64 JRE.
- **Sized for**: two concurrent worlds, 2–10 players. Easy to resize
  (`aws ec2 modify-instance-attribute` + reboot) if TPS drops.
- **No SSH key pair.** Shell access goes through **AWS Systems Manager
  Session Manager** — no open port 22, no key to leak, every session logged
  in CloudTrail.

## Networking & security

- Dedicated VPC (`10.20.0.0/16`), single public subnet — no NAT gateway
  needed since the box needs a public IP anyway.
- Security group, default-deny, only four inbound rules:
  - `443/tcp` (panel HTTPS) — restricted to an admin CIDR you supply, not
    `0.0.0.0/0`.
  - `8080/tcp` (Wings daemon API) — also restricted to the admin CIDR.
    Needed because the panel's live console/stats view opens a WebSocket
    directly from your browser to Wings, bypassing the panel backend
    entirely — restricting it to admin CIDR keeps it from being reachable
    by anyone else, same as the panel itself.
  - `25565/tcp` (Paper) and `25566/tcp` (Forge/Fabric) — open to the
    internet (Minecraft has no concept of IP-restricted play unless you
    also lock the SG down to friends' IPs), with the in-game **whitelist**
    as the actual access control.
  - Everything else denied by default.
- IAM instance role scoped to: SSM Session Manager, CloudWatch agent
  metrics, read/write to the one backup S3 bucket, and — new — write access
  to DNS records in *just* the `charliesystems.ai` hosted zone plus read of
  one SSM parameter (`/minecraft/subdomain`). Nothing account-wide.
- Root/admin EBS volumes encrypted by default (AWS default account setting
  should already have EBS encryption-by-default on — the template also sets
  it explicitly).

## DNS & TLS

- **Subdomain**: `blockparty.charliesystems.ai`, in the existing Route 53
  hosted zone for `charliesystems.ai` in the dev-lab account. CloudFormation
  creates an A record for the apex label and a wildcard A record
  (`*.blockparty.charliesystems.ai`) pointing at the Elastic IP, so any
  future service on this box (a second node, a status page) needs no
  further DNS work.
- **SRV records** let friends connect with `blockparty.charliesystems.ai`
  and `modded.blockparty.charliesystems.ai` directly — no `:25566` to
  remember or explain.
- **Wildcard TLS cert** via Let's Encrypt, issued with `certbot`'s
  `dns-route53` plugin (DNS-01 challenge — the only way to get a wildcard
  cert; HTTP-01 can't). Certbot runs on the host using the instance's IAM
  role, no credentials stored anywhere. A daily systemd timer handles
  renewal automatically, including restarting the panel container so it
  picks up the renewed cert.
- **Trust tradeoff worth knowing**: this means the instance's IAM role can
  write DNS records — scoped to only the one `charliesystems.ai` hosted
  zone, not the whole account, but still real write access. If this
  specific box were ever compromised, that's the blast radius (in addition
  to the S3 backup bucket and its own resources). Acceptable at this scale;
  worth revisiting if the threat model changes.
- **The game ports stay plain TCP.** Java Edition's protocol has no
  standard TLS wrapping, so 25565/25566 aren't (and can't meaningfully be)
  covered by the cert — same as every other Minecraft host, including
  AccuWebHosting. Security there is the SG + whitelist + Shield Standard,
  covered below.

## DDoS protection

- **AWS Shield Standard** is automatic and free on any Elastic IP — it
  covers the common L3/L4 floods (SYN floods, UDP reflection, etc.) that
  take down home-hosted servers. This is the right tier at whitelisted,
  2–10-player scale.
- **Shield Advanced** (~$3k/month commitment) is not justified here — it's
  built for public, high-value, or previously-targeted services. If this
  server ever opens up publicly and gets targeted, revisit, or front it
  with a purpose-built Minecraft proxy (TCPShield, BungeeGuard-style) which
  is the cheaper option most hobbyist hosts land on when Shield Standard
  isn't enough.
- Defense in depth beyond Shield: strict security group, in-game whitelist,
  and — if griefing/connection-flooding becomes an issue rather than true
  DDoS — Paper's built-in connection-throttle settings.

## Backups (two layers, matching what commercial hosts do)

1. **EBS snapshots** via Data Lifecycle Manager — whole-volume, daily,
   7-day retention. Fast, coarse-grained disaster recovery (instance/volume
   loss).
2. **Pterodactyl per-server backups to S3** — Wings' native backup driver
   archives each world individually, restorable straight from the panel UI
   without touching the AWS console. S3 bucket is versioned, encrypted,
   fully blocked from public access, with lifecycle rules to age out old
   backups automatically.

## Teardown tiers

The template splits resources into "core" (VPC, security group, IAM, the S3
backup bucket, DNS records, the DLM snapshot policy, the SNS alarm topic)
and "compute" (the EC2 instance, its EBS data volume, the Elastic IP
*association*, and the instance-scoped CloudWatch alarms), gated by a
`DeployCompute` parameter/`HasCompute` condition. This gives two teardown
levels without needing separate stacks:

- **Tier 1**: `DEPLOY_COMPUTE=false scripts/deploy.sh` — a stack update
  that tears down just the compute resources. Core infra, including the
  Elastic IP itself (not just its DNS records), stays allocated. Rebuilding
  re-associates a fresh instance with the *same* EIP, so DNS never needs to
  change across a rebuild — only the TLS cert needs reissuing, since it
  lives on the instance's own disk.
- **Tier 2**: `scripts/teardown.sh` — deletes the whole stack. The S3
  backup bucket is the one exception (`DeletionPolicy: Retain`), on
  purpose — bucket deletion is a separate, explicit, manual step even here.

Redeploying from scratch after a tier-2 teardown hits a real gotcha: the S3
bucket is still there (that's the point), but S3 bucket names are globally
unique, so CloudFormation's early validation refuses to even build a
changeset that tries to `Add` it again — fails before anything else in the
template gets touched. A `BackupBucketExists` parameter/
`ShouldCreateBackupBucket` condition handles this: when true, the template
skips declaring the bucket and just references it by its deterministic
name instead (in the IAM policy and the `BackupBucketName` output). It
falls out of CloudFormation's management at that point, which is fine —
it was already effectively unmanaged the moment it survived a stack
deletion via `Retain`. `deploy.sh` auto-detects this with a `head-bucket`
check rather than requiring anyone to remember a flag.

See `POST_DEPLOY.md`'s teardown section for the actual commands.

## Tagging

`deploy.sh` passes `--tags Project=blockparty Build=<stack name>
ManagedBy=cloudformation` to `aws cloudformation deploy`, which
CloudFormation propagates automatically to every taggable resource in the
stack — no per-resource `Tags:` needed in the template for this. `Build`
uses the stack name specifically so that if this ever grows into running
several independent deployments side by side (a different friend group's
server, a test stack), each one's resources stay identifiable at a glance
via `aws resourcegroupstaggingapi` or the Resource Groups console, without
having to cross-reference instance/volume IDs by hand.

## Monitoring

- CloudWatch agent on the instance for CPU, memory, and disk (EC2's default
  metrics don't include memory/disk for a non-Nitro-enabled custom metric,
  the agent fills that gap).
- Alarms on high CPU, high memory, low disk, and instance status-check
  failure, notifying an email you provide via SNS.

## Modpack & plugin management

- **Paper world**: plugins uploaded/managed through the panel's file
  manager, or via Pterodactyl's plugin manager UI if you install that
  add-on later.
- **Forge/Fabric world**: Pterodactyl "eggs" for CurseForge/Modrinth
  modpacks let you pick a modpack from the panel and it downloads and
  configures the server automatically; updating to a new modpack version is
  a couple of clicks.

## Estimated cost (us-east-1, on-demand, verify against current AWS pricing)

| Item | Approx. monthly |
|---|---|
| c6g.xlarge (24/7) | ~$100 |
| EBS gp3 (20 GB root + 60 GB data) | ~$8 |
| S3 backups (small worlds) | ~$1–3 |
| Elastic IP, Shield Standard, SNS | $0 |
| **Total** | **~$110–115/month** |

Biggest lever if that's too high: stop the instance when nobody's playing
(billed by the second) — a scheduled Lambda or just manual `aws ec2
stop-instances`/`start-instances` around your friend group's usual play
hours can cut this substantially, at the cost of a ~2 minute boot before
someone can join.

## What's out of scope for now (call out if priorities change)

- Multi-node/horizontal scaling (add more Wings nodes behind the same
  panel later if you add more worlds/players).
- Public exposure beyond a whitelist (would push you toward Shield
  Advanced or a Minecraft-specific proxy, plus WAF on the panel).
