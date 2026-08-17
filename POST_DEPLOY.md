# Post-deploy setup

One-time manual steps after `deploy.sh` finishes and bootstrap has completed
(`sudo tail -f /var/log/bootstrap.log` over SSM, watch for "bootstrap
complete"). These involve secrets (DB passwords, node tokens, admin
credentials, cert issuance) that are deliberately **not** baked into
CloudFormation parameters or user-data — anything passed that way ends up in
CloudTrail and the console. ~15–20 minutes total.

Connect with no SSH key needed:
```
aws ssm start-session --target <InstanceId> --profile dev-lab --region <region>
```
(`InstanceId` is a stack output; the `SsmConnectCommand` output has the full
command pre-filled.)

The panel's `APP_URL` is already set correctly at boot (fetched from an SSM
parameter the stack creates) — no manual sed/edit needed here anymore.

## 1. Confirm DNS has propagated

```
dig +short blockparty.charliesystems.ai
dig +short random-test.blockparty.charliesystems.ai   # proves the wildcard record works
```
Both should return the stack's `PublicIp` output. Route 53 is authoritative
and usually near-instant, but give it a minute if not.

## 2. Issue the wildcard TLS certificate

```
sudo su -
which certbot   # confirm the path certbot actually installed to
certbot certonly --dns-route53 \
  -d "blockparty.charliesystems.ai" \
  -d "*.blockparty.charliesystems.ai" \
  --non-interactive --agree-tos -m your-email@example.com
```
This uses the instance's IAM role (scoped to just this hosted zone) to
create/remove the `_acme-challenge` TXT record automatically — no manual DNS
work, and it's the only way to get a *wildcard* cert (Let's Encrypt requires
DNS-01 for wildcards; HTTP-01 can't do it). The cert lands at
`/etc/letsencrypt/live/blockparty.charliesystems.ai/`, which is bind-mounted
straight into the panel container.

**The panel image doesn't pick this up on its own.** Its entrypoint only
writes an SSL nginx config when an `LE_EMAIL` env var is set — and setting
that would make it run its *own* standalone HTTP-01 certbot, which conflicts
with the wildcard DNS-01 cert we just issued on the host. So on first boot it
wrote a plain HTTP-only `panel.conf` (bind-mounted at
`/srv/pterodactyl/panel/nginx/`), which persists across restarts — a bare
`docker compose restart panel` does **not** add an SSL server block.
Write the real one, pointed at the cert already on disk, then restart:

```
sudo tee /srv/pterodactyl/panel/nginx/panel.conf > /dev/null <<'NGINXCONF'
server {
    listen 80;
    server_name blockparty.charliesystems.ai;
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name blockparty.charliesystems.ai;

    root /app/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;

    sendfile off;

    ssl_certificate /etc/letsencrypt/live/blockparty.charliesystems.ai/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/blockparty.charliesystems.ai/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;

    add_header Strict-Transport-Security "max-age=15768000; preload;";
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
        include /etc/nginx/fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
NGINXCONF
cd /srv/pterodactyl/panel
docker compose restart panel
```

This is a one-time step. Renewal after this is automatic — a systemd timer
(`certbot-renew.timer`, installed by bootstrap) runs `certbot renew` daily
and restarts the panel container when a renewal actually happens; since
`panel.conf` now already has the SSL block pointed at the live cert path,
that restart alone is enough to pick up a renewed cert. Nothing further to
do here, ever, as long as the instance keeps running.

**Scope note:** this wildcard cert covers everything under
`*.blockparty.charliesystems.ai` — the panel now, and any future service you
put on this box (a status page, a second node, etc.) without touching DNS or
certs again. It does **not** wrap the raw Minecraft game ports (25565/25566)
in TLS — the vanilla Java Edition protocol doesn't support that; those stay
plain TCP, protected by the security group + in-game whitelist + Shield
Standard instead, same as it would be for AccuWebHosting or any other
Minecraft host.

## 3. Create your admin account

The database schema migrates and seeds itself automatically on first boot
(bootstrap.sh shadows the image's bundled schema dump so this always goes
through Laravel's normal per-migration path — see the comment above the
`empty-schema` volume mount in `bootstrap.sh` if you're curious why).

One known issue in Pterodactyl's individual migrations (as opposed to their
squashed schema dump) leaves `users.external_id` as `NOT NULL` when it's
meant to be nullable — creating your first user fails with `SQLSTATE[23000]:
... Column 'external_id' cannot be null` otherwise. Fix it once, then create
the account:

```
docker compose exec database sh -c 'mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" panel -e "ALTER TABLE users MODIFY external_id VARCHAR(191) NULL DEFAULT NULL;"'
docker compose exec panel php artisan p:user:make
```
Follow the prompts (email, username, password, and answer "yes" to admin).

