#!/usr/bin/env bash
# Reconcile Common/DEPLOYMENT_STATUS.md against the live AWS deploy.
#
# Default is dry-run: probe CloudFormation/DNS/S3/(SSM) and print a
# per-step diff of file vs live. Pass --write to rewrite the status file.
#
# Usage:
#   AWS_REGION=us-west-1 scripts/refresh-deployment-status.sh
#   AWS_REGION=us-west-1 scripts/refresh-deployment-status.sh --write
#
# Exit codes:
#   0  live matches file (or only unknowns), or --write succeeded
#   1  one or more steps CHANGED (dry-run only — so a stale file is noticeable)
#   2  probe/auth failure
#
# Requires: aws CLI, jq, dig. Bash 3.2+ (macOS /bin/bash OK).
#
set -euo pipefail

PROFILE="${AWS_PROFILE:-dev-lab}"
REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-minecraft-server}"
ROOT_DOMAIN="${ROOT_DOMAIN:-charliesystems.ai}"
SUBDOMAIN_LABEL="${SUBDOMAIN_LABEL:-blockparty}"
FQDN="${SUBDOMAIN_LABEL}.${ROOT_DOMAIN}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATUS_FILE="${REPO_ROOT}/Common/DEPLOYMENT_STATUS.md"

WRITE=false
for arg in "$@"; do
  case "$arg" in
    --write) WRITE=true ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg (try --write)" >&2
      exit 2
      ;;
  esac
done

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_FAIL=""; C_DIM=""; C_RESET=""
fi

die() { echo "${C_FAIL}error:${C_RESET} $*" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq)"
command -v dig >/dev/null 2>&1 || die "dig is required (brew install bind)"

echo "=== deployment status reconcile ==="
echo "profile=$PROFILE  region=$REGION  stack=$STACK_NAME"
echo "status file: $STATUS_FILE"
echo

if ! aws sts get-caller-identity --profile "$PROFILE" --region "$REGION" >/dev/null 2>&1; then
  die "could not authenticate with profile '$PROFILE' (try: aws sso login --profile $PROFILE)"
fi

# Parallel arrays indexed 1..11 (bash 3.2-safe; no associative arrays).
LIVE_STATE=()
LIVE_NOTE=()
FILE_STATE=()
STEP_TITLE=()

STEP_TITLE[1]="Confirm DNS propagated"
STEP_TITLE[2]="Issue the wildcard TLS cert"
STEP_TITLE[3]="Create admin account"
STEP_TITLE[4]="Log into the panel"
STEP_TITLE[5]="Create a Location and a Node"
STEP_TITLE[6]="Apply Wings config, start Wings"
STEP_TITLE[7]="Create allocations (25565, 25566)"
STEP_TITLE[8]="Create the two servers (Paper, Forge/Fabric)"
STEP_TITLE[9]="Wire up S3 backups"
STEP_TITLE[10]="Whitelist friends"
STEP_TITLE[11]="Verify DDoS/security posture"

set_live() {
  LIVE_STATE[$1]="$2"
  LIVE_NOTE[$1]="$3"
}

# ---------------------------------------------------------------------------
# Probe: CloudFormation
# ---------------------------------------------------------------------------
STACK_EXISTS=false
STACK_STATUS=""
INSTANCE_ID=""
PUBLIC_IP=""
PANEL_URL=""
BACKUP_BUCKET=""
SSM_CMD=""
DEPLOY_COMPUTE=""
BACKUP_BUCKET_EXISTS_PARAM=""
INSTANCE_TYPE=""
BOOTSTRAP_LINE=""
PANEL_UP=""
HAS_SSL_CONF=""
HAS_CERT=""
WINGS_ACTIVE=""
WINGS_CONFIGURED=""
SERVER_COUNT="0"
BUCKET_OBJECT_COUNT="0"
SSM_REACHABLE=false
BUCKET_PRESENT=false
MAIL_DRIVER=""
SES_VERIFIED=""
SES_CONFIG_SET=""

