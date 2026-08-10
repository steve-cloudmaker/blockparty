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
