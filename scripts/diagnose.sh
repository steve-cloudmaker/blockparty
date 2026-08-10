#!/bin/bash
# Health check for every known failure mode this project has actually hit
# (see Common/AI_ONBOARDING.md for the full writeup of each). Read-only —
# doesn't fix anything, just tells you what's wrong faster than clicking
# through the panel UI or paging through logs by hand.
#
# Run this ON THE INSTANCE, as root, over SSM:
#   aws ssm start-session --target <InstanceId> --profile dev-lab --region <region>
#   sudo bash /path/to/diagnose.sh
# (or paste the script contents directly if it's not already on the box)
#
# Security-group-level checks (which ports are open) run from your own
# machine instead, via `aws ec2 describe-security-groups` — see
# POST_DEPLOY.md step 11. This script only sees what the instance itself
# can see.

# Color only when stdout is an actual terminal (SSM sessions are) and the
# user hasn't opted out via NO_COLOR (https://no-color.org) -- avoids
# dumping raw escape codes into a file if output ever gets redirected/piped.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_RESET=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_FAIL=""; C_RESET=""
fi

ok()   { echo "${C_OK}[OK]${C_RESET}   $1"; }
warn() { echo "${C_WARN}[WARN]${C_RESET} $1"; }
fail() { echo "${C_FAIL}[FAIL]${C_RESET} $1"; }

echo "=== blockparty diagnostics: $(date -u) ==="
echo

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------
if [ -f /var/log/user-data-complete ]; then
  ok "bootstrap completed ($(cat /var/log/user-data-complete))"
else
  fail "bootstrap never completed -- check /var/log/bootstrap.log for where it stopped"
fi

# ---------------------------------------------------------------------------
# Panel container stack
# ---------------------------------------------------------------------------
if [ -f /srv/pterodactyl/panel/docker-compose.yml ]; then
  cd /srv/pterodactyl/panel
  NOT_RUNNING=$(docker compose ps --format json 2>/dev/null | jq -r 'select(.State != "running") | .Service')
  if [ -z "$NOT_RUNNING" ]; then
    ok "all panel containers running (database, cache, panel)"
  else
    fail "container(s) not running: $NOT_RUNNING -- check 'docker compose logs <service>'"
  fi

  if grep -q "listen 443 ssl" nginx/panel.conf 2>/dev/null; then
    ok "panel.conf has an SSL server block"
  else
    fail "panel.conf has no SSL block -- panel is serving plain HTTP only, see POST_DEPLOY.md step 2"
  fi

  if grep -q "host-gateway" docker-compose.yml; then
    ok "panel has extra_hosts host-gateway override (server pages need this)"
  else
    fail "panel missing extra_hosts host-gateway override -- server pages will show 'Could not establish a connection', see POST_DEPLOY.md step 8"
  fi

  if grep -q "172.20.0.0/16" docker-compose.yml; then
    ok "panel compose network pinned off Wings' default subnet"
  else
    warn "panel compose network has no explicit subnet pin -- could collide with Wings' default 172.18.0.0/16, see POST_DEPLOY.md step 6"
  fi
else
  fail "no docker-compose.yml at /srv/pterodactyl/panel -- bootstrap may not have finished"
fi

# ---------------------------------------------------------------------------
# Wings
# ---------------------------------------------------------------------------
if systemctl is-active --quiet wings; then
  ok "wings.service is active"
else
  fail "wings.service is $(systemctl is-active wings 2>&1) -- check 'journalctl -u wings -n 50'"
fi

if grep -q "Environment=TZ=UTC" /etc/systemd/system/wings.service 2>/dev/null; then
  ok "wings.service has TZ=UTC set"
else
  warn "wings.service has no TZ override -- may crash-loop with 'timezone n/a is invalid', see POST_DEPLOY.md step 6"
fi

SUBDOMAIN=$(grep "^remote:" /etc/pterodactyl/config.yml 2>/dev/null | sed 's#remote: https\?://##' | tr -d '"' | tr -d '[:space:]')
if [ -n "$SUBDOMAIN" ]; then
  if grep -q "$SUBDOMAIN" /etc/hosts; then
    ok "/etc/hosts has a loopback entry for $SUBDOMAIN"
  else
    fail "/etc/hosts is missing a loopback entry for $SUBDOMAIN -- wings configure/API calls may hairpin-timeout, see POST_DEPLOY.md step 6"
  fi
else
  warn "couldn't read panel URL from /etc/pterodactyl/config.yml -- has 'wings configure' been run yet?"
fi

CRASH_COUNT=$(grep -c "entering a crashed state" /var/log/pterodactyl/wings.log 2>/dev/null || echo 0)
if [ "$CRASH_COUNT" -gt 0 ]; then
  warn "$CRASH_COUNT crash event(s) logged in wings.log -- check 'grep crashed /var/log/pterodactyl/wings.log' for which server(s)"
fi

# ---------------------------------------------------------------------------
# TLS cert
# ---------------------------------------------------------------------------
if [ -n "$SUBDOMAIN" ]; then
  CERT="/etc/letsencrypt/live/$SUBDOMAIN/fullchain.pem"
  if [ -f "$CERT" ]; then
    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT" 2>/dev/null | cut -d= -f2)
    ok "TLS cert present, expires $EXPIRY"
  else
    fail "no cert found at $CERT -- run POST_DEPLOY.md step 2"
  fi
fi

# ---------------------------------------------------------------------------
# Per-server launcher sanity (the Forge "Unable to access jarfile" class of bug)
# ---------------------------------------------------------------------------
if [ -d /var/lib/pterodactyl/volumes ]; then
  for dir in /var/lib/pterodactyl/volumes/*/; do
    uuid=$(basename "$dir")
    [ "$uuid" = ".sftp" ] && continue
    if [ -f "${dir}server.jar" ]; then
      ok "server $uuid: server.jar present"
    elif ls "${dir}"*shim*.jar >/dev/null 2>&1 || [ -f "${dir}run.sh" ]; then
      ALT=$(ls "${dir}"*shim*.jar 2>/dev/null | head -1)
      warn "server $uuid: no server.jar, but found $(basename "${ALT:-${dir}run.sh}") -- if the Startup Command/Server Jar File variable still says server.jar, this server won't start (see POST_DEPLOY.md step 8)"
    else
      warn "server $uuid: no server.jar and no recognizable alternate launcher -- may still be installing, or the install may have failed"
    fi
  done
fi

echo
echo "=== done ==="