if aws cloudformation describe-stacks \
    --profile "$PROFILE" --region "$REGION" \
    --stack-name "$STACK_NAME" >/dev/null 2>&1; then
  STACK_EXISTS=true
  STACK_JSON=$(aws cloudformation describe-stacks \
    --profile "$PROFILE" --region "$REGION" \
    --stack-name "$STACK_NAME" --output json)

  STACK_STATUS=$(echo "$STACK_JSON" | jq -r '.Stacks[0].StackStatus')
  DEPLOY_COMPUTE=$(echo "$STACK_JSON" | jq -r '.Stacks[0].Parameters[] | select(.ParameterKey=="DeployCompute") | .ParameterValue')
  BACKUP_BUCKET_EXISTS_PARAM=$(echo "$STACK_JSON" | jq -r '.Stacks[0].Parameters[] | select(.ParameterKey=="BackupBucketExists") | .ParameterValue')

  out() { echo "$STACK_JSON" | jq -r --arg k "$1" '.Stacks[0].Outputs[]? | select(.OutputKey==$k) | .OutputValue // empty'; }
  INSTANCE_ID=$(out InstanceId)
  PUBLIC_IP=$(out PublicIp)
  PANEL_URL=$(out PanelUrl)
  BACKUP_BUCKET=$(out BackupBucketName)
  SSM_CMD=$(out SsmConnectCommand)

  if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
    INSTANCE_TYPE=$(aws ec2 describe-instances \
      --profile "$PROFILE" --region "$REGION" \
      --instance-ids "$INSTANCE_ID" \
      --query 'Reservations[0].Instances[0].InstanceType' --output text 2>/dev/null || echo "")
  fi
else
  echo "No CloudFormation stack named '$STACK_NAME' in $REGION."
fi

if [ -z "$BACKUP_BUCKET" ]; then
  ACCOUNT_ID=$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)
  BACKUP_BUCKET="minecraft-backups-${ACCOUNT_ID}-${REGION}"
fi

# ---------------------------------------------------------------------------
# Probe: DNS
# ---------------------------------------------------------------------------
DNS_APEX=$(dig +short "$FQDN" A 2>/dev/null | tail -1 | tr -d '[:space:]')
DNS_WILD=$(dig +short "status-probe.${FQDN}" A 2>/dev/null | tail -1 | tr -d '[:space:]')

# ---------------------------------------------------------------------------
# Probe: S3 backup bucket
# ---------------------------------------------------------------------------
if aws s3api head-bucket --profile "$PROFILE" --region "$REGION" --bucket "$BACKUP_BUCKET" >/dev/null 2>&1; then
  BUCKET_PRESENT=true
  BUCKET_OBJECT_COUNT=$(aws s3api list-objects-v2 \
    --profile "$PROFILE" --region "$REGION" \
    --bucket "$BACKUP_BUCKET" \
    --query 'length(Contents || `[]`)' --output text 2>/dev/null || echo 0)
  case "$BUCKET_OBJECT_COUNT" in
    ''|*[!0-9]*) BUCKET_OBJECT_COUNT=0 ;;
  esac
fi

# ---------------------------------------------------------------------------
# Probe: SES panel mail
# ---------------------------------------------------------------------------
if [ "$STACK_EXISTS" = true ]; then
  SES_JSON=$(aws sesv2 get-email-identity \
    --profile "$PROFILE" --region "$REGION" \
    --email-identity "$FQDN" --output json 2>/dev/null || echo "")
  if [ -n "$SES_JSON" ]; then
    SES_VERIFIED=$(echo "$SES_JSON" | jq -r '.VerifiedForSendingStatus')
    SES_CONFIG_SET=$(echo "$SES_JSON" | jq -r '.ConfigurationSetName // empty')
  fi
fi

