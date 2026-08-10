# Minecraft on AWS (dev-lab)

Lives at **blockparty.charliesystems.ai** — panel over HTTPS with a Let's
Encrypt wildcard cert, game worlds on 25565/25566.

Read [`ARCHITECTURE.md`](./ARCHITECTURE.md) first for the design and
tradeoffs. Then:

```
scripts/deploy.sh
```

`deploy.sh` looks up the `charliesystems.ai` Route 53 hosted zone
automatically, prompts for the CIDR allowed to reach the panel (defaults to
your current public IP) and a notification email, confirms what it's about
to create, then runs `aws cloudformation deploy --profile dev-lab`. Takes
~3-5 minutes for the stack, plus ~3-5 minutes of user-data bootstrap on
first boot. (Override the subdomain/domain with `SUBDOMAIN_LABEL=` /
`ROOT_DOMAIN=` env vars if you ever want something other than
`blockparty.charliesystems.ai`.)

After that: follow [`POST_DEPLOY.md`](./POST_DEPLOY.md) for the one-time
manual steps (confirm DNS, issue the wildcard cert, admin account, node
registration, creating the Paper + Forge/Fabric servers, wiring up S3
backups) — these involve secrets, so they're deliberately not automated
into CloudFormation parameters.

To tear everything down: `scripts/teardown.sh` (the S3 backup bucket is
retained on purpose; delete it yourself once you're sure).

## Files

| File | Purpose |
|---|---|
| `ARCHITECTURE.md` | Design, security model, DNS/TLS approach, DDoS approach, backup strategy, cost estimate |
| `cloudformation/minecraft-stack.yaml` | The whole stack — VPC, security group, IAM, EC2, EBS, S3, DLM snapshots, CloudWatch alarms, Route 53 records |
| `scripts/bootstrap.sh` | Human-readable copy of the EC2 user-data (installs Docker, Pterodactyl Panel, Wings, certbot) — the template embeds an equivalent copy directly |
| `scripts/deploy.sh` | `aws cloudformation deploy` wrapper, auto-looks-up the hosted zone |
| `scripts/teardown.sh` | `aws cloudformation delete-stack` wrapper |
| `scripts/diagnose.sh` | Read-only health check — run on the instance to check for every known failure mode in one pass instead of clicking through the panel UI |
| `POST_DEPLOY.md` | Manual setup after the stack is up: DNS check, wildcard cert issuance, admin account, node registration, server creation, backups, whitelist |

## Dev setup

This repo is public, so a [pre-commit](https://pre-commit.com) hook
(`.pre-commit-config.yaml`) runs [gitleaks](https://github.com/gitleaks/gitleaks)
before every commit to block anything secret-shaped from landing in history.
Git hooks aren't installed automatically on clone — after cloning, run once:

```
brew install pre-commit
pre-commit install
```

Validated with `cfn-lint` (clean) and `bash -n` against the exact script
embedded in the template. Not yet run against a live AWS account — I don't
have your AWS credentials in this environment, so `deploy.sh` is meant to be
run from your machine with the `dev-lab` profile.
