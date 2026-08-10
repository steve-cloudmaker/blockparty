# Start here

This is `blockparty` — a small, whitelisted Minecraft server (Paper +
Forge/Fabric) running on AWS behind Pterodactyl, reachable at
`blockparty.charliesystems.ai`. Public repo, single-maintainer dev-lab
project.

## Where things live

| Doc | Read it for |
|---|---|
| [`README.md`](../README.md) | Quick start, file map, dev setup (pre-commit hook) |
| [`ARCHITECTURE.md`](../ARCHITECTURE.md) | Design, security model, DNS/TLS, DDoS, backups, cost |
| [`POST_DEPLOY.md`](../POST_DEPLOY.md) | The manual steps after `deploy.sh` — numbered, run in order |
| [`Common/DEPLOYMENT_STATUS.md`](DEPLOYMENT_STATUS.md) | Where the *current* live deploy actually stands right now |
| [`Common/AI_ONBOARDING.md`](AI_ONBOARDING.md) | Context for an AI assistant picking this up cold |
| `cloudformation/minecraft-stack.yaml` | The whole stack, one file |
| `scripts/{bootstrap,deploy,teardown}.sh` | Deploy tooling |

## If you're deploying this for the first time

1. [`README.md`](../README.md) — run `scripts/deploy.sh`
2. [`ARCHITECTURE.md`](../ARCHITECTURE.md) — understand what you just created and why
3. [`POST_DEPLOY.md`](../POST_DEPLOY.md) — the manual steps, in order, right after the stack is up

## If you're picking up mid-deployment

Check [`Common/DEPLOYMENT_STATUS.md`](DEPLOYMENT_STATUS.md) first — it tracks
which `POST_DEPLOY.md` step this specific live instance is actually on, plus
any workarounds already applied by hand that aren't baked into the automated
scripts yet.

## If you're an AI assistant

Read [`Common/AI_ONBOARDING.md`](AI_ONBOARDING.md) before touching anything —
it covers account/region specifics that are easy to get wrong, and a list of
gotchas already diagnosed and fixed so you don't rediscover them from
scratch.

## Dev setup

One-time, after cloning:
```bash
brew install pre-commit
pre-commit install
```
Blocks secret-shaped commits via gitleaks. See `README.md` → Dev setup for
why.
