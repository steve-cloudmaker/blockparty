# AI onboarding

Context for an AI assistant working on this repo with no memory of prior
sessions. Read [`START_HERE.md`](START_HERE.md) first for the doc map. This
file covers the parts that aren't obvious from the code and are easy to get
wrong or re-diagnose from scratch.

## Account / environment facts

- AWS CLI profile: **`dev-lab`** — an IAM Identity Center (SSO) profile, not
  static keys.
  - SSO session name: `cloudmaker`. Instance URL
    `https://identitycenter.amazonaws.com/ssoins-82011f01b5b11537`, **SSO
    region `us-west-1`** — separate from any other AWS SSO org already
    logged into on this machine. `aws sso login --profile dev-lab` logs
    into *this* session specifically.
  - Account: `164083713732`. Role/permission-set name must be exactly
    `AWSAdministratorAccess` (matches `sso_role_name` in `~/.aws/config`) —
    if IAM Identity Center has a permission set under a different name
    (e.g. `AdministratorAccess` without the `AWS` prefix), `aws sts
    get-caller-identity` fails with `ForbiddenException: No access` even
    though the login itself succeeded. Not a credentials problem — a naming
    mismatch between the assigned permission set and `sso_role_name`.
- **Deploy region is `us-west-1`.** `scripts/deploy.sh` reads the
  `AWS_REGION` env var (falls back to `us-east-1` if unset) — a plain
  `REGION=` override is silently ignored, it's just an unused shell
  variable. Always: `AWS_REGION=us-west-1 scripts/deploy.sh`.
- Stack name: `minecraft-server`. Domain: `blockparty.charliesystems.ai`
  (Route 53 zone `charliesystems.ai`, same account). Access to the instance
  is SSM Session Manager only — no SSH key exists.
- Repo is **public** on GitHub (`steve-cloudmaker/blockparty`). Secrets
  hygiene matters here for real, not hypothetically — see Conventions below.

## Gotchas already diagnosed and fixed — don't rediscover these

Check `git log --oneline` before assuming something is broken; most sharp
edges hit so far are already patched. In rough chronological order:

1. **AL2023 ships `curl-minimal`**, which conflicts with the full `curl`
   package bootstrap needs (for certbot/AWS CLI downloads). `dnf install`
   without `--allowerasing` aborts the *entire* transaction atomically —
   Docker never even installs. Fixed in `scripts/bootstrap.sh` and the
   embedded copy in `cloudformation/minecraft-stack.yaml`.
2. **AL2023's default `python3-pip` is 21.3.1**, which predates the
   `--break-system-packages` flag (added in pip 23.0.1 for PEP 668) and
   errors on the unrecognized option. Fixed with a runtime capability check
   — and note the check itself is written as an `if` block, not a bare
   `grep ... && VAR=...`, because under `set -e` a bare `&&` list that
   fails on its left side kills the script silently (this bit us once;
   see commit `5cf5636`).
3. **Pterodactyl's bundled `database/schema/mysql-schema.sql` fast-path**
   shells out to the `mysql` CLI, which on the image in use requires TLS —
   but the `mariadb:10.11` container here doesn't have TLS configured, so
   the fast-path always fails with `SSL is required, but the server does
   not support it`. Fixed permanently by bind-mounting an empty host
   directory over `/app/database/schema` inside the panel container (see
   the `empty-schema` volume in `bootstrap.sh`), which hides the dump file
   and forces Laravel to fall through to running every migration
   individually via PDO instead — that path doesn't use the CLI, so it's
   unaffected by the TLS issue. Runs cleanly and automatically now on first
   boot, no manual re-run needed.
4. **Running migrations individually (rather than via the schema dump)
   leaves `users.external_id` as `NOT NULL`** when it's supposed to be
   nullable — schema drift between Pterodactyl's packaged snapshot and its
   individual migration files. Surfaces as `SQLSTATE[23000]: ... Column
   'external_id' cannot be null` the first time you run `p:user:make`.
   One-time fix is documented and required in `POST_DEPLOY.md` step 3 (an
   `ALTER TABLE` right before creating the admin account) — this can't be
   baked into `bootstrap.sh` because it needs the database already
   migrated, which only finishes after boot.
5. **The Pterodactyl panel image doesn't auto-enable SSL** on restart just
   because certs exist at `/etc/letsencrypt`. Its entrypoint only writes an
   SSL nginx config when an `LE_EMAIL` env var is set — and setting that
   triggers the container's *own* standalone HTTP-01 certbot, which
   conflicts with the wildcard DNS-01 cert this project manages on the
   host. So the panel serves plain HTTP by default, permanently, once
   `panel.conf` is first written. `POST_DEPLOY.md` step 2 now includes
   writing the real SSL `panel.conf` by hand (pointed at the host-managed
   cert) as part of the documented procedure — a bare `docker compose
   restart panel` after cert issuance is **not** sufficient on its own.
