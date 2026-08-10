#!/bin/bash
# Bootstrap script for the Minecraft/Pterodactyl host.
# Runs once as EC2 user-data on first boot (Amazon Linux 2023, ARM64).
# Idempotent-ish: safe to re-run manually via SSM if something fails partway.
set -euo pipefail
exec > >(tee -a /var/log/bootstrap.log) 2>&1
echo "=== bootstrap start: $(date -u) ==="

# ---------------------------------------------------------------------------
# 0. Basics
# ---------------------------------------------------------------------------
dnf -y update
# --allowerasing: AL2023 ships curl-minimal by default, which conflicts with
# the full curl package pulled in here (needed for certbot/AWS CLI download
# steps below) — without this flag dnf aborts the whole transaction.
dnf -y install --allowerasing docker xfsprogs jq curl amazon-cloudwatch-agent
systemctl enable --now docker

# Docker Compose v2 plugin (not bundled with AL2023's docker package)
mkdir -p /usr/local/lib/docker/cli-plugins
if [ ! -x /usr/local/lib/docker/cli-plugins/docker-compose ]; then
  curl -sSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-aarch64" \
    -o /usr/local/lib/docker/cli-plugins/docker-compose
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
fi

# AWS CLI v2 + certbot with the Route 53 DNS plugin — used later for the
# wildcard TLS cert (DNS-01 challenge, no open port 80 needed).
if ! command -v aws >/dev/null 2>&1; then
  dnf -y install unzip
  curl -s "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscliv2.zip
  (cd /tmp && unzip -q awscliv2.zip && ./aws/install)
fi
dnf -y install python3-pip
# --break-system-packages only exists on pip >= 23.0.1 (PEP 668); AL2023's
# default python3-pip (21.3.1) predates it and errors on the unknown flag.
PIP_FLAGS=""
if pip3 install --help 2>/dev/null | grep -q break-system-packages; then
  PIP_FLAGS="--break-system-packages"
fi
pip3 install $PIP_FLAGS --quiet certbot certbot-dns-route53

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
# Set via CloudFormation (SubdomainParameter) so this file needs no editing.
SUBDOMAIN=$(aws ssm get-parameter --name /minecraft/subdomain --region "$REGION" --query 'Parameter.Value' --output text)

# Panel and Wings run on the same box, but Wings talks to the panel over its
# public FQDN (needed for `wings configure`'s --panel-url). Public DNS for
# that FQDN resolves to this instance's own Elastic IP, and an EC2 instance
# generally can't reach its own public IP back through the Internet Gateway
# (no NAT gateway in this VPC to hairpin through) — that request just hangs
# until it times out. Resolving the FQDN to loopback instead sidesteps it;
# TLS still verifies fine since the cert matches the hostname either way.
grep -q "$SUBDOMAIN" /etc/hosts || echo "127.0.0.1 $SUBDOMAIN" >> /etc/hosts

# ---------------------------------------------------------------------------
# 1. Find, format (if needed), and mount the data EBS volume at /srv/pterodactyl
# ---------------------------------------------------------------------------
ROOT_SRC=$(findmnt -n -o SOURCE / | sed 's/p\?[0-9]*$//')
DATA_DEV=""
for cand in /dev/nvme1n1 /dev/xvdf /dev/sdf; do
  if [ -b "$cand" ] && [ "$cand" != "$ROOT_SRC" ]; then
    DATA_DEV="$cand"
    break
  fi
done

if [ -z "$DATA_DEV" ]; then
  echo "!! Could not locate the data volume automatically. Check 'lsblk' and mount /srv/pterodactyl manually." >&2
else
  mkdir -p /srv/pterodactyl
  if ! blkid "$DATA_DEV" >/dev/null 2>&1; then
    mkfs.xfs "$DATA_DEV"
  fi
  UUID=$(blkid -s UUID -o value "$DATA_DEV")
  grep -q "$UUID" /etc/fstab || echo "UUID=$UUID /srv/pterodactyl xfs defaults,nofail 0 2" >> /etc/fstab
  mountpoint -q /srv/pterodactyl || mount /srv/pterodactyl
