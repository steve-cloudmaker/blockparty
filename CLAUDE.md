# blockparty

Read [`Common/START_HERE.md`](Common/START_HERE.md) and
[`Common/AI_ONBOARDING.md`](Common/AI_ONBOARDING.md) before doing anything
in this repo — they cover AWS account/region specifics that are easy to get
wrong (wrong SSO session, wrong region env var) and a list of gotchas
already diagnosed and fixed, so you don't re-debug them from scratch.

Quick fact most likely to trip you up: deploys need
`AWS_REGION=us-west-1` set explicitly — `REGION=` is silently ignored.
