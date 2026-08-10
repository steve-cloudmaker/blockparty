# Deployment status

Tracks where the **current live instance** actually stands against
[`POST_DEPLOY.md`](../POST_DEPLOY.md)'s numbered steps — separate from
whether the automated scripts *would* get a fresh deploy this far
unattended (see the "automated vs. manual" note below).

Update this file as steps get done. Don't treat it as historical — it
describes the instance as of the last edit, not a log.

## Current live stack

- Profile: `dev-lab`, region: `us-west-1`, stack: `minecraft-server`
- Domain: `blockparty.charliesystems.ai`
- **`InstanceId` changes on redeploy/replacement** — don't hardcode it
  anywhere; pull it fresh from stack outputs:
  ```bash
  aws cloudformation describe-stacks --profile dev-lab --region us-west-1 \
    --stack-name minecraft-server --query "Stacks[0].Outputs" --output table
  ```

## Step checklist

- [x] **1. Confirm DNS propagated** — verified, both apex and wildcard
      resolve to the stack's `PublicIp`.
- [x] **2. Issue the wildcard TLS cert** — issued via `certbot`
      (`dns-route53`). Panel's SSL `panel.conf` written by hand per the
      updated step 2 (the panel image doesn't do this automatically — see
      [`AI_ONBOARDING.md`](AI_ONBOARDING.md) gotcha #5). Panel confirmed
      reachable over HTTPS from the admin CIDR.
- [x] **3. Create admin account** — done. `users.external_id` NOT NULL
      issue (gotcha #4 in AI_ONBOARDING.md) was hit and fixed by hand on
      *this* instance via a direct `ALTER TABLE`, since that fix landed in
      `POST_DEPLOY.md` after this instance had already migrated. Admin
      account: `steve.cloudmaker@gmail.com`, admin = yes.
- [x] **4. Log into the panel** — reachable and logged in (implied by
      reaching step 5/6).
- [x] **5. Create a Location and a Node** — done.
- [x] **6. Apply Wings config, start Wings** — hit three issues on this
      instance, all now permanently fixed in `bootstrap.sh` for future
      deploys: the hairpin-DNS timeout on `wings configure` (gotcha #6),
      fixed by hand with a loopback `/etc/hosts` entry; a timezone
      crash-loop on startup, `the supplied timezone n/a is invalid`
      (gotcha #7), fixed by hand with `Environment=TZ=UTC` on the systemd
      unit; then a Docker network collision, `Pool overlaps with other one
      on this address space` (gotcha #8), fixed by hand by pinning the
      panel's compose network to `172.20.0.0/16`. `systemctl status wings`
      now shows `active (running)`, clean.
- [x] **7. Create allocations (25565, 25566)** — done (IP `0.0.0.0` gotcha
      #9, documented but not a bug).
- [x] **8. Create the two servers (Paper, Forge/Fabric)** — both done.
      Paper server created first (4096MB memory, 5000MB disk) and hit
      "Could not establish a connection to the machine running this
      server" — a second instance of the hairpin-DNS problem, this time
      from inside the panel container's isolated `/etc/hosts` (gotcha
      #10), fixed by hand with an `extra_hosts: host-gateway` override, now
      permanent in `bootstrap.sh`. Forge/Fabric server created afterward
      with no issues — confirms the fix holds. Backup Limit was left at 0
      on the Paper server, blocking step 9 until rebuilt/reconfigured.
      Opening a server's console also hit "We're having some trouble
      connecting to your server" — Wings' daemon port (8080) was never
      opened in the security group, even to admin CIDR (gotcha #11); fixed
      with an admin-CIDR-restricted ingress rule, now permanent in
      `cloudformation/minecraft-stack.yaml`. Requires a `scripts/deploy.sh`
      re-run on this stack to actually take effect (SG change, not
      user-data — a fresh boot won't pick it up).
- [ ] **9. Wire up S3 backups** — blocked on Backup Limit being 0; rebuild
      in progress.
- [ ] **10. Whitelist friends**
- [ ] **11. Verify DDoS/security posture**

## Automated vs. manual right now

Steps 1–2 are what `bootstrap.sh` sets up automatically on a fresh instance
(DNS records via CloudFormation, cert issuance still requires running the
`certbot` command by hand — DNS-01 needs a real run, not just config).
Step 3's schema-loading crash (gotcha #3) is now fixed permanently in
`bootstrap.sh`, so a *fresh* deploy should sail through the automatic
migration cleanly — but the `external_id` `ALTER TABLE` (gotcha #4) is
still a required manual one-liner in `POST_DEPLOY.md`, since it depends on
migrations having already finished. Steps 4 onward are inherently manual
(panel UI clicks) and not expected to ever be automated.

## Known backlog (not blocking, not yet done)

From a one-time `checkov` scan of `cloudformation/minecraft-stack.yaml`
(see [`AI_ONBOARDING.md`](AI_ONBOARDING.md) → Conventions):
- Security group rules missing `Description` fields
- S3 backup bucket has no access logging enabled
- SNS alarm topic isn't encrypted at rest

None are exposure risks; just unaddressed hardening suggestions.