Additional panel users created from the UI get an invite email from
`noreply@blockparty.charliesystems.ai` via SES (instance role, no SMTP
keys). Confirm the SNS subscription for topic `minecraft-server-ses-events`
— that's a second confirm-click, separate from the CloudWatch alarm topic
`deploy.sh` already mentioned. Bounce/complaint notices go there; SES's
suppression list then stops retrying that address.

The live panel's `MAIL_*` env was patched in place. The embedded
CloudFormation UserData still writes `MAIL_DRIVER: log` because changing
UserData replaces the instance. After a compute rebuild, copy the `MAIL_*`
block from `scripts/bootstrap.sh` into
`/srv/pterodactyl/panel/docker-compose.yml` and run `docker compose up -d
panel`, or copy those lines into the template UserData as part of the
rebuild. `scripts/diagnose.sh` warns if the driver is still `log`.

## 4. Log into the panel

Browse to `https://blockparty.charliesystems.ai` from the machine whose IP
you used as `AdminCidr`. You should get a clean, trusted cert now — no
warning. Log in with the account from step 3.

## 5. Create a Location and a Node

Admin → Locations → Create (anything, e.g. `aws-us-east-1`).
Admin → Nodes → Create:
- Location: the one you just made
- FQDN: `blockparty.charliesystems.ai`
- Communicate over SSL: **On** (you now have a real cert)
- Behind Proxy: No
- Daemon Port: `8080` (default)

Save, then open the node's **Configuration** tab — it shows a one-line
`wings configure ...` command with a one-time token.

## 6. Apply that config and start Wings

Back in your SSM session:
```
sudo <paste the wings configure command from the panel>
sudo systemctl restart wings
sudo systemctl status wings
```

If `wings configure` hangs and fails with `context deadline exceeded`
fetching `https://blockparty.charliesystems.ai/api/...`: Wings is trying to
reach the panel over its public FQDN, which resolves to this instance's own
Elastic IP — and an EC2 instance generally can't reach its own public IP
back through the Internet Gateway (no NAT gateway in this VPC). Bootstrap
now adds a loopback `/etc/hosts` entry for the subdomain to sidestep this,
so this shouldn't happen on a fresh deploy; if it does anyway (e.g. an
older instance from before this fix), add it by hand and retry:
```
echo "127.0.0.1 blockparty.charliesystems.ai" | sudo tee -a /etc/hosts
```
TLS still verifies correctly afterward — the cert matches the hostname
regardless of which IP it's served from. You may need a fresh token from
the panel's Auto-deploy if the failed attempt consumed the old one.

If `wings` starts crash-looping (`systemctl status wings` shows
`activating (auto-restart)`) with `journalctl -u wings` showing `failed to
detect system timezone ... the supplied timezone n/a is invalid`: AL2023
has no `/etc/timezone` file, and its minimal AMI often leaves
`/etc/localtime` not set up as a real zoneinfo symlink, so `timedatectl`
reports `Time zone: n/a` — Wings takes that literally and refuses to start.
Bootstrap now sets `TZ=UTC` directly on the systemd unit so this shouldn't
happen on a fresh deploy; if it does anyway, fix and retry:
```
sudo sed -i '/\[Service\]/a Environment=TZ=UTC' /etc/systemd/system/wings.service
sudo systemctl daemon-reload
sudo systemctl restart wings
sudo systemctl status wings
```

If `wings` fails immediately with `failed to configure docker environment
error=Error response from daemon: Pool overlaps with other one on this
address space`: Wings' own default network (`pterodactyl_nw`, created on
its first start) hardcodes `172.18.0.0/16` — the exact subnet Docker
Compose picks by default for the panel's own bridge network too, since
panel and Wings share one box (`docker network inspect panel_default` will
confirm the collision). Bootstrap now pins the panel's compose network to
`172.20.0.0/16` so this shouldn't happen on a fresh deploy; if it does
anyway (e.g. an older instance), fix and retry:
```
cd /srv/pterodactyl/panel
sudo tee -a docker-compose.yml > /dev/null <<'YAML'

networks:
  default:
    ipam:
      config:
        - subnet: 172.20.0.0/16
YAML
sudo docker compose down
sudo docker compose up -d
sudo systemctl restart wings
sudo systemctl status wings
```
`docker compose down`/`up` briefly stops the panel/database/cache
containers while the network gets recreated — a few seconds, harmless here.

## 7. Create allocations (ports) on the node