fi

mkdir -p /srv/pterodactyl/panel/{var,nginx,certs,logs,mysql,redis,empty-schema}
mkdir -p /srv/pterodactyl/wings/{etc,logs}
mkdir -p /srv/pterodactyl/wings-data   # bind-mounted into wings for server volumes

# ---------------------------------------------------------------------------
# 2. Pterodactyl Panel via docker compose (generated per-host secrets)
# ---------------------------------------------------------------------------
CRED_FILE=/root/pterodactyl-credentials.txt
if [ ! -f "$CRED_FILE" ]; then
  DB_ROOT_PW=$(openssl rand -hex 20)
  DB_PANEL_PW=$(openssl rand -hex 20)
  APP_KEY_SEED=$(openssl rand -hex 32)
  cat > "$CRED_FILE" <<EOF
# Generated on first boot. Root-readable only. Retrieve via SSM Session Manager:
#   sudo cat /root/pterodactyl-credentials.txt
MYSQL_ROOT_PASSWORD=$DB_ROOT_PW
MYSQL_PANEL_PASSWORD=$DB_PANEL_PW
APP_KEY_SEED=$APP_KEY_SEED
EOF
  chmod 600 "$CRED_FILE"
fi
source "$CRED_FILE"

cat > /srv/pterodactyl/panel/docker-compose.yml <<COMPOSE
services:
  database:
    image: mariadb:10.11
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: "${MYSQL_ROOT_PASSWORD}"
      MYSQL_DATABASE: "panel"
      MYSQL_USER: "pterodactyl"
      MYSQL_PASSWORD: "${MYSQL_PANEL_PASSWORD}"
    volumes:
      - /srv/pterodactyl/panel/mysql:/var/lib/mysql

  cache:
    image: redis:7-alpine
    restart: unless-stopped
    volumes:
      - /srv/pterodactyl/panel/redis:/data

  panel:
    image: ghcr.io/pterodactyl/panel:latest
    restart: unless-stopped
    ports:
      - "443:443"
      - "80:80"
    # The panel container needs to reach Wings (a native systemd process on
    # this same host) at https://$SUBDOMAIN:8080 to fetch node/server info.
    # Docker containers have their own isolated /etc/hosts, so the host-level
    # loopback entry above doesn't apply here -- without this override, that
    # request resolves via public DNS to this instance's own Elastic IP and
    # hits the same can't-hairpin-to-your-own-public-IP wall as before, just
    # from inside the container. host-gateway is Docker's own alias for "the
    # host, as reachable from this container" -- no IP to hardcode.
    extra_hosts:
      - "${SUBDOMAIN}:host-gateway"
    links:
      - database
      - cache
    environment:
      APP_URL: "https://${SUBDOMAIN}"
      APP_TIMEZONE: "UTC"
      APP_SERVICE_AUTHOR: "admin@example.com"
      TRUSTED_PROXIES: "*"
      MAIL_FROM: "noreply@example.com"
      MAIL_DRIVER: "log"
      DB_HOST: "database"
      DB_PORT: "3306"
      DB_DATABASE: "panel"
      DB_USERNAME: "pterodactyl"
      DB_PASSWORD: "${MYSQL_PANEL_PASSWORD}"
      CACHE_DRIVER: "redis"
      SESSION_DRIVER: "redis"
      QUEUE_DRIVER: "redis"
      REDIS_HOST: "cache"
    volumes:
      - /srv/pterodactyl/panel/var:/app/var
      - /srv/pterodactyl/panel/nginx:/etc/nginx/http.d
      - /etc/letsencrypt:/etc/letsencrypt
      - /srv/pterodactyl/panel/logs:/app/storage/logs
      # Shadows the image's bundled database/schema/mysql-schema.sql with an
      # empty host dir so Laravel's migrate never attempts the raw-SQL fast
      # path, which shells out to the mysql CLI. That CLI defaults to
      # requiring TLS (Debian Trixie's mariadb-client 11.4+), which our
      # internal-only mariadb container doesn't support, and fails migrate
      # on every fresh boot otherwise. Individual migrations run over PHP's
      # own PDO driver instead, which has no such default and just works.
      - /srv/pterodactyl/panel/empty-schema:/app/database/schema

