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

## 7. Create allocations (ports) on the node

Admin → Nodes → your node → Allocations → Create:
- `25565` for the Paper world
- `25566` for the Forge/Fabric world

(Both ports are already open in the security group — see `AdminCidr`/
`GameCidr` parameters if you need to change who can reach them. Both also
already have SRV records, so friends can connect with just
`blockparty.charliesystems.ai` and `modded.blockparty.charliesystems.ai` —
no port number needed.)

## 8. Create the two servers

Admin → Servers → New:

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

- `aws ec2 describe-security-groups` — confirm only 443 (your IP), 25565,
  25566 are open.
- Panel is unreachable from outside `AdminCidr` — try it from another
  network.
- Elastic IP is automatically under Shield Standard; nothing to configure.
- `https://blockparty.charliesystems.ai` shows a valid, trusted cert (padlock,
  no warning) from any network.

## Later, optional

- Add a second Wings node if you outgrow one instance — the panel/node
  split means this doesn't touch the existing servers, and the wildcard
  cert/DNS already cover whatever hostname you give it under
  `*.blockparty.charliesystems.ai`.