Admin → Nodes → your node → Allocations → Create. The form asks for an IP
address — use **`0.0.0.0`** (bind all interfaces), not the public/Elastic
IP. The Elastic IP is NAT'd at AWS's network edge and is never actually
bound to the instance's own network interface — the OS only knows its
private IP (`10.20.x.x`). Wings/Docker would fail to bind if you entered
the public IP here; this is the standard "node behind NAT" pattern
Pterodactyl's own docs describe (don't use `127.0.0.1` either — the panel
explicitly disallows it). If there's an optional **IP Alias** field, set it
to `blockparty.charliesystems.ai` so the panel displays the friendly
hostname instead of the internal IP — purely cosmetic, doesn't affect
binding.

Then create the two ports:
- `25565` for the Paper world
- `25566` for the Forge/Fabric world

(Both ports are already open in the security group — see `AdminCidr`/
`GameCidr` parameters if you need to change who can reach them. Both also
already have SRV records, so friends can connect with just
`blockparty.charliesystems.ai` and `modded.blockparty.charliesystems.ai` —
no port number needed.)

## 8. Create the two servers

Admin → Servers → New. Use the same resource/feature limits for both:

| Field | Value |
|---|---|
| Memory | `4096` MB |
| Disk | `5000` MB |
| Enable OOM Killer | on |
| Database Limit | `1` |
| Allocation Limit | `1` |
| Backup Limit | `1` |

Leaving Backup Limit at 0 means the Backups tab won't let you create any,
and you'll need step 9 to actually work. These are usually editable later
without a rebuild via Admin → Servers → your server → Build Configuration.

**Paper world**
- Nest/Egg: Minecraft Java → Paper
- Allocation: `25565`
- Startup: set the Minecraft version/build via the egg's variables

**Modded world**
- Nest/Egg: Minecraft Java → Forge (or the CurseForge/Modrinth modpack egg
  if you install Pterodactyl's community egg for it — makes picking a
  specific modpack a dropdown instead of manual jar wrangling)
- Allocation: `25566`

Each server gets its own console, file manager, and scheduler in the panel
— that's where day-to-day plugin/mod management happens (upload a plugin
jar to `/plugins`, restart; pick a new modpack version from the egg
dropdown, reinstall).

**Forge: expected first-boot jar fix (do this as one workflow).** Modern
Forge (roughly 1.17+) installs a launcher script (`run.sh`) plus a
`*-shim.jar`, not a monolithic `server.jar`, but the built-in "Forge" egg's
default Startup Command still hardcodes `-jar server.jar`. The real jar
name isn't knowable until the install finishes, so don't treat the first
crash as a failure — bake the fix into create:

1. Create the Forge server and let the install run to completion (console
   will typically hit `Unable to access jarfile server.jar` right after
   "Server marked as starting" — that's the signal the files are on disk).
2. Find the actual launcher on the host:
   ```
   sudo ls /var/lib/pterodactyl/volumes/<server-uuid>/
   ```
   Look for something like `forge-<version>-shim.jar` (or `run.sh`).
3. On the server's **Startup** tab, set **Server Jar File** (or edit the
   Startup Command) to that real filename — not `server.jar`.
4. Restart the server from the panel and confirm the console gets past
   jar launch.

Not an infrastructure bug and not worth baking into `bootstrap.sh` — just
an egg/Minecraft-version mismatch that has to wait for the first install.

**Faster than clicking through the panel to find issues like this:**
`scripts/diagnose.sh` checks every failure mode this project has hit so far
in one pass — panel/Wings health, the hairpin-DNS and network-collision
fixes are actually in place, cert status, and per-server launcher sanity
(including this exact `server.jar` mismatch). Run it in your SSM session:
```
curl -s https://raw.githubusercontent.com/steve-cloudmaker/blockparty/main/scripts/diagnose.sh | sudo bash
```

If creating a server (or just opening the node overview) shows **"Could not
establish a connection to the machine running this server. Please try
again"**: this is the panel *backend* failing to reach Wings, not your
browser. The panel container has its own isolated `/etc/hosts` — the
loopback entry bootstrap adds for the subdomain lives on the host and
doesn't carry into the container, so the panel's request to
`https://blockparty.charliesystems.ai:8080` resolves via public DNS to this
instance's own Elastic IP and hits the same can't-reach-your-own-public-IP
wall as the `wings configure` issue in step 6 — just from inside Docker
this time. Bootstrap now adds an `extra_hosts: - "$SUBDOMAIN:host-gateway"`
override on the panel service so this shouldn't happen on a fresh deploy;
if it does anyway, confirm with:
```
cd /srv/pterodactyl/panel
docker compose exec panel sh -c 'curl -m 5 -vk https://blockparty.charliesystems.ai:8080/api/system'
```
A hang/timeout confirms it. Fix and retry:
```
sudo sed -i '/^  panel:/a\    extra_hosts:\n      - "blockparty.charliesystems.ai:host-gateway"' docker-compose.yml
sudo docker compose up -d panel
```