6. **`wings configure` can hang and time out** with `context deadline
   exceeded` fetching the panel's API over its public FQDN. That FQDN
   resolves to this instance's own Elastic IP, and an EC2 instance
   generally can't reach its own public IP back through the Internet
   Gateway (no NAT gateway in this VPC — see `ARCHITECTURE.md`) — the
   request just hangs. Fixed by having `bootstrap.sh` add a loopback
   `/etc/hosts` entry for the subdomain before anything else runs, so
   Wings and the panel talk over `127.0.0.1` instead. TLS still verifies
   correctly either way, since the cert matches the hostname regardless of
   which IP served it.
7. **Wings can crash-loop on startup** with `the supplied timezone n/a is
   invalid`. Its timezone auto-detection (`config.ConfigureTimezone()` in
   the Wings source) falls back to parsing `timedatectl` output when
   `/etc/timezone` doesn't exist — which it never does on AL2023, that's a
   Debian/Ubuntu-only file — and AL2023's minimal AMI often hasn't set up
   `/etc/localtime` as a real zoneinfo symlink, so `timedatectl` literally
   prints `Time zone: n/a`. Fixed by setting `Environment=TZ=UTC` directly
   on the `wings.service` systemd unit in `bootstrap.sh`, matching
   `APP_TIMEZONE: "UTC"` already set on the panel container — `TZ` env is
   checked before any host detection is attempted.
8. **Wings fails to start with `Pool overlaps with other one on this
   address space`.** Wings' own default network (`pterodactyl_nw`, created
   on its first start) hardcodes `172.18.0.0/16` — the exact subnet Docker
   Compose picks by default for the panel's own bridge network too, since
   panel and Wings share one box here. Fixed by pinning the panel's compose
   network to `172.20.0.0/16` explicitly (`networks.default.ipam` block at
   the end of the generated `docker-compose.yml` in `bootstrap.sh`), well
   clear of both Docker's own default bridge (`172.17.0.0/16`) and Wings'
   hardcoded default.
9. **Allocation IP in the panel UI (Nodes → Allocations → Create) is not
   the public/Elastic IP.** The Elastic IP is NAT'd at AWS's network edge
   and is never actually bound to the instance's own interface — the OS
   only knows its private IP (`10.20.x.x`). Use `0.0.0.0` to bind all
   interfaces (never `127.0.0.1`, which the panel disallows). This is
   documented in `POST_DEPLOY.md` step 7 — not a bug to fix, just a
   UI field that's easy to fill in wrong once.
10. **The panel shows "Could not establish a connection to the machine
    running this server"** when creating/viewing a server. This is the
    *panel backend* failing to reach Wings, not the browser — a second,
    separate instance of gotcha #6's hairpin-DNS problem. Docker containers
    have their own isolated `/etc/hosts`, so the host-level loopback entry
    from gotcha #6 doesn't carry into the panel container; its request to
    `https://$SUBDOMAIN:8080` resolves via public DNS to the instance's own
    Elastic IP and hangs the same way. Fixed with an `extra_hosts:
    ["$SUBDOMAIN:host-gateway"]` override on the panel service in
    `docker-compose.yml` — `host-gateway` is Docker's own alias for "the
    host, as reachable from this container," so no IP needs hardcoding.
11. **A server's console shows "We're having some trouble connecting to
    your server, please wait..." and never clears.** Different code path
    than gotcha #10: the panel's *frontend* JS opens a WebSocket directly
    from the browser to Wings' daemon port (8080), bypassing the panel
    backend entirely — that's how the live console/stats work. The
    security group originally never opened 8080 at all, on the (wrong, for
    this specific case) assumption that Wings' API never needed to be
    reachable from outside the host. Fixed with an admin-CIDR-restricted
    `8080/tcp` ingress rule on `GameServerSecurityGroup` in
    `cloudformation/minecraft-stack.yaml` — same restriction as the panel's
    443 rule, not opened any wider.
