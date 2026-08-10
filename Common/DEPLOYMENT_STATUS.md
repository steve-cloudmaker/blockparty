# Deployment status

Tracks where the **current live instance** actually stands against
[`POST_DEPLOY.md`](../POST_DEPLOY.md)'s numbered steps — separate from
whether the automated scripts *would* get a fresh deploy this far
unattended (see the "automated vs. manual" note below).

Update this file as steps get done. Don't treat it as historical — it
describes the instance as of the last edit, not a log.

## No live stack right now

A full tier-2 teardown (`scripts/teardown.sh`) ran and is confirmed
complete — `aws cloudformation describe-stacks --stack-name
minecraft-server` returns `ValidationError: Stack ... does not exist`. VPC,
security group, IAM, EC2 instance, EBS data volume, DNS records, DLM
policy, and SNS topic are all gone.

The **S3 backup bucket survived**, as designed (`DeletionPolicy: Retain`),
confirmed present via `aws s3 ls`: `minecraft-backups-164083713732-us-west-1`
(`us-west-1`). It holds the Paper and Forge/Fabric backups taken just
before teardown — restore from these once a fresh instance and node exist
again.

## Step checklist (reset — nothing deployed)

All steps below reset to unchecked; the previous run's history (which
gotchas got hit, how they were fixed) lives in `git log` and in
[`AI_ONBOARDING.md`](AI_ONBOARDING.md)'s gotcha list, which is
instance-independent and still fully accurate for the next deploy. Per the
"Automated vs. manual" note below, a fresh deploy should sail through
steps 1–8 without re-hitting gotchas #1–3 and #5–12 (all permanent fixes in
`bootstrap.sh`/the template now) — only gotcha #4's `ALTER TABLE` (step 3)
remains a required manual one-liner.

- [ ] 1. Confirm DNS propagated
- [ ] 2. Issue the wildcard TLS cert
- [ ] 3. Create admin account
- [ ] 4. Log into the panel
- [ ] 5. Create a Location and a Node
- [ ] 6. Apply Wings config, start Wings
- [ ] 7. Create allocations (25565, 25566)
- [ ] 8. Create the two servers (Paper, Forge/Fabric)
- [ ] 9. Wire up S3 backups
- [ ] 10. Whitelist friends — was blocked last time on needing a Minecraft
      license to test with; still true unless that's been resolved since.
- [ ] 11. Verify DDoS/security posture

## Automated vs. manual right now

Steps 1–2 are what `bootstrap.sh` sets up automatically on a fresh instance
(DNS records via CloudFormation, cert issuance still requires running the
`certbot` command by hand — DNS-01 needs a real run, not just config).
Step 3's schema-loading crash (gotcha #3) is fixed permanently in
`bootstrap.sh`, so a *fresh* deploy should sail through the automatic
migration cleanly — but the `external_id` `ALTER TABLE` (gotcha #4) is
still a required manual one-liner in `POST_DEPLOY.md`, since it depends on
migrations having already finished. Steps 4 onward are inherently manual
(panel UI clicks) and not expected to ever be automated.

## Two-tier teardown and tagging

`cloudformation/minecraft-stack.yaml` has a `DeployCompute`
parameter/`HasCompute` condition (tier-1: `DEPLOY_COMPUTE=false
scripts/deploy.sh` tears down EC2/EBS/EIP-association/alarms, keeps
VPC/SG/IAM/S3 backups/DNS/DLM/SNS) and `deploy.sh` tags every resource
(`Project=blockparty Build=<stack name> ManagedBy=cloudformation`).

**Tier-2 is confirmed working for real** — S3 bucket retained exactly as
designed. **Tier-1 still hasn't been exercised** — the stack went straight
to a full teardown without a tier-1 test first.

**Redeploying from scratch after that tier-2 teardown immediately hit a
real bug**: changeset creation failed with
`[AWS::EarlyValidation::ResourceExistenceCheck]` — the retained S3 bucket
collided with CloudFormation trying to `Add` a bucket with the same
(globally unique) name again. Fixed with a `BackupBucketExists`
parameter/`ShouldCreateBackupBucket` condition, `deploy.sh` now
auto-detects it via `head-bucket` (see gotcha #13 in `AI_ONBOARDING.md`).
The failed attempt left a stub stack in `REVIEW_IN_PROGRESS` — deleted
before retrying. **Tagging still unverified against a real deploy** — the
tagging feature landed after the last real deploy on the now-deleted
stack, so it's never actually applied yet; watch for it on the next
successful run. Full design writeup in `ARCHITECTURE.md` → "Teardown
tiers" / "Tagging", command reference in `POST_DEPLOY.md` → "Teardown &
rebuild".

## Known backlog (not blocking, not yet done)

From a one-time `checkov` scan of `cloudformation/minecraft-stack.yaml`
(see [`AI_ONBOARDING.md`](AI_ONBOARDING.md) → Conventions):
- Security group rules missing `Description` fields
- S3 backup bucket has no access logging enabled
- SNS alarm topic isn't encrypted at rest

None are exposure risks; just unaddressed hardening suggestions.