# ---------------------------------------------------------------------------
# Probe: SSM on-instance signals
# ---------------------------------------------------------------------------
if [ "$STACK_EXISTS" = true ] && [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
  PING=$(aws ssm describe-instance-information \
    --profile "$PROFILE" --region "$REGION" \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "")
  if [ "$PING" = "Online" ]; then
    SSM_REACHABLE=true
    REMOTE_SCRIPT=$(cat <<'EOS'
set +e
if [ -f /var/log/bootstrap.log ] && grep -q "bootstrap complete" /var/log/bootstrap.log; then
  echo "BOOTSTRAP=$(grep "bootstrap complete" /var/log/bootstrap.log | tail -1)"
else
  echo "BOOTSTRAP="
fi
if command -v docker >/dev/null 2>&1 && [ -f /srv/pterodactyl/panel/docker-compose.yml ]; then
  cd /srv/pterodactyl/panel
  RUNNING=$(docker compose ps --status running --format '{{.Name}}' 2>/dev/null | wc -l | tr -d ' ')
  echo "PANEL_RUNNING_COUNT=$RUNNING"
else
  echo "PANEL_RUNNING_COUNT=0"
fi
if grep -q "listen 443 ssl" /srv/pterodactyl/panel/nginx/panel.conf 2>/dev/null; then
  echo "HAS_SSL_CONF=1"
else
  echo "HAS_SSL_CONF=0"
fi
if ls /etc/letsencrypt/live/*/fullchain.pem >/dev/null 2>&1; then
  echo "HAS_CERT=1"
else
  echo "HAS_CERT=0"
fi
if systemctl is-active --quiet wings 2>/dev/null; then
  echo "WINGS_ACTIVE=1"
else
  echo "WINGS_ACTIVE=0"
fi
if [ -f /etc/pterodactyl/config.yml ]; then
  echo "WINGS_CONFIGURED=1"
else
  echo "WINGS_CONFIGURED=0"
fi
COUNT=0
if [ -d /var/lib/pterodactyl/volumes ]; then
  for d in /var/lib/pterodactyl/volumes/*/; do
    [ -d "$d" ] || continue
    base=$(basename "$d")
    [ "$base" = ".sftp" ] && continue
    COUNT=$((COUNT + 1))
  done
fi
echo "SERVER_COUNT=$COUNT"
if grep -qE 'MAIL_MAILER: "ses"|MAIL_DRIVER: "ses"' /srv/pterodactyl/panel/docker-compose.yml 2>/dev/null; then
  echo "MAIL_DRIVER=ses"
elif grep -q 'MAIL_DRIVER: "log"' /srv/pterodactyl/panel/docker-compose.yml 2>/dev/null; then
  echo "MAIL_DRIVER=log"
else
  echo "MAIL_DRIVER=unknown"
fi
EOS
)
    REMOTE_JSON=$(jq -n --arg c "$REMOTE_SCRIPT" '{commands:[$c]}')
    CMD_ID=$(aws ssm send-command \
      --profile "$PROFILE" --region "$REGION" \
      --instance-ids "$INSTANCE_ID" \
      --document-name "AWS-RunShellScript" \
      --parameters "$REMOTE_JSON" \
      --query 'Command.CommandId' --output text)

    ST=""
    i=0
    while [ "$i" -lt 20 ]; do
      INV=$(aws ssm get-command-invocation \
        --profile "$PROFILE" --region "$REGION" \
        --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
        --output json 2>/dev/null || echo '{}')
      ST=$(echo "$INV" | jq -r '.Status // empty')
      case "$ST" in
        Success|Failed|Cancelled|TimedOut) break ;;
        *) sleep 1 ;;
      esac
      i=$((i + 1))
    done

    if [ "$ST" != "Success" ]; then
      echo "${C_WARN}warn:${C_RESET} SSM probe did not succeed (Status=$ST) — instance steps may show as unknown"
      SSM_REACHABLE=false
    else
      OUT=$(echo "$INV" | jq -r '.StandardOutputContent // empty')
      BOOTSTRAP_LINE=$(echo "$OUT" | sed -n 's/^BOOTSTRAP=//p' | head -1)
      PANEL_UP=$(echo "$OUT" | sed -n 's/^PANEL_RUNNING_COUNT=//p' | head -1)
      HAS_SSL_CONF=$(echo "$OUT" | sed -n 's/^HAS_SSL_CONF=//p' | head -1)
      HAS_CERT=$(echo "$OUT" | sed -n 's/^HAS_CERT=//p' | head -1)
      WINGS_ACTIVE=$(echo "$OUT" | sed -n 's/^WINGS_ACTIVE=//p' | head -1)
      WINGS_CONFIGURED=$(echo "$OUT" | sed -n 's/^WINGS_CONFIGURED=//p' | head -1)
      SERVER_COUNT=$(echo "$OUT" | sed -n 's/^SERVER_COUNT=//p' | head -1)
      MAIL_DRIVER=$(echo "$OUT" | sed -n 's/^MAIL_DRIVER=//p' | head -1)
      case "$SERVER_COUNT" in
        ''|*[!0-9]*) SERVER_COUNT=0 ;;
      esac
    fi
  else
    echo "${C_WARN}warn:${C_RESET} instance $INSTANCE_ID SSM PingStatus=${PING:-unknown} — skipping on-box probes"
  fi