# Wings' own default network (pterodactyl_nw, created on its first start)
# hardcodes 172.18.0.0/16 — the exact subnet Docker Compose picks by default
# for this project's own bridge network too, since panel+Wings share one
# box. Pin this one off Wings' default so `wings configure`/first-start
# never fails with "Pool overlaps with other one on this address space".
networks:
  default:
    ipam:
      config:
        - subnet: 172.20.0.0/16
COMPOSE

# Real host path (not /srv/pterodactyl/panel/certs) so certbot, running
# natively on the host, and the panel container both read/write the exact
# same cert files at /etc/letsencrypt/live/$SUBDOMAIN/{fullchain,privkey}.pem.
# The panel serves plain HTTP until then — its entrypoint only writes an SSL
# nginx config when an LE_EMAIL env var triggers its own standalone certbot,
# which we deliberately don't set (it'd conflict with the wildcard DNS-01 cert
# issued here). POST_DEPLOY.md's cert step writes the real SSL panel.conf by
# hand once the cert exists.
mkdir -p /etc/letsencrypt

cd /srv/pterodactyl/panel
docker compose up -d

# ---------------------------------------------------------------------------
# 3. Wings (game server daemon) — binary + systemd unit, NOT started yet.
#    Wings needs a config generated by the Panel after you register this node
#    (panel UI -> Nodes -> Create -> Configuration tab gives a one-line
#    `wings configure` command). See POST_DEPLOY.md.
# ---------------------------------------------------------------------------
curl -sSL -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_arm64"
chmod +x /usr/local/bin/wings

cat > /etc/systemd/system/wings.service <<'UNIT'
[Unit]
Description=Pterodactyl Wings daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
WorkingDirectory=/etc/pterodactyl
# AL2023 has no /etc/timezone (a Debian/Ubuntu-only file) and its minimal
# AMI often leaves /etc/localtime not properly set up as a zoneinfo symlink,
# so `timedatectl` reports "Time zone: n/a" — Wings takes that literally
# and refuses to start ("the supplied timezone n/a is invalid"). Force UTC
# explicitly rather than relying on host detection, matching APP_TIMEZONE
# on the panel container above.
Environment=TZ=UTC
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid

[Install]
WantedBy=multi-user.target
UNIT

mkdir -p /etc/pterodactyl
systemctl daemon-reload
systemctl enable wings   # enabled but will fail to start until config.yml exists — expected

# ---------------------------------------------------------------------------
# 3b. Cert renewal — DNS-01 via route53 plugin needs no open ports and no
#     manual step once the first cert is issued (see POST_DEPLOY.md).
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/certbot-renew.service <<'UNIT'
[Unit]
Description=Renew Let's Encrypt certificates

[Service]
Type=oneshot
ExecStart=/usr/local/bin/certbot renew --quiet --deploy-hook "cd /srv/pterodactyl/panel && docker compose restart panel"
UNIT

cat > /etc/systemd/system/certbot-renew.timer <<'UNIT'
[Unit]
Description=Daily Let's Encrypt renewal check

[Timer]
OnCalendar=daily
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now certbot-renew.timer

# ---------------------------------------------------------------------------
# 4. CloudWatch agent — CPU/mem/disk metrics
# ---------------------------------------------------------------------------
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<EOF
{
  "metrics": {
    "namespace": "MinecraftHost",
    "append_dimensions": { "InstanceId": "\${aws:InstanceId}" },
    "metrics_collected": {
      "mem": { "measurement": ["mem_used_percent"] },
      "disk": { "measurement": ["used_percent"], "resources": ["/", "/srv/pterodactyl"] }
    }
  }
}
EOF
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

echo "=== bootstrap complete: $(date -u) ===" | tee /var/log/user-data-complete