If a specific server's console instead shows **"We're having some trouble
connecting to your server, please wait..."** and never clears: this is a
different path than the one above — the panel's *frontend* JavaScript opens
a WebSocket **directly from your browser** to Wings' daemon port (8080),
bypassing the panel backend entirely, for the live console/stats. The
security group originally only allowed 443/25565/25566 — the daemon port
was never opened even to the admin CIDR, since the original design assumed
Wings' API never needed to be reachable from outside the host at all (see
`ARCHITECTURE.md`; this assumption was wrong for the console specifically).
Fixed by adding an admin-CIDR-restricted `8080/tcp` ingress rule to
`GameServerSecurityGroup` in `cloudformation/minecraft-stack.yaml` — same
restriction as the panel's own 443 rule, so this doesn't expose Wings more
broadly than the panel already is. Re-run `scripts/deploy.sh` to apply it
to an existing stack (it's a non-destructive SG update).

## 9. Wire up S3 backups

Admin → that server → Settings, or globally in the panel's backup
configuration: set the backup driver to **S3**, bucket = the
`BackupBucketName` stack output, region = your stack region, and **leave
the access key / secret key fields blank** — Wings runs under the
instance's IAM role, which already has scoped read/write to that bucket, so
it'll pick up credentials automatically via the instance metadata service.
Test with a manual backup from a server's Backups tab before relying on the
schedule.

Set a recurring backup schedule per server (panel → server → Schedules).

## 10. Whitelist your friends

Per server: console → `whitelist add <username>` and `whitelist on`, or via
the panel's file manager on `whitelist.json`.

## 11. Verify the DDoS/security posture

- `aws ec2 describe-security-groups` — confirm only 443 and 8080 (your IP),
  and 25565, 25566 (open) are allowed.
- Panel and Wings' daemon API (8080) are both unreachable from outside
  `AdminCidr` — try it from another network.
- Elastic IP is automatically under Shield Standard; nothing to configure.
- `https://blockparty.charliesystems.ai` shows a valid, trusted cert (padlock,
  no warning) from any network.

## Teardown & rebuild

Two tiers, depending on how much you want to keep:

**Tier 1 — keep core infra, rebuild the rest.** For "something went wrong
with the instance/EBS volume, start fresh" scenarios. Tears down the EC2
instance, its EBS data volume, the Elastic IP *association*, and the
instance-scoped CloudWatch alarms — keeps the VPC, security group, IAM, S3
backup bucket, DNS records, SES sending identity (DKIM/SPF + bounce/complaint
SNS), DLM snapshot policy, and SNS alarm topic/subscription in place. This is a stack **update**, not a delete:
```
DEPLOY_COMPUTE=false scripts/deploy.sh
```
To rebuild: re-run `scripts/deploy.sh` normally (no `DEPLOY_COMPUTE`). A
fresh instance boots via the same bootstrap and re-associates with the
*same* Elastic IP — since DNS points at the EIP itself, not the instance,
nothing needs to change there, and the wildcard cert just needs reissuing
(POST_DEPLOY.md step 2 again). World save data on the old EBS volume is
gone; restore from the S3 backup bucket (per-server Pterodactyl backups) or
a DLM EBS snapshot (whole-volume, daily, 7-day retention) after rebuilding
and re-registering the node.

**Tier 2 — everything, to zero.** `scripts/teardown.sh` deletes the whole
stack: VPC, security group, IAM, DNS records, SES identities/config set,
DLM policy, SNS topics, and
the EC2 instance if one still exists. The S3 backup bucket survives even
this (`DeletionPolicy: Retain`) — deleting your actual backups is
deliberately never bundled into a scripted teardown. The script prints the
`aws s3 rb --force` command for that as a separate, explicit step once
you're sure.

**Redeploying from scratch after a tier-2 teardown** will fail with
`Failed to create the changeset: ... [AWS::EarlyValidation::ResourceExistenceCheck]`
if you don't have the fix below — the S3 bucket survived on purpose, but
S3 bucket names are globally unique, so CloudFormation refuses to create
one with the same name again. `scripts/deploy.sh` auto-detects this
(`head-bucket` check) and adjusts automatically, so this shouldn't surface
at all on a current checkout. If it does anyway (e.g. an older
`deploy.sh`), first clean up the stuck stub stack the failed attempt left
behind:
```
aws cloudformation delete-stack --profile dev-lab --region us-west-1 --stack-name minecraft-server
```
(Safe — it's sitting in `REVIEW_IN_PROGRESS` with no real resources
created yet.) Then re-run `scripts/deploy.sh` on a current checkout.

## Later, optional

- Add a second Wings node if you outgrow one instance — the panel/node
  split means this doesn't touch the existing servers, and the wildcard
  cert/DNS already cover whatever hostname you give it under
  `*.blockparty.charliesystems.ai`.