fi

# ---------------------------------------------------------------------------
# Derive live step states: done | notdone | unknown
# ---------------------------------------------------------------------------
if [ "$STACK_EXISTS" = true ] && [ -n "$PUBLIC_IP" ] \
  && [ "$DNS_APEX" = "$PUBLIC_IP" ] && [ "$DNS_WILD" = "$PUBLIC_IP" ]; then
  set_live 1 done "dig apex+wildcard both return $PUBLIC_IP"
elif [ "$STACK_EXISTS" = true ] && [ -n "$PUBLIC_IP" ]; then
  set_live 1 notdone "expected $PUBLIC_IP, got apex=${DNS_APEX:-none} wild=${DNS_WILD:-none}"
elif [ -n "$DNS_APEX" ]; then
  set_live 1 unknown "DNS resolves to $DNS_APEX but no live stack PublicIp to compare"
else
  set_live 1 notdone "DNS does not resolve"
fi

if [ "$SSM_REACHABLE" = true ]; then
  if [ "${HAS_CERT:-0}" = 1 ] && [ "${HAS_SSL_CONF:-0}" = 1 ]; then
    set_live 2 done "LE cert on disk and panel.conf has listen 443 ssl"
  else
    set_live 2 notdone "HAS_CERT=${HAS_CERT:-?} HAS_SSL_CONF=${HAS_SSL_CONF:-?}"
  fi
else
  set_live 2 unknown "needs SSM (certs + panel.conf)"
fi

set_live 3 unknown "admin account only visible in panel/DB — verify manually"
set_live 4 unknown "login is a human action — verify manually"

if [ "$SSM_REACHABLE" = true ]; then
  if [ "${WINGS_CONFIGURED:-0}" = 1 ]; then
    set_live 5 done "Wings config present at /etc/pterodactyl/config.yml (node was configured)"
  else
    set_live 5 notdone "no /etc/pterodactyl/config.yml yet"
  fi
  if [ "${WINGS_ACTIVE:-0}" = 1 ]; then
    set_live 6 done "wings.service is active"
  else
    set_live 6 notdone "wings.service is not active"
  fi
else
  set_live 5 unknown "needs SSM (Wings config)"
  set_live 6 unknown "needs SSM (Wings service)"
fi