12. **A Forge server crashes with `Unable to access jarfile server.jar`**
    right after "Server marked as starting," even though the install
    succeeded. Modern Forge (roughly 1.17+) installs a launcher script
    (`run.sh`) plus a `*-shim.jar` instead of a monolithic `server.jar`, but
    the built-in "Forge" egg's default Startup Command hardcodes `-jar
    server.jar`. Expected on first boot — the real jar name isn't knowable
    until install finishes. Workflow in `POST_DEPLOY.md` step 8: create →
    let install finish → `ls` the volume for the shim jar → point Startup
    at it → restart. Not an infrastructure bug; not `bootstrap.sh`.
13. **Redeploying from scratch after a tier-2 teardown fails changeset
    creation** with `[AWS::EarlyValidation::ResourceExistenceCheck]`. The
    S3 backup bucket survives the teardown on purpose
    (`DeletionPolicy: Retain`), but S3 bucket names are globally unique, so
    CloudFormation refuses to even build a changeset that tries to `Add` a
    bucket with a name that already exists. Fixed with a
    `BackupBucketExists` parameter/`ShouldCreateBackupBucket` condition —
    when true, the template skips declaring the bucket and references it
    by its deterministic name instead (falls out of CloudFormation's
    management, which is fine — it was already effectively unmanaged the
    moment `Retain` let it survive a stack deletion). `deploy.sh`
    auto-detects this via `head-bucket` rather than needing a remembered
    flag. If you hit this anyway (e.g. an older `deploy.sh` on disk), the
    failed attempt leaves a stub stack in `REVIEW_IN_PROGRESS` with no real
    resources — safe to `aws cloudformation delete-stack` before retrying
    on a current checkout.
14. **Panel invites never arrive in Gmail.** The original bootstrap set
    `MAIL_DRIVER: "log"`, so Laravel wrote the MIME message to
    `/srv/pterodactyl/panel/logs/` and never called SES. Mail is now the
    Laravel `ses` driver, credentials from the instance role (no SMTP
    user), from `noreply@blockparty.charliesystems.ai`. Production access is
    granted. Bounce/complaint handling is a configuration set default on
    the domain identity (`minecraft-server-panel-mail`) publishing to SNS
    topic `minecraft-server-ses-events` (email the notification address);
    the account suppression list already blocks re-sends. Confirm the SNS
    subscription or those notifications never arrive. Two traps:
    (a) Before production access, a "sent" invite to an unverified Gmail
    is a `MessageRejected`, not a log-driver miss. (b) Do **not** "fix"
    mail by editing `MAIL_*` in the embedded
    CloudFormation UserData on a live stack — `AWS::EC2::Instance`
    UserData updates replace the instance. Patch
    `/srv/pterodactyl/panel/docker-compose.yml` in place (then
    `docker compose up -d panel`) and keep `scripts/bootstrap.sh` as the
    source of truth for the next compute rebuild; copy those `MAIL_*`
    lines into the template UserData only as part of that rebuild.

## Diagnosing faster than clicking through the UI

`scripts/diagnose.sh` checks all of the above in one pass — read-only,
meant to be run on the instance over SSM. Reach for it before manually
re-deriving any of the above from scratch:
```
curl -s https://raw.githubusercontent.com/steve-cloudmaker/blockparty/main/scripts/diagnose.sh | sudo bash
```
It only sees what the instance itself can see; security-group-level checks
(which ports are actually open) still need `aws ec2 describe-security-groups`
from your own machine — see `POST_DEPLOY.md` step 11.

## Teardown tiers and tagging

The template has a `DeployCompute` parameter/`HasCompute` condition
splitting resources into "core" (VPC, SG, IAM, S3 backups, DNS, SES mail,
DLM, SNS)
and "compute" (EC2 instance, EBS data volume, EIP *association*,
instance-scoped alarms). `DEPLOY_COMPUTE=false scripts/deploy.sh` tears
down just compute via a stack update; re-running `scripts/deploy.sh`
normally rebuilds it, re-associating with the *same* Elastic IP so DNS
never needs touching. `scripts/teardown.sh` remains the tier-2 "delete
everything" path (S3 bucket still retained). Full writeup in
`ARCHITECTURE.md`'s "Teardown tiers" section and `POST_DEPLOY.md`'s
teardown section — don't re-derive a different teardown scheme without
reading those first, this one was a deliberate design choice (single stack
+ conditional resources, not a core/compute stack split) made after
weighing both.

`deploy.sh` also tags every resource in the stack via `--tags
Project=blockparty Build=<stack name> ManagedBy=cloudformation` — `Build`
is the stack name specifically, anticipating a future with more than one
independent deployment side by side.

Redeploying from scratch after a tier-2 teardown has its own gotcha (#13
above) — the retained S3 bucket collides with CloudFormation trying to
recreate it. `deploy.sh` handles this automatically now.

## Conventions

- Never put secrets in tracked files. `.gitignore` blocks common shapes
  (`.env`, `*.pem`, `*.key`, `*credentials*`, `*secret*`) and a `pre-commit`
  hook runs `gitleaks` on every commit — but both are best-effort, not a
  substitute for judgment.
- Commit messages explain *why* something broke and *why* the fix works,
  not just what changed — follow the existing log's style.
- The CloudFormation template is `cfn-lint`-clean and was checked once with
  `checkov` (installed via `brew install checkov`). Three low-severity
  hardening suggestions are still open and not yet acted on: security group
  rules lack `Description` fields, the S3 backup bucket doesn't have access
  logging enabled, and the SNS alarm topic isn't encrypted at rest. None of
  these are exposure risks — they're just unaddressed backlog.

## Before recommending a fix

Grep for the symptom in `POST_DEPLOY.md`, `bootstrap.sh`, and `git log`
first. Several of the issues above look like generic AWS/Docker/Laravel
problems at first glance but have project-specific fixes already in place —
re-deriving a generic fix (e.g. a different pip workaround, a different
nginx config) risks reverting something that was deliberately shaped around
a constraint documented here (like the DNS-01 wildcard vs. the panel's
built-in HTTP-01 certbot).
