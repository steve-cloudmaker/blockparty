# Deployment status

Tracks where the **current live instance** actually stands against
[`POST_DEPLOY.md`](../POST_DEPLOY.md)'s numbered steps — separate from
whether the automated scripts *would* get a fresh deploy this far
unattended.

**Last reconciled:** 2026-08-17 09:17:27 UTC via
`scripts/refresh-deployment-status.sh`. Prefer re-running that script
over hand-editing the checklist; pass `--write` to apply. Steps the
script cannot prove stay **unknown** on purpose so a human verifies them.

## Live stack

Stack `minecraft-server` is `UPDATE_COMPLETE` in `us-west-1`.
DeployCompute=`true`, BackupBucketExists=`true`.

| | |
|---|---|
| Instance | `i-08b94a591121bd811` (`c6g.xlarge`) |
| Public IP | `13.56.129.171` |
| Panel | `https://blockparty.charliesystems.ai` |
| SSM | `aws ssm start-session --target i-08b94a591121bd811 --profile dev-lab --region us-west-1` |
| Backup bucket | `minecraft-backups-164083713732-us-west-1` (present=true; objects≈0) |
| SES | identity=`blockparty.charliesystems.ai` verified=true config-set=`minecraft-server-panel-mail` panel-mail=`ses` |

Bootstrap: `=== bootstrap complete: Mon Aug 10 22:08:33 UTC 2026 ===`.

On-box probe: panel_running_count=3 cert=1 ssl_conf=1 wings_active=1 wings_configured=1 server_volumes=2.

## Step checklist

- [x] 1. Confirm DNS propagated — dig apex+wildcard both return 13.56.129.171
- [x] 2. Issue the wildcard TLS cert — LE cert on disk and panel.conf has listen 443 ssl
- [ ] 3. Create admin account (includes gotcha #4 ALTER TABLE one-liner) — **unknown** — admin account only visible in panel/DB — verify manually
- [ ] 4. Log into the panel — **unknown** — login is a human action — verify manually
- [x] 5. Create a Location and a Node — Wings config present at /etc/pterodactyl/config.yml (node was configured)
- [x] 6. Apply Wings config, start Wings — wings.service is active
- [x] 7. Create allocations (25565, 25566) — inferred from 2 server volume(s) — allocations required to create them
- [x] 8. Create the two servers (Paper, Forge/Fabric) — 2 server volumes under /var/lib/pterodactyl/volumes
- [ ] 9. Wire up S3 backups — **unknown** — bucket exists but is empty — may or may not be wired in the panel
- [ ] 10. Whitelist friends — **unknown** — whitelist requires a Minecraft client / friends — verify manually
- [ ] 11. Verify DDoS/security posture — **unknown** — security posture is a human review (POST_DEPLOY.md step 11)

## Automated vs. manual right now

DNS/TLS/Wings/server-volume signals above come from live probes. Steps marked
**unknown** (admin account, panel login, whitelist, security review — and
sometimes allocations/backups when evidence is ambiguous) still need a human.
Gotchas #1–3 and #5–14 are permanent fixes in `bootstrap.sh`/the template;
see [`AI_ONBOARDING.md`](AI_ONBOARDING.md). Step 3's `external_id`
`ALTER TABLE` remains a required manual one-liner in `POST_DEPLOY.md`.
Gotcha #14: live panel mail is SES; do not edit UserData `MAIL_*` on a
live stack (that replaces the instance).

## Two-tier teardown and tagging

`DeployCompute` / `HasCompute` supports tier-1 compute teardown while
keeping VPC/SG/IAM/S3/DNS/SES/DLM/SNS. `deploy.sh` tags resources
(`Project=blockparty Build=<stack name> ManagedBy=cloudformation`).
Tier-2 full teardown retains the S3 backup bucket; redeploy auto-detects it
via `BackupBucketExists` (gotcha #13). See `ARCHITECTURE.md` and
`POST_DEPLOY.md` → Teardown & rebuild.

## Known backlog (not blocking, not yet done)

From a one-time `checkov` scan of `cloudformation/minecraft-stack.yaml`
(see [`AI_ONBOARDING.md`](AI_ONBOARDING.md) → Conventions):
- Security group rules missing `Description` fields
- S3 backup bucket has no access logging enabled
- SNS alarm topic isn't encrypted at rest

None are exposure risks; just unaddressed hardening suggestions.