if [ "$SSM_REACHABLE" = true ]; then
  if [ "$SERVER_COUNT" -ge 1 ]; then
    set_live 7 done "inferred from $SERVER_COUNT server volume(s) — allocations required to create them"
  elif [ "${WINGS_CONFIGURED:-0}" = 1 ]; then
    set_live 7 unknown "Wings configured but no server volumes yet — check panel Allocations"
  else
    set_live 7 notdone "no Wings config / no server volumes"
  fi
  if [ "$SERVER_COUNT" -ge 2 ]; then
    set_live 8 done "$SERVER_COUNT server volumes under /var/lib/pterodactyl/volumes"
  elif [ "$SERVER_COUNT" -eq 1 ]; then
    set_live 8 notdone "only 1 server volume found (want Paper + Forge/Fabric)"
  else
    set_live 8 notdone "no server volumes yet"
  fi
else
  set_live 7 unknown "needs SSM (allocations / volumes)"
  set_live 8 unknown "needs SSM (server volumes)"
fi

if [ "$BUCKET_PRESENT" = true ] && [ "$BUCKET_OBJECT_COUNT" -gt 0 ]; then
  set_live 9 done "backup bucket has $BUCKET_OBJECT_COUNT object(s)"
elif [ "$BUCKET_PRESENT" = true ]; then
  set_live 9 unknown "bucket exists but is empty — may or may not be wired in the panel"
else
  set_live 9 notdone "backup bucket not found"
fi

set_live 10 unknown "whitelist requires a Minecraft client / friends — verify manually"
set_live 11 unknown "security posture is a human review (POST_DEPLOY.md step 11)"

# ---------------------------------------------------------------------------
# Parse checkboxes currently in the status file
# ---------------------------------------------------------------------------
i=1
while [ "$i" -le 11 ]; do
  FILE_STATE[$i]="missing"
  i=$((i + 1))
done

if [ -f "$STATUS_FILE" ]; then
  while IFS= read -r line; do
    num=$(echo "$line" | sed -n 's/^- \[[xX]\] \([0-9][0-9]*\)\..*/\1/p')
    if [ -n "$num" ]; then
      FILE_STATE[$num]="done"
      continue
    fi
    num=$(echo "$line" | sed -n 's/^- \[ \] \([0-9][0-9]*\)\..*/\1/p')
    if [ -n "$num" ]; then
      FILE_STATE[$num]="notdone"
    fi
  done < "$STATUS_FILE"
fi

# ---------------------------------------------------------------------------
# Diff report
# ---------------------------------------------------------------------------
CHANGED=0
UNKNOWN_COUNT=0

mark_box() {
  case "$1" in
    done) echo "[x]" ;;
    *) echo "[ ]" ;;
  esac
}

live_box() {
  case "$1" in
    done) echo "[x]" ;;
    notdone) echo "[ ]" ;;
    *) echo "[?]" ;;
  esac
}

if [ "$STACK_EXISTS" = true ]; then
  echo "Stack: $STACK_STATUS  instance=${INSTANCE_ID:-none}  ip=${PUBLIC_IP:-none}  DeployCompute=${DEPLOY_COMPUTE:-?}"
else
  echo "Stack: (none)"
fi
echo "SSM reachable: $SSM_REACHABLE   backup bucket: $BACKUP_BUCKET (present=$BUCKET_PRESENT objects=$BUCKET_OBJECT_COUNT)"
if [ -n "$BOOTSTRAP_LINE" ]; then
  echo "Bootstrap: $BOOTSTRAP_LINE"
fi
echo
printf "  %-6s %-48s %-10s %-10s %s\n" "step" "name" "file" "live" "result"
printf "  %-6s %-48s %-10s %-10s %s\n" "----" "----" "----" "----" "------"

i=1
while [ "$i" -le 11 ]; do
  f="${FILE_STATE[$i]}"
  l="${LIVE_STATE[$i]}"
  fb=$(mark_box "$f")
  lb=$(live_box "$l")
  if [ "$l" = "unknown" ]; then
    if [ "$f" = "done" ]; then
      result="${C_WARN}CHANGED→unknown${C_RESET}"
      CHANGED=$((CHANGED + 1))
    else
      result="${C_DIM}unknown${C_RESET}"
    fi
    UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1))
  elif [ "$f" = "$l" ]; then
    result="${C_OK}unchanged${C_RESET}"
  elif [ "$f" = "missing" ]; then
    result="${C_WARN}CHANGED${C_RESET}"
    CHANGED=$((CHANGED + 1))
  else
    result="${C_FAIL}CHANGED${C_RESET}"
    CHANGED=$((CHANGED + 1))
  fi
  printf "  %-6s %-48s %-10s %-10s %b\n" "$i" "${STEP_TITLE[$i]}" "file=$fb" "live=$lb" "$result"
  if [ -n "${LIVE_NOTE[$i]:-}" ]; then
    printf "         %s%s%s\n" "$C_DIM" "${LIVE_NOTE[$i]}" "$C_RESET"
  fi
  i=$((i + 1))
done

echo
echo "Summary: CHANGED=$CHANGED  unknown=$UNKNOWN_COUNT"

# ---------------------------------------------------------------------------
# Render + optionally write DEPLOYMENT_STATUS.md
# ---------------------------------------------------------------------------
checklist_line() {
  step="$1"
  state="${LIVE_STATE[$step]}"
  note="${LIVE_NOTE[$step]}"
  title="${STEP_TITLE[$step]}"

  case "$step" in
    3) title="Create admin account (includes gotcha #4 ALTER TABLE one-liner)" ;;
    10) title="Whitelist friends" ;;
  esac

  if [ "$state" = "unknown" ]; then
    echo "- [ ] ${step}. ${title} — **unknown** — ${note}"
  elif [ "$state" = "done" ] && [ -n "$note" ]; then
    echo "- [x] ${step}. ${title} — ${note}"
  elif [ "$state" = "done" ]; then
    echo "- [x] ${step}. ${title}"
  else
    echo "- [ ] ${step}. ${title}"
  fi
}

RECONCILED_AT=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

render_status() {
  cat <<EOF
# Deployment status

Tracks where the **current live instance** actually stands against
[\`POST_DEPLOY.md\`](../POST_DEPLOY.md)'s numbered steps — separate from
whether the automated scripts *would* get a fresh deploy this far
unattended.

**Last reconciled:** ${RECONCILED_AT} via
\`scripts/refresh-deployment-status.sh\`. Prefer re-running that script
over hand-editing the checklist; pass \`--write\` to apply. Steps the
script cannot prove stay **unknown** on purpose so a human verifies them.

EOF

  if [ "$STACK_EXISTS" != true ]; then
    cat <<EOF
## No live stack right now

\`aws cloudformation describe-stacks --stack-name ${STACK_NAME}\` finds no
stack in \`${REGION}\`.

EOF
    if [ "$BUCKET_PRESENT" = true ]; then
      cat <<EOF
The **S3 backup bucket survived** (or still exists):
\`${BACKUP_BUCKET}\` (\`${REGION}\`), object count ≈ ${BUCKET_OBJECT_COUNT}.

EOF
    fi
  else
    INSTANCE_CELL="\`${INSTANCE_ID:-none}\`"
    if [ -n "$INSTANCE_TYPE" ] && [ "$INSTANCE_TYPE" != "None" ]; then
      INSTANCE_CELL="${INSTANCE_CELL} (\`${INSTANCE_TYPE}\`)"
    fi
    SSM_CELL="${SSM_CMD}"
    if [ -z "$SSM_CELL" ]; then
      SSM_CELL="aws ssm start-session --target ${INSTANCE_ID} --profile ${PROFILE} --region ${REGION}"
    fi
    cat <<EOF
## Live stack

Stack \`${STACK_NAME}\` is \`${STACK_STATUS}\` in \`${REGION}\`.
DeployCompute=\`${DEPLOY_COMPUTE:-?}\`, BackupBucketExists=\`${BACKUP_BUCKET_EXISTS_PARAM:-?}\`.

| | |
|---|---|
| Instance | ${INSTANCE_CELL} |
| Public IP | \`${PUBLIC_IP:-none}\` |
| Panel | \`${PANEL_URL:-https://${FQDN}}\` |
| SSM | \`${SSM_CELL}\` |
| Backup bucket | \`${BACKUP_BUCKET}\` (present=${BUCKET_PRESENT}; objects≈${BUCKET_OBJECT_COUNT}) |
| SES | identity=\`${FQDN}\` verified=${SES_VERIFIED:-?} config-set=\`${SES_CONFIG_SET:-none}\` panel-mail=\`${MAIL_DRIVER:-?}\` |

EOF
    if [ -n "$BOOTSTRAP_LINE" ]; then
      echo "Bootstrap: \`${BOOTSTRAP_LINE}\`."
      echo
    fi
    if [ "$SSM_REACHABLE" = true ]; then
      echo "On-box probe: panel_running_count=${PANEL_UP:-?} cert=${HAS_CERT:-?} ssl_conf=${HAS_SSL_CONF:-?} wings_active=${WINGS_ACTIVE:-?} wings_configured=${WINGS_CONFIGURED:-?} server_volumes=${SERVER_COUNT}."
      echo
    else
      echo "On-box SSM probe was not available this run — instance-local steps may be marked unknown."
      echo
    fi
  fi

  echo "## Step checklist"
  echo
  i=1
  while [ "$i" -le 11 ]; do
    checklist_line "$i"
    i=$((i + 1))
  done

  cat <<EOF

## Automated vs. manual right now

DNS/TLS/Wings/server-volume signals above come from live probes. Steps marked
**unknown** (admin account, panel login, whitelist, security review — and
sometimes allocations/backups when evidence is ambiguous) still need a human.
Gotchas #1–3 and #5–14 are permanent fixes in \`bootstrap.sh\`/the template;
see [\`AI_ONBOARDING.md\`](AI_ONBOARDING.md). Step 3's \`external_id\`
\`ALTER TABLE\` remains a required manual one-liner in \`POST_DEPLOY.md\`.
Gotcha #14: live panel mail is SES; do not edit UserData \`MAIL_*\` on a
live stack (that replaces the instance).

## Two-tier teardown and tagging

\`DeployCompute\` / \`HasCompute\` supports tier-1 compute teardown while
keeping VPC/SG/IAM/S3/DNS/SES/DLM/SNS. \`deploy.sh\` tags resources
(\`Project=blockparty Build=<stack name> ManagedBy=cloudformation\`).
Tier-2 full teardown retains the S3 backup bucket; redeploy auto-detects it
via \`BackupBucketExists\` (gotcha #13). See \`ARCHITECTURE.md\` and
\`POST_DEPLOY.md\` → Teardown & rebuild.

## Known backlog (not blocking, not yet done)

From a one-time \`checkov\` scan of \`cloudformation/minecraft-stack.yaml\`
(see [\`AI_ONBOARDING.md\`](AI_ONBOARDING.md) → Conventions):
- Security group rules missing \`Description\` fields
- S3 backup bucket has no access logging enabled
- SNS alarm topic isn't encrypted at rest

None are exposure risks; just unaddressed hardening suggestions.
EOF
}

# Bash 3.2: no mapfile; capture via temp file.
TMP_RENDER=$(mktemp)
trap 'rm -f "$TMP_RENDER"' EXIT
render_status > "$TMP_RENDER"

if [ "$WRITE" = true ]; then
  cp "$TMP_RENDER" "$STATUS_FILE"
  echo "${C_OK}Wrote${C_RESET} $STATUS_FILE"
  exit 0
fi

echo "Dry-run only — did not modify $STATUS_FILE"
echo "Re-run with --write to apply the reconciled checklist."
if [ "$CHANGED" -gt 0 ]; then
  echo "${C_FAIL}File is out of date relative to live state (CHANGED=$CHANGED).${C_RESET}"
  exit 1
fi
exit 0
